<#
.SYNOPSIS
  Runs Quick-HA-Analysis for multiple days and shows a summary table.
.EXAMPLE
  .\Quick-HA-Summary.ps1 -TradingSymbol SENSEX -InstrumentToken 265 -Days 50
  .\Quick-HA-Summary.ps1 -TradingSymbol SENSEX -InstrumentToken 265 -Days 10 -TimeFrame 2minute -SLLookback 1
#>

param(
    [Parameter(Mandatory)][string]$TradingSymbol,
    [Parameter(Mandatory)][int]$InstrumentToken,
    [int]$Days              = 50,
    [string]$TimeFrame      = 'minute',
    [int]$SLLookback        = 1,
    [string]$EntryStartTime = '09:16',
    [string]$EntryStopTime  = '15:29',
    [string]$MarketCloseTime = '15:30'
)

# ── Setup ───────────────────────────────────────────────────────
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$rootDir = Split-Path -Parent $scriptDir
Import-Module "$rootDir\KiteData.psm1" -Force

if (-not $Global:common_header) {
    $cfg = Get-Content (Join-Path $rootDir 'input.json') -Raw | ConvertFrom-Json
    $tok = (Get-Content (Join-Path $rootDir 'accesstoken.json') -Raw | ConvertFrom-Json).access_token
    $Global:common_header = @{
        'X-Kite-Version' = '3'
        'Authorization'  = "token $($cfg.API_Key):${tok}"
    }
}

$entryStart = [TimeSpan]::Parse($EntryStartTime)
$entryStop  = [TimeSpan]::Parse($EntryStopTime)

$tfMap = @{
    'minute'='1'; '2minute'='2'; '3minute'='3'; '4minute'='4'; '5minute'='5'
    '10minute'='10'; '15minute'='15'; '30minute'='30'; '60minute'='60'
}
$apiTF = if ($tfMap.ContainsKey($TimeFrame)) { $tfMap[$TimeFrame] } else { $TimeFrame }
$needsAggregation = $TimeFrame -in @('2minute','4minute')
$minutes = if ($needsAggregation) { [int]($TimeFrame -replace 'minute','') } else { 0 }

# ── Collect results ─────────────────────────────────────────────
$results = @()

