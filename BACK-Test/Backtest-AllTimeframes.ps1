<#
.SYNOPSIS
  Multi-timeframe, multi-day backtest for both Long and Short HA strategies.
.DESCRIPTION
  Fetches historical data once per timeframe, converts to Heikin-Ashi,
  then runs both Long and Short strategies day-by-day (intraday only).
  Produces a consolidated summary table across all timeframes and strategies.
.EXAMPLE
  .\Backtest-AllTimeframes.ps1 -TradingSymbol NIFTY -Days 50
  .\Backtest-AllTimeframes.ps1 -TradingSymbol BANKNIFTY -Days 30 -SLLookback 5
    [string[]]$TimeFrames  = @('minute','2minute','3minute','4minute','5minute','10minute','15minute','30minute','60minute'),

#>

param(
    [string]$TradingSymbol = 'NIFTY',
    [int]$InstrumentToken,
    [int]$Days             = 50,
    [string[]]$TimeFrames  = @('minute','2minute'),
    [string]$EntryStartTime = '09:16',
    [string]$EntryStopTime  = '15:29',
    [string]$MarketCloseTime = '15:30',
    [int]$SLLookback          = 3,
    [switch]$ShowTrades,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret
)

# ================================================================
# Setup
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$rootDir = Split-Path -Parent $scriptDir
Import-Module "$rootDir\KiteData.psm1" -Force

$configPath = Join-Path $rootDir "input.json"
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($API_Key))    { $API_Key    = $cfg.API_Key }
    if ([string]::IsNullOrWhiteSpace($API_Secret)) { $API_Secret = $cfg.API_Secret }
    if (-not $PSBoundParameters.ContainsKey('TradingSymbol') -and $cfg.TradingSymbol)    { $TradingSymbol = $cfg.TradingSymbol }
    if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
}

# Token
$tokenFile = Join-Path $rootDir 'accesstoken.json'
if (-not $AccessToken -and (Test-Path $tokenFile)) {
    try {
        $tokenData = Get-Content $tokenFile -Raw | ConvertFrom-Json
        if ($tokenData.access_token) { $AccessToken = $tokenData.access_token }
    } catch {}
}
if (-not $AccessToken) {
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
}

# Symbol
$sym = $TradingSymbol.ToUpper().Trim()
if ($InstrumentToken -gt 0) {
    $instToken = $InstrumentToken
    $label = $sym
} else {
    $preset = Resolve-KiteSymbol $sym
    if ($preset) { $instToken = $preset.Token; $label = $preset.Label }
    else { Write-Host "  Unknown symbol: $TradingSymbol" -ForegroundColor Red; exit 1 }
}

# Index flag
$isIndex = $sym -match '^(NIFTY|SENSEX|BANKNIFTY)$'

# Dates
$fromDate = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd')
$toDate   = (Get-Date).ToString('yyyy-MM-dd')

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

$entryStartSpan   = [TimeSpan]::Parse($EntryStartTime)
$entryStopSpan    = [TimeSpan]::Parse($EntryStopTime)
$marketCloseSpan  = [TimeSpan]::Parse($MarketCloseTime)

# ================================================================
# Header
# ================================================================
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  MULTI-TIMEFRAME BACKTEST: Long + Short HA Strategies" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  Symbol     : $sym ($label)" -ForegroundColor White
Write-Host "  Token      : $instToken" -ForegroundColor White
Write-Host "  Period     : $fromDate to $toDate ($Days days)" -ForegroundColor White
Write-Host "  Entry      : $EntryStartTime to $EntryStopTime (entries only)" -ForegroundColor White
Write-Host "  Exit       : anytime until $MarketCloseTime (EOD force-close)" -ForegroundColor White
Write-Host "  StopLoss   : Last $SLLookback candle(s) Low (Long) / High (Short)" -ForegroundColor White
Write-Host "  TimeFrames : $($TimeFrames -join ', ')" -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

# ================================================================
# Results collection
# ================================================================
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# ================================================================
# Functions: Aggregate, Convert to HA, filter by time, simulate
# ================================================================

# ── TF short labels ──
$tfLabels = [ordered]@{ 'minute'='1m'; '2minute'='2m'; '3minute'='3m'; '4minute'='4m'; '5minute'='5m'; '10minute'='10m'; '15minute'='15m'; '30minute'='30m'; '60minute'='60m' }

