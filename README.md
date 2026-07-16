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
├── Long-Short-Combined.ps1        # Main trading strategy (HA Long+Short) — auth, WS loop, $State
├── Liquidity-Sweep-Combined.ps1   # Liquidity-sweep strategy (pivot sweep + reversal)
├── KiteData.psm1                  # PowerShell module (Kite API helpers + HA strategy engine)
├── input.json                     # Main bot config (symbol, timeframe, lots, etc.)
├── Liquidity-sweep-input.json     # Liquidity-sweep bot config (separate to avoid conflicts)
├── accesstoken.json               # Persisted Kite access token (auto-managed)
├── start-webapp.ps1               # Launcher script for the web dashboard
├── webapp/
│   ├── server.js                  # Express server (auth, API proxy, SSE, bot management, JS engine)
│   ├── package.json               # Node.js dependencies
│   ├── data/                      # Persisted trade history (trades-<userId>.json)
│   └── public/
│       ├── index.html             # Login page (AlphaSense AI branded, 3-step OAuth)
│       └── dashboard.html         # Trading dashboard UI (Dashboard / Sweep / Trades tabs)
├── PlacedOrders/                  # Active position state (Position.json)
├── BACK-Test/                     # Backtesting scripts
└── Archive/                       # Older/experimental strategy scripts
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

The `webapp/` folder is a **local, single-process Node.js/Express dashboard** that wraps the trading bots. It handles Kite OAuth login, streams live market data to the browser via Server-Sent Events (SSE), and runs two trading strategies.

### Architecture

```
Browser UI  ──HTTP + SSE──▶  server.js (Express)  ──REST/WebSocket──▶  Kite Connect API
                                     │
                                     ├─ spawn pwsh ─▶ Long-Short-Combined.ps1 / Liquidity-Sweep-Combined.ps1
                                     └─ read/write ─▶ input.json · accesstoken.json · webapp/data/*.json
```

**Tech stack:** `express`, `express-session`, `axios`, `ws` (Kite WebSocket client), `dotenv`. Requires Node ≥ 22.

**Dual execution model** — the server supports two ways to run a strategy:
1. **PowerShell spawn (primary)** — `/api/bot/start` spawns `Long-Short-Combined.ps1` via `pwsh` and pipes its stdout/stderr into the log stream. Tracked in the `activeProcesses` map.
2. **In-process JS engine** — a `TradingBot` class in `server.js` re-implements the HA strategy in JavaScript (binary tick parser, HA candle builder, signal check, order placement). Tracked in the `activeBots` map. Mostly a self-contained alternative engine.

### Login Flow
1. User enters Kite API key + secret on the login page (`index.html`)
2. `/api/login` returns the Kite OAuth URL → opens Kite login → returns a `request_token`
3. User pastes the `request_token` (or full redirect URL); `/api/set-token` (or the `/callback` OAuth route) exchanges it for an `access_token` using a SHA-256 checksum
4. Token is saved to `accesstoken.json` for persistence across restarts
5. On next visit, the saved token is validated against the Kite profile API — auto-redirects to the dashboard if valid

### Dashboard UI (`dashboard.html`)

Three tabs, plus a top market ticker (live NIFTY + SENSEX) and an IST clock / market-status indicator:

- **Dashboard tab** — cumulative P&L banner, Start/Stop controls, live stat cards (direction, symbol, entry, LTP, ticks, total P&L), the full `input.json` config form (locked while running), live logs, and a completed-orders table.
- **Sweep tab** — Liquidity-Sweep bot controls, a sweep-phase panel (pivot level, sweep candle, target, stop-loss, risk:reward), its own config form, and a signal table.
- **Trades tab** — trade summary stats (total, winners, losers, win rate, total P&L, best/worst) and the full persisted trade-history table.

All live updates arrive over SSE (`EventSource`) with event types: `tick`, `candle`, `signal`, `trade`, `log`, `status`.

### Bots

| Bot | Script | Config file | Default TF | Endpoints |
|-----|--------|-------------|-----------|-----------|
| **HA Long/Short** | `Long-Short-Combined.ps1` | `input.json` | 30second | `/api/bot/*` |
| **Liquidity Sweep** | `Liquidity-Sweep-Combined.ps1` | `Liquidity-sweep-input.json` | 5minute | `/api/sweepbot/*` |

### API Endpoints

**Auth & profile**

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/login` | Accept API key/secret → return Kite OAuth login URL |
| POST | `/api/set-token` | Exchange pasted `request_token` for an access token |
| GET | `/callback` | OAuth redirect handler (exchanges `request_token`) |
| GET | `/api/token-status` | Check if the saved token is still valid |
| GET | `/api/defaults` | Pre-fill API key/secret from `input.json` |
| GET | `/api/profile` | Authenticated user profile from Kite |
| GET | `/api/logout` | Clear session and stop any running bot |
| GET | `/api/health` | Server health / active-user count |

**Market & positions**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/market/indices` | Live NIFTY + SENSEX quotes for the ticker |
| GET | `/api/positions` | Portfolio positions from Kite |
| GET | `/api/orders` | Today's orders from Kite |
| GET | `/api/bot/position` | Saved position from `PlacedOrders/Position.json` |
| GET | `/api/bot/liveposition` | Saved position + live option LTP and spot price |

**Config, streaming & bot control**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/config` | Read `input.json` config (secrets stripped) |
| POST | `/api/config` | Save config (blocked while bot is running) |
| GET | `/api/stream` | Per-user SSE stream (logs, ticks, candles, signals, trades, status) |
| POST | `/api/bot/start` | Start HA bot (spawns `Long-Short-Combined.ps1`) |
| POST | `/api/bot/stop` | Stop HA bot (kills PS1 process tree) |
| GET | `/api/bot/state` | Current bot status and recent logs (poll fallback) |
| GET | `/api/bot/trades` | Persisted trade history (`webapp/data/*.json`) |
| POST | `/api/sweepbot/start` | Start Liquidity-Sweep bot (spawns sweep PS1) |
| POST | `/api/sweepbot/stop` | Stop Liquidity-Sweep bot |

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
