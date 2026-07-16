<#
.SYNOPSIS
  Liquidity Sweep swing/sweep analyzer on 1-minute Heikin-Ashi candles.
  READ-ONLY: fetches historical data and analyzes it. Places NO orders.

.DESCRIPTION
  Workflow:
   1. Fetch historical 1-min OHLC for the instrument and convert to Heikin-Ashi.
   2. Detect MAJOR swing highs / swing lows using fractal pivots (strength N on
      each side) plus a minimum-move filter that discards minor swings.
   3. Detect liquidity sweeps between swings:
        - UPSIDE sweep  : candle HIGH pierces a prior swing HIGH but CLOSE comes
                          back below it (stop-hunt above liquidity -> bearish).
        - DOWNSIDE sweep: candle LOW pierces a prior swing LOW but CLOSE comes
                          back above it (stop-hunt below liquidity -> bullish).
   4. Classify each sweep by looking forward up to -ConfirmWindow candles:
        - SUCCESS         : price reversed and CLOSED beyond the sweep candle's
                            opposite extreme (reversal confirmed).
        - FAILED-BREAKOUT : price accepted beyond the swept swing (CLOSED past the
                            pivot in the sweep direction) -> not a sweep, a breakout.
        - FAILED-NOCONFIRM: neither happened within the window (no follow-through).
   5. Print swing list, sweep list (which candle swept, which pivot, outcome),
      a summary, and export an annotated CSV.

.PARAMETER TradingSymbol
  Label for display. Default: SENSEX2671677400PE
.PARAMETER InstrumentToken
  Kite instrument token. Default: 212349189
.PARAMETER StartDate / EndDate
  0 = today, -N = N days ago, or yyyy-MM-dd.
.PARAMETER SwingStrength
  Fractal pivot strength (candles required on each side). Higher = more major. Default 3.
.PARAMETER MinSwingMovePct
  Minimum % move between consecutive kept swings to be considered MAJOR. Default 0.8.
.PARAMETER ConfirmWindow
  How many candles after a sweep to look for confirmation/failure. Default 5.

.EXAMPLE
  .\Backtest-LiquiditySweep.ps1
  .\Backtest-LiquiditySweep.ps1 -StartDate -3 -EndDate 0 -SwingStrength 4 -MinSwingMovePct 1.0
  .\Backtest-LiquiditySweep.ps1 -InstrumentToken 212349189 -TradingSymbol SENSEX2671677400PE -ShowAllCandles
#>

param(
    [string]$TradingSymbol   = 'SENSEX2671677400PE',
    [int]$InstrumentToken    = 212349189,
    [string]$StartDate       = '0',
    [string]$EndDate         = '0',
    [ValidateSet('minute','3minute','5minute','10minute','15minute')]
    [string]$TimeFrame       = 'minute',
    [string]$StartTime       = '09:15',
    [string]$EndTime         = '15:30',
    [int]$SwingStrength      = 3,
    [double]$MinSwingMovePct = 0.8,
    [int]$ConfirmWindow      = 5,
    [int]$SweepLookbackBars  = 20,
    [switch]$ShowAllCandles,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret
)

$ErrorActionPreference = 'Stop'

# ================================================================
# Module & config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$rootDir   = Split-Path -Parent $scriptDir
Import-Module "$rootDir\KiteData.psm1" -Force -WarningAction SilentlyContinue

# Load API keys from Liquidity-sweep-input.json (fallback input.json)
$cfgPath = Join-Path $rootDir 'Liquidity-sweep-input.json'
if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $rootDir 'input.json' }
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($API_Key))    { $API_Key    = $cfg.API_Key }
    if ([string]::IsNullOrWhiteSpace($API_Secret)) { $API_Secret = $cfg.API_Secret }
}

# ================================================================
# Resolve dates & access token
# ================================================================
function Resolve-BacktestDate([string]$d) {
    if ($d -match '^-?\d+$') { return (Get-Date).AddDays([int]$d).ToString('yyyy-MM-dd') }
    return $d
}
$fromDate = Resolve-BacktestDate $StartDate
$toDate   = Resolve-BacktestDate $EndDate