# Aggregate 1-min candles into N-min candles (for 2min, 4min etc.)
# Uses sequential grouping per day (every N consecutive candles) to match Quick-HA-Analysis
function Aggregate-Candles($rawCandles, [int]$minutes) {
    $aggregated = [System.Collections.Generic.List[object[]]]::new()
    # Group by day first, then aggregate sequentially within each day
    $dayBuckets = [ordered]@{}
    foreach ($c in $rawCandles) {
        $ts = $c[0]
        if ($ts -is [string]) { try { $ts = [DateTime]::Parse($ts) } catch { continue } }
        $dayKey = $ts.ToString('yyyy-MM-dd')
        if (-not $dayBuckets.Contains($dayKey)) { $dayBuckets[$dayKey] = [System.Collections.Generic.List[object[]]]::new() }
        $dayBuckets[$dayKey].Add($c)
    }
    # Within each day, group sequentially (every N candles)
    foreach ($dayKey in $dayBuckets.Keys) {
        $dayCandles = $dayBuckets[$dayKey]
        $bucket = [System.Collections.Generic.List[object[]]]::new()
        $bucketStart = $null
        foreach ($c in $dayCandles) {
            $ts = $c[0]
            if ($ts -is [string]) { try { $ts = [DateTime]::Parse($ts) } catch { continue } }
            if ($null -eq $bucketStart) { $bucketStart = $ts }
            $bucket.Add($c)
            if ($bucket.Count -ge $minutes) {
                $bOpen  = [double]$bucket[0][1]
                $bHigh  = ($bucket | ForEach-Object { [double]$_[2] } | Measure-Object -Maximum).Maximum
                $bLow   = ($bucket | ForEach-Object { [double]$_[3] } | Measure-Object -Minimum).Minimum
                $bClose = [double]$bucket[$bucket.Count - 1][4]
                $bVol   = ($bucket | ForEach-Object { [long]$_[5] } | Measure-Object -Sum).Sum
                $aggregated.Add(@($bucketStart, $bOpen, $bHigh, $bLow, $bClose, $bVol))
                $bucket.Clear()
                $bucketStart = $null
            }
        }
        # Drop incomplete last bucket (matches Quick-HA-Analysis behavior)
    }
    return $aggregated
}

function Convert-ToHA($rawCandles) {
    $ha = [System.Collections.Generic.List[PSCustomObject]]::new()
    $prev = $null
    $prevDate = $null
    foreach ($c in $rawCandles) {
        $candleDate = ([datetime]$c[0]).Date
        if ($candleDate -ne $prevDate) { $prev = $null; $prevDate = $candleDate }
        $open  = [double]$c[1]; $high = [double]$c[2]; $low = [double]$c[3]; $close = [double]$c[4]; $vol = [long]$c[5]
        $haClose = ($open + $high + $low + $close) / 4.0
        $haOpen  = if ($null -ne $prev) { ($prev.Open + $prev.Close) / 2.0 } else { ($open + $close) / 2.0 }
        $haHigh  = [Math]::Max($high, [Math]::Max($haOpen, $haClose))
        $haLow   = [Math]::Min($low, [Math]::Min($haOpen, $haClose))
        $candle  = [PSCustomObject]@{
            Time = $c[0]; Open = [Math]::Round($haOpen,2); High = [Math]::Round($haHigh,2)
            Low = [Math]::Round($haLow,2); Close = [Math]::Round($haClose,2); Volume = $vol
            RawClose = $close; RawHigh = $high; RawLow = $low
        }
        $ha.Add($candle); $prev = $candle
    }
    return $ha
}

function Filter-ByTime($haCandles, $startSpan, $closeSpan) {
    $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($h in $haCandles) {
        $ts = $h.Time
        if ($ts -is [string]) { try { $ts = [DateTime]::Parse($ts) } catch { continue } }
        # Include all candles from entry start until market close (exits need full day)
        if ($ts.TimeOfDay -ge $startSpan -and $ts.TimeOfDay -le $closeSpan) { $filtered.Add($h) }
    }
    return $filtered
}

function Group-ByDay($haCandles) {
    $groups = [ordered]@{}
    foreach ($h in $haCandles) {
        $ts = $h.Time
        if ($ts -is [string]) { try { $ts = [DateTime]::Parse($ts) } catch { continue } }
        $dk = $ts.ToString('yyyy-MM-dd')
        if (-not $groups.Contains($dk)) { $groups[$dk] = [System.Collections.Generic.List[PSCustomObject]]::new() }
        $groups[$dk].Add($h)
    }
    return $groups
}

