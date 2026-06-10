<#
.SYNOPSIS
  Combined HA + SuperTrend Long Signal + CE Option Auto-Trade (zero-latency).
.DESCRIPTION
  Streams live HA candles via Kite WebSocket. Computes SuperTrend (ATR length=5, factor=1.5)
  on HA candles. When SuperTrend flips from DOWN to UP (HA Close > Upper Band),
  immediately places a CE BUY order. Exit when SuperTrend flips from UP to DOWN
  (HA Close < Lower Band).

  SuperTrend Parameters:
    Length = 5  (ATR period, configurable via -STLength or input.json)
    Factor = 1.5  (multiplier, configurable via -STFactor or input.json)
.EXAMPLE
  .\SuperTrend-Long-CE.ps1
  .\SuperTrend-Long-CE.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
  .\SuperTrend-Long-CE.ps1 -TradingSymbol SENSEX -IndexChoosen SENSEX -STLength 7 -STFactor 2.0
#>

param(
    [string]$TradingSymbol,
    [int]$InstrumentToken,
    [ValidateSet('5second','15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame,
    [int]$CandlesToShow,
    [switch]$FullMode,
    [switch]$ListSymbols,
    [switch]$GetLoginUrl,
    [string]$RequestToken,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret,

    # CE-BUY params
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

    # SuperTrend params
    [int]$STLength,
    [double]$STFactor
)

# ================================================================
# Module & Config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) {
    Write-Host '  ERROR: input.json not found. This file is required for configuration.' -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

# Load all params from input.json; command-line overrides take priority
if (-not $PSBoundParameters.ContainsKey('TradingSymbol'))  { $TradingSymbol  = $cfg.TradingSymbol }
if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
if (-not $PSBoundParameters.ContainsKey('TimeFrame'))      { $TimeFrame      = $cfg.TimeFrame }
if (-not $PSBoundParameters.ContainsKey('CandlesToShow'))  { $CandlesToShow  = [int]$cfg.CandlesToShow }
if (-not $PSBoundParameters.ContainsKey('FullMode')  -and $cfg.FullMode)  { $FullMode  = [switch]$true }
if (-not $PSBoundParameters.ContainsKey('API_Key'))        { $API_Key        = $cfg.API_Key }
if (-not $PSBoundParameters.ContainsKey('API_Secret'))     { $API_Secret     = $cfg.API_Secret }
if (-not $PSBoundParameters.ContainsKey('IndexChoosen')) {
    $rawIdx = $cfg.IndexChoosen
    $idxMap = @{ 'NIFTY'='NIFTY'; 'BANKNIFTY'='BANKNIFTY'; 'FINNIFTY'='FinNifty'; 'MIDCPNIFTY'='MIDCPNIFTY'; 'SENSEX'='SENSEX' }
    $IndexChoosen = if ($idxMap.ContainsKey($rawIdx.ToUpper())) { $idxMap[$rawIdx.ToUpper()] } else { $rawIdx }
}
if (-not $PSBoundParameters.ContainsKey('NoOfLotsPurchaseAtaTime')) { $NoOfLotsPurchaseAtaTime = [int]$cfg.NoOfLotsPurchaseAtaTime }
if (-not $PSBoundParameters.ContainsKey('AmountToTrade'))           { $AmountToTrade           = if ($cfg.AmountToTrade) { [double]$cfg.AmountToTrade } else { 0 } }
if (-not $PSBoundParameters.ContainsKey('Product'))                 { $Product                 = $cfg.Product }
if (-not $PSBoundParameters.ContainsKey('StartTime'))               { $StartTime               = [datetime]$cfg.StartTime }
if (-not $PSBoundParameters.ContainsKey('StopTime'))                { $StopTime                = [datetime]$cfg.StopTime }
if (-not $PSBoundParameters.ContainsKey('Order_type'))              { $Order_type              = $cfg.Order_type }
if (-not $PSBoundParameters.ContainsKey('ModeOfTrading'))           { $ModeOfTrading           = $cfg.ModeOfTrading }
if (-not $PSBoundParameters.ContainsKey('ATMOffset'))               { $ATMOffset               = [int]$cfg.ATMOffset }
if (-not $PSBoundParameters.ContainsKey('Variety'))                 { $Variety                 = if ($cfg.Variety) { $cfg.Variety } else { 'regular' } }
if (-not $PSBoundParameters.ContainsKey('MarketProtection'))        { $MarketProtection        = if ($cfg.MarketProtection) { [int]$cfg.MarketProtection } else { 3 } }
if (-not $PSBoundParameters.ContainsKey('ExitTrade'))              { $ExitTrade              = if ($cfg.ExitTrade) { $cfg.ExitTrade } else { 'yes' } }
if (-not $PSBoundParameters.ContainsKey('STLength'))               { $STLength               = if ($cfg.STLength) { [int]$cfg.STLength } else { 5 } }
if (-not $PSBoundParameters.ContainsKey('STFactor'))               { $STFactor               = if ($cfg.STFactor) { [double]$cfg.STFactor } else { 1.5 } }
Write-Host "  Loaded config from input.json" -ForegroundColor DarkGray

# ================================================================
# Auth
# ================================================================
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  ERROR: API_Key/API_Secret not found. Check input.json exists and has valid values.' -ForegroundColor Red
    exit 1
}

if ($GetLoginUrl) {
    $url = 'https://kite.zerodha.com/connect/login?api_key=' + $API_Key
    Write-Host "  Login URL: $url" -ForegroundColor White
    try { Start-Process $url } catch {}
    exit 0
}

if ($ListSymbols) { Show-KiteSymbols; exit 0 }

$tokenFile = Join-Path $scriptDir 'accesstoken.json'
if (-not $AccessToken) {
    if ($RequestToken) {
        $AccessToken = Exchange-KiteRequestToken -ApiKey $API_Key -ApiSecret $API_Secret -ReqToken $RequestToken -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    } else {
        $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
    }
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

# Validate token by calling the profile API
$tokenValid = $false
try {
    $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
    if ($profile.data -and $profile.data.user_id) {
        $tokenValid = $true
        Write-Host "  Token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    }
} catch {
    Write-Host "  Token validation failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $tokenValid) {
    Write-Host '  Access token is INVALID or EXPIRED. Requesting new token...' -ForegroundColor Red
    Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  Login failed. Exiting.' -ForegroundColor Red; exit 1 }
    $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
    try {
        $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
        Write-Host "  New token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: New token also failed. Check API credentials." -ForegroundColor Red
        exit 1
    }
}

# ================================================================
# Resolve symbol for WebSocket
# ================================================================
$sym = $TradingSymbol.ToUpper().Trim()
if ($InstrumentToken -gt 0) {
    $instToken = $InstrumentToken
    $label = $sym
} else {
    $preset = Resolve-KiteSymbol $sym
    if ($preset) {
        $instToken = $preset.Token
        $label = $preset.Label
    } else {
        Write-Host "  Unknown symbol: $TradingSymbol. Use -ListSymbols to see presets." -ForegroundColor Red
        exit 1
    }
}

$intSec   = Get-IntervalSeconds $TimeFrame
$intLabel = Get-IntervalLabel $intSec

# ================================================================
# CE Option setup
# ================================================================
$IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots $NoOfLotsPurchaseAtaTime
if (-not $IndexConfig) { exit 1 }

$exchange       = $IndexConfig.exchange
$optExchange    = $IndexConfig.OptExchange
$LotSize        = $IndexConfig.Lot
$underlyingName = $IndexConfig.SearchKeyWord

$Quantity = $IndexConfig.Quantity

Write-Host ""
Write-Host "  Fetching $optExchange CE instruments..." -ForegroundColor Yellow

$optData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'CE' -Headers $headers
if (-not $optData) { exit 1 }

$ceOptions     = $optData.Options
$allStrikes    = $optData.Strikes
$nearestExpiry = $optData.Expiry

Write-Host "  Expiry: $nearestExpiry | CE Strikes: $($allStrikes.Count) | Lot Size: $($ceOptions[0].LotSize)" -ForegroundColor Green

$PlacedOrdersDir = Join-Path $scriptDir 'PlacedOrders'
if (-not (Test-Path $PlacedOrdersDir)) { New-Item -ItemType Directory -Path $PlacedOrdersDir -Force | Out-Null }

# ================================================================
# Strategy + Position state (all in-memory)
# ================================================================
$script:STR_CompletedCandles = @{}
$script:STR_ActiveCandle     = @{}
$script:STR_PreviousHA       = @{}
$script:STR_TickCount        = 0
$script:STR_IntervalSeconds  = $intSec
$script:STR_DisplayConfig    = @{
    SymbolName=$sym; SymbolLabel=$label; InstrumentToken=$instToken
    TimeFrame=$TimeFrame; IntervalLabel=$intLabel; MaxCandles=$CandlesToShow
}
$script:STR_LastDisplayTime   = [datetime]::MinValue
$script:STR_DisplayIntervalMs = 250

# Signal state
$script:LongOrderPlaced = $false
$script:LongEntryPrice  = 0.0
$script:LongEntryTime   = ''
$script:StrategySignals  = [System.Collections.Generic.List[string]]::new()

# CE position state
$script:CE_InPosition   = $false
$script:CE_EntrySymbol  = ''
$script:CE_EntryToken   = 0
$script:CE_EntryStrike  = 0
$script:CE_EntryPrice   = 0
$script:CE_EntryTime    = ''
$script:CE_EntryQty     = 0
$script:CE_EntryLots    = 0

# SuperTrend state
$script:ST_Length          = $STLength
$script:ST_Factor          = $STFactor
$script:ST_TRValues        = [System.Collections.Generic.List[double]]::new()
$script:ST_ATR             = 0.0
$script:ST_PrevHAClose     = 0.0
$script:ST_FinalUpperBand  = [double]::MaxValue
$script:ST_FinalLowerBand  = 0.0
$script:ST_Direction       = 0    # 0 = not computed, 1 = UP (bullish), -1 = DOWN (bearish)
$script:ST_SuperTrendValue = 0.0
$script:ST_Ready           = $false

# Restore position if script restarts
$PositionFile = Join-Path $PlacedOrdersDir 'CE-Position.json'
if (Test-Path $PositionFile) {
    $saved = Get-Content $PositionFile -Raw | ConvertFrom-Json
    Write-Host ""
    Write-Host "  Existing position found: $($saved.Symbol) | Strike: $($saved.Strike) | Qty: $($saved.Qty) | Entry: $($saved.Price) @ $($saved.Time)" -ForegroundColor Yellow
    $cleanup = Read-Host "  Do you want to cleanup old entries and start fresh? (y/n)"
    if ($cleanup -eq 'y' -or $cleanup -eq 'Y') {
        Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
        Write-Host "  Old position cleared. Starting fresh." -ForegroundColor Green
    } else {
        $script:CE_InPosition  = $true
        $script:CE_EntrySymbol = $saved.Symbol
        $script:CE_EntryToken  = $saved.Token
        $script:CE_EntryStrike = $saved.Strike
        $script:CE_EntryPrice  = $saved.Price
        $script:CE_EntryTime   = $saved.Time
        $script:CE_EntryQty    = if ($saved.Qty) { [int]$saved.Qty } else { $Quantity }
        $script:CE_EntryLots   = if ($saved.Lots) { [int]$saved.Lots } else { $NoOfLotsPurchaseAtaTime }
        $script:LongOrderPlaced = $true
        $script:LongEntryPrice  = $saved.Price
        Write-Host "  Resuming position: $($script:CE_EntrySymbol) | Strike: $($script:CE_EntryStrike) | Qty: $($script:CE_EntryQty)" -ForegroundColor Yellow
    }
}

# ================================================================
# HA helper functions
# ================================================================
function script:Get-STR-TimeBucket {
    $now = Get-Date
    $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
    $bucket = [Math]::Floor($totalSeconds / $script:STR_IntervalSeconds) * $script:STR_IntervalSeconds
    $bH = [int][Math]::Floor($bucket / 3600)
    $bM = [int][Math]::Floor(($bucket % 3600) / 60)
    $bS = [int]($bucket % 60)
    return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
}

function script:Convert-ToHA([hashtable]$rawCandle, [hashtable]$previousHA) {
    $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
    if ($null -ne $previousHA) {
        $haOpen = ($previousHA.Open + $previousHA.Close) / 2.0
    } else {
        $haOpen = ($rawCandle.Open + $rawCandle.Close) / 2.0
    }
    $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
    $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
    return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
}

# ================================================================
# SuperTrend computation on completed HA candle
# ================================================================
function script:Update-SuperTrend([double]$haHigh, [double]$haLow, [double]$haClose) {
    # True Range
    if ($script:ST_PrevHAClose -gt 0) {
        $tr = [Math]::Max($haHigh - $haLow, [Math]::Max([Math]::Abs($haHigh - $script:ST_PrevHAClose), [Math]::Abs($haLow - $script:ST_PrevHAClose)))
    } else {
        $tr = $haHigh - $haLow
    }
    if ($tr -le 0) { $tr = 0.01 }
    $script:ST_TRValues.Add($tr)

    if ($script:ST_TRValues.Count -lt $script:ST_Length) {
        $script:ST_PrevHAClose = $haClose
        return
    }

    # ATR (Wilder's RMA)
    if ($script:ST_TRValues.Count -eq $script:ST_Length) {
        $sum = 0.0
        for ($i = 0; $i -lt $script:ST_Length; $i++) { $sum += $script:ST_TRValues[$i] }
        $script:ST_ATR = $sum / $script:ST_Length
    } else {
        $script:ST_ATR = ($script:ST_ATR * ($script:ST_Length - 1) + $tr) / $script:ST_Length
    }

    # Basic bands
    $hl2 = ($haHigh + $haLow) / 2.0
    $basicUpper = $hl2 + $script:ST_Factor * $script:ST_ATR
    $basicLower = $hl2 - $script:ST_Factor * $script:ST_ATR

    if (-not $script:ST_Ready) {
        # First time — initialize
        $script:ST_FinalUpperBand = $basicUpper
        $script:ST_FinalLowerBand = $basicLower
        $script:ST_Direction = if ($haClose -gt $basicUpper) { 1 } else { -1 }
        $script:ST_SuperTrendValue = if ($script:ST_Direction -eq 1) { $script:ST_FinalLowerBand } else { $script:ST_FinalUpperBand }
        $script:ST_Ready = $true
        $script:ST_PrevHAClose = $haClose
        return
    }

    # Clamp bands using previous candle's final bands and previous close
    $prevFinalUpper = $script:ST_FinalUpperBand
    $prevFinalLower = $script:ST_FinalLowerBand

    # Lower band can only move UP when previous close was above it (support tightens)
    $finalLower = if ($script:ST_PrevHAClose -gt $prevFinalLower) { [Math]::Max($basicLower, $prevFinalLower) } else { $basicLower }
    # Upper band can only move DOWN when previous close was below it (resistance tightens)
    $finalUpper = if ($script:ST_PrevHAClose -lt $prevFinalUpper) { [Math]::Min($basicUpper, $prevFinalUpper) } else { $basicUpper }

    # Direction flip check (current close vs PREVIOUS final bands)
    if ($script:ST_Direction -eq -1 -and $haClose -gt $prevFinalUpper) {
        $script:ST_Direction = 1   # Flip DOWN → UP (BUY)
    } elseif ($script:ST_Direction -eq 1 -and $haClose -lt $prevFinalLower) {
        $script:ST_Direction = -1  # Flip UP → DOWN (SELL)
    }

    $script:ST_SuperTrendValue = if ($script:ST_Direction -eq 1) { $finalLower } else { $finalUpper }

    # Store for next candle
    $script:ST_FinalUpperBand = $finalUpper
    $script:ST_FinalLowerBand = $finalLower
    $script:ST_PrevHAClose = $haClose
}

# ================================================================
# CORE: SuperTrend signal check + IMMEDIATE order placement
# ================================================================
function script:Check-LongAndTrade([int]$instrumentToken, [double]$lastPrice) {
    if (-not $script:ST_Ready) { return }

    $currentRaw = $script:STR_ActiveCandle[$instrumentToken]
    if ($null -eq $currentRaw) { return }

    $prevHA = $script:STR_PreviousHA[$instrumentToken]
    $liveHA = script:Convert-ToHA $currentRaw $prevHA

    $now = Get-Date
    $timeStamp = $now.ToString('yyyy-MM-dd_HH-mm-ss')

    # Check trading window
    if ($now.TimeOfDay -lt $StartTime.TimeOfDay -or $now.TimeOfDay -gt $StopTime.TimeOfDay) { return }

    # ── LONG ENTRY: SuperTrend is DOWN and HA Close breaks above Upper Band ──
    if ((-not $script:LongOrderPlaced) -and ($script:ST_Direction -eq -1) -and ($liveHA.Close -gt $script:ST_FinalUpperBand)) {
        $script:LongOrderPlaced = $true
        $script:LongEntryPrice  = $lastPrice
        $script:LongEntryTime   = $timeStamp

        Write-Host ""
        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] *** SUPERTREND BUY SIGNAL *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) > Upper Band: $([Math]::Round($script:ST_FinalUpperBand,2))" -ForegroundColor Yellow

        # ── IMMEDIATE CE BUY ──
        $spotPrice = $lastPrice
        $atmOption = Get-ATMOption -SpotPrice $spotPrice -Options $ceOptions -AllStrikes $allStrikes -Offset (-$ATMOffset)

        if ($atmOption) {
            $entryQty = $Quantity
            $entryLots = $NoOfLotsPurchaseAtaTime
            if ($AmountToTrade -gt 0) {
                $optLTP = 0
                try {
                    $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$($atmOption.Symbol)"))" -Headers $headers -ErrorAction Stop
                    foreach ($p in $qr.data.PSObject.Properties) { $optLTP = $p.Value.last_price; break }
                } catch {}
                if ($optLTP -gt 0) {
                    $entryLots = [int][Math]::Floor($AmountToTrade / ($optLTP * $LotSize))
                    if ($entryLots -lt 1) { $entryLots = 1 }
                    $entryQty = $entryLots * $LotSize
                    Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] CE LTP: $optLTP | Amount: $AmountToTrade | Lots: $entryLots | Qty: $entryQty" -ForegroundColor Magenta
                } else {
                    Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] Could not fetch CE LTP, using fallback Qty: $entryQty" -ForegroundColor DarkYellow
                }
            }

            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] CE BUY | Strike: $($atmOption.Strike) | Symbol: $($atmOption.Symbol) | Qty: $entryQty" -ForegroundColor Cyan
            $result = Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
                -Tradingsymbol $atmOption.Symbol -Quantity $entryQty `
                -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "CE-ENTRY" -MarketProtection $MarketProtection

            if ($result) {
                $script:CE_InPosition   = $true
                $script:CE_EntrySymbol  = $atmOption.Symbol
                $script:CE_EntryToken   = $atmOption.Token
                $script:CE_EntryStrike  = $atmOption.Strike
                $script:CE_EntryPrice   = $spotPrice
                $script:CE_EntryTime    = $now.ToString('HH:mm:ss')
                $script:CE_EntryQty     = $entryQty
                $script:CE_EntryLots    = $entryLots
                @{ Symbol=$script:CE_EntrySymbol; Token=$script:CE_EntryToken; Strike=$script:CE_EntryStrike; Price=$script:CE_EntryPrice; Time=$script:CE_EntryTime; Qty=$script:CE_EntryQty; Lots=$script:CE_EntryLots } | ConvertTo-Json | Set-Content $PositionFile -Force
                $orderLatency = ((Get-Date) - $now).TotalMilliseconds
                Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] POSITION OPENED in ${orderLatency}ms | $($script:CE_EntrySymbol) | Strike: $($script:CE_EntryStrike) | Lots: $entryLots | Qty: $entryQty" -ForegroundColor Green
            } else {
                Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] CE BUY FAILED — resetting signal state" -ForegroundColor Red
                $script:LongOrderPlaced = $false
            }
        } else {
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] Could not find ATM CE option. Resetting." -ForegroundColor Red
            $script:LongOrderPlaced = $false
        }

        $script:StrategySignals.Add("ENTRY @ $lastPrice  CE: $($script:CE_EntrySymbol) ST-BUY ($timeStamp)")
    }

    # ── LONG EXIT: HA Close breaks below Lower Band ──
    if ($script:LongOrderPlaced -and $script:CE_InPosition -and ($liveHA.Close -lt $script:ST_FinalLowerBand)) {
        $pnl = $lastPrice - $script:LongEntryPrice

        Write-Host ""
        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] *** SUPERTREND SELL SIGNAL *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) < Lower Band: $([Math]::Round($script:ST_FinalLowerBand,2))" -ForegroundColor Yellow

        if ($ExitTrade -eq 'no') {
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] EXIT TRADE DISABLED (ExitTrade=no) — skipping SELL order, position stays open" -ForegroundColor DarkYellow
            return
        }

        # ── IMMEDIATE CE SELL ──
        $exitQty = $script:CE_EntryQty
        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] CE SELL | Symbol: $($script:CE_EntrySymbol) | Qty: $exitQty" -ForegroundColor Cyan
        $result = Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
            -Tradingsymbol $script:CE_EntrySymbol -Quantity $exitQty `
            -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "CE-EXIT" -MarketProtection $MarketProtection

        if (-not $result) {
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] CE SELL order failed but closing position state" -ForegroundColor DarkYellow
        } else {
            $orderLatency = ((Get-Date) - $now).TotalMilliseconds
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] POSITION CLOSED in ${orderLatency}ms | SELL $($script:CE_EntrySymbol) | P&L: $([Math]::Round($pnl,2))" -ForegroundColor Green
        }

        $script:StrategySignals.Add("EXIT  @ $lastPrice  P&L: $([Math]::Round($pnl,2)) ST-SELL ($timeStamp)")

        $script:LongOrderPlaced = $false
        $script:LongEntryPrice  = 0.0
        $script:LongEntryTime   = ''
        $script:CE_InPosition   = $false
        $script:CE_EntrySymbol  = ''
        $script:CE_EntryToken   = 0
        $script:CE_EntryStrike  = 0
        $script:CE_EntryPrice   = 0
        $script:CE_EntryTime    = ''
        $script:CE_EntryQty     = 0
        $script:CE_EntryLots    = 0
        Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
    }
}

