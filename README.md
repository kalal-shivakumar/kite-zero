# Kite HA Trading Bot

Automated Heikin-Ashi (HA) based options trading bot for Zerodha Kite with a local web dashboard.

## Prerequisites

| Software | Version | Purpose |
|----------|---------|---------|
| **PowerShell 7.2+** (pwsh) | 7.2 or later | Runs the trading strategy script |
| **Node.js** | 22.x or later | Runs the web dashboard server |
| **npm** | Bundled with Node.js | Installs webapp dependencies |
| **Git** | Any recent version | Version control |

### Install Links

- PowerShell 7: https://github.com/PowerShell/PowerShell/releases
- Node.js: https://nodejs.org/

Verify installations:
```powershell
pwsh --version        # Should be 7.2+
node --version        # Should be 22+
git --version
```

## Project Structure

```
Powershell-kite/
├── Long-Short-Combined.ps1    # Main trading strategy (HA Long+Short) — auth, WS loop, $State
├── KiteData.psm1              # PowerShell module (Kite API helpers + HA strategy engine)
├── input.json                 # Trading configuration (symbol, timeframe, lots, etc.)
├── accesstoken.json           # Persisted Kite access token (auto-managed)
├── start-webapp.ps1           # Launcher script for the web dashboard
├── webapp/
│   ├── server.js              # Express server (auth, API proxy, bot management)
│   ├── package.json           # Node.js dependencies
│   └── public/
│       ├── index.html         # Login page
│       └── dashboard.html     # Trading dashboard UI
├── PlacedOrders/              # Active position state (Position.json)
├── BACK-Test/                 # Backtesting scripts
└── Delta-Exchange-India/      # Delta Exchange integration (Python)
```

## Setup

1. **Clone the repository:**
   ```powershell
   git clone https://github.com/kalal-shivakumar/kite-zero.git
   cd kite-zero
   ```

2. **Configure `input.json`:**
   ```json
   {
       "API_Key": "your_kite_api_key",
       "API_Secret": "your_kite_api_secret",
       "TradingSymbol": "Nifty",
       "TimeFrame": "30second",
       "NoOfLotsPurchaseAtaTime": 1,
       "Product": "NRML",
       "StartTime": "09:16:01",
       "StopTime": "15:30:00",
       "ModeOfTrading": "Option_Buyer"
   }
   ```

3. **Start the web dashboard:**
   ```powershell
   .\start-webapp.ps1
   ```
   Opens at **http://localhost:5000**

## Trading Logic

The strategy (`Long-Short-Combined.ps1`) is a **Heikin-Ashi (HA) breakout system** that trades an index direction by **buying ATM options** (LONG view → buy CE, SHORT view → buy PE; both are buy-to-open, sell-to-close). HA candles are built live from the Kite WebSocket tick stream, and signals are evaluated on every tick against the **live/forming** candle for zero-latency entries.

### Entry / Exit Rules

| Signal | Condition | Action |
|--------|-----------|--------|
| **Long Entry** | live HA Close > Previous Candle High | BUY CE (Call Option) |
| **Long Exit** | live HA Close < Previous Candle Low | SELL CE |
| **Short Entry** | live HA Close < Previous Candle Low | BUY PE (Put Option) |
| **Short Exit** | live HA Close > Previous Candle High | SELL PE |

Only **one direction** is active at a time — the position state (`Direction`) is `''`, `LONG`, or `SHORT`. A fresh HA candle breaking beyond the prior candle's range signals momentum; the opposite break closes it.

### Heikin-Ashi Formula

HA smooths raw OHLC to filter noise (`Convert-ToHACandle` in `KiteData.psm1`):

```
HA_Close = (Open + High + Low + Close) / 4
HA_Open  = (prev HA_Open + prev HA_Close) / 2   (raw Open for first candle)
HA_High  = max(High, HA_Open, HA_Close)
HA_Low   = min(Low,  HA_Open, HA_Close)
```

### Execution Flow

1. **Config & auth** — loads `input.json`, applies command-line overrides, validates (and if stale re-fetches) the Kite access token.
2. **Option setup** — resolves the index config (lot size, exchange) and fetches the full CE + PE option chains for the **nearest expiry**.
3. **State object** — builds one `$State` hashtable holding config + mutable position/candle state, then restores any open position from `PlacedOrders/Position.json` (`-CleanupPosition` controls resume vs. fresh start).
4. **WebSocket loop** — connects to `wss://ws.kite.trade`, subscribes to the index token, and processes each binary tick.

### Per-Tick Pipeline (in `KiteData.psm1`)