function Run-LongStrategy($dayGroups, $entryStartSpan, $entryStopSpan, [int]$lookback = 3) {
    $trades = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($dayKey in $dayGroups.Keys) {
        $dc = $dayGroups[$dayKey]; if ($dc.Count -lt 2) { continue }
        $inPos = $false; $ep = 0.0; $sl = 0.0; $et = $null; $eCandle = $null
        for ($i = 1; $i -lt $dc.Count; $i++) {
            $cur = $dc[$i]; $prv = $dc[$i-1]
            $cTime = $cur.Time; if ($cTime -is [string]) { try { $cTime = [DateTime]::Parse($cTime) } catch {} }
            $tod = $cTime.TimeOfDay
            # Entry: only within entry window
            if ((-not $inPos) -and ($tod -ge $entryStartSpan) -and ($tod -le $entryStopSpan) -and ($cur.Close -gt $prv.High)) {
                $inPos = $true; $ep = $cur.RawClose; $et = $cTime; $eCandle = $cur
                $slStart = [Math]::Max(0, $i - $lookback + 1)
                $sl = ($dc[$slStart..$i] | ForEach-Object { $_.RawLow } | Measure-Object -Minimum).Minimum
                continue
            }
            # SL hit
            if ($inPos -and ($cur.RawClose -le $sl)) {
                $xp = [Math]::Round($sl, 2)
                $xt = $cTime
                $trades.Add([PSCustomObject]@{
                    Day=$dayKey; PnL=[Math]::Round($xp - $ep, 2); EntryTime=$et; ExitTime=$xt
                    EntryPrice=$ep; ExitPrice=$xp; SL=$sl; Reason='SL'
                    EntryO=$eCandle.RawClose; EntryH=$eCandle.RawHigh; EntryL=$eCandle.RawLow
                    ExitO=[double]$cur.RawClose; ExitH=[double]$cur.RawHigh; ExitL=[double]$cur.RawLow
                })
                $inPos = $false; continue
            }
            # Signal exit
            if ($inPos -and ($cur.Close -lt $prv.Low)) {
                $xp = $cur.RawClose; $xt = $cTime
                $trades.Add([PSCustomObject]@{
                    Day=$dayKey; PnL=[Math]::Round($xp - $ep, 2); EntryTime=$et; ExitTime=$xt
                    EntryPrice=$ep; ExitPrice=$xp; SL=$sl; Reason='Signal'
                    EntryO=$eCandle.RawClose; EntryH=$eCandle.RawHigh; EntryL=$eCandle.RawLow
                    ExitO=[double]$cur.RawClose; ExitH=[double]$cur.RawHigh; ExitL=[double]$cur.RawLow
                })
                $inPos = $false
            }
        }
        # EOD
        if ($inPos) {
            $lc = $dc[$dc.Count - 1]
            $lcTime = $lc.Time; if ($lcTime -is [string]) { try { $lcTime = [DateTime]::Parse($lcTime) } catch {} }
            $trades.Add([PSCustomObject]@{
                Day=$dayKey; PnL=[Math]::Round($lc.RawClose - $ep, 2); EntryTime=$et; ExitTime=$lcTime
                EntryPrice=$ep; ExitPrice=$lc.RawClose; SL=$sl; Reason='EOD'
                EntryO=$eCandle.RawClose; EntryH=$eCandle.RawHigh; EntryL=$eCandle.RawLow
                ExitO=[double]$lc.RawClose; ExitH=[double]$lc.RawHigh; ExitL=[double]$lc.RawLow
            })
        }
    }
    return $trades
}

function Run-ShortStrategy($dayGroups, $entryStartSpan, $entryStopSpan, [int]$lookback = 3) {
    $trades = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($dayKey in $dayGroups.Keys) {
        $dc = $dayGroups[$dayKey]; if ($dc.Count -lt 2) { continue }
        $inPos = $false; $ep = 0.0; $sl = 0.0; $et = $null; $eCandle = $null
        for ($i = 1; $i -lt $dc.Count; $i++) {
            $cur = $dc[$i]; $prv = $dc[$i-1]
            $cTime = $cur.Time; if ($cTime -is [string]) { try { $cTime = [DateTime]::Parse($cTime) } catch {} }
            $tod = $cTime.TimeOfDay
            # Entry: only within entry window
            if ((-not $inPos) -and ($tod -ge $entryStartSpan) -and ($tod -le $entryStopSpan) -and ($cur.Close -lt $prv.Low)) {
                $inPos = $true; $ep = $cur.RawClose; $et = $cTime; $eCandle = $cur
                $slStart = [Math]::Max(0, $i - $lookback + 1)
                $sl = ($dc[$slStart..$i] | ForEach-Object { $_.RawHigh } | Measure-Object -Maximum).Maximum
                continue
            }
            # SL hit
            if ($inPos -and ($cur.RawClose -ge $sl)) {
                $xp = [Math]::Round($sl, 2)
                $xt = $cTime
                $trades.Add([PSCustomObject]@{
                    Day=$dayKey; PnL=[Math]::Round($ep - $xp, 2); EntryTime=$et; ExitTime=$xt
                    EntryPrice=$ep; ExitPrice=$xp; SL=$sl; Reason='SL'
                    EntryO=$eCandle.RawClose; EntryH=$eCandle.RawHigh; EntryL=$eCandle.RawLow
                    ExitO=[double]$cur.RawClose; ExitH=[double]$cur.RawHigh; ExitL=[double]$cur.RawLow
                })
                $inPos = $false; continue
            }
            # Signal exit
            if ($inPos -and ($cur.Close -gt $prv.High)) {
                $xp = $cur.RawClose; $xt = $cTime
                $trades.Add([PSCustomObject]@{
                    Day=$dayKey; PnL=[Math]::Round($ep - $xp, 2); EntryTime=$et; ExitTime=$xt
                    EntryPrice=$ep; ExitPrice=$xp; SL=$sl; Reason='Signal'
                    EntryO=$eCandle.RawClose; EntryH=$eCandle.RawHigh; EntryL=$eCandle.RawLow
                    ExitO=[double]$cur.RawClose; ExitH=[double]$cur.RawHigh; ExitL=[double]$cur.RawLow
                })
                $inPos = $false
            }
        }
        # EOD
        if ($inPos) {
            $lc = $dc[$dc.Count - 1]
            $lcTime = $lc.Time; if ($lcTime -is [string]) { try { $lcTime = [DateTime]::Parse($lcTime) } catch {} }
            $trades.Add([PSCustomObject]@{
                Day=$dayKey; PnL=[Math]::Round($ep - $lc.RawClose, 2); EntryTime=$et; ExitTime=$lcTime
                EntryPrice=$ep; ExitPrice=$lc.RawClose; SL=$sl; Reason='EOD'
                EntryO=$eCandle.RawClose; EntryH=$eCandle.RawHigh; EntryL=$eCandle.RawLow
                ExitO=[double]$lc.RawClose; ExitH=[double]$lc.RawHigh; ExitL=[double]$lc.RawLow
            })
        }
    }
    return $trades
}

