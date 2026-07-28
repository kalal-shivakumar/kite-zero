<#
.SYNOPSIS
  Heikin Ashi (HA) Trend-Based Pyramiding Option Trading Bot with CE+PE Auto-Trade (zero-latency).
  Backtest logic from Backtest-Pyramid-With-Trend-HeikinAshi.ps1

.DESCRIPTION
  Streams live Heikin Ashi candles via Zerodha Kite WebSocket. Trades both directions with PYRAMIDING
  support (multiple concurrent lots), automatically switching directions on trend reversals.

  TREND DETECTION (Using Heikin Ashi Close vs Previous HA High/Low):
  ├─ INITIAL STATE (NONE):
  │  ├─ If HA_Close > Previous HA_High  → Switch to UPTREND
  │  └─ If HA_Close < Previous HA_Low   → Switch to DOWNTREND
  ├─ IN UPTREND:
  │  ├─ Remains UPTREND while HA_Close > Previous HA_Low
  │  └─ If HA_Close < Previous HA_Low   → Switch to DOWNTREND
  └─ IN DOWNTREND:
     ├─ Remains DOWNTREND while HA_Close < Previous HA_High
     └─ If HA_Close > Previous HA_High  → Switch to UPTREND

  LONG ENTRY SIGNALS (CE - Call Option):
  ├─ FIRST TRADE: Trend = UPTREND AND PreviousSwingLow = Null
  ├─ PYRAMIDING: Trend = UPTREND AND Current SwingLow > Previous SwingLow (HIGHER LOWS)
  ├─ Entry Price: Current Heikin Ashi Close
  └─ Stoploss: Current Heikin Ashi Low (SwingLow)

  SHORT ENTRY SIGNALS (PE - Put Option):
  ├─ FIRST TRADE: Trend = DOWNTREND AND PreviousSwingHigh = Null
  ├─ PYRAMIDING: Trend = DOWNTREND AND Current SwingHigh < Previous SwingHigh (LOWER HIGHS)
  ├─ Entry Price: Previous Heikin Ashi Low
  └─ Stoploss: Current Heikin Ashi High (SwingHigh)

  EXIT CONDITIONS:
  ├─ EXIT 1 - STOPLOSS HIT (Individual Lot):
  │  ├─ LONG: If HA_Low ≤ Lot_SL → Close LONG lot at lastPrice
  │  └─ SHORT: If HA_High ≥ Lot_SL → Close SHORT lot at lastPrice
  └─ EXIT 2 - OPPOSITE SIGNAL (All Opposite Lots):
     ├─ LONG Signal → Close ALL active SHORT lots at lastPrice
     └─ SHORT Signal → Close ALL active LONG lots at lastPrice

  FEATURES:
  - Zero-latency real-time tick streaming via WebSocket
  - Trend-based entry signals with swing level detection
  - Pyramiding support (multiple concurrent lots per direction)
  - Individual Stoploss tracking per lot
  - Opposite signal closes all opposite direction lots
  - Per-lot P&L tracking + Cumulative P&L
  - Automatic ATM option strike selection with configurable offset
  - Respects trading window (no new entries after StopTime, but holds existing positions)
  - Real-time display: Trend, SwingLow, SwingHigh, Signal, Active Lots, P&L
  - Supports configurable timeframes (5 seconds to 60 minutes)

.EXAMPLE
  .\Paper-Trading-2nd-Swing.ps1
  .\Paper-Trading-2nd-Swing.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute -NoOfLotsPurchaseAtaTime 1
  .\Paper-Trading-2nd-Swing.ps1 -TradingSymbol NIFTY -TimeFrame minute -Product MIS -ModeOfTrading Option_Buyer
  
.NOTES
  Strategy: Trend Detection + Swing Levels + Pyramiding
  Logic Source: Backtest-Pyramid-With-Trend-HeikinAshi.ps1 (tested and verified)
  Status: Production Ready with Paper Trading (simulated orders)
#>

