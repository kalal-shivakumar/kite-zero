<#
.SYNOPSIS
  Quick inline Heikin-Ashi trade analysis on raw candles for a single instrument/day.
.DESCRIPTION
  Fetches raw candles, converts to HA, runs Long + Short strategies with
  N-candle lookback SL, prints trade log and summary.
.EXAMPLE
  .\Quick-HA-Analysis.ps1 -TradingSymbol NIFTY2661623800CE -InstrumentToken 12955394
  .\Quick-HA-Analysis.ps1 -TradingSymbol NIFTY2661623800CE -InstrumentToken 12955394 -SLLookback 1 -TimeFrame 3minute
  .\Quick-HA-Analysis.ps1 -TradingSymbol NIFTY2661624100PE -InstrumentToken 12958722 -Date 2026-06-15
#>

param(
    [Parameter(Mandatory)][string]$TradingSymbol,
    [Parameter(Mandatory)][int]$InstrumentToken,
    [string]$Date            = (Get-Date).ToString('yyyy-MM-dd'),
    [string]$TimeFrame       = 'minute',
    [int]$SLLookback         = 3,
    [string]$EntryStartTime  = '09:16',
    [string]$EntryStopTime   = '15:29',
    [string]$MarketCloseTime = '15:30',
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret
)

# ── Auth setup ──────────────────────────────────────────────────
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'KiteData.psm1') -Force

if (-not $Global:common_header) {
    $cfg = Get-Content (Join-Path $root 'input.json') -Raw | ConvertFrom-Json
    $ak  = if ($API_Key) { $API_Key } else { $cfg.API_Key }
    $tok = if ($AccessToken) { $AccessToken }
           else { (Get-Content (Join-Path $root 'accesstoken.json') -Raw | ConvertFrom-Json).access_token }
    $Global:common_header = @{
        'X-Kite-Version' = '3'
        'Authorization'  = "token ${ak}:${tok}"
    }
}

# ── Fetch raw candles ───────────────────────────────────────────
$fromDate = $Date
$toDate   = "$Date $MarketCloseTime`:00"

Write-Host "`n  Fetching $TimeFrame candles for $TradingSymbol ($InstrumentToken) on $Date ..." -ForegroundColor DarkGray

# Map timeframe to API interval
$tfMap = @{
    'minute'='1'; '2minute'='2'; '3minute'='3'; '4minute'='4'; '5minute'='5'
    '10minute'='10'; '15minute'='15'; '30minute'='30'; '60minute'='60'
}
$apiTF = if ($tfMap.ContainsKey($TimeFrame)) { $tfMap[$TimeFrame] } else { $TimeFrame }

# For 2min/4min we need 1-min data and aggregate
$needsAggregation = $TimeFrame -in @('2minute','4minute')

if ($needsAggregation) {
    $raw1m = Get-ZerodhaCandleData -tradingsymbol $TradingSymbol -instrument_token $InstrumentToken `
        -TimeFrame '1' -FromDate $fromDate -TODate $toDate -LastNCandles 500
    $minutes = [int]($TimeFrame -replace 'minute','')
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
    Write-Host "  Aggregated $($raw1m.Count) 1-min candles -> $($raw.Count) ${TimeFrame} candles" -ForegroundColor DarkGray
} else {
    $raw = Get-ZerodhaCandleData -tradingsymbol $TradingSymbol -instrument_token $InstrumentToken `
        -TimeFrame $apiTF -FromDate $fromDate -TODate $toDate -LastNCandles 500
}

if (-not $raw -or $raw.Count -lt 2) {
    Write-Host "  No candle data returned. Check instrument token / date." -ForegroundColor Red
    return
}

Write-Host "  Got $($raw.Count) candles" -ForegroundColor DarkGray

# ── Convert to Heikin-Ashi ──────────────────────────────────────
$ha = @()
$prev = $null
foreach ($c in $raw) {
    $hc = ($c.open + $c.high + $c.low + $c.close) / 4
    $ho = if ($prev) { ($prev.haOpen + $prev.haClose) / 2 } else { ($c.open + $c.close) / 2 }
    $hh = [Math]::Max($c.high, [Math]::Max($ho, $hc))
    $hl = [Math]::Min($c.low,  [Math]::Min($ho, $hc))
    $obj = [PSCustomObject]@{
        Time     = $c.timestamp
        haOpen   = [Math]::Round($ho, 2)
        haHigh   = [Math]::Round($hh, 2)
        haLow    = [Math]::Round($hl, 2)
        haClose  = [Math]::Round($hc, 2)
        RawClose = $c.close
        RawHigh  = $c.high
        RawLow   = $c.low
    }
    $ha += $obj
    $prev = $obj
}

