# Regular-Long-Short-35Min-V2.ps1

Regular-candle, long + short **option buying** bot for Zerodha Kite. It watches live ticks of one instrument, builds
candles of the chosen timeframe, buys a **CE** on a strong green candle and a **PE** on a strong red candle, and
closes everything at the end of every candle.

Script: [Regular-Long-Short-35Min-V2.ps1](./Regular-Long-Short-35Min-V2.ps1) · Shared helpers: [KiteData.psm1](./KiteData.psm1)

---

## 1. Quick start

```powershell
# Uses input.json for everything except TimeFrame (script default: 35minute)
.\Regular-Long-Short-35Min-V2.ps1

# Examples
.\Regular-Long-Short-35Min-V2.ps1 -ExitTrade no
.\Regular-Long-Short-35Min-V2.ps1 -TimeFrame 15minute -NoOfLotsPurchaseAtaTime 1 -AmountToTrade 0 -ExitTrade yes
.\Regular-Long-Short-35Min-V2.ps1 -ExitTrade no -SLTriggerPercentage 3 -SLPriceGap 2 -ForceExitTime 15:20
```

This places **real orders**. `-AmountToTrade 0` forces exactly `NoOfLotsPurchaseAtaTime` lots.

---

## 2. Signal logic

Candles are built from live ticks of `TradingSymbol` and are anchored to the 09:15 market open
(35m candles: 09:15, 09:50, 10:25, 11:00, 11:35, 12:10, 12:45, 13:20, 13:55, 14:30, 15:05).
The last 35m candle is shorter than 35 minutes.

The signal is evaluated on **every tick** of the forming candle, using only that candle's own Open and Close:

| Condition | Meaning |
|---|---|
| `Close >= Open + OffsetPoints` | **GREEN** → CE signal |
| `Close <= Open - OffsetPoints` | **RED** → PE signal |

> `TradingSymbol` is whatever is in `input.json`. If it is an option contract (e.g. `NIFTY26O1923050CE`), the
> candles, the offset and the signals are based on **that option's premium**, not on the index. Use the index symbol
> (e.g. `NIFTY`) if you want index-based signals.

A new entry is allowed only when **all** are true:

- the time is within `StartTime`–`StopTime` **and** earlier than `ForceExitTime`;
- fewer than `MaxRetryCountOnBar` entries have been made in the current candle (counter resets every candle);
- the side is not already open (max one CE and one PE);
- (`ExitTrade = yes` only) the opposite side is not open;
- the last failed entry attempt was more than 2 seconds ago.

### Strike selection and size

- Strike: ATM strike from the **index spot price** (`Get-KiteSpotPrice`), shifted by `ATMOffset`
  (CE = `-ATMOffset`, PE = `+ATMOffset`), nearest expiry.
- Size: `NoOfLotsPurchaseAtaTime` lots, **or** if `AmountToTrade > 0`: `floor(AmountToTrade / (option LTP x lot size))`
  lots (minimum 1).
- Orders: `BUY` to open, `SELL` to close, order type `Order_type` (normally `MARKET` with `MarketProtection`),
  product `Product`, variety `Variety`. Kite may show a protected MARKET order as `LIMIT` in the order book.

---

## 3. `ExitTrade = yes`

No stop-loss orders are placed.

| Event | Action |
|---|---|
| Candle turns GREEN, flat | BUY CE |
| Candle turns RED while CE open | Market-SELL CE, then BUY PE |
| Candle turns GREEN while PE open | Market-SELL PE, then BUY CE |
| Candle closes | Market-SELL all open positions |

Only one side is open at a time.

## 4. `ExitTrade = no`

Every new position gets its own stop-loss. The opposite colour does **not** close anything (the SL is the protection),
so a CE and a PE can be open together (at most one each).

| Event | Action |
|---|---|
| Candle turns GREEN, no CE open | BUY CE, then place SELL SL for the CE |
| Candle turns RED, no PE open | BUY PE, then place SELL SL for the PE |
| Opposite colour | Nothing is closed |
| SL is hit | Position is booked as closed; a new entry on that side is allowed again (within `MaxRetryCountOnBar`) |
| Candle closes | Cancel the bot's own SLs **first**, then market-SELL each remaining position |