param(
    [string]$TradingSymbol,
    [int]$InstrumentToken,
    [ValidateSet('5second','15second','30second','minute','2minute','3minute','4minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame,
    [int]$CandlesToShow,
    [switch]$FullMode,
    [switch]$ListSymbols,
    [switch]$GetLoginUrl,
    [string]$RequestToken,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret,
    [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
    [string]$IndexChoosen,
    [int]$NoOfLotsPurchaseAtaTime,
    [double]$AmountToTrade,
    [ValidateSet('NRML','MIS')]
    [string]$Product,
    [datetime]$StartTime,
    [datetime]$StopTime,
    [string]$Order_type,
    [ValidateSet('Option_Buyer','Option_Seller')]
    [string]$ModeOfTrading,
    [int]$ATMOffset,
    [string]$Variety,
    [int]$MarketProtection,
    [ValidateSet('yes','no')]
    [string]$ExitTrade,
    [ValidateSet('yes','no','auto')]
    [string]$CleanupPosition = 'auto'
)

# ================================================================
# Module & Config
# ================================================================
$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force -warningaction SilentlyContinue

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) { Write-Host '  ERROR: input.json not found.' -ForegroundColor Red; exit 1 }
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

# Load params from input.json; command-line overrides take priority
if (-not $PSBoundParameters.ContainsKey('TradingSymbol'))  { $TradingSymbol  = $cfg.TradingSymbol }
if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
if (-not $PSBoundParameters.ContainsKey('TimeFrame'))      { $TimeFrame      = $cfg.TimeFrame }
if (-not $PSBoundParameters.ContainsKey('CandlesToShow'))  { $CandlesToShow  = [int]$cfg.CandlesToShow }
if (-not $PSBoundParameters.ContainsKey('FullMode') -and $cfg.FullMode) { $FullMode = [switch]$true }
if (-not $PSBoundParameters.ContainsKey('API_Key'))        { $API_Key        = $cfg.API_Key }
if (-not $PSBoundParameters.ContainsKey('API_Secret'))     { $API_Secret     = $cfg.API_Secret }
if (-not $PSBoundParameters.ContainsKey('IndexChoosen')) {
    $rawIdx = $cfg.IndexChoosen
    $idxMap = @{ 'NIFTY'='NIFTY'; 'BANKNIFTY'='BANKNIFTY'; 'FINNIFTY'='FinNifty'; 'MIDCPNIFTY'='MIDCPNIFTY'; 'SENSEX'='SENSEX' }
    $IndexChoosen = if ($idxMap.ContainsKey($rawIdx.ToUpper())) { $idxMap[$rawIdx.ToUpper()] } else { $rawIdx }
}
if (-not $PSBoundParameters.ContainsKey('NoOfLotsPurchaseAtaTime')) { $NoOfLotsPurchaseAtaTime = [int]$cfg.NoOfLotsPurchaseAtaTime }
if (-not $PSBoundParameters.ContainsKey('AmountToTrade'))           { $AmountToTrade = if ($cfg.AmountToTrade) { [double]$cfg.AmountToTrade } else { 0 } }
if (-not $PSBoundParameters.ContainsKey('Product'))                 { $Product       = $cfg.Product }
if (-not $PSBoundParameters.ContainsKey('StartTime'))               { $StartTime     = [datetime]$cfg.StartTime }
if (-not $PSBoundParameters.ContainsKey('StopTime'))                { $StopTime      = [datetime]$cfg.StopTime }
if (-not $PSBoundParameters.ContainsKey('Order_type'))              { $Order_type    = $cfg.Order_type }
if (-not $PSBoundParameters.ContainsKey('ModeOfTrading'))           { $ModeOfTrading = $cfg.ModeOfTrading }
if (-not $PSBoundParameters.ContainsKey('ATMOffset'))               { $ATMOffset     = [int]$cfg.ATMOffset }
if (-not $PSBoundParameters.ContainsKey('Variety'))                 { $Variety       = if ($cfg.Variety) { $cfg.Variety } else { 'regular' } }
if (-not $PSBoundParameters.ContainsKey('MarketProtection'))        { $MarketProtection = if ($cfg.MarketProtection) { [int]$cfg.MarketProtection } else { 3 } }
if (-not $PSBoundParameters.ContainsKey('ExitTrade'))               { $ExitTrade     = if ($cfg.ExitTrade) { $cfg.ExitTrade } else { 'yes' } }
Write-Host "  Loaded config from input.json" -ForegroundColor DarkGray

# ================================================================
# Auth
# ================================================================
if (-not $API_Key -or -not $API_Secret) { Write-Host '  ERROR: API_Key/API_Secret not found.' -ForegroundColor Red; exit 1 }
if ($GetLoginUrl) { Start-Process "https://kite.zerodha.com/connect/login?api_key=$API_Key"; exit 0 }
if ($ListSymbols) { Show-KiteSymbols; exit 0 }

$tokenFile = Join-Path $scriptDir 'accesstoken.json'
if (-not $AccessToken) {
    if ($RequestToken) {
        $AccessToken = Exchange-KiteRequestToken -ApiKey $API_Key -ApiSecret $API_Secret -ReqToken $RequestToken -TokenFilePath $tokenFile
    } else {
        $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    }
    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
}

$headers = @{ 'X-Kite-Version'='3'; 'Authorization'="token ${API_Key}:${AccessToken}" }

# Validate token
$tokenValid = $false
try {
    $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
    if ($profile.data.user_id) { $tokenValid = $true; Write-Host "  Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green }
} catch { Write-Host "  Token validation failed: $($_.Exception.Message)" -ForegroundColor Yellow }

if (-not $tokenValid) {
    Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
    try {
        $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
        Write-Host "  Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    } catch { Write-Host '  ERROR: Token failed.' -ForegroundColor Red; exit 1 }
}

# ================================================================
# Resolve symbol
# ================================================================
$sym = $TradingSymbol.ToUpper().Trim()
if ($InstrumentToken -gt 0) { $instToken = $InstrumentToken; $label = $sym }
else {
    $preset = Resolve-KiteSymbol $sym
    if ($preset) { $instToken = $preset.Token; $label = $preset.Label }
    else { Write-Host "  Unknown symbol: $TradingSymbol" -ForegroundColor Red; exit 1 }
}
$intSec   = Get-IntervalSeconds $TimeFrame
$intLabel = Get-IntervalLabel $intSec

# ================================================================
# Option setup (both CE and PE)
# ================================================================
$IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots $NoOfLotsPurchaseAtaTime
if (-not $IndexConfig) { exit 1 }

$exchange       = $IndexConfig.exchange
$optExchange    = $IndexConfig.OptExchange
$LotSize        = $IndexConfig.Lot
$underlyingName = $IndexConfig.SearchKeyWord
$Quantity       = $IndexConfig.Quantity

Write-Host "  Fetching $optExchange CE+PE instruments..." -ForegroundColor Yellow

$ceData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'CE' -Headers $headers
$peData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'PE' -Headers $headers
if (-not $ceData -or -not $peData) { exit 1 }

$ceOptions  = $ceData.Options; $ceStrikes = $ceData.Strikes
$peOptions  = $peData.Options; $peStrikes = $peData.Strikes
$nearestExpiry = $ceData.Expiry

Write-Host "  Expiry: $nearestExpiry | CE: $($ceStrikes.Count) strikes | PE: $($peStrikes.Count) strikes | Lot: $LotSize" -ForegroundColor Green

$PlacedOrdersDir = Join-Path $scriptDir 'PlacedOrders'
if (-not (Test-Path $PlacedOrdersDir)) { New-Item -ItemType Directory -Path $PlacedOrdersDir -Force | Out-Null }

# ================================================================
# Strategy state (shared $State object passed to module functions)
# ================================================================
$PositionFile = Join-Path $PlacedOrdersDir 'Position.json'

$State = @{
    # --- Config (immutable during run) ---
    headers                 = $headers
    IndexConfig             = $IndexConfig
    ceOptions               = $ceOptions
    ceStrikes               = $ceStrikes
    peOptions               = $peOptions
    peStrikes               = $peStrikes
    exchange                = $exchange
    optExchange             = $optExchange
    LotSize                 = $LotSize
    Quantity                = $Quantity
    NoOfLotsPurchaseAtaTime = $NoOfLotsPurchaseAtaTime
    AmountToTrade           = $AmountToTrade
    ATMOffset               = $ATMOffset
    Variety                 = $Variety
    Order_type              = $Order_type
    Product                 = $Product
    MarketProtection        = $MarketProtection
    ExitTrade               = $ExitTrade
    StartTime               = $StartTime
    StopTime                = $StopTime
    PositionFile            = $PositionFile
    IntervalSeconds         = $intSec
    DisplayConfig           = @{ SymbolName=$sym; SymbolLabel=$label; InstrumentToken=$instToken; TimeFrame=$TimeFrame; IntervalLabel=$intLabel; MaxCandles=$CandlesToShow }
    DisplayIntervalMs       = 100
    # --- Candle/runtime state ---
    STR_CompletedCandles    = @{}
    STR_ActiveCandle        = @{}
    STR_PreviousHA          = @{}
    STR_TickCount           = 0
    LastDisplayTime         = [datetime]::MinValue
    CanClearHost            = $null
    StrategySignals         = [System.Collections.Generic.List[string]]::new()
    TotalPnL                = 0
    # --- TREND STATE (from backtest logic) ---
    Trend                   = 'NONE'  # 'NONE' | 'Uptrend' | 'Downtrend'
    SwingLow                = 0.0
    SwingHigh               = 0.0
    PreviousSwingLow        = 0.0
    PreviousSwingHigh       = 0.0
    HasCompletedUptrend     = $false
    HasCompletedDowntrend   = $false
    # --- ENTRY LEVEL TRACKING (prevent endless lot entries on same signal) ---
    LastEntrySwingLow       = 0.0      # Track last LONG entry swing level - only enter new LONG if SwingLow > this
    LastEntrySwingHigh      = 0.0      # Track last SHORT entry swing level - only enter new SHORT if SwingHigh < this
    # --- LOT-BASED PYRAMIDING (from backtest logic) ---
    ActiveLots              = [System.Collections.Generic.List[PSCustomObject]]::new()   # [{type, entry, SL, optSymbol, optToken, optStrike, optLTP, qty, lots}]
    CumulativePnL           = 0.0
}

# Restore position
if (Test-Path $PositionFile) {
    $saved = Get-Content $PositionFile -Raw | ConvertFrom-Json
    Write-Host "`n  Existing position: $($saved.Direction) | $($saved.Symbol) | Strike: $($saved.Strike) | Qty: $($saved.Qty) @ $($saved.Time)" -ForegroundColor Yellow
    if ($CleanupPosition -eq 'auto') {
        $isNonInteractive = try { [Console]::IsInputRedirected } catch { $true }
        if ($isNonInteractive) {
            $cleanup = 'n'
            Write-Host "  Non-interactive mode: resuming position." -ForegroundColor DarkGray
        } else {
            $cleanup = Read-Host "  Cleanup old entry and start fresh? (y/n)"
        }
    } else {
        $cleanup = $CleanupPosition
    }
    if ($cleanup -eq 'y' -or $cleanup -eq 'yes') {
        Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared." -ForegroundColor Green
    } else {
        $State.Direction   = $saved.Direction
        $State.EntryPrice  = $saved.Price
        $State.EntryTime   = $saved.Time
        $State.OptSymbol   = $saved.Symbol
        $State.OptToken    = $saved.Token
        $State.OptStrike   = $saved.Strike
        $State.OptEntryLTP = if ($saved.OptionLTP) { $saved.OptionLTP } else { 0 }
        $State.OptQty      = if ($saved.Qty) { [int]$saved.Qty } else { $Quantity }
        $State.OptLots     = if ($saved.Lots) { [int]$saved.Lots } else { $NoOfLotsPurchaseAtaTime }
        $State.OptType     = $saved.OptType
        $State.TotalPnL    = if ($saved.TotalPnL) { $saved.TotalPnL } else { 0 }
        Write-Host "  Resuming: $($State.Direction) | $($State.OptSymbol) | Qty: $($State.OptQty)" -ForegroundColor Yellow
    }
}

# ================================================================
# INLINE TRADING FUNCTIONS (copied from KiteData.psm1 for testing)
# ================================================================

function Get-HAStrategyTimeBucket {
    param([int]$IntervalSeconds)
    $now = [datetime]::Now
    $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
    $bucket = [int]([Math]::Floor($totalSeconds / $IntervalSeconds)) * $IntervalSeconds
    $bH = [int]($bucket / 3600); $bM = [int](($bucket % 3600) / 60); $bS = $bucket % 60
    return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
}

function Convert-ToHACandle {
    param([hashtable]$rawCandle, [hashtable]$previousHA)
    $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
    $haOpen = if ($null -ne $previousHA) { ($previousHA.Open + $previousHA.Close) / 2.0 } else { ($rawCandle.Open + $rawCandle.Close) / 2.0 }
    $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
    $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
    return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
}

function Enter-HAStrategyPosition {
    param([hashtable]$State, [string]$dir, [double]$spotPrice, [string]$timeStamp, [double]$entry, [double]$stoploss)
    $optType = if ($dir -eq 'Long') { 'CE' } else { 'PE' }
    $options = if ($dir -eq 'Long') { $State.ceOptions } else { $State.peOptions }
    $strikes = if ($dir -eq 'Long') { $State.ceStrikes } else { $State.peStrikes }
    $offset  = if ($dir -eq 'Long') { -$State.ATMOffset } else { $State.ATMOffset }
    $tag     = "$optType-ENTRY"

    # Fetch index spot price for ATM selection
    $idxSpot = Get-KiteSpotPrice -SpotQuoteKey $State.IndexConfig.SpotQuoteKey -Headers $State.headers
    if ($idxSpot -le 0) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] Could not fetch index spot price. Using tick price." -ForegroundColor Yellow
        $idxSpot = $spotPrice
    }

    $atmOption = Get-ATMOption -SpotPrice $idxSpot -Options $options -AllStrikes $strikes -Offset $offset
    if (-not $atmOption) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] Could not find ATM $optType option." -ForegroundColor Red
        return $false
    }

    $entryQty = $State.Quantity; $entryLots = $State.NoOfLotsPurchaseAtaTime; $optLTP = 0
    try {
        $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("$($State.optExchange):$($atmOption.Symbol)"))" -Headers $State.headers -ErrorAction Stop
        foreach ($p in $qr.data.PSObject.Properties) { $optLTP = $p.Value.last_price; break }
    } catch {}

    if ($State.AmountToTrade -gt 0 -and $optLTP -gt 0) {
        $entryLots = [int][Math]::Floor($State.AmountToTrade / ($optLTP * $State.LotSize))
        if ($entryLots -lt 1) { $entryLots = 1 }
        $entryQty = $entryLots * $State.LotSize
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $optType LTP: $optLTP | Amount: $($State.AmountToTrade) | Lots: $entryLots | Qty: $entryQty" -ForegroundColor Magenta
    }

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $optType BUY | Strike: $($atmOption.Strike) | Symbol: $($atmOption.Symbol) | Qty: $entryQty" -ForegroundColor Cyan
    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] PAPER TRADING: Order NOT placed (simulated)" -ForegroundColor Yellow
    $now = Get-Date
    $result = $true  # Place-ZerodhaOrder simulation

    if ($result) {
        # Store lot data for tracking (for pyramiding)
        $State.LastOptSymbol = $atmOption.Symbol
        $State.LastOptToken = $atmOption.Token
        $State.LastOptStrike = $atmOption.Strike
        $State.LastOptLTP = $optLTP
        $State.LastOptQty = $entryQty
        $State.LastOptLots = $entryLots

        $latency = ((Get-Date) - $now).TotalMilliseconds
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] LOT OPENED in ${latency}ms | $dir $($atmOption.Symbol) | Strike: $($atmOption.Strike) | Entry: $entry | SL: $stoploss | Qty: $entryQty | LTP: $optLTP" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $optType BUY FAILED" -ForegroundColor Red
        return $false
    }
}

