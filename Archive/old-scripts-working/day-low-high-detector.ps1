<#
.SYNOPSIS
  Detects when price touches the day's low or high via Kite WebSocket.
.DESCRIPTION
  Streams live ticks and monitors DayLow / DayHigh from exchange data.
  Each time the LTP touches the day's low or high, creates a timestamped
  file inside the DayLowDetectedFiles directory.
.EXAMPLE
  .\day-low-high-detector.ps1
  .\day-low-high-detector.ps1 -TradingSymbol BANKNIFTY
#>

param(
    [string]$TradingSymbol,
    [int]$InstrumentToken,
    [switch]$FullMode,
    [switch]$ListSymbols,
    [switch]$GetLoginUrl,
    [string]$RequestToken,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret,
    [datetime]$StopTime
)

# ================================================================
# Module & Config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) {
    Write-Host '  ERROR: input.json not found.' -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

if (-not $PSBoundParameters.ContainsKey('TradingSymbol'))  { $TradingSymbol  = $cfg.TradingSymbol }
if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
if (-not $PSBoundParameters.ContainsKey('FullMode')  -and $cfg.FullMode)  { $FullMode  = [switch]$true }
if (-not $PSBoundParameters.ContainsKey('API_Key'))        { $API_Key        = $cfg.API_Key }
if (-not $PSBoundParameters.ContainsKey('API_Secret'))     { $API_Secret     = $cfg.API_Secret }
if (-not $PSBoundParameters.ContainsKey('StopTime'))       { $StopTime       = [datetime]$cfg.StopTime }
Write-Host "  Loaded config from input.json" -ForegroundColor DarkGray

# ================================================================
# Auth
# ================================================================
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  ERROR: API_Key/API_Secret not found. Check input.json.' -ForegroundColor Red
    exit 1
}

if ($GetLoginUrl) {
    $url = 'https://kite.zerodha.com/connect/login?api_key=' + $API_Key
    Write-Host "  Login URL: $url" -ForegroundColor White
    try { Start-Process $url } catch {}
    exit 0
}

if ($ListSymbols) { Show-KiteSymbols; exit 0 }