### Stop-loss calculation (no historical API)

Taken from the bought option's live LTP right after the buy. The percentage is read from `SLTriggerPercentage` in
`input.json` (nothing is hard-coded; e.g. `"SLTriggerPercentage": 3` means 3%):

```
trigger = round(LTP x (1 - SLTriggerPercentage/100))     # whole number
price   = trigger - SLPriceGap                           # whole number, default SLPriceGap = 2
```

Examples with `SLTriggerPercentage = 3`:

| Option LTP | Trigger | Price |
|---|---|---|
| 301 | 292 | 290 |
| 100 | 97 | 95 |
| 150.5 | 146 | 144 |

The SL is a SELL order of type `SL` (trigger + limit price) with tag `SL-CE` / `SL-PE`.
If the LTP cannot be fetched, the LTP recorded just before the buy is used.

**SL cannot be placed** (trigger not below LTP, price <= 0 for very cheap options, or API rejection):
one retry, then the position is market-exited immediately.

---

## 5. Closing rules (both modes)

Closing order is always: **cancel SL → verify → market SELL**.

1. **Cancel the SL** (only the order ID this bot placed, never other orders in the account), up to 3 attempts.
   - If the order turns out to be `COMPLETE`, the SL already filled: the exit is booked at the SL fill price and
     **no market sell is sent**.
   - If it is already `CANCELLED`/`REJECTED`, continue to the sell.
   - If all 3 attempts fail, log a warning and **still market-sell** (check Kite for a leftover SL).
2. **Check the broker net quantity** for the symbol. If it is already flat, nothing is sold. Otherwise the sell
   quantity is capped at the net quantity, so a double sell can never create a short.
3. **Market SELL**. If the sell fails it is retried every 5 seconds until it succeeds.

Positions are closed at:

| Trigger | Notes |
|---|---|
| Candle close | Every candle, both modes |
| `ForceExitTime` (default 15:20) | Closes everything, then the script stops. The last 35m candle (15:05) would otherwise run to 15:30. |
| Opposite colour | `ExitTrade = yes` only |
| SL fill | `ExitTrade = no` only |
| Feed lost | After all WebSocket reconnect attempts fail, remaining positions are closed |

The script stops itself at `ForceExitTime`, or at `StopTime` when no position is open.

---

## 6. Worked example (`ExitTrade = no`, 35m candles)

| Step | Candle event | Action | Open | Pending SLs |
|---|---|---|---|---|
| 1 | Green by offset | Buy CE#1 + SL | CE | CE SL |
| 2 | Turns red | Buy PE#1 + SL (CE stays open) | CE, PE | CE SL, PE SL |
| 3 | Turns green again | Nothing: CE already open | CE, PE | 2 |
| 4 | CE SL hit | CE booked closed | PE | PE SL |
| 5 | Green again | Buy CE#2 + SL (if entries left on this candle) | CE, PE | 2 |
| 6 | Candle closes | Cancel both SLs, market-sell CE and PE | none | none |
| 7 | Next candle | Repeat from a clean state | | |

---

## 7. Configuration

Values come from [input.json](./input.json); command-line parameters override them.

| Setting | Source | Notes |
|---|---|---|
| `TradingSymbol`, `InstrumentToken` | input.json / param | Instrument whose candles generate signals |
| `TimeFrame` | **param only**, default `35minute` | `TimeFrame` in input.json is **ignored** by this script |
| `IndexChoosen` | input.json / param | NIFTY, BANKNIFTY, FinNifty, MIDCPNIFTY, SENSEX; selects options and lot size |
| `NoOfLotsPurchaseAtaTime`, `AmountToTrade` | input.json / param | `AmountToTrade > 0` overrides lots |
| `Product` (NRML/MIS), `Order_type`, `Variety`, `MarketProtection` | input.json / param | Used for entries, exits and SL |
| `ATMOffset` | input.json / param | Strike shift from ATM |
| `OffsetPoints` | input.json / param | Green/red threshold (default 5) |
| `MaxRetryCountOnBar` | input.json / param | Max entries per candle (default 10) |
| `StartTime`, `StopTime` | input.json / param | Entry window |
| `ForceExitTime` | input.json / param, default 15:20 | Hard close-out time |
| `ExitTrade` | input.json / param | `yes` or `no` (default `yes`) |
| `SLTriggerPercentage` | input.json / param, **no default** | Stop-loss distance in % below the option LTP. Required when `ExitTrade = no`, must be 0.5–50, otherwise the script refuses to start |
| `SLPriceGap` | **param only**, default 2 | Must be >= 1 when `ExitTrade = no` |
| `CleanupPosition` | param, default `auto` | See restart behaviour |