function Exit-HAStrategyPosition {
    param([hashtable]$State, [double]$lastPrice, [string]$timeStamp)
    if ($State.ExitTrade -eq 'no') {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] EXIT DISABLED - position stays open" -ForegroundColor DarkYellow
        return
    }
    
    # This function is kept for compatibility but exit logic is now in Invoke-HAStrategySignalCheck
    # which handles lot-based closing
}

function Invoke-HAStrategySignalCheck {
    param([hashtable]$State, [int]$instrumentToken, [double]$lastPrice)
    $completedList = $State.STR_CompletedCandles[$instrumentToken]
    if (-not $completedList -or $completedList.Count -lt 1) { return }

    $prev = $completedList[$completedList.Count - 1]
    $currentRaw = $State.STR_ActiveCandle[$instrumentToken]
    if ($null -eq $currentRaw) { return }

    $liveHA = Convert-ToHACandle $currentRaw ($State.STR_PreviousHA[$instrumentToken])

    $now = [datetime]::Now
    $withinWindow = ($now.TimeOfDay -ge $State.StartTime.TimeOfDay -and $now.TimeOfDay -le $State.StopTime.TimeOfDay)
    $timeStamp = $now.ToString('yyyy-MM-dd_HH-mm-ss')

    # ================================================================
    # TREND DETECTION (from Backtest-Pyramid-With-Trend-HeikinAshi.ps1)
    # ================================================================
    if ($State.Trend -eq 'NONE') {
        if ($liveHA.Close -gt $prev.High) {
            $State.Trend = 'Uptrend'
            $State.SwingLow = $liveHA.Low
        } elseif ($liveHA.Close -lt $prev.Low) {
            $State.Trend = 'Downtrend'
            $State.SwingHigh = $liveHA.High
        }
    } elseif ($State.Trend -eq 'Uptrend') {
        if ($liveHA.Close -lt $prev.Low) {
            $State.Trend = 'Downtrend'
            if ($State.HasCompletedDowntrend) {
                $State.PreviousSwingHigh = $State.SwingHigh
            }
            $State.SwingHigh = $liveHA.High
            $State.HasCompletedUptrend = $true
        }
    } elseif ($State.Trend -eq 'Downtrend') {
        if ($liveHA.Close -gt $prev.High) {
            $State.Trend = 'Uptrend'
            if ($State.HasCompletedUptrend) {
                $State.PreviousSwingLow = $State.SwingLow
            }
            $State.SwingLow = $liveHA.Low
            $State.HasCompletedDowntrend = $true
        }
    }

    # ================================================================
    # SIGNAL GENERATION based on TREND + SWING LEVELS
    # Only generate signal if entry level has changed (new pyramiding opportunity)
    # ================================================================
    $signal = ''

    # LONG: Uptrend + (First trade with Null prevSwingLow OR pyramiding with Higher Lows) + SwingLow > LastEntrySwingLow
    if ($State.Trend -eq 'Uptrend') {
        if ($State.PreviousSwingLow -eq 0 -or $State.SwingLow -gt $State.PreviousSwingLow) {
            # Only enter if we haven't entered at this level yet
            if ($State.LastEntrySwingLow -eq 0 -or $State.SwingLow -gt $State.LastEntrySwingLow) {
                $signal = 'Long'
            }
        }
    }
    # SHORT: Downtrend + (First trade with Null prevSwingHigh OR pyramiding with Lower Highs) + SwingHigh < LastEntrySwingHigh
    elseif ($State.Trend -eq 'Downtrend') {
        if ($State.PreviousSwingHigh -eq 0 -or $State.SwingHigh -lt $State.PreviousSwingHigh) {
            # Only enter if we haven't entered at this level yet
            if ($State.LastEntrySwingHigh -eq 0 -or $State.SwingHigh -lt $State.LastEntrySwingHigh) {
                $signal = 'Short'
            }
        }
    }

    # ================================================================
    # SL CHECKS & OPPOSITE SIGNAL CLOSES
    # ================================================================
    $justClosedPnL = 0
    $closureReason = ''

    # First: Check SL triggers on active lots
    $remainingLots = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($lot in $State.ActiveLots) {
        $slHit = $false
        if ($lot.type -eq 'Long' -and $liveHA.Low -le $lot.SL) {
            $slHit = $true
            $closureReason = 'SL_HIT'
        } elseif ($lot.type -eq 'Short' -and $liveHA.High -ge $lot.SL) {
            $slHit = $true
            $closureReason = 'SL_HIT'
        }

        if ($slHit) {
            # Calculate P&L and close
            $lotPnL = if ($lot.type -eq 'Long') { 
                [Math]::Round($lastPrice - $lot.entry, 2) 
            } else { 
                [Math]::Round($lot.entry - $lastPrice, 2) 
            }
            $justClosedPnL += $lotPnL
            $State.CumulativePnL += $lotPnL
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $($lot.type.ToUpper()) LOT CLOSED @ $lastPrice | SL HIT @ $($lot.SL) | P&L: $($lotPnL.ToString('N2')) | Cumulative: $($State.CumulativePnL.ToString('N2'))" -ForegroundColor Magenta
        } else {
            $remainingLots.Add($lot)
        }
    }
    $State.ActiveLots = $remainingLots

    # Second: Check if opposite signal closes all active lots of opposite type
    if ($signal -ne '' -and $withinWindow) {
        if ($signal -eq 'Long') {
            $lotsToClose = @($State.ActiveLots | Where-Object { $_.type -eq 'Short' })
            foreach ($lot in $lotsToClose) {
                $lotPnL = [Math]::Round($lot.entry - $lastPrice, 2)
                $justClosedPnL += $lotPnL
                $State.CumulativePnL += $lotPnL
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] SHORT LOT CLOSED ON LONG SIGNAL @ $lastPrice | P&L: $($lotPnL.ToString('N2')) | Cumulative: $($State.CumulativePnL.ToString('N2'))" -ForegroundColor Green
            }
            $State.ActiveLots = [System.Collections.Generic.List[PSCustomObject]]@($State.ActiveLots | Where-Object { $_.type -ne 'Short' })
        } elseif ($signal -eq 'Short') {
            $lotsToClose = @($State.ActiveLots | Where-Object { $_.type -eq 'Long' })
            foreach ($lot in $lotsToClose) {
                $lotPnL = [Math]::Round($lastPrice - $lot.entry, 2)
                $justClosedPnL += $lotPnL
                $State.CumulativePnL += $lotPnL
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] LONG LOT CLOSED ON SHORT SIGNAL @ $lastPrice | P&L: $($lotPnL.ToString('N2')) | Cumulative: $($State.CumulativePnL.ToString('N2'))" -ForegroundColor Green
            }
            $State.ActiveLots = [System.Collections.Generic.List[PSCustomObject]]@($State.ActiveLots | Where-Object { $_.type -ne 'Long' })
        }
    }

    # ================================================================
    # NEW LOT ENTRY on signal (pyramiding)
    # ================================================================
    if ($signal -ne '' -and $withinWindow) {
        $entry = 0
        $optType = ''

        if ($signal -eq 'Long') {
            $entry = [Math]::Round($liveHA.Close, 2)
            $stoploss = [Math]::Round($liveHA.Low, 2)
            $optType = 'CE'
            Write-Host "`n  [$(Get-Date -Format 'HH:mm:ss.fff')] *** LONG ENTRY SIGNAL *** Trend: Uptrend | SwingLow: $($State.SwingLow.ToString('N2')) | Entry: $entry | SL: $stoploss" -ForegroundColor Yellow
        } else {
            $entry = [Math]::Round($prev.Low, 2)  # Previous HA Low for SHORT
            $stoploss = [Math]::Round($liveHA.High, 2)
            $optType = 'PE'
            Write-Host "`n  [$(Get-Date -Format 'HH:mm:ss.fff')] *** SHORT ENTRY SIGNAL *** Trend: Downtrend | SwingHigh: $($State.SwingHigh.ToString('N2')) | Entry: $entry | SL: $stoploss" -ForegroundColor Yellow
        }

        # ENTER new position
        $ok = Enter-HAStrategyPosition $State $signal $lastPrice $timeStamp $entry $stoploss
        if ($ok) {
            # Add to active lots
            $newLot = [PSCustomObject]@{
                type = $signal
                entry = $entry
                SL = $stoploss
                optSymbol = $State.LastOptSymbol
                optToken = $State.LastOptToken
                optStrike = $State.LastOptStrike
                optLTP = $State.LastOptLTP
                qty = $State.LastOptQty
                lots = $State.LastOptLots
            }
            $State.ActiveLots.Add($newLot)
            
            # CRITICAL: Track entry level to prevent endless entries on same signal
            if ($signal -eq 'Long') {
                $State.LastEntrySwingLow = $State.SwingLow
            } elseif ($signal -eq 'Short') {
                $State.LastEntrySwingHigh = $State.SwingHigh
            }
            
            Write-Host "  Lot added | Active: $($State.ActiveLots.Count) total | LastEntryLevel: Long=$($State.LastEntrySwingLow.ToString('N2')) Short=$($State.LastEntrySwingHigh.ToString('N2'))" -ForegroundColor Cyan
        }
    }
}

