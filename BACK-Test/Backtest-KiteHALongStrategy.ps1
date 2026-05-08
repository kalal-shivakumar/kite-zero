<#
.SYNOPSIS
  Backtest Heikin-Ashi Long-only strategy using historical candle data.
.DESCRIPTION
  Fetches historical OHLCV data from Kite Connect API, converts to Heikin-Ashi
  candles, and simulates the Long strategy (same logic as Invoke-KiteHALongStrategy).
  
  Entry: HA Close > Previous HA High  (Long Entry)
  Exit:  HA Close < Previous HA Low   (Long Exit)
  
  Generates a detailed report with all trades, win/loss stats, and P&L summary.
.PARAMETER TradingSymbol
  Symbol name (must be in presets). Default: NIFTY
.PARAMETER StartDate
  Start date for backtest. Use 0 for today, -1 for yesterday, -7 for 7 days ago, or yyyy-MM-dd format.
.PARAMETER EndDate
  End date for backtest. Use 0 for today, -1 for yesterday, or yyyy-MM-dd format.
.EXAMPLE
  .\Backtest-KiteHALongStrategy.ps1 -TradingSymbol NIFTY -StartDate 0 -EndDate 0
  .\Backtest-KiteHALongStrategy.ps1 -TradingSymbol NATGASMINI -StartDate -7 -EndDate 0
  .\Backtest-KiteHALongStrategy.ps1 -TradingSymbol BANKNIFTY -StartDate "2026-04-20" -EndDate "2026-04-25"
#>