function Get-Stats($trades) {
    if ($trades.Count -eq 0) {
        return [PSCustomObject]@{
            Trades=0; Winners=0; Losers=0; WinPct=0; TotalPnL=0; AvgPnL=0
            AvgWin=0; AvgLoss=0; MaxWin=0; MaxLoss=0; PF='N/A'; MaxDD=0; ConsecW=0; ConsecL=0
        }
    }
    $w = @($trades | Where-Object { $_.PnL -gt 0 })
    $l = @($trades | Where-Object { $_.PnL -lt 0 })
    $total = [Math]::Round(($trades | Measure-Object -Property PnL -Sum).Sum, 2)
    $avgPnL = [Math]::Round($total / $trades.Count, 2)
    $avgW = if ($w.Count -gt 0) { [Math]::Round(($w | Measure-Object -Property PnL -Sum).Sum / $w.Count, 2) } else { 0 }
    $avgL = if ($l.Count -gt 0) { [Math]::Round(($l | Measure-Object -Property PnL -Sum).Sum / $l.Count, 2) } else { 0 }
    $maxW = if ($w.Count -gt 0) { ($w | Measure-Object -Property PnL -Maximum).Maximum } else { 0 }
    $maxL = if ($l.Count -gt 0) { ($l | Measure-Object -Property PnL -Minimum).Minimum } else { 0 }
    $pf = if ($l.Count -gt 0 -and ($l | Measure-Object -Property PnL -Sum).Sum -ne 0) {
        [Math]::Round([Math]::Abs(($w | Measure-Object -Property PnL -Sum).Sum / ($l | Measure-Object -Property PnL -Sum).Sum), 2)
    } else { 'N/A' }
    # Max drawdown
    $cum = 0.0; $peak = 0.0; $dd = 0.0
    foreach ($t in $trades) { $cum += $t.PnL; if ($cum -gt $peak) { $peak = $cum }; $d = $peak - $cum; if ($d -gt $dd) { $dd = $d } }
    $dd = [Math]::Round($dd, 2)
    # Consecutive
    $cw = 0; $cl = 0; $mw = 0; $ml = 0
    foreach ($t in $trades) {
        if ($t.PnL -gt 0) { $cw++; $cl = 0; if ($cw -gt $mw) { $mw = $cw } }
        elseif ($t.PnL -lt 0) { $cl++; $cw = 0; if ($cl -gt $ml) { $ml = $cl } }
        else { $cw = 0; $cl = 0 }
    }
    return [PSCustomObject]@{
        Trades=$trades.Count; Winners=$w.Count; Losers=$l.Count
        WinPct=[Math]::Round(($w.Count/$trades.Count)*100,1); TotalPnL=$total; AvgPnL=$avgPnL
        AvgWin=$avgW; AvgLoss=$avgL; MaxWin=$maxW; MaxLoss=$maxL; PF=$pf; MaxDD=$dd; ConsecW=$mw; ConsecL=$ml
    }
}

# ================================================================
# Main loop: fetch once per timeframe, run both strategies
# ================================================================

# Kite API max days per request by interval
$maxDaysPerChunk = @{
    'minute'=60; '3minute'=100; '5minute'=100; '10minute'=100
    '15minute'=100; '30minute'=365; '60minute'=365
}