function Update-HAStrategyFromTick {
    param([hashtable]$State, [int]$instrumentToken, [double]$lastPrice, [int]$volume, [double]$dayOpen, [double]$dayHigh, [double]$dayLow, [double]$dayClose, [int]$openInterest)
    $State.STR_TickCount++
    $timeBucket = Get-HAStrategyTimeBucket $State.IntervalSeconds

    if (-not $State.STR_CompletedCandles.ContainsKey($instrumentToken)) {
        $State.STR_CompletedCandles[$instrumentToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    $currentCandle = $State.STR_ActiveCandle[$instrumentToken]

    if (($null -eq $currentCandle) -or ($currentCandle.TimeBucket -ne $timeBucket)) {
        if ($null -ne $currentCandle) {
            $prevHA = $State.STR_PreviousHA[$instrumentToken]
            $ha = Convert-ToHACandle $currentCandle $prevHA
            $State.STR_PreviousHA[$instrumentToken] = @{ Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close }
            $State.STR_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
            })
        }
        $State.STR_ActiveCandle[$instrumentToken] = @{
            TimeBucket=$timeBucket; Open=$lastPrice; High=$lastPrice; Low=$lastPrice; Close=$lastPrice
            Volume=0; PreviousVolume=$volume; OpenInterest=$openInterest; TicksInCandle=1
            DayOpen=$dayOpen; DayHigh=$dayHigh; DayLow=$dayLow; DayClose=$dayClose
        }
    } else {
        $currentCandle.High  = [Math]::Max($currentCandle.High, $lastPrice)
        $currentCandle.Low   = [Math]::Min($currentCandle.Low, $lastPrice)
        $currentCandle.Close = $lastPrice
        $currentCandle.OpenInterest = $openInterest
        $currentCandle.TicksInCandle++
        if ($dayHigh -gt 0)  { $currentCandle.DayHigh  = $dayHigh }
        if ($dayLow -gt 0)   { $currentCandle.DayLow   = $dayLow }
        if ($dayOpen -gt 0)  { $currentCandle.DayOpen   = $dayOpen }
        if ($dayClose -gt 0) { $currentCandle.DayClose  = $dayClose }
        if (($volume -gt $currentCandle.PreviousVolume) -and ($currentCandle.PreviousVolume -gt 0)) {
            $currentCandle.Volume += ($volume - $currentCandle.PreviousVolume)
        }
        $currentCandle.PreviousVolume = $volume
    }

    Invoke-HAStrategySignalCheck $State $instrumentToken $lastPrice
}

