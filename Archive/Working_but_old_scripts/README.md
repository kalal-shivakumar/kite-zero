# Kite-Zero

Automated options trading system built with PowerShell using Zerodha Kite Connect APIs. Streams real-time market data via WebSocket, generates Heikin-Ashi trading signals, and executes ATM option orders automatically.

Supports: **NSE, BSE, NFO, BFO, MCX, CDS, BCD** — Indices, Equities, Futures, Options, Commodities, Currency.

---

## Quick Start

```powershell
# 1. Configure credentials in input.json
# 2. Authenticate
.\Long-SignalGenerator.ps1 -GetLoginUrl
.\Long-SignalGenerator.ps1 -RequestToken "paste_token_here"

# 3. Run all 4 scripts in separate terminals
.\Long-SignalGenerator.ps1      # Terminal 1 — generates Long signals
.\Short-SignalGenerator.ps1     # Terminal 2 — generates Short signals
.\CE-BUY.ps1                    # Terminal 3 — buys CE on Long signals
.\PE-BUY.ps1                    # Terminal 4 — buys PE on Short signals
```

---

## Architecture

```
┌─────────────────────────────┐                     ┌─────────────────────────┐
│   Long-SignalGenerator.ps1  │                     │       CE-BUY.ps1        │
│   (WebSocket → HA Candles)  │──Long-Entry-*.txt──▶│  (Buys ATM CE options)  │
│                             │──Long-Exit-*.txt───▶│  (Sells CE on exit)     │
└─────────────────────────────┘                     └─────────────────────────┘

┌─────────────────────────────┐                     ┌─────────────────────────┐
│   Short-SignalGenerator.ps1 │                     │       PE-BUY.ps1        │
│   (WebSocket → HA Candles)  │──Short-Entry-*.txt─▶│  (Buys ATM PE options)  │
│                             │──Short-Exit-*.txt──▶│  (Sells PE on exit)     │
└─────────────────────────────┘                     └─────────────────────────┘

         WebSocket ticks              PlacedOrders/              Kite Order API
        (binary stream)              (signal files)             (REST POST)
```

**Flow:** WebSocket tick → Build OHLC candle → Convert to Heikin-Ashi → Check signal condition → Write signal file → Option buyer detects file → Place order → Delete file

---

## WebSocket Data Pipeline

### Connection & Subscription

```
wss://ws.kite.trade?api_key=<key>&access_token=<token>
```

```json
{"a": "subscribe", "v": [265]}
{"a": "mode", "v": ["quote", [265]]}
```

Uses .NET `System.Net.WebSockets.ClientWebSocket` — zero external dependencies.

### Binary Tick Parsing

Kite sends big-endian binary packets. Each packet:

```
[2 bytes: tick count] [2 bytes: payload size] [N bytes: payload] [repeat...]
```

| Payload Size | Data |
|---|---|
| 8 bytes | Token + LTP |
| 44 bytes | + Volume + Day OHLC |
| 184 bytes | + OI + Market Depth (5 levels) |

Prices = integer / 100 (e.g., `8250050` = `82500.50`)

### Candle Building (Seconds-Based Time Bucketing)

Ticks are grouped into time buckets by `TimeFrame`. The bucketing uses **seconds-level precision**:

```
Total seconds of day = Hour×3600 + Minute×60 + Second
Bucket = Floor(TotalSeconds / IntervalSeconds) × IntervalSeconds
```

This enables candles as small as **15 seconds** from live tick data.

### Supported TimeFrames

| TimeFrame | Interval | Live (WebSocket) | Backtest (Historical API) |
|---|---|:---:|:---:|
| `15second` | 15 sec | Yes | No |
| `30second` | 30 sec | Yes | No |
| `minute` | 1 min | Yes | Yes |
| `3minute` | 3 min | Yes | Yes |
| `5minute` | 5 min | Yes | Yes |
| `10minute` | 10 min | Yes | Yes |
| `15minute` | 15 min | Yes | Yes |
| `30minute` | 30 min | Yes | Yes |
| `60minute` | 1 hour | Yes | Yes |