$tokenFile = Join-Path $rootDir 'accesstoken.json'
if (-not $AccessToken -and (Test-Path $tokenFile)) {
    try { $td = Get-Content $tokenFile -Raw | ConvertFrom-Json; if ($td.access_token) { $AccessToken = $td.access_token } } catch {}
}
if (-not $AccessToken) {
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  No access token. Exiting.' -ForegroundColor Red; exit 1 }
}
$headers = @{ 'X-Kite-Version'='3'; 'Authorization'="token ${API_Key}:${AccessToken}" }

# ================================================================
# Fetch historical candles
# ================================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  LIQUIDITY SWEEP ANALYZER (1-min Heikin-Ashi) - READ ONLY' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol       : $TradingSymbol" -ForegroundColor White
Write-Host "  Token        : $InstrumentToken" -ForegroundColor White
Write-Host "  TimeFrame    : $TimeFrame" -ForegroundColor White
Write-Host "  Period       : $fromDate to $toDate" -ForegroundColor White
Write-Host "  Time window  : $StartTime - $EndTime" -ForegroundColor White
Write-Host "  SwingStrength: $SwingStrength (each side)  |  MinMove: $MinSwingMovePct%  |  ConfirmWindow: $ConfirmWindow  |  SweepLookback: $SweepLookbackBars bars" -ForegroundColor White
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  Fetching historical data...' -ForegroundColor Yellow

$histUrl = "https://api.kite.trade/instruments/historical/$InstrumentToken/$TimeFrame`?from=$fromDate+00:00:00&to=$toDate+23:59:59"
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
Write-Host "  Received $($rawCandles.Count) raw candles." -ForegroundColor Green

# ================================================================
# Convert to Heikin-Ashi + filter by time window
# ================================================================
$startTS = [TimeSpan]::Parse($StartTime)
$endTS   = [TimeSpan]::Parse($EndTime)

$haCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
$prevHA = $null
foreach ($c in $rawCandles) {
    $open = [double]$c[1]; $high = [double]$c[2]; $low = [double]$c[3]; $close = [double]$c[4]
    $haClose = ($open + $high + $low + $close) / 4.0
    $haOpen  = if ($null -ne $prevHA) { ($prevHA.Open + $prevHA.Close) / 2.0 } else { ($open + $close) / 2.0 }
    $haHigh  = [Math]::Max($high, [Math]::Max($haOpen, $haClose))
    $haLow   = [Math]::Min($low,  [Math]::Min($haOpen, $haClose))

    $ts = $c[0]
    if ($ts -is [string]) { try { $ts = [DateTime]::Parse($ts) } catch { $ts = $null } }
    $obj = [PSCustomObject]@{
        Time     = $ts
        Open     = [Math]::Round($haOpen, 2)
        High     = [Math]::Round($haHigh, 2)
        Low      = [Math]::Round($haLow, 2)
        Close    = [Math]::Round($haClose, 2)
        RawClose = [Math]::Round($close, 2)   # actual traded close (used for fills)
    }
    $prevHA = $obj
    if ($null -ne $ts) {
        $tod = ([datetime]$ts).TimeOfDay
        if ($tod -ge $startTS -and $tod -le $endTS) { $haCandles.Add($obj) }
    }
}

$N = $haCandles.Count
if ($N -lt (2 * $SwingStrength + 3)) {
    Write-Host "  Not enough candles ($N) for analysis with SwingStrength $SwingStrength." -ForegroundColor Red
    exit 1
}
# Attach a sequential index for reporting
for ($i = 0; $i -lt $N; $i++) { $haCandles[$i] | Add-Member -NotePropertyName Idx -NotePropertyValue $i -Force }
Write-Host "  Analyzing $N Heikin-Ashi candles in time window." -ForegroundColor Green
Write-Host ''

# ================================================================
# STEP 1: Detect fractal pivots (raw swings)
# ================================================================
# A pivot HIGH at i: High[i] is strictly greater than High of SwingStrength
# candles on both sides. Pivot LOW symmetric.
$rawSwings = [System.Collections.Generic.List[PSCustomObject]]::new()
for ($i = $SwingStrength; $i -lt ($N - $SwingStrength); $i++) {
    $isHigh = $true; $isLow = $true
    for ($j = $i - $SwingStrength; $j -le $i + $SwingStrength; $j++) {
        if ($j -eq $i) { continue }
        if ($haCandles[$j].High -ge $haCandles[$i].High) { $isHigh = $false }
        if ($haCandles[$j].Low  -le $haCandles[$i].Low)  { $isLow  = $false }
    }
    if ($isHigh) {
        $rawSwings.Add([PSCustomObject]@{ Idx=$i; Type='HIGH'; Level=$haCandles[$i].High; Time=$haCandles[$i].Time })
    } elseif ($isLow) {
        $rawSwings.Add([PSCustomObject]@{ Idx=$i; Type='LOW';  Level=$haCandles[$i].Low;  Time=$haCandles[$i].Time })
    }
}