# ================================================================
# Tick processing (builds HA candles + updates SuperTrend + checks signals)
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
            $closedHA = @{ Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close }
            $script:STR_PreviousHA[$instrumentToken] = $closedHA

            # Update SuperTrend with completed HA candle
            script:Update-SuperTrend $ha.High $ha.Low $ha.Close

            $stVal = if ($script:ST_Ready) { [Math]::Round($script:ST_SuperTrendValue, 2) } else { 0 }
            $stDir = $script:ST_Direction

            $script:STR_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
                SuperTrend=$stVal; STDirection=$stDir
            })
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

    # Check signal + trade on EVERY tick — zero delay
    script:Check-LongAndTrade $instrumentToken $lastPrice
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
        $prevHA = $script:STR_PreviousHA[$instrumentToken]
        $ha = script:Convert-ToHA $currentCandle $prevHA

        # Live SuperTrend value for display
        $liveST = 0; $liveSTDir = 0
        if ($script:ST_Ready) {
            $liveST = [Math]::Round($script:ST_SuperTrendValue, 2)
            $liveSTDir = $script:ST_Direction
            # Check if live candle would flip
            if ($script:ST_Direction -eq -1 -and $ha.Close -gt $script:ST_FinalUpperBand) { $liveSTDir = 1 }
            if ($script:ST_Direction -eq 1 -and $ha.Close -lt $script:ST_FinalLowerBand) { $liveSTDir = -1 }
        }

        $allCandles.Add([PSCustomObject]@{
            TimeBucket=$currentCandle.TimeBucket
            Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
            Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
            Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
            TicksInCandle=$currentCandle.TicksInCandle
            SuperTrend=$liveST; STDirection=$liveSTDir
        })
    }
    if ($allCandles.Count -eq 0) { return }

    $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
    $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

    $sb = [System.Text.StringBuilder]::new(2048)
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("  ===========================================================")
    $null = $sb.AppendLine("  $($config.SymbolLabel) - HA + SuperTrend Long + CE Auto-Trade")
    $null = $sb.AppendLine("  ===========================================================")
    $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TF: $($config.TimeFrame)")
    $null = $sb.AppendLine("  ST Params: Length=$($script:ST_Length)  Factor=$($script:ST_Factor)  |  ATR: $([Math]::Round($script:ST_ATR, 2))")
    if ($script:ST_Ready) {
        $dirStr = if ($script:ST_Direction -eq 1) { 'UP (Bullish)' } else { 'DOWN (Bearish)' }
        $null = $sb.AppendLine("  ST Value: $([Math]::Round($script:ST_SuperTrendValue, 2))  |  Direction: $dirStr  |  UB: $([Math]::Round($script:ST_FinalUpperBand, 2))  LB: $([Math]::Round($script:ST_FinalLowerBand, 2))")
    } else {
        $null = $sb.AppendLine("  ST Value: Warming up ($($script:ST_TRValues.Count)/$($script:ST_Length) candles)...")
    }
    if ($AmountToTrade -gt 0) {
        $null = $sb.AppendLine("  Trade   : Amount: $AmountToTrade  |  LotSize: $LotSize  |  Product: $Product")
    } else {
        $null = $sb.AppendLine("  Trade   : Lots: $NoOfLotsPurchaseAtaTime  |  Qty: $Quantity  |  Product: $Product")
    }
    $null = $sb.AppendLine("  Ticks   : $($script:STR_TickCount)  |  Window: $($StartTime.ToString('HH:mm:ss'))-$($StopTime.ToString('HH:mm:ss'))")
    $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
    $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')")

    if ($script:CE_InPosition) {
        $null = $sb.AppendLine("  POSITION: LONG ACTIVE  CE: $($script:CE_EntrySymbol)  Strike: $($script:CE_EntryStrike)  Lots: $($script:CE_EntryLots)  Qty: $($script:CE_EntryQty)  Entry: $($script:CE_EntryPrice.ToString('N2')) @ $($script:CE_EntryTime)")
        if ($null -ne $currentCandle) {
            $unrealizedPnL = $currentCandle.Close - $script:LongEntryPrice
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized P&L: $($unrealizedPnL.ToString('N2'))")
        }
    } else {
        $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for SuperTrend BUY signal)")
        if ($null -ne $currentCandle) {
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
        }
    }

    $null = $sb.AppendLine('')
    $rowFormat = ' {0,-18} {1,12} {2,12} {3,12} {4,12} {5,12} {6,5} {7,5}'
    $null = $sb.AppendLine(($rowFormat -f 'Time','HA Open','HA High','HA Low','HA Close','SuperTrend','Ticks','STDir'))
    $null = $sb.AppendLine(' ' + ('-' * 95))

    Clear-Host
    Write-Host $sb.ToString()

    for ($rowIndex = 0; $rowIndex -lt $visibleCandles.Count; $rowIndex++) {
        $candle = $visibleCandles[$rowIndex]
        $stDirStr = if ($candle.STDirection -eq 1) { '  UP' } elseif ($candle.STDirection -eq -1) { 'DOWN' } else { '  --' }
        $color = if ($candle.STDirection -eq 1) { 'Green' } elseif ($candle.STDirection -eq -1) { 'Red' } else { 'Gray' }
        $stStr = if ($candle.SuperTrend -gt 0) { '{0:N2}' -f $candle.SuperTrend } else { '       --' }
        $line = $rowFormat -f $candle.TimeBucket, ('{0:N2}' -f $candle.Open), ('{0:N2}' -f $candle.High), ('{0:N2}' -f $candle.Low), ('{0:N2}' -f $candle.Close), $stStr, $candle.TicksInCandle, $stDirStr
        if ($rowIndex -eq ($visibleCandles.Count - 1)) {
            Write-Host $line -ForegroundColor Yellow
        } else {
            Write-Host $line -ForegroundColor $color
        }
    }

    if ($script:StrategySignals.Count -gt 0) {
        Write-Host ''
        Write-Host '  --- Trade Signals ---' -ForegroundColor Cyan
        $showCount = [Math]::Min(5, $script:StrategySignals.Count)
        for ($si = $script:StrategySignals.Count - $showCount; $si -lt $script:StrategySignals.Count; $si++) {
            $sigColor = if ($script:StrategySignals[$si] -match 'ENTRY') { 'Green' } else { 'Red' }
            Write-Host "    $($script:StrategySignals[$si])" -ForegroundColor $sigColor
        }
    }

    Write-Host ''
    Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
}

