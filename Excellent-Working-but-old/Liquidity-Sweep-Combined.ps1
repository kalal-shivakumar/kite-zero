<#
.SYNOPSIS
  Liquidity Sweep Strategy with CE+PE Option Auto-Trade (zero-latency).
.DESCRIPTION
  Streams live HA candles via Kite WebSocket. Detects liquidity sweeps using pivot highs/lows
  over last 5, 10, 20 candles. After a sweep, waits for the sweep candle to confirm direction:
  
  FLOW:
  1. Identify pivot highs (swing highs) and pivot lows (swing lows) over lookback windows (5, 10, 20 candles)
  2. Detect liquidity sweep: price takes out a pivot high or pivot low then reverses
  3. Note the sweep candle (the candle that performed the sweep)
  4. Wait for confirmation: sweep candle's high/low must be crossed by a subsequent candle
  5. Entry:
     - Upside sweep (took out pivot high) + sweep candle LOW broken -> SHORT entry -> BUY PE
     - Downside sweep (took out pivot low) + sweep candle HIGH broken -> LONG entry -> BUY CE
  6. Exit:
     - Long exit: HA Close < prev Low -> SELL CE
     - Short exit: HA Close > prev High -> SELL PE
  Only one direction is active at a time.
.EXAMPLE
  .\Liquidity-Sweep-Combined.ps1
  .\Liquidity-Sweep-Combined.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
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

$inputFile = Join-Path $scriptDir 'Liquidity-sweep-input.json'
if (-not (Test-Path $inputFile)) { Write-Host '  ERROR: Liquidity-sweep-input.json not found.' -ForegroundColor Red; exit 1 }
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
# Strategy state
# ================================================================
$script:STR_CompletedCandles  = @{}
$script:STR_ActiveCandle      = @{}
$script:STR_PreviousHA        = @{}
$script:STR_TickCount         = 0
$script:STR_IntervalSeconds   = $intSec
$script:STR_DisplayConfig     = @{ SymbolName=$sym; SymbolLabel=$label; InstrumentToken=$instToken; TimeFrame=$TimeFrame; IntervalLabel=$intLabel; MaxCandles=$CandlesToShow }
$script:STR_LastDisplayTime   = [datetime]::MinValue
$script:STR_DisplayIntervalMs = 100
$script:StrategySignals       = [System.Collections.Generic.List[string]]::new()
$script:TotalPnL              = 0

# Position state: direction = 'LONG' | 'SHORT' | ''
$script:Direction      = ''
$script:EntryPrice     = 0.0
$script:EntryTime      = ''
$script:OptSymbol      = ''
$script:OptToken       = 0
$script:OptStrike      = 0
$script:OptEntryLTP    = 0
$script:OptQty         = 0
$script:OptLots        = 0
$script:OptType        = ''  # 'CE' or 'PE'
$script:TargetPrice    = 0.0  # Nearest swing high (LONG) or swing low (SHORT)
$script:StopLoss       = 0.0  # Sweep candle HIGH (SHORT) or LOW (LONG)

# ================================================================
# Liquidity Sweep state
# ================================================================
# Sweep detection state machine:
#   Phase '' = scanning for sweeps
#   Phase 'SWEEP_UP' = upside liquidity taken, waiting for sweep candle LOW to break -> SHORT
#   Phase 'SWEEP_DOWN' = downside liquidity taken, waiting for sweep candle HIGH to break -> LONG
$script:SweepPhase        = ''       # '' | 'SWEEP_UP' | 'SWEEP_DOWN'
$script:SweepCandle       = $null    # The HA candle that performed the sweep
$script:SweepPivotLevel   = 0       # The pivot level that was swept
$script:SweepLookback     = 0       # Which lookback window triggered the sweep
$script:SweepTime         = ''       # When the sweep was detected
$script:SweepCandleCount  = 0       # Completed candle count at sweep detection (for timeout)

# Lookback windows for pivot detection
$script:PivotLookbacks = @(5, 10, 20)

# Restore position
$PositionFile = Join-Path $PlacedOrdersDir 'Position.json'
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
        $script:Direction   = $saved.Direction
        $script:EntryPrice  = $saved.Price
        $script:EntryTime   = $saved.Time
        $script:OptSymbol   = $saved.Symbol
        $script:OptToken    = $saved.Token
        $script:OptStrike   = $saved.Strike
        $script:OptEntryLTP = if ($saved.OptionLTP) { $saved.OptionLTP } else { 0 }
        $script:OptQty      = if ($saved.Qty) { [int]$saved.Qty } else { $Quantity }
        $script:OptLots     = if ($saved.Lots) { [int]$saved.Lots } else { $NoOfLotsPurchaseAtaTime }
        $script:OptType     = $saved.OptType
        $script:TotalPnL    = if ($saved.TotalPnL) { $saved.TotalPnL } else { 0 }
        $script:TargetPrice = if ($saved.TargetPrice) { $saved.TargetPrice } else { 0 }
        $script:StopLoss    = if ($saved.StopLoss) { $saved.StopLoss } else { 0 }
        Write-Host "  Resuming: $($script:Direction) | $($script:OptSymbol) | Qty: $($script:OptQty) | TGT: $($script:TargetPrice) | SL: $($script:StopLoss)" -ForegroundColor Yellow
    }
}