function Fetch-ChunkedCandles($instToken, $fetchTF, $fromDate, $toDate, $headers, $maxDays) {
    $allCandles = [System.Collections.Generic.List[object]]::new()
    $startDt = [DateTime]::Parse($fromDate)
    $endDt   = [DateTime]::Parse($toDate)
    $chunkNum = 0
    while ($startDt -lt $endDt) {
        $chunkEnd = $startDt.AddDays($maxDays - 1)
        if ($chunkEnd -gt $endDt) { $chunkEnd = $endDt }
        $chunkNum++
        $f = $startDt.ToString('yyyy-MM-dd')
        $t = $chunkEnd.ToString('yyyy-MM-dd')
        $histUrl = "https://api.kite.trade/instruments/historical/$instToken/$fetchTF`?from=$f+00:00:00&to=$t+23:59:59"
        try {
            $resp = Invoke-RestMethod -Uri $histUrl -Headers $headers -Method Get -ErrorAction Stop
            if ($resp.data -and $resp.data.candles -and $resp.data.candles.Count -gt 0) {
                foreach ($c in $resp.data.candles) { $allCandles.Add($c) }
                if ($chunkNum -gt 1) { Write-Host " +$($resp.data.candles.Count)" -ForegroundColor Green -NoNewline }
            }
        } catch {
            Write-Host " chunk[$f..$t] FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
        $startDt = $chunkEnd.AddDays(1)
    }
    return $allCandles
}

$script:cached1mCandles = $null
$tfCount = 0
foreach ($tf in $TimeFrames) {
    $tfCount++
    Write-Host "  [$tfCount/$($TimeFrames.Count)] Fetching $tf data..." -ForegroundColor Yellow -NoNewline

    # Determine API interval — 2min/4min need aggregation from 1-min data
    $nativeIntervals = @('minute','3minute','5minute','10minute','15minute','30minute','60minute')
    $needsAggregation = $tf -notin $nativeIntervals
    $fetchTF = if ($needsAggregation) { 'minute' } else { $tf }
    $aggMinutes = switch ($tf) { '2minute' { 2 } '4minute' { 4 } default { 0 } }
    $chunkMax = if ($maxDaysPerChunk.ContainsKey($fetchTF)) { $maxDaysPerChunk[$fetchTF] } else { 60 }

    # Use cached 1-min data if already fetched
    if ($needsAggregation -and $script:cached1mCandles) {
        $raw = $script:cached1mCandles
        Write-Host " (from 1m cache: $($raw.Count))" -ForegroundColor DarkGray -NoNewline
    } else {
        $raw = Fetch-ChunkedCandles $instToken $fetchTF $fromDate $toDate $headers $chunkMax
        if ($raw.Count -eq 0) {
            Write-Host " No data." -ForegroundColor Red
            continue
        }
        # Cache 1-min data for reuse by 2min/4min
        if ($fetchTF -eq 'minute') { $script:cached1mCandles = $raw }
        Write-Host " $($raw.Count) candles" -ForegroundColor Green -NoNewline
    }

    # Aggregate if needed
    if ($needsAggregation) {
        $raw = Aggregate-Candles $raw $aggMinutes
        Write-Host " -> $($raw.Count) ${tf}" -ForegroundColor Green -NoNewline
    }

    # Convert & filter
    $ha = Convert-ToHA $raw
    $ha = Filter-ByTime $ha $entryStartSpan $marketCloseSpan
    Write-Host " -> $($ha.Count) filtered" -ForegroundColor Green -NoNewline

    # Group by day
    $dayGroups = Group-ByDay $ha
    $tradingDays = $dayGroups.Keys.Count
    Write-Host " ($tradingDays trading days)" -ForegroundColor DarkGray

    # Run both strategies
    $longTrades  = Run-LongStrategy  $dayGroups $entryStartSpan $entryStopSpan $SLLookback
    $shortTrades = Run-ShortStrategy $dayGroups $entryStartSpan $entryStopSpan $SLLookback

    $longStats  = Get-Stats $longTrades
    $shortStats = Get-Stats $shortTrades

    # Show detailed trades if -ShowTrades switch is on
    if ($ShowTrades) {
        $tfLbl = if ($tfLabels.Contains($tf)) { $tfLabels[$tf] } else { $tf }
        foreach ($strat in @('LONG','SHORT')) {
            $tList = if ($strat -eq 'LONG') { $longTrades } else { $shortTrades }
            if ($tList.Count -eq 0) { continue }
            Write-Host ""
            Write-Host "  TRADE LOG — $strat $tfLbl" -ForegroundColor Magenta
            $tLogSep = "  " + ("-" * 130)
            $tLogHdr = "  {0,4} {1,-12} {2,-8} {3,10} {4,-8} {5,10} {6,10} {7,-7} {8,22} {9,22} {10,8}" -f '#','Date','EntryAt','EntryPx','ExitAt','ExitPx','SL','Reason','Entry(C/H/L)','Exit(C/H/L)','PnL'
            Write-Host $tLogSep -ForegroundColor DarkGray
            Write-Host $tLogHdr -ForegroundColor Cyan
            Write-Host $tLogSep -ForegroundColor DarkGray
            $tNum = 0
            foreach ($t in $tList) {
                $tNum++
                $entryTs = if ($t.EntryTime -is [DateTime]) { $t.EntryTime.ToString('HH:mm') } else { "$($t.EntryTime)" }
                $exitTs  = if ($t.ExitTime  -is [DateTime]) { $t.ExitTime.ToString('HH:mm')  } else { "$($t.ExitTime)"  }
                $eCHL = "{0}/{1}/{2}" -f $t.EntryO, $t.EntryH, $t.EntryL
                $xCHL = "{0}/{1}/{2}" -f $t.ExitO, $t.ExitH, $t.ExitL
                $pnlStr = if ($t.PnL -ge 0) { "+$($t.PnL)" } else { "$($t.PnL)" }
                $color = if ($t.PnL -ge 0) { 'Green' } elseif ($t.Reason -eq 'SL') { 'Red' } else { 'Yellow' }
                $line = "  {0,4} {1,-12} {2,-8} {3,10} {4,-8} {5,10} {6,10} {7,-7} {8,22} {9,22} {10,8}" -f $tNum, $t.Day, $entryTs, $t.EntryPrice, $exitTs, $t.ExitPrice, $t.SL, $t.Reason, $eCHL, $xCHL, $pnlStr
                Write-Host $line -ForegroundColor $color
            }
            Write-Host $tLogSep -ForegroundColor DarkGray
        }
    }

    # Compute per-day PnL
    $longDaily  = @{}
    $shortDaily = @{}
    foreach ($t in $longTrades)  { if (-not $longDaily.ContainsKey($t.Day))  { $longDaily[$t.Day]  = 0.0 }; $longDaily[$t.Day]  += $t.PnL }
    foreach ($t in $shortTrades) { if (-not $shortDaily.ContainsKey($t.Day)) { $shortDaily[$t.Day] = 0.0 }; $shortDaily[$t.Day] += $t.PnL }

    $allResults.Add([PSCustomObject]@{ TF=$tf; Strategy='LONG';  Days=$tradingDays; Stats=$longStats;  DailyPnL=$longDaily })
    $allResults.Add([PSCustomObject]@{ TF=$tf; Strategy='SHORT'; Days=$tradingDays; Stats=$shortStats; DailyPnL=$shortDaily })
}

# ================================================================
# Print Summary Report
# ================================================================
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  CONSOLIDATED BACKTEST REPORT" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  Symbol: $sym ($label)  |  Period: $fromDate to $toDate  |  SL: Last $SLLookback candle(s) Low/High" -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

# ── Collect all trading days across all timeframes ──
$allDays = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $allResults) { foreach ($dk in $r.DailyPnL.Keys) { [void]$allDays.Add($dk) } }
$sortedDays = $allDays | Sort-Object