# ================================================================
# Force-exit at stop time
# ================================================================
function script:Force-ExitAtStopTime {
    if ($script:CE_InPosition -and $script:CE_EntrySymbol) {
        $now = Get-Date
        Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME — Force exiting: $($script:CE_EntrySymbol)" -ForegroundColor Red
        $forceQty = if ($script:CE_EntryQty -gt 0) { $script:CE_EntryQty } else { $Quantity }
        Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
            -Tradingsymbol $script:CE_EntrySymbol -Quantity $forceQty `
            -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "CE-TIMEEXIT" -MarketProtection $MarketProtection
        $script:CE_InPosition   = $false
        $script:CE_EntrySymbol  = ''
        $script:LongOrderPlaced = $false
        Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
    }
}

# ================================================================
# WebSocket — stream ticks and process everything inline
# ================================================================
$wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host '  ==============================================================' -ForegroundColor Cyan
Write-Host '  COMBINED: HA + SuperTrend Long + CE Auto-Trade (Zero Latency)' -ForegroundColor Cyan
Write-Host '  ==============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym)"
Write-Host "  Token    : $instToken"
Write-Host "  TimeFrame: $TimeFrame ($intLabel candles)"
Write-Host "  SuperTrend: Length=$STLength  Factor=$STFactor"
if ($AmountToTrade -gt 0) {
    Write-Host "  Trade    : Amount: $AmountToTrade | LotSize: $LotSize | Lots: Dynamic"
} else {
    Write-Host "  Trade    : Lots: $NoOfLotsPurchaseAtaTime | Qty: $Quantity"
}
Write-Host "  Expiry   : $nearestExpiry | CE Strikes: $($allStrikes.Count)"
Write-Host "  Product  : $Product | Order: $Order_type | Mode: $modeStr"
Write-Host "  Window   : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss'))"
Write-Host ''
Write-Host '  Connecting...' -ForegroundColor Yellow

$maxRetries = 3
$retryCount = 0
$buf = New-Object byte[] 65536

while ($retryCount -le $maxRetries) {
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader('X-Kite-Version', '3')
    $cts = [System.Threading.CancellationTokenSource]::new()

    try {
        $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
        if (-not $ct.Wait(15000)) {
            Write-Host '  Connection timed out.' -ForegroundColor Red
            $retryCount++
            if ($retryCount -le $maxRetries) {
                $wait = $retryCount * 5
                Write-Host "  Retrying in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                continue
            }
            script:Force-ExitAtStopTime
            exit 1
        }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host "  Connection failed. State: $($ws.State)" -ForegroundColor Red
            script:Force-ExitAtStopTime
            exit 1
        }

        $retryCount = 0
        Write-Host '  Connected!' -ForegroundColor Green

        $subB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"subscribe","v":[' + $instToken + ']}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($subB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        Write-Host "  Subscribed to $label" -ForegroundColor Green

        $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["' + $modeStr + '",[' + $instToken + ']]}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        Write-Host "  Mode: $modeStr" -ForegroundColor Green
        Write-Host ''
        Write-Host '  Waiting for market ticks...' -ForegroundColor Yellow

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay) {
                script:Force-ExitAtStopTime
                Write-Host "  Stop time reached. Exiting." -ForegroundColor Yellow
                break
            }

            $seg = [System.ArraySegment[byte]]::new($buf)
            try {
                $rt = $ws.ReceiveAsync($seg, $cts.Token)
                if (-not $rt.Wait(30000)) { continue }
                $res = $rt.Result
            } catch {
                if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
                continue
            }

            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                Write-Host '  Server closed connection.' -ForegroundColor Yellow; break
            }
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                if ($res.Count -gt 1) {
                    $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
                    try { $jm = $txt | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($jm.type -eq 'error') { Write-Host "  ERROR: $($jm.data)" -ForegroundColor Red } } catch {}
                }
                continue
            }
            if (($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) -and ($res.Count -gt 2)) {
                $ticks = Parse-KiteTicks $buf $res.Count
                foreach ($tick in $ticks) {
                    if ($tick.LastPrice -gt 0) {
                        script:Update-StrategyFromTick $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest
                    }
                }
                script:Render-StrategyDisplay $instToken
            }
        }

        if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay) { break }

        $retryCount++
        if ($retryCount -le $maxRetries) {
            $wait = $retryCount * 5
            Write-Host "  Connection lost. Reconnecting in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) { Write-Host "  Detail: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
        $retryCount++
        if ($retryCount -le $maxRetries) {
            $wait = $retryCount * 5
            Write-Host "  Retrying in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    finally {
        if ($ws -and ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open)) {
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done', $cts.Token).Wait(5000) } catch {}
        }
        if ($ws)  { $ws.Dispose() }
        if ($cts) { $cts.Dispose() }
    }
}

Write-Host ''
Write-Host '  Disconnected.' -ForegroundColor Yellow
Write-Host "  Total Trades: $($script:StrategySignals.Count)" -ForegroundColor Gray
foreach ($sig in $script:StrategySignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
Write-Host ''