for ($d = $Days; $d -ge 0; $d--) {
    $dt = (Get-Date).AddDays(-$d)
    if ($dt.DayOfWeek -eq 'Saturday' -or $dt.DayOfWeek -eq 'Sunday') { continue }
    $dateStr = $dt.ToString('yyyy-MM-dd')
    $toDate = "$dateStr ${MarketCloseTime}:00"

    # Fetch candles
    if ($needsAggregation) {
        $raw1m = Get-ZerodhaCandleData -tradingsymbol $TradingSymbol -instrument_token $InstrumentToken `
            -TimeFrame '1' -FromDate $dateStr -TODate $toDate -LastNCandles 500
        if (-not $raw1m -or $raw1m.Count -lt 2) { continue }
        $raw = @()
        $bucket = @()
        $bucketStart = $null
        foreach ($c in $raw1m) {
            $ts = [DateTime]$c.timestamp
            if (-not $bucketStart) { $bucketStart = $ts }
            $bucket += $c
            if ($bucket.Count -ge $minutes) {
                $raw += [PSCustomObject]@{
                    timestamp = $bucketStart.ToString('yyyy-MM-dd HH:mm:ss')
                    open      = $bucket[0].open
                    high      = ($bucket | Measure-Object -Property high -Maximum).Maximum
                    low       = ($bucket | Measure-Object -Property low  -Minimum).Minimum
                    close     = $bucket[-1].close
                    volume    = ($bucket | Measure-Object -Property volume -Sum).Sum
                }
                $bucket = @()
                $bucketStart = $null
            }
        }
    } else {
        $raw = Get-ZerodhaCandleData -tradingsymbol $TradingSymbol -instrument_token $InstrumentToken `
            -TimeFrame $apiTF -FromDate $dateStr -TODate $toDate -LastNCandles 500
    }

    if (-not $raw -or $raw.Count -lt 2) { continue }

    # Convert to HA
    $ha = @()
    $prev = $null
    foreach ($c in $raw) {
        $hc = ($c.open + $c.high + $c.low + $c.close) / 4
        $ho = if ($prev) { ($prev.haOpen + $prev.haClose) / 2 } else { ($c.open + $c.close) / 2 }
        $hh = [Math]::Max($c.high, [Math]::Max($ho, $hc))
        $hl = [Math]::Min($c.low,  [Math]::Min($ho, $hc))
        $obj = [PSCustomObject]@{
            Time=$c.timestamp; haOpen=[Math]::Round($ho,2); haHigh=[Math]::Round($hh,2)
            haLow=[Math]::Round($hl,2); haClose=[Math]::Round($hc,2)
            RawClose=$c.close; RawHigh=$c.high; RawLow=$c.low
        }
        $ha += $obj; $prev = $obj
    }

    # ── LONG ──
    $longTrades = @(); $inPos = $false
    for ($i = 1; $i -lt $ha.Count; $i++) {
        $cur = $ha[$i]; $prv = $ha[$i-1]
        $curTime = ([DateTime]$cur.Time).TimeOfDay
        if (-not $inPos -and $cur.haClose -gt $prv.haHigh -and $curTime -ge $entryStart -and $curTime -le $entryStop) {
            $inPos = $true; $ep = $cur.RawClose; $et = $cur.Time
            $start = [Math]::Max(0, $i - $SLLookback + 1)
            $sl = ($ha[$start..$i] | Measure-Object -Property RawLow -Minimum).Minimum
            continue
        }
        if ($inPos) {
            if ($cur.RawClose -le $sl) {
                $longTrades += [PSCustomObject]@{ PnL=[Math]::Round($sl - $ep, 2); EntryTime=$et }
                $inPos = $false; continue
            }
            if ($cur.haClose -lt $prv.haLow) {
                $longTrades += [PSCustomObject]@{ PnL=[Math]::Round($cur.RawClose - $ep, 2); EntryTime=$et }
                $inPos = $false
            }
        }
    }
    if ($inPos) { $longTrades += [PSCustomObject]@{ PnL=[Math]::Round($ha[-1].RawClose - $ep, 2); EntryTime=$et } }

    # ── SHORT ──
    $shortTrades = @(); $inPos = $false
    for ($i = 1; $i -lt $ha.Count; $i++) {
        $cur = $ha[$i]; $prv = $ha[$i-1]
        $curTime = ([DateTime]$cur.Time).TimeOfDay
        if (-not $inPos -and $cur.haClose -lt $prv.haLow -and $curTime -ge $entryStart -and $curTime -le $entryStop) {
            $inPos = $true; $ep = $cur.RawClose; $et = $cur.Time
            $start = [Math]::Max(0, $i - $SLLookback + 1)
            $sl = ($ha[$start..$i] | Measure-Object -Property RawHigh -Maximum).Maximum
            continue
        }
        if ($inPos) {
            if ($cur.RawClose -ge $sl) {
                $shortTrades += [PSCustomObject]@{ PnL=[Math]::Round($ep - $sl, 2); EntryTime=$et }
                $inPos = $false; continue
            }
            if ($cur.haClose -gt $prv.haHigh) {
                $shortTrades += [PSCustomObject]@{ PnL=[Math]::Round($ep - $cur.RawClose, 2); EntryTime=$et }
                $inPos = $false
            }
        }
    }
    if ($inPos) { $shortTrades += [PSCustomObject]@{ PnL=[Math]::Round($ep - $ha[-1].RawClose, 2); EntryTime=$et } }

    # Summarize
    $lPnL = if ($longTrades.Count -gt 0) { [Math]::Round(($longTrades | Measure-Object -Property PnL -Sum).Sum, 2) } else { 0 }
    $sPnL = if ($shortTrades.Count -gt 0) { [Math]::Round(($shortTrades | Measure-Object -Property PnL -Sum).Sum, 2) } else { 0 }
    $lW = @($longTrades | Where-Object { $_.PnL -gt 0 }).Count
    $sW = @($shortTrades | Where-Object { $_.PnL -gt 0 }).Count

    $allTrades = @($longTrades) + @($shortTrades)
    $bestTrade  = if ($allTrades.Count -gt 0) { [Math]::Round(($allTrades | Measure-Object -Property PnL -Maximum).Maximum, 2) } else { 0 }
    $worstTrade = if ($allTrades.Count -gt 0) { [Math]::Round(($allTrades | Measure-Object -Property PnL -Minimum).Minimum, 2) } else { 0 }
    $bestTradeTime  = if ($allTrades.Count -gt 0) { $bt = $allTrades | Sort-Object PnL -Descending | Select-Object -First 1; ([DateTime]$bt.EntryTime).ToString('HH:mm') } else { '' }
    $worstTradeTime = if ($allTrades.Count -gt 0) { $wt = $allTrades | Sort-Object PnL | Select-Object -First 1; ([DateTime]$wt.EntryTime).ToString('HH:mm') } else { '' }

    $results += [PSCustomObject]@{
        Date = $dateStr
        LTrades = $longTrades.Count; LWin = $lW; LPnL = $lPnL
        STrades = $shortTrades.Count; SWin = $sW; SPnL = $sPnL
        Combined = [Math]::Round($lPnL + $sPnL, 2)
        BestTrade = $bestTrade; BestTradeTime = $bestTradeTime
        WorstTrade = $worstTrade; WorstTradeTime = $worstTradeTime
    }

    Write-Host "  $dateStr done ($($longTrades.Count)L/$($shortTrades.Count)S)" -ForegroundColor DarkGray
}