function Show-HAStrategyDisplay {
    param([hashtable]$State, [int]$instrumentToken)
    $now = [datetime]::Now
    if (($now - $State.LastDisplayTime).TotalMilliseconds -lt $State.DisplayIntervalMs) { return }
    $State.LastDisplayTime = $now

    $config = $State.DisplayConfig
    $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
    $closedCandles = $State.STR_CompletedCandles[$instrumentToken]
    if ($closedCandles -and $closedCandles.Count -gt 0) { $allCandles.AddRange($closedCandles) }

    $currentCandle = $State.STR_ActiveCandle[$instrumentToken]
    $currentHA = $null
    if ($null -ne $currentCandle) {
        $currentHA = Convert-ToHACandle $currentCandle ($State.STR_PreviousHA[$instrumentToken])
        $allCandles.Add([PSCustomObject]@{
            TimeBucket=$currentCandle.TimeBucket
            Open=[Math]::Round($currentHA.Open, 2); High=[Math]::Round($currentHA.High, 2)
            Low=[Math]::Round($currentHA.Low, 2); Close=[Math]::Round($currentHA.Close, 2)
            Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest; TicksInCandle=$currentCandle.TicksInCandle
        })
    }
    if ($allCandles.Count -eq 0) { return }

    $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
    $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

    if ($null -eq $State.CanClearHost) { $State.CanClearHost = try { Clear-Host; $true } catch { $false } }
    elseif ($State.CanClearHost) { try { Clear-Host } catch {} }

    $sb = [System.Text.StringBuilder]::new(4000)
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("┌──────────────────────────────────────────────────────────────────────────────────────┐")
    $null = $sb.AppendLine("│  📊 PAPER TRADING - HA TREND PYRAMIDING STRATEGY                                    │")
    $null = $sb.AppendLine("└──────────────────────────────────────────────────────────────────────────────────────┘")
    $null = $sb.AppendLine("  $($config.SymbolName) | $($config.TimeFrame) | $(Get-Date -Format 'HH:mm:ss.fff') | Ticks: $($State.STR_TickCount)")
    
    # === TREND STATE - PROMINENT DISPLAY ===
    $trendEmoji = switch ($State.Trend) {
        'Uptrend' { '📈' }
        'Downtrend' { '📉' }
        default { '⏳' }
    }
    $trendStatus = $State.Trend.ToUpper().PadRight(12)
    
    $displaySwingLow = if ($State.SwingLow -gt 0) { "$($State.SwingLow.ToString('N2'))" } else { '---' }
    $displaySwingHigh = if ($State.SwingHigh -gt 0) { "$($State.SwingHigh.ToString('N2'))" } else { '---' }
    $displayPrevSwingLow = if ($State.PreviousSwingLow -gt 0) { "$($State.PreviousSwingLow.ToString('N2'))" } else { '---' }
    $displayPrevSwingHigh = if ($State.PreviousSwingHigh -gt 0) { "$($State.PreviousSwingHigh.ToString('N2'))" } else { '---' }
    
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("╔════════════════════════════════════════════════════════════════════════════════════╗")
    $null = $sb.AppendLine("║                        🔄 CURRENT TREND & SWING LEVELS                             ║")
    $null = $sb.AppendLine("╚════════════════════════════════════════════════════════════════════════════════════╝")
    $null = $sb.AppendLine("  TREND: $trendEmoji $trendStatus")
    $null = $sb.AppendLine("  ├─ Current SwingLow:  $($displaySwingLow.PadLeft(10))   │   Previous SwingLow: $($displayPrevSwingLow.PadLeft(10))")
    $null = $sb.AppendLine("  └─ Current SwingHigh: $($displaySwingHigh.PadLeft(10))   │   Previous SwingHigh: $($displayPrevSwingHigh.PadLeft(10))")
    
    # === SIGNAL ANALYSIS - VERY PROMINENT (matching Invoke-HAStrategySignalCheck logic) ===
    $signalStatus = '-'
    $signalDetail = ''
    $signalEmoji = '⏳'
    
    if ($State.Trend -eq 'Uptrend') {
        if ($State.PreviousSwingLow -eq 0 -or $State.SwingLow -gt $State.PreviousSwingLow) {
            # Check if entry level tracking allows new entry
            if ($State.LastEntrySwingLow -eq 0 -or $State.SwingLow -gt $State.LastEntrySwingLow) {
                if ($State.PreviousSwingLow -eq 0) {
                    $signalStatus = 'LONG (First Entry)'
                    $signalDetail = "🟢 ENTRY SIGNAL ACTIVE - New Uptrend Detected"
                } else {
                    $signalStatus = 'LONG (Pyramiding)'
                    $signalDetail = "🟢 ENTRY SIGNAL ACTIVE - Higher Lows: $displaySwingLow > $displayPrevSwingLow"
                }
                $signalEmoji = '🟢'
            } else {
                $signalStatus = 'WAITING'
                $signalDetail = "⏳ In Uptrend - Entry level locked at $($State.LastEntrySwingLow.ToString('N2')). Need SwingLow > this level"
                $signalEmoji = '⏳'
            }
        } else {
            $signalStatus = 'WAITING'
            $signalDetail = "⏳ In Uptrend - No new entry yet (SL: $displaySwingLow ≤ Prev: $displayPrevSwingLow)"
            $signalEmoji = '⏳'
        }
    } elseif ($State.Trend -eq 'Downtrend') {
        if ($State.PreviousSwingHigh -eq 0 -or $State.SwingHigh -lt $State.PreviousSwingHigh) {
            # Check if entry level tracking allows new entry
            if ($State.LastEntrySwingHigh -eq 0 -or $State.SwingHigh -lt $State.LastEntrySwingHigh) {
                if ($State.PreviousSwingHigh -eq 0) {
                    $signalStatus = 'SHORT (First Entry)'
                    $signalDetail = "🔴 ENTRY SIGNAL ACTIVE - New Downtrend Detected"
                } else {
                    $signalStatus = 'SHORT (Pyramiding)'
                    $signalDetail = "🔴 ENTRY SIGNAL ACTIVE - Lower Highs: $displaySwingHigh < $displayPrevSwingHigh"
                }
                $signalEmoji = '🔴'
            } else {
                $signalStatus = 'WAITING'
                $signalDetail = "⏳ In Downtrend - Entry level locked at $($State.LastEntrySwingHigh.ToString('N2')). Need SwingHigh < this level"
                $signalEmoji = '⏳'
            }
        } else {
            $signalStatus = 'WAITING'
            $signalDetail = "⏳ In Downtrend - No new entry yet (SH: $displaySwingHigh ≥ Prev: $displayPrevSwingHigh)"
            $signalEmoji = '⏳'
        }
    } else {
        $signalStatus = 'NO TREND'
        $signalDetail = "⏳ Waiting for first breakout (HA Close > Prev High OR < Prev Low)"
        $signalEmoji = '⏳'
    }
    
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("╔════════════════════════════════════════════════════════════════════════════════════╗")
    $null = $sb.AppendLine("║                          🎯 ENTRY SIGNAL STATUS                                   ║")
    $null = $sb.AppendLine("╚════════════════════════════════════════════════════════════════════════════════════╝")
    $null = $sb.AppendLine("  Signal: $signalEmoji $signalStatus")
    $null = $sb.AppendLine("  $signalDetail")
    
    # === ACTIVE POSITIONS - CLEAR SUMMARY ===
    $currentPrice = if ($null -ne $currentHA) { $currentHA.Close } else { 0 }
    
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("╔════════════════════════════════════════════════════════════════════════════════════╗")
    $null = $sb.AppendLine("║                     💰 ACTIVE POSITIONS & P&L ($($State.ActiveLots.Count) Lot(s))                    ║")
    $null = $sb.AppendLine("╚════════════════════════════════════════════════════════════════════════════════════╝")
    
    if ($State.ActiveLots.Count -gt 0) {
        # Calculate statistics
        $profitable = 0
        $lossmaking = 0
        $totalPnL = 0
        $maxProfit = -999999
        $maxLoss = 999999
        
        foreach ($lot in $State.ActiveLots) {
            $lotPnL = if ($lot.type -eq 'Long') { $currentPrice - $lot.entry } else { $lot.entry - $currentPrice }
            if ($lotPnL -ge 0) { $profitable++ } else { $lossmaking++ }
            $totalPnL += $lotPnL
            if ($lotPnL -gt $maxProfit) { $maxProfit = $lotPnL }
            if ($lotPnL -lt $maxLoss) { $maxLoss = $lotPnL }
        }
        $avgPnL = $totalPnL / $State.ActiveLots.Count
        $profitPct = [Math]::Round(($profitable / $State.ActiveLots.Count) * 100, 1)
        $lossPct = [Math]::Round(($lossmaking / $State.ActiveLots.Count) * 100, 1)
        
        $totalActivePnLStr = if ($totalPnL -ge 0) { "✓ +$($totalPnL.ToString('N2'))" } else { "✗ $($totalPnL.ToString('N2'))" }
        $avgPnLStr = if ($avgPnL -ge 0) { "✓ +$($avgPnL.ToString('N2'))" } else { "✗ $($avgPnL.ToString('N2'))" }
        $maxProfitStr = "✓ +$($maxProfit.ToString('N2'))"
        $maxLossStr = "✗ $($maxLoss.ToString('N2'))"
        
        $null = $sb.AppendLine("  Active Lots: $($State.ActiveLots.Count) │ Profitable: $profitable ($profitPct%) │ Loss-Making: $lossmaking ($lossPct%)")
        $null = $sb.AppendLine("  ├─ Total Active P&L:  $totalActivePnLStr")
        $null = $sb.AppendLine("  ├─ Average P&L/Lot:   $avgPnLStr")
        $null = $sb.AppendLine("  ├─ Max Profit (1 lot): $maxProfitStr")
        $null = $sb.AppendLine("  ├─ Max Loss (1 lot):   $maxLossStr")
        $cumulativePnLFormatted = if ($State.CumulativePnL -ge 0) { "✓ +$($State.CumulativePnL.ToString('N2'))" } else { "✗ $($State.CumulativePnL.ToString('N2'))" }
        $null = $sb.AppendLine("  └─ Cumulative P&L:    $cumulativePnLFormatted (from closed positions)")
    } else {
        $null = $sb.AppendLine("  🟣 NO ACTIVE POSITIONS")
        $null = $sb.AppendLine("  └─ Waiting for entry signal...")
    }
    
    # === CANDLE DATA ===
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("╔════════════════════════════════════════════════════════════════════════════════════╗")
    $null = $sb.AppendLine("║                    📈 HEIKIN-ASHI CANDLES (Last $($visibleCandles.Count) Candles)                      ║")
    $null = $sb.AppendLine("╚════════════════════════════════════════════════════════════════════════════════════╝")
    $null = $sb.AppendLine("  Time              │ Open      High       Low      Close  │ Ticks")
    $null = $sb.AppendLine("  ──────────────────┼──────────────────────────────────────┼────────")
    
    Write-Host $sb.ToString()

    # Display candles with colors
    for ($i = 0; $i -lt $visibleCandles.Count; $i++) {
        $c = $visibleCandles[$i]
        $color = if ($c.Close -ge $c.Open) { 'Green' } else { 'Red' }
        $marker = if ($i -eq $visibleCandles.Count - 1) { '← LIVE' } else { '' }
        $timeStr = "$($c.TimeBucket) $marker".PadRight(19)
        $line = "  $timeStr│ $($c.Open.ToString('N2').PadLeft(8)) $($c.High.ToString('N2').PadLeft(8)) $($c.Low.ToString('N2').PadLeft(8)) $($c.Close.ToString('N2').PadLeft(8))  │ $($c.TicksInCandle.ToString().PadLeft(5))"
        Write-Host $line -ForegroundColor $(if ($i -eq $visibleCandles.Count - 1) { 'Yellow' } else { $color })
    }
    
    $null = $sb2 = [System.Text.StringBuilder]::new(1000)
    $null = $sb2.AppendLine("")
    $null = $sb2.AppendLine("  ═══════════════════════════════════════════════════════════════════════════════════")
    $null = $sb2.AppendLine("  Status: $(if ($State.ActiveLots.Count -gt 0) { "IN TRADE - $($State.ActiveLots.Count) lot(s) active" } else { "FLAT - Ready for entry" }) │ Window: $($State.StartTime.ToString('HH:mm:ss'))-$($State.StopTime.ToString('HH:mm:ss'))")
    $null = $sb2.AppendLine("  🔴 Press Ctrl+C to stop │ 📊 Refreshing every 100ms")
    Write-Host $sb2.ToString()
    
    # === RECENT EVENTS LOG ===
    if ($State.StrategySignals.Count -gt 0) {
        Write-Host "  ┌──────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "  │                         📋 RECENT EVENTS & SIGNAL LOG                               │" -ForegroundColor Cyan
        Write-Host "  └──────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
        $show = [Math]::Min(5, $State.StrategySignals.Count)
        for ($si = $State.StrategySignals.Count - $show; $si -lt $State.StrategySignals.Count; $si++) {
            $sig = $State.StrategySignals[$si]
            $eventColor = if ($sig -match 'LONG|Entry') { 'Green' } elseif ($sig -match 'SHORT|Exit') { 'Red' } else { 'DarkGray' }
            Write-Host "  ► $sig" -ForegroundColor $eventColor
        }
        Write-Host ""
    }
}

