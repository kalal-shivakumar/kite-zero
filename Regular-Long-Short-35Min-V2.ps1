<#
.SYNOPSIS
  Regular-candle Long+Short offset strategy (default 35-minute candles) with CE+PE option auto-trade
  and per-position stop-loss handling when ExitTrade = no.
.DESCRIPTION
  Signals use the forming regular candle: Close >= Open + OffsetPoints is GREEN, Close <= Open - OffsetPoints is RED.

  ExitTrade = yes
    - GREEN -> BUY CE. RED while CE is open -> market SELL CE, then BUY PE (and vice versa).
    - No stop-loss orders. Every open position is market-closed when the candle closes.

  ExitTrade = no
    - GREEN -> BUY CE and place a SELL SL order; RED -> BUY PE and place a SELL SL order.
    - SL level comes from the bought option's live LTP right after entry (no historical API):
      trigger = round(LTP * (1 - SLTriggerPercentage/100)) as a whole number (SLTriggerPercentage from input.json), price = trigger - SLPriceGap (default 2).
    - The opposite colour does NOT close anything (the SL is the protection); a CE and a PE can be open together,
      at most one per side.
    - When the candle closes: the bot's own SL orders are cancelled first, then each open position is market-sold.
    - A position whose SL already filled is not sold again.

  Both modes: everything is closed at the candle close and never later than ForceExitTime (default 15:20).
  On start, positions/SLs from a previous run are not resumed.
.EXAMPLE
  .\Regular-Long-Short-35Min-V2.ps1 -ExitTrade no
#>

param(
    [string]$TradingSymbol,
    [int]$InstrumentToken,
    [ValidateSet('5second','15second','30second','minute','2minute','3minute','4minute','5minute','10minute','15minute','30minute','35minute','60minute')]
    [string]$TimeFrame = '35minute',
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
    [datetime]$ForceExitTime,
    [string]$Order_type,
    [ValidateSet('Option_Buyer','Option_Seller')]
    [string]$ModeOfTrading,
    [int]$ATMOffset,
    [string]$Variety,
    [int]$MarketProtection,
    [ValidateSet('yes','no')]
    [string]$ExitTrade,
    [double]$OffsetPoints,
    [int]$MaxRetryCountOnBar,
    [int]$SLPriceGap = 2,
    [double]$SLTriggerPercentage,
    [ValidateSet('yes','no','auto')]
    [string]$CleanupPosition = 'auto'
)

# ================================================================
# Module & Config
# ================================================================
$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force -WarningAction SilentlyContinue

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) { Write-Host '  ERROR: input.json not found.' -ForegroundColor Red; exit 1 }
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

