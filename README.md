# Powershell-Kite

PowerShell scripts for **live market data streaming**, **Heikin-Ashi trading strategies**, and **backtesting** using **Zerodha Kite** APIs.

Supports all exchanges: **NSE, BSE, NFO, BFO, MCX, CDS, BCD** — Equities, Futures, Options, Commodities, Currency, Indices.

---

## Project Structure

```
Powershell-kite/
├── KiteData.psm1                          # Core module — all shared functions
├── input.json                             # Central config — all scripts read from here
├── Long-SignalGenerator.ps1               # HA Long signal generator (writes signal files)
├── Short-SignalGenerator.ps1              # HA Short signal generator (writes signal files)
├── CE-BUY.ps1                             # CE option buyer (reads Long signal files)
├── PE-BUY.ps1                             # PE option buyer (reads Short signal files)
├── accesstoken.json                       # Saved Kite access token (auto-generated)
├── README.md
├── Archive/
│   ├── Get-KiteHeikinAshiCandles.ps1      # Live HA candle streaming (WebSocket)
│   ├── Get-KiteLiveCandles.ps1            # Live OHLCV candle streaming (WebSocket)
│   └── Get-NFOOptionChain.ps1             # NFO option chain viewer
├── BACK-Test/
│   ├── Backtest-KiteHALongStrategy.ps1    # Backtest HA Long strategy
│   ├── Backtest-KiteHAShortStrategy.ps1   # Backtest HA Short strategy
│   └── Run-SensexOptionChainBacktest.ps1  # Sensex option chain backtester
├── MCX/
│   ├── Get-MCXInstruments.ps1             # List all MCX commodities with live prices
│   ├── Invoke-KiteHALongStrategy-NatGasMini.ps1   # HA Long strategy for NATGASMINI
│   └── Invoke-KiteHAShortStrategy-NatGasMini.ps1  # HA Short strategy for NATGASMINI
└── PlacedOrders/                          # Signal files + position state (auto-created)
    ├── Long-Entry-*.txt                   # Created by Long-SignalGenerator
    ├── Long-Exit-*.txt                    # Created by Long-SignalGenerator
    ├── Short-Entry-*.txt                  # Created by Short-SignalGenerator
    ├── Short-Exit-*.txt                   # Created by Short-SignalGenerator
    ├── CE-Position.json                   # CE-BUY active position state
    └── PE-Position.json                   # PE-BUY active position state
```

---

## Files

| File | Description |
|---|---|
| `KiteData.psm1` | Core module — preset instruments, auth, WebSocket tick parsing, HA candle building, strategy engines, option helpers |
| `input.json` | **Central configuration file** — all 4 scripts read their parameters from here |
| `Long-SignalGenerator.ps1` | Runs HA Long strategy, writes signal files to `PlacedOrders/` |
| `Short-SignalGenerator.ps1` | Runs HA Short strategy, writes signal files to `PlacedOrders/` |
| `CE-BUY.ps1` | Monitors Long signal files, auto-trades ATM CE options |
| `PE-BUY.ps1` | Monitors Short signal files, auto-trades ATM PE options |
| `BACK-Test/Backtest-KiteHAShortStrategy.ps1` | Backtest HA Short strategy on historical candle data |
| `BACK-Test/Backtest-KiteHALongStrategy.ps1` | Backtest HA Long strategy on historical candle data |
| `MCX/Get-MCXInstruments.ps1` | List all MCX commodity futures with live prices & lot sizes |
| `MCX/Invoke-KiteHALongStrategy-NatGasMini.ps1` | HA Long strategy pre-configured for Natural Gas Mini |
| `MCX/Invoke-KiteHAShortStrategy-NatGasMini.ps1` | HA Short strategy pre-configured for Natural Gas Mini |
| `PlacedOrders/` | Auto-generated signal files and position state |

---

## Setup

### Prerequisites