Supported timeframes: `5second`, `15second`, `30second`, `minute`, `2minute`, `3minute`, `4minute`, `5minute`,
`10minute`, `15minute`, `30minute`, `35minute`, `60minute`.

Keys read from input.json (besides `API_Key` / `API_Secret`): `TradingSymbol`, `InstrumentToken`, `IndexChoosen`,
`NoOfLotsPurchaseAtaTime`, `AmountToTrade`, `Product`, `Order_type`, `Variety`, `MarketProtection`, `ATMOffset`,
`OffsetPoints`, `MaxRetryCountOnBar`, `StartTime`, `StopTime`, `ForceExitTime`, `ExitTrade`, `SLTriggerPercentage`,
`CandlesToShow`, `FullMode`.

Example `input.json` entries used by this script (secrets omitted):

```json
{
  "TradingSymbol": "NIFTY",
  "IndexChoosen": "Nifty",
  "NoOfLotsPurchaseAtaTime": 1,
  "AmountToTrade": 0,
  "Product": "NRML",
  "Order_type": "MARKET",
  "MarketProtection": 3,
  "ATMOffset": 1,
  "OffsetPoints": 2,
  "MaxRetryCountOnBar": 6,
  "StartTime": "09:50:00",
  "StopTime": "15:30:00",
  "ForceExitTime": "15:20:00",
  "ExitTrade": "no",
  "SLTriggerPercentage": 3
}
```

Not used by this script: `TimeFrame`, `SLCandlesLookback` and `SLTriggerOffset` (old swing-low stop-loss script, if
present), `ModeOfTrading` (it only ever buys options).

---

## 8. Restart behaviour and state

- Open positions and SL order IDs are written to `PlacedOrders\Position-35Min-V2.json` while positions are open
  (separate from the other bots' `Position.json`) and removed when flat.
- On start, a leftover record is **not resumed**. The script lists it and, with `-CleanupPosition yes` (or when run
  without a terminal, as from the dashboard), clears it and starts fresh. Any old position or SL **stays on Kite
  and must be handled manually**. With `-CleanupPosition no` the script refuses to start.

---

## 9. Things to know

- **A new entry can happen within seconds of a candle boundary.** The new candle's Open is its first tick, so a
  fast move can reach the offset almost immediately (e.g. close at 15:00:00, new entry at 15:00:06).
- **Closing the console or pressing Ctrl+C** stops the bot without closing positions or cancelling SLs.
- **Trade P&L** in the log uses the option LTP fetched just after the order, so it can differ slightly from the
  actual fill prices on Kite.
- **Other bots:** do not run this alongside another bot on the same account and instrument; they do not know about
  each other's positions or SLs.
- **Dashboard:** the web dashboard does not launch this script yet. It currently starts `Regular-Long-Short-30Min.ps1`.

## 10. Verified behaviour

Mock-API checks (SL maths, cancel-before-sell, filled-SL path, failed-cancel path, flat-at-broker path, CE/PE
sequencing in both modes) all passed. Config validation was checked for `SLTriggerPercentage` (missing or out of
range with `ExitTrade = no` stops the script; missing with `ExitTrade = yes` is accepted).

A live 5-minute run with `ExitTrade = no`, 1 lot, on 2026-10-16 produced 8 trades; Kite showed every SL cancelled at
its candle close, no open positions and no pending SLs at the end. That run was made while the stop-loss percentage
was still fixed at 3% in the script; the input.json-driven `SLTriggerPercentage` was added afterwards and has not yet
been exercised with live orders.
