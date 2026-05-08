<#
.SYNOPSIS
  PE Option Buyer — monitors HA Short strategy signals and auto-trades ATM PE.
.DESCRIPTION
  Runs continuously alongside Invoke-KiteHAShortStrategy.ps1.
  When a Short-Entry file appears in PlacedOrders/, it immediately:
    1. Fetches current spot price
    2. Finds the ATM PE strike
    3. Places a BUY order for that PE option
    4. Remembers the trading symbol and instrument token
  When a Short-Exit file appears, it places a SELL order for the same PE
  option to exit the trade.
.EXAMPLE
  .\PE-BUY.ps1
  .\PE-BUY.ps1 -IndexChoosen BANKNIFTY -NoOfLotsPurchaseAtaTime 2
  .\PE-BUY.ps1 -IndexChoosen NIFTY -Product MIS
#>

param(
    [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
    [string]$IndexChoosen = "SENSEX",
    [string]$Global:ProfilePath = "$PSScriptRoot\",
    [int]$NoOfLotsPurchaseAtaTime = 5,
    [ValidateSet('NRML','MIS')]
    [string]$Product = "NRML",
    [datetime]$StartTime = [datetime]("09:17:01"),
    [datetime]$StopTime = [datetime]("21:00:00"),
    [string]$Order_type = "MARKET",
    [ValidateSet('Option_Buyer','Option_Seller')]
    [string]$ModeOfTrading = "Option_Buyer",
    [int]$ATMOffset = 1
)

# ================================================================
# Setup
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$API_Key          = '0fvxhlacu555dhp0'
$API_Secret       = '69wajxn41hj77pze3xnhw1dp442auw8t'
$Variety          = 'regular'
$MarketProtection = 3

# ================================================================
# Load defaults from input.json (command-line params override)
# ================================================================
$inputFile = Join-Path $scriptDir 'input.json'
if (Test-Path $inputFile) {
    $cfg = Get-Content $inputFile -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('IndexChoosen'))            { $IndexChoosen            = $cfg.IndexChoosen }
    if (-not $PSBoundParameters.ContainsKey('NoOfLotsPurchaseAtaTime')) { $NoOfLotsPurchaseAtaTime = [int]$cfg.NoOfLotsPurchaseAtaTime }
    if (-not $PSBoundParameters.ContainsKey('Product'))                 { $Product                 = $cfg.Product }
    if (-not $PSBoundParameters.ContainsKey('StartTime'))               { $StartTime               = [datetime]$cfg.StartTime }
    if (-not $PSBoundParameters.ContainsKey('StopTime'))                { $StopTime                = [datetime]$cfg.StopTime }
    if (-not $PSBoundParameters.ContainsKey('Order_type'))              { $Order_type              = $cfg.Order_type }
    if (-not $PSBoundParameters.ContainsKey('ModeOfTrading'))           { $ModeOfTrading           = $cfg.ModeOfTrading }
    if (-not $PSBoundParameters.ContainsKey('ATMOffset'))               { $ATMOffset               = [int]$cfg.ATMOffset }
    $API_Key          = if ($cfg.API_Key)          { $cfg.API_Key }          else { $API_Key }
    $API_Secret       = if ($cfg.API_Secret)       { $cfg.API_Secret }       else { $API_Secret }
    $Variety          = if ($cfg.Variety)          { $cfg.Variety }          else { $Variety }
    $MarketProtection = if ($cfg.MarketProtection) { [int]$cfg.MarketProtection } else { $MarketProtection }
    Write-Host "  Loaded config from input.json" -ForegroundColor DarkGray
}

$tokenFile  = Join-Path $scriptDir 'accesstoken.json'