# ================================================================
# STEP 2: Keep only MAJOR swings
#   - alternate HIGH/LOW (collapse consecutive same-type to the extreme)
#   - require a minimum % move from the previous kept swing
# ================================================================
$majorSwings = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($sw in $rawSwings) {
    if ($majorSwings.Count -eq 0) { $majorSwings.Add($sw); continue }
    $last = $majorSwings[$majorSwings.Count - 1]

    if ($sw.Type -eq $last.Type) {
        # Same type in a row -> keep the more extreme one
        if ($sw.Type -eq 'HIGH' -and $sw.Level -gt $last.Level) { $majorSwings[$majorSwings.Count - 1] = $sw }
        elseif ($sw.Type -eq 'LOW' -and $sw.Level -lt $last.Level) { $majorSwings[$majorSwings.Count - 1] = $sw }
        continue
    }

    # Opposite type -> require a minimum move to count as a major swing leg
    $movePct = if ($last.Level -ne 0) { [Math]::Abs($sw.Level - $last.Level) / $last.Level * 100.0 } else { 0 }
    if ($movePct -ge $MinSwingMovePct) {
        $majorSwings.Add($sw)
    } else {
        # Minor wiggle: if this new swing is more extreme in a way that improves the
        # last kept leg direction, replace; otherwise ignore (filters minor swings).
        if ($last.Type -eq 'HIGH' -and $sw.Type -eq 'LOW') {
            # ignore shallow low
        } elseif ($last.Type -eq 'LOW' -and $sw.Type -eq 'HIGH') {
            # ignore shallow high
        }
    }
}

Write-Host "  Detected $($rawSwings.Count) raw pivots -> $($majorSwings.Count) MAJOR swings" -ForegroundColor Green

# Build quick lookup of major swing highs/lows for sweep scanning
$swingHighs = @($majorSwings | Where-Object Type -eq 'HIGH')
$swingLows  = @($majorSwings | Where-Object Type -eq 'LOW')

# ================================================================
# STEP 3: Detect liquidity sweeps
#   For each candle i, scan ALL prior MAJOR swings (not just the most recent).
#   A candle sweeps a swing HIGH when its High pierces the level AND its Close
#   comes back below it. Among all qualifying prior swing highs we pick the one
#   NEAREST above the close (the level whose liquidity was just taken and rejected).
#   Symmetric logic for swing LOWs. This catches sweeps of deeper swings that a
#   "most-recent-swing-only" scan would misclassify as breakouts.
# ================================================================
$sweeps = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($i = ($SwingStrength + 1); $i -lt $N; $i++) {
    $cand = $haCandles[$i]

    # ---- UPSIDE sweep: pierce a prior swing HIGH, close back below ----
    #   nearest above close = smallest qualifying level
    $bestHigh = $null
    foreach ($s in $swingHighs) {
        if ($s.Idx -ge $i) { break }
        if ($s.Idx -lt ($i - $SweepLookbackBars)) { continue }
        if ($cand.Idx -le ($s.Idx + $SwingStrength)) { continue }
        if ($cand.High -gt $s.Level -and $cand.Close -le $s.Level) {
            if ($null -eq $bestHigh -or $s.Level -lt $bestHigh.Level) { $bestHigh = $s }
        }
    }
    if ($null -ne $bestHigh) {
        $sweeps.Add([PSCustomObject]@{
            Direction  = 'UPSIDE'
            SweepIdx   = $i
            SweepTime  = $cand.Time
            PivotIdx   = $bestHigh.Idx
            PivotLevel = $bestHigh.Level
            SweepHigh  = $cand.High
            SweepLow   = $cand.Low
            SweepClose = $cand.Close
        })
    }

    # ---- DOWNSIDE sweep: pierce a prior swing LOW, close back above ----
    #   nearest below close = largest qualifying level
    $bestLow = $null
    foreach ($s in $swingLows) {
        if ($s.Idx -ge $i) { break }
        if ($s.Idx -lt ($i - $SweepLookbackBars)) { continue }
        if ($cand.Idx -le ($s.Idx + $SwingStrength)) { continue }
        if ($cand.Low -lt $s.Level -and $cand.Close -ge $s.Level) {
            if ($null -eq $bestLow -or $s.Level -gt $bestLow.Level) { $bestLow = $s }
        }
    }
    if ($null -ne $bestLow) {
        $sweeps.Add([PSCustomObject]@{
            Direction  = 'DOWNSIDE'
            SweepIdx   = $i
            SweepTime  = $cand.Time
            PivotIdx   = $bestLow.Idx
            PivotLevel = $bestLow.Level
            SweepHigh  = $cand.High
            SweepLow   = $cand.Low
            SweepClose = $cand.Close
        })
    }
}