# ── Helper to format PnL value for fixed-width column ──
function Fmt-PnL([double]$v) {
    $s = [Math]::Round($v, 1)
    if ($s -ge 0) { return "+$s" } else { return "$s" }
}

# ================================================================
# DAILY P&L REPORT — LONG STRATEGY
# ================================================================
Write-Host "  DAILY P&L — LONG STRATEGY:" -ForegroundColor Yellow
Write-Host ""

# Build header
$colW = 9
$hdrLine = "  {0,-12}" -f "Date"
$sepLine = "  " + ("-" * 12)
foreach ($tf in $TimeFrames) {
    $lb = if ($tfLabels.Contains($tf)) { $tfLabels[$tf] } else { $tf.Substring(0,[Math]::Min(4,$tf.Length)) }
    $hdrLine += ("{0,$colW}" -f $lb)
    $sepLine += ("-" * $colW)
}
$hdrLine += ("{0,$colW}" -f "TOTAL")
$sepLine += ("-" * $colW)

Write-Host $sepLine -ForegroundColor DarkGray
Write-Host $hdrLine -ForegroundColor Cyan
Write-Host $sepLine -ForegroundColor DarkGray

# TF totals accumulators
$longTFTotals = @{}; foreach ($tf in $TimeFrames) { $longTFTotals[$tf] = 0.0 }
$longGrandTotal = 0.0

foreach ($day in $sortedDays) {
    $line = "  {0,-12}" -f $day
    $dayTotal = 0.0
    foreach ($tf in $TimeFrames) {
        $r = $allResults | Where-Object { $_.TF -eq $tf -and $_.Strategy -eq 'LONG' }
        $pnl = if ($r -and $r.DailyPnL.ContainsKey($day)) { [Math]::Round($r.DailyPnL[$day], 2) } else { 0 }
        $dayTotal += $pnl
        $longTFTotals[$tf] += $pnl
        $line += ("{0,$colW}" -f (Fmt-PnL $pnl))
    }
    $longGrandTotal += $dayTotal
    $line += ("{0,$colW}" -f (Fmt-PnL $dayTotal))
    $color = if ($dayTotal -ge 0) { 'Green' } else { 'Red' }
    Write-Host $line -ForegroundColor $color
}