# Resolve access token
$AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
if (-not $AccessToken) {
    Write-Host "  No access token found. Please login first." -ForegroundColor Red
    exit 1
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

# ============================================================================
# INITIALIZE CONFIGURATION (using module functions)
# ============================================================================
$IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots $NoOfLotsPurchaseAtaTime
if (-not $IndexConfig) { exit 1 }

$spotExchange   = $IndexConfig.SpotExchange
$optExchange    = $IndexConfig.OptExchange
$exchange       = $IndexConfig.exchange
$Quantity       = $IndexConfig.Quantity
$underlyingName = $IndexConfig.SearchKeyWord

$PlacedOrdersDir = Join-Path $scriptDir 'PlacedOrders'

# Track position state
$script:InPosition       = $false
$script:EntrySymbol      = ''
$script:EntryToken       = 0
$script:EntryStrike      = 0
$script:EntryPrice       = 0
$script:EntryTime        = ''
$script:ProcessedFiles   = @{}

# Persist position state to file so script remembers after restart
$PositionFile = Join-Path $PlacedOrdersDir 'PE-Position.json'
if (Test-Path $PositionFile) {
    $saved = Get-Content $PositionFile -Raw | ConvertFrom-Json
    $script:InPosition  = $true
    $script:EntrySymbol = $saved.Symbol
    $script:EntryToken  = $saved.Token
    $script:EntryStrike = $saved.Strike
    $script:EntryPrice  = $saved.Price
    $script:EntryTime   = $saved.Time
    Write-Host "  Restored position: $($script:EntrySymbol) | Strike: $($script:EntryStrike)" -ForegroundColor Yellow
}

# ================================================================
# Fetch PE option instruments (once at startup)
# ================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  PE-BUY | Index: $IndexChoosen | Mode: $ModeOfTrading" -ForegroundColor Cyan
Write-Host "  Product: $Product | Lots: $NoOfLotsPurchaseAtaTime | Qty: $Quantity | Order: $Order_type" -ForegroundColor Cyan
Write-Host "  Window: $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "  Monitoring: $PlacedOrdersDir" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Fetching $optExchange PE instruments..." -ForegroundColor Yellow

$optData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'PE' -Headers $headers
if (-not $optData) { exit 1 }

$peOptions  = $optData.Options
$allStrikes = $optData.Strikes
$nearestExpiry = $optData.Expiry

Write-Host "  Expiry: $nearestExpiry | PE Strikes: $($allStrikes.Count) | Lot Size: $($peOptions[0].LotSize)" -ForegroundColor Green
Write-Host ""
Write-Host "  Waiting for signals from Invoke-KiteHAShortStrategy.ps1..." -ForegroundColor Yellow
Write-Host "  Entry pattern: Short-Entry-*.txt | Exit pattern: Short-Exit-*.txt" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# MAIN LOOP — Monitor for Short Entry/Exit signals and trade ATM PE
# ============================================================================

while ($true) {
    $now = Get-Date

    # Check time window
    if ($now.TimeOfDay -lt $StartTime.TimeOfDay) {
        Write-Host "`r  [$($now.ToString('HH:mm:ss'))] Waiting for start time $($StartTime.ToString('HH:mm:ss'))...   " -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
        continue
    }
    if ($now.TimeOfDay -gt $StopTime.TimeOfDay) {
        # Auto-exit if position is still open at stop time
        if ($script:InPosition -and $script:EntrySymbol) {
            Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME — Force exiting position: $($script:EntrySymbol)" -ForegroundColor Red
            Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety -Tradingsymbol $script:EntrySymbol -Quantity $Quantity -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "PE-TIMEEXIT" -MarketProtection $MarketProtection
            $script:InPosition  = $false
            $script:EntrySymbol = ''
            Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
        }
        Write-Host ""
        Write-Host "  Stop time $($StopTime.ToString('HH:mm:ss')) reached. Exiting script." -ForegroundColor Yellow
        break
    }

    # ------------------------------------------------------------------
    # Check for SHORT ENTRY signal (only if not already in a position)
    # ------------------------------------------------------------------
    if (-not $script:InPosition) {
        $entryFiles = Get-ChildItem -Path $PlacedOrdersDir -Filter "Short-Entry-*.txt" -File -ErrorAction SilentlyContinue
        foreach ($ef in $entryFiles) {
            if ($script:ProcessedFiles.ContainsKey($ef.FullName)) { continue }

            Write-Host ""
            Write-Host "  [$($now.ToString('HH:mm:ss'))] SHORT ENTRY SIGNAL DETECTED: $($ef.Name)" -ForegroundColor Yellow

            # Get current spot price
            $spotPrice = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers
            if ($spotPrice -le 0) {
                Write-Host "  Could not fetch spot price. Skipping this signal." -ForegroundColor Red
                $script:ProcessedFiles[$ef.FullName] = $true
                continue
            }

            # Find ATM PE
            $atmOption = Get-ATMOption -SpotPrice $spotPrice -Options $peOptions -AllStrikes $allStrikes -Offset $ATMOffset
            if (-not $atmOption) {
                Write-Host "  Could not find ATM PE option. Skipping." -ForegroundColor Red
                $script:ProcessedFiles[$ef.FullName] = $true
                continue
            }

            Write-Host "  Spot: $spotPrice | ATM Strike: $($atmOption.Strike) | PE Symbol: $($atmOption.Symbol) | Token: $($atmOption.Token)" -ForegroundColor Cyan

            # Place BUY order for PE with 3% market protection
            $result = Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
                -Tradingsymbol $atmOption.Symbol -Quantity $Quantity `
                -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "PE-ENTRY" -MarketProtection $MarketProtection

            # Delete all Short-Entry files immediately to prevent duplicate orders
            Get-ChildItem -Path $PlacedOrdersDir -Filter "Short-Entry-*.txt" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            if ($result) {
                $script:InPosition  = $true
                $script:EntrySymbol = $atmOption.Symbol
                $script:EntryToken  = $atmOption.Token
                $script:EntryStrike = $atmOption.Strike
                $script:EntryPrice  = $spotPrice
                $script:EntryTime   = $now.ToString('HH:mm:ss')
                @{ Symbol=$script:EntrySymbol; Token=$script:EntryToken; Strike=$script:EntryStrike; Price=$script:EntryPrice; Time=$script:EntryTime } | ConvertTo-Json | Set-Content $PositionFile -Force
                Write-Host "  POSITION OPENED | BUY $($script:EntrySymbol) | Strike: $($script:EntryStrike) | Qty: $Quantity" -ForegroundColor Green
            }
        }
    }

    # ------------------------------------------------------------------
    # Check for SHORT EXIT signal (only if in a position)
    # ------------------------------------------------------------------
    if ($script:InPosition) {
        $exitFiles = Get-ChildItem -Path $PlacedOrdersDir -Filter "Short-Exit-*.txt" -File -ErrorAction SilentlyContinue
        foreach ($xf in $exitFiles) {
            if ($script:ProcessedFiles.ContainsKey($xf.FullName)) { continue }

            Write-Host ""
            Write-Host "  [$($now.ToString('HH:mm:ss'))] SHORT EXIT SIGNAL DETECTED: $($xf.Name)" -ForegroundColor Yellow

            # Place SELL order for the same PE symbol we bought
            $result = Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
                -Tradingsymbol $script:EntrySymbol -Quantity $Quantity `
                -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "PE-EXIT" -MarketProtection $MarketProtection

            # Delete all Short-Exit files immediately to prevent duplicate orders
            Get-ChildItem -Path $PlacedOrdersDir -Filter "Short-Exit-*.txt" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            if ($result) {
                Write-Host "  POSITION CLOSED | SELL $($script:EntrySymbol) | Strike: $($script:EntryStrike)" -ForegroundColor Green
                $script:InPosition  = $false
                $script:EntrySymbol = ''
                $script:EntryToken  = 0
                $script:EntryStrike = 0
                $script:EntryPrice  = 0
                $script:EntryTime   = ''
                Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
            }

            $script:ProcessedFiles[$xf.FullName] = $true
            break  # Process one exit at a time
        }
    }

    # ------------------------------------------------------------------
    # Status display (single line overwrite)
    # ------------------------------------------------------------------
    $sym = ''; $ltp = 0; $status = 'ENTRY'
    if (-not $script:InPosition) {
        $spotNow = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers -ErrorAction SilentlyContinue
        $atmNow = if ($spotNow -gt 0) { Get-ATMOption -SpotPrice $spotNow -Options $peOptions -AllStrikes $allStrikes -Offset $ATMOffset } else { $null }
        if ($atmNow) { $sym = $atmNow.Strike }
    } else {
        $sym = $script:EntryStrike; $status = 'EXIT'
    }
    if ($sym) {
        $optSym = if ($script:InPosition) { $script:EntrySymbol } else { $atmNow.Symbol }
        try { $r = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:${optSym}"))" -Headers $headers -ErrorAction Stop; foreach ($p in $r.data.PSObject.Properties) { $ltp = $p.Value.last_price; break } } catch {}
    }
    $color = if ($script:InPosition) { 'Green' } else { 'DarkGray' }
    Write-Host "`r  $($now.ToString('HH:mm:ss')) | PE $sym @ $ltp | $status   " -NoNewline -ForegroundColor $color

    Start-Sleep -Seconds 2
}