if (-not $PSBoundParameters.ContainsKey('TradingSymbol'))  { $TradingSymbol  = $cfg.TradingSymbol }
if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
if (-not $PSBoundParameters.ContainsKey('CandlesToShow'))  { $CandlesToShow  = if ($cfg.CandlesToShow) { [int]$cfg.CandlesToShow } else { 10 } }
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
if (-not $PSBoundParameters.ContainsKey('ForceExitTime'))           { $ForceExitTime = if ($cfg.ForceExitTime) { [datetime]$cfg.ForceExitTime } else { [datetime]'15:20:00' } }
if (-not $PSBoundParameters.ContainsKey('Order_type'))              { $Order_type    = $cfg.Order_type }
if (-not $PSBoundParameters.ContainsKey('ModeOfTrading'))           { $ModeOfTrading = $cfg.ModeOfTrading }
if (-not $PSBoundParameters.ContainsKey('ATMOffset'))               { $ATMOffset     = [int]$cfg.ATMOffset }
if (-not $PSBoundParameters.ContainsKey('Variety'))                 { $Variety       = if ($cfg.Variety) { $cfg.Variety } else { 'regular' } }
if (-not $PSBoundParameters.ContainsKey('MarketProtection'))        { $MarketProtection = if ($cfg.MarketProtection) { [int]$cfg.MarketProtection } else { 3 } }
if (-not $PSBoundParameters.ContainsKey('ExitTrade'))               { $ExitTrade     = if ($cfg.ExitTrade) { $cfg.ExitTrade } else { 'yes' } }
if (-not $PSBoundParameters.ContainsKey('OffsetPoints'))            { $OffsetPoints  = if ($null -ne $cfg.OffsetPoints) { [double]$cfg.OffsetPoints } else { 5 } }
if (-not $PSBoundParameters.ContainsKey('MaxRetryCountOnBar'))      { $MaxRetryCountOnBar = if ($cfg.MaxRetryCountOnBar) { [int]$cfg.MaxRetryCountOnBar } else { 10 } }
if (-not $PSBoundParameters.ContainsKey('SLTriggerPercentage'))     { $SLTriggerPercentage = if ($null -ne $cfg.SLTriggerPercentage) { [double]$cfg.SLTriggerPercentage } else { 0 } }
# The stop-loss % has no built-in default: it must come from input.json (or -SLTriggerPercentage) when ExitTrade=no
if ($ExitTrade -eq 'no' -and ($SLTriggerPercentage -lt 0.5 -or $SLTriggerPercentage -gt 50)) {
    Write-Host "  ERROR: SLTriggerPercentage must be set between 0.5 and 50 in input.json (current: $SLTriggerPercentage)." -ForegroundColor Red; exit 1
}
if ($ExitTrade -eq 'no' -and $SLPriceGap -lt 1) { Write-Host '  ERROR: SLPriceGap must be >= 1.' -ForegroundColor Red; exit 1 }
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
# Resolve symbol + option chains
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
$nearestExpiry = $ceData.Expiry
Write-Host "  Expiry: $nearestExpiry | CE: $($ceData.Strikes.Count) strikes | PE: $($peData.Strikes.Count) strikes | Lot: $LotSize" -ForegroundColor Green

$PlacedOrdersDir = Join-Path $scriptDir 'PlacedOrders'
if (-not (Test-Path $PlacedOrdersDir)) { New-Item -ItemType Directory -Path $PlacedOrdersDir -Force | Out-Null }
$PositionFile = Join-Path $PlacedOrdersDir 'Position-35Min-V2.json'

# ================================================================
# State
# ================================================================
$State = @{
    Positions       = @{ CE = $null; PE = $null }
    Candle          = $null
    Completed       = [System.Collections.Generic.List[PSCustomObject]]::new()
    TickCount       = 0
    BarEntryCount   = 0
    LastEntryFail   = [datetime]::MinValue
    LastOrderPoll   = [datetime]::MinValue
    LastDisplay     = [datetime]::MinValue
    CanClearHost    = $null
    Signals         = [System.Collections.Generic.List[string]]::new()
    TotalPnL        = 0.0
}

# Previous-run leftovers are never resumed (no SL tracking for them).
if (Test-Path $PositionFile) {
    try {
        $old = Get-Content $PositionFile -Raw | ConvertFrom-Json
        foreach ($o in @($old)) { Write-Host "  Previous-run position (NOT managed by this run): $($o.Side) $($o.Symbol) Qty $($o.Qty) SL order: $($o.SlOrderId)" -ForegroundColor Yellow }
    } catch {}
    $cleanup = $CleanupPosition
    if ($cleanup -eq 'auto') {
        $isNonInteractive = try { [Console]::IsInputRedirected } catch { $true }
        if ($isNonInteractive) { $cleanup = 'yes'; Write-Host '  Non-interactive mode: starting fresh (old positions/SLs must be handled manually).' -ForegroundColor DarkGray }
        else { $cleanup = Read-Host '  Start fresh and ignore the above? (y/n)' }
    }
    if ($cleanup -in @('y','yes')) { Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue }
    else { Write-Host '  Not starting - handle the previous positions first.' -ForegroundColor Red; exit 1 }
}

# ================================================================
# Helpers
# ================================================================
function Save-Positions {
    $open = @($State.Positions.Values | Where-Object { $_ })
    if ($open.Count -eq 0) { Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue; return }
    ConvertTo-Json -InputObject @($open | ForEach-Object { [ordered]@{
        Side=$_.Side; Symbol=$_.Symbol; Token=$_.Token; Strike=$_.Strike; Qty=$_.Qty; Lots=$_.Lots
        EntryLTP=$_.EntryLTP; EntryTime=$_.EntryTime; SlOrderId=$_.SlOrderId; SlTrigger=$_.SlTrigger; SlPrice=$_.SlPrice } }) |
        Set-Content $PositionFile -Force
}