# Collapse duplicate consecutive sweeps of same direction on the same pivot
# (a run of candles hunting the same level) -> keep the first sweep candle.
$dedupSweeps = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($sw in $sweeps) {
    $isDup = $false
    if ($dedupSweeps.Count -gt 0) {
        $last = $dedupSweeps[$dedupSweeps.Count - 1]
        if ($last.Direction -eq $sw.Direction -and $last.PivotIdx -eq $sw.PivotIdx -and ($sw.SweepIdx - $last.SweepIdx) -le $SwingStrength) {
            $isDup = $true
        }
    }
    if (-not $isDup) { $dedupSweeps.Add($sw) }
}
$sweeps = $dedupSweeps

# ================================================================
# STEP 4: Sequential TRADE SIMULATION
#   After a sweep, WAIT for HA confirmation, then trade (one position at a time):
#     DOWNSIDE sweep -> LONG bias  : enter when HA Close > prev HA High  (BUY CE)
#                                    exit  when HA Close < prev HA Low   (SELL CE)
#     UPSIDE   sweep -> SHORT bias : enter when HA Close < prev HA Low   (BUY PE)
#                                    exit  when HA Close > prev HA High  (SELL PE)
#   Confirmation must arrive within -ConfirmWindow candles of the sweep, else the
#   setup is discarded. Signals use HA values; fills use the raw close.
#   NOTE: trades are simulated on THIS instrument's own candles (long = buy,
#   short = sell); P&L is in this instrument's points.
# ================================================================
foreach ($sw in $sweeps) {
    $sw | Add-Member -NotePropertyName Bias -NotePropertyValue $(if ($sw.Direction -eq 'UPSIDE') { 'SHORT' } else { 'LONG' }) -Force
}

# First sweep at each candle index (engine arms only while flat)
$sweepAtIdx = @{}
foreach ($sw in $sweeps) { if (-not $sweepAtIdx.ContainsKey($sw.SweepIdx)) { $sweepAtIdx[$sw.SweepIdx] = $sw } }

$trades      = [System.Collections.Generic.List[PSCustomObject]]::new()
$expiredArm  = 0
$pos = ''; $entryIdx = -1; $entryPrice = 0.0; $curSweep = $null
$armed = ''; $armSweep = $null; $armSweepIdx = -1

