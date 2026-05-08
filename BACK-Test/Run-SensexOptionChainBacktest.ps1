<#
.SYNOPSIS
  Fetch SENSEX option chain (ATM +/- 10 strikes), save to CSV, and run HA Long backtest on all symbols.
.DESCRIPTION
  1. Fetches BFO instruments from Kite API
  2. Finds ATM strike based on current SENSEX price
  3. Gets 10 CE + 10 PE strikes around ATM
  4. Saves option chain to CSV
  5. Runs Backtest-KiteHALongStrategy for each symbol across specified days and timeframes
  6. Outputs consolidated report
.PARAMETER Expiry
  Expiry date in yyyy-MM-dd format. Default: nearest weekly expiry.
.PARAMETER StrikesAboveBelow
  Number of strikes above and below ATM. Default: 10
.EXAMPLE
  .\Run-SensexOptionChainBacktest.ps1 -Expiry "2026-05-07"
  .\Run-SensexOptionChainBacktest.ps1 -Expiry "2026-05-07" -StrikesAboveBelow 5
#>

param(
    [string]$Expiry,
    [int]$StrikesAboveBelow = 10,
    [string[]]$Dates        = @('2026-04-30','2026-05-05','2026-05-06'),
    [string[]]$TimeFrames   = @('minute','3minute'),
    [string]$AccessToken,
    [string]$API_Key        = '0fvxhlacu555dhp0',
    [string]$API_Secret     = '69wajxn41hj77pze3xnhw1dp442auw8t'
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$rootDir = Split-Path -Parent $scriptDir
Import-Module "$rootDir\KiteData.psm1" -Force

# ================================================================
# Resolve access token
# ================================================================
$tokenFile = Join-Path $rootDir 'accesstoken.json'
if (-not $AccessToken) {
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

# ================================================================
# Step 1: Get current SENSEX price (LTP)
# ================================================================
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  SENSEX Option Chain Backtest Runner" -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Fetching SENSEX LTP..." -ForegroundColor Yellow

try {
    $quoteResp = Invoke-RestMethod -Uri "https://api.kite.trade/quote/ltp?i=BSE:SENSEX" -Headers $headers -Method Get -ErrorAction Stop
    $sensexLTP = $quoteResp.data.'BSE:SENSEX'.last_price
    Write-Host "  SENSEX LTP: $sensexLTP" -ForegroundColor Green
} catch {
    Write-Host "  Failed to get SENSEX LTP: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ================================================================
# Step 2: Fetch BFO instruments
# ================================================================
Write-Host "  Fetching BFO instruments..." -ForegroundColor Yellow

try {
    $instResp = Invoke-WebRequest -Uri 'https://api.kite.trade/instruments/BFO' -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Host "  Failed to fetch instruments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Parse CSV
$lines = ($instResp.Content -split "`n")
$headerLine = $lines[0]
$dataLines = $lines[1..($lines.Count-1)] | Where-Object { $_ -match 'SENSEX' -and $_ -match ',CE,|,PE,' }

$options = foreach ($line in $dataLines) {
    $cols = $line -split ','
    if ($cols.Count -ge 12) {
        [PSCustomObject]@{
            Token      = [int]$cols[0]
            Symbol     = $cols[2] -replace '"',''
            Name       = $cols[3] -replace '"',''
            Expiry     = $cols[5]
            Strike     = [double]$cols[6]
            Type       = $cols[9] -replace '"',''   # CE or PE
            Exchange   = $cols[11] -replace '"',''
            Segment    = $cols[10] -replace '"',''
        }
    }
}

# ================================================================
# Step 3: Filter by expiry
# ================================================================
if (-not $Expiry) {
    # Find nearest expiry
    $allExpiries = $options | Select-Object -ExpandProperty Expiry -Unique | Sort-Object
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $Expiry = $allExpiries | Where-Object { $_ -ge $today } | Select-Object -First 1
    if (-not $Expiry) {
        Write-Host "  No valid expiry found." -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Using expiry: $Expiry" -ForegroundColor Green

$expiryOptions = $options | Where-Object { $_.Expiry -eq $Expiry }
$ceOptions = $expiryOptions | Where-Object { $_.Type -eq 'CE' } | Sort-Object Strike
$peOptions = $expiryOptions | Where-Object { $_.Type -eq 'PE' } | Sort-Object Strike

Write-Host "  Found $($ceOptions.Count) CE and $($peOptions.Count) PE options for expiry $Expiry" -ForegroundColor Green

# ================================================================
# Step 4: Find ATM and select strikes
# ================================================================
# Find ATM strike (closest to LTP)
$allStrikes = @($ceOptions | Select-Object -ExpandProperty Strike -Unique | Sort-Object)
$atmStrike = $allStrikes | Sort-Object { [Math]::Abs($_ - $sensexLTP) } | Select-Object -First 1

Write-Host "  ATM Strike: $atmStrike (SENSEX LTP: $sensexLTP)" -ForegroundColor Green

# Get index of ATM in sorted strikes
$atmIdx = [Array]::IndexOf($allStrikes, $atmStrike)
$startIdx = [Math]::Max(0, $atmIdx - $StrikesAboveBelow)
$endIdx   = [Math]::Min($allStrikes.Count - 1, $atmIdx + $StrikesAboveBelow)

$selectedStrikes = $allStrikes[$startIdx..$endIdx]
Write-Host "  Selected $($selectedStrikes.Count) strikes: $($selectedStrikes[0]) to $($selectedStrikes[-1])" -ForegroundColor Green

# Filter CE and PE for selected strikes
$selectedCE = $ceOptions | Where-Object { $_.Strike -in $selectedStrikes }
$selectedPE = $peOptions | Where-Object { $_.Strike -in $selectedStrikes }

$allSelected = @()
$allSelected += $selectedCE
$allSelected += $selectedPE

Write-Host "  Total symbols to backtest: $($allSelected.Count) ($($selectedCE.Count) CE + $($selectedPE.Count) PE)" -ForegroundColor Green

# ================================================================
# Step 5: Save to CSV
# ================================================================
$csvPath = Join-Path $scriptDir "SensexOptionChain_$($Expiry).csv"
$allSelected | Select-Object Token, Symbol, Strike, Type, Expiry | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "  Option chain saved to: $csvPath" -ForegroundColor Green
Write-Host ""

# ================================================================
# Step 6: Run Long Backtest for each symbol
# ================================================================
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  Running HA Long Backtests..." -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$totalSymbols = $allSelected.Count
$symbolNum = 0

foreach ($opt in $allSelected) {
    $symbolNum++
    $sym = $opt.Symbol
    $token = $opt.Token
    $strike = $opt.Strike
    $optType = $opt.Type

    Write-Host "  [$symbolNum/$totalSymbols] $sym (Token: $token, Strike: $strike $optType)" -ForegroundColor White

    foreach ($d in $Dates) {
        foreach ($tf in $TimeFrames) {
            try {
                # Capture the full output (6>&1 captures Write-Host stream)
                $output = & "$scriptDir\Backtest-KiteHALongStrategy.ps1" `
                    -TradingSymbol $sym `
                    -InstrumentToken $token `
                    -StartDate $d `
                    -EndDate $d `
                    -TimeFrame $tf `
                    -AccessToken $AccessToken 6>&1 2>$null

                $outputText = ($output | Out-String)

                # Parse key metrics from output
                $totalPnL = 0; $totalTrades = 0; $winRate = '0%'; $pf = 'N/A'; $maxDD = 0
                
                if ($outputText -match 'Total P&L\s*:\s*([-\d.]+)') { $totalPnL = [double]$Matches[1] }
                if ($outputText -match 'Total Trades\s*:\s*(\d+)') { $totalTrades = [int]$Matches[1] }
                if ($outputText -match 'Winners\s*:\s*\d+\s*\(([^)]+)\)') { $winRate = $Matches[1] }
                if ($outputText -match 'Profit Factor\s*:\s*([\d.]+|N/A)') { $pf = $Matches[1] }
                if ($outputText -match 'Max Drawdown\s*:\s*([\d.]+)') { $maxDD = [double]$Matches[1] }

                if ($outputText -match 'No candle data') { $totalTrades = -1 }

                $results.Add([PSCustomObject]@{
                    Symbol     = $sym
                    Strike     = $strike
                    Type       = $optType
                    Date       = $d
                    TimeFrame  = $tf
                    PnL        = $totalPnL
                    Trades     = $totalTrades
                    WinRate    = $winRate
                    PF         = $pf
                    MaxDD      = $maxDD
                })
            } catch {
                $results.Add([PSCustomObject]@{
                    Symbol     = $sym
                    Strike     = $strike
                    Type       = $optType
                    Date       = $d
                    TimeFrame  = $tf
                    PnL        = 0
                    Trades     = -1
                    WinRate    = '0%'
                    PF         = 'N/A'
                    MaxDD      = 0
                })
            }
        }
    }
}

# ================================================================
# Step 7: Generate Consolidated Report
# ================================================================
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  CONSOLIDATED BACKTEST REPORT: HA Long Strategy" -ForegroundColor Cyan
Write-Host "  Underlying: SENSEX | Expiry: $Expiry" -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""

# Filter out days with no data
$validResults = $results | Where-Object { $_.Trades -ge 0 }

foreach ($d in $Dates) {
    $dayResults = $validResults | Where-Object { $_.Date -eq $d }
    if ($dayResults.Count -eq 0) {
        Write-Host "  DATE: $d — No data (Holiday)" -ForegroundColor DarkGray
        Write-Host ""
        continue
    }

    Write-Host "  ================================================================" -ForegroundColor Yellow
    Write-Host "  DATE: $d" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor Yellow

    foreach ($tf in $TimeFrames) {
        $tfResults = $dayResults | Where-Object { $_.TimeFrame -eq $tf }
        if ($tfResults.Count -eq 0) { continue }

        Write-Host ""
        Write-Host "  TimeFrame: $tf" -ForegroundColor Cyan
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray

        $fmt = "  {0,-28} {1,7} {2,8} {3,6} {4,8} {5,7} {6,7}"
        Write-Host ($fmt -f "Symbol", "Strike", "Type", "P&L", "Trades", "Win%", "PF") -ForegroundColor White
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray

        $dayTotalPnL = 0; $dayTotalTrades = 0

        foreach ($r in ($tfResults | Sort-Object Type, Strike)) {
            if ($r.Trades -eq 0 -and $r.PnL -eq 0) {
                $color = 'DarkGray'
                $pnlStr = "0"
            } else {
                $color = if ($r.PnL -ge 0) { 'Green' } else { 'Red' }
                $pnlStr = if ($r.PnL -ge 0) { "+$($r.PnL)" } else { "$($r.PnL)" }
            }
            Write-Host ($fmt -f $r.Symbol, $r.Strike, $r.Type, $pnlStr, $r.Trades, $r.WinRate, $r.PF) -ForegroundColor $color
            $dayTotalPnL += $r.PnL
            $dayTotalTrades += [Math]::Max(0, $r.Trades)
        }

        Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
        $dayTotalPnL = [Math]::Round($dayTotalPnL, 2)
        $summColor = if ($dayTotalPnL -ge 0) { 'Green' } else { 'Red' }
        Write-Host ("  TOTAL: P&L = {0} | Trades = {1}" -f $dayTotalPnL, $dayTotalTrades) -ForegroundColor $summColor
        Write-Host ""
    }
}

# ================================================================
# Grand Summary
# ================================================================
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  GRAND SUMMARY (All Days Combined)" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($tf in $TimeFrames) {
    $tfAll = $validResults | Where-Object { $_.TimeFrame -eq $tf -and $_.Trades -gt 0 }
    if ($tfAll.Count -eq 0) { continue }

    $grandPnL = [Math]::Round(($tfAll | Measure-Object -Property PnL -Sum).Sum, 2)
    $grandTrades = ($tfAll | Measure-Object -Property Trades -Sum).Sum
    $profitable = @($tfAll | Where-Object { $_.PnL -gt 0 }).Count
    $losing     = @($tfAll | Where-Object { $_.PnL -lt 0 }).Count

    $summColor = if ($grandPnL -ge 0) { 'Green' } else { 'Red' }
    Write-Host "  TimeFrame: $tf" -ForegroundColor White
    Write-Host "    Total P&L       : $grandPnL" -ForegroundColor $summColor
    Write-Host "    Total Trades    : $grandTrades" -ForegroundColor White
    Write-Host "    Symbols Profit  : $profitable" -ForegroundColor Green
    Write-Host "    Symbols Loss    : $losing" -ForegroundColor Red
    Write-Host ""
}

# Save results to CSV
$resultsCsvPath = Join-Path $scriptDir "SensexBacktestResults_$($Expiry).csv"
$validResults | Export-Csv -Path $resultsCsvPath -NoTypeInformation
Write-Host "  Results saved to: $resultsCsvPath" -ForegroundColor Green
Write-Host ""
