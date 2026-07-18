# Get-DayWiseTrades.ps1
# Day-wise F&O report + PERSISTENT daily capture.
#
# WHAT IT DOES
#   1) TODAY (live): fetches Kite Positions API (day-wise, authoritative) and Orders
#      API, pairs BUY->SELL into entry/exit trades.
#   2) CAPTURE: writes today's record (pnl / trades / wins / losses / per-trade
#      entries[]) into  webapp/data/daily-pnl-<user>.json.  This file is the single
#      source of truth and is used for ALL future calculations. Running the script
#      each trading day accumulates history (Kite itself is today-only).
#   3) REPORT: prints EVERY day stored in the JSON (plus today) with per-trade
#      entry/exit detail when available, and a grand total.
#
# Kite Connect has NO historical orders API, so past days can only exist in the JSON
# because they were captured on that day. Run this daily (e.g. via Task Scheduler
# after 3:30 PM) to build a permanent record.
#
# Usage:
#   .\Get-DayWiseTrades.ps1            # capture today + show all days
#   .\Get-DayWiseTrades.ps1 -NoSave    # report only, do not write JSON
#   .\Get-DayWiseTrades.ps1 -CaptureOnly  # write JSON, skip the report

param(
    [switch]$NoSave,
    [switch]$CaptureOnly
)