> Sub-minute candles (`15second`, `30second`) work only with live WebSocket data. Kite's historical API does not provide sub-minute granularity.

### Reconnection

- Connection timeout: 15s
- Receive timeout: 30s
- Max retries: 3 (backoff: 5s → 10s → 15s)
- Tick rate: ~1/sec for liquid instruments

---

## Heikin-Ashi Strategy Logic

**HA Formula:**
- Close = (O + H + L + C) / 4
- Open = (Prev HA Open + Prev HA Close) / 2
- High = Max(H, HA Open, HA Close)
- Low = Min(L, HA Open, HA Close)

### Long Strategy

| Signal | Condition | Output |
|---|---|---|
| Entry | HA Close > Previous HA High | `Long-Entry-*.txt` |
| Exit | HA Close < Previous HA Low | `Long-Exit-*.txt` |

### Short Strategy

| Signal | Condition | Output |
|---|---|---|
| Entry | HA Close < Previous HA Low | `Short-Entry-*.txt` |
| Exit | HA Close > Previous HA High | `Short-Exit-*.txt` |

One position at a time per strategy. Signals are checked on every tick.

---

## Option Execution (CE-BUY / PE-BUY)

1. Polls `PlacedOrders/` every 2 seconds for signal files
2. On entry signal: fetches spot price → finds ATM strike → places BUY order
3. On exit signal: places SELL order for the same option
4. Deletes signal files immediately to prevent duplicates
5. Persists position state to JSON (survives script restarts)
6. Force-exits at `StopTime` if position is still open

---

## Configuration — `input.json`

Single config file for all 4 scripts:

```json
{
    "API_Key":                  "your_api_key",
    "API_Secret":               "your_api_secret",
    "TradingSymbol":            "SENSEX",
    "InstrumentToken":          0,
    "TimeFrame":                "3minute",
    "CandlesToShow":            10,
    "FullMode":                 false,
    "IndexChoosen":             "SENSEX",
    "NoOfLotsPurchaseAtaTime":  5,
    "Product":                  "NRML",
    "StartTime":                "09:17:01",
    "StopTime":                 "21:00:00",
    "Order_type":               "MARKET",
    "ModeOfTrading":            "Option_Buyer",
    "ATMOffset":                1,
    "Variety":                  "regular",
    "MarketProtection":         3
}
```

| Parameter | Used By | Description |
|---|---|---|
| `API_Key`, `API_Secret` | All | Kite Connect credentials |
| `TradingSymbol` | Signal Generators | Instrument to stream (SENSEX, NIFTY, BANKNIFTY, etc.) |
| `TimeFrame` | Signal Generators | Candle interval (15second to 60minute) |
| `IndexChoosen` | CE-BUY, PE-BUY | Index for option chain lookup |
| `NoOfLotsPurchaseAtaTime` | CE-BUY, PE-BUY | Number of lots per trade |
| `Product` | CE-BUY, PE-BUY | NRML or MIS |
| `StartTime`, `StopTime` | CE-BUY, PE-BUY | Trading window |
| `ATMOffset` | CE-BUY, PE-BUY | Strike offset from ATM (0 = exact ATM) |
| `MarketProtection` | CE-BUY, PE-BUY | Max % slippage for market orders |

Command-line params override `input.json` (e.g., `.\CE-BUY.ps1 -IndexChoosen BANKNIFTY`).

---

## Project Structure