function Invoke-HAStrategyForceExit {
    param([hashtable]$State)
    if ($State.Direction -ne '' -and $State.OptSymbol) {
        $now = Get-Date
        Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME - Force exiting: $($State.OptSymbol)" -ForegroundColor Red
        $forceQty = if ($State.OptQty -gt 0) { $State.OptQty } else { $State.Quantity }
        Write-Host "  PAPER TRADING: Force exit order NOT placed (simulated)" -ForegroundColor Yellow
        # Place-ZerodhaOrder -CommonHeader $State.headers -Type "SELL" -Variety $State.Variety `
            # -Tradingsymbol $State.OptSymbol -Quantity $forceQty `
            # -OrderType $State.Order_type -Product $State.Product -Exchange $State.exchange -Tag "$($State.OptType)-TIMEEXIT" -MarketProtection $State.MarketProtection
        $State.Direction = ''; $State.OptSymbol = ''
    }
}
$wsUri = "wss://ws.kite.trade?api_key=$API_Key&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  COMBINED: HA Long+Short | CE+PE Auto-Trade (Zero Latency)' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym) | Token: $instToken"
Write-Host "  TimeFrame: $TimeFrame ($intLabel) | Expiry: $nearestExpiry"
if ($AmountToTrade -gt 0) { Write-Host "  Trade    : Amount: $AmountToTrade | LotSize: $LotSize" }
else { Write-Host "  Trade    : Lots: $NoOfLotsPurchaseAtaTime | Qty: $Quantity" }
Write-Host "  Product  : $Product | Order: $Order_type | Mode: $modeStr"
Write-Host "  Window   : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss'))"
Write-Host '  Connecting...' -ForegroundColor Yellow