for ($i = 1; $i -lt $N; $i++) {
    $c = $haCandles[$i]; $p = $haCandles[$i - 1]

    # --- Manage open position: check exit signal ---
    if ($pos -ne '') {
        $doExit = ($pos -eq 'LONG' -and $c.Close -lt $p.Low) -or ($pos -eq 'SHORT' -and $c.Close -gt $p.High)
        if ($doExit) {
            $exitPrice = $c.RawClose
            $pnl = if ($pos -eq 'LONG') { $exitPrice - $entryPrice } else { $entryPrice - $exitPrice }
            $trades.Add([PSCustomObject]@{
                Bias=$pos; SweepDir=$curSweep.Direction; SweepIdx=$curSweep.SweepIdx; SweepTime=$curSweep.SweepTime; PivotLevel=$curSweep.PivotLevel
                EntryIdx=$entryIdx; EntryTime=$haCandles[$entryIdx].Time; EntryPrice=[Math]::Round($entryPrice,2)
                ExitIdx=$i; ExitTime=$c.Time; ExitPrice=[Math]::Round($exitPrice,2); ExitReason='SIGNAL'
                PnLPts=[Math]::Round($pnl,2); Result=$(if ($pnl -ge 0) { 'WIN' } else { 'LOSS' })
            })
            $pos=''; $entryIdx=-1; $entryPrice=0.0; $curSweep=$null
        }
        continue   # one action per candle; do not arm/enter on an exit candle
    }

    # --- Armed: wait for confirmation within the window ---
    if ($armed -ne '') {
        if (($i - $armSweepIdx) -gt $ConfirmWindow) {
            $expiredArm++
            $armed=''; $armSweep=$null; $armSweepIdx=-1
            # fall through to scan this same candle for a fresh sweep
        } else {
            $enter = ($armed -eq 'LONG' -and $c.Close -gt $p.High) -or ($armed -eq 'SHORT' -and $c.Close -lt $p.Low)
            if ($enter) {
                $pos=$armed; $entryIdx=$i; $entryPrice=$c.RawClose; $curSweep=$armSweep
                $armed=''; $armSweep=$null; $armSweepIdx=-1
            }
            continue   # still waiting, or just entered this candle
        }
    }

    # --- Flat & unarmed: scan for a sweep to arm ---
    if ($sweepAtIdx.ContainsKey($i)) {
        $sw = $sweepAtIdx[$i]
        $armed      = if ($sw.Direction -eq 'DOWNSIDE') { 'LONG' } else { 'SHORT' }
        $armSweep   = $sw
        $armSweepIdx = $i
    }
}

# Close any still-open position at the last candle (EOD)
if ($pos -ne '') {
    $last = $haCandles[$N - 1]
    $exitPrice = $last.RawClose
    $pnl = if ($pos -eq 'LONG') { $exitPrice - $entryPrice } else { $entryPrice - $exitPrice }
    $trades.Add([PSCustomObject]@{
        Bias=$pos; SweepDir=$curSweep.Direction; SweepIdx=$curSweep.SweepIdx; SweepTime=$curSweep.SweepTime; PivotLevel=$curSweep.PivotLevel
        EntryIdx=$entryIdx; EntryTime=$haCandles[$entryIdx].Time; EntryPrice=[Math]::Round($entryPrice,2)
        ExitIdx=$N-1; ExitTime=$last.Time; ExitPrice=[Math]::Round($exitPrice,2); ExitReason='EOD'
        PnLPts=[Math]::Round($pnl,2); Result=$(if ($pnl -ge 0) { 'WIN' } else { 'LOSS' })
    })
}

# ================================================================
# REPORT: Swings
# ================================================================
function Format-T($t) { if ($t -is [datetime]) { $t.ToString('MM-dd HH:mm') } else { [string]$t } }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  MAJOR SWINGS' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ('  {0,-5} {1,-13} {2,-6} {3,12}' -f 'Idx','Time','Type','Level') -ForegroundColor Gray
Write-Host ('  ' + ('-' * 42)) -ForegroundColor DarkGray
foreach ($s in $majorSwings) {
    $col = if ($s.Type -eq 'HIGH') { 'Red' } else { 'Green' }
    Write-Host ('  {0,-5} {1,-13} {2,-6} {3,12}' -f $s.Idx, (Format-T $s.Time), $s.Type, ('{0:N2}' -f $s.Level)) -ForegroundColor $col
}

