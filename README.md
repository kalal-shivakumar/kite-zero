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
├── Long-Short-Combined.ps1    # Main trading strategy (HA Long+Short)
├── KiteData.psm1              # PowerShell module (Kite API helpers)
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

The strategy (`Long-Short-Combined.ps1`) uses **Heikin-Ashi candles** computed from live Kite WebSocket ticks:

| Signal | Condition | Action |
|--------|-----------|--------|
| **Long Entry** | HA Close > Previous Candle High | BUY CE (Call Option) |
| **Long Exit** | HA Close < Previous Candle Low | SELL CE |
| **Short Entry** | HA Close < Previous Candle Low | BUY PE (Put Option) |
| **Short Exit** | HA Close > Previous Candle High | SELL PE |

- Only **one direction** is active at a time (Long OR Short, never both)
- ATM strike selection with configurable offset
- Supports both lot-based and amount-based position sizing
- Auto force-exit at configured stop time
- Position state persisted to `PlacedOrders/Position.json` for crash recovery

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
