<#
.SYNOPSIS
  Combined live dashboard: Heikin Ashi candles + Option Chain candidates + Open Positions.
.DESCRIPTION
  Connects to Kite WebSocket for live HA candles, reads OptionChaindata.csv and
  CE-Positions.csv / PE-Positions.csv to display a unified live trading dashboard.
.EXAMPLE
  .\LiveDashboard.ps1
  .\LiveDashboard.ps1 -TradingSymbol BANKNIFTY -TimeFrame 3minute
#>

param(
    [string]$TradingSymbol,
    [int]$InstrumentToken,
    [ValidateSet('5second','15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame,
    [int]$CandlesToShow,
    [switch]$FullMode,
    [switch]$ListSymbols,
    [switch]$GetLoginUrl,
    [string]$RequestToken,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret
)

# ================================================================
# Module & Config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (Test-Path $inputFile) {
    $cfg = Get-Content $inputFile -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('TradingSymbol'))  { $TradingSymbol  = $cfg.TradingSymbol }
    if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [int]$cfg.InstrumentToken }
    if (-not $PSBoundParameters.ContainsKey('TimeFrame'))      { $TimeFrame      = $cfg.TimeFrame }
    if (-not $PSBoundParameters.ContainsKey('CandlesToShow'))  { $CandlesToShow  = [int]$cfg.CandlesToShow }
    if (-not $PSBoundParameters.ContainsKey('FullMode') -and $cfg.FullMode) { $FullMode = [switch]$true }
    if (-not $PSBoundParameters.ContainsKey('API_Key'))        { $API_Key        = $cfg.API_Key }
    if (-not $PSBoundParameters.ContainsKey('API_Secret'))     { $API_Secret     = $cfg.API_Secret }
}
if (-not $TradingSymbol) { $TradingSymbol = 'NIFTY' }
if (-not $TimeFrame)     { $TimeFrame = '15second' }
if (-not $CandlesToShow -or $CandlesToShow -le 0) { $CandlesToShow = 10 }
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  API_Key/API_Secret not found. Set them in input.json.' -ForegroundColor Red; exit 1
}

# CSV file paths (written by Get-OptionByPrice.ps1 and Monitor-Positions.ps1)
$optionChainCsv = Join-Path $scriptDir 'OptionChaindata.csv'
$cePositionsCsv = Join-Path $scriptDir 'CE-Positions.csv'
$pePositionsCsv = Join-Path $scriptDir 'PE-Positions.csv'

# ================================================================
# Auth
# ================================================================
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
Write-Host "  Access token ready." -ForegroundColor Green

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

$intSec   = Get-IntervalSeconds $TimeFrame
$intLabel = Get-IntervalLabel $intSec

# ================================================================
# HA Candle State
# ================================================================
$script:CompletedCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:ActiveCandle     = $null
$script:PreviousHA       = $null
$script:TickCount        = 0
$script:LastDisplayTime  = [datetime]::MinValue

# CSV cache state (avoid re-reading every tick)
$script:LastCsvReadTime      = [datetime]::MinValue
$script:CsvRefreshSec        = 2
$script:CachedOptionChain    = $null
$script:CachedCEPositions    = $null
$script:CachedPEPositions    = $null

# ================================================================
# HA Helper Functions
# ================================================================
function script:Get-TimeBucket {
    $now = Get-Date
    $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
    $bucket = [Math]::Floor($totalSeconds / $intSec) * $intSec
    $bH = [int][Math]::Floor($bucket / 3600)
    $bM = [int][Math]::Floor(($bucket % 3600) / 60)
    $bS = [int]($bucket % 60)
    return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
}

function script:Convert-ToHA([hashtable]$rawCandle, [hashtable]$previousHA) {
    $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
    if ($null -ne $previousHA) {
        $haOpen = ($previousHA.Open + $previousHA.Close) / 2.0
    } else {
        $haOpen = ($rawCandle.Open + $rawCandle.Close) / 2.0
    }
    $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
    $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
    return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
}

# ================================================================
# CSV Reader
# ================================================================
function script:Refresh-CsvData {
    $now = [datetime]::Now
    if (($now - $script:LastCsvReadTime).TotalSeconds -lt $script:CsvRefreshSec) { return }
    $script:LastCsvReadTime = $now

    # Read Option Chain CSV
    if (Test-Path $optionChainCsv) {
        try { $script:CachedOptionChain = Import-Csv $optionChainCsv } catch { $script:CachedOptionChain = $null }
    }

    # Read CE Positions CSV
    if (Test-Path $cePositionsCsv) {
        try { $script:CachedCEPositions = Import-Csv $cePositionsCsv } catch { $script:CachedCEPositions = $null }
    }

    # Read PE Positions CSV
    if (Test-Path $pePositionsCsv) {
        try { $script:CachedPEPositions = Import-Csv $pePositionsCsv } catch { $script:CachedPEPositions = $null }
    }
}