# ================================================================
# REPORT: Sweeps (detected)
# ================================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  LIQUIDITY SWEEPS (detected)' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ('  {0,-4} {1,-11} {2,-9} {3,-6} {4,10} {5,10} {6,10}' -f `
    'S#','SweepTime','Dir','Bias','Pivot','SweepHi','SweepLo') -ForegroundColor Gray
Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
$n = 0
foreach ($sw in $sweeps) {
    $n++
    $col = if ($sw.Direction -eq 'UPSIDE') { 'Red' } else { 'Green' }
    Write-Host ('  {0,-4} {1,-11} {2,-9} {3,-6} {4,10} {5,10} {6,10}' -f `
        $n, (Format-T $sw.SweepTime), $sw.Direction, $sw.Bias,
        ('{0:N2}' -f $sw.PivotLevel), ('{0:N2}' -f $sw.SweepHigh), ('{0:N2}' -f $sw.SweepLow)) -ForegroundColor $col
}
if ($sweeps.Count -eq 0) { Write-Host '  (no sweeps detected in period)' -ForegroundColor DarkYellow }

# ================================================================
# REPORT: Trades (sweep -> confirmation -> entry/exit)
# ================================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  TRADES  (wait-for-confirmation model)' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ('  {0,-4} {1,-6} {2,-9} {3,-11} {4,9} {5,-11} {6,9} {7,-7} {8,9} {9,-6}' -f `
    'T#','Bias','FromSweep','EntryTime','EntryPx','ExitTime','ExitPx','Reason','PnLPts','W/L') -ForegroundColor Gray
Write-Host ('  ' + ('-' * 98)) -ForegroundColor DarkGray
$t = 0
foreach ($tr in $trades) {
    $t++
    $col = if ($tr.Result -eq 'WIN') { 'Green' } else { 'Red' }
    Write-Host ('  {0,-4} {1,-6} {2,-9} {3,-11} {4,9} {5,-11} {6,9} {7,-7} {8,9} {9,-6}' -f `
        $t, $tr.Bias, $tr.SweepDir, (Format-T $tr.EntryTime), ('{0:N2}' -f $tr.EntryPrice),
        (Format-T $tr.ExitTime), ('{0:N2}' -f $tr.ExitPrice), $tr.ExitReason,
        ('{0:N2}' -f $tr.PnLPts), $tr.Result) -ForegroundColor $col
}
if ($trades.Count -eq 0) { Write-Host '  (no trades - no sweep produced a confirmed entry)' -ForegroundColor DarkYellow }

# ================================================================
# SUMMARY
# ================================================================
$upSweeps    = @($sweeps | Where-Object Direction -eq 'UPSIDE')
$dnSweeps    = @($sweeps | Where-Object Direction -eq 'DOWNSIDE')
$longTrades  = @($trades | Where-Object Bias -eq 'LONG')
$shortTrades = @($trades | Where-Object Bias -eq 'SHORT')
$wins        = @($trades | Where-Object Result -eq 'WIN')
$losses      = @($trades | Where-Object Result -eq 'LOSS')
$totalPts    = ($trades | Measure-Object -Property PnLPts -Sum).Sum
if ($null -eq $totalPts) { $totalPts = 0 }
$totalPts    = [Math]::Round($totalPts, 2)
$winRate     = if ($trades.Count -gt 0) { [Math]::Round($wins.Count / $trades.Count * 100, 1) } else { 0 }
$avgWin      = if ($wins.Count   -gt 0) { [Math]::Round((($wins   | Measure-Object PnLPts -Average).Average), 2) } else { 0 }
$avgLoss     = if ($losses.Count -gt 0) { [Math]::Round((($losses | Measure-Object PnLPts -Average).Average), 2) } else { 0 }

function Get-DirStats($list) {
    $w = @($list | Where-Object Result -eq 'WIN').Count
    $pts = ($list | Measure-Object PnLPts -Sum).Sum
    if ($null -eq $pts) { $pts = 0 }
    $wr = if ($list.Count -gt 0) { [Math]::Round($w / $list.Count * 100, 1) } else { 0 }
    return @{ Count=$list.Count; Wins=$w; Pts=[Math]::Round($pts,2); WinRate=$wr }
}
$lStat = Get-DirStats $longTrades
$sStat = Get-DirStats $shortTrades

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Major swings       : $($majorSwings.Count)  (Highs: $($swingHighs.Count) | Lows: $($swingLows.Count))" -ForegroundColor White
Write-Host "  Sweeps detected    : $($sweeps.Count)  (Upside: $($upSweeps.Count) | Downside: $($dnSweeps.Count))" -ForegroundColor White
Write-Host "  Setups expired     : $expiredArm  (sweep but no confirmation within $ConfirmWindow candles)" -ForegroundColor DarkYellow
Write-Host "  Trades taken       : $($trades.Count)  (Wins: $($wins.Count) | Losses: $($losses.Count))" -ForegroundColor White
Write-Host "  Win rate           : $winRate%" -ForegroundColor $(if ($winRate -ge 50) { 'Green' } else { 'Yellow' })
Write-Host "  Total P&L (points) : $totalPts" -ForegroundColor $(if ($totalPts -ge 0) { 'Green' } else { 'Red' })
Write-Host "  Avg win / avg loss : $avgWin / $avgLoss pts" -ForegroundColor White
Write-Host ''
Write-Host "  DOWNSIDE sweeps -> LONG  (BUY CE): $($lStat.Count) trades | $($lStat.Wins) wins | WinRate $($lStat.WinRate)% | Pts $($lStat.Pts)" -ForegroundColor Green
Write-Host "  UPSIDE   sweeps -> SHORT (BUY PE): $($sStat.Count) trades | $($sStat.Wins) wins | WinRate $($sStat.WinRate)% | Pts $($sStat.Pts)" -ForegroundColor Red

# ================================================================
# Optional full annotated candle table
# ================================================================
if ($ShowAllCandles) {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '  ALL CANDLES (annotated)' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    $swingMap = @{}; foreach ($s in $majorSwings) { $swingMap[$s.Idx] = $s.Type }
    $sweepMap = @{}; foreach ($sw in $sweeps) { $sweepMap[$sw.SweepIdx] = "$($sw.Direction):$($sw.Bias)" }
    $entryMap = @{}; $exitMap = @{}
    foreach ($tr in $trades) { $entryMap[$tr.EntryIdx] = $tr.Bias; $exitMap[$tr.ExitIdx] = $tr.Result }
    Write-Host ('  {0,-5} {1,-13} {2,9} {3,9} {4,9} {5,9}  {6}' -f 'Idx','Time','Open','High','Low','Close','Marker') -ForegroundColor Gray
    for ($i = 0; $i -lt $N; $i++) {
        $c = $haCandles[$i]
        $marker = ''
        if ($swingMap.ContainsKey($i)) { $marker += "<< SWING $($swingMap[$i]) " }
        if ($sweepMap.ContainsKey($i)) { $marker += "** SWEEP $($sweepMap[$i]) " }
        if ($entryMap.ContainsKey($i)) { $marker += ">> ENTER $($entryMap[$i]) " }
        if ($exitMap.ContainsKey($i))  { $marker += "<< EXIT $($exitMap[$i]) " }
        $col = if ($entryMap.ContainsKey($i) -or $exitMap.ContainsKey($i)) { 'Yellow' } elseif ($sweepMap.ContainsKey($i)) { 'Magenta' } elseif ($swingMap.ContainsKey($i)) { if ($swingMap[$i] -eq 'HIGH') { 'Red' } else { 'Green' } } elseif ($c.Close -ge $c.Open) { 'DarkGreen' } else { 'DarkRed' }
        Write-Host ('  {0,-5} {1,-13} {2,9} {3,9} {4,9} {5,9}  {6}' -f `
            $i, (Format-T $c.Time), ('{0:N2}' -f $c.Open), ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), $marker) -ForegroundColor $col
    }
}