- `Update-HAStrategyFromTick` — buckets ticks into time-based candles; on bucket rollover it closes the active candle, converts it to HA, and stores it as "previous".
- `Invoke-HAStrategySignalCheck` — computes the **live HA** of the in-progress candle and compares its Close to the **previous completed** candle's High/Low to trigger the rules above.
- `Enter-HAStrategyPosition` — fetches the real **index spot price** (not the tick price, which for options is a premium) to pick the ATM strike, applies `ATMOffset`, optionally sizes lots from `AmountToTrade ÷ (optionLTP × LotSize)`, places a MARKET BUY, and persists the position.
- `Exit-HAStrategyPosition` — cancels pending stop-losses, SELLs the option, computes trade P&L = `(exitLTP − entryLTP) × qty`, adds to `TotalPnL`, and clears state.
- `Invoke-HAStrategyForceExit` — liquidates any open position at `StopTime`.
- `Show-HAStrategyDisplay` — renders the live candle table, position, and P&L to the console (captured by the webapp via stdout).

### Key Behaviours

- Trades only within the `StartTime`–`StopTime` window; force-exits at stop time.
- ATM strike selection with configurable offset (`ATMOffset`).
- Supports both lot-based and amount-based position sizing.
- Auto-reconnect (up to 3 retries with backoff) if the socket drops.
- Position state persisted to `PlacedOrders/Position.json` for crash/restart recovery.

> **Architecture note:** the strategy engine functions live in `KiteData.psm1` and operate on a shared `$State` hashtable (a reference type, so mutations propagate back to the script). `Long-Short-Combined.ps1` builds `$State`, runs the WebSocket loop, and calls `Update-HAStrategyFromTick`, `Show-HAStrategyDisplay`, and `Invoke-HAStrategyForceExit`.

## Web Dashboard

### Login Flow
1. User enters Kite API key + secret on the login page
2. Redirects to Kite for OAuth login → returns a `request_token`
3. Server exchanges `request_token` for `access_token` (SHA-256 checksum)
4. Token is saved to `accesstoken.json` for persistence across restarts
5. On next visit, saved token is validated against Kite profile API — auto-redirects to dashboard if valid

### Dashboard Features
- **Start/Stop Trading** — Spawns/kills `Long-Short-Combined.ps1` as a child process
- **Bot Logs** — Real-time stdout from the PowerShell script (streamed via SSE)
- **Trade Records** — Live order book from Kite API (BUY/SELL paired with P&L), polled every 1 second
- **Strategy Config** — Edit `input.json` values from the UI; locked while trading is active
- **Profile** — Shows authenticated user info from Kite
- **Trade History tab** — Summary stats (win rate, best/worst trade, total P&L)

### API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/profile` | User profile from Kite |
| GET | `/api/orders` | Today's orders from Kite |
| GET | `/api/config` | Read `input.json` config |
| POST | `/api/config` | Save config (blocked while bot is running) |
| POST | `/api/bot/start` | Start trading (spawns PS1 script) |
| POST | `/api/bot/stop` | Stop trading (kills PS1 process tree) |
| GET | `/api/bot/state` | Current bot status and logs |
| GET | `/api/stream` | SSE stream (logs, ticks, trades, status) |
| GET | `/api/token-status` | Check if saved token is still valid |
| POST | `/api/logout` | Clear session |

## Running the Script Standalone

You can also run the trading script directly without the webapp:

```powershell
# Uses input.json for all config
.\Long-Short-Combined.ps1

# Override specific params
.\Long-Short-Combined.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute -NoOfLotsPurchaseAtaTime 2
```

## Configuration Reference (`input.json`)

| Field | Type | Description |
|-------|------|-------------|
| `API_Key` | string | Kite Connect API key |
| `API_Secret` | string | Kite Connect API secret |
| `TradingSymbol` | string | Nifty, BANKNIFTY, FINNIFTY, MIDCPNIFTY, SENSEX |
| `InstrumentToken` | int | 0 = auto-resolve from symbol |
| `TimeFrame` | string | 5second, 15second, 30second, minute, 5minute, etc. |
| `CandlesToShow` | int | Number of candles displayed in terminal |
| `IndexChoosen` | string | Index for option chain lookup |
| `NoOfLotsPurchaseAtaTime` | int | Number of lots per trade |
| `AmountToTrade` | number | 0 = use lots; >0 = calculate lots from amount |
| `Product` | string | NRML or MIS |
| `StartTime` | string | Trading window start (HH:mm:ss) |
| `StopTime` | string | Trading window end (HH:mm:ss) |
| `Order_type` | string | MARKET or LIMIT |
| `ModeOfTrading` | string | Option_Buyer or Option_Seller |
| `ATMOffset` | int | Strike offset from ATM |
| `Variety` | string | regular or amo |
| `MarketProtection` | int | Market protection % for orders |
| `ExitTrade` | string | yes/no — whether to auto-exit positions |
| `SLCandlesLookback` | int | Candles to look back for stop loss |
| `SLTriggerOffset` | number | Offset for SL trigger price |

## Notes

- The webapp runs **locally only** (localhost:5000) — no cloud deployment
- Token expires daily at ~6 AM IST; re-login required each trading day
- The PS1 script uses raw .NET WebSocket for zero-latency tick processing
- All orders go through Zerodha's official Kite Connect API