# ── Parse time windows ─────────────────────────────────────────
$entryStart = [TimeSpan]::Parse($EntryStartTime)
$entryStop  = [TimeSpan]::Parse($EntryStopTime)

# ── Helper: format PnL ─────────────────────────────────────────
function Fmt-PnL($v) { if ($v -ge 0) { "+$v" } else { "$v" } }

# ── LONG Strategy ──────────────────────────────────────────────
$longTrades = @()
$inPos = $false

for ($i = 1; $i -lt $ha.Count; $i++) {
    $cur = $ha[$i]; $prv = $ha[$i - 1]
    $curTime = ([DateTime]$cur.Time).TimeOfDay

    # Entry: HA Close > Prev HA High, within entry window
    if (-not $inPos -and $cur.haClose -gt $prv.haHigh -and $curTime -ge $entryStart -and $curTime -le $entryStop) {
        $inPos = $true
        $ep = $cur.RawClose
        $et = $cur.Time
        $start = [Math]::Max(0, $i - $SLLookback + 1)
        $sl = ($ha[$start..$i] | Measure-Object -Property RawLow -Minimum).Minimum
        continue
    }

    if ($inPos) {
        # SL hit
        if ($cur.RawClose -le $sl) {
            $longTrades += [PSCustomObject]@{ E=$et; EP=$ep; X=$cur.Time; XP=$sl; PnL=[Math]::Round($sl - $ep, 2); R='SL' }
            $inPos = $false
            continue
        }
        # Signal exit: HA Close < Prev HA Low
        if ($cur.haClose -lt $prv.haLow) {
            $longTrades += [PSCustomObject]@{ E=$et; EP=$ep; X=$cur.Time; XP=$cur.RawClose; PnL=[Math]::Round($cur.RawClose - $ep, 2); R='Signal' }
            $inPos = $false
        }
    }
}
# EOD close
if ($inPos) {
    $lc = $ha[-1]
    $longTrades += [PSCustomObject]@{ E=$et; EP=$ep; X=$lc.Time; XP=$lc.RawClose; PnL=[Math]::Round($lc.RawClose - $ep, 2); R='EOD' }
}

# ── SHORT Strategy ─────────────────────────────────────────────
$shortTrades = @()
$inPos = $false

for ($i = 1; $i -lt $ha.Count; $i++) {
    $cur = $ha[$i]; $prv = $ha[$i - 1]
    $curTime = ([DateTime]$cur.Time).TimeOfDay

    # Entry: HA Close < Prev HA Low, within entry window
    if (-not $inPos -and $cur.haClose -lt $prv.haLow -and $curTime -ge $entryStart -and $curTime -le $entryStop) {
        $inPos = $true
        $ep = $cur.RawClose
        $et = $cur.Time
        $start = [Math]::Max(0, $i - $SLLookback + 1)
        $sl = ($ha[$start..$i] | Measure-Object -Property RawHigh -Maximum).Maximum
        continue
    }

    if ($inPos) {
        # SL hit
        if ($cur.RawClose -ge $sl) {
            $shortTrades += [PSCustomObject]@{ E=$et; EP=$ep; X=$cur.Time; XP=$sl; PnL=[Math]::Round($ep - $sl, 2); R='SL' }
            $inPos = $false
            continue
        }
        # Signal exit: HA Close > Prev HA High
        if ($cur.haClose -gt $prv.haHigh) {
            $shortTrades += [PSCustomObject]@{ E=$et; EP=$ep; X=$cur.Time; XP=$cur.RawClose; PnL=[Math]::Round($ep - $cur.RawClose, 2); R='Signal' }
            $inPos = $false
        }
    }
}
# EOD close
if ($inPos) {
    $lc = $ha[-1]
    $shortTrades += [PSCustomObject]@{ E=$et; EP=$ep; X=$lc.Time; XP=$lc.RawClose; PnL=[Math]::Round($ep - $lc.RawClose, 2); R='EOD' }
}

# ── Print Results ──────────────────────────────────────────────
$header = "  $TradingSymbol | $TimeFrame | $Date | SL Lookback: $SLLookback"
Write-Host "`n  $('=' * ($header.Length))" -ForegroundColor Cyan
Write-Host $header -ForegroundColor Cyan
Write-Host "  $('=' * ($header.Length))" -ForegroundColor Cyan