param(
    [string]$TradingSymbol  = 'NIFTY',
    [int]$InstrumentToken,
    [Parameter(Mandatory = $true)]
    [string]$StartDate      = '0',
    [string]$EndDate        = '-1',
    [ValidateSet('15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame      = 'minute',
    [string]$StartTime      = '09:16',
    [string]$EndTime        = '15:30',
    [string]$LastEntryTime  = '15:29',
    [double]$StopLoss        = 5,
    [string]$AccessToken,
    [string]$API_Key        = '0fvxhlacu555dhp0',
    [string]$API_Secret     = '69wajxn41hj77pze3xnhw1dp442auw8t'
)

# Import the module
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$rootDir = Split-Path -Parent $scriptDir
Import-Module "$rootDir\KiteData.psm1" -Force

# ================================================================
# Resolve dates (0 = today, -N = N days ago, or yyyy-MM-dd)
# ================================================================
function Resolve-BacktestDate([string]$dateVal) {
    if ($dateVal -match '^-?\d+$') {
        $days = [int]$dateVal
        return (Get-Date).AddDays($days).ToString('yyyy-MM-dd')
    }
    return $dateVal
}

$fromDate = Resolve-BacktestDate $StartDate
$toDate   = Resolve-BacktestDate $EndDate

# ================================================================
# Resolve access token
# ================================================================
$tokenFile = Join-Path $rootDir 'accesstoken.json'
if (-not $AccessToken) {
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
}

# ================================================================
# Resolve symbol
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

# ================================================================
# Fetch historical candle data
# ================================================================
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  BACKTEST: HA Long Strategy" -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  Symbol    : $sym ($label)" -ForegroundColor White
Write-Host "  Token     : $instToken" -ForegroundColor White
Write-Host "  TimeFrame : $TimeFrame" -ForegroundColor White
Write-Host "  Period    : $fromDate to $toDate" -ForegroundColor White
Write-Host "  Time      : $StartTime to $EndTime" -ForegroundColor White
# Determine SL mode: points for NIFTY/SENSEX, percentage for others
$isIndex = $sym -match '^(NIFTY|SENSEX|BANKNIFTY)$'
if ($isIndex) {
    if (-not $PSBoundParameters.ContainsKey('StopLoss')) {
        if ($sym -eq 'SENSEX') { $StopLoss = 50 }
        elseif ($sym -eq 'BANKNIFTY') { $StopLoss = 50 }
        else { $StopLoss = 30 }
    }
    Write-Host "  StopLoss  : $StopLoss pts (index)" -ForegroundColor White
} else {
    Write-Host "  StopLoss  : $StopLoss%" -ForegroundColor White
}
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Fetching historical data..." -ForegroundColor Yellow

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

$histUrl = "https://api.kite.trade/instruments/historical/$instToken/$TimeFrame`?from=$fromDate+00:00:00&to=$toDate+23:59:59"

try {
    $resp = Invoke-RestMethod -Uri $histUrl -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Host "  Failed to fetch historical data: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "  $($_.ErrorDetails.Message)" -ForegroundColor Yellow }
    exit 1
}

if (-not $resp.data -or -not $resp.data.candles -or $resp.data.candles.Count -eq 0) {
    Write-Host "  No candle data returned for the given period." -ForegroundColor Red
    exit 1
}

$rawCandles = $resp.data.candles
Write-Host "  Received $($rawCandles.Count) candles." -ForegroundColor Green
Write-Host ""

# ================================================================
# Convert raw candles to Heikin-Ashi
# ================================================================
$haCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
$prevHA = $null

foreach ($c in $rawCandles) {
    # Kite candle format: [timestamp, open, high, low, close, volume]
    $timestamp = $c[0]
    $open  = [double]$c[1]
    $high  = [double]$c[2]
    $low   = [double]$c[3]
    $close = [double]$c[4]
    $vol   = [long]$c[5]

    # HA calculation
    $haClose = ($open + $high + $low + $close) / 4.0
    if ($null -ne $prevHA) {
        $haOpen = ($prevHA.Open + $prevHA.Close) / 2.0
    } else {
        $haOpen = ($open + $close) / 2.0
    }
    $haHigh = [Math]::Max($high, [Math]::Max($haOpen, $haClose))
    $haLow  = [Math]::Min($low, [Math]::Min($haOpen, $haClose))

    $candle = [PSCustomObject]@{
        Time   = $timestamp
        Open   = [Math]::Round($haOpen, 2)
        High   = [Math]::Round($haHigh, 2)
        Low    = [Math]::Round($haLow, 2)
        Close  = [Math]::Round($haClose, 2)
        Volume = $vol
        RawClose = $close  # actual close price for trade execution
    }
    $haCandles.Add($candle)
    $prevHA = $candle
}

# ================================================================
# Filter candles by time window
# ================================================================
$startTimeSpan = [TimeSpan]::Parse($StartTime)
$endTimeSpan   = [TimeSpan]::Parse($EndTime)

$filteredCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($ha in $haCandles) {
    $ts = $ha.Time
    if ($ts -is [string]) {
        try { $ts = [DateTime]::Parse($ts) } catch { continue }
    }
    $tod = $ts.TimeOfDay
    if ($tod -ge $startTimeSpan -and $tod -le $endTimeSpan) {
        $filteredCandles.Add($ha)
    }
}

Write-Host "  Filtered to $($filteredCandles.Count) candles ($StartTime - $EndTime)." -ForegroundColor Green
$haCandles = $filteredCandles

# ================================================================
# Simulate Long Strategy
# ================================================================
$trades      = [System.Collections.Generic.List[PSCustomObject]]::new()
$inPosition  = $false
$entryPrice  = 0.0
$entryTime   = ''
$entryIdx    = 0

$lastEntrySpan = [TimeSpan]::Parse($LastEntryTime)

for ($i = 1; $i -lt $haCandles.Count; $i++) {
    $current  = $haCandles[$i]
    $previous = $haCandles[$i - 1]

    # Get current candle time for entry cutoff
    $cTime = $current.Time
    if ($cTime -is [string]) { try { $cTime = [DateTime]::Parse($cTime) } catch {} }
    $candleTOD = $cTime.TimeOfDay

    # LONG ENTRY: current HA Close > previous HA High (no open position, before last entry time)
    if ((-not $inPosition) -and ($candleTOD -le $lastEntrySpan) -and ($current.Close -gt $previous.High)) {
        $inPosition = $true
        $entryPrice = $current.RawClose
        $entryTime  = $current.Time
        $entryIdx   = $i
    }

    # STOP LOSS: points for index, percentage for others
    $slPoints = if ($isIndex) { $StopLoss } else { [Math]::Round($entryPrice * $StopLoss / 100, 2) }
    if ($inPosition -and $StopLoss -gt 0 -and ($current.RawClose -le ($entryPrice - $slPoints))) {
        $exitPrice = [Math]::Round($entryPrice - $slPoints, 2)
        $pnl = [Math]::Round($exitPrice - $entryPrice, 2)
        $pnlPct = [Math]::Round(($pnl / $entryPrice) * 100, 2)

        $trades.Add([PSCustomObject]@{
            EntryTime  = $entryTime
            ExitTime   = "$($current.Time) (SL)"
            EntryPrice = $entryPrice
            ExitPrice  = $exitPrice
            PnL        = $pnl
            PnLPct     = $pnlPct
            Candles    = $i - $entryIdx
        })

        $inPosition = $false
        $entryPrice = 0.0
        $entryTime  = ''
        continue
    }

    # LONG EXIT: current HA Close < previous HA Low (position open)
    if ($inPosition -and ($current.Close -lt $previous.Low)) {
        $exitPrice = $current.RawClose
        $pnl = [Math]::Round($exitPrice - $entryPrice, 2)
        $pnlPct = [Math]::Round(($pnl / $entryPrice) * 100, 2)

        $trades.Add([PSCustomObject]@{
            EntryTime  = $entryTime
            ExitTime   = $current.Time
            EntryPrice = $entryPrice
            ExitPrice  = $exitPrice
            PnL        = $pnl
            PnLPct     = $pnlPct
            Candles    = $i - $entryIdx
        })

        $inPosition = $false
        $entryPrice = 0.0
        $entryTime  = ''
    }
}

# If still in position at end, close at last candle
if ($inPosition) {
    $lastCandle = $haCandles[$haCandles.Count - 1]
    $exitPrice = $lastCandle.RawClose
    $pnl = [Math]::Round($exitPrice - $entryPrice, 2)
    $pnlPct = [Math]::Round(($pnl / $entryPrice) * 100, 2)
    $trades.Add([PSCustomObject]@{
        EntryTime  = $entryTime
        ExitTime   = "$($lastCandle.Time) (EOD)"
        EntryPrice = $entryPrice
        ExitPrice  = $exitPrice
        PnL        = $pnl
        PnLPct     = $pnlPct
        Candles    = ($haCandles.Count - 1) - $entryIdx
    })
}

# ================================================================
# Generate Report
# ================================================================
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  BACKTEST REPORT: HA Long Strategy" -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  Symbol    : $sym ($label)" -ForegroundColor White
Write-Host "  TimeFrame : $TimeFrame" -ForegroundColor White
Write-Host "  Period    : $fromDate to $toDate" -ForegroundColor White
Write-Host "  Time      : $StartTime to $EndTime" -ForegroundColor White
Write-Host "  Candles   : $($haCandles.Count)" -ForegroundColor White
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""

if ($trades.Count -eq 0) {
    Write-Host "  No trades generated in this period." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Trade list
Write-Host "  TRADES ($($trades.Count) total):" -ForegroundColor Yellow
Write-Host "  -------------------------------------------------------------------------------" -ForegroundColor DarkGray
$fmt = "  {0,4} {1,-22} {2,-22} {3,10} {4,10} {5,10} {6,8} {7,6}"
Write-Host ($fmt -f "#", "Entry Time", "Exit Time", "Entry", "Exit", "P&L", "P&L%", "Bars") -ForegroundColor Cyan
Write-Host "  -------------------------------------------------------------------------------" -ForegroundColor DarkGray

$tradeNum = 0
foreach ($t in $trades) {
    $tradeNum++
    $color = if ($t.PnL -ge 0) { 'Green' } else { 'Red' }
    $pnlStr = if ($t.PnL -ge 0) { "+$($t.PnL)" } else { "$($t.PnL)" }
    $pctStr = if ($t.PnLPct -ge 0) { "+$($t.PnLPct)%" } else { "$($t.PnLPct)%" }
    Write-Host ($fmt -f $tradeNum, $t.EntryTime, $t.ExitTime, $t.EntryPrice, $t.ExitPrice, $pnlStr, $pctStr, $t.Candles) -ForegroundColor $color
}

Write-Host "  -------------------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# Statistics
$totalPnL   = [Math]::Round(($trades | Measure-Object -Property PnL -Sum).Sum, 2)
$winners    = @($trades | Where-Object { $_.PnL -gt 0 })
$losers     = @($trades | Where-Object { $_.PnL -lt 0 })
$breakeven  = @($trades | Where-Object { $_.PnL -eq 0 })
$winRate    = if ($trades.Count -gt 0) { [Math]::Round(($winners.Count / $trades.Count) * 100, 1) } else { 0 }
$avgPnL     = [Math]::Round($totalPnL / $trades.Count, 2)
$avgWin     = if ($winners.Count -gt 0) { [Math]::Round(($winners | Measure-Object -Property PnL -Sum).Sum / $winners.Count, 2) } else { 0 }
$avgLoss    = if ($losers.Count -gt 0) { [Math]::Round(($losers | Measure-Object -Property PnL -Sum).Sum / $losers.Count, 2) } else { 0 }
$maxWin     = if ($winners.Count -gt 0) { ($winners | Measure-Object -Property PnL -Maximum).Maximum } else { 0 }
$maxLoss    = if ($losers.Count -gt 0) { ($losers | Measure-Object -Property PnL -Minimum).Minimum } else { 0 }
$profitFactor = if ($losers.Count -gt 0 -and ($losers | Measure-Object -Property PnL -Sum).Sum -ne 0) {
    [Math]::Round([Math]::Abs(($winners | Measure-Object -Property PnL -Sum).Sum / ($losers | Measure-Object -Property PnL -Sum).Sum), 2)
} else { 'N/A' }

# Max drawdown
$cumPnL = 0.0; $peak = 0.0; $maxDD = 0.0
foreach ($t in $trades) {
    $cumPnL += $t.PnL
    if ($cumPnL -gt $peak) { $peak = $cumPnL }
    $dd = $peak - $cumPnL
    if ($dd -gt $maxDD) { $maxDD = $dd }
}
$maxDD = [Math]::Round($maxDD, 2)

# Consecutive wins/losses
$maxConsecWins = 0; $maxConsecLosses = 0; $cw = 0; $cl = 0
foreach ($t in $trades) {
    if ($t.PnL -gt 0) { $cw++; $cl = 0; if ($cw -gt $maxConsecWins) { $maxConsecWins = $cw } }
    elseif ($t.PnL -lt 0) { $cl++; $cw = 0; if ($cl -gt $maxConsecLosses) { $maxConsecLosses = $cl } }
    else { $cw = 0; $cl = 0 }
}

Write-Host "  SUMMARY:" -ForegroundColor Yellow
Write-Host "  ====================================================" -ForegroundColor DarkGray
$totalPnLPct = [Math]::Round(($trades | Measure-Object -Property PnLPct -Sum).Sum, 2)
$avgPnLPct   = [Math]::Round($totalPnLPct / $trades.Count, 2)
$summColor = if ($totalPnL -ge 0) { 'Green' } else { 'Red' }
Write-Host "  Total P&L           : $totalPnL ($totalPnLPct%)" -ForegroundColor $summColor
Write-Host "  Total Trades        : $($trades.Count)" -ForegroundColor White
Write-Host "  Winners             : $($winners.Count) ($winRate%)" -ForegroundColor Green
Write-Host "  Losers              : $($losers.Count)" -ForegroundColor Red
Write-Host "  Breakeven           : $($breakeven.Count)" -ForegroundColor Gray
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host "  Avg P&L per Trade   : $avgPnL ($avgPnLPct%)" -ForegroundColor White
Write-Host "  Avg Win             : $avgWin" -ForegroundColor Green
Write-Host "  Avg Loss            : $avgLoss" -ForegroundColor Red
Write-Host "  Max Win             : $maxWin" -ForegroundColor Green
Write-Host "  Max Loss            : $maxLoss" -ForegroundColor Red
Write-Host "  Profit Factor       : $profitFactor" -ForegroundColor White
Write-Host "  Max Drawdown        : $maxDD" -ForegroundColor Red
Write-Host "  Max Consec Wins     : $maxConsecWins" -ForegroundColor Green
Write-Host "  Max Consec Losses   : $maxConsecLosses" -ForegroundColor Red
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host ""