function Get-OptionLtp([string]$Symbol) {
    try {
        $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$Symbol"))" -Headers $headers -ErrorAction Stop
        foreach ($p in $qr.data.PSObject.Properties) { return [double]$p.Value.last_price }
    } catch {}
    return 0.0
}

function Get-KiteOrderList {
    try { return @((Invoke-RestMethod 'https://api.kite.trade/orders' -Headers $headers -ErrorAction Stop).data) } catch { return $null }
}

# Net quantity for a symbol; $null when it cannot be determined
function Get-NetQty([string]$Symbol) {
    try {
        $net = @((Invoke-RestMethod 'https://api.kite.trade/portfolio/positions' -Headers $headers -ErrorAction Stop).data.net)
        $row = $net | Where-Object { $_.tradingsymbol -eq $Symbol -and (-not $_.product -or $_.product -eq $Product) } | Select-Object -First 1
        if ($row) { return [int]$row.quantity } else { return 0 }
    } catch { return $null }
}

function Add-Signal([string]$Text) { $State.Signals.Add("$(Get-Date -Format 'HH:mm:ss') $Text") }

function Register-Exit($Pos, [double]$ExitPrice, [string]$Reason) {
    $pnl = ($ExitPrice - $Pos.EntryLTP) * $Pos.Qty
    $State.TotalPnL += $pnl
    $col = if ($pnl -ge 0) { 'Green' } else { 'Red' }
    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] CLOSED $($Pos.Side) $($Pos.Symbol) ($Reason) | Exit: $ExitPrice | Trade P&L: $($pnl.ToString('N2')) | Total: $($State.TotalPnL.ToString('N2'))" -ForegroundColor $col
    Add-Signal "EXIT $($Pos.Side) $($Pos.Symbol) ($Reason) P&L $($pnl.ToString('N2'))"
    $State.Positions[$Pos.Side] = $null
    Save-Positions
}

# Returns 'none' | 'cancelled' | 'filled' | 'failed'
function Cancel-PositionSL($Pos) {
    if (-not $Pos.SlOrderId) { return 'none' }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-RestMethod "https://api.kite.trade/orders/$Variety/$($Pos.SlOrderId)" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] SL cancelled | $($Pos.Symbol) | OrderID: $($Pos.SlOrderId)" -ForegroundColor Green
            return 'cancelled'
        } catch {
            $ord = Get-KiteOrderList | Where-Object { $_.order_id -eq $Pos.SlOrderId } | Select-Object -First 1
            if ($ord -and $ord.status -eq 'COMPLETE') { return 'filled' }
            if ($ord -and $ord.status -in @('CANCELLED','REJECTED')) { return 'cancelled' }
            Write-Host "  SL cancel attempt $i/3 failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
        }
    }
    return 'failed'
}

