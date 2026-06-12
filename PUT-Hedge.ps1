<#
.SYNOPSIS
  Combined HA Short Signal + PE Option Auto-Trade (zero-latency).
.DESCRIPTION
  Streams live HA candles via Kite WebSocket. When the HA short entry
  condition fires, immediately places a PE BUY order in the same tick
  — no file I/O, no polling delay. Exit is equally instant.

  This replaces running Short-SignalGenerator.ps1 + PE-BUY.ps1 separately.
.EXAMPLE
  .\Short-PE-Combined.ps1
  .\Short-PE-Combined.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
  .\Short-PE-Combined.ps1 -TradingSymbol SENSEX -IndexChoosen SENSEX -TimeFrame 15second
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

    # PE-BUY params
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
    [string]$ExitTrade
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
    # Re-validate new token
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
# PE Option setup
# ================================================================
$IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots $NoOfLotsPurchaseAtaTime
if (-not $IndexConfig) { exit 1 }

$exchange       = $IndexConfig.exchange
$optExchange    = $IndexConfig.OptExchange
$LotSize        = $IndexConfig.Lot
$underlyingName = $IndexConfig.SearchKeyWord

# Quantity will be calculated dynamically at entry if AmountToTrade is set
$Quantity = $IndexConfig.Quantity  # fallback if AmountToTrade is 0

Write-Host ""
Write-Host "  Fetching $optExchange PE instruments..." -ForegroundColor Yellow

$optData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'PE' -Headers $headers
if (-not $optData) { exit 1 }

$peOptions     = $optData.Options
$allStrikes    = $optData.Strikes
$nearestExpiry = $optData.Expiry

Write-Host "  Expiry: $nearestExpiry | PE Strikes: $($allStrikes.Count) | Lot Size: $($peOptions[0].LotSize)" -ForegroundColor Green

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

$script:StrategySignals   = [System.Collections.Generic.List[string]]::new()
$script:ShortEntryPrice   = 0.0  # For unrealized P&L display
$script:PE_TotalPnL       = 0
$script:LastPositionStatus = $null  # Cached Check-AlreadyAnyOrderRunning result

