<#
.SYNOPSIS
  Backtest with Trend Detection using Heikin Ashi - HA OHLC + Swing Levels + Trend + Pyramiding

.DESCRIPTION
  Fetches NIFTY 1-min candles, calculates Heikin Ashi values, detects trends using swing levels,
  generates Long/Short signals, and tracks pyramided lots with individual and cumulative P&L.

  TREND DETECTION (Using Heikin Ashi Close):
  ├─ INITIAL STATE (NONE):
  │  ├─ If HA_Close > Previous HA_High  → Switch to UPTREND
  │  └─ If HA_Close < Previous HA_Low   → Switch to DOWNTREND
  ├─ IN UPTREND:
  │  ├─ Remains UPTREND while HA_Close > Previous HA_Low
  │  └─ If HA_Close < Previous HA_Low   → Switch to DOWNTREND
  └─ IN DOWNTREND:
     ├─ Remains DOWNTREND while HA_Close < Previous HA_High
     └─ If HA_Close > Previous HA_High  → Switch to UPTREND

  LONG SIGNAL GENERATION (First Trade + Pyramiding):
  ├─ FIRST TRADE: Trend = UPTREND AND PREV_SWING_LOW = Null
  └─ PYRAMIDING: Trend = UPTREND AND Current Swing Low > Previous Swing Low (HIGHER LOWS)
  
  Entry Price: Current Heikin Ashi Close
  Stoploss: Current Heikin Ashi Low

  SHORT SIGNAL GENERATION (First Trade + Pyramiding):
  ├─ FIRST TRADE: Trend = DOWNTREND AND PREV_SWING_HIGH = Null
  └─ PYRAMIDING: Trend = DOWNTREND AND Current Swing High < Previous Swing High (LOWER HIGHS)
  
  Entry Price: Previous Heikin Ashi Low
  Stoploss: Current Heikin Ashi High

  TRADE MANAGEMENT & PYRAMIDING:
  ├─ SIGNAL CHANGE: When opposite signal appears, ALL active positions of opposite type close
  ├─ STOPLOSS HIT: Individual lot closes when HA_Low <= Long_SL or HA_High >= Short_SL
  ├─ PYRAMIDING: Same signal can generate multiple lots (stacked positions)
  └─ P&L TRACKING: Each lot tracked individually + cumulative running P&L

  OUTPUT COLUMNS:
  - HA_O, HA_H, HA_L, HA_C: Heikin Ashi OHLC values
  - SWING_LOW/HIGH: Current swing extremes (relative to trend)
  - PREV_SWING_LOW/HIGH: Previous swing extremes (for comparison)
  - TREND: Current trend (Uptrend/Downtrend/-)
  - SIGNAL: Trade signal (Long/Short/-)
  - ENTRY: Entry price for new signal
  - STOPLOSS: Stoploss price for new signal
  - TRADE_STATUS: Real-time position tracking with lot-by-lot P&L
  - CUMULATIVE_PNL: Running total P&L

.EXAMPLE
  .\Backtest-Pyramid-With-Trend-HeikinAshi.ps1
  .\Backtest-Pyramid-With-Trend-HeikinAshi.ps1 -Date 2026-07-24
  .\Backtest-Pyramid-With-Trend-HeikinAshi.ps1 -Symbol BANKNIFTY -Date 2026-07-24
#>

param(
    [string]$Symbol = 'NIFTY',
    [string]$Date = '2026-07-27'
)

$ErrorActionPreference = 'Continue'

# Load config
$cfg = Get-Content "..\input.json" -Raw | ConvertFrom-Json
$token = Get-Content "..\accesstoken.json" -Raw | ConvertFrom-Json
$headers = @{
    'X-Kite-Version' = '3'
    'Authorization' = "token $($cfg.API_Key):$($token.access_token)"
}

# Symbol mapping
$symbols = @{ "NIFTY" = 256265; "BANKNIFTY" = 260105; "SENSEX" = 265 }
$token = $symbols[$Symbol]

Write-Host "`n  Fetching $Symbol - $Date (Heikin Ashi)...`n" -ForegroundColor Cyan
$resp = Invoke-RestMethod -Uri "https://api.kite.trade/instruments/historical/$token/minute?from=$Date&to=$Date" -Headers $headers

# Build raw data array first
$rawData = @()
$resp.data.candles | ForEach-Object {
    $rawData += [PSCustomObject]@{
        TIME = $_[0]
        O = [Math]::Round([double]$_[1], 2)
        H = [Math]::Round([double]$_[2], 2)
        L = [Math]::Round([double]$_[3], 2)
        C = [Math]::Round([double]$_[4], 2)
    }
}

# Calculate Heikin Ashi candles
$haData = @()
$prevHAOpen = $null
$prevHAClose = $null

