<#
.SYNOPSIS
  Detects every swing high and swing low from 09:15 to current candle using Heikin-Ashi.
.DESCRIPTION
  Fetches today's HA candles via REST API, identifies all swing highs/lows,
  and displays a table: candle-time, swing-high1, swing-low1, swing-high2, etc.
  A swing high = candle whose HA High > both neighbors.
  A swing low  = candle whose HA Low  < both neighbors.
  Refreshes every 60 seconds.
.EXAMPLE
  .\every-swing-detector.ps1
  .\every-swing-detector.ps1 -TimeFrame 5
#>

param(
    [string]$TradingSymbol,
    [int]$InstrumentToken,
    [string]$TimeFrame,
    [string]$API_Key,
    [string]$API_Secret,
    [string]$AccessToken,
    [int]$RefreshSeconds = 60
)

# ================================================================
# Module & Config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) { Write-Host '  ERROR: input.json not found.' -ForegroundColor Red; exit 1 }
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

if (-not $PSBoundParameters.ContainsKey('TradingSymbol'))  { $TradingSymbol  = $cfg.TradingSymbol }
if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
if (-not $PSBoundParameters.ContainsKey('TimeFrame'))      { $TimeFrame      = $cfg.TimeFrame }
if (-not $PSBoundParameters.ContainsKey('API_Key'))        { $API_Key        = $cfg.API_Key }
if (-not $PSBoundParameters.ContainsKey('API_Secret'))     { $API_Secret     = $cfg.API_Secret }

# Normalize TimeFrame to just the number for the API (e.g. "minute" -> "1", "5minute" -> "5")
$tfNumeric = switch ($TimeFrame) {
    'minute'   { '1' }
    '1'        { '1' }
    default    { $TimeFrame -replace 'minute','' }
}

Write-Host "  Loaded config from input.json" -ForegroundColor DarkGray

# ================================================================
# Auth
# ================================================================
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  ERROR: API_Key/API_Secret not found.' -ForegroundColor Red; exit 1
}

$tokenFile = Join-Path $scriptDir 'accesstoken.json'
if (-not $AccessToken) {
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}
$Global:common_header = $headers

# Validate token
try {
    $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
    Write-Host "  Token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
} catch {
    Write-Host '  Token invalid. Requesting new...' -ForegroundColor Red
    Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
    $Global:common_header = $headers
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
    if ($preset) { $instToken = $preset.Token; $label = $preset.Label }
    else { Write-Host "  Unknown symbol: $sym" -ForegroundColor Red; exit 1 }
}

# ================================================================
# Swing detection on HA candles
# ================================================================
function Detect-Swings {
    param([array]$candles)

    # Need at least 3 candles for a swing
    if (-not $candles -or $candles.Count -lt 3) { return @() }

    $swings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $swingCount = 0

    for ($i = 1; $i -lt ($candles.Count - 1); $i++) {
        $prev = $candles[$i - 1]
        $curr = $candles[$i]
        $next = $candles[$i + 1]

        $isSwingHigh = ($curr.High -gt $prev.High) -and ($curr.High -gt $next.High)
        $isSwingLow  = ($curr.Low -lt $prev.Low) -and ($curr.Low -lt $next.Low)

        if ($isSwingHigh -or $isSwingLow) {
            $swingCount++
            $swings.Add([PSCustomObject]@{
                Index     = $i
                Time      = $curr.TimeStamp
                Type      = if ($isSwingHigh -and $isSwingLow) { 'BOTH' } elseif ($isSwingHigh) { 'HIGH' } else { 'LOW' }
                High      = [Math]::Round($curr.High, 2)
                Low       = [Math]::Round($curr.Low, 2)
                SwingNum  = $swingCount
            })
        }
    }

    return $swings
}

# ================================================================
# Main loop — refresh every N seconds
# ================================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  EVERY SWING DETECTOR — Heikin-Ashi Swing High/Low Tracker' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym)"
Write-Host "  Token    : $instToken"
Write-Host "  TimeFrame: ${tfNumeric}min HA candles"
Write-Host "  Refresh  : Every ${RefreshSeconds}s"
Write-Host ''