# ================================================================
# Auto-detect existing positions at startup (no user prompt)
# ================================================================
Write-Host ''
Write-Host '  Checking for existing open positions...' -ForegroundColor Yellow
$startupPositions = Check-AlreadyAnyOrderRunning -SearchKeyWord $underlyingName -NoOfLotsPurchaseAtaTime $NoOfLotsPurchaseAtaTime -Headers $headers
if ($null -ne $startupPositions -and @($startupPositions).Count -gt 0) {
    $startupDownTrend = $startupPositions | Where-Object { $_.Type -eq 'DownTrend' }
    if ($startupDownTrend.Running -eq $true) {
        # Existing PE position found — resume tracking
        $spotQuoteKey = "$($exchange):$($TradingSymbol)"
        $currentSpot = Get-KiteSpotPrice -SpotQuoteKey $spotQuoteKey -Headers $headers
        if ($currentSpot -gt 0) {
            $script:ShortEntryPrice = $currentSpot
        }
        $script:LastPositionStatus = $startupDownTrend
        Write-Host "  RESUMING — Existing PE position detected: $($startupDownTrend.TradingSymbols) | Qty: $($startupDownTrend.RunningQuantity) | Current Spot: $($currentSpot.ToString('N2'))" -ForegroundColor Green
        $script:StrategySignals.Add("RESUME @ $currentSpot  PE: $($startupDownTrend.TradingSymbols) ($(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))")
    } else {
        Write-Host '  No existing PE position found. Starting fresh.' -ForegroundColor DarkGray
    }
} else {
    Write-Host '  No existing positions found. Starting fresh.' -ForegroundColor DarkGray
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
# CORE: Signal check + IMMEDIATE order placement (no file I/O)
# ================================================================
function script:Check-ShortAndTrade([int]$instrumentToken, [double]$lastPrice) {
    $completedList = $script:STR_CompletedCandles[$instrumentToken]
    if (-not $completedList -or $completedList.Count -lt 1) { return }

    $previousCandle = $completedList[$completedList.Count - 1]
    $currentRaw = $script:STR_ActiveCandle[$instrumentToken]
    if ($null -eq $currentRaw) { return }

    $prevHA = $script:STR_PreviousHA[$instrumentToken]
    $liveHA = script:Convert-ToHA $currentRaw $prevHA

    $now = Get-Date
    $timeStamp = $now.ToString('yyyy-MM-dd_HH-mm-ss')

    # Check trading window
    if ($now.TimeOfDay -lt $StartTime.TimeOfDay -or $now.TimeOfDay -gt $StopTime.TimeOfDay) { return }

    # ── Check position state via API (single source of truth) ──
    $existingPositions = Check-AlreadyAnyOrderRunning -SearchKeyWord $underlyingName -NoOfLotsPurchaseAtaTime $NoOfLotsPurchaseAtaTime -Headers $headers
    if ($null -eq $existingPositions -or @($existingPositions).Count -eq 0) {
        return
    }
    $downTrendStatus = $existingPositions | Where-Object { $_.Type -eq 'DownTrend' }
    $script:LastPositionStatus = $downTrendStatus

    # ── SHORT ENTRY: HA Close < previous HA Low ──
    if (($downTrendStatus.Running -ne $true) -and ($liveHA.Close -lt $previousCandle.Low)) {

        $script:ShortEntryPrice  = $lastPrice

        Write-Host ""
        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT ENTRY SIGNAL *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) < Prev Low: $($previousCandle.Low)" -ForegroundColor Yellow

        # ── IMMEDIATE PE BUY ──
        $spotPrice = $lastPrice  # Use WebSocket LTP directly — zero extra API call latency
        $atmOption = Get-ATMOption -SpotPrice $spotPrice -Options $peOptions -AllStrikes $allStrikes -Offset $ATMOffset

        if ($atmOption) {
            # Dynamic lot calculation based on AmountToTrade
            $entryQty = $Quantity  # fallback to fixed lots
            $entryLots = $NoOfLotsPurchaseAtaTime
            $optLTP = 0
            if ($AmountToTrade -gt 0) {
                try {
                    $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$($atmOption.Symbol)"))" -Headers $headers -ErrorAction Stop
                    foreach ($p in $qr.data.PSObject.Properties) { $optLTP = $p.Value.last_price; break }
                } catch {}
                if ($optLTP -gt 0) {
                    $entryLots = [int][Math]::Floor($AmountToTrade / ($optLTP * $LotSize))
                    if ($entryLots -lt 1) { $entryLots = 1 }
                    $entryQty = $entryLots * $LotSize
                    Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] PE LTP: $optLTP | Amount: $AmountToTrade | Lots: $entryLots | Qty: $entryQty" -ForegroundColor Magenta
                } else {
                    Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] Could not fetch PE LTP, using fallback Qty: $entryQty" -ForegroundColor DarkYellow
                }
            }

            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] PE BUY | Strike: $($atmOption.Strike) | Symbol: $($atmOption.Symbol) | Qty: $entryQty" -ForegroundColor Cyan
            $result = Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
                -Tradingsymbol $atmOption.Symbol -Quantity $entryQty `
                -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "PE-ENTRY" -MarketProtection $MarketProtection

            if ($result) {
                $orderLatency = ((Get-Date) - $now).TotalMilliseconds
                Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] POSITION OPENED in ${orderLatency}ms | $($atmOption.Symbol) | Strike: $($atmOption.Strike) | Lots: $entryLots | Qty: $entryQty" -ForegroundColor Green
            } else {
                Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] PE BUY FAILED" -ForegroundColor Red
                $script:ShortEntryPrice = 0.0
            }
        } else {
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] Could not find ATM PE option." -ForegroundColor Red
            $script:ShortEntryPrice = 0.0
        }

        if ($script:ShortEntryPrice -gt 0) {
            $script:StrategySignals.Add("ENTRY @ $lastPrice  PE: $($atmOption.Symbol) ($timeStamp)")
        }
    }

    # ── SHORT EXIT: HA Close > previous HA High ──
    if (($downTrendStatus.Running -eq $true) -and ($liveHA.Close -gt $previousCandle.High)) {
        $pnl = $script:ShortEntryPrice - $lastPrice

        Write-Host ""
        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT EXIT SIGNAL *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) > Prev High: $($previousCandle.High)" -ForegroundColor Yellow

        if ($ExitTrade -eq 'no') {
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] EXIT TRADE DISABLED (ExitTrade=no) — skipping SELL order, position stays open" -ForegroundColor DarkYellow
            return
        }

        # ── IMMEDIATE PE SELL (use symbol & qty from API) ──
        $exitSymbol = $downTrendStatus.TradingSymbols
        $exitQty    = $downTrendStatus.RunningQuantity
        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] PE SELL | Symbol: $exitSymbol | Qty: $exitQty" -ForegroundColor Cyan
        $result = Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
            -Tradingsymbol $exitSymbol -Quantity $exitQty `
            -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "PE-EXIT" -MarketProtection $MarketProtection

        if ($result) {
            $orderLatency = ((Get-Date) - $now).TotalMilliseconds
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] POSITION CLOSED in ${orderLatency}ms | SELL $exitSymbol | Spot P&L: $([Math]::Round($pnl,2)) | Total P&L: $($script:PE_TotalPnL.ToString('N2'))" -ForegroundColor Green
        } else {
            Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] PE SELL order failed" -ForegroundColor DarkYellow
        }

        $script:StrategySignals.Add("EXIT  @ $lastPrice  P&L: $([Math]::Round($pnl,2)) ($timeStamp)")
        $script:ShortEntryPrice  = 0.0
    }
}