# Long trades
Write-Host "`n  ── LONG ──" -ForegroundColor Green
if ($longTrades.Count -eq 0) {
    Write-Host "  No trades" -ForegroundColor DarkGray
} else {
    $n = 0
    foreach ($t in $longTrades) {
        $n++
        $es = ([DateTime]$t.E).ToString('HH:mm')
        $xs = ([DateTime]$t.X).ToString('HH:mm')
        $p  = Fmt-PnL $t.PnL
        $pct = [Math]::Round($t.PnL / $t.EP * 100, 1)
        $pctStr = if ($pct -ge 0) { "+${pct}%" } else { "${pct}%" }
        $cl = if ($t.PnL -ge 0) { 'Green' } elseif ($t.R -eq 'SL') { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,3}. {1} Buy@{2,8} -> {3} Exit@{4,8} [{5,-6}] {6,9} {7,8}" -f $n, $es, $t.EP, $xs, $t.XP, $t.R, $p, $pctStr) -ForegroundColor $cl
    }
    $lw  = @($longTrades | Where-Object { $_.PnL -gt 0 })
    $ll  = @($longTrades | Where-Object { $_.PnL -lt 0 })
    $lTot = [Math]::Round(($longTrades | Measure-Object -Property PnL -Sum).Sum, 2)
    $lWinPct = [Math]::Round($lw.Count / $longTrades.Count * 100, 1)
    $lTotPct = [Math]::Round(($longTrades | ForEach-Object { $_.PnL / $_.EP * 100 } | Measure-Object -Sum).Sum, 1)
    $lTotPctStr = if ($lTotPct -ge 0) { "+${lTotPct}%" } else { "${lTotPct}%" }
    Write-Host "`n  Trades:$($longTrades.Count) W:$($lw.Count) L:$($ll.Count) Win%:${lWinPct}% PnL:$(Fmt-PnL $lTot) ($lTotPctStr)" -ForegroundColor Yellow
}

# Short trades
Write-Host "`n  ── SHORT ──" -ForegroundColor Magenta
if ($shortTrades.Count -eq 0) {
    Write-Host "  No trades" -ForegroundColor DarkGray
} else {
    $n = 0
    foreach ($t in $shortTrades) {
        $n++
        $es = ([DateTime]$t.E).ToString('HH:mm')
        $xs = ([DateTime]$t.X).ToString('HH:mm')
        $p  = Fmt-PnL $t.PnL
        $pct = [Math]::Round($t.PnL / $t.EP * 100, 1)
        $pctStr = if ($pct -ge 0) { "+${pct}%" } else { "${pct}%" }
        $cl = if ($t.PnL -ge 0) { 'Green' } elseif ($t.R -eq 'SL') { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,3}. {1} Sell@{2,8} -> {3} Cover@{4,8} [{5,-6}] {6,9} {7,8}" -f $n, $es, $t.EP, $xs, $t.XP, $t.R, $p, $pctStr) -ForegroundColor $cl
    }
    $sw  = @($shortTrades | Where-Object { $_.PnL -gt 0 })
    $sll = @($shortTrades | Where-Object { $_.PnL -lt 0 })
    $sTot = [Math]::Round(($shortTrades | Measure-Object -Property PnL -Sum).Sum, 2)
    $sWinPct = [Math]::Round($sw.Count / $shortTrades.Count * 100, 1)
    $sTotPct = [Math]::Round(($shortTrades | ForEach-Object { $_.PnL / $_.EP * 100 } | Measure-Object -Sum).Sum, 1)
    $sTotPctStr = if ($sTotPct -ge 0) { "+${sTotPct}%" } else { "${sTotPct}%" }
    Write-Host "`n  Trades:$($shortTrades.Count) W:$($sw.Count) L:$($sll.Count) Win%:${sWinPct}% PnL:$(Fmt-PnL $sTot) ($sTotPctStr)" -ForegroundColor Yellow
}

# Combined
if ($longTrades.Count -gt 0 -or $shortTrades.Count -gt 0) {
    $lTotal = if ($longTrades.Count -gt 0) { $lTot } else { 0 }
    $sTotal = if ($shortTrades.Count -gt 0) { $sTot } else { 0 }
    $combined = [Math]::Round($lTotal + $sTotal, 2)
    Write-Host "`n  ── COMBINED ──" -ForegroundColor Cyan
    Write-Host "  Long: $(Fmt-PnL $lTotal) + Short: $(Fmt-PnL $sTotal) = $(Fmt-PnL $combined)" -ForegroundColor White
}
Write-Host ""