if ($results.Count -eq 0) { Write-Host "`n  No trading days found." -ForegroundColor Red; return }

# ── Print Summary Table ─────────────────────────────────────────
Write-Host ""
Write-Host "  ══════════════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  $TradingSymbol | $TimeFrame | SL: $SLLookback | Last $Days days ($($results.Count) trading days)" -ForegroundColor Cyan
Write-Host "  ══════════════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$hdr = "  {0,-12} {1,6} {2,4} {3,5} {4,10} {5,6} {6,4} {7,5} {8,10} {9,10} {10,10} {11,10} {12,6} {13,10} {14,6}" -f "Date","LTrd","LW","LW%","LongPnL","STrd","SW","SW%","ShortPnL","Combined","Cumulative","BestTrd","BTime","WorstTrd","WTime"
$sep = "  " + ("-" * 138)

Write-Host $sep -ForegroundColor DarkGray
Write-Host $hdr -ForegroundColor White
Write-Host $sep -ForegroundColor DarkGray

$cumulative = 0.0
$totalLPnL = 0.0; $totalSPnL = 0.0; $totalComb = 0.0
$totalLTrd = 0; $totalSTrd = 0; $totalLW = 0; $totalSW = 0
$winDays = 0; $loseDays = 0

# Streak tracking
$curWinStreak = 0; $curWinPts = 0.0; $bestWinStreak = 0; $bestWinPts = 0.0
$curLoseStreak = 0; $curLosePts = 0.0; $worstLoseStreak = 0; $worstLosePts = 0.0

foreach ($r in $results) {
    $cumulative += $r.Combined
    $totalLPnL += $r.LPnL; $totalSPnL += $r.SPnL; $totalComb += $r.Combined
    $totalLTrd += $r.LTrades; $totalSTrd += $r.STrades; $totalLW += $r.LWin; $totalSW += $r.SWin
    if ($r.Combined -ge 0) {
        $winDays++
        $curWinStreak++; $curWinPts += $r.Combined
        if ($curWinStreak -gt $bestWinStreak -or ($curWinStreak -eq $bestWinStreak -and $curWinPts -gt $bestWinPts)) {
            $bestWinStreak = $curWinStreak; $bestWinPts = [Math]::Round($curWinPts, 2)
        }
        $curLoseStreak = 0; $curLosePts = 0.0
    } else {
        $loseDays++
        $curLoseStreak++; $curLosePts += $r.Combined
        if ($curLoseStreak -gt $worstLoseStreak -or ($curLoseStreak -eq $worstLoseStreak -and $curLosePts -lt $worstLosePts)) {
            $worstLoseStreak = $curLoseStreak; $worstLosePts = [Math]::Round($curLosePts, 2)
        }
        $curWinStreak = 0; $curWinPts = 0.0
    }

    $lWinPct = if ($r.LTrades -gt 0) { [Math]::Round($r.LWin / $r.LTrades * 100, 0) } else { 0 }
    $sWinPct = if ($r.STrades -gt 0) { [Math]::Round($r.SWin / $r.STrades * 100, 0) } else { 0 }

    $lPnLStr = if ($r.LPnL -ge 0) { "+$($r.LPnL)" } else { "$($r.LPnL)" }
    $sPnLStr = if ($r.SPnL -ge 0) { "+$($r.SPnL)" } else { "$($r.SPnL)" }
    $cPnLStr = if ($r.Combined -ge 0) { "+$($r.Combined)" } else { "$($r.Combined)" }
    $cumStr  = if ($cumulative -ge 0) { "+$([Math]::Round($cumulative,2))" } else { "$([Math]::Round($cumulative,2))" }

    $bestTrdStr  = if ($r.BestTrade -ge 0) { "+$($r.BestTrade)" } else { "$($r.BestTrade)" }
    $worstTrdStr = if ($r.WorstTrade -ge 0) { "+$($r.WorstTrade)" } else { "$($r.WorstTrade)" }

    $color = if ($r.Combined -ge 0) { 'Green' } else { 'Red' }
    $line = "  {0,-12} {1,6} {2,4} {3,4}% {4,10} {5,6} {6,4} {7,4}% {8,10} {9,10} {10,10} {11,10} {12,6} {13,10} {14,6}" -f $r.Date, $r.LTrades, $r.LWin, $lWinPct, $lPnLStr, $r.STrades, $r.SWin, $sWinPct, $sPnLStr, $cPnLStr, $cumStr, $bestTrdStr, $r.BestTradeTime, $worstTrdStr, $r.WorstTradeTime
    Write-Host $line -ForegroundColor $color
}

Write-Host $sep -ForegroundColor DarkGray