while ($true) {
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $fromDate = "$today 09:15:00"

    # Fetch today's HA candles from 09:15 to now
    $haCandles = Get-HeikinAshiCandlesData -instrument_token $instToken -tradingsymbol $sym `
        -TimeFrame $tfNumeric -FromDate $fromDate -LastNCandles 500

    if (-not $haCandles -or $haCandles.Count -lt 3) {
        Write-Host "  Waiting for candles (have $($haCandles.Count))... retrying in ${RefreshSeconds}s" -ForegroundColor Yellow
        Start-Sleep -Seconds $RefreshSeconds
        continue
    }

    # Detect all swings
    $swings = Detect-Swings -candles $haCandles

    # ── Build display ──
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '  EVERY SWING DETECTOR — Heikin-Ashi Swing High/Low Tracker' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  Symbol   : $label ($sym)  |  Token: $instToken  |  TF: ${tfNumeric}min"
    Write-Host "  Candles  : $($haCandles.Count) (09:15 to now)  |  Swings Found: $($swings.Count)"
    Write-Host "  Updated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Refresh: ${RefreshSeconds}s"

    # Show current price from last candle
    $lastCandle = $haCandles[-1]
    $dayHigh = ($haCandles | Measure-Object -Property High -Maximum).Maximum
    $dayLow  = ($haCandles | Measure-Object -Property Low -Minimum).Minimum
    Write-Host "  HA Close : $([Math]::Round($lastCandle.Close, 2))  |  Day HA High: $([Math]::Round($dayHigh, 2))  |  Day HA Low: $([Math]::Round($dayLow, 2))"
    Write-Host ''

    # ── Candle table with swing markers ──
    $swingHighNum = 0
    $swingLowNum  = 0

    # Build a lookup: candle index -> swing info
    $swingMap = @{}
    foreach ($s in $swings) { $swingMap[$s.Index] = $s }

    # Table header
    $fmt = ' {0,-20} {1,12} {2,12} {3,12} {4,12} {5,6} {6,-22}'
    Write-Host ($fmt -f 'Time', 'HA Open', 'HA High', 'HA Low', 'HA Close', 'Trend', 'Swing') -ForegroundColor White
    Write-Host (' ' + ('-' * 100))

    for ($i = 0; $i -lt $haCandles.Count; $i++) {
        $c = $haCandles[$i]
        $trend = if ($c.Close -ge $c.Open) { '  UP' } else { 'DOWN' }
        $color = if ($c.Close -ge $c.Open) { 'Green' } else { 'Red' }

        # Format timestamp
        $ts = try { ([datetime]$c.TimeStamp).ToString('yyyy-MM-dd HH:mm') } catch { $c.TimeStamp.ToString().Substring(0, 16) }

        $swingLabel = ''
        if ($swingMap.ContainsKey($i)) {
            $sw = $swingMap[$i]
            if ($sw.Type -eq 'HIGH' -or $sw.Type -eq 'BOTH') {
                $swingHighNum++
                $swingLabel += "SH$swingHighNum=$([Math]::Round($sw.High, 2))"
            }
            if ($sw.Type -eq 'LOW' -or $sw.Type -eq 'BOTH') {
                $swingLowNum++
                if ($swingLabel) { $swingLabel += ' | ' }
                $swingLabel += "SL$swingLowNum=$([Math]::Round($sw.Low, 2))"
            }
        }

        $line = $fmt -f $ts, ('{0:N2}' -f $c.Open), ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), $trend, $swingLabel

        if ($i -eq ($haCandles.Count - 1)) {
            Write-Host $line -ForegroundColor Yellow  # current candle
        } elseif ($swingLabel) {
            Write-Host $line -ForegroundColor Magenta  # swing candle
        } else {
            Write-Host $line -ForegroundColor $color
        }
    }

    # ── Swing summary table ──
    if ($swings.Count -gt 0) {
        Write-Host ''
        Write-Host '  ── Swing Summary ──' -ForegroundColor Cyan

        $shIdx = 0; $slIdx = 0
        $summaryFmt = '  {0,-6} {1,-20} {2,14}'
        Write-Host ($summaryFmt -f 'Swing', 'Time', 'Price') -ForegroundColor White
        Write-Host ('  ' + ('-' * 42))

        foreach ($s in $swings) {
            $sTime = try { ([datetime]$s.Time).ToString('yyyy-MM-dd HH:mm') } catch { $s.Time.ToString().Substring(0, 16) }

            if ($s.Type -eq 'HIGH' -or $s.Type -eq 'BOTH') {
                $shIdx++
                Write-Host ($summaryFmt -f "SH$shIdx", $sTime, ('{0:N2}' -f $s.High)) -ForegroundColor Green
            }
            if ($s.Type -eq 'LOW' -or $s.Type -eq 'BOTH') {
                $slIdx++
                Write-Host ($summaryFmt -f "SL$slIdx", $sTime, ('{0:N2}' -f $s.Low)) -ForegroundColor Red
            }
        }

        # Latest swing direction indicator
        $lastSwing = $swings[-1]
        $dirColor = if ($lastSwing.Type -eq 'HIGH') { 'Green' } elseif ($lastSwing.Type -eq 'LOW') { 'Red' } else { 'Yellow' }
        Write-Host ''
        Write-Host "  Last Swing: $($lastSwing.Type) at $([Math]::Round($(if ($lastSwing.Type -eq 'HIGH') { $lastSwing.High } else { $lastSwing.Low }), 2))" -ForegroundColor $dirColor
    } else {
        Write-Host ''
        Write-Host '  No swings detected yet. Need more candles.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host "  Next refresh in ${RefreshSeconds}s... (Ctrl+C to stop)" -ForegroundColor DarkGray
    Start-Sleep -Seconds $RefreshSeconds
}