# ================================================================
# Tick processing (builds HA candles + checks signals)
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

            $script:STR_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
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
    script:Check-ShortAndTrade $instrumentToken $lastPrice
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
        $allCandles.Add([PSCustomObject]@{
            TimeBucket=$currentCandle.TimeBucket
            Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
            Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
            Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
            TicksInCandle=$currentCandle.TicksInCandle
        })
    }
    if ($allCandles.Count -eq 0) { return }

    $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
    $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

    $sb = [System.Text.StringBuilder]::new(2048)
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("  ================================================")
    $null = $sb.AppendLine("  $($config.SymbolLabel) - HA Short + PE Auto-Trade (COMBINED)")
    $null = $sb.AppendLine("  ================================================")
    $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TF: $($config.TimeFrame)")
    if ($AmountToTrade -gt 0) {
        $null = $sb.AppendLine("  Trade   : Amount: $AmountToTrade  |  LotSize: $LotSize  |  Product: $Product")
    } else {
        $null = $sb.AppendLine("  Trade   : Lots: $NoOfLotsPurchaseAtaTime  |  Qty: $Quantity  |  Product: $Product")
    }
    $null = $sb.AppendLine("  Ticks   : $($script:STR_TickCount)  |  Window: $($StartTime.ToString('HH:mm:ss'))-$($StopTime.ToString('HH:mm:ss'))  |  Total P&L: $($script:PE_TotalPnL.ToString('N2'))")
    $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
    $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')")

    $posStatus = $script:LastPositionStatus
    if ($posStatus -and $posStatus.Running -eq $true) {
        $null = $sb.AppendLine("  POSITION: SHORT ACTIVE  PE: $($posStatus.TradingSymbols)  Qty: $($posStatus.RunningQuantity)  Entry Spot: $($script:ShortEntryPrice.ToString('N2'))")
        if ($null -ne $currentCandle) {
            $unrealizedPnL = $script:ShortEntryPrice - $currentCandle.Close
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized Spot P&L: $($unrealizedPnL.ToString('N2'))")
        }
    } else {
        $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for Short Entry signal)")
        if ($null -ne $currentCandle) {
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
        }
    }

    $null = $sb.AppendLine('')
    $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,5} {7,6}'
    $null = $sb.AppendLine(($rowFormat -f 'Time','HA Open','HA High','HA Low','HA Close','Volume','Ticks','Trend'))
    $null = $sb.AppendLine(' ' + ('-' * 102))

    Clear-Host
    Write-Host $sb.ToString()

    for ($rowIndex = 0; $rowIndex -lt $visibleCandles.Count; $rowIndex++) {
        $candle = $visibleCandles[$rowIndex]
        $trend = if ($candle.Close -ge $candle.Open) { '  UP' } else { 'DOWN' }
        $color = if ($candle.Close -ge $candle.Open) { 'Green' } else { 'Red' }
        $line = $rowFormat -f $candle.TimeBucket, ('{0:N2}' -f $candle.Open), ('{0:N2}' -f $candle.High), ('{0:N2}' -f $candle.Low), ('{0:N2}' -f $candle.Close), ('{0:N0}' -f $candle.Volume), $candle.TicksInCandle, $trend
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
    $now = Get-Date
    $existingPositions = Check-AlreadyAnyOrderRunning -SearchKeyWord $underlyingName -NoOfLotsPurchaseAtaTime $NoOfLotsPurchaseAtaTime -Headers $headers
    if ($null -eq $existingPositions -or @($existingPositions).Count -eq 0) { return }
    $downTrendStatus = $existingPositions | Where-Object { $_.Type -eq 'DownTrend' }
    if ($downTrendStatus.Running -eq $true) {
        if ($ExitTrade -eq 'no') {
            Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME — EXIT TRADE DISABLED (ExitTrade=no) — position stays open: $($downTrendStatus.TradingSymbols)" -ForegroundColor DarkYellow
            return
        }
        $exitSymbol = $downTrendStatus.TradingSymbols
        $exitQty    = $downTrendStatus.RunningQuantity
        Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME — Force exiting: $exitSymbol | Qty: $exitQty" -ForegroundColor Red
        Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
            -Tradingsymbol $exitSymbol -Quantity $exitQty `
            -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "PE-TIMEEXIT" -MarketProtection $MarketProtection
        $script:ShortEntryPrice = 0.0
    }
}

# ================================================================
# WebSocket — stream ticks and process everything inline
# ================================================================
$wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  COMBINED: HA Short Signal + PE Auto-Trade (Zero File Latency)' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym)"
Write-Host "  Token    : $instToken"
Write-Host "  TimeFrame: $TimeFrame ($intLabel candles)"
if ($AmountToTrade -gt 0) {
    Write-Host "  Trade    : Amount: $AmountToTrade | LotSize: $LotSize | Lots: Dynamic"
} else {
    Write-Host "  Trade    : Lots: $NoOfLotsPurchaseAtaTime | Qty: $Quantity"
}
Write-Host "  Expiry   : $nearestExpiry | PE Strikes: $($allStrikes.Count)"
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
            # Check stop time
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

        # If stop time triggered the break, exit cleanly
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
Write-Host "  Total Trades: $($script:StrategySignals.Count) | Total P&L: $($script:PE_TotalPnL.ToString('N2'))" -ForegroundColor Gray
foreach ($sig in $script:StrategySignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
Write-Host ''