# ================================================================
# HA helpers
# ================================================================
function script:Get-STR-TimeBucket {
    $now = [datetime]::Now
    $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
    $bucket = [int]([Math]::Floor($totalSeconds / $script:STR_IntervalSeconds)) * $script:STR_IntervalSeconds
    $bH = [int]($bucket / 3600); $bM = [int](($bucket % 3600) / 60); $bS = $bucket % 60
    return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
}

function script:Convert-ToHA([hashtable]$rawCandle, [hashtable]$previousHA) {
    $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
    $haOpen = if ($null -ne $previousHA) { ($previousHA.Open + $previousHA.Close) / 2.0 } else { ($rawCandle.Open + $rawCandle.Close) / 2.0 }
    $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
    $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
    return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
}

# ================================================================
# Pivot detection helpers
# ================================================================
function script:Find-PivotHighs([System.Collections.Generic.List[PSCustomObject]]$candles, [int]$lookback) {
    # Find pivot highs: a candle whose High is the highest in the lookback window around it
    $pivots = @()
    $count = $candles.Count
    if ($count -lt 3) { return $pivots }
    
    $halfLook = [int][Math]::Floor($lookback / 2)
    if ($halfLook -lt 1) { $halfLook = 1 }
    
    # Only scan completed candles, leave room for left+right context
    $startIdx = [Math]::Max($halfLook, 0)
    $endIdx = $count - 1  # Don't require right context for the latest candles
    
    for ($i = $startIdx; $i -lt $endIdx; $i++) {
        $isHighest = $true
        $leftStart = [Math]::Max(0, $i - $halfLook)
        $rightEnd = [Math]::Min($count - 1, $i + $halfLook)
        
        for ($j = $leftStart; $j -le $rightEnd; $j++) {
            if ($j -eq $i) { continue }
            if ($candles[$j].High -ge $candles[$i].High) { $isHighest = $false; break }
        }
        if ($isHighest) {
            $pivots += @{ Index=$i; Level=$candles[$i].High; TimeBucket=$candles[$i].TimeBucket; Lookback=$lookback }
        }
    }
    return $pivots
}

function script:Find-PivotLows([System.Collections.Generic.List[PSCustomObject]]$candles, [int]$lookback) {
    # Find pivot lows: a candle whose Low is the lowest in the lookback window around it
    $pivots = @()
    $count = $candles.Count
    if ($count -lt 3) { return $pivots }
    
    $halfLook = [int][Math]::Floor($lookback / 2)
    if ($halfLook -lt 1) { $halfLook = 1 }
    
    $startIdx = [Math]::Max($halfLook, 0)
    $endIdx = $count - 1
    
    for ($i = $startIdx; $i -lt $endIdx; $i++) {
        $isLowest = $true
        $leftStart = [Math]::Max(0, $i - $halfLook)
        $rightEnd = [Math]::Min($count - 1, $i + $halfLook)
        
        for ($j = $leftStart; $j -le $rightEnd; $j++) {
            if ($j -eq $i) { continue }
            if ($candles[$j].Low -le $candles[$i].Low) { $isLowest = $false; break }
        }
        if ($isLowest) {
            $pivots += @{ Index=$i; Level=$candles[$i].Low; TimeBucket=$candles[$i].TimeBucket; Lookback=$lookback }
        }
    }
    return $pivots
}

