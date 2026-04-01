# Powershell-Kite

PowerShell scripts for fetching live and historical market data from **Zerodha Kite** APIs.

Supports all exchanges: **NSE, BSE, NFO, BFO, MCX, CDS, BCD** — Equities, Futures, Options, Commodities, Currency, Indices.

---

## Files

| File | Description |
|---|---|
| `Get-KiteLiveCandles.ps1` | **WebSocket** real-time tick streaming + live 1-min candle builder via Kite Connect API |
| `Get-KiteCandles.ps1` | **REST** historical candle data fetcher (uses browser enctoken) |
| `KiteData.psm1` | Reusable module with preset instruments, search, and candle functions |

---

## Setup

### Option A: WebSocket Live Streaming (Kite Connect API)

Requires `api_key` + `api_secret` from [Kite Connect Developer Portal](https://developers.kite.trade/).

```powershell
# Step 1: Open login URL in browser
.\Get-KiteLiveCandles.ps1 -GetLoginUrl

# Step 2: Log in, copy request_token from redirect URL
.\Get-KiteLiveCandles.ps1 -RequestToken "paste_token_here"

# Step 3: Runs automatically — access_token saved for the session
.\Get-KiteLiveCandles.ps1 -FullMode
```

### Option B: REST Historical Data (Browser enctoken)

No developer account needed — just your Zerodha login.

```powershell
# Get enctoken from browser:
#   1. Log in at https://kite.zerodha.com
#   2. F12 > Application > Cookies > kite.zerodha.com > enctoken
$env:KITE_ENCTOKEN = "paste_enctoken_here"

.\Get-KiteCandles.ps1
```

---

## Get-KiteLiveCandles.ps1 — WebSocket Live Ticks

Connects to `wss://ws.kite.trade`, subscribes to instruments, parses binary tick packets per [Kite WebSocket docs](https://kite.trade/docs/connect/v3/websocket/), and builds live 1-min OHLCV candles that update on every tick.

### Usage

```powershell
# Default: SILVERM26APRFUT in full mode
.\Get-KiteLiveCandles.ps1 -FullMode

# Custom instrument
.\Get-KiteLiveCandles.ps1 -Tokens 256265 -Labels "NIFTY50" -FullMode

# Multiple instruments
.\Get-KiteLiveCandles.ps1 -Tokens 256265,260105 -Labels "NIFTY","BANKNIFTY"

# Show more candles
.\Get-KiteLiveCandles.ps1 -CandlesToShow 20 -FullMode
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-RequestToken` | | One-time token from Kite login redirect |
| `-AccessToken` | `$env:KITE_ACCESS_TOKEN` | Reuse saved access token |
| `-Tokens` | `117128455` | Instrument token(s) to subscribe |
| `-Labels` | `SILVERM26APRFUT` | Display label(s) for instruments |
| `-CandlesToShow` | `10` | Number of candle rows to display |
| `-FullMode` | off | Full tick mode (184 bytes with OI + depth) vs quote (44 bytes) |
| `-GetLoginUrl` | | Opens Kite login URL in browser |

### WebSocket Tick Modes

| Mode | Packet Size | Fields |
|---|---|---|
| `ltp` | 8 bytes | Token, LTP |
| `quote` | 44 bytes | Token, LTP, LTQ, Avg, Volume, BuyQty, SellQty, OHLC |
| `full` | 184 bytes | All quote fields + Timestamp, OI, Market Depth |

### Output

```
  ================================================
  SILVERM26APRFUT - Live 1-Min Candles (WebSocket)
  ================================================
  Token   : 117128455
  Ticks   : 3
  Candles : 1 total | Showing 1
  Time    : 2026-03-31 23:45:43
  LTP     : 2,44,490.00  |  Day O/H/L/C: 2,38,001.00/2,44,564.00/2,38,001.00/2,43,733.00

 Time                Open           High            Low          Close   Volume     OI  Ticks
 --------------------------------------------------------------------------------------------
 2026-03-31 23:45    2,44,490.00    2,44,490.00    2,44,490.00  2,44,490.00    0  13,484    3
```

---

## Get-KiteCandles.ps1 — REST Historical Candles

Fetches historical candle data via Kite's REST API. Supports all intervals and any instrument.

### Usage

```powershell
# Default: SILVERM26APRFUT 1-min candles
.\Get-KiteCandles.ps1

# Preset instruments
.\Get-KiteCandles.ps1 -Preset NIFTY
.\Get-KiteCandles.ps1 -Preset RELIANCE -Interval 5minute -CandleCount 20

# Custom instrument by token
.\Get-KiteCandles.ps1 -InstrumentToken 260105 -TradingSymbol "NIFTY BANK" -Exchange NSE

# Search instruments
.\Get-KiteCandles.ps1 -Search "BANKNIFTY"

# List all presets
.\Get-KiteCandles.ps1 -ListPresets
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Preset` | | Use a preset instrument (NIFTY, SENSEX, RELIANCE, etc.) |
| `-InstrumentToken` | `117128455` | Kite instrument token |
| `-TradingSymbol` | `SILVERM26APRFUT` | Trading symbol |
| `-Exchange` | `MCX` | Exchange: NSE, BSE, NFO, BFO, MCX, CDS, BCD |
| `-Interval` | `minute` | Candle interval (see table below) |
| `-CandleCount` | `10` | Number of candles to show |
| `-Search` | | Search for instruments by name |
| `-ListPresets` | | Show all available preset instruments |
| `-Continuous` | | Keep polling and refreshing data |

### Intervals

| Value | Candle Size |
|---|---|
| `minute` | 1 minute |
| `3minute` | 3 minutes |
| `5minute` | 5 minutes |
| `10minute` | 10 minutes |
| `15minute` | 15 minutes |
| `30minute` | 30 minutes |
| `60minute` | 1 hour |
| `day` | 1 day |

---

## KiteData.psm1 — Reusable Module

Import the module to use functions directly in your scripts:

```powershell
Import-Module .\KiteData.psm1

# Fetch candles with preset
Get-KiteCandles -Preset NIFTY -Interval 5minute -CandleCount 20

# Search instruments
Search-KiteInstrument -Query "BANKNIFTY" -Exchange NFO

# List presets
Show-KitePresets
```

### Preset Instruments

**Indices:** NIFTY, SENSEX, BANKNIFTY, FINNIFTY, MIDCPNIFTY

**Equity (NSE):** RELIANCE, TCS, INFY, HDFCBANK, ICICIBANK, SBIN, TATAMOTORS, ITC, WIPRO, BHARTIARTL, KOTAKBANK, LT, HINDUNILVR, AXISBANK, MARUTI

**Commodities (MCX):** SILVERM26APRFUT, GOLDM26APRFUT, CRUDEOIL26APRFUT, NATURALGAS26APRFUT

---

## Authentication

| Method | Used By | How to Get |
|---|---|---|
| **enctoken** | `Get-KiteCandles.ps1` | Browser: F12 > Application > Cookies > kite.zerodha.com |
| **access_token** | `Get-KiteLiveCandles.ps1` | Kite Connect OAuth login flow (api_key + api_secret) |

### Getting enctoken (REST mode)

1. Log in at https://kite.zerodha.com
2. Press F12 > Application > Cookies > `kite.zerodha.com`
3. Copy the `enctoken` value
4. `$env:KITE_ENCTOKEN = "paste_here"`

### Getting access_token (WebSocket mode)

1. `.\Get-KiteLiveCandles.ps1 -GetLoginUrl` (opens browser)
2. Log in with Zerodha credentials
3. Copy `request_token` from the redirect URL
4. `.\Get-KiteLiveCandles.ps1 -RequestToken "paste_here"`
5. Token saved to `$env:KITE_ACCESS_TOKEN` for the session

---

## API References

- [Kite Connect WebSocket Streaming](https://kite.trade/docs/connect/v3/websocket/)
- [Kite Connect Historical Data](https://kite.trade/docs/connect/v3/historical/)
- [Kite Connect API Docs](https://kite.trade/docs/connect/v3/)