# Totals
$tLWinPct = if ($totalLTrd -gt 0) { [Math]::Round($totalLW / $totalLTrd * 100, 0) } else { 0 }
$tSWinPct = if ($totalSTrd -gt 0) { [Math]::Round($totalSW / $totalSTrd * 100, 0) } else { 0 }
$tLPnLStr = if ($totalLPnL -ge 0) { "+$([Math]::Round($totalLPnL,2))" } else { "$([Math]::Round($totalLPnL,2))" }
$tSPnLStr = if ($totalSPnL -ge 0) { "+$([Math]::Round($totalSPnL,2))" } else { "$([Math]::Round($totalSPnL,2))" }
$tCStr    = if ($totalComb -ge 0) { "+$([Math]::Round($totalComb,2))" } else { "$([Math]::Round($totalComb,2))" }

$overallBest  = [Math]::Round(($results | Measure-Object -Property BestTrade -Maximum).Maximum, 2)
$overallWorst = [Math]::Round(($results | Measure-Object -Property WorstTrade -Minimum).Minimum, 2)
$oBestStr  = if ($overallBest -ge 0) { "+$overallBest" } else { "$overallBest" }
$oWorstStr = if ($overallWorst -ge 0) { "+$overallWorst" } else { "$overallWorst" }

$totLine = "  {0,-12} {1,6} {2,4} {3,4}% {4,10} {5,6} {6,4} {7,4}% {8,10} {9,10} {10,10} {11,10}" -f "TOTAL", $totalLTrd, $totalLW, $tLWinPct, $tLPnLStr, $totalSTrd, $totalSW, $tSWinPct, $tSPnLStr, $tCStr, $oBestStr, $oWorstStr
$totColor = if ($totalComb -ge 0) { 'Green' } else { 'Red' }
Write-Host $totLine -ForegroundColor $totColor
Write-Host $sep -ForegroundColor DarkGray

# Footer stats
$dayWinPct = [Math]::Round($winDays / $results.Count * 100, 1)
Write-Host ""
Write-Host "  Win Days: $winDays/$($results.Count) ($dayWinPct%) | Long Total: $tLPnLStr | Short Total: $tSPnLStr | Combined: $tCStr" -ForegroundColor Yellow
$bestWinPtsStr = if ($bestWinPts -ge 0) { "+$bestWinPts" } else { "$bestWinPts" }
$worstLosePtsStr = "$worstLosePts"
Write-Host "  Best Win Streak: $bestWinStreak days ($bestWinPtsStr pts) | Worst Lose Streak: $worstLoseStreak days ($worstLosePtsStr pts)" -ForegroundColor Yellow
Write-Host ""

# ── Export to CSV ───────────────────────────────────────────────
$csvDir = Join-Path $scriptDir 'Results-csv'
if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }

$csvCumulative = 0.0
$csvRows = foreach ($r in $results) {
    $csvCumulative += $r.Combined
    $lWPct = if ($r.LTrades -gt 0) { [Math]::Round($r.LWin / $r.LTrades * 100, 1) } else { 0 }
    $sWPct = if ($r.STrades -gt 0) { [Math]::Round($r.SWin / $r.STrades * 100, 1) } else { 0 }
    [PSCustomObject]@{
        Date        = $r.Date
        LongTrades  = $r.LTrades
        LongWins    = $r.LWin
        LongWinPct  = $lWPct
        LongPnL     = $r.LPnL
        ShortTrades = $r.STrades
        ShortWins   = $r.SWin
        ShortWinPct = $sWPct
        ShortPnL    = $r.SPnL
        Combined    = $r.Combined
        Cumulative  = [Math]::Round($csvCumulative, 2)
        BestTrade   = $r.BestTrade
        BestTradeTime  = $r.BestTradeTime
        WorstTrade  = $r.WorstTrade
        WorstTradeTime = $r.WorstTradeTime
    }
}

# Add totals row
$csvRows += [PSCustomObject]@{
    Date='TOTAL'; LongTrades=$totalLTrd; LongWins=$totalLW; LongWinPct=$tLWinPct
    LongPnL=[Math]::Round($totalLPnL,2); ShortTrades=$totalSTrd; ShortWins=$totalSW; ShortWinPct=$tSWinPct
    ShortPnL=[Math]::Round($totalSPnL,2); Combined=[Math]::Round($totalComb,2); Cumulative=[Math]::Round($csvCumulative,2)
    BestTrade=$overallBest; BestTradeTime=''; WorstTrade=$overallWorst; WorstTradeTime=''
}

$csvFile = Join-Path $csvDir "backtest-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').csv"
$csvRows | Export-Csv -Path $csvFile -NoTypeInformation -Force
Write-Host "  CSV exported: $csvFile" -ForegroundColor Green
Write-Host ""