# ================================================================
# Helper: Enter position
# ================================================================
function script:Enter-Position([string]$dir, [double]$spotPrice, [string]$timeStamp) {
    $optType = if ($dir -eq 'LONG') { 'CE' } else { 'PE' }
    $options = if ($dir -eq 'LONG') { $ceOptions } else { $peOptions }
    $strikes = if ($dir -eq 'LONG') { $ceStrikes } else { $peStrikes }
    $offset  = if ($dir -eq 'LONG') { -$ATMOffset } else { $ATMOffset }
    $tag     = "$optType-ENTRY"

    $idxSpot = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers
    if ($idxSpot -le 0) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] Could not fetch index spot price for ATM selection. Using tick price." -ForegroundColor Yellow
        $idxSpot = $spotPrice
    }

    $atmOption = Get-ATMOption -SpotPrice $idxSpot -Options $options -AllStrikes $strikes -Offset $offset
    if (-not $atmOption) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] Could not find ATM $optType option. Resetting." -ForegroundColor Red
        return $false
    }

    $entryQty = $Quantity; $entryLots = $NoOfLotsPurchaseAtaTime; $optLTP = 0
    try {
        $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$($atmOption.Symbol)"))" -Headers $headers -ErrorAction Stop
        foreach ($p in $qr.data.PSObject.Properties) { $optLTP = $p.Value.last_price; break }
    } catch {}

    if ($AmountToTrade -gt 0 -and $optLTP -gt 0) {
        $entryLots = [int][Math]::Floor($AmountToTrade / ($optLTP * $LotSize))
        if ($entryLots -lt 1) { $entryLots = 1 }
        $entryQty = $entryLots * $LotSize
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $optType LTP: $optLTP | Amount: $AmountToTrade | Lots: $entryLots | Qty: $entryQty" -ForegroundColor Magenta
    }

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $optType BUY | Strike: $($atmOption.Strike) | Symbol: $($atmOption.Symbol) | Qty: $entryQty" -ForegroundColor Cyan
    $now = Get-Date
    $result = Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
        -Tradingsymbol $atmOption.Symbol -Quantity $entryQty `
        -OrderType $Order_type -Product $Product -Exchange $exchange -Tag $tag -MarketProtection $MarketProtection

    if ($result) {
        $script:Direction   = $dir
        $script:EntryPrice  = $spotPrice
        $script:EntryTime   = $timeStamp
        $script:OptSymbol   = $atmOption.Symbol
        $script:OptToken    = $atmOption.Token
        $script:OptStrike   = $atmOption.Strike
        $script:OptEntryLTP = $optLTP
        $script:OptQty      = $entryQty
        $script:OptLots     = $entryLots
        $script:OptType     = $optType
        @{ Direction=$dir; Symbol=$script:OptSymbol; Token=$script:OptToken; Strike=$script:OptStrike; Price=$spotPrice; Time=$timeStamp; OptionLTP=$optLTP; TotalPnL=$script:TotalPnL; Qty=$entryQty; Lots=$entryLots; OptType=$optType; TargetPrice=$script:TargetPrice; StopLoss=$script:StopLoss } | ConvertTo-Json | Set-Content $PositionFile -Force
        $latency = ((Get-Date) - $now).TotalMilliseconds
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] POSITION OPENED in ${latency}ms | $dir $($script:OptSymbol) | Strike: $($script:OptStrike) | Qty: $entryQty | LTP: $optLTP" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $optType BUY FAILED" -ForegroundColor Red
        return $false
    }
}

# ================================================================
# Helper: Exit position
# ================================================================
function script:Exit-Position([double]$lastPrice, [string]$timeStamp) {
    if ($ExitTrade -eq 'no') {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] EXIT DISABLED - position stays open" -ForegroundColor DarkYellow
        return
    }

    $trendSel = if ($script:OptType -eq 'CE') { 'CE' } else { 'PE' }
    Cancel-AllStopLosses -TrendEntrySelection $trendSel -Headers $headers

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $($script:OptType) SELL | Symbol: $($script:OptSymbol) | Qty: $($script:OptQty)" -ForegroundColor Cyan
    $now = Get-Date
    $result = Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
        -Tradingsymbol $script:OptSymbol -Quantity $script:OptQty `
        -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "$($script:OptType)-EXIT" -MarketProtection $MarketProtection

    if ($result) {
        $exitLTP = 0
        try {
            $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$($script:OptSymbol)"))" -Headers $headers -ErrorAction Stop
            foreach ($p in $qr.data.PSObject.Properties) { $exitLTP = $p.Value.last_price; break }
        } catch {}
        $tradePnL = ($exitLTP - $script:OptEntryLTP) * $script:OptQty
        $script:TotalPnL += $tradePnL
        $pnlColor = if ($tradePnL -ge 0) { 'Green' } else { 'Red' }
        $latency = ((Get-Date) - $now).TotalMilliseconds
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] CLOSED in ${latency}ms | $($script:OptSymbol) | Trade P&L: $($tradePnL.ToString('N2')) | Total: $($script:TotalPnL.ToString('N2'))" -ForegroundColor $pnlColor
    } else {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] SELL failed - clearing state anyway" -ForegroundColor DarkYellow
    }

    $script:StrategySignals.Add("EXIT $($script:Direction) @ $lastPrice  P&L: $([Math]::Round($lastPrice - $script:EntryPrice, 2)) ($timeStamp)")
    $script:Direction = ''; $script:EntryPrice = 0; $script:EntryTime = ''
    $script:OptSymbol = ''; $script:OptToken = 0; $script:OptStrike = 0
    $script:OptEntryLTP = 0; $script:OptQty = 0; $script:OptLots = 0; $script:OptType = ''
    $script:TargetPrice = 0; $script:StopLoss = 0
    Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
}

