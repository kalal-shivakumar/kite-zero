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
    # --- Position state: Direction = 'LONG' | 'SHORT' | '' ---
    Direction               = ''
    EntryPrice              = 0.0
    EntryTime               = ''
    OptSymbol               = ''
    OptToken                = 0
    OptStrike               = 0
    OptEntryLTP             = 0
    OptQty                  = 0
    OptLots                 = 0
    OptType                 = ''  # 'CE' or 'PE'
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
# Strategy functions have been moved into KiteData.psm1 and operate
# on the shared $State object built above:
#   Update-HAStrategyFromTick, Show-HAStrategyDisplay,
#   Invoke-HAStrategyForceExit (+ internal helpers)
# ================================================================

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

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $now = [datetime]::Now
            if (($now - $lastStopCheck).TotalSeconds -ge 1) {
                $lastStopCheck = $now
                if ($now.TimeOfDay -gt $stopTOD) {
                    Invoke-HAStrategyForceExit $State; Write-Host "  Stop time reached." -ForegroundColor Yellow; break
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
Write-Host "  Total Trades: $($State.StrategySignals.Count) | Total P&L: $($State.TotalPnL.ToString('N2'))" -ForegroundColor Gray
foreach ($sig in $State.StrategySignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
Write-Host ''