```
├── KiteData.psm1                    # Core module (all shared functions)
├── input.json                       # Central configuration
├── Long-SignalGenerator.ps1         # HA Long strategy → signal files
├── Short-SignalGenerator.ps1        # HA Short strategy → signal files
├── CE-BUY.ps1                       # Reads Long signals → buys CE options
├── PE-BUY.ps1                       # Reads Short signals → buys PE options
├── accesstoken.json                 # Auto-generated auth token
├── Archive/
│   ├── Get-KiteLiveCandles.ps1      # Standalone live OHLCV candle viewer
│   ├── Get-KiteHeikinAshiCandles.ps1 # Standalone live HA candle viewer
│   └── Get-NFOOptionChain.ps1       # NFO option chain viewer
├── BACK-Test/
│   ├── Backtest-KiteHALongStrategy.ps1   # HA Long backtest
│   ├── Backtest-KiteHAShortStrategy.ps1  # HA Short backtest
│   └── Run-SensexOptionChainBacktest.ps1 # Sensex option chain backtest
└── PlacedOrders/                    # Signal files + position state
    ├── CE-Position.json             # Active CE position
    └── PE-Position.json             # Active PE position
```

---

## Backtesting

```powershell
# Today's data, 1-min candles
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol NIFTY -StartDate "0" -EndDate "0"

# Last 5 days
.\BACK-Test\Backtest-KiteHALongStrategy.ps1 -TradingSymbol SENSEX -StartDate "-5" -EndDate "0"

# Specific date range with time filter
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol BANKNIFTY -StartDate "2026-04-20" -EndDate "2026-04-25" -StartTime "09:15" -EndTime "11:30"

# Custom stop loss
.\BACK-Test\Backtest-KiteHALongStrategy.ps1 -TradingSymbol NIFTY -StartDate "0" -EndDate "0" -StopLoss 30
```

**Note:** Backtesting only supports `minute` and above (Kite historical API limitation). Sub-minute intervals (`15second`, `30second`) are for live trading only.

Report includes: trade list, entry/exit times, P&L per trade, win rate, profit factor, max drawdown, consecutive wins/losses.

---

## KiteData.psm1 — Module Functions

| Function | Description |
|---|---|
| `Invoke-KiteHALongStrategy` | HA Long strategy engine with WebSocket streaming |
| `Invoke-KiteHAShortStrategy` | HA Short strategy engine with WebSocket streaming |
| `Get-KiteLiveCandles` | Live OHLCV candle builder (WebSocket) |
| `Get-KiteHeikinAshiCandles` | Live HA candle builder (WebSocket) |
| `Place-ZerodhaOrder` | Places BUY/SELL orders with market protection |
| `Get-IndexOptionConfig` | Index-specific config (exchange, lot size, quote key) |
| `Get-KiteOptionInstruments` | Fetches option chain for an exchange |
| `Get-KiteSpotPrice` | Current spot price via quote API |
| `Get-ATMOption` | Finds ATM strike from option chain |
| `Search-KiteInstrument` | Search instruments by name across exchanges |
| `Resolve-KiteAccessToken` | Token resolution (env → file → interactive login) |
| `Exchange-KiteRequestToken` | OAuth token exchange |

### Preset Instruments

**Indices:** NIFTY, SENSEX, BANKNIFTY, FINNIFTY, MIDCPNIFTY

**Equity:** RELIANCE, TCS, INFY, HDFCBANK, ICICIBANK, SBIN, TATAMOTORS, ITC, WIPRO, BHARTIARTL, KOTAKBANK, LT, HINDUNILVR, AXISBANK, MARUTI, ADANIENT, ADANIPORTS, BAJFINANCE, SUNPHARMA, TITAN

**Commodities (MCX):** SILVERM, GOLDM, CRUDEOIL, NATURALGAS, NATGASMINI

---

## Authentication

```powershell
# Open Kite login in browser
.\Long-SignalGenerator.ps1 -GetLoginUrl

# After login, paste the request_token from redirect URL
.\Long-SignalGenerator.ps1 -RequestToken "your_request_token"

# Token saved to accesstoken.json (valid ~10 hours)
# All scripts auto-load — no manual setup after first login
```

Token expires after ~10 hours. Scripts auto-detect expiry and prompt for re-login.

---

## API References

- [Kite Connect WebSocket](https://kite.trade/docs/connect/v3/websocket/)
- [Kite Connect Historical Data](https://kite.trade/docs/connect/v3/historical/)
- [Kite Connect API](https://kite.trade/docs/connect/v3/)