$rawData | ForEach-Object {
    $candle = $_
    
    # HA_Close = (O + H + L + C) / 4
    $haClose = [Math]::Round(($candle.O + $candle.H + $candle.L + $candle.C) / 4, 2)
    
    # HA_Open = (Previous HA_Open + Previous HA_Close) / 2
    # For first candle: (O + C) / 2
    if ($prevHAOpen -eq $null) {
        $haOpen = [Math]::Round(($candle.O + $candle.C) / 2, 2)
    } else {
        $haOpen = [Math]::Round(($prevHAOpen + $prevHAClose) / 2, 2)
    }
    
    # HA_High = MAX(H, HA_Open, HA_Close)
    $haHigh = [Math]::Round([Math]::Max([Math]::Max($candle.H, $haOpen), $haClose), 2)
    
    # HA_Low = MIN(L, HA_Open, HA_Close)
    $haLow = [Math]::Round([Math]::Min([Math]::Min($candle.L, $haOpen), $haClose), 2)
    
    $haData += [PSCustomObject]@{
        TIME = $candle.TIME
        O = $candle.O
        H = $candle.H
        L = $candle.L
        C = $candle.C
        HA_O = $haOpen
        HA_H = $haHigh
        HA_L = $haLow
        HA_C = $haClose
    }
    
    $prevHAOpen = $haOpen
    $prevHAClose = $haClose
}

# Now calculate trend detection and swing levels using HA candles
$data = @()
$prevCandle = $null
$trend = "NONE"
$displayTrend = "-"
$swingLow = $null
$swingHigh = $null
$prevSwingLow = $null
$prevSwingHigh = $null
$hasCompletedUptrend = $false
$hasCompletedDowntrend = $false

# Trade tracking variables - LOT-BASED PYRAMIDING
$activeLots = @()
$closedLots = @()
$allClosedPnL = @()
$tradeStatus = "-"
$cumulativePnL = 0

# TIME FILTER: Only process candles between 9:16 and 11:00
$timeStart = [TimeSpan]"09:16:00"
$timeEnd = [TimeSpan]"11:00:00"