# SL first, then market SELL. Never sells a position whose SL already filled.
function Close-Position([string]$Side, [string]$Reason) {
    $pos = $State.Positions[$Side]
    if (-not $pos) { return }

    $sl = Cancel-PositionSL $pos
    if ($sl -eq 'filled') {
        $ord = Get-KiteOrderList | Where-Object { $_.order_id -eq $pos.SlOrderId } | Select-Object -First 1
        $px = if ($ord -and $ord.average_price) { [double]$ord.average_price } else { $pos.SlPrice }
        Register-Exit $pos $px 'SL filled'
        return
    }
    if ($sl -eq 'failed') { Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] WARNING: SL $($pos.SlOrderId) could not be cancelled - selling anyway. Check Kite for a leftover SL!" -ForegroundColor Red }
    $pos.SlOrderId = $null

    $qty = $pos.Qty
    $net = Get-NetQty $pos.Symbol
    if ($null -ne $net) {
        if ($net -le 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $($pos.Symbol) already flat at broker - nothing to sell." -ForegroundColor Yellow
            $State.Positions[$Side] = $null; Save-Positions; return
        }
        $qty = [Math]::Min($qty, $net)
    }

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $Side MARKET SELL ($Reason) | $($pos.Symbol) | Qty: $qty" -ForegroundColor Cyan
    $res = Place-ZerodhaOrder -CommonHeader $headers -Type 'SELL' -Variety $Variety -Tradingsymbol $pos.Symbol -Quantity $qty `
        -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "$Side-EXIT" -MarketProtection $MarketProtection
    if ($res) {
        $ltp = Get-OptionLtp $pos.Symbol
        Register-Exit $pos $ltp $Reason
    } else {
        $pos.CloseReason = $Reason
        $pos.NextCloseTry = (Get-Date).AddSeconds(5)
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] SELL FAILED for $($pos.Symbol) - will retry." -ForegroundColor Red
        Save-Positions
    }
}

function Close-AllPositions([string]$Reason) {
    foreach ($s in @('CE','PE')) { if ($State.Positions[$s]) { Close-Position $s $Reason } }
}

# Trigger is a whole number SLTriggerPercentage below the option's live LTP; price sits SLPriceGap below it.
# Two attempts, then the caller market-exits.
function Place-PositionSL($Pos) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $ltp = Get-OptionLtp $Pos.Symbol
        if ($ltp -le 0) { $ltp = [double]$Pos.EntryLTP }
        if ($ltp -gt 0) {
            $trigger = [int][Math]::Round($ltp * (1 - $SLTriggerPercentage / 100), 0, [MidpointRounding]::AwayFromZero)
            $price   = $trigger - $SLPriceGap
            if ($price -gt 0 -and $trigger -lt $ltp) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $($Pos.Side) SL | LTP: $ltp | -$SLTriggerPercentage% | Trigger: $trigger | Price: $price" -ForegroundColor Yellow
                $res = Place-ZerodhaOrder -CommonHeader $headers -Type 'SELL' -Variety $Variety -Tradingsymbol $Pos.Symbol -Quantity $Pos.Qty `
                    -OrderType 'SL' -Product $Product -Exchange $exchange -Price $price -TriggerPrice $trigger -Tag "SL-$($Pos.Side)"
                if ($res -and $res.order_id) {
                    $Pos.SlOrderId = [string]$res.order_id; $Pos.SlTrigger = $trigger; $Pos.SlPrice = $price
                    return $true
                }
            } else {
                Write-Host "  SL not placeable (attempt $attempt): LTP $ltp -> Trigger $trigger / Price $price (trigger must be below LTP and price > 0)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  SL inputs unavailable (attempt $attempt): option LTP not available" -ForegroundColor Yellow
        }
        if ($attempt -lt 2) { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Open-Position([string]$Side, [double]$TickPrice) {
    $isCE    = ($Side -eq 'CE')
    $options = if ($isCE) { $ceData.Options } else { $peData.Options }
    $strikes = if ($isCE) { $ceData.Strikes } else { $peData.Strikes }
    $offset  = if ($isCE) { -$ATMOffset } else { $ATMOffset }

    $idxSpot = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers
    if ($idxSpot -le 0) { $idxSpot = $TickPrice }
    $atm = Get-ATMOption -SpotPrice $idxSpot -Options $options -AllStrikes $strikes -Offset $offset
    if (-not $atm) { Write-Host "  Could not find ATM $Side option." -ForegroundColor Red; return $false }

    $qty = $Quantity; $lots = $NoOfLotsPurchaseAtaTime
    $ltp = Get-OptionLtp $atm.Symbol
    if ($AmountToTrade -gt 0 -and $ltp -gt 0) {
        $lots = [int][Math]::Floor($AmountToTrade / ($ltp * $LotSize)); if ($lots -lt 1) { $lots = 1 }
        $qty = $lots * $LotSize
    }

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $Side BUY | Strike: $($atm.Strike) | $($atm.Symbol) | Qty: $qty | LTP: $ltp" -ForegroundColor Cyan
    $res = Place-ZerodhaOrder -CommonHeader $headers -Type 'BUY' -Variety $Variety -Tradingsymbol $atm.Symbol -Quantity $qty `
        -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "$Side-ENTRY" -MarketProtection $MarketProtection
    if (-not $res) { Write-Host "  $Side BUY FAILED" -ForegroundColor Red; return $false }

    $pos = @{
        Side=$Side; Symbol=$atm.Symbol; Token=[int]$atm.Token; Strike=$atm.Strike; Qty=$qty; Lots=$lots
        EntryLTP=$ltp; EntryTime=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        SlOrderId=$null; SlTrigger=0; SlPrice=0; CloseReason=$null; NextCloseTry=[datetime]::MinValue
    }
    $State.Positions[$Side] = $pos
    Save-Positions
    Add-Signal "ENTRY $Side $($atm.Symbol) Qty $qty @ $ltp"

    if ($ExitTrade -eq 'no' -and -not (Place-PositionSL $pos)) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] SL could not be placed - exiting $Side at market." -ForegroundColor Red
        Close-Position $Side 'SL placement failed'
        return $true
    }
    Save-Positions
    return $true
}

# Detects SL fills / externally cancelled SLs (polled at most every 3 seconds)
function Sync-StopLosses {
    $tracked = @($State.Positions.Values | Where-Object { $_ -and $_.SlOrderId })
    if ($tracked.Count -eq 0) { return }
    if (((Get-Date) - $State.LastOrderPoll).TotalSeconds -lt 3) { return }
    $State.LastOrderPoll = Get-Date
    $orders = Get-KiteOrderList
    if ($null -eq $orders) { return }
    foreach ($pos in $tracked) {
        $ord = $orders | Where-Object { $_.order_id -eq $pos.SlOrderId } | Select-Object -First 1
        if (-not $ord) { continue }
        if ($ord.status -eq 'COMPLETE') {
            $px = if ($ord.average_price) { [double]$ord.average_price } else { $pos.SlPrice }
            Register-Exit $pos $px 'SL hit'
        } elseif ($ord.status -in @('CANCELLED','REJECTED')) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] WARNING: SL for $($pos.Symbol) is $($ord.status) - position is UNPROTECTED until candle close." -ForegroundColor Red
            $pos.SlOrderId = $null; Save-Positions
        }
    }
}

function Retry-PendingCloses {
    foreach ($s in @('CE','PE')) {
        $p = $State.Positions[$s]
        if ($p -and $p.CloseReason -and (Get-Date) -ge $p.NextCloseTry) { Close-Position $s $p.CloseReason }
    }
}

function Test-AnyOpen { return [bool](@($State.Positions.Values | Where-Object { $_ }).Count) }

# ================================================================
# Signals + candle building
# ================================================================
function Invoke-SignalCheck([double]$LastPrice) {
    $c = $State.Candle
    if ($null -eq $c) { return }
    $now = [datetime]::Now
    $withinWindow = ($now.TimeOfDay -ge $StartTime.TimeOfDay -and $now.TimeOfDay -le $StopTime.TimeOfDay -and $now.TimeOfDay -lt $ForceExitTime.TimeOfDay)
    $isGreen = ($c.Close -ge ($c.Open + $OffsetPoints))
    $isRed   = ($c.Close -le ($c.Open - $OffsetPoints))

    # ExitTrade=yes: opposite colour closes the running position. ExitTrade=no: the SL is the exit.
    if ($ExitTrade -eq 'yes') {
        if ($State.Positions.CE -and $isRed)   { Write-Host "`n  *** CE EXIT (red) *** LTP: $LastPrice" -ForegroundColor Yellow; Close-Position 'CE' 'opposite candle' }
        if ($State.Positions.PE -and $isGreen) { Write-Host "`n  *** PE EXIT (green) *** LTP: $LastPrice" -ForegroundColor Yellow; Close-Position 'PE' 'opposite candle' }
    }

    if (-not $withinWindow -or $State.BarEntryCount -ge $MaxRetryCountOnBar) { return }
    if (((Get-Date) - $State.LastEntryFail).TotalSeconds -lt 2) { return }

    $side = $null
    if ($isGreen -and -not $State.Positions.CE -and ($ExitTrade -eq 'no' -or -not $State.Positions.PE)) { $side = 'CE' }
    elseif ($isRed -and -not $State.Positions.PE -and ($ExitTrade -eq 'no' -or -not $State.Positions.CE)) { $side = 'PE' }
    if (-not $side) { return }

    $col = if ($side -eq 'CE') { 'green' } else { 'red' }
    Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** $side ENTRY ($col) *** LTP: $LastPrice | Open: $([Math]::Round($c.Open,2)) | Close: $([Math]::Round($c.Close,2)) | Bar entry $($State.BarEntryCount + 1)/$MaxRetryCountOnBar" -ForegroundColor Yellow
    if (Open-Position $side $LastPrice) { $State.BarEntryCount++ } else { $State.LastEntryFail = Get-Date }
}