Requires `api_key` + `api_secret` from [Kite Connect Developer Portal](https://developers.kite.trade/).

### Step 1: Configure `input.json`

Edit `input.json` with your API credentials and desired trading parameters.

### Step 2: Authenticate

```powershell
# Open login URL in browser
.\Long-SignalGenerator.ps1 -GetLoginUrl

# Log in, copy request_token from redirect URL
.\Long-SignalGenerator.ps1 -RequestToken "paste_token_here"

# access_token saved to accesstoken.json (valid ~10 hours)
# All scripts auto-load from accesstoken.json — no manual setup needed
```

### Step 3: Run

Open 4 terminals and start all scripts (see "Running the System" above).

---

## Central Configuration — `input.json`

All 4 scripts (`Long-SignalGenerator.ps1`, `Short-SignalGenerator.ps1`, `CE-BUY.ps1`, `PE-BUY.ps1`) read their parameters from a single `input.json` file. Edit this one file to configure everything.

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

### Which script uses which parameters

| Parameter | Signal Generators | CE-BUY / PE-BUY |
|---|:---:|:---:|
| `API_Key`, `API_Secret` | Yes | Yes |
| `TradingSymbol` | Yes | — |
| `InstrumentToken` | Yes | — |
| `TimeFrame` | Yes | — |
| `CandlesToShow` | Yes | — |
| `FullMode` | Yes | — |
| `IndexChoosen` | — | Yes |
| `NoOfLotsPurchaseAtaTime` | — | Yes |
| `Product` | — | Yes |
| `StartTime`, `StopTime` | — | Yes |
| `Order_type` | — | Yes |
| `ModeOfTrading` | — | Yes |
| `ATMOffset` | — | Yes |
| `Variety` | — | Yes |
| `MarketProtection` | — | Yes |

Command-line parameters always override `input.json` values (e.g., `.\CE-BUY.ps1 -IndexChoosen BANKNIFTY`).

---

## How It Works — Architecture & Signal Flow

The system runs as **4 independent scripts** that communicate through **signal files** in the `PlacedOrders/` folder:

```
┌─────────────────────────┐     Signal Files      ┌─────────────────────────┐
│  Long-SignalGenerator   │ ──── Long-Entry-*.txt ──▶│       CE-BUY.ps1        │
│  (HA Long Strategy)     │ ──── Long-Exit-*.txt  ──▶│  (Buys ATM CE options)  │
└─────────────────────────┘                        └─────────────────────────┘

┌─────────────────────────┐     Signal Files      ┌─────────────────────────┐
│  Short-SignalGenerator  │ ──── Short-Entry-*.txt──▶│       PE-BUY.ps1        │
│  (HA Short Strategy)    │ ──── Short-Exit-*.txt ──▶│  (Buys ATM PE options)  │
└─────────────────────────┘                        └─────────────────────────┘

                All 4 scripts read config from: input.json
```

### Step-by-step flow

1. **Signal Generators** connect to Kite WebSocket, receive live ticks, and build Heikin-Ashi candles in real-time
2. When HA conditions are met, they write a **signal file** (e.g., `Long-Entry-85200-20260508-0930.txt`) to `PlacedOrders/`
3. **CE-BUY / PE-BUY** poll `PlacedOrders/` every 2 seconds looking for their respective signal files
4. On detecting a signal file, they fetch the current spot price, find the ATM option strike, and place a BUY order via Kite API
5. The signal file is **deleted immediately** after processing to prevent duplicate orders
6. Position state is persisted to `CE-Position.json` / `PE-Position.json` so scripts survive restarts

---

## Heikin-Ashi Trading Strategies

### Strategy Logic

Both Long and Short strategies use **Heikin-Ashi candles** for signal generation and execute at **real market price (LTP)**.

**Heikin-Ashi Formula:**
- HA Close = (Open + High + Low + Close) / 4
- HA Open = (Previous HA Open + Previous HA Close) / 2
- HA High = Max(High, HA Open, HA Close)
- HA Low = Min(Low, HA Open, HA Close)

### Long Strategy (`Long-SignalGenerator.ps1`)

| Signal | Condition | Action |
|---|---|---|
| **Long Entry** | Current HA Close > Previous HA High | Writes `Long-Entry-*.txt` to `PlacedOrders/` |
| **Long Exit** | Current HA Close < Previous HA Low | Writes `Long-Exit-*.txt` to `PlacedOrders/` |

Only one Long position at a time.

### Short Strategy (`Short-SignalGenerator.ps1`)

| Signal | Condition | Action |
|---|---|---|
| **Short Entry** | Current HA Close < Previous HA Low | Writes `Short-Entry-*.txt` to `PlacedOrders/` |
| **Short Exit** | Current HA Close > Previous HA High | Writes `Short-Exit-*.txt` to `PlacedOrders/` |

Only one Short position at a time.

### How CE-BUY.ps1 Reads Signals (Long → CE Options)

1. Polls `PlacedOrders/` for `Long-Entry-*.txt` files every 2 seconds
2. On detection:
   - Fetches current spot price via Kite quote API
   - Calculates ATM CE strike from the option chain (offset by `ATMOffset`)
   - Places a **BUY** order for the ATM CE option via `Place-ZerodhaOrder`
   - Deletes all `Long-Entry-*.txt` files to prevent duplicate orders
   - Saves position state to `CE-Position.json`
3. Then polls for `Long-Exit-*.txt` files
4. On detection:
   - Places a **SELL** order for the same CE option it bought
   - Deletes all `Long-Exit-*.txt` files
   - Removes `CE-Position.json`
5. At `StopTime`, force-exits any open position

### How PE-BUY.ps1 Reads Signals (Short → PE Options)

1. Polls `PlacedOrders/` for `Short-Entry-*.txt` files every 2 seconds
2. On detection:
   - Fetches current spot price via Kite quote API
   - Calculates ATM PE strike from the option chain (offset by `ATMOffset`)
   - Places a **BUY** order for the ATM PE option via `Place-ZerodhaOrder`
   - Deletes all `Short-Entry-*.txt` files to prevent duplicate orders
   - Saves position state to `PE-Position.json`
3. Then polls for `Short-Exit-*.txt` files
4. On detection:
   - Places a **SELL** order for the same PE option it bought
   - Deletes all `Short-Exit-*.txt` files
   - Removes `PE-Position.json`
5. At `StopTime`, force-exits any open position

### Signal File Format

Strategy scripts write signal files to `PlacedOrders/` with the naming convention:
```
Long-Entry-{price}-{timestamp}.txt
Long-Exit-{price}-{timestamp}.txt
Short-Entry-{price}-{timestamp}.txt
Short-Exit-{price}-{timestamp}.txt
```

Each file contains: Symbol, LTP, HA Close, Previous HA High/Low, Entry/Exit price, P&L, and timestamp.

---

## Running the System

Open **4 separate terminals** and run all scripts simultaneously:

```powershell
# Terminal 1 — Long signal generator
.\Long-SignalGenerator.ps1

# Terminal 2 — Short signal generator
.\Short-SignalGenerator.ps1

# Terminal 3 — CE option buyer (reads Long signals)
.\CE-BUY.ps1

# Terminal 4 — PE option buyer (reads Short signals)
.\PE-BUY.ps1
```

Or override specific params on the command line:

```powershell
.\Long-SignalGenerator.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
.\CE-BUY.ps1 -IndexChoosen BANKNIFTY -NoOfLotsPurchaseAtaTime 2
```

---

## Backtesting

### Backtest HA Short Strategy (`BACK-Test/Backtest-KiteHAShortStrategy.ps1`)

Fetches historical candle data from Kite API, converts to Heikin-Ashi, and simulates the Short strategy with full trade-by-trade reporting.

```powershell
# Last 5 days, 1-min candles
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol NIFTY -StartDate "-5" -EndDate "0"

# Specific dates
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol BANKNIFTY -StartDate "2026-04-20" -EndDate "2026-04-25"

# Time window filter (9:15 AM to 11:30 AM only)
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol NIFTY -StartDate "0" -EndDate "0" -StartTime "09:15" -EndTime "11:30"

# With 10-point stop loss
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol NIFTY -StartDate "0" -EndDate "0" -StopLoss 10

# Options by instrument token
.\BACK-Test\Backtest-KiteHAShortStrategy.ps1 -TradingSymbol NIFTY26APR24600PE -InstrumentToken 18516482 -StartDate "0" -EndDate "0" -StartTime "09:15" -EndTime "11:30" -StopLoss 10
```

### Backtest Parameters

| Parameter | Default | Description |
|---|---|---|
| `-TradingSymbol` | `NIFTY` | Symbol name (preset or custom) |
| `-InstrumentToken` | | Kite instrument token (for non-preset symbols like options) |
| `-StartDate` | | Start date: `0` = today, `-1` = yesterday, `-7` = 7 days ago, or `yyyy-MM-dd` |
| `-EndDate` | | End date: same format as StartDate |
| `-TimeFrame` | `minute` | Candle interval: `minute`, `3minute`, `5minute`, `10minute`, `15minute`, `30minute`, `60minute` |
| `-StartTime` | `09:15` | Filter candles from this time (HH:mm) |
| `-EndTime` | `15:30` | Filter candles until this time (HH:mm) |
| `-StopLoss` | `10` | Stop loss in points (0 to disable) |

### Backtest Report

The report includes:
- Trade-by-trade list with entry/exit times, prices, P&L, and holding duration
- Stop loss hits marked with `(SL)`
- Summary statistics: Total P&L, Win Rate, Avg Win/Loss, Max Win/Loss, Profit Factor, Max Drawdown, Consecutive Wins/Losses

---

## MCX Commodity Scripts

### List All MCX Instruments (`MCX/Get-MCXInstruments.ps1`)

Fetches all MCX futures (nearest month) with live prices and lot sizes.

```powershell
.\MCX\Get-MCXInstruments.ps1
```

### Natural Gas Mini Strategies

Pre-configured strategy scripts for NATGASMINI (MCX):

```powershell
# Long strategy
.\MCX\Invoke-KiteHALongStrategy-NatGasMini.ps1

# Short strategy
.\MCX\Invoke-KiteHAShortStrategy-NatGasMini.ps1

# Custom timeframe
.\MCX\Invoke-KiteHALongStrategy-NatGasMini.ps1 -TimeFrame 3minute
```

---

## Live Candle Streaming (Archive)

### Regular OHLCV Candles (`Archive/Get-KiteLiveCandles.ps1`)

Connects to `wss://ws.kite.trade`, subscribes to instruments, parses binary tick packets per [Kite WebSocket docs](https://kite.trade/docs/connect/v3/websocket/), and builds live OHLCV candles.

```powershell
.\Archive\Get-KiteLiveCandles.ps1
.\Archive\Get-KiteLiveCandles.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
.\Archive\Get-KiteLiveCandles.ps1 -TradingSymbol SILVERM -TimeFrame 3minute -FullMode
.\Archive\Get-KiteLiveCandles.ps1 -ListSymbols
```

### Heikin-Ashi Candles (`Archive/Get-KiteHeikinAshiCandles.ps1`)

Same as above but builds Heikin-Ashi candles with trend indicator.

```powershell
.\Archive\Get-KiteHeikinAshiCandles.ps1
.\Archive\Get-KiteHeikinAshiCandles.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
.\Archive\Get-KiteHeikinAshiCandles.ps1 -TradingSymbol NATGASMINI -TimeFrame minute
```

### Common Parameters

| Parameter | Default | Description |
|---|---|---|
| `-TradingSymbol` | `NIFTY` | Preset symbol name |
| `-InstrumentToken` | | Override with specific instrument token |
| `-TimeFrame` | `minute` / `5minute` | Candle interval |
| `-CandlesToShow` | `10` | Number of candle rows to display |
| `-FullMode` | off | Full tick mode (184 bytes with OI + depth) |
| `-ListSymbols` | | Show all available preset symbols |
| `-GetLoginUrl` | | Opens Kite login URL in browser |
| `-RequestToken` | | One-time token from Kite login redirect |

---

## KiteData.psm1 — Core Module

All shared functions live here. Imported automatically by all scripts.

```powershell
Import-Module .\KiteData.psm1

# Search instruments
Search-KiteInstrument -Query "BANKNIFTY" -Exchange NFO

# List presets
Show-KiteSymbols
```

### Preset Instruments

**Indices:** NIFTY, SENSEX, BANKNIFTY, FINNIFTY, MIDCPNIFTY

**Equity (NSE):** RELIANCE, TCS, INFY, HDFCBANK, ICICIBANK, SBIN, TATAMOTORS, ITC, WIPRO, BHARTIARTL, KOTAKBANK, LT, HINDUNILVR, AXISBANK, MARUTI, ADANIENT, ADANIPORTS, BAJFINANCE, SUNPHARMA, TITAN

**Commodities (MCX):** SILVERM, GOLDM, CRUDEOIL, NATURALGAS, NATGASMINI

### Exported Functions

| Function | Description |
|---|---|
| `Get-KiteLiveCandles` | WebSocket live OHLCV candle builder |
| `Get-KiteHeikinAshiCandles` | WebSocket live Heikin-Ashi candle builder |
| `Invoke-KiteHALongStrategy` | HA Long strategy engine (writes signal files) |
| `Invoke-KiteHAShortStrategy` | HA Short strategy engine (writes signal files) |
| `Get-IndexOptionConfig` | Returns index-specific config (exchange, lot size, quote key) |
| `Get-KiteOptionInstruments` | Fetches option chain instruments for an exchange |
| `Get-KiteSpotPrice` | Fetches current spot price via Kite quote API |
| `Get-ATMOption` | Finds ATM option strike from option chain |
| `Place-ZerodhaOrder` | Places BUY/SELL orders via Kite order API |
| `Search-KiteInstrument` | Search instruments by name across exchanges |
| `Resolve-KiteSymbol` | Resolve a symbol name to preset data |
| `Show-KiteSymbols` | List all preset symbols |
| `Resolve-KiteAccessToken` | Resolve access token (env > file > login) |
| `Exchange-KiteRequestToken` | Exchange request token for access token |

---

## Setup & Authentication

All scripts use Kite Connect API with `api_key` + `access_token`. Credentials are configured in `input.json`.

```powershell
# Step 1: Open login URL in browser
.\Long-SignalGenerator.ps1 -GetLoginUrl

# Step 2: Log in, copy request_token from redirect URL
.\Long-SignalGenerator.ps1 -RequestToken "paste_token_here"

# Step 3: access_token saved to accesstoken.json (valid ~10 hours)
# All scripts auto-load from accesstoken.json — no manual setup needed
```

If the token expires, any script will prompt for re-login automatically.

---

## API References

- [Kite Connect WebSocket Streaming](https://kite.trade/docs/connect/v3/websocket/)
- [Kite Connect Historical Data](https://kite.trade/docs/connect/v3/historical/)
- [Kite Connect API Docs](https://kite.trade/docs/connect/v3/)