# Totals row
Write-Host $sepLine -ForegroundColor DarkGray
$totLine = "  {0,-12}" -f "TOTAL"
foreach ($tf in $TimeFrames) { $totLine += ("{0,$colW}" -f (Fmt-PnL $longTFTotals[$tf])) }
$totLine += ("{0,$colW}" -f (Fmt-PnL $longGrandTotal))
$totColor = if ($longGrandTotal -ge 0) { 'Green' } else { 'Red' }
Write-Host $totLine -ForegroundColor $totColor
Write-Host $sepLine -ForegroundColor DarkGray
Write-Host ""

# ================================================================
# DAILY P&L REPORT — SHORT STRATEGY
# ================================================================
Write-Host "  DAILY P&L — SHORT STRATEGY:" -ForegroundColor Yellow
Write-Host ""

Write-Host $sepLine -ForegroundColor DarkGray
Write-Host $hdrLine -ForegroundColor Cyan
Write-Host $sepLine -ForegroundColor DarkGray

$shortTFTotals = @{}; foreach ($tf in $TimeFrames) { $shortTFTotals[$tf] = 0.0 }
$shortGrandTotal = 0.0

foreach ($day in $sortedDays) {
    $line = "  {0,-12}" -f $day
    $dayTotal = 0.0
    foreach ($tf in $TimeFrames) {
        $r = $allResults | Where-Object { $_.TF -eq $tf -and $_.Strategy -eq 'SHORT' }
        $pnl = if ($r -and $r.DailyPnL.ContainsKey($day)) { [Math]::Round($r.DailyPnL[$day], 2) } else { 0 }
        $dayTotal += $pnl
        $shortTFTotals[$tf] += $pnl
        $line += ("{0,$colW}" -f (Fmt-PnL $pnl))
    }
    $shortGrandTotal += $dayTotal
    $line += ("{0,$colW}" -f (Fmt-PnL $dayTotal))
    $color = if ($dayTotal -ge 0) { 'Green' } else { 'Red' }
    Write-Host $line -ForegroundColor $color
}

Write-Host $sepLine -ForegroundColor DarkGray
$totLine = "  {0,-12}" -f "TOTAL"
foreach ($tf in $TimeFrames) { $totLine += ("{0,$colW}" -f (Fmt-PnL $shortTFTotals[$tf])) }
$totLine += ("{0,$colW}" -f (Fmt-PnL $shortGrandTotal))
$totColor = if ($shortGrandTotal -ge 0) { 'Green' } else { 'Red' }
Write-Host $totLine -ForegroundColor $totColor
Write-Host $sepLine -ForegroundColor DarkGray
Write-Host ""

# ================================================================
# DAILY COMBINED P&L — LONG + SHORT per day
# ================================================================
$combTFs = @('minute','2minute','3minute')
$cColW = 12
$cSep = "  " + ("-" * 62)
$cHdr = "  {0,-12}{1,$cColW}{2,$cColW}{3,$cColW}{4,$cColW}" -f "Date","Long","Short","Combined","Cumulative"

foreach ($ctf in $combTFs) {
    $ctfLabel = if ($tfLabels.Contains($ctf)) { $tfLabels[$ctf] } else { $ctf }
    Write-Host "  DAILY COMBINED P&L — LONG + SHORT ($ctfLabel):" -ForegroundColor Yellow
    Write-Host ""
    Write-Host $cSep -ForegroundColor DarkGray
    Write-Host $cHdr -ForegroundColor Cyan
    Write-Host $cSep -ForegroundColor DarkGray

    $cumTotal = 0.0
    $combLongTotal = 0.0; $combShortTotal = 0.0; $combGrandTotal = 0.0

    foreach ($day in $sortedDays) {
        $rL = $allResults | Where-Object { $_.TF -eq $ctf -and $_.Strategy -eq 'LONG' }
        $rS = $allResults | Where-Object { $_.TF -eq $ctf -and $_.Strategy -eq 'SHORT' }
        $dayLong  = if ($rL -and $rL.DailyPnL.ContainsKey($day)) { [Math]::Round($rL.DailyPnL[$day], 2) } else { 0 }
        $dayShort = if ($rS -and $rS.DailyPnL.ContainsKey($day)) { [Math]::Round($rS.DailyPnL[$day], 2) } else { 0 }
        $dayComb = [Math]::Round($dayLong + $dayShort, 2)
        $cumTotal += $dayComb
        $combLongTotal += $dayLong; $combShortTotal += $dayShort; $combGrandTotal += $dayComb
        $line = "  {0,-12}{1,$cColW}{2,$cColW}{3,$cColW}{4,$cColW}" -f $day, (Fmt-PnL $dayLong), (Fmt-PnL $dayShort), (Fmt-PnL $dayComb), (Fmt-PnL ([Math]::Round($cumTotal,2)))
        $color = if ($dayComb -ge 0) { 'Green' } else { 'Red' }
        Write-Host $line -ForegroundColor $color
    }

    Write-Host $cSep -ForegroundColor DarkGray
    $totLine = "  {0,-12}{1,$cColW}{2,$cColW}{3,$cColW}{4,$cColW}" -f "TOTAL", (Fmt-PnL $combLongTotal), (Fmt-PnL $combShortTotal), (Fmt-PnL $combGrandTotal), ""
    $totColor = if ($combGrandTotal -ge 0) { 'Green' } else { 'Red' }
    Write-Host $totLine -ForegroundColor $totColor
    Write-Host $cSep -ForegroundColor DarkGray
    Write-Host ""
}

