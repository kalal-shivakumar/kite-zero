<#
.SYNOPSIS
  Combined HA Long+Short Signal with CE+PE Option Auto-Trade (zero-latency).
.DESCRIPTION
  Streams live HA candles via Kite WebSocket. Trades both directions:
  - Long entry (HA Close > prev High) -> BUY CE, exit when HA Close < prev Low -> SELL CE
  - Short entry (HA Close < prev Low) -> BUY PE, exit when HA Close > prev High -> SELL PE
  Only one direction is active at a time.
.EXAMPLE
  .\Long-Short-Combined.ps1
  .\Long-Short-Combined.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute
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
    [string]$ExitTrade
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
# Strategy state
# ================================================================
$script:STR_CompletedCandles  = @{}
$script:STR_ActiveCandle      = @{}
$script:STR_PreviousHA        = @{}
$script:STR_TickCount         = 0
$script:STR_IntervalSeconds   = $intSec
$script:STR_DisplayConfig     = @{ SymbolName=$sym; SymbolLabel=$label; InstrumentToken=$instToken; TimeFrame=$TimeFrame; IntervalLabel=$intLabel; MaxCandles=$CandlesToShow }
$script:STR_LastDisplayTime   = [datetime]::MinValue
$script:STR_DisplayIntervalMs = 250
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

# Restore position
$PositionFile = Join-Path $PlacedOrdersDir 'Position.json'
if (Test-Path $PositionFile) {
    $saved = Get-Content $PositionFile -Raw | ConvertFrom-Json
    Write-Host "`n  Existing position: $($saved.Direction) | $($saved.Symbol) | Strike: $($saved.Strike) | Qty: $($saved.Qty) @ $($saved.Time)" -ForegroundColor Yellow
    $cleanup = Read-Host "  Cleanup old entry and start fresh? (y/n)"
    if ($cleanup -eq 'y' -or $cleanup -eq 'Y') {
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
        Write-Host "  Resuming: $($script:Direction) | $($script:OptSymbol) | Qty: $($script:OptQty)" -ForegroundColor Yellow
    }
}