# ================================================================
# Tick Processing
# ================================================================
function script:Process-Tick([double]$lastPrice, [int]$volume, [int]$openInterest) {
    $script:TickCount++
    $timeBucket = script:Get-TimeBucket

    if (($null -eq $script:ActiveCandle) -or ($script:ActiveCandle.TimeBucket -ne $timeBucket)) {
        if ($null -ne $script:ActiveCandle) {
            $ha = script:Convert-ToHA $script:ActiveCandle $script:PreviousHA
            $script:PreviousHA = @{ Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close }

            $script:CompletedCandles.Add([PSCustomObject]@{
                TimeBucket  = $script:ActiveCandle.TimeBucket
                Open        = [Math]::Round($ha.Open, 2)
                High        = [Math]::Round($ha.High, 2)
                Low         = [Math]::Round($ha.Low, 2)
                Close       = [Math]::Round($ha.Close, 2)
                Volume      = $script:ActiveCandle.Volume
                OI          = $script:ActiveCandle.OpenInterest
                Ticks       = $script:ActiveCandle.TicksInCandle
            })
        }
        $script:ActiveCandle = @{
            TimeBucket=$timeBucket; Open=$lastPrice; High=$lastPrice; Low=$lastPrice; Close=$lastPrice
            Volume=0; PreviousVolume=$volume; OpenInterest=$openInterest; TicksInCandle=1
        }
    } else {
        $script:ActiveCandle.High  = [Math]::Max($script:ActiveCandle.High, $lastPrice)
        $script:ActiveCandle.Low   = [Math]::Min($script:ActiveCandle.Low, $lastPrice)
        $script:ActiveCandle.Close = $lastPrice
        $script:ActiveCandle.OpenInterest = $openInterest
        $script:ActiveCandle.TicksInCandle++
        if (($volume -gt $script:ActiveCandle.PreviousVolume) -and ($script:ActiveCandle.PreviousVolume -gt 0)) {
            $script:ActiveCandle.Volume += ($volume - $script:ActiveCandle.PreviousVolume)
        }
        $script:ActiveCandle.PreviousVolume = $volume
    }
}

