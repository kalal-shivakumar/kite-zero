<#
.SYNOPSIS
  CE Option Buyer — monitors HA Long strategy signals and auto-trades ATM CE.
.DESCRIPTION
  Runs continuously alongside Invoke-KiteHALongStrategy.ps1.
  When a Long-Entry file appears in PlacedOrders/, it immediately:
    1. Fetches current spot price
    2. Finds the ATM CE strike
    3. Places a BUY order for that CE option
    4. Remembers the trading symbol
  When a Long-Exit file appears, it places a SELL order for the same CE
  option to exit the trade.
.EXAMPLE
  .\CE-BUY.ps1
  .\CE-BUY.ps1 -IndexChoosen BANKNIFTY -NoOfLotsPurchaseAtaTime 2
  .\CE-BUY.ps1 -IndexChoosen NIFTY -Product MIS
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
$script:EntryOptionLTP   = 0
$script:TotalPnL         = 0
$script:TradeCount       = 0
$script:TradeHistory     = @()
$script:ProcessedFiles   = @{}

# Persist position state to file so script remembers after restart
$PositionFile = Join-Path $PlacedOrdersDir 'CE-Position.json'
if (Test-Path $PositionFile) {
    $saved = Get-Content $PositionFile -Raw | ConvertFrom-Json
    $script:InPosition  = $true
    $script:EntrySymbol = $saved.Symbol
    $script:EntryToken  = $saved.Token
    $script:EntryStrike = $saved.Strike
    $script:EntryPrice  = $saved.Price
    $script:EntryTime   = $saved.Time
    $script:EntryOptionLTP = if ($saved.OptionLTP) { $saved.OptionLTP } else { 0 }
    $script:TotalPnL       = if ($saved.TotalPnL)  { $saved.TotalPnL }  else { 0 }
    $script:TradeCount     = if ($saved.TradeCount) { [int]$saved.TradeCount } else { 0 }
    Write-Host "  Restored position: $($script:EntrySymbol) | Strike: $($script:EntryStrike) | Entry LTP: $($script:EntryOptionLTP)" -ForegroundColor Yellow
}

# ================================================================
# Fetch CE option instruments (once at startup)
# ================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  CE-BUY | Index: $IndexChoosen | Mode: $ModeOfTrading" -ForegroundColor Cyan
Write-Host "  Product: $Product | Lots: $NoOfLotsPurchaseAtaTime | Qty: $Quantity | Order: $Order_type" -ForegroundColor Cyan
Write-Host "  Window: $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "  Monitoring: $PlacedOrdersDir" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Fetching $optExchange CE instruments..." -ForegroundColor Yellow

$optData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'CE' -Headers $headers
if (-not $optData) { exit 1 }

$ceOptions  = $optData.Options
$allStrikes = $optData.Strikes
$nearestExpiry = $optData.Expiry

Write-Host "  Expiry: $nearestExpiry | CE Strikes: $($allStrikes.Count) | Lot Size: $($ceOptions[0].LotSize)" -ForegroundColor Green
Write-Host ""
Write-Host "  Waiting for signals from Invoke-KiteHALongStrategy.ps1..." -ForegroundColor Yellow
Write-Host "  Entry pattern: Long-Entry-*.txt | Exit pattern: Long-Exit-*.txt" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# MAIN LOOP — Monitor for Long Entry/Exit signals and trade ATM CE
# ============================================================================