# ================================================================
# CORE: Liquidity Sweep Signal Detection + Trade
# ================================================================
function script:Check-SignalAndTrade([int]$instrumentToken, [double]$lastPrice) {
    $completedList = $script:STR_CompletedCandles[$instrumentToken]
    if (-not $completedList -or $completedList.Count -lt 3) { return }

    $currentRaw = $script:STR_ActiveCandle[$instrumentToken]
    if ($null -eq $currentRaw) { return }

    $liveHA = script:Convert-ToHA $currentRaw ($script:STR_PreviousHA[$instrumentToken])
    $prev = $completedList[$completedList.Count - 1]

    $now = [datetime]::Now
    if ($now.TimeOfDay -lt $StartTime.TimeOfDay -or $now.TimeOfDay -gt $StopTime.TimeOfDay) { return }
    $timeStamp = $now.ToString('yyyy-MM-dd_HH-mm-ss')

    # ── EXIT CHECKS (always check first, regardless of sweep phase) ──

    # -- LONG TARGET: LTP reaches target (nearest swing high) --
    if ($script:Direction -eq 'LONG' -and $script:TargetPrice -gt 0 -and $lastPrice -ge $script:TargetPrice) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** LONG TARGET HIT *** LTP: $lastPrice >= Target: $($script:TargetPrice)" -ForegroundColor Green
        $script:StrategySignals.Add("TARGET HIT LONG @ $lastPrice  Target: $($script:TargetPrice) ($timeStamp)")
        script:Exit-Position $lastPrice $timeStamp
        $script:SweepPhase = ''; $script:SweepCandle = $null
        $script:TargetPrice = 0; $script:StopLoss = 0
        return
    }

    # -- LONG STOPLOSS: LTP drops below stoploss (sweep candle LOW) --
    if ($script:Direction -eq 'LONG' -and $script:StopLoss -gt 0 -and $lastPrice -le $script:StopLoss) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** LONG STOPLOSS HIT *** LTP: $lastPrice <= SL: $($script:StopLoss)" -ForegroundColor Red
        $script:StrategySignals.Add("STOPLOSS LONG @ $lastPrice  SL: $($script:StopLoss) ($timeStamp)")
        script:Exit-Position $lastPrice $timeStamp
        $script:SweepPhase = ''; $script:SweepCandle = $null
        $script:TargetPrice = 0; $script:StopLoss = 0
        return
    }

    # -- SHORT TARGET: LTP drops to target (nearest swing low) --
    if ($script:Direction -eq 'SHORT' -and $script:TargetPrice -gt 0 -and $lastPrice -le $script:TargetPrice) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT TARGET HIT *** LTP: $lastPrice <= Target: $($script:TargetPrice)" -ForegroundColor Green
        $script:StrategySignals.Add("TARGET HIT SHORT @ $lastPrice  Target: $($script:TargetPrice) ($timeStamp)")
        script:Exit-Position $lastPrice $timeStamp
        $script:SweepPhase = ''; $script:SweepCandle = $null
        $script:TargetPrice = 0; $script:StopLoss = 0
        return
    }

    # -- SHORT STOPLOSS: LTP rises above stoploss (sweep candle HIGH) --
    if ($script:Direction -eq 'SHORT' -and $script:StopLoss -gt 0 -and $lastPrice -ge $script:StopLoss) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT STOPLOSS HIT *** LTP: $lastPrice >= SL: $($script:StopLoss)" -ForegroundColor Red
        $script:StrategySignals.Add("STOPLOSS SHORT @ $lastPrice  SL: $($script:StopLoss) ($timeStamp)")
        script:Exit-Position $lastPrice $timeStamp
        $script:SweepPhase = ''; $script:SweepCandle = $null
        $script:TargetPrice = 0; $script:StopLoss = 0
        return
    }

    # ── Only look for new entries when flat ──
    if ($script:Direction -ne '') { return }

    # ── PHASE 2: Waiting for sweep candle confirmation ──
    $sweepConfirmed = $false
    if ($script:SweepPhase -eq 'SWEEP_UP' -and $null -ne $script:SweepCandle) {
        # Upside liquidity was swept. Wait for sweep candle's LOW to break -> SHORT
        if ($liveHA.Close -lt $script:SweepCandle.Low) {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SWEEP SHORT CONFIRMED *** Sweep candle LOW broken: $([Math]::Round($liveHA.Close,2)) < $($script:SweepCandle.Low) | Pivot: $($script:SweepPivotLevel) (LB:$($script:SweepLookback))" -ForegroundColor Magenta
            $ok = script:Enter-Position 'SHORT' $lastPrice $timeStamp
            if ($ok) {
                # Stoploss = sweep candle HIGH; Target = nearest swing low below entry
                $script:StopLoss = $script:SweepCandle.High
                $nearestSwingLow = 0
                foreach ($lb in $script:PivotLookbacks) {
                    $pls = script:Find-PivotLows $completedList $lb
                    foreach ($pl in $pls) {
                        if ($pl.Level -lt $lastPrice -and ($nearestSwingLow -eq 0 -or $pl.Level -gt $nearestSwingLow)) {
                            $nearestSwingLow = $pl.Level
                        }
                    }
                }
                $script:TargetPrice = $nearestSwingLow
                Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] TARGET: $($script:TargetPrice) (nearest swing low) | SL: $($script:StopLoss) (sweep candle HIGH)" -ForegroundColor Cyan
                $script:StrategySignals.Add("ENTRY SHORT (SWEEP_UP confirm) @ $lastPrice  PE: $($script:OptSymbol) Pivot:$($script:SweepPivotLevel) TGT:$($script:TargetPrice) SL:$($script:StopLoss) ($timeStamp)")
            }
            $script:SweepPhase = ''
            $script:SweepCandle = $null
            return
        }
        $sweepConfirmed = $false  # not confirmed yet, but allow Phase 1 to scan opposite direction
    }

    if ($script:SweepPhase -eq 'SWEEP_DOWN' -and $null -ne $script:SweepCandle) {
        # Downside liquidity was swept. Wait for sweep candle's HIGH to break -> LONG
        if ($liveHA.Close -gt $script:SweepCandle.High) {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SWEEP LONG CONFIRMED *** Sweep candle HIGH broken: $([Math]::Round($liveHA.Close,2)) > $($script:SweepCandle.High) | Pivot: $($script:SweepPivotLevel) (LB:$($script:SweepLookback))" -ForegroundColor Magenta
            $ok = script:Enter-Position 'LONG' $lastPrice $timeStamp
            if ($ok) {
                # Stoploss = sweep candle LOW; Target = nearest swing high above entry
                $script:StopLoss = $script:SweepCandle.Low
                $nearestSwingHigh = 0
                foreach ($lb in $script:PivotLookbacks) {
                    $phs = script:Find-PivotHighs $completedList $lb
                    foreach ($ph in $phs) {
                        if ($ph.Level -gt $lastPrice -and ($nearestSwingHigh -eq 0 -or $ph.Level -lt $nearestSwingHigh)) {
                            $nearestSwingHigh = $ph.Level
                        }
                    }
                }
                $script:TargetPrice = $nearestSwingHigh
                Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] TARGET: $($script:TargetPrice) (nearest swing high) | SL: $($script:StopLoss) (sweep candle LOW)" -ForegroundColor Cyan
                $script:StrategySignals.Add("ENTRY LONG (SWEEP_DOWN confirm) @ $lastPrice  CE: $($script:OptSymbol) Pivot:$($script:SweepPivotLevel) TGT:$($script:TargetPrice) SL:$($script:StopLoss) ($timeStamp)")
            }
            $script:SweepPhase = ''
            $script:SweepCandle = $null
            return
        }
        $sweepConfirmed = $false
    }

    # ── Sweep timeout: invalidate if not confirmed within 5 candles ──
    if ($script:SweepPhase -ne '' -and $script:SweepCandleCount -gt 0) {
        $candlesSinceSweep = $completedList.Count - $script:SweepCandleCount
        if ($candlesSinceSweep -ge 5) {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] ** SWEEP EXPIRED ** $($script:SweepPhase) not confirmed within 5 candles ($candlesSinceSweep), resetting" -ForegroundColor DarkYellow
            $script:StrategySignals.Add("SWEEP EXPIRED: $($script:SweepPhase) @ Pivot:$($script:SweepPivotLevel) ($timeStamp)")
            $script:SweepPhase = ''
            $script:SweepCandle = $null
        }
    }

    # ── PHASE 1: Scan for liquidity sweeps (both directions always) ──
    # Only allow new sweep detection if no current sweep, or at least 1 candle completed since current sweep
    # This prevents ping-pong between UP/DOWN when both sweep conditions are simultaneously valid
    if ($script:SweepPhase -ne '' -and $script:SweepCandleCount -gt 0 -and ($completedList.Count - $script:SweepCandleCount) -lt 1) {
        return
    }
    $candleCount = $completedList.Count
    
    foreach ($lookback in $script:PivotLookbacks) {
        if ($candleCount -lt ($lookback + 2)) { continue }

        # Get the relevant window of candles for this lookback
        $windowStart = [Math]::Max(0, $candleCount - $lookback - 5)
        # Work with the full completed candle list for pivot detection
        
        # Find pivot highs
        $pivotHighs = script:Find-PivotHighs $completedList $lookback
        # Find pivot lows
        $pivotLows = script:Find-PivotLows $completedList $lookback

        # Check if current live HA candle sweeps above any recent pivot high
        # Skip if we're already tracking an upside sweep in Phase 2
        if ($script:SweepPhase -ne 'SWEEP_UP') {
        foreach ($ph in $pivotHighs) {
            # Only consider pivots from the last N candles
            if ($ph.Index -lt ($candleCount - $lookback - 2)) { continue }
            
            # Upside sweep: live HA high goes above pivot high, but close comes back below or near it
            if ($liveHA.High -gt $ph.Level -and $liveHA.Close -le $ph.Level) {
                # This is an upside liquidity sweep! 
                $script:SweepPhase = 'SWEEP_UP'
                $script:SweepCandle = @{
                    High = [Math]::Round($liveHA.High, 2)
                    Low  = [Math]::Round($liveHA.Low, 2)
                    Open = [Math]::Round($liveHA.Open, 2)
                    Close = [Math]::Round($liveHA.Close, 2)
                }
                $script:SweepPivotLevel = $ph.Level
                $script:SweepLookback = $lookback
                $script:SweepTime = $timeStamp
                $script:SweepCandleCount = $completedList.Count
                Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] ** UPSIDE SWEEP DETECTED ** HA High: $([Math]::Round($liveHA.High,2)) > Pivot High: $($ph.Level) | Close back: $([Math]::Round($liveHA.Close,2)) | LB: $lookback" -ForegroundColor DarkCyan
                $script:StrategySignals.Add("SWEEP UP detected @ Pivot:$($ph.Level) LB:$lookback ($timeStamp)")
                return
            }
        }
        }

        # Check if current live HA candle sweeps below any recent pivot low
        # Skip if we're already tracking a downside sweep in Phase 2
        if ($script:SweepPhase -ne 'SWEEP_DOWN') {
        foreach ($pl in $pivotLows) {
            if ($pl.Index -lt ($candleCount - $lookback - 2)) { continue }
            
            # Downside sweep: live HA low goes below pivot low, but close comes back above or near it
            if ($liveHA.Low -lt $pl.Level -and $liveHA.Close -ge $pl.Level) {
                # This is a downside liquidity sweep!
                $script:SweepPhase = 'SWEEP_DOWN'
                $script:SweepCandle = @{
                    High = [Math]::Round($liveHA.High, 2)
                    Low  = [Math]::Round($liveHA.Low, 2)
                    Open = [Math]::Round($liveHA.Open, 2)
                    Close = [Math]::Round($liveHA.Close, 2)
                }
                $script:SweepPivotLevel = $pl.Level
                $script:SweepLookback = $lookback
                $script:SweepTime = $timeStamp
                $script:SweepCandleCount = $completedList.Count
                Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] ** DOWNSIDE SWEEP DETECTED ** HA Low: $([Math]::Round($liveHA.Low,2)) < Pivot Low: $($pl.Level) | Close back: $([Math]::Round($liveHA.Close,2)) | LB: $lookback" -ForegroundColor DarkCyan
                $script:StrategySignals.Add("SWEEP DOWN detected @ Pivot:$($pl.Level) LB:$lookback ($timeStamp)")
                return
            }
        }
        }
    }
}

