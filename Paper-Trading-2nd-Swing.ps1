<#
.SYNOPSIS
  Heikin Ashi (HA) Swing-Based Long/Short Option Trading Bot with CE+PE Auto-Trade (zero-latency).

.DESCRIPTION
  Streams live Heikin Ashi candles via Zerodha Kite WebSocket. Trades both directions with single
  active position at a time, automatically switching directions on swing reversals.

  ENTRY SIGNALS:
  - LONG:  HA Close > Previous High  → BUY Call Option (CE)
  - SHORT: HA Close < Previous Low   → BUY Put Option (PE)

  EXIT SIGNALS:
  - LONG Exit:  HA Close < Previous Low   → SELL Call Option (CE)
  - SHORT Exit: HA Close > Previous High  → SELL Put Option (PE)

  FEATURES:
  - Zero-latency real-time tick streaming via WebSocket
  - Automatic ATM option strike selection with configurable offset
  - Respects trading window (no new entries after StopTime, but holds existing positions)
  - Position resumption on script restart (can continue partial positions)
  - P&L tracking and reporting
  - Supports configurable timeframes (5 seconds to 60 minutes)

.EXAMPLE
  .\take-entry-on-second-swing.ps1
  .\take-entry-on-second-swing.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute -NoOfLotsPurchaseAtaTime 1
  .\take-entry-on-second-swing.ps1 -TradingSymbol NIFTY -TimeFrame minute -Product MIS -ModeOfTrading Option_Buyer
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
    SwingLow                = 0.0   # Recorded on LONG entry (current candle low)
    SwingHigh               = 0.0   # Recorded on SHORT entry (current candle high)
    PreviousSwingLow        = 0.0   # Previous LONG entry's swing low (for perfect entry validation)
    PreviousSwingHigh       = 0.0   # Previous SHORT entry's swing high (for perfect entry validation)
    SwingLowHistory         = [System.Collections.Generic.List[double]]::new()   # Last swing lows for LONG entries
    SwingHighHistory        = [System.Collections.Generic.List[double]]::new()   # Last swing highs for SHORT entries
    SignalTimeBucket        = ''   # Time bucket when signal was triggered (for table display)
    SignalType              = ''   # 'LONG' or 'SHORT' (for table display)
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
    param([hashtable]$State, [string]$dir, [double]$spotPrice, [string]$timeStamp)
    $optType = if ($dir -eq 'LONG') { 'CE' } else { 'PE' }
    $options = if ($dir -eq 'LONG') { $State.ceOptions } else { $State.peOptions }
    $strikes = if ($dir -eq 'LONG') { $State.ceStrikes } else { $State.peStrikes }
    $offset  = if ($dir -eq 'LONG') { -$State.ATMOffset } else { $State.ATMOffset }
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
    $result = $true  # Place-ZerodhaOrder -CommonHeader $State.headers -Type "BUY" -Variety $State.Variety `
        # -Tradingsymbol $atmOption.Symbol -Quantity $entryQty `
        # -OrderType $State.Order_type -Product $State.Product -Exchange $State.exchange -Tag $tag -MarketProtection $State.MarketProtection

    if ($result) {
        $State.Direction   = $dir
        $State.EntryPrice  = $spotPrice
        $State.EntryTime   = $timeStamp
        $State.OptSymbol   = $atmOption.Symbol
        $State.OptToken    = $atmOption.Token
        $State.OptStrike   = $atmOption.Strike
        $State.OptEntryLTP = $optLTP
        $State.OptQty      = $entryQty
        $State.OptLots     = $entryLots
        $State.OptType     = $optType
        @{ Direction=$dir; Symbol=$State.OptSymbol; Token=$State.OptToken; Strike=$State.OptStrike; Price=$spotPrice; Time=$timeStamp; OptionLTP=$optLTP; TotalPnL=$State.TotalPnL; Qty=$entryQty; Lots=$entryLots; OptType=$optType } | ConvertTo-Json | Set-Content $State.PositionFile -Force
        $latency = ((Get-Date) - $now).TotalMilliseconds
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] POSITION OPENED in ${latency}ms | $dir $($State.OptSymbol) | Strike: $($State.OptStrike) | Qty: $entryQty | LTP: $optLTP" -ForegroundColor Green
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

    $trendSel = if ($State.OptType -eq 'CE') { 'CE' } else { 'PE' }
    Cancel-AllStopLosses -TrendEntrySelection $trendSel -Headers $State.headers

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $($State.OptType) SELL | Symbol: $($State.OptSymbol) | Qty: $($State.OptQty)" -ForegroundColor Cyan
    Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] PAPER TRADING: Order NOT placed (simulated)" -ForegroundColor Yellow
    $now = Get-Date
    $result = $true  # Place-ZerodhaOrder -CommonHeader $State.headers -Type "SELL" -Variety $State.Variety `
        # -Tradingsymbol $State.OptSymbol -Quantity $State.OptQty `
        # -OrderType $State.Order_type -Product $State.Product -Exchange $State.exchange -Tag "$($State.OptType)-EXIT" -MarketProtection $State.MarketProtection

    if ($result) {
        $exitLTP = 0
        try {
            $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("$($State.optExchange):$($State.OptSymbol)"))" -Headers $State.headers -ErrorAction Stop
            foreach ($p in $qr.data.PSObject.Properties) { $exitLTP = $p.Value.last_price; break }
        } catch {}
        $tradePnL = ($exitLTP - $State.OptEntryLTP) * $State.OptQty
        $State.TotalPnL += $tradePnL
        $pnlColor = if ($tradePnL -ge 0) { 'Green' } else { 'Red' }
        $latency = ((Get-Date) - $now).TotalMilliseconds
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] CLOSED in ${latency}ms | $($State.OptSymbol) | Trade P&L: $($tradePnL.ToString('N2')) | Total: $($State.TotalPnL.ToString('N2'))" -ForegroundColor $pnlColor
    } else {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] SELL failed - clearing state anyway" -ForegroundColor DarkYellow
    }

    $State.StrategySignals.Add("EXIT $($State.Direction) @ $lastPrice  P&L: $([Math]::Round($lastPrice - $State.EntryPrice, 2)) ($timeStamp)")
    $State.Direction = ''; $State.EntryPrice = 0; $State.EntryTime = ''
    $State.OptSymbol = ''; $State.OptToken = 0; $State.OptStrike = 0
    $State.OptEntryLTP = 0; $State.OptQty = 0; $State.OptLots = 0; $State.OptType = ''
    $State.SwingLow = 0.0; $State.SwingHigh = 0.0
    $State.SignalTimeBucket = ''; $State.SignalType = ''
    Remove-Item $State.PositionFile -Force -ErrorAction SilentlyContinue
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

    if ($withinWindow -and $State.Direction -eq '' -and $liveHA.Close -gt $prev.High) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** LONG ENTRY SIGNAL *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) > Prev High: $($prev.High)" -ForegroundColor Yellow
        $State.SwingLow = $currentRaw.Low
        
        # Filter: Only enter if first LONG entry OR current SL > previous SL (perfect entry)
        $isPerfectEntry = ($State.PreviousSwingLow -eq 0) -or ($State.SwingLow -gt $State.PreviousSwingLow)
        
        if (-not $isPerfectEntry) {
            Write-Host "  SIGNAL REJECTED: Current SL $($State.SwingLow.ToString('N2')) not > Previous SL $($State.PreviousSwingLow.ToString('N2'))" -ForegroundColor Red
            return
        }
        
        $ok = Enter-HAStrategyPosition $State 'LONG' $lastPrice $timeStamp
        if ($ok) {
            $signal = "ENTRY LONG @ $lastPrice | SL: $($State.SwingLow.ToString('N2'))"
            if ($State.PreviousSwingLow -gt 0) {
                $signal += " | Previous SL: $($State.PreviousSwingLow.ToString('N2'))"
            }
            $signal += "  CE: $($State.OptSymbol) ($timeStamp)"
            if ($State.SwingLowHistory.Count -gt 0) {
                $historyDisplay = "  Last Swing Lows: "
                for ($i = 0; $i -lt [Math]::Min(2, $State.SwingLowHistory.Count); $i++) {
                    $historyDisplay += "$($State.SwingLowHistory[$State.SwingLowHistory.Count - 1 - $i].ToString('N2'))"
                    if ($i -lt [Math]::Min(2, $State.SwingLowHistory.Count) - 1) { $historyDisplay += " <- " }
                }
                Write-Host $historyDisplay -ForegroundColor Cyan
            }
            if ($State.PreviousSwingLow -gt 0 -and $State.SwingLow -gt $State.PreviousSwingLow) {
                Write-Host "  Current SL: $($State.SwingLow.ToString('N2')) vs Previous SL: $($State.PreviousSwingLow.ToString('N2'))" -ForegroundColor Green
                $signal += "`n---------> perfect Long entry"
            }
            $State.StrategySignals.Add($signal)
            $State.SwingLowHistory.Add($State.SwingLow)
            if ($State.SwingLowHistory.Count -gt 2) { $State.SwingLowHistory.RemoveAt(0) }
            $State.PreviousSwingLow = $State.SwingLow
            $State.SignalTimeBucket = $currentRaw.TimeBucket
            $State.SignalType = 'LONG'
        }
        return
    }

    if ($withinWindow -and $State.Direction -eq '' -and $liveHA.Close -lt $prev.Low) {
        Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT ENTRY SIGNAL *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) < Prev Low: $($prev.Low)" -ForegroundColor Yellow
        $State.SwingHigh = $currentRaw.High
        
        # Filter: Only enter if first SHORT entry OR current SH < previous SH (perfect entry)
        $isPerfectEntry = ($State.PreviousSwingHigh -eq 0) -or ($State.SwingHigh -lt $State.PreviousSwingHigh)
        
        if (-not $isPerfectEntry) {
            Write-Host "  SIGNAL REJECTED: Current SH $($State.SwingHigh.ToString('N2')) not < Previous SH $($State.PreviousSwingHigh.ToString('N2'))" -ForegroundColor Red
            return
        }
        
        $ok = Enter-HAStrategyPosition $State 'SHORT' $lastPrice $timeStamp
        if ($ok) {
            $signal = "ENTRY SHORT @ $lastPrice | SH: $($State.SwingHigh.ToString('N2'))"
            if ($State.PreviousSwingHigh -gt 0) {
                $signal += " | Previous SH: $($State.PreviousSwingHigh.ToString('N2'))"
            }
            $signal += "  PE: $($State.OptSymbol) ($timeStamp)"
            if ($State.SwingHighHistory.Count -gt 0) {
                $historyDisplay = "  Last Swing Highs: "
                for ($i = 0; $i -lt [Math]::Min(2, $State.SwingHighHistory.Count); $i++) {
                    $historyDisplay += "$($State.SwingHighHistory[$State.SwingHighHistory.Count - 1 - $i].ToString('N2'))"
                    if ($i -lt [Math]::Min(2, $State.SwingHighHistory.Count) - 1) { $historyDisplay += " <- " }
                }
                Write-Host $historyDisplay -ForegroundColor Cyan
            }
            if ($State.PreviousSwingHigh -gt 0 -and $State.SwingHigh -lt $State.PreviousSwingHigh) {
                Write-Host "  Current SH: $($State.SwingHigh.ToString('N2')) vs Previous SH: $($State.PreviousSwingHigh.ToString('N2'))" -ForegroundColor Green
                $signal += "`n---------> perfect Short entry"
            }
            $State.StrategySignals.Add($signal)
            $State.SwingHighHistory.Add($State.SwingHigh)
            if ($State.SwingHighHistory.Count -gt 2) { $State.SwingHighHistory.RemoveAt(0) }
            $State.PreviousSwingHigh = $State.SwingHigh
            $State.SignalTimeBucket = $currentRaw.TimeBucket
            $State.SignalType = 'SHORT'
        }
        return
    }

    if ($State.Direction -eq 'LONG' -and $liveHA.Close -lt $prev.Low) {
        $State.SwingHigh = $currentRaw.High
        # Exit LONG if: 1) Price breaks down AND 2) Current SH < Previous SL (swing level filter)
        if ($State.SwingHigh -lt $State.PreviousSwingLow) {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** LONG EXIT *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) < Prev Low: $($prev.Low) | SH: $($State.SwingHigh.ToString('N2')) < Prev SL: $($State.PreviousSwingLow.ToString('N2'))" -ForegroundColor Yellow
            Exit-HAStrategyPosition $State $lastPrice $timeStamp
        } else {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] LONG EXIT SIGNAL BLOCKED: SH $($State.SwingHigh.ToString('N2')) not < Prev SL $($State.PreviousSwingLow.ToString('N2'))" -ForegroundColor DarkYellow
        }
        return
    }

    if ($State.Direction -eq 'SHORT' -and $liveHA.Close -gt $prev.High) {
        $State.SwingLow = $currentRaw.Low
        # Exit SHORT if: 1) Price breaks up AND 2) Current SL > Previous SH (swing level filter)
        if ($State.SwingLow -gt $State.PreviousSwingHigh) {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] *** SHORT EXIT *** LTP: $lastPrice | HA Close: $([Math]::Round($liveHA.Close,2)) > Prev High: $($prev.High) | SL: $($State.SwingLow.ToString('N2')) > Prev SH: $($State.PreviousSwingHigh.ToString('N2'))" -ForegroundColor Yellow
            Exit-HAStrategyPosition $State $lastPrice $timeStamp
        } else {
            Write-Host "`n  [$($now.ToString('HH:mm:ss.fff'))] SHORT EXIT SIGNAL BLOCKED: SL $($State.SwingLow.ToString('N2')) not > Prev SH $($State.PreviousSwingHigh.ToString('N2'))" -ForegroundColor DarkYellow
        }
        return
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
    if ($null -ne $currentCandle) {
        $ha = Convert-ToHACandle $currentCandle ($State.STR_PreviousHA[$instrumentToken])
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
    if ($State.AmountToTrade -gt 0) {
        $null = $sb.AppendLine("  Trade   : Amount: $($State.AmountToTrade)  |  LotSize: $($State.LotSize)  |  Product: $($State.Product)")
    } else {
        $null = $sb.AppendLine("  Trade   : Lots: $($State.NoOfLotsPurchaseAtaTime)  |  Qty: $($State.Quantity)  |  Product: $($State.Product)")
    }
    $null = $sb.AppendLine("  Ticks   : $($State.STR_TickCount)  |  Window: $($State.StartTime.ToString('HH:mm:ss'))-$($State.StopTime.ToString('HH:mm:ss'))  |  Total P&L: $($State.TotalPnL.ToString('N2'))")
    $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
    $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')")

    if ($State.Direction -ne '') {
        $null = $sb.AppendLine("  POSITION: $($State.Direction) ACTIVE  $($State.OptType): $($State.OptSymbol)  Strike: $($State.OptStrike)  Lots: $($State.OptLots)  Qty: $($State.OptQty)  Entry: $($State.EntryPrice.ToString('N2')) @ $($State.EntryTime)  OptLTP: $($State.OptEntryLTP)")
        if ($null -ne $currentCandle) {
            $unrealized = if ($State.Direction -eq 'LONG') { $currentCandle.Close - $State.EntryPrice } else { $State.EntryPrice - $currentCandle.Close }
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized Spot P&L: $($unrealized.ToString('N2'))")
        }
    } else {
        $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for signal)")
        if ($null -ne $currentCandle) {
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
        }
    }

    $null = $sb.AppendLine('')
    $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,8} {5,7} {6,7} {7,5} {8,6}'
    $null = $sb.AppendLine(($rowFormat -f 'Time','HA High','HA Low','HA Close','Signal','SL','SH','Ticks','Trend'))
    $null = $sb.AppendLine(' ' + ('-' * 106))

    if ($null -eq $State.CanClearHost) { $State.CanClearHost = try { Clear-Host; $true } catch { $false } }
    elseif ($State.CanClearHost) { try { Clear-Host } catch {} }
    Write-Host $sb.ToString()

    for ($i = 0; $i -lt $visibleCandles.Count; $i++) {
        $c = $visibleCandles[$i]
        $trend = if ($c.Close -ge $c.Open) { '  UP' } else { 'DOWN' }
        $color = if ($c.Close -ge $c.Open) { 'Green' } else { 'Red' }
        
        # Only show signal/SL/SH on the row where the signal was triggered
        if ($State.SignalTimeBucket -ne '' -and $c.TimeBucket -eq $State.SignalTimeBucket) {
            $signal = $State.SignalType  # 'LONG' or 'SHORT'
            $sl = if ($State.SignalType -eq 'LONG') { $State.SwingLow.ToString('N2') } else { '-' }
            $sh = if ($State.SignalType -eq 'SHORT') { $State.SwingHigh.ToString('N2') } else { '-' }
        } else {
            $signal = 'FLAT'
            $sl = '-'
            $sh = '-'
        }
        
        $line = $rowFormat -f $c.TimeBucket, ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), $signal, $sl, $sh, $c.TicksInCandle, $trend
        Write-Host $line -ForegroundColor $(if ($i -eq $visibleCandles.Count - 1) { 'Yellow' } else { $color })
    }

    if ($State.StrategySignals.Count -gt 0) {
        Write-Host ''; Write-Host '  --- Trade Signals ---' -ForegroundColor Cyan
        $show = [Math]::Min(8, $State.StrategySignals.Count)
        for ($si = $State.StrategySignals.Count - $show; $si -lt $State.StrategySignals.Count; $si++) {
            $signal = $State.StrategySignals[$si]
            if ($signal -match 'ENTRY LONG') {
                Write-Host "    $signal" -ForegroundColor Green
            } elseif ($signal -match 'ENTRY SHORT') {
                Write-Host "    $signal" -ForegroundColor Green
            } else {
                Write-Host "    $signal" -ForegroundColor Red
            }
        }
    }
    Write-Host ''; Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
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
