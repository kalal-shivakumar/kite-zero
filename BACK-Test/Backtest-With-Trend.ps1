<#
.SYNOPSIS
  Backtest with Trend Detection - OHLC + Swing Levels + Trend
.DESCRIPTION
  Fetches NIFTY 1-min candles and adds:
  - SWING_LOW (previous swing low)
  - SWING_HIGH (previous swing high)
  - TREND (Uptrend/Downtrend detection)
.EXAMPLE
  .\Backtest-With-Trend.ps1
  .\Backtest-With-Trend.ps1 -Date 2026-07-23
#>

param(
    [string]$Symbol = 'NIFTY',
    [string]$Date = '2026-07-23'
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

Write-Host "`n  Fetching $Symbol - $Date...`n" -ForegroundColor Cyan
$resp = Invoke-RestMethod -Uri "https://api.kite.trade/instruments/historical/$token/minute?from=$Date&to=$Date" -Headers $headers

# Build data array first
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

# Now calculate trend detection and swing levels
# Uptrend = current close > previous high
# Downtrend = current close < previous low
# SWING_LOW: The low where current uptrend started (only updates when entering uptrend)
# SWING_HIGH: The high where current downtrend started (only updates when entering downtrend)

$data = @()
$prevCandle = $null
$trend = "NONE"
$displayTrend = "-"
$swingLow = $null
$swingHigh = $null
$prevSwingLow = $null
$prevSwingHigh = $null
$hasCompletedUptrend = $false  # Track if we've seen at least one complete uptrend cycle
$hasCompletedDowntrend = $false  # Track if we've seen at least one complete downtrend cycle

# Trade tracking variables - LOT-BASED PYRAMIDING
# Each lot is tracked separately: @{type="Long"/"Short", entry=price, SL=price, status="RUNNING"/"SL_HIT"/"CLOSED"}
$activeLots = @()
$closedLots = @()  # Track lots closed in current iteration
$allClosedPnL = @()  # Track all closed trade P&L for cumulative
$tradeStatus = "-"
$cumulativePnL = 0

for ($i = 0; $i -lt $rawData.Count; $i++) {
    $candle = $rawData[$i]
    
    if ($i -eq 0) {
        $prevCandle = $candle
        $trend = "NONE"
        $displayTrend = "-"
        $swingLow = $candle.L
        $swingHigh = $candle.H
    } else {
        $newTrend = $trend
        
        # Trend change logic (state machine)
        if ($trend -eq "NONE") {
            # From NONE, can go to Uptrend or Downtrend
            # NOTE: Do NOT save prevSwing values when entering from NONE (first trend)
            if ($candle.C -gt $prevCandle.H) {
                $newTrend = "Uptrend"
                $displayTrend = "Uptrend"
                $swingLow = $candle.L  # Set swing low when entering uptrend
            } elseif ($candle.C -lt $prevCandle.L) {
                $newTrend = "Downtrend"
                $displayTrend = "Downtrend"
                $swingHigh = $candle.H  # Set swing high when entering downtrend
            } else {
                $displayTrend = "-"
            }
        } elseif ($trend -eq "Uptrend") {
            # From Uptrend, only change to Downtrend if close < previous low
            if ($candle.C -lt $prevCandle.L) {
                $newTrend = "Downtrend"
                $displayTrend = "Downtrend"
                # Only save previous swing high if we've already seen a complete downtrend cycle
                if ($hasCompletedDowntrend) {
                    $prevSwingHigh = $swingHigh  # Save previous swing high before updating
                }
                $swingHigh = $candle.H  # Set swing high when entering downtrend
                $hasCompletedUptrend = $true  # Mark that we've seen at least one uptrend
            } else {
                $displayTrend = "-"
            }
        } elseif ($trend -eq "Downtrend") {
            # From Downtrend, only change to Uptrend if close > previous high
            if ($candle.C -gt $prevCandle.H) {
                $newTrend = "Uptrend"
                $displayTrend = "Uptrend"
                # Only save previous swing low if we've already seen a complete uptrend cycle
                if ($hasCompletedUptrend) {
                    $prevSwingLow = $swingLow  # Save previous swing low before updating
                }
                $swingLow = $candle.L  # Set swing low when entering uptrend
                $hasCompletedDowntrend = $true  # Mark that we've seen at least one downtrend
            } else {
                $displayTrend = "-"
            }
        }
        
        $trend = $newTrend
    }
    
    # Display swing levels based on trend type:
    # Uptrend: show SWING_LOW and PREVIOUS_SWING_LOW
    # Downtrend: show SWING_HIGH and PREVIOUS_SWING_HIGH
    # No trend: hide all
    $displaySwingLow = if ($displayTrend -eq "Uptrend") { [Math]::Round($swingLow, 2) } else { "-" }
    $displaySwingHigh = if ($displayTrend -eq "Downtrend") { [Math]::Round($swingHigh, 2) } else { "-" }
    $displayPrevSwingLow = if ($displayTrend -eq "Uptrend" -and $prevSwingLow -ne $null) { [Math]::Round($prevSwingLow, 2) } else { if ($displayTrend -eq "Uptrend") { "Null" } else { "-" } }
    $displayPrevSwingHigh = if ($displayTrend -eq "Downtrend" -and $prevSwingHigh -ne $null) { [Math]::Round($prevSwingHigh, 2) } else { if ($displayTrend -eq "Downtrend") { "Null" } else { "-" } }
    
    # Calculate SIGNAL
    # Long: Uptrend (displayed) + current SWING_LOW > previous SWING_LOW
    # Short: Downtrend (displayed) + current SWING_HIGH < previous SWING_HIGH
    # Signal only shows when TREND is displayed
    $signal = "-"
    if ($displayTrend -eq "Uptrend" -and $prevSwingLow -ne $null -and $swingLow -gt $prevSwingLow) {
        $signal = "Long"
    } elseif ($displayTrend -eq "Downtrend" -and $prevSwingHigh -ne $null -and $swingHigh -lt $prevSwingHigh) {
        $signal = "Short"
    }
    
    # Calculate ENTRY and STOPLOSS
    # ENTRY:
    #   Long: Current candle CLOSE
    #   Short: Previous candle LOW
    # STOPLOSS:
    #   Long: Current candle LOW
    #   Short: Current candle HIGH
    $entry = "-"
    $stoploss = "-"
    
    if ($signal -eq "Long") {
        $entry = [Math]::Round($candle.C, 2)
        $stoploss = [Math]::Round($candle.L, 2)
    } elseif ($signal -eq "Short") {
        $entry = [Math]::Round($prevCandle.L, 2)
        $stoploss = [Math]::Round($candle.H, 2)
    }
    
    # Trade Status Logic - LOT-BASED PYRAMIDING
    # 1. Check if any active lots hit stoploss
    # 2. Calculate P&L for lots that will be closed via opposite signal
    # 3. Check if opposite signal closes all lots of that type
    # 4. If new signal, add new lot (pyramiding)
    # 5. Build status string with closed position info + new position info
    
    $justClosedShorts = 0
    $justClosedLongs = 0
    $closedLongsPnL = 0
    $closedShortsPnL = 0
    $slTriggeredLongsPnL = 0
    $slTriggeredShortsPnL = 0
    
    # First: Check SL triggers on active lots & calculate P&L
    foreach ($lot in $activeLots) {
        $slHit = $false
        if ($lot.type -eq "Long" -and $candle.L -le $lot.SL) {
            $slHit = $true
        } elseif ($lot.type -eq "Short" -and $candle.H -ge $lot.SL) {
            $slHit = $true
        }
        
        if ($slHit) {
            $lot.status = "SL_HIT"
            # Calculate P&L for SL_HIT
            if ($lot.type -eq "Long") {
                $slPnL = [Math]::Round($candle.C - $lot.entry, 2)
                $slTriggeredLongsPnL += $slPnL
                $cumulativePnL += $slPnL
            } else {
                $slPnL = [Math]::Round($lot.entry - $candle.C, 2)
                $slTriggeredShortsPnL += $slPnL
                $cumulativePnL += $slPnL
            }
        }
    }
    
    # Second: Check if opposite signal closes all active lots & calculate P&L
    if ($signal -ne "-") {
        if ($signal -eq "Long") {
            # Close all SHORT lots via CLOSED_SIGNAL
            foreach ($lot in $activeLots) {
                if ($lot.type -eq "Short") {
                    # Calculate P&L for SHORT: entry - close
                    $shortPnL = [Math]::Round($lot.entry - $candle.C, 2)
                    $closedShortsPnL += $shortPnL
                    $cumulativePnL += $shortPnL
                    $lot.status = "CLOSED_SIGNAL"
                    $justClosedShorts++
                }
            }
        } elseif ($signal -eq "Short") {
            # Close all LONG lots via CLOSED_SIGNAL
            foreach ($lot in $activeLots) {
                if ($lot.type -eq "Long") {
                    # Calculate P&L for LONG: close - entry
                    $longPnL = [Math]::Round($candle.C - $lot.entry, 2)
                    $closedLongsPnL += $longPnL
                    $cumulativePnL += $longPnL
                    $lot.status = "CLOSED_SIGNAL"
                    $justClosedLongs++
                }
            }
        }
    }
    
    # Third: Remove CLOSED_SIGNAL and SL_HIT lots (they should not appear in next iterations)
    $activeLots = @($activeLots | Where-Object { $_.status -eq "RUNNING" })
    
    # Fourth: If new signal, add new lot (pyramiding if same type already exists)
    if ($signal -eq "Long") {
        $newLot = [PSCustomObject]@{type="Long"; entry=[Math]::Round($entry, 2); SL=[Math]::Round($stoploss, 2); status="RUNNING"}
        $activeLots = @($activeLots) + @($newLot)
    } elseif ($signal -eq "Short") {
        $newLot = [PSCustomObject]@{type="Short"; entry=[Math]::Round($entry, 2); SL=[Math]::Round($stoploss, 2); status="RUNNING"}
        $activeLots = @($activeLots) + @($newLot)
    }
    
    # Fifth: Build TRADE_STATUS string with closed position info + new position info
    $runningLongs = @($activeLots | Where-Object { $_.status -eq "RUNNING" -and $_.type -eq "Long" })
    $runningShorts = @($activeLots | Where-Object { $_.status -eq "RUNNING" -and $_.type -eq "Short" })
    $slHitLongs = @($activeLots | Where-Object { $_.status -eq "SL_HIT" -and $_.type -eq "Long" })
    $slHitShorts = @($activeLots | Where-Object { $_.status -eq "SL_HIT" -and $_.type -eq "Short" })
    
    $tradeStatus = "-"
    $currentClose = $candle.C
    
    # Build status with closed positions info + running/SL_HIT positions info
    $statusParts = @()
    
    # Add closed position info if applicable
    if ($justClosedLongs -gt 0) {
        $closedPnLStr = if ($closedLongsPnL -ge 0) { "+$closedLongsPnL" } else { "$closedLongsPnL" }
        $statusParts += "Long profit booked $($closedPnLStr)pts"
    }
    if ($justClosedShorts -gt 0) {
        $closedPnLStr = if ($closedShortsPnL -ge 0) { "+$closedShortsPnL" } else { "$closedShortsPnL" }
        $statusParts += "Short profit booked $($closedPnLStr)pts"
    }
    
    # Add running LONG lots info
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
    
    # Add SL_HIT LONG lots info
    if ($slHitLongs.Count -gt 0) {
        $slDetails = @()
        $longCounter = $runningLongs.Count
        for ($j = 0; $j -lt $slHitLongs.Count; $j++) {
            $longCounter++
            # Calculate P&L at SL point
            $slPnL = [Math]::Round($candle.C - $slHitLongs[$j].entry, 2)
            $slPnLStr = if ($slPnL -ge 0) { "+$slPnL" } else { "$slPnL" }
            $slDetails += "long$($longCounter)=[$slPnLStr]pts"
        }
        $slDisplay = $slDetails -join " + "
        $statusParts += "$($slHitLongs.Count) lot Long stoploss triggered ($slDisplay)"
    }
    
    # Add running SHORT lots info
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
    
    # Add SL_HIT SHORT lots info
    if ($slHitShorts.Count -gt 0) {
        $slDetails = @()
        $shortCounter = $runningShorts.Count
        for ($j = 0; $j -lt $slHitShorts.Count; $j++) {
            $shortCounter++
            # Calculate P&L at SL point
            $slPnL = [Math]::Round($slHitShorts[$j].entry - $candle.C, 2)
            $slPnLStr = if ($slPnL -ge 0) { "+$slPnL" } else { "$slPnL" }
            $slDetails += "short$($shortCounter)=[$slPnLStr]pts"
        }
        $slDisplay = $slDetails -join " + "
        $statusParts += "$($slHitShorts.Count) lot Short stoploss triggered ($slDisplay)"
    }
    
    # Join all status parts
    if ($statusParts.Count -gt 0) {
        $tradeStatus = $statusParts -join " | "
    }
    
    # Create object with all columns
    $data += [PSCustomObject]@{
        "#" = $i + 1
        "TIME" = $candle.TIME
        "O" = $candle.O
        "H" = $candle.H
        "L" = $candle.L
        "C" = $candle.C
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
Write-Host "  📊 OHLC with SWING LEVELS & TREND:" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────────────────────────────────" -ForegroundColor Gray
$data | Format-Table -AutoSize | Out-Host

Write-Host ""
Write-Host "  Total: $($data.Count) candles" -ForegroundColor Green

# Export to CSV
$resultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "BACK-Test\Results-csv"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$csvPath = Join-Path $resultsDir "backtest-$Symbol-$Date-$timestamp.csv"
$data | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "  ✓ CSV exported: $csvPath`n" -ForegroundColor Green