# ================================================================
# Tick processing
# ================================================================
function script:Update-StrategyFromTick([int]$instrumentToken, [double]$lastPrice, [int]$volume, [double]$dayOpen, [double]$dayHigh, [double]$dayLow, [double]$dayClose, [int]$openInterest) {
    $script:STR_TickCount++
    $timeBucket = script:Get-STR-TimeBucket

    if (-not $script:STR_CompletedCandles.ContainsKey($instrumentToken)) {
        $script:STR_CompletedCandles[$instrumentToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    $currentCandle = $script:STR_ActiveCandle[$instrumentToken]

    if (($null -eq $currentCandle) -or ($currentCandle.TimeBucket -ne $timeBucket)) {
        if ($null -ne $currentCandle) {
            $prevHA = $script:STR_PreviousHA[$instrumentToken]
            $ha = script:Convert-ToHA $currentCandle $prevHA
            $script:STR_PreviousHA[$instrumentToken] = @{ Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close }
            $script:STR_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
            })
            
            # When a candle completes and we're in a sweep phase, update sweep candle
            # to the just-completed candle's FINAL HA values (only the actual sweep candle)
            if ($script:SweepPhase -ne '' -and $null -ne $script:SweepCandle -and $script:SweepTime -ne '') {
                # SweepTime format: yyyy-MM-dd_HH-mm-ss, TimeBucket format: yyyy-MM-dd HH:mm:ss
                # Convert SweepTime to TimeBucket prefix for matching (just date + hour:minute)
                $sweepTB = $script:SweepTime.Substring(0,16) -replace '_',' ' -replace '-',':'
                # Fix: only first dash after date should remain, rest become colons
                $sweepTBPrefix = $script:SweepTime.Substring(0,10) + ' ' + $script:SweepTime.Substring(11,2) + ':' + $script:SweepTime.Substring(14,2)
                if ($currentCandle.TimeBucket.StartsWith($sweepTBPrefix)) {
                    $completedHA = $script:STR_CompletedCandles[$instrumentToken]
                    $lastCompleted = $completedHA[$completedHA.Count - 1]
                    $script:SweepCandle = @{
                        High = $lastCompleted.High
                        Low  = $lastCompleted.Low
                        Open = $lastCompleted.Open
                        Close = $lastCompleted.Close
                    }
                }
            }
        }
        $script:STR_ActiveCandle[$instrumentToken] = @{
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

    script:Check-SignalAndTrade $instrumentToken $lastPrice
}

# ================================================================
# Display
# ================================================================
function script:Render-StrategyDisplay([int]$instrumentToken) {
    $now = [datetime]::Now
    if (($now - $script:STR_LastDisplayTime).TotalMilliseconds -lt $script:STR_DisplayIntervalMs) { return }
    $script:STR_LastDisplayTime = $now

    $config = $script:STR_DisplayConfig
    $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
    $closedCandles = $script:STR_CompletedCandles[$instrumentToken]
    if ($closedCandles -and $closedCandles.Count -gt 0) { $allCandles.AddRange($closedCandles) }

    $currentCandle = $script:STR_ActiveCandle[$instrumentToken]
    if ($null -ne $currentCandle) {
        $ha = script:Convert-ToHA $currentCandle ($script:STR_PreviousHA[$instrumentToken])
        $allCandles.Add([PSCustomObject]@{
            TimeBucket=$currentCandle.TimeBucket
            Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
            Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
            Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest; TicksInCandle=$currentCandle.TicksInCandle
        })
    }
    if ($allCandles.Count -eq 0) { return }

    $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
    $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

    $sb = [System.Text.StringBuilder]::new(2048)
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("  ================================================")
    $null = $sb.AppendLine("  $($config.SymbolLabel) - Liquidity Sweep | CE+PE Auto-Trade")
    $null = $sb.AppendLine("  ================================================")
    $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TF: $($config.TimeFrame)")
    if ($AmountToTrade -gt 0) {
        $null = $sb.AppendLine("  Trade   : Amount: $AmountToTrade  |  LotSize: $LotSize  |  Product: $Product")
    } else {
        $null = $sb.AppendLine("  Trade   : Lots: $NoOfLotsPurchaseAtaTime  |  Qty: $Quantity  |  Product: $Product")
    }
    $null = $sb.AppendLine("  Ticks   : $($script:STR_TickCount)  |  Window: $($StartTime.ToString('HH:mm:ss'))-$($StopTime.ToString('HH:mm:ss'))  |  Total P&L: $($script:TotalPnL.ToString('N2'))")
    $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
    $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')")

    # Sweep state display
    if ($script:SweepPhase -ne '') {
        $sweepDir = if ($script:SweepPhase -eq 'SWEEP_UP') { 'UPSIDE SWEPT' } else { 'DOWNSIDE SWEPT' }
        $waitFor = if ($script:SweepPhase -eq 'SWEEP_UP') { "Wait: Close < SweepLow $($script:SweepCandle.Low)" } else { "Wait: Close > SweepHigh $($script:SweepCandle.High)" }
        $null = $sb.AppendLine("  SWEEP   : $sweepDir | Pivot: $($script:SweepPivotLevel) | LB: $($script:SweepLookback) | $waitFor")
    } else {
        $null = $sb.AppendLine("  SWEEP   : Scanning for pivot sweeps (LB: $($script:PivotLookbacks -join ', '))")
    }

    if ($script:Direction -ne '') {
        $null = $sb.AppendLine("  POSITION: $($script:Direction) ACTIVE  $($script:OptType): $($script:OptSymbol)  Strike: $($script:OptStrike)  Lots: $($script:OptLots)  Qty: $($script:OptQty)  Entry: $($script:EntryPrice.ToString('N2')) @ $($script:EntryTime)  OptLTP: $($script:OptEntryLTP)")
        if ($null -ne $currentCandle) {
            $unrealized = if ($script:Direction -eq 'LONG') { $currentCandle.Close - $script:EntryPrice } else { $script:EntryPrice - $currentCandle.Close }
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized Spot P&L: $($unrealized.ToString('N2'))")
        }
        if ($script:TargetPrice -gt 0 -or $script:StopLoss -gt 0) {
            $tgtStr = if ($script:TargetPrice -gt 0) { $script:TargetPrice.ToString('N2') } else { 'N/A' }
            $slStr  = if ($script:StopLoss -gt 0)    { $script:StopLoss.ToString('N2') }    else { 'N/A' }
            $null = $sb.AppendLine("  TGT/SL  : Target: $tgtStr (nearest swing $( if ($script:Direction -eq 'LONG') {'high'} else {'low'} )) | StopLoss: $slStr (sweep candle $( if ($script:Direction -eq 'LONG') {'LOW'} else {'HIGH'} ))")
        }
    } else {
        $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for sweep confirmation)")
        if ($null -ne $currentCandle) {
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
        }
    }

    $null = $sb.AppendLine('')
    $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,5} {7,6}'
    $null = $sb.AppendLine(($rowFormat -f 'Time','HA Open','HA High','HA Low','HA Close','Volume','Ticks','Trend'))
    $null = $sb.AppendLine(' ' + ('-' * 102))

    if ($script:STR_CanClearHost -eq $null) { $script:STR_CanClearHost = try { Clear-Host; $true } catch { $false } }
    elseif ($script:STR_CanClearHost) { try { Clear-Host } catch {} }
    Write-Host $sb.ToString()

    for ($i = 0; $i -lt $visibleCandles.Count; $i++) {
        $c = $visibleCandles[$i]
        $trend = if ($c.Close -ge $c.Open) { '  UP' } else { 'DOWN' }
        $color = if ($c.Close -ge $c.Open) { 'Green' } else { 'Red' }
        $line = $rowFormat -f $c.TimeBucket, ('{0:N2}' -f $c.Open), ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), ('{0:N0}' -f $c.Volume), $c.TicksInCandle, $trend
        Write-Host $line -ForegroundColor $(if ($i -eq $visibleCandles.Count - 1) { 'Yellow' } else { $color })
    }

    if ($script:StrategySignals.Count -gt 0) {
        Write-Host ''; Write-Host '  --- Sweep Signals ---' -ForegroundColor Cyan
        $show = [Math]::Min(10, $script:StrategySignals.Count)
        for ($si = $script:StrategySignals.Count - $show; $si -lt $script:StrategySignals.Count; $si++) {
            $sigColor = if ($script:StrategySignals[$si] -match 'ENTRY') { 'Green' } elseif ($script:StrategySignals[$si] -match 'SWEEP') { 'DarkCyan' } else { 'Red' }
            Write-Host "    $($script:StrategySignals[$si])" -ForegroundColor $sigColor
        }
    }
    Write-Host ''; Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
}