# ================================================================
# HA helpers
# ================================================================
function script:Get-STR-TimeBucket {
    $now = Get-Date
    $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
    $bucket = [Math]::Floor($totalSeconds / $script:STR_IntervalSeconds) * $script:STR_IntervalSeconds
    $bH = [int][Math]::Floor($bucket / 3600); $bM = [int][Math]::Floor(($bucket % 3600) / 60); $bS = [int]($bucket % 60)
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
# Helper: Enter position
# ================================================================
function script:Enter-Position([string]$dir, [double]$spotPrice, [string]$timeStamp) {
    $optType = if ($dir -eq 'LONG') { 'CE' } else { 'PE' }
    $options = if ($dir -eq 'LONG') { $ceOptions } else { $peOptions }
    $strikes = if ($dir -eq 'LONG') { $ceStrikes } else { $peStrikes }
    $offset  = if ($dir -eq 'LONG') { -$ATMOffset } else { $ATMOffset }
    $tag     = "$optType-ENTRY"

    $atmOption = Get-ATMOption -SpotPrice $spotPrice -Options $options -AllStrikes $strikes -Offset $offset
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
        @{ Direction=$dir; Symbol=$script:OptSymbol; Token=$script:OptToken; Strike=$script:OptStrike; Price=$spotPrice; Time=$timeStamp; OptionLTP=$optLTP; TotalPnL=$script:TotalPnL; Qty=$entryQty; Lots=$entryLots; OptType=$optType } | ConvertTo-Json | Set-Content $PositionFile -Force
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
    Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
}

# ================================================================
# CORE: Check signals + trade
# ================================================================
function script:Check-SignalAndTrade([int]$instrumentToken, [double]$lastPrice) {
    $completedList = $script:STR_CompletedCandles[$instrumentToken]
    if (-not $completedList -or $completedList.Count -lt 1) { return }

    $prev = $completedList[$completedList.Count - 1]
    $currentRaw = $script:STR_ActiveCandle[$instrumentToken]
    if ($null -eq $currentRaw) { return }

    $liveHA = script:Convert-ToHA $currentRaw ($script:STR_PreviousHA[$instrumentToken])

    $now = Get-Date
    if ($now.TimeOfDay -lt $StartTime.TimeOfDay -or $now.TimeOfDay -gt $StopTime.TimeOfDay) { return }
    $timeStamp = $now.ToString('yyyy-MM-dd_HH-mm-ss')

    # -- LONG ENTRY: HA Close > prev High (only if flat) --
    if ($script:Direction -eq '' -and $liveHA.Close -gt $prev.High) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** LONG ENTRY *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) > Prev High: $($prev.High)" -ForegroundColor Yellow
        $ok = script:Enter-Position 'LONG' $lastPrice $timeStamp
        if ($ok) { $script:StrategySignals.Add("ENTRY LONG @ $lastPrice  CE: $($script:OptSymbol) ($timeStamp)") }
        return
    }

    # -- SHORT ENTRY: HA Close < prev Low (only if flat) --
    if ($script:Direction -eq '' -and $liveHA.Close -lt $prev.Low) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT ENTRY *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) < Prev Low: $($prev.Low)" -ForegroundColor Yellow
        $ok = script:Enter-Position 'SHORT' $lastPrice $timeStamp
        if ($ok) { $script:StrategySignals.Add("ENTRY SHORT @ $lastPrice  PE: $($script:OptSymbol) ($timeStamp)") }
        return
    }

    # -- LONG EXIT: HA Close < prev Low --
    if ($script:Direction -eq 'LONG' -and $liveHA.Close -lt $prev.Low) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** LONG EXIT *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) < Prev Low: $($prev.Low)" -ForegroundColor Yellow
        script:Exit-Position $lastPrice $timeStamp
        return
    }

    # -- SHORT EXIT: HA Close > prev High --
    if ($script:Direction -eq 'SHORT' -and $liveHA.Close -gt $prev.High) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT EXIT *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) > Prev High: $($prev.High)" -ForegroundColor Yellow
        script:Exit-Position $lastPrice $timeStamp
        return
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
    $null = $sb.AppendLine("  $($config.SymbolLabel) - HA Long+Short | CE+PE Auto-Trade")
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

    if ($script:Direction -ne '') {
        $null = $sb.AppendLine("  POSITION: $($script:Direction) ACTIVE  $($script:OptType): $($script:OptSymbol)  Strike: $($script:OptStrike)  Lots: $($script:OptLots)  Qty: $($script:OptQty)  Entry: $($script:EntryPrice.ToString('N2')) @ $($script:EntryTime)  OptLTP: $($script:OptEntryLTP)")
        if ($null -ne $currentCandle) {
            $unrealized = if ($script:Direction -eq 'LONG') { $currentCandle.Close - $script:EntryPrice } else { $script:EntryPrice - $currentCandle.Close }
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized Spot P&L: $($unrealized.ToString('N2'))")
        }
    } else {
        $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for signal)")
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

    for ($i = 0; $i -lt $visibleCandles.Count; $i++) {
        $c = $visibleCandles[$i]
        $trend = if ($c.Close -ge $c.Open) { '  UP' } else { 'DOWN' }
        $color = if ($c.Close -ge $c.Open) { 'Green' } else { 'Red' }
        $line = $rowFormat -f $c.TimeBucket, ('{0:N2}' -f $c.Open), ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), ('{0:N0}' -f $c.Volume), $c.TicksInCandle, $trend
        Write-Host $line -ForegroundColor $(if ($i -eq $visibleCandles.Count - 1) { 'Yellow' } else { $color })
    }

    if ($script:StrategySignals.Count -gt 0) {
        Write-Host ''; Write-Host '  --- Trade Signals ---' -ForegroundColor Cyan
        $show = [Math]::Min(8, $script:StrategySignals.Count)
        for ($si = $script:StrategySignals.Count - $show; $si -lt $script:StrategySignals.Count; $si++) {
            $sigColor = if ($script:StrategySignals[$si] -match 'ENTRY') { 'Green' } else { 'Red' }
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

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay) {
                script:Force-ExitAtStopTime; Write-Host "  Stop time reached." -ForegroundColor Yellow; break
            }

            $seg = [System.ArraySegment[byte]]::new($buf)
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
                script:Render-StrategyDisplay $instToken
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