function Update-FromTick([double]$LastPrice) {
    $State.TickCount++
    $bucket = Get-HAStrategyTimeBucket $intSec
    $c = $State.Candle

    if ($null -eq $c -or $c.TimeBucket -ne $bucket) {
        if ($null -ne $c) {
            $State.Completed.Add([PSCustomObject]@{ TimeBucket=$c.TimeBucket; Open=$c.Open; High=$c.High; Low=$c.Low; Close=$c.Close })
            if (Test-AnyOpen) {
                Write-Host "`n  [$(Get-Date -Format 'HH:mm:ss.fff')] *** CANDLE CLOSE *** closing all positions (SLs first)" -ForegroundColor Yellow
                Close-AllPositions 'candle close'
            }
        }
        $State.Candle = @{ TimeBucket=$bucket; Open=$LastPrice; High=$LastPrice; Low=$LastPrice; Close=$LastPrice }
        $State.BarEntryCount = 0
    } else {
        $c.High = [Math]::Max($c.High, $LastPrice); $c.Low = [Math]::Min($c.Low, $LastPrice); $c.Close = $LastPrice
    }
    Invoke-SignalCheck $LastPrice
}

function Show-Display {
    $now = [datetime]::Now
    if (($now - $State.LastDisplay).TotalMilliseconds -lt 500) { return }
    $State.LastDisplay = $now
    $c = $State.Candle
    if ($null -eq $c) { return }

    $sb = [System.Text.StringBuilder]::new(1024)
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("  ================================================")
    $null = $sb.AppendLine("  $label - Regular Long+Short V2 | ExitTrade=$ExitTrade | TF: $TimeFrame ($intLabel)")
    $null = $sb.AppendLine("  ================================================")
    $null = $sb.AppendLine("  Window  : $($StartTime.ToString('HH:mm:ss'))-$($StopTime.ToString('HH:mm:ss')) | ForceExit: $($ForceExitTime.ToString('HH:mm:ss')) | Offset: $OffsetPoints | Entries this candle: $($State.BarEntryCount)/$MaxRetryCountOnBar")
    $null = $sb.AppendLine("  Ticks   : $($State.TickCount) | Total P&L: $($State.TotalPnL.ToString('N2')) | Time: $(Get-Date -Format 'HH:mm:ss')")
    $null = $sb.AppendLine("  Candle  : $($c.TimeBucket) O:$([Math]::Round($c.Open,2)) H:$([Math]::Round($c.High,2)) L:$([Math]::Round($c.Low,2)) C:$([Math]::Round($c.Close,2))")
    foreach ($s in @('CE','PE')) {
        $p = $State.Positions[$s]
        if ($p) {
            $slTxt = if ($p.SlOrderId) { "SL trig $($p.SlTrigger) / price $($p.SlPrice) (#$($p.SlOrderId))" } elseif ($ExitTrade -eq 'no') { 'NO SL' } else { '-' }
            $null = $sb.AppendLine("  $s      : OPEN $($p.Symbol) Qty $($p.Qty) Entry $($p.EntryLTP) | $slTxt")
        } else { $null = $sb.AppendLine("  $s      : flat") }
    }
    foreach ($sg in ($State.Signals | Select-Object -Last 6)) { $null = $sb.AppendLine("    $sg") }

    if ($null -eq $State.CanClearHost) { $State.CanClearHost = try { Clear-Host; $true } catch { $false } }
    elseif ($State.CanClearHost) { try { Clear-Host } catch {} }
    Write-Host $sb.ToString()
}