$maxRetries = 3; $retryCount = 0; $buf = New-Object byte[] 65536

while ($retryCount -le $maxRetries) {
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader('X-Kite-Version', '3')
    $cts = [System.Threading.CancellationTokenSource]::new()

    try {
        $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
        if (-not $ct.Wait(15000)) {
            Write-Host '  Connection timed out.' -ForegroundColor Red
            $retryCount++
            if ($retryCount -le $maxRetries) { $w = $retryCount * 5; Write-Host "  Retry in ${w}s..." -ForegroundColor Yellow; Start-Sleep $w; continue }
            Invoke-HAStrategyForceExit $State; exit 1
        }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host "  Connection failed." -ForegroundColor Red; Invoke-HAStrategyForceExit $State; exit 1
        }

        $retryCount = 0
        Write-Host '  Connected!' -ForegroundColor Green

        $subB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"subscribe","v":[' + $instToken + ']}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($subB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)

        $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["' + $modeStr + '",[' + $instToken + ']]}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        Write-Host "  Subscribed ($modeStr). Waiting for ticks..." -ForegroundColor Green

        $seg = [System.ArraySegment[byte]]::new($buf)
        $stopTOD = $StopTime.TimeOfDay
        $lastStopCheck = [datetime]::MinValue
        $stopNoticeShown = $false

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $now = [datetime]::Now
            if (($now - $lastStopCheck).TotalSeconds -ge 1) {
                $lastStopCheck = $now
                if ($now.TimeOfDay -gt $stopTOD) {
                    if ($State.Direction -eq '') {
                        Write-Host "  Stop time reached - no open position. Stopping." -ForegroundColor Yellow; break
                    } elseif (-not $stopNoticeShown) {
                        $stopNoticeShown = $true
                        Write-Host "  Stop time reached - new entries disabled. Holding open $($State.Direction) position until its exit signal." -ForegroundColor Yellow
                    }
                }
            }

            try { $rt = $ws.ReceiveAsync($seg, $cts.Token); if (-not $rt.Wait(30000)) { continue }; $res = $rt.Result }
            catch { if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }; continue }

            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { Write-Host '  Server closed.' -ForegroundColor Yellow; break }
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                if ($res.Count -gt 1) { try { $jm = [System.Text.Encoding]::UTF8.GetString($buf,0,$res.Count) | ConvertFrom-Json; if ($jm.type -eq 'error') { Write-Host "  ERROR: $($jm.data)" -ForegroundColor Red } } catch {} }
                continue
            }
            if (($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) -and ($res.Count -gt 2)) {
                $ticks = Parse-KiteTicks $buf $res.Count
                foreach ($tick in $ticks) {
                    if ($tick.LastPrice -gt 0) {
                        Update-HAStrategyFromTick $State $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest
                    }
                }
                try { Show-HAStrategyDisplay $State $instToken } catch {}
            }
        }

        if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay -and $State.Direction -eq '') { break }
        $retryCount++
        if ($retryCount -le $maxRetries) { $w = $retryCount * 5; Write-Host "  Reconnecting in ${w}s..." -ForegroundColor Yellow; Start-Sleep $w }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $retryCount++
        if ($retryCount -le $maxRetries) { $w = $retryCount * 5; Write-Host "  Retry in ${w}s..." -ForegroundColor Yellow; Start-Sleep $w }
    }
    finally {
        if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'Done',$cts.Token).Wait(5000) } catch {} }
        if ($ws) { $ws.Dispose() }; if ($cts) { $cts.Dispose() }
    }
}

Write-Host ''
Write-Host '  Disconnected.' -ForegroundColor Yellow
Write-Host "  Total Trades: $($State.StrategySignals.Count) | Total P&L: $($State.TotalPnL.ToString('N2'))" -ForegroundColor Gray
foreach ($sig in $State.StrategySignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
Write-Host ''