for ($i = 0; $i -lt $haData.Count; $i++) {
    $candle = $haData[$i]
    
    # Parse time and filter
    $candleTime = $candle.TIME.TimeOfDay
    if ($candleTime -lt $timeStart -or $candleTime -gt $timeEnd) {
        continue
    }
    
    if ($i -eq 0) {
        $prevCandle = $candle
        $trend = "NONE"
        $displayTrend = "-"
        $swingLow = $candle.HA_L
        $swingHigh = $candle.HA_H
    } else {
        $newTrend = $trend
        
        # Trend change logic using HA Close and HA values
        if ($trend -eq "NONE") {
            if ($candle.HA_C -gt $prevCandle.HA_H) {
                $newTrend = "Uptrend"
                $displayTrend = "Uptrend"
                $swingLow = $candle.HA_L
            } elseif ($candle.HA_C -lt $prevCandle.HA_L) {
                $newTrend = "Downtrend"
                $displayTrend = "Downtrend"
                $swingHigh = $candle.HA_H
            } else {
                $displayTrend = "-"
            }
        } elseif ($trend -eq "Uptrend") {
            if ($candle.HA_C -lt $prevCandle.HA_L) {
                $newTrend = "Downtrend"
                $displayTrend = "Downtrend"
                if ($hasCompletedDowntrend) {
                    $prevSwingHigh = $swingHigh
                }
                $swingHigh = $candle.HA_H
                $hasCompletedUptrend = $true
            } else {
                $displayTrend = "-"
            }
        } elseif ($trend -eq "Downtrend") {
            if ($candle.HA_C -gt $prevCandle.HA_H) {
                $newTrend = "Uptrend"
                $displayTrend = "Uptrend"
                if ($hasCompletedUptrend) {
                    $prevSwingLow = $swingLow
                }
                $swingLow = $candle.HA_L
                $hasCompletedDowntrend = $true
            } else {
                $displayTrend = "-"
            }
        }
        
        $trend = $newTrend
    }
    
    # Display swing levels based on trend type
    $displaySwingLow = if ($displayTrend -eq "Uptrend") { [Math]::Round($swingLow, 2) } else { "-" }
    $displaySwingHigh = if ($displayTrend -eq "Downtrend") { [Math]::Round($swingHigh, 2) } else { "-" }
    $displayPrevSwingLow = if ($displayTrend -eq "Uptrend" -and $prevSwingLow -ne $null) { [Math]::Round($prevSwingLow, 2) } else { if ($displayTrend -eq "Uptrend") { "Null" } else { "-" } }
    $displayPrevSwingHigh = if ($displayTrend -eq "Downtrend" -and $prevSwingHigh -ne $null) { [Math]::Round($prevSwingHigh, 2) } else { if ($displayTrend -eq "Downtrend") { "Null" } else { "-" } }
    
    # Calculate SIGNAL using swing levels
    # LONG: Uptrend + (First trade with Null prevSwingLow OR pyramiding with Higher Lows)
    # SHORT: Downtrend + (First trade with Null prevSwingHigh OR pyramiding with Lower Highs)
    $signal = "-"
    if ($displayTrend -eq "Uptrend") {
        if ($prevSwingLow -eq $null -or $swingLow -gt $prevSwingLow) {
            $signal = "Long"
        }
    } elseif ($displayTrend -eq "Downtrend") {
        if ($prevSwingHigh -eq $null -or $swingHigh -lt $prevSwingHigh) {
            $signal = "Short"
        }
    }
    
    # Calculate ENTRY and STOPLOSS using HA Close (for entry) and HA extremes (for SL)
    $entry = "-"
    $stoploss = "-"
    
    if ($signal -eq "Long") {
        $entry = [Math]::Round($candle.HA_C, 2)
        $stoploss = [Math]::Round($candle.HA_L, 2)
    } elseif ($signal -eq "Short") {
        $entry = [Math]::Round($prevCandle.HA_L, 2)
        $stoploss = [Math]::Round($candle.HA_H, 2)
    }
    
    # Trade Status Logic - LOT-BASED PYRAMIDING
    $justClosedShorts = 0
    $justClosedLongs = 0
    $closedLongsPnL = 0
    $closedShortsPnL = 0
    $slTriggeredLongsPnL = 0
    $slTriggeredShortsPnL = 0
    
    # First: Check SL triggers on active lots & calculate P&L
    foreach ($lot in $activeLots) {
        $slHit = $false
        if ($lot.type -eq "Long" -and $candle.HA_L -le $lot.SL) {
            $slHit = $true
        } elseif ($lot.type -eq "Short" -and $candle.HA_H -ge $lot.SL) {
            $slHit = $true
        }
        
        if ($slHit) {
            $lot.status = "SL_HIT"
            # Calculate P&L for SL_HIT
            if ($lot.type -eq "Long") {
                $slPnL = [Math]::Round($candle.HA_C - $lot.entry, 2)
                $slTriggeredLongsPnL += $slPnL
                $cumulativePnL += $slPnL
            } else {
                $slPnL = [Math]::Round($lot.entry - $candle.HA_C, 2)
                $slTriggeredShortsPnL += $slPnL
                $cumulativePnL += $slPnL
            }
        }
    }
    
    # Second: Check if opposite signal closes all active lots & calculate P&L
    if ($signal -ne "-") {
        if ($signal -eq "Long") {
            foreach ($lot in $activeLots) {
                if ($lot.type -eq "Short") {
                    $shortPnL = [Math]::Round($lot.entry - $candle.HA_C, 2)
                    $closedShortsPnL += $shortPnL
                    $cumulativePnL += $shortPnL
                    $lot.status = "CLOSED_SIGNAL"
                    $justClosedShorts++
                }
            }
        } elseif ($signal -eq "Short") {
            foreach ($lot in $activeLots) {
                if ($lot.type -eq "Long") {
                    $longPnL = [Math]::Round($candle.HA_C - $lot.entry, 2)
                    $closedLongsPnL += $longPnL
                    $cumulativePnL += $longPnL
                    $lot.status = "CLOSED_SIGNAL"
                    $justClosedLongs++
                }
            }
        }
    }
    
    # Third: Remove CLOSED_SIGNAL and SL_HIT lots
    $activeLots = @($activeLots | Where-Object { $_.status -eq "RUNNING" })
    
    # Fourth: If new signal, add new lot (pyramiding)
    if ($signal -eq "Long") {
        $newLot = [PSCustomObject]@{type="Long"; entry=[Math]::Round($entry, 2); SL=[Math]::Round($stoploss, 2); status="RUNNING"}
        $activeLots = @($activeLots) + @($newLot)
    } elseif ($signal -eq "Short") {
        $newLot = [PSCustomObject]@{type="Short"; entry=[Math]::Round($entry, 2); SL=[Math]::Round($stoploss, 2); status="RUNNING"}
        $activeLots = @($activeLots) + @($newLot)
    }
    
    # Fifth: Build TRADE_STATUS string
    $runningLongs = @($activeLots | Where-Object { $_.status -eq "RUNNING" -and $_.type -eq "Long" })
    $runningShorts = @($activeLots | Where-Object { $_.status -eq "RUNNING" -and $_.type -eq "Short" })
    $slHitLongs = @($activeLots | Where-Object { $_.status -eq "SL_HIT" -and $_.type -eq "Long" })
    $slHitShorts = @($activeLots | Where-Object { $_.status -eq "SL_HIT" -and $_.type -eq "Short" })
    
    $tradeStatus = "-"
    $currentClose = $candle.HA_C
    
    $statusParts = @()
    
    if ($justClosedLongs -gt 0) {
        $closedPnLStr = if ($closedLongsPnL -ge 0) { "+$closedLongsPnL" } else { "$closedLongsPnL" }
        $statusParts += "Long profit booked $($closedPnLStr)pts"
    }
    if ($justClosedShorts -gt 0) {
        $closedPnLStr = if ($closedShortsPnL -ge 0) { "+$closedShortsPnL" } else { "$closedShortsPnL" }
        $statusParts += "Short profit booked $($closedPnLStr)pts"
    }
    
    if ($runningLongs.Count -gt 0) {
        $pnlDetails = @()
        for ($j = 0; $j -lt $runningLongs.Count; $j++) {
            $pnl = [Math]::Round($currentClose - $runningLongs[$j].entry, 2)
            $pnlStr = if ($pnl -ge 0) { "+$pnl" } else { "$pnl" }
            $pnlDetails += "long$($j+1)=$($pnlStr)pts"
        }
        $pnlDisplay = $pnlDetails -join " + "
        $statusParts += "$($runningLongs.Count) lots Long running ($pnlDisplay)"
    }
    
    if ($slHitLongs.Count -gt 0) {
        $slDetails = @()
        $longCounter = $runningLongs.Count
        for ($j = 0; $j -lt $slHitLongs.Count; $j++) {
            $longCounter++
            $slPnL = [Math]::Round($candle.HA_C - $slHitLongs[$j].entry, 2)
            $slPnLStr = if ($slPnL -ge 0) { "+$slPnL" } else { "$slPnL" }
            $slDetails += "long$($longCounter)=[$slPnLStr]pts"
        }
        $slDisplay = $slDetails -join " + "
        $statusParts += "$($slHitLongs.Count) lot Long stoploss triggered ($slDisplay)"
    }
    
    if ($runningShorts.Count -gt 0) {
        $pnlDetails = @()
        for ($j = 0; $j -lt $runningShorts.Count; $j++) {
            $pnl = [Math]::Round($runningShorts[$j].entry - $currentClose, 2)
            $pnlStr = if ($pnl -ge 0) { "+$pnl" } else { "$pnl" }
            $pnlDetails += "short$($j+1)=$($pnlStr)pts"
        }
        $pnlDisplay = $pnlDetails -join " + "
        $statusParts += "$($runningShorts.Count) lots Short running ($pnlDisplay)"
    }
    
    if ($slHitShorts.Count -gt 0) {
        $slDetails = @()
        $shortCounter = $runningShorts.Count
        for ($j = 0; $j -lt $slHitShorts.Count; $j++) {
            $shortCounter++
            $slPnL = [Math]::Round($slHitShorts[$j].entry - $candle.HA_C, 2)
            $slPnLStr = if ($slPnL -ge 0) { "+$slPnL" } else { "$slPnL" }
            $slDetails += "short$($shortCounter)=[$slPnLStr]pts"
        }
        $slDisplay = $slDetails -join " + "
        $statusParts += "$($slHitShorts.Count) lot Short stoploss triggered ($slDisplay)"
    }
    
    if ($statusParts.Count -gt 0) {
        $tradeStatus = $statusParts -join " | "
    }
    
    # Create output object with HA values and regular OHLC for reference
    $data += [PSCustomObject]@{
        "#" = $i + 1
        "TIME" = $candle.TIME
        "O" = $candle.O
        "H" = $candle.H
        "L" = $candle.L
        "C" = $candle.C
        "HA_O" = $candle.HA_O
        "HA_H" = $candle.HA_H
        "HA_L" = $candle.HA_L
        "HA_C" = $candle.HA_C
        "SWING_LOW" = $displaySwingLow
        "SWING_HIGH" = $displaySwingHigh
        "PREV_SWING_LOW" = $displayPrevSwingLow
        "PREV_SWING_HIGH" = $displayPrevSwingHigh
        "TREND" = $displayTrend
        "SIGNAL" = $signal
        "ENTRY" = $entry
        "STOPLOSS" = $stoploss
        "TRADE_STATUS" = $tradeStatus
        "CUMULATIVE_PNL" = $cumulativePnL
    }
    
    $prevCandle = $candle
}

# Display
Write-Host "  📊 HEIKIN ASHI OHLC with SWING LEVELS & TREND:" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────────────────────────────────" -ForegroundColor Gray
$data | Format-Table -AutoSize | Out-Host

Write-Host ""
Write-Host "  Total: $($data.Count) candles" -ForegroundColor Green

# Export to CSV
$resultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "BACK-Test\Results-csv"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$csvPath = Join-Path $resultsDir "backtest-$Symbol-HA-$Date-$timestamp.csv"
$data | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "  ✓ CSV exported: $csvPath`n" -ForegroundColor Green