# ================================================================
# WebSocket
# ================================================================
$wsUri   = "wss://ws.kite.trade?api_key=$API_Key&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Regular Long+Short V2 | ExitTrade=$ExitTrade | $TimeFrame" -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym) | Token: $instToken | Expiry: $nearestExpiry"
if ($AmountToTrade -gt 0) { Write-Host "  Trade    : Amount: $AmountToTrade | LotSize: $LotSize" } else { Write-Host "  Trade    : Lots: $NoOfLotsPurchaseAtaTime | Qty: $Quantity" }
Write-Host "  Product  : $Product | Order: $Order_type | Mode: $modeStr"
Write-Host "  Window   : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss')) | Force exit: $($ForceExitTime.ToString('HH:mm:ss'))"
if ($ExitTrade -eq 'no') { Write-Host "  SL       : trigger = option LTP -$SLTriggerPercentage% (whole number), price = trigger-$SLPriceGap" }
Write-Host '  Connecting...' -ForegroundColor Yellow

$maxRetries = 3; $retryCount = 0; $buf = New-Object byte[] 65536

while ($retryCount -le $maxRetries) {
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader('X-Kite-Version', '3')
    $cts = [System.Threading.CancellationTokenSource]::new()
    $rt  = $null

    try {
        $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
        if (-not $ct.Wait(15000) -or $ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host '  Connection failed.' -ForegroundColor Red
            $retryCount++
            if ($retryCount -le $maxRetries) { $w = $retryCount * 5; Write-Host "  Retry in ${w}s..." -ForegroundColor Yellow; Start-Sleep $w }
            continue
        }

        $retryCount = 0
        Write-Host '  Connected!' -ForegroundColor Green
        $subB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"subscribe","v":[' + $instToken + ']}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($subB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["' + $modeStr + '",[' + $instToken + ']]}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        Write-Host "  Subscribed ($modeStr). Waiting for ticks..." -ForegroundColor Green

        $seg = [System.ArraySegment[byte]]::new($buf)
        $done = $false

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $nowTOD = [datetime]::Now.TimeOfDay

            if ($nowTOD -ge $ForceExitTime.TimeOfDay) {
                if (Test-AnyOpen) { Write-Host "`n  Force-exit time reached - closing all positions." -ForegroundColor Red; Close-AllPositions 'force exit time' }
                if (-not (Test-AnyOpen)) { Write-Host '  Force-exit time reached - stopping.' -ForegroundColor Yellow; $done = $true; break }
            } elseif ($nowTOD -gt $StopTime.TimeOfDay -and -not (Test-AnyOpen)) {
                Write-Host '  Stop time reached - no open position. Stopping.' -ForegroundColor Yellow; $done = $true; break
            }

            if ($ExitTrade -eq 'no') { Sync-StopLosses }
            Retry-PendingCloses

            try {
                if ($null -eq $rt) { $rt = $ws.ReceiveAsync($seg, $cts.Token) }
                if (-not $rt.Wait(1000)) { continue }
                $res = $rt.Result; $rt = $null
            } catch { $rt = $null; if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }; continue }

            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { Write-Host '  Server closed.' -ForegroundColor Yellow; break }
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                if ($res.Count -gt 1) { try { $jm = [System.Text.Encoding]::UTF8.GetString($buf,0,$res.Count) | ConvertFrom-Json; if ($jm.type -eq 'error') { Write-Host "  ERROR: $($jm.data)" -ForegroundColor Red } } catch {} }
                continue
            }
            if (($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) -and ($res.Count -gt 2)) {
                foreach ($tick in (Parse-KiteTicks $buf $res.Count)) {
                    if ($tick.InstrumentToken -eq $instToken -and $tick.LastPrice -gt 0) { Update-FromTick $tick.LastPrice }
                }
                try { Show-Display } catch {}
            }
        }

        if ($done) { break }
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

# Feed lost for good: do not leave positions running unattended
if (Test-AnyOpen) { Write-Host "`n  Feed lost - closing remaining positions." -ForegroundColor Red; Close-AllPositions 'feed lost' }

Write-Host ''
Write-Host '  Disconnected.' -ForegroundColor Yellow
Write-Host "  Signals: $($State.Signals.Count) | Total P&L: $($State.TotalPnL.ToString('N2'))" -ForegroundColor Gray
foreach ($sig in $State.Signals) { Write-Host "    $sig" -ForegroundColor DarkGray }
Write-Host ''