# ================================================================
# OVERALL STRATEGY SUMMARY
# ================================================================
Write-Host "  STRATEGY TOTALS:" -ForegroundColor Yellow
Write-Host "  -----------------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
$hdr = "  {0,-10} {1,5} {2,6} {3,4}/{4,-4} {5,6} {6,10} {7,8} {8,8} {9,8} {10,8} {11,6} {12,8} {13,4}/{14,-4}"
Write-Host ($hdr -f "TimeFrame","Days","Trd","W","L","Win%","TotalPnL","AvgPnL","AvgWin","AvgLoss","MaxWin","PF","MaxDD","CW","CL") -ForegroundColor Cyan
Write-Host "  -----------------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray

Write-Host "  --- LONG ---" -ForegroundColor Yellow
foreach ($r in ($allResults | Where-Object { $_.Strategy -eq 'LONG' })) {
    $s = $r.Stats
    $color = if ($s.TotalPnL -ge 0) { 'Green' } else { 'Red' }
    $pnlStr = if ($s.TotalPnL -ge 0) { "+$($s.TotalPnL)" } else { "$($s.TotalPnL)" }
    Write-Host ($hdr -f $r.TF, $r.Days, $s.Trades, $s.Winners, $s.Losers, "$($s.WinPct)%", $pnlStr, $s.AvgPnL, $s.AvgWin, $s.AvgLoss, $s.MaxWin, $s.PF, $s.MaxDD, $s.ConsecW, $s.ConsecL) -ForegroundColor $color
}
Write-Host "  --- SHORT ---" -ForegroundColor Yellow
foreach ($r in ($allResults | Where-Object { $_.Strategy -eq 'SHORT' })) {
    $s = $r.Stats
    $color = if ($s.TotalPnL -ge 0) { 'Green' } else { 'Red' }
    $pnlStr = if ($s.TotalPnL -ge 0) { "+$($s.TotalPnL)" } else { "$($s.TotalPnL)" }
    Write-Host ($hdr -f $r.TF, $r.Days, $s.Trades, $s.Winners, $s.Losers, "$($s.WinPct)%", $pnlStr, $s.AvgPnL, $s.AvgWin, $s.AvgLoss, $s.MaxWin, $s.PF, $s.MaxDD, $s.ConsecW, $s.ConsecL) -ForegroundColor $color
}
Write-Host "  -----------------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# Best performers
Write-Host "  TOP PERFORMERS:" -ForegroundColor Yellow
$sorted = $allResults | Sort-Object { $_.Stats.TotalPnL } -Descending
$best = $sorted[0]
$worst = $sorted[-1]
Write-Host "  Best  : $($best.Strategy) $($best.TF) -> PnL: $($best.Stats.TotalPnL) | Win%: $($best.Stats.WinPct)% | PF: $($best.Stats.PF) | Trades: $($best.Stats.Trades)" -ForegroundColor Green
Write-Host "  Worst : $($worst.Strategy) $($worst.TF) -> PnL: $($worst.Stats.TotalPnL) | Win%: $($worst.Stats.WinPct)% | PF: $($worst.Stats.PF) | Trades: $($worst.Stats.Trades)" -ForegroundColor Red

$bestPF = $allResults | Where-Object { $_.Stats.PF -ne 'N/A' -and $_.Stats.PF -gt 0 } | Sort-Object { $_.Stats.PF } -Descending | Select-Object -First 1
if ($bestPF) {
    Write-Host "  BestPF: $($bestPF.Strategy) $($bestPF.TF) -> PF: $($bestPF.Stats.PF) | PnL: $($bestPF.Stats.TotalPnL) | Win%: $($bestPF.Stats.WinPct)% | DD: $($bestPF.Stats.MaxDD)" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