# ================================================================
# Display
# ================================================================
function script:Render-Display {
    $now = [datetime]::Now
    if (($now - $script:LastDisplayTime).TotalMilliseconds -lt 250) { return }
    $script:LastDisplayTime = $now

    # Refresh CSV data
    script:Refresh-CsvData

    $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($script:CompletedCandles.Count -gt 0) { $allCandles.AddRange($script:CompletedCandles) }

    if ($null -ne $script:ActiveCandle) {
        $ha = script:Convert-ToHA $script:ActiveCandle $script:PreviousHA
        $allCandles.Add([PSCustomObject]@{
            TimeBucket = $script:ActiveCandle.TimeBucket
            Open       = [Math]::Round($ha.Open, 2)
            High       = [Math]::Round($ha.High, 2)
            Low        = [Math]::Round($ha.Low, 2)
            Close      = [Math]::Round($ha.Close, 2)
            Volume     = $script:ActiveCandle.Volume
            OI         = $script:ActiveCandle.OpenInterest
            Ticks      = $script:ActiveCandle.TicksInCandle
        })
    }
    if ($allCandles.Count -eq 0) { return }

    $skipCount = [Math]::Max(0, $allCandles.Count - $CandlesToShow)
    $visible = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

    Clear-Host
    Write-Host ''

    # ── Section 1: Open Positions ──
    $ceOpen = if ($script:CachedCEPositions) { @($script:CachedCEPositions | Where-Object { $_.Status -eq 'OPEN' }) } else { @() }
    $peOpen = if ($script:CachedPEPositions) { @($script:CachedPEPositions | Where-Object { $_.Status -eq 'OPEN' }) } else { @() }
    $totalOpenCount = $ceOpen.Count + $peOpen.Count

    if ($totalOpenCount -gt 0) {
        Write-Host "  ── OPEN POSITIONS ($totalOpenCount) ──────────────────────────────────────────" -ForegroundColor Yellow
        $posFmt = '  {0,-26} {1,5} {2,6} {3,10} {4,10} {5,12}'
        Write-Host ($posFmt -f 'Symbol', 'Side', 'Qty', 'Avg', 'LTP', 'P&L') -ForegroundColor Cyan

        $totalPnL = 0.0
        foreach ($p in $ceOpen) {
            $pnl = [double]$p.PnL
            $totalPnL += $pnl
            $color = if ($pnl -ge 0) { 'Green' } else { 'Red' }
            Write-Host ($posFmt -f $p.Symbol, $p.Side, $p.Qty, $p.BuyAvg, $p.LTP, ('{0:N2}' -f $pnl)) -ForegroundColor $color
        }
        foreach ($p in $peOpen) {
            $pnl = [double]$p.PnL
            $totalPnL += $pnl
            $color = if ($pnl -ge 0) { 'Green' } else { 'Red' }
            Write-Host ($posFmt -f $p.Symbol, $p.Side, $p.Qty, $p.BuyAvg, $p.LTP, ('{0:N2}' -f $pnl)) -ForegroundColor $color
        }
        $pnlColor = if ($totalPnL -ge 0) { 'Green' } else { 'Red' }
        Write-Host "  Total Open P&L: $($totalPnL.ToString('N2'))" -ForegroundColor $pnlColor
        Write-Host ''
    } else {
        Write-Host "  POSITIONS: No open positions" -ForegroundColor DarkGray
        Write-Host ''
    }

    # ── Section 2: Option Chain Candidates (from OptionChaindata.csv) ──
    if ($script:CachedOptionChain -and $script:CachedOptionChain.Count -gt 0) {
        $ceCandidates = @($script:CachedOptionChain | Where-Object { $_.Type -eq 'CE' -and $_.IsBest -eq 'True' })
        $peCandidates = @($script:CachedOptionChain | Where-Object { $_.Type -eq 'PE' -and $_.IsBest -eq 'True' })
        $fetchedAt = $script:CachedOptionChain[0].FetchedAt

        Write-Host "  ── OPTION CHAIN TARGETS ─────────────────────── $fetchedAt" -ForegroundColor Magenta
        $optFmt = '  {0,4}  {1,-26} {2,10} {3,10} {4,10}'
        Write-Host ($optFmt -f 'Type', 'Symbol', 'Strike', 'LTP', 'Target') -ForegroundColor Cyan

        foreach ($c in $ceCandidates) {
            Write-Host ($optFmt -f 'CE', $c.Symbol, $c.Strike, $c.LTP, $c.Target) -ForegroundColor Green
        }
        foreach ($c in $peCandidates) {
            Write-Host ($optFmt -f 'PE', $c.Symbol, $c.Strike, $c.LTP, $c.Target) -ForegroundColor Red
        }
        Write-Host ''
    }

    # ── Section 3: Heikin Ashi Candles ──
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "  $label - Live Heikin Ashi Candles" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "  Symbol: $sym  |  Token: $instToken  |  TF: $TimeFrame ($intLabel)"
    Write-Host "  Ticks : $($script:TickCount)  |  Candles: $($allCandles.Count)  |  Showing: $($visible.Count)"
    Write-Host "  Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')"
    Write-Host ''

    $fmt = ' {0,-18} {1,12} {2,12} {3,12} {4,12} {5,10} {6,8} {7,5} {8,6}'
    Write-Host ($fmt -f 'Time','Open','High','Low','Close','Volume','OI','Ticks','Trend') -ForegroundColor Cyan
    Write-Host (' ' + ('-' * 98))

    for ($i = 0; $i -lt $visible.Count; $i++) {
        $c = $visible[$i]
        $trend = if ($c.Close -ge $c.Open) { '  UP' } else { 'DOWN' }
        $color = if ($c.Close -ge $c.Open) { 'Green' } else { 'Red' }
        $line = $fmt -f $c.TimeBucket, ('{0:N2}' -f $c.Open), ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), ('{0:N0}' -f $c.Volume), ('{0:N0}' -f $c.OI), $c.Ticks, $trend
        if ($i -eq ($visible.Count - 1)) {
            Write-Host $line -ForegroundColor Yellow
        } else {
            Write-Host $line -ForegroundColor $color
        }
    }

    Write-Host ''
    Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
}

# ================================================================
# WebSocket
# ================================================================
$wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
$modeStr = if ($FullMode) { 'full' } else { 'quote' }

Write-Host ''
Write-Host "  $label - Live Dashboard" -ForegroundColor Cyan
Write-Host "  Symbol: $sym | Token: $instToken | TF: $TimeFrame | Mode: $modeStr"
Write-Host "  CSVs: OptionChaindata.csv, CE-Positions.csv, PE-Positions.csv"
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

        $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["' + $modeStr + '",[' + $instToken + ']]}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)

        Write-Host "  Subscribed ($modeStr). Waiting for ticks..." -ForegroundColor Green
        Write-Host ''

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
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
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) { continue }

            if (($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) -and ($res.Count -gt 2)) {
                $ticks = Parse-KiteTicks $buf $res.Count
                foreach ($tick in $ticks) {
                    if ($tick.LastPrice -gt 0) {
                        script:Process-Tick $tick.LastPrice $tick.Volume $tick.OpenInterest
                    }
                }
                script:Render-Display
            }
        }

        $retryCount++
        if ($retryCount -le $maxRetries) {
            $wait = $retryCount * 5
            Write-Host "  Connection lost. Reconnecting in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
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
Write-Host "  Total ticks received: $($script:TickCount)" -ForegroundColor Gray
Write-Host ''