while ($true) {
    $now = Get-Date

    # Check time window
    if ($now.TimeOfDay -lt $StartTime.TimeOfDay) {
        Write-Host "`r  [$($now.ToString('HH:mm:ss'))] Waiting for start time $($StartTime.ToString('HH:mm:ss'))...   " -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 100
        continue
    }
    if ($now.TimeOfDay -gt $StopTime.TimeOfDay) {
        # Auto-exit if position is still open at stop time
        if ($script:InPosition -and $script:EntrySymbol) {
            Write-Host "  [$($now.ToString('HH:mm:ss'))] STOP TIME — Force exiting position: $($script:EntrySymbol)" -ForegroundColor Red
            Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety -Tradingsymbol $script:EntrySymbol -Quantity $Quantity -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "CE-TIMEEXIT" -MarketProtection $MarketProtection
            $script:InPosition  = $false
            $script:EntrySymbol = ''
            Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
        }
        Write-Host ""
        Write-Host "  Stop time $($StopTime.ToString('HH:mm:ss')) reached. Exiting script." -ForegroundColor Yellow
        break
    }

    # ------------------------------------------------------------------
    # Check for LONG ENTRY signal (only if not already in a position)
    # ------------------------------------------------------------------
    if (-not $script:InPosition) {
        $entryFiles = Get-ChildItem -Path $PlacedOrdersDir -Filter "Long-Entry-*.txt" -File -ErrorAction SilentlyContinue
        foreach ($ef in $entryFiles) {
            if ($script:ProcessedFiles.ContainsKey($ef.FullName)) { continue }

            Write-Host ""
            Write-Host "  [$($now.ToString('HH:mm:ss'))] LONG ENTRY SIGNAL DETECTED: $($ef.Name)" -ForegroundColor Yellow

            # Delete ALL Long-Entry files IMMEDIATELY on detection
            Get-ChildItem -Path $PlacedOrdersDir -Filter "Long-Entry-*.txt" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            # Get current spot price
            $spotPrice = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers
            if ($spotPrice -le 0) {
                Write-Host "  Could not fetch spot price. Skipping this signal." -ForegroundColor Red
                $script:ProcessedFiles[$ef.FullName] = $true
                continue
            }

            # Find ATM CE
            $atmOption = Get-ATMOption -SpotPrice $spotPrice -Options $ceOptions -AllStrikes $allStrikes -Offset (-$ATMOffset)
            if (-not $atmOption) {
                Write-Host "  Could not find ATM CE option. Skipping." -ForegroundColor Red
                $script:ProcessedFiles[$ef.FullName] = $true
                continue
            }

            Write-Host "  Spot: $spotPrice | ATM Strike: $($atmOption.Strike) | CE Symbol: $($atmOption.Symbol) | Token: $($atmOption.Token)" -ForegroundColor Cyan

            # Place BUY order with 3% market protection
            $result = Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
                -Tradingsymbol $atmOption.Symbol -Quantity $Quantity `
                -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "CE-ENTRY" -MarketProtection $MarketProtection

            if ($result) {
                # Fetch option LTP right after order to track entry premium
                $script:EntryOptionLTP = 0
                try {
                    $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$($atmOption.Symbol)"))" -Headers $headers -ErrorAction Stop
                    foreach ($p in $qr.data.PSObject.Properties) { $script:EntryOptionLTP = $p.Value.last_price; break }
                } catch {}
                $script:InPosition  = $true
                $script:EntrySymbol = $atmOption.Symbol
                $script:EntryToken  = $atmOption.Token
                $script:EntryStrike = $atmOption.Strike
                $script:EntryPrice  = $spotPrice
                $script:EntryTime   = $now.ToString('HH:mm:ss')
                $script:TradeCount++
                $script:TradeHistory += [PSCustomObject]@{ Num=$script:TradeCount; Type='ENTRY'; Strike=$script:EntryStrike; Symbol=$script:EntrySymbol; LTP=$script:EntryOptionLTP; Spot=$spotPrice; Time=$script:EntryTime; PnL=$null }
                @{ Symbol=$script:EntrySymbol; Token=$script:EntryToken; Strike=$script:EntryStrike; Price=$script:EntryPrice; Time=$script:EntryTime; OptionLTP=$script:EntryOptionLTP; TotalPnL=$script:TotalPnL; TradeCount=$script:TradeCount } | ConvertTo-Json | Set-Content $PositionFile -Force
            }
        }
    }

    # ------------------------------------------------------------------
    # Check for LONG EXIT signal (only if in a position)
    # ------------------------------------------------------------------
    if ($script:InPosition) {
        $exitFiles = Get-ChildItem -Path $PlacedOrdersDir -Filter "Long-Exit-*.txt" -File -ErrorAction SilentlyContinue
        foreach ($xf in $exitFiles) {
            if ($script:ProcessedFiles.ContainsKey($xf.FullName)) { continue }

            Write-Host ""
            Write-Host "  [$($now.ToString('HH:mm:ss'))] LONG EXIT SIGNAL DETECTED: $($xf.Name)" -ForegroundColor Yellow

            # Delete all Long-Exit files FIRST to prevent duplicate orders
            Get-ChildItem -Path $PlacedOrdersDir -Filter "Long-Exit-*.txt" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            # Place SELL order for the same CE symbol we bought
            $result = Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
                -Tradingsymbol $script:EntrySymbol -Quantity $Quantity `
                -OrderType $Order_type -Product $Product -Exchange $exchange -Tag "CE-EXIT" -MarketProtection $MarketProtection

            if ($result) {
                # Calculate realized P&L for this trade
                $exitLTP = 0
                try {
                    $qr = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:$($script:EntrySymbol)"))" -Headers $headers -ErrorAction Stop
                    foreach ($p in $qr.data.PSObject.Properties) { $exitLTP = $p.Value.last_price; break }
                } catch {}
                $tradePnL = ($exitLTP - $script:EntryOptionLTP) * $Quantity
                $script:TotalPnL += $tradePnL
                $script:TradeHistory += [PSCustomObject]@{ Num=$script:TradeCount; Type='EXIT'; Strike=$script:EntryStrike; Symbol=$script:EntrySymbol; LTP=$exitLTP; Spot=0; Time=$now.ToString('HH:mm:ss'); PnL=$tradePnL }
                $script:InPosition  = $false
                $script:EntrySymbol = ''
                $script:EntryToken  = 0
                $script:EntryStrike = 0
                $script:EntryPrice  = 0
                $script:EntryTime   = ''
                $script:EntryOptionLTP = 0
                Remove-Item $PositionFile -Force -ErrorAction SilentlyContinue
            }

            $script:ProcessedFiles[$xf.FullName] = $true
            break  # Process one exit at a time
        }
    }

    # ------------------------------------------------------------------
    # Dashboard display (full screen refresh)
    # ------------------------------------------------------------------
    $spotNow = 0; $atmNow = $null; $ltp = 0; $optSym = ''
    $spotNow = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers -ErrorAction SilentlyContinue
    if (-not $script:InPosition) {
        $atmNow = if ($spotNow -gt 0) { Get-ATMOption -SpotPrice $spotNow -Options $ceOptions -AllStrikes $allStrikes -Offset (-$ATMOffset) } else { $null }
        if ($atmNow) { $optSym = $atmNow.Symbol }
    } else {
        $optSym = $script:EntrySymbol
    }
    if ($optSym) {
        try { $r = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([System.Uri]::EscapeDataString("${optExchange}:${optSym}"))" -Headers $headers -ErrorAction Stop; foreach ($p in $r.data.PSObject.Properties) { $ltp = $p.Value.last_price; break } } catch {}
    }

    $unrealizedPnL = if ($script:InPosition -and $script:EntryOptionLTP -gt 0 -and $ltp -gt 0) { ($ltp - $script:EntryOptionLTP) * $Quantity } else { 0 }
    $dayPnL = $script:TotalPnL + $unrealizedPnL

    Clear-Host
    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════════════════════════════╗' -ForegroundColor Green
    Write-Host '  ║' -NoNewline -ForegroundColor Green; Write-Host '        ▲▲▲  CE OPTION BUYER — LIVE DASHBOARD  ▲▲▲' -NoNewline -ForegroundColor White; Write-Host '              ║' -ForegroundColor Green
    Write-Host '  ╠══════════════════════════════════════════════════════════════════════╣' -ForegroundColor Green
    Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Index  : $($IndexChoosen.PadRight(12))" -NoNewline -ForegroundColor Cyan; Write-Host " Expiry : $($nearestExpiry.PadRight(14))" -NoNewline -ForegroundColor White; Write-Host " Mode: $($ModeOfTrading.PadRight(15))" -NoNewline -ForegroundColor Cyan; Write-Host "║" -ForegroundColor Green
    Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Product: $($Product.PadRight(12))" -NoNewline -ForegroundColor Cyan; Write-Host " Lots   : $($NoOfLotsPurchaseAtaTime.ToString().PadRight(14))" -NoNewline -ForegroundColor White; Write-Host " Qty : $($Quantity.ToString().PadRight(15))" -NoNewline -ForegroundColor Cyan; Write-Host "║" -ForegroundColor Green
    Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Order  : $($Order_type.PadRight(12))" -NoNewline -ForegroundColor Cyan; Write-Host " Window : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss'))                    " -NoNewline -ForegroundColor White; Write-Host "║" -ForegroundColor Green
    Write-Host '  ╠══════════════════════════════════════════════════════════════════════╣' -ForegroundColor Green

    if ($script:InPosition) {
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "POSITION : " -NoNewline -ForegroundColor White; Write-Host "██ LONG ACTIVE ██" -NoNewline -ForegroundColor Green -BackgroundColor DarkGreen; Write-Host "                                     ║" -ForegroundColor Green
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Symbol   : " -NoNewline -ForegroundColor Gray; Write-Host "$($script:EntrySymbol.PadRight(56))" -NoNewline -ForegroundColor Yellow; Write-Host "║" -ForegroundColor Green
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Strike   : " -NoNewline -ForegroundColor Gray; Write-Host "$($script:EntryStrike.ToString().PadRight(18))" -NoNewline -ForegroundColor Yellow; Write-Host " Entry LTP: " -NoNewline -ForegroundColor Gray; Write-Host "$($script:EntryOptionLTP.ToString('N2').PadRight(14))" -NoNewline -ForegroundColor Cyan; Write-Host " Time: $($script:EntryTime.PadRight(8))" -NoNewline -ForegroundColor White; Write-Host "║" -ForegroundColor Green
        $unrlColor = if ($unrealizedPnL -ge 0) { 'Green' } else { 'Red' }
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Spot     : " -NoNewline -ForegroundColor Gray; Write-Host "$($spotNow.ToString('N2').PadRight(18))" -NoNewline -ForegroundColor White; Write-Host " Opt LTP  : " -NoNewline -ForegroundColor Gray; Write-Host "$($ltp.ToString('N2').PadRight(14))" -NoNewline -ForegroundColor Yellow; Write-Host " Unrl: " -NoNewline -ForegroundColor Gray; Write-Host "$($unrealizedPnL.ToString('N2').PadRight(8))" -NoNewline -ForegroundColor $unrlColor; Write-Host "║" -ForegroundColor Green
    } else {
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "POSITION : " -NoNewline -ForegroundColor White; Write-Host "FLAT  (Waiting for Long Entry signal)                  " -NoNewline -ForegroundColor DarkGray; Write-Host "║" -ForegroundColor Green
        $atmStrike = if ($atmNow) { $atmNow.Strike.ToString() } else { '--' }
        $atmSym = if ($atmNow) { $atmNow.Symbol } else { '--' }
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Spot     : " -NoNewline -ForegroundColor Gray; Write-Host "$($spotNow.ToString('N2').PadRight(18))" -NoNewline -ForegroundColor White; Write-Host " ATM CE   : " -NoNewline -ForegroundColor Gray; Write-Host "$($atmStrike.PadRight(30))" -NoNewline -ForegroundColor Cyan; Write-Host "║" -ForegroundColor Green
        Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Next CE  : " -NoNewline -ForegroundColor Gray; Write-Host "$($atmSym.PadRight(42))" -NoNewline -ForegroundColor Cyan; Write-Host " LTP: " -NoNewline -ForegroundColor Gray; Write-Host "$($ltp.ToString('N2').PadRight(8))" -NoNewline -ForegroundColor Yellow; Write-Host "║" -ForegroundColor Green
    }

    Write-Host '  ╠══════════════════════════════════════════════════════════════════════╣' -ForegroundColor Green
    $realPnLStr = $script:TotalPnL.ToString('N2')
    $dayPnLStr  = $dayPnL.ToString('N2')
    $realColor = if ($script:TotalPnL -ge 0) { 'Green' } else { 'Red' }
    $dayColor  = if ($dayPnL -ge 0) { 'Green' } else { 'Red' }
    Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "Trades : $($script:TradeCount.ToString().PadRight(8))" -NoNewline -ForegroundColor White; Write-Host " Realized P&L: " -NoNewline -ForegroundColor Gray; Write-Host "$($realPnLStr.PadRight(14))" -NoNewline -ForegroundColor $realColor; Write-Host " Day P&L: " -NoNewline -ForegroundColor Gray; Write-Host "$($dayPnLStr.PadRight(10))" -NoNewline -ForegroundColor $dayColor; Write-Host "║" -ForegroundColor Green
    Write-Host '  ╠══════════════════════════════════════════════════════════════════════╣' -ForegroundColor Green

    if ($script:TradeHistory.Count -gt 0) {
        Write-Host '  ║' -NoNewline -ForegroundColor Green; Write-Host '   #  Type   Strike      Symbol                    Opt LTP   P&L    ' -NoNewline -ForegroundColor DarkCyan; Write-Host ' ║' -ForegroundColor Green
        Write-Host '  ║' -NoNewline -ForegroundColor Green; Write-Host '  ─────────────────────────────────────────────────────────────────── ' -NoNewline -ForegroundColor DarkGreen; Write-Host '║' -ForegroundColor Green
        $showCount = [Math]::Min(20, $script:TradeHistory.Count)
        $startIdx = $script:TradeHistory.Count - $showCount
        for ($i = $startIdx; $i -lt $script:TradeHistory.Count; $i++) {
            $t = $script:TradeHistory[$i]
            $pnlStr = if ($null -ne $t.PnL) { $t.PnL.ToString('N2') } else { '' }
            $line = " {0,2}  {1,-6} {2,-10} {3,-25} {4,8} {5,8} " -f $t.Num, $t.Type, $t.Strike, $t.Symbol, $t.LTP.ToString('N2'), $pnlStr
            $rowColor = if ($t.Type -eq 'ENTRY') { 'Green' } elseif ($null -ne $t.PnL -and $t.PnL -ge 0) { 'Cyan' } else { 'Red' }
            Write-Host '  ║' -NoNewline -ForegroundColor Green; Write-Host $line -NoNewline -ForegroundColor $rowColor; Write-Host '║' -ForegroundColor Green
        }
    } else {
        Write-Host '  ║' -NoNewline -ForegroundColor Green; Write-Host '  No trades yet — waiting for signals...                             ' -NoNewline -ForegroundColor DarkGray; Write-Host '║' -ForegroundColor Green
    }

    Write-Host '  ╠══════════════════════════════════════════════════════════════════════╣' -ForegroundColor Green
    Write-Host "  ║  " -NoNewline -ForegroundColor Green; Write-Host "$($now.ToString('yyyy-MM-dd HH:mm:ss'))" -NoNewline -ForegroundColor White; Write-Host "  |  Monitoring: PlacedOrders/  |  " -NoNewline -ForegroundColor DarkGray; Write-Host "Ctrl+C to stop" -NoNewline -ForegroundColor Yellow; Write-Host "   ║" -ForegroundColor Green
    Write-Host '  ╚══════════════════════════════════════════════════════════════════════╝' -ForegroundColor Green

    Start-Sleep -Milliseconds 100
}