$tokenFile = Join-Path $scriptDir 'accesstoken.json'
if (-not $AccessToken) {
    if ($RequestToken) {
        $AccessToken = Exchange-KiteRequestToken -ApiKey $API_Key -ApiSecret $API_Secret -ReqToken $RequestToken -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    } else {
        $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
    }
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

$tokenValid = $false
try {
    $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
    if ($profile.data -and $profile.data.user_id) {
        $tokenValid = $true
        Write-Host "  Token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    }
} catch {
    Write-Host "  Token validation failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $tokenValid) {
    Write-Host '  Access token is INVALID or EXPIRED. Requesting new token...' -ForegroundColor Red
    Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  Login failed. Exiting.' -ForegroundColor Red; exit 1 }
    $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
    try {
        $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
        Write-Host "  New token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: New token also failed. Check API credentials." -ForegroundColor Red
        exit 1
    }
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
# Output directory
# ================================================================
$outputDir = Join-Path $scriptDir 'DayLowDetectedFiles'
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# ================================================================
# Tracking state
# ================================================================
$script:TickCount    = 0
$script:DayLow      = [double]::MaxValue
$script:DayHigh     = 0
$script:LTP         = 0
$script:LowTouches  = 0
$script:HighTouches = 0
$script:LastLowTouch  = ''
$script:LastHighTouch = ''
$script:LastDisplayTime = [datetime]::MinValue

# ================================================================
# WebSocket — stream ticks and detect day low/high touches
# ================================================================
$wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  Day Low / High Detector' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host "  Symbol   : $label ($sym)"
Write-Host "  Token    : $instToken"
Write-Host "  Mode     : $modeStr"
Write-Host "  Output   : $outputDir"
Write-Host "  StopTime : $($StopTime.ToString('HH:mm:ss'))"
Write-Host ''
Write-Host '  Connecting...' -ForegroundColor Yellow

$maxRetries = 3
$retryCount = 0
$buf = New-Object byte[] 65536

while ($retryCount -le $maxRetries) {
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader('X-Kite-Version', '3')
    $cts = [System.Threading.CancellationTokenSource]::new()

    try {
        $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
        if (-not $ct.Wait(15000)) {
            Write-Host '  Connection timed out.' -ForegroundColor Red
            $retryCount++
            if ($retryCount -le $maxRetries) {
                $wait = $retryCount * 5
                Write-Host "  Retrying in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                continue
            }
            exit 1
        }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host "  Connection failed. State: $($ws.State)" -ForegroundColor Red
            exit 1
        }

        $retryCount = 0
        Write-Host '  Connected!' -ForegroundColor Green

        $subB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"subscribe","v":[' + $instToken + ']}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($subB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        Write-Host "  Subscribed to $label" -ForegroundColor Green

        $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["' + $modeStr + '",[' + $instToken + ']]}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        Write-Host "  Mode: $modeStr" -ForegroundColor Green
        Write-Host ''
        Write-Host '  Waiting for market ticks...' -ForegroundColor Yellow

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            # Check stop time
            if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay) {
                Write-Host "  Stop time reached. Exiting." -ForegroundColor Yellow
                break
            }

            $seg = [System.ArraySegment[byte]]::new($buf)
            try {
                $rt = $ws.ReceiveAsync($seg, $cts.Token)
                if (-not $rt.Wait(30000)) { continue }
                $res = $rt.Result
            } catch {
                if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
                continue
            }

            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                Write-Host '  Server closed connection.' -ForegroundColor Yellow; break
            }
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                if ($res.Count -gt 1) {
                    $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
                    try { $jm = $txt | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($jm.type -eq 'error') { Write-Host "  ERROR: $($jm.data)" -ForegroundColor Red } } catch {}
                }
                continue
            }
            if (($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) -and ($res.Count -gt 2)) {
                $ticks = Parse-KiteTicks $buf $res.Count
                foreach ($tick in $ticks) {
                    if ($tick.LastPrice -le 0) { continue }
                    $script:TickCount++
                    $script:LTP = $tick.LastPrice
                    $now = Get-Date
                    $ts  = $now.ToString('yyyy-MM-dd_HH-mm-ss-fff')

                    # Update day low/high from exchange data
                    if ($tick.DayLow -gt 0)  { $script:DayLow  = $tick.DayLow }
                    if ($tick.DayHigh -gt 0) { $script:DayHigh = $tick.DayHigh }

                    # ── Day Low touched ──
                    if ($script:DayLow -gt 0 -and $tick.LastPrice -le $script:DayLow) {
                        $script:LowTouches++
                        $script:LastLowTouch = $now.ToString('HH:mm:ss.fff')
                        $fileContent = "Day Low Touched!`nSymbol: $label`nLTP: $($tick.LastPrice)`nDay Low: $($script:DayLow)`nDay High: $($script:DayHigh)`nTime: $($now.ToString('yyyy-MM-dd HH:mm:ss.fff'))`nTouch #$($script:LowTouches)"
                        $filePath = Join-Path $outputDir "day-low-touched.txt"
                        $fileContent | Set-Content -Path $filePath -Force
                        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] *** DAY LOW TOUCHED *** LTP: $($tick.LastPrice) = DayLow: $($script:DayLow) | Touch #$($script:LowTouches) | File: day-low-touched.txt" -ForegroundColor Red
                    }

                    # ── Day High touched ──
                    if ($script:DayHigh -gt 0 -and $tick.LastPrice -ge $script:DayHigh) {
                        $script:HighTouches++
                        $script:LastHighTouch = $now.ToString('HH:mm:ss.fff')
                        $fileContent = "Day High Touched!`nSymbol: $label`nLTP: $($tick.LastPrice)`nDay High: $($script:DayHigh)`nDay Low: $($script:DayLow)`nTime: $($now.ToString('yyyy-MM-dd HH:mm:ss.fff'))`nTouch #$($script:HighTouches)"
                        $filePath = Join-Path $outputDir "day-high-touched.txt"
                        $fileContent | Set-Content -Path $filePath -Force
                        Write-Host "  [$($now.ToString('HH:mm:ss.fff'))] *** DAY HIGH TOUCHED *** LTP: $($tick.LastPrice) = DayHigh: $($script:DayHigh) | Touch #$($script:HighTouches) | File: day-high-touched.txt" -ForegroundColor Green
                    }
                }

                # ── Display (throttled to 500ms) ──
                $now = [datetime]::Now
                if (($now - $script:LastDisplayTime).TotalMilliseconds -ge 500) {
                    $script:LastDisplayTime = $now
                    Clear-Host
                    Write-Host ''
                    Write-Host '  ============================================================' -ForegroundColor Cyan
                    Write-Host '  Day Low / High Detector' -ForegroundColor Cyan
                    Write-Host '  ============================================================' -ForegroundColor Cyan
                    Write-Host "  Symbol   : $label  |  Token: $instToken  |  Mode: $modeStr"
                    Write-Host "  Time     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')"
                    Write-Host "  Ticks    : $($script:TickCount)"
                    Write-Host ''
                    Write-Host "  LTP      : $($script:LTP.ToString('N2'))" -ForegroundColor White
                    $lowColor = if ($script:LTP -le $script:DayLow) { 'Red' } else { 'Yellow' }
                    $highColor = if ($script:LTP -ge $script:DayHigh) { 'Green' } else { 'Yellow' }
                    Write-Host "  Day Low  : $($script:DayLow.ToString('N2'))  |  Touches: $($script:LowTouches)  |  Last: $($script:LastLowTouch)" -ForegroundColor $lowColor
                    Write-Host "  Day High : $($script:DayHigh.ToString('N2'))  |  Touches: $($script:HighTouches)  |  Last: $($script:LastHighTouch)" -ForegroundColor $highColor
                    Write-Host "  Range    : $( ($script:DayHigh - $script:DayLow).ToString('N2') ) pts" -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
                }
            }
        }

        # If stop time triggered the break, exit cleanly
        if ((Get-Date).TimeOfDay -gt $StopTime.TimeOfDay) { break }

        $retryCount++
        if ($retryCount -le $maxRetries) {
            $wait = $retryCount * 5
            Write-Host "  Connection lost. Reconnecting in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) { Write-Host "  Detail: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
        $retryCount++
        if ($retryCount -le $maxRetries) {
            $wait = $retryCount * 5
            Write-Host "  Retrying in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    finally {
        if ($ws -and ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open)) {
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done', $cts.Token).Wait(5000) } catch {}
        }
        if ($ws)  { $ws.Dispose() }
        if ($cts) { $cts.Dispose() }
    }
}

Write-Host ''
Write-Host '  Disconnected.' -ForegroundColor Yellow
Write-Host "  Total Low Touches : $($script:LowTouches)" -ForegroundColor Red
Write-Host "  Total High Touches: $($script:HighTouches)" -ForegroundColor Green
Write-Host ''