# ================================================================
# Force-exit at stop time
# ================================================================
function script:Force-ExitAtStopTime {
    if ($script:Direction -ne '' -and $script:OptSymbol) {
        $now = Get-Date
        Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME - Force exiting: $($script:OptSymbol)" -ForegroundColor Red
        $forceQty = if ($script:OptQty -gt 0) { $script:OptQty } else { $Quantity }
        Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
            -Tradingsymbol $script:OptSymbol -Quantity $forceQty `
            -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "$($script:OptType)-TIMEEXIT" -MarketProtection $MarketProtection
        $script:Direction = ''; $script:OptSymbol = ''
        Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
    }
}

# ================================================================
# WebSocket
# ================================================================
# Set global header for Get-HeikinAshiCandlesData (uses $Global:common_header)
$Global:common_header = $headers

# ================================================================
# Seed historical HA candles via REST API (so pivots work immediately)
# ================================================================
# Convert TimeFrame (minute, 3minute, 5minute, etc.) to numeric format for Get-HeikinAshiCandlesData
$histTF = if ($TimeFrame -eq 'minute') { '1' } elseif ($TimeFrame -match '^(\d+)minute$') { $Matches[1] } else { '5' }

# Fetch enough candles to cover the largest lookback window + buffer
$histCount = ($script:PivotLookbacks | Measure-Object -Maximum).Maximum + 10
Write-Host "  Fetching $histCount historical HA candles ($TimeFrame)..." -ForegroundColor Yellow

$histCandles = Get-HeikinAshiCandlesData -instrument_token $instToken -TimeFrame $histTF -LastNCandles $histCount

if ($histCandles -and $histCandles.Count -gt 0) {
    # Seed completed candles list
    if (-not $script:STR_CompletedCandles.ContainsKey($instToken)) {
        $script:STR_CompletedCandles[$instToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    # Drop the last candle (it may still be forming in the current time bucket)
    $seedCandles = if ($histCandles.Count -gt 1) { $histCandles[0..($histCandles.Count - 2)] } else { $histCandles }

    foreach ($hc in $seedCandles) {
        $ts = if ($hc.TimeStamp -is [datetime]) { $hc.TimeStamp.ToString('yyyy-MM-dd HH:mm:ss') } else { [string]$hc.TimeStamp }
        $script:STR_CompletedCandles[$instToken].Add([PSCustomObject]@{
            TimeBucket  = $ts
            Open        = [Math]::Round($hc.Open, 2)
            High        = [Math]::Round($hc.High, 2)
            Low         = [Math]::Round($hc.Low, 2)
            Close       = [Math]::Round($hc.Close, 2)
            Volume      = 0
            OpenInterest = 0
            TicksInCandle = 0
        })
    }

    # Set PreviousHA from the last seeded candle so live HA continues smoothly
    $lastSeeded = $seedCandles[-1]
    $script:STR_PreviousHA[$instToken] = @{
        Open  = [double]$lastSeeded.Open
        High  = [double]$lastSeeded.High
        Low   = [double]$lastSeeded.Low
        Close = [double]$lastSeeded.Close
    }

    Write-Host "  Seeded $($script:STR_CompletedCandles[$instToken].Count) historical HA candles (pivots ready)" -ForegroundColor Green

    # Show last few seeded candles
    $showCount = [Math]::Min(5, $script:STR_CompletedCandles[$instToken].Count)
    $startIdx = $script:STR_CompletedCandles[$instToken].Count - $showCount
    for ($si = $startIdx; $si -lt $script:STR_CompletedCandles[$instToken].Count; $si++) {
        $sc = $script:STR_CompletedCandles[$instToken][$si]
        $trend = if ($sc.Close -ge $sc.Open) { 'UP' } else { 'DN' }
        Write-Host "    $($sc.TimeBucket) | O:$($sc.Open) H:$($sc.High) L:$($sc.Low) C:$($sc.Close) [$trend]" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Could not fetch historical candles - will build from live ticks (pivots need $histCount candles)" -ForegroundColor DarkYellow
}

$wsUri = "wss://ws.kite.trade?api_key=$API_Key&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  LIQUIDITY SWEEP | CE+PE Auto-Trade (Zero Latency)' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym) | Token: $instToken"
Write-Host "  TimeFrame: $TimeFrame ($intLabel) | Expiry: $nearestExpiry"
Write-Host "  Pivots   : Lookback windows: $($script:PivotLookbacks -join ', ') candles | Seeded: $($script:STR_CompletedCandles[$instToken].Count) HA candles"
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
            script:Force-ExitAtStopTime; exit 1
        }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host "  Connection failed." -ForegroundColor Red; script:Force-ExitAtStopTime; exit 1
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

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $now = [datetime]::Now
            if (($now - $lastStopCheck).TotalSeconds -ge 1) {
                $lastStopCheck = $now
                if ($now.TimeOfDay -gt $stopTOD) {
                    script:Force-ExitAtStopTime; Write-Host "  Stop time reached." -ForegroundColor Yellow; break
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
                        script:Update-StrategyFromTick $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest
                    }
                }
                try { script:Render-StrategyDisplay $instToken } catch {}
            }
        }

        if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay) { break }
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
Write-Host "  Total Trades: $($script:StrategySignals.Count) | Total P&L: $($script:TotalPnL.ToString('N2'))" -ForegroundColor Gray
foreach ($sig in $script:StrategySignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
Write-Host ''