$ErrorActionPreference = 'Stop'
$tok     = Get-Content -Raw 'accesstoken.json' | ConvertFrom-Json
$headers = @{ 'Authorization' = "token $($tok.api_key):$($tok.access_token)"; 'X-Kite-Version' = '3' }
$fno     = @('NFO', 'BFO')
$userId  = $tok.user_id
$today   = (Get-Date).ToString('yyyy-MM-dd')
$nowIso  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ("  Day-wise F&O report + capture  -  {0}  ({1})" -f $userId, (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------
# Helper: pair BUY -> earliest later SELL of same symbol (webapp logic)
# Emits webapp-format entry objects (full timestamps for persistence).
# ---------------------------------------------------------------
function Get-PairedTrades($completed) {
    $buys  = @($completed | Where-Object { $_.transaction_type -eq 'BUY' }  | Sort-Object { [datetime]$_.order_timestamp })
    $sells = @($completed | Where-Object { $_.transaction_type -eq 'SELL' } | Sort-Object { [datetime]$_.order_timestamp })
    $usedSells = New-Object System.Collections.Generic.HashSet[string]
    $out = @()
    foreach ($buy in $buys) {
        $sell = $sells | Where-Object {
            $_.tradingsymbol -eq $buy.tradingsymbol -and
            (-not $usedSells.Contains([string]$_.order_id)) -and
            ([datetime]$_.order_timestamp -ge [datetime]$buy.order_timestamp)
        } | Select-Object -First 1
        if ($sell) {
            [void]$usedSells.Add([string]$sell.order_id)
            $entry = [double]$buy.average_price; $exit = [double]$sell.average_price; $qty = [double]$buy.quantity
            $out += [pscustomobject]@{
                symbol    = $buy.tradingsymbol
                exchange  = $buy.exchange
                qty       = $qty
                entry     = [math]::Round($entry, 2)
                exit      = [math]::Round($exit, 2)
                pnl       = [math]::Round(($exit - $entry) * $qty, 2)
                entryTime = ([datetime]$buy.order_timestamp).ToString('yyyy-MM-dd HH:mm:ss')
                exitTime  = ([datetime]$sell.order_timestamp).ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
    }
    , $out
}

# ---------------------------------------------------------------
# Helper: print one day's trade table + subtotal (rows in webapp entry format)
# ---------------------------------------------------------------
function Write-DayTrades($day, $rows, $tag) {
    $dayPnL = [double](($rows | Measure-Object -Property pnl -Sum).Sum)
    $wins   = @($rows | Where-Object { $_.pnl -gt 0 }).Count
    $loss   = @($rows | Where-Object { $_.pnl -lt 0 }).Count
    Write-Host ''
    Write-Host ("==== {0} {1} ====" -f $day, $tag) -ForegroundColor White
    $rows | Sort-Object exitTime | Select-Object `
        @{n = 'Entry'; e = { if ($_.entryTime) { ([string]$_.entryTime).Substring(11, 5) } else { '' } } },
        @{n = 'Exit'; e = { if ($_.exitTime) { ([string]$_.exitTime).Substring(11, 5) } else { '' } } },
        @{n = 'Exch'; e = { $_.exchange } }, @{n = 'Symbol'; e = { $_.symbol } }, @{n = 'Qty'; e = { $_.qty } },
        @{n = 'EntryPx'; e = { '{0:N2}' -f [double]$_.entry } },
        @{n = 'ExitPx'; e = { '{0:N2}' -f [double]$_.exit } },
        @{n = 'PnL'; e = { '{0:N2}' -f [double]$_.pnl } } | Format-Table -AutoSize
    $col = if ($dayPnL -ge 0) { 'Green' } else { 'Red' }
    Write-Host ("   Day total: {0:N2}   |   trades: {1}   |   W/L: {2}/{3}" -f $dayPnL, @($rows).Count, $wins, $loss) -ForegroundColor $col
}

# ---------------------------------------------------------------
# 0) TODAY via Positions API (Kite-authoritative day-wise realised P&L)
# ---------------------------------------------------------------
$posRealised = $null
try {
    $pos    = Invoke-RestMethod -Uri 'https://api.kite.trade/portfolio/positions' -Headers $headers -Method Get
    $dayPos = @($pos.data.day | Where-Object {
            $fno -contains $_.exchange -and ([double]$_.day_buy_quantity -ne 0 -or [double]$_.day_sell_quantity -ne 0)
        })
    Write-Host ("Positions API : {0} F&O day-position(s) for today" -f $dayPos.Count)
    if ($dayPos.Count -gt 0) {
        $posRealised = [double](($dayPos | Measure-Object -Property realised -Sum).Sum)
    }
}
catch { Write-Host ("Positions fetch skipped: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }

# ---------------------------------------------------------------
# 1) TODAY paired entry/exit trades from Orders API
# ---------------------------------------------------------------
$todayEntries = @()
try {
    $orders    = @((Invoke-RestMethod -Uri 'https://api.kite.trade/orders' -Headers $headers -Method Get).data)
    $completed = @($orders | Where-Object { $_.status -eq 'COMPLETE' -and $fno -contains $_.exchange })
    Write-Host ("Orders API    : {0} orders, {1} F&O COMPLETE" -f $orders.Count, $completed.Count)
    if ($completed.Count -gt 0) { $todayEntries = @(Get-PairedTrades $completed) }
}
catch { Write-Host ("Orders fetch skipped: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }

# Fallback: if no paired orders but Positions shows closed day-legs, synthesize one
# entry per symbol from day_buy_price/day_sell_price.
if ($todayEntries.Count -eq 0 -and $dayPos -and $dayPos.Count -gt 0) {
    $todayEntries = @($dayPos | Where-Object { [double]$_.day_sell_quantity -gt 0 -and [double]$_.day_buy_quantity -gt 0 } | ForEach-Object {
            $q = [math]::Min([double]$_.day_buy_quantity, [double]$_.day_sell_quantity)
            $en = [double]$_.day_buy_price; $ex = [double]$_.day_sell_price
            [pscustomobject]@{
                symbol = $_.tradingsymbol; exchange = $_.exchange; qty = $q
                entry = [math]::Round($en, 2); exit = [math]::Round($ex, 2)
                pnl = [math]::Round(($ex - $en) * $q, 2)
                entryTime = $nowIso; exitTime = $nowIso
            }
        })
}

# ---------------------------------------------------------------
# 2) Load persistent JSON (source of truth)
# ---------------------------------------------------------------
$dataDir  = Join-Path $PSScriptRoot 'webapp/data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$histPath = Join-Path $dataDir ("daily-pnl-{0}.json" -f ($userId -replace '[^a-zA-Z0-9-]', '-'))

$history = [ordered]@{}
if (Test-Path $histPath) {
    $raw = Get-Content -Raw $histPath | ConvertFrom-Json
    foreach ($p in $raw.PSObject.Properties) { $history[$p.Name] = $p.Value }
    Write-Host ("History file  : {0} ({1} day(s) stored)" -f $histPath, $history.Count)
}
else {
    Write-Host ("History file  : {0} (new)" -f $histPath)
}

# ---------------------------------------------------------------
# 3) CAPTURE today's record into the JSON (persist for all future calcs)
# ---------------------------------------------------------------
if (-not $NoSave) {
    if ($todayEntries.Count -gt 0) {
        $tPnl  = [double](($todayEntries | Measure-Object -Property pnl -Sum).Sum)
        $tWin  = @($todayEntries | Where-Object { $_.pnl -gt 0 }).Count
        $tLoss = @($todayEntries | Where-Object { $_.pnl -lt 0 }).Count
        $rec = [pscustomobject]@{
            pnl     = [math]::Round($tPnl, 2)
            trades  = $todayEntries.Count
            wins    = $tWin
            losses  = $tLoss
            entries = $todayEntries
            updated = $nowIso
        }
        # Keep Kite's authoritative realised figure alongside, if available.
        if ($null -ne $posRealised) { $rec | Add-Member -NotePropertyName kiteRealised -NotePropertyValue ([math]::Round($posRealised, 2)) }
        $history[$today] = $rec

        # Re-sort by date ascending and write.
        $sorted = [ordered]@{}
        foreach ($k in ($history.Keys | Sort-Object)) { $sorted[$k] = $history[$k] }
        ($sorted | ConvertTo-Json -Depth 8) | Set-Content -Path $histPath -Encoding UTF8
        $history = $sorted
        Write-Host ("CAPTURED {0}: {1} trade(s), P&L {2:N2} -> saved to JSON" -f $today, $rec.trades, $rec.pnl) -ForegroundColor Green
    }
    else {
        Write-Host ("Nothing to capture for {0} (no F&O trades today - JSON left unchanged)." -f $today) -ForegroundColor DarkGray
    }
}
else {
    Write-Host 'Capture skipped (-NoSave).' -ForegroundColor DarkGray
}

if ($CaptureOnly) { return }

# ---------------------------------------------------------------
# 4) REPORT every stored day (source of truth = JSON)
# ---------------------------------------------------------------
if ($history.Count -eq 0) {
    Write-Host ''
    Write-Host 'No day-wise records available yet. Run on a trading day to capture.' -ForegroundColor Yellow
    return
}

$grandPnL = 0.0; $grandTrades = 0; $dayCount = 0
foreach ($day in ($history.Keys | Sort-Object)) {
    $dayCount++
    $h = $history[$day]
    if ($h.entries -and @($h.entries).Count -gt 0) {
        $rows = @($h.entries)
        $tag  = if ($day -eq $today) { '(today)' } else { '(captured)' }
        Write-DayTrades $day $rows $tag
        $grandPnL += [double](($rows | Measure-Object -Property pnl -Sum).Sum)
        $grandTrades += $rows.Count
    }
    else {
        $col = if ([double]$h.pnl -ge 0) { 'Green' } else { 'Red' }
        Write-Host ''
        Write-Host ("==== {0} (aggregate only) ====" -f $day) -ForegroundColor White
        Write-Host ("   Day total: {0:N2}   |   trades: {1}   |   W/L: {2}/{3}" -f `
                [double]$h.pnl, $h.trades, $h.wins, $h.losses) -ForegroundColor $col
        Write-Host '   (no per-trade entry/exit stored for this day)' -ForegroundColor DarkGray
        $grandPnL += [double]$h.pnl; $grandTrades += [int]$h.trades
    }
}

Write-Host ''
Write-Host '----------------------------------------------------------------'
$gcol = if ($grandPnL -ge 0) { 'Green' } else { 'Red' }
Write-Host ("GRAND TOTAL  ->  {0} day(s)  |  {1} trade(s)  |  NET F&O P&L: {2:N2}" -f $dayCount, $grandTrades, $grandPnL) -ForegroundColor $gcol
Write-Host '----------------------------------------------------------------'