# ================================================================
# CSV export
# ================================================================
$resultsDir = Join-Path $scriptDir 'Results-csv'
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$csvPath = Join-Path $resultsDir "liquidity-sweep-trades-$stamp.csv"

$trades | Select-Object `
    @{n='Bias';e={$_.Bias}},
    @{n='SweepDir';e={$_.SweepDir}},
    @{n='SweepTime';e={ if ($_.SweepTime -is [datetime]) { $_.SweepTime.ToString('yyyy-MM-dd HH:mm') } else { $_.SweepTime } }},
    @{n='PivotLevel';e={$_.PivotLevel}},
    @{n='EntryTime';e={ if ($_.EntryTime -is [datetime]) { $_.EntryTime.ToString('yyyy-MM-dd HH:mm') } else { $_.EntryTime } }},
    @{n='EntryPrice';e={$_.EntryPrice}},
    @{n='ExitTime';e={ if ($_.ExitTime -is [datetime]) { $_.ExitTime.ToString('yyyy-MM-dd HH:mm') } else { $_.ExitTime } }},
    @{n='ExitPrice';e={$_.ExitPrice}},
    @{n='ExitReason';e={$_.ExitReason}},
    @{n='PnLPts';e={$_.PnLPts}},
    @{n='Result';e={$_.Result}} |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "  CSV exported: $csvPath" -ForegroundColor Green
Write-Host '  Done. (No orders were placed - analysis only.)' -ForegroundColor Gray
Write-Host ''
