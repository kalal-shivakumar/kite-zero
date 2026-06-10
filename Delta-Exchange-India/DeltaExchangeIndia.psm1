# ============================================================
# DeltaExchangeIndia.psm1 — Delta Exchange India Trading Module
#
# REST API + WebSocket streaming for Delta Exchange India
# Supports: Perpetual Futures, Call Options, Put Options
# Auth: HMAC-SHA256 signed requests
#
# Base URL:  https://api.india.delta.exchange
# WebSocket: wss://public-socket.india.delta.exchange (public)
#            wss://socket.india.delta.exchange (private)
#
# SETUP:
#   Import-Module .\DeltaExchangeIndia.psm1
# ============================================================

# ── Configuration ────────────────────────────────────────────
$script:BaseUrl     = 'https://api.india.delta.exchange'
$script:WsPublicUrl = 'wss://public-socket.india.delta.exchange'
$script:WsPrivateUrl= 'wss://socket.india.delta.exchange'

$script:Presets = @{
    'BTCUSD'   = @{ Symbol = 'BTCUSD';   Asset = 'BTC';  Label = 'Bitcoin Perpetual' }
    'ETHUSD'   = @{ Symbol = 'ETHUSD';   Asset = 'ETH';  Label = 'Ethereum Perpetual' }
    'SOLUSD'   = @{ Symbol = 'SOLUSD';   Asset = 'SOL';  Label = 'Solana Perpetual' }
    'XRPUSD'   = @{ Symbol = 'XRPUSD';   Asset = 'XRP';  Label = 'XRP Perpetual' }
    'BNBUSD'   = @{ Symbol = 'BNBUSD';   Asset = 'BNB';  Label = 'BNB Perpetual' }
    'DOGEUSD'  = @{ Symbol = 'DOGEUSD';  Asset = 'DOGE'; Label = 'Dogecoin Perpetual' }
    'LINKUSD'  = @{ Symbol = 'LINKUSD';  Asset = 'LINK'; Label = 'Chainlink Perpetual' }
    'AVAXUSD'  = @{ Symbol = 'AVAXUSD';  Asset = 'AVAX'; Label = 'Avalanche Perpetual' }
    'MATICUSD' = @{ Symbol = 'MATICUSD'; Asset = 'MATIC';Label = 'Polygon Perpetual' }
    'ADAUSD'   = @{ Symbol = 'ADAUSD';   Asset = 'ADA';  Label = 'Cardano Perpetual' }
    'DOTUSD'   = @{ Symbol = 'DOTUSD';   Asset = 'DOT';  Label = 'Polkadot Perpetual' }
    'LTCUSD'   = @{ Symbol = 'LTCUSD';   Asset = 'LTC';  Label = 'Litecoin Perpetual' }
}

$script:Resolutions = @{
    '1m'  = 60;      '3m'  = 180;     '5m'  = 300
    '15m' = 900;     '30m' = 1800;    '1h'  = 3600
    '2h'  = 7200;    '4h'  = 14400;   '6h'  = 21600
    '1d'  = 86400;   '1w'  = 604800
}

# ══════════════════════════════════════════════════════════════
# AUTHENTICATION
# ══════════════════════════════════════════════════════════════

function New-DeltaSignature {
    param([string]$Secret, [string]$Message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message))
    return [BitConverter]::ToString($hash).Replace('-', '').ToLower()
}

function Invoke-DeltaApi {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$Method   = 'GET',
        [string]$Endpoint,
        [hashtable]$Query  = @{},
        [object]$Body,
        [switch]$Public
    )

    $queryString = ''
    if ($Query.Count -gt 0) {
        $parts = @()
        foreach ($key in ($Query.Keys | Sort-Object)) {
            if ($null -ne $Query[$key] -and $Query[$key] -ne '') {
                $parts += "$key=$([System.Uri]::EscapeDataString($Query[$key].ToString()))"
            }
        }
        if ($parts.Count -gt 0) { $queryString = '?' + ($parts -join '&') }
    }

    $path    = "/v2$Endpoint"
    $url     = "${script:BaseUrl}${path}${queryString}"
    $bodyJson = ''
    if ($Body) { $bodyJson = $Body | ConvertTo-Json -Compress -Depth 10 }

    $headers = @{
        'Content-Type' = 'application/json'
        'User-Agent'   = 'powershell-delta-client'
    }

    if (-not $Public) {
        $timestamp     = [string][int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $signatureData = $Method.ToUpper() + $timestamp + $path + $queryString + $bodyJson
        $signature     = New-DeltaSignature -Secret $ApiSecret -Message $signatureData
        $headers['api-key']   = $ApiKey
        $headers['timestamp'] = $timestamp
        $headers['signature'] = $signature
    }

    try {
        $splat = @{ Uri = $url; Method = $Method.ToUpper(); Headers = $headers }
        if ($bodyJson -and $Method.ToUpper() -ne 'GET') {
            $splat.Body        = $bodyJson
            $splat.ContentType = 'application/json'
        }
        return (Invoke-RestMethod @splat -ErrorAction Stop)
    } catch {
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            Write-Host "  Delta API [$Method $Endpoint]: $($errBody.error.code)" -ForegroundColor Red
        } catch {
            Write-Host "  Delta API [$Method $Endpoint]: $($_.Exception.Message)" -ForegroundColor Red
        }
        return $null
    }
}

# ══════════════════════════════════════════════════════════════
# MARKET DATA (public — no auth required)
# ══════════════════════════════════════════════════════════════

function Get-DeltaProducts {
    param(
        [string]$ContractTypes,
        [string]$States = 'live',
        [int]$PageSize  = 100
    )
    $q = @{ states = $States; page_size = $PageSize.ToString() }
    if ($ContractTypes) { $q.contract_types = $ContractTypes }
    $r = Invoke-DeltaApi -Method GET -Endpoint '/products' -Query $q -Public
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Get-DeltaProductBySymbol {
    param([string]$Symbol)
    $r = Invoke-DeltaApi -Method GET -Endpoint "/products/$Symbol" -Public
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Get-DeltaTicker {
    param([string]$Symbol)
    $r = Invoke-DeltaApi -Method GET -Endpoint "/tickers/$Symbol" -Public
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Get-DeltaTickers {
    param(
        [string]$ContractTypes,
        [string]$UnderlyingAssetSymbols,
        [string]$ExpiryDate
    )
    $q = @{}
    if ($ContractTypes)           { $q.contract_types = $ContractTypes }
    if ($UnderlyingAssetSymbols)  { $q.underlying_asset_symbols = $UnderlyingAssetSymbols }
    if ($ExpiryDate)              { $q.expiry_date = $ExpiryDate }
    $r = Invoke-DeltaApi -Method GET -Endpoint '/tickers' -Query $q -Public
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Get-DeltaCandles {
    param(
        [string]$Symbol,
        [string]$Resolution = '1m',
        [int64]$Start,
        [int64]$End
    )
    $q = @{
        symbol     = $Symbol
        resolution = $Resolution
        start      = $Start.ToString()
        end        = $End.ToString()
    }
    $r = Invoke-DeltaApi -Method GET -Endpoint '/history/candles' -Query $q -Public
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Get-DeltaOrderbook {
    param([string]$Symbol, [int]$Depth = 20)
    $q = @{ depth = $Depth.ToString() }
    $r = Invoke-DeltaApi -Method GET -Endpoint "/l2orderbook/$Symbol" -Query $q -Public
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Get-DeltaSpotPrice {
    param([string]$Symbol)
    $ticker = Get-DeltaTicker -Symbol $Symbol
    if ($ticker -and $ticker.spot_price) {
        return [double]$ticker.spot_price
    }
    if ($ticker -and $ticker.close) {
        return [double]$ticker.close
    }
    return 0
}

# ══════════════════════════════════════════════════════════════
# TRADING (auth required)
# ══════════════════════════════════════════════════════════════

function Place-DeltaOrder {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$ProductSymbol,
        [int]$ProductId,
        [int]$Size,
        [string]$Side,
        [string]$OrderType    = 'market_order',
        [string]$LimitPrice,
        [string]$StopPrice,
        [string]$StopOrderType,
        [string]$TimeInForce  = 'gtc',
        [bool]$ReduceOnly     = $false,
        [string]$ClientOrderId,
        [string]$Tag
    )
    $body = @{
        size       = $Size
        side       = $Side
        order_type = $OrderType
    }
    if ($ProductSymbol) { $body.product_symbol = $ProductSymbol }
    if ($ProductId -gt 0) { $body.product_id = $ProductId }
    if ($LimitPrice)     { $body.limit_price = $LimitPrice }
    if ($StopPrice)      { $body.stop_price  = $StopPrice }
    if ($StopOrderType)  { $body.stop_order_type = $StopOrderType }
    if ($TimeInForce)    { $body.time_in_force = $TimeInForce }
    if ($ReduceOnly)     { $body.reduce_only = $true }
    if ($ClientOrderId)  { $body.client_order_id = $ClientOrderId }

    Write-Host "  Placing $Side $OrderType | Symbol: $(if($ProductSymbol){$ProductSymbol}else{$ProductId}) | Size: $Size" -ForegroundColor Yellow

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method POST -Endpoint '/orders' -Body $body
    if ($r -and $r.success) {
        Write-Host "  Order placed: ID=$($r.result.id) | State=$($r.result.state)" -ForegroundColor Green
        return $r.result
    }
    Write-Host "  Order FAILED" -ForegroundColor Red
    return $null
}

function Edit-DeltaOrder {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [int]$OrderId,
        [string]$ProductSymbol,
        [int]$ProductId,
        [int]$Size,
        [string]$LimitPrice
    )
    $body = @{ id = $OrderId }
    if ($ProductSymbol) { $body.product_symbol = $ProductSymbol }
    if ($ProductId -gt 0) { $body.product_id = $ProductId }
    if ($Size -gt 0) { $body.size = $Size }
    if ($LimitPrice) { $body.limit_price = $LimitPrice }

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method PUT -Endpoint '/orders' -Body $body
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Remove-DeltaOrder {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [int]$OrderId,
        [int]$ProductId,
        [string]$ClientOrderId
    )
    $body = @{}
    if ($OrderId -gt 0)   { $body.id = $OrderId }
    if ($ProductId -gt 0) { $body.product_id = $ProductId }
    if ($ClientOrderId)   { $body.client_order_id = $ClientOrderId }

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method DELETE -Endpoint '/orders' -Body $body
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Remove-DeltaAllOrders {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$ProductSymbol,
        [string]$ContractTypes
    )
    $body = @{}
    if ($ProductSymbol) { $body.product_symbol = $ProductSymbol }
    if ($ContractTypes) { $body.contract_types = $ContractTypes }

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method DELETE -Endpoint '/orders/all' -Body $body
    if ($r -and $r.success) { return $true }
    return $false
}

function Get-DeltaActiveOrders {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$ProductIds,
        [string]$States = 'open,pending'
    )
    $q = @{ states = $States }
    if ($ProductIds) { $q.product_ids = $ProductIds }

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method GET -Endpoint '/orders' -Query $q
    if ($r -and $r.success) { return $r.result }
    return @()
}

function Get-DeltaPositions {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$ContractTypes
    )
    $q = @{}
    if ($ContractTypes) { $q.contract_types = $ContractTypes }

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method GET -Endpoint '/positions/margined' -Query $q
    if ($r -and $r.success) { return $r.result }
    return @()
}

function Get-DeltaPosition {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [int]$ProductId,
        [string]$UnderlyingAssetSymbol
    )
    $q = @{}
    if ($ProductId -gt 0) { $q.product_id = $ProductId.ToString() }
    if ($UnderlyingAssetSymbol) { $q.underlying_asset_symbol = $UnderlyingAssetSymbol }

    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method GET -Endpoint '/positions' -Query $q
    if ($r -and $r.success) { return $r.result }
    return $null
}

function Close-DeltaAllPositions {
    param(
        [string]$ApiKey,
        [string]$ApiSecret
    )
    $body = @{ close_all_portfolio = $true; close_all_isolated = $true }
    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method POST -Endpoint '/positions/close_all' -Body $body
    if ($r -and $r.success) { return $true }
    return $false
}

function Get-DeltaWalletBalances {
    param(
        [string]$ApiKey,
        [string]$ApiSecret
    )
    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method GET -Endpoint '/wallet/balances'
    if ($r -and $r.success) { return $r.result }
    return @()
}

function Set-DeltaLeverage {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [int]$ProductId,
        [string]$Leverage
    )
    $body = @{ leverage = $Leverage }
    $r = Invoke-DeltaApi -ApiKey $ApiKey -ApiSecret $ApiSecret -Method POST -Endpoint "/products/$ProductId/orders/leverage" -Body $body
    if ($r -and $r.success) { return $r.result }
    return $null
}

# ══════════════════════════════════════════════════════════════
# CANDLE & HEIKIN-ASHI HELPERS
# ══════════════════════════════════════════════════════════════

function Get-ResolutionSeconds([string]$Res) {
    if ($script:Resolutions.ContainsKey($Res)) { return $script:Resolutions[$Res] }
    return 60
}

function ConvertTo-HeikinAshi {
    param([array]$Candles)
    if (-not $Candles -or $Candles.Count -eq 0) { return @() }

    $ha = @()
    for ($i = 0; $i -lt $Candles.Count; $i++) {
        $c = $Candles[$i]
        $haClose = ($c.open + $c.high + $c.low + $c.close) / 4
        if ($i -eq 0) {
            $haOpen = ($c.open + $c.close) / 2
        } else {
            $haOpen = ($ha[$i - 1].Open + $ha[$i - 1].Close) / 2
        }
        $haHigh = [Math]::Max($c.high, [Math]::Max($haOpen, $haClose))
        $haLow  = [Math]::Min($c.low, [Math]::Min($haOpen, $haClose))

        $ha += [PSCustomObject]@{
            Time  = $c.time
            Open  = [Math]::Round($haOpen, 2)
            High  = [Math]::Round($haHigh, 2)
            Low   = [Math]::Round($haLow, 2)
            Close = [Math]::Round($haClose, 2)
            Vol   = if ($c.volume) { $c.volume } else { 0 }
        }
    }
    return $ha
}

function Format-CandleTable {
    param([array]$Candles, [int]$Show = 10, [string]$Label = 'HA')
    if (-not $Candles -or $Candles.Count -eq 0) { return }

    $display = $Candles | Select-Object -Last $Show
    Write-Host ""
    Write-Host "  ┌─────────────────────┬──────────────┬──────────────┬──────────────┬──────────────┬───────┐" -ForegroundColor DarkGray
    Write-Host "  │ Time                │ $Label Open       │ $Label High       │ $Label Low        │ $Label Close      │ Color │" -ForegroundColor DarkGray
    Write-Host "  ├─────────────────────┼──────────────┼──────────────┼──────────────┼──────────────┼───────┤" -ForegroundColor DarkGray

    foreach ($candle in $display) {
        $ts    = [DateTimeOffset]::FromUnixTimeSeconds($candle.Time).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        $color = if ($candle.Close -ge $candle.Open) { 'Green' } else { 'Red' }
        $tag   = if ($candle.Close -ge $candle.Open) { ' G ' } else { ' R ' }

        $o = $candle.Open.ToString('N2').PadLeft(12)
        $h = $candle.High.ToString('N2').PadLeft(12)
        $l = $candle.Low.ToString('N2').PadLeft(12)
        $c = $candle.Close.ToString('N2').PadLeft(12)

        Write-Host "  │ $ts │ $o │ $h │ $l │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$c" -NoNewline -ForegroundColor $color
        Write-Host " │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$tag" -NoNewline -ForegroundColor $color
        Write-Host " │" -ForegroundColor DarkGray
    }
    Write-Host "  └─────────────────────┴──────────────┴──────────────┴──────────────┴──────────────┴───────┘" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# PRESET HELPERS
# ══════════════════════════════════════════════════════════════

function Show-DeltaPresets {
    Write-Host ""
    Write-Host "  Available Preset Symbols:" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    foreach ($key in ($script:Presets.Keys | Sort-Object)) {
        $p = $script:Presets[$key]
        Write-Host "    $($key.PadRight(12)) $($p.Label)" -ForegroundColor White
    }
    Write-Host ""
}

function Resolve-DeltaSymbol([string]$Name) {
    $upper = $Name.ToUpper()
    if ($script:Presets.ContainsKey($upper)) { return $script:Presets[$upper] }
    return @{ Symbol = $upper; Asset = $upper.Replace('USD',''); Label = $upper }
}

# ══════════════════════════════════════════════════════════════
# WEBSOCKET STREAMING HELPERS
# Non-blocking WebSocket for 100ms real-time updates
# ══════════════════════════════════════════════════════════════

function New-DeltaStreamWebSocket {
    <#
    .SYNOPSIS
      Opens a public WebSocket and subscribes to channels. Returns the WS object.
    #>
    param(
        [string[]]$Channels,
        [string[]]$Symbols
    )

    $ws  = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(10)
    $uri = [System.Uri]::new($script:WsPublicUrl)

    try {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(10000)
        $null = $ws.ConnectAsync($uri, $cts.Token).GetAwaiter().GetResult()
    } catch {
        Write-Host "  WebSocket connect failed: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        return $null
    }

    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        Write-Host "  WebSocket state: $($ws.State)" -ForegroundColor Red
        return $null
    }

    # Build subscription
    $channelList = @()
    foreach ($ch in $Channels) {
        $channelList += @{ name = $ch; symbols = $Symbols }
    }
    $subMsg = @{ type = 'subscribe'; payload = @{ channels = $channelList } } |
              ConvertTo-Json -Compress -Depth 5

    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($subMsg)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $null = $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

    # Enable server heartbeats to keep connection alive
    $hbMsg   = '{"type":"enable_heartbeat","payload":{"interval":15}}'
    $hbBytes = [System.Text.Encoding]::UTF8.GetBytes($hbMsg)
    $hbSeg   = [System.ArraySegment[byte]]::new($hbBytes)
    $null = $ws.SendAsync($hbSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

    return $ws
}

function Receive-DeltaWsMessage {
    <#
    .SYNOPSIS
      Non-blocking receive with timeout (default 100ms). Returns parsed JSON or $null.
    #>
    param(
        [System.Net.WebSockets.ClientWebSocket]$Ws,
        [byte[]]$Buffer,
        [int]$TimeoutMs = 100
    )

    if ($Ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return $null }

    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)

    try {
        $task = $Ws.ReceiveAsync([System.ArraySegment[byte]]::new($Buffer), $cts.Token)
        $result = $task.GetAwaiter().GetResult()

        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $msg = [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $result.Count)
        return ($msg | ConvertFrom-Json -ErrorAction SilentlyContinue)
    } catch [System.OperationCanceledException] {
        return $null       # timeout — no data
    } catch {
        return $null       # connection issue
    } finally {
        $cts.Dispose()
    }
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Get-DeltaLiveCandles  (WebSocket streaming)
# ══════════════════════════════════════════════════════════════

function Get-DeltaLiveCandles {
    param(
        [string]$TradingSymbol = 'BTCUSD',
        [string]$TimeFrame     = '1m',
        [int]$CandlesToShow    = 10,
        [int]$RefreshMs        = 100,
        [switch]$ListSymbols
    )

    if ($ListSymbols) { Show-DeltaPresets; return }

    $preset = Resolve-DeltaSymbol $TradingSymbol
    $resSec = Get-ResolutionSeconds $TimeFrame
    $symbol = $preset.Symbol
    $wsChannel = "candlestick_$TimeFrame"

    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Delta Exchange Live Candles | $symbol | $TimeFrame" -ForegroundColor Cyan
    Write-Host "  Mode: WebSocket streaming (${RefreshMs}ms)" -ForegroundColor Cyan
    Write-Host "  ═══════════════════════════════════════════════" -ForegroundColor Cyan

    # Bootstrap: fetch historical candles via REST
    $now   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $start = $now - ($resSec * ($CandlesToShow + 5))
    $candles = Get-DeltaCandles -Symbol $symbol -Resolution $TimeFrame -Start $start -End $now

    $candleMap = [ordered]@{}
    if ($candles) {
        foreach ($c in ($candles | Sort-Object { $_.time })) {
            $candleMap[[int64]$c.time] = @{ time = [int64]$c.time; open = [double]$c.open; high = [double]$c.high; low = [double]$c.low; close = [double]$c.close; volume = 0 }
        }
    }

    # Connect WebSocket
    Write-Host "  Connecting WebSocket..." -ForegroundColor Yellow
    $ws = New-DeltaStreamWebSocket -Channels @($wsChannel) -Symbols @($symbol)
    if (-not $ws) { Write-Host "  Failed to connect WebSocket. Exiting." -ForegroundColor Red; return }
    Write-Host "  WebSocket connected — streaming $wsChannel" -ForegroundColor Green

    $buffer       = New-Object byte[] 32768
    $lastRedraw   = [DateTime]::MinValue
    $ltp          = 0

    try {
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $data = Receive-DeltaWsMessage -Ws $ws -Buffer $buffer -TimeoutMs $RefreshMs

            # WS fields: o=open, h=high, l=low, c=close, cst=candle_start (microseconds), v=volume
            if ($data -and $data.cst -and $null -ne $data.o) {
                $t = [int64]($data.cst / 1000000)   # microseconds → seconds
                $candleMap[$t] = @{ time = $t; open = [double]$data.o; high = [double]$data.h; low = [double]$data.l; close = [double]$data.c; volume = [double]$data.v }
                $ltp = [double]$data.c
            }

            # Redraw at refresh interval
            $nowDt = [DateTime]::UtcNow
            if (($nowDt - $lastRedraw).TotalMilliseconds -ge $RefreshMs -and $candleMap.Count -gt 0) {
                $lastRedraw = $nowDt
                $arr = @($candleMap.Values) | Sort-Object { $_.time } | Select-Object -Last $CandlesToShow
                try { [Console]::SetCursorPosition(0, 7) } catch {}
                foreach ($c in $arr) {
                    $ts    = [DateTimeOffset]::FromUnixTimeSeconds($c.time).LocalDateTime.ToString('HH:mm:ss')
                    $color = if ($c.close -ge $c.open) { 'Green' } else { 'Red' }
                    $line  = "  $ts | O: $($c.open.ToString('N2').PadLeft(12)) | H: $($c.high.ToString('N2').PadLeft(12)) | L: $($c.low.ToString('N2').PadLeft(12)) | C: $($c.close.ToString('N2').PadLeft(12))    "
                    Write-Host $line -ForegroundColor $color
                }
                Write-Host ""
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] LTP: $ltp | WS streaming    " -ForegroundColor DarkGray -NoNewline
            }
        }
    } finally {
        try { $ws.Dispose() } catch {}
        Write-Host "`n  WebSocket disconnected." -ForegroundColor Yellow
    }
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Get-DeltaHeikinAshiCandles  (WebSocket streaming)
# ══════════════════════════════════════════════════════════════

function Get-DeltaHeikinAshiCandles {
    param(
        [string]$TradingSymbol = 'BTCUSD',
        [string]$TimeFrame     = '1m',
        [int]$CandlesToShow    = 10,
        [int]$RefreshMs        = 100,
        [switch]$ListSymbols
    )

    if ($ListSymbols) { Show-DeltaPresets; return }

    $preset = Resolve-DeltaSymbol $TradingSymbol
    $resSec = Get-ResolutionSeconds $TimeFrame
    $symbol = $preset.Symbol
    $wsChannel = "candlestick_$TimeFrame"

    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Delta Exchange HA Candles | $symbol | $TimeFrame" -ForegroundColor Cyan
    Write-Host "  Mode: WebSocket streaming (${RefreshMs}ms)" -ForegroundColor Cyan
    Write-Host "  ═══════════════════════════════════════════════" -ForegroundColor Cyan

    # Bootstrap
    $now   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $start = $now - ($resSec * ($CandlesToShow + 10))
    $candles = Get-DeltaCandles -Symbol $symbol -Resolution $TimeFrame -Start $start -End $now

    $candleMap = [ordered]@{}
    if ($candles) {
        foreach ($c in ($candles | Sort-Object { $_.time })) {
            $candleMap[[int64]$c.time] = [PSCustomObject]@{ time = [int64]$c.time; open = [double]$c.open; high = [double]$c.high; low = [double]$c.low; close = [double]$c.close; volume = 0 }
        }
    }

    Write-Host "  Connecting WebSocket..." -ForegroundColor Yellow
    $ws = New-DeltaStreamWebSocket -Channels @($wsChannel) -Symbols @($symbol)
    if (-not $ws) { Write-Host "  Failed. Exiting." -ForegroundColor Red; return }
    Write-Host "  WebSocket connected — streaming $wsChannel" -ForegroundColor Green

    $buffer     = New-Object byte[] 32768
    $lastRedraw = [DateTime]::MinValue
    $ltp        = 0

    try {
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $data = Receive-DeltaWsMessage -Ws $ws -Buffer $buffer -TimeoutMs $RefreshMs

            # WS fields: o=open, h=high, l=low, c=close, cst=candle_start (microseconds), v=volume
            if ($data -and $data.cst -and $null -ne $data.o) {
                $t = [int64]($data.cst / 1000000)
                $candleMap[$t] = [PSCustomObject]@{ time = $t; open = [double]$data.o; high = [double]$data.h; low = [double]$data.l; close = [double]$data.c; volume = [double]$data.v }
                $ltp = [double]$data.c
            }

            $nowDt = [DateTime]::UtcNow
            if (($nowDt - $lastRedraw).TotalMilliseconds -ge $RefreshMs -and $candleMap.Count -ge 2) {
                $lastRedraw = $nowDt
                $arr = @($candleMap.Values) | Sort-Object { $_.time }
                $ha  = ConvertTo-HeikinAshi -Candles $arr

                try { Clear-Host } catch {}
                Write-Host ""
                Write-Host "  Delta Exchange HA Candles | $symbol | $TimeFrame | WS ${RefreshMs}ms" -ForegroundColor Cyan
                Format-CandleTable -Candles $ha -Show $CandlesToShow -Label 'HA'
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] LTP: $ltp   " -ForegroundColor DarkGray
            }
        }
    } finally {
        try { $ws.Dispose() } catch {}
        Write-Host "`n  WebSocket disconnected." -ForegroundColor Yellow
    }
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Invoke-DeltaHALongStrategy  (WebSocket streaming)
# Heikin-Ashi Long-only strategy — signals on RUNNING candle
# Entry: current HA Close > previous HA High
# Exit:  current HA Close < previous HA Low
# ══════════════════════════════════════════════════════════════

function Invoke-DeltaHALongStrategy {
    param(
        [string]$TradingSymbol = 'BTCUSD',
        [string]$TimeFrame     = '3m',
        [int]$CandlesToShow    = 10,
        [int]$RefreshMs        = 100,
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$OrdersFolder,
        [switch]$ListSymbols
    )

    if ($ListSymbols) { Show-DeltaPresets; return }

    $preset    = Resolve-DeltaSymbol $TradingSymbol
    $resSec    = Get-ResolutionSeconds $TimeFrame
    $symbol    = $preset.Symbol
    $wsChannel = "candlestick_$TimeFrame"

    if (-not (Test-Path $OrdersFolder)) { New-Item -ItemType Directory -Path $OrdersFolder -Force | Out-Null }

    $script:LongInPosition = $false
    $script:LongEntryPrice = 0
    $script:LongEntryTime  = ''
    $script:LongTotalPnL   = 0
    $script:LongTradeCount = 0

    # Restore position state
    $posFile = Join-Path $OrdersFolder 'Long-Position.json'
    if (Test-Path $posFile) {
        $saved = Get-Content $posFile -Raw | ConvertFrom-Json
        $script:LongInPosition = $true
        $script:LongEntryPrice = $saved.Price
        $script:LongEntryTime  = $saved.Time
        $script:LongTotalPnL   = if ($saved.TotalPnL) { $saved.TotalPnL } else { 0 }
        Write-Host "  Restored Long position: Entry=$($script:LongEntryPrice) at $($script:LongEntryTime)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  DELTA HA LONG STRATEGY | $symbol | $TimeFrame | WS ${RefreshMs}ms" -ForegroundColor Green
    Write-Host "  Signals on RUNNING candle (real-time)" -ForegroundColor Green
    Write-Host "  Entry: HA Close > prev HA High | Exit: HA Close < prev HA Low" -ForegroundColor Green
    Write-Host "  Signal folder: $OrdersFolder" -ForegroundColor Green
    Write-Host "  ═══════════════════════════════════════════════════════════" -ForegroundColor Green

    # Bootstrap: fetch historical candles via REST (includes current running candle)
    $now   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $start = $now - ($resSec * ($CandlesToShow + 15))
    $restCandles = Get-DeltaCandles -Symbol $symbol -Resolution $TimeFrame -Start $start -End $now

    $candleMap = [ordered]@{}
    if ($restCandles) {
        foreach ($c in ($restCandles | Sort-Object { $_.time })) {
            $candleMap[[int64]$c.time] = [PSCustomObject]@{ time=[int64]$c.time; open=[double]$c.open; high=[double]$c.high; low=[double]$c.low; close=[double]$c.close; volume=0 }
        }
    }
    Write-Host "  Bootstrapped $($candleMap.Count) candles from REST" -ForegroundColor DarkGray

    # Connect WebSocket (with auto-reconnect)
    $buffer     = New-Object byte[] 32768
    $lastRedraw = [DateTime]::MinValue
    $ltp        = if ($candleMap.Count -gt 0) { [double](@($candleMap.Values)[-1].close) } else { 0 }
    $signalFired = $false
    $wsTickReceived = $false

    while ($true) {
      try {
        Write-Host "  Connecting WebSocket to $wsChannel..." -ForegroundColor Yellow
        $ws = New-DeltaStreamWebSocket -Channels @($wsChannel) -Symbols @($symbol)
        if (-not $ws) {
            Write-Host "  WebSocket failed. Retrying in 3s..." -ForegroundColor Red
            Start-Sleep -Seconds 3
            continue
        }
        Write-Host "  WebSocket connected - streaming live" -ForegroundColor Green

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            # Non-blocking receive (100ms timeout)
            $data = Receive-DeltaWsMessage -Ws $ws -Buffer $buffer -TimeoutMs $RefreshMs

            # Update candle map from WebSocket data
            # WS fields: o=open, h=high, l=low, c=close, cst=candle_start (microseconds), v=volume
            if ($data -and $data.cst -and $null -ne $data.o) {
                $t = [int64]($data.cst / 1000000)
                $candleMap[$t] = [PSCustomObject]@{ time=$t; open=[double]$data.o; high=[double]$data.h; low=[double]$data.l; close=[double]$data.c; volume=[double]$data.v }
                $ltp = [double]$data.c
                $signalFired = $false   # new tick — allow signal check
                $wsTickReceived = $true
            }

            # Skip signal checking if not enough candles or already fired signal this tick or no WS data yet
            $checkSignals = ($candleMap.Count -ge 3 -and -not $signalFired -and $wsTickReceived)

            if ($checkSignals) {
            # Build HA from ALL candles including the running one
            $arr = @($candleMap.Values) | Sort-Object { $_.time }
            $ha  = ConvertTo-HeikinAshi -Candles $arr

            if ($ha.Count -ge 2) {

            $latestHA = $ha[-1]   # current running candle HA
            $prevHA   = $ha[-2]   # previous completed candle HA

            # ── LONG ENTRY: HA Close > previous HA High ──
            if (-not $script:LongInPosition) {
                if ($latestHA.Close -gt $prevHA.High) {
                    $ts       = (Get-Date).ToString('HH:mm:ss')
                    $fileName = "Long-Entry-$($ts.Replace(':','-')).txt"
                    $filePath = Join-Path $OrdersFolder $fileName

                    "LONG ENTRY | $symbol | HA Close $($latestHA.Close) > prev HA High $($prevHA.High) | LTP: $ltp | $ts" |
                        Set-Content $filePath -Force

                    $script:LongInPosition = $true
                    $script:LongEntryPrice = $ltp
                    $script:LongEntryTime  = $ts
                    $script:LongTradeCount++
                    $signalFired = $true

                    @{ Price=$script:LongEntryPrice; Time=$script:LongEntryTime; Symbol=$symbol; TotalPnL=$script:LongTotalPnL } |
                        ConvertTo-Json | Set-Content $posFile -Force

                    Write-Host ""
                    Write-Host "  [$ts] ▲ LONG ENTRY | HA Close $($latestHA.Close) > prev High $($prevHA.High) | LTP: $ltp" -ForegroundColor Green
                }
            }

            # ── LONG EXIT: HA Close < previous HA Low ──
            if ($script:LongInPosition -and -not $signalFired) {
                if ($latestHA.Close -lt $prevHA.Low) {
                    $ts       = (Get-Date).ToString('HH:mm:ss')
                    $fileName = "Long-Exit-$($ts.Replace(':','-')).txt"
                    $filePath = Join-Path $OrdersFolder $fileName

                    $tradePnL = $ltp - $script:LongEntryPrice
                    $script:LongTotalPnL += $tradePnL

                    "LONG EXIT | $symbol | HA Close $($latestHA.Close) < prev HA Low $($prevHA.Low) | LTP: $ltp | PnL: $($tradePnL.ToString('N2')) | $ts" |
                        Set-Content $filePath -Force

                    $pnlColor = if ($tradePnL -ge 0) { 'Green' } else { 'Red' }
                    Write-Host ""
                    Write-Host "  [$ts] ▼ LONG EXIT | HA Close $($latestHA.Close) < prev Low $($prevHA.Low) | LTP: $ltp | PnL: $($tradePnL.ToString('N2'))" -ForegroundColor $pnlColor

                    $script:LongInPosition = $false
                    $script:LongEntryPrice = 0
                    $script:LongEntryTime  = ''
                    $signalFired = $true
                    Remove-Item $posFile -Force -ErrorAction SilentlyContinue
                }
            }

            } # end if ($ha.Count -ge 2)
            } # end if ($checkSignals)

            # Build HA for display (always, even before WS tick)
            if ($candleMap.Count -ge 2) {
                $arr = @($candleMap.Values) | Sort-Object { $_.time }
                $ha  = ConvertTo-HeikinAshi -Candles $arr
            }

            # Redraw display at refresh interval
            $nowDt = [DateTime]::UtcNow
            if (($nowDt - $lastRedraw).TotalMilliseconds -ge 250) {
                $lastRedraw = $nowDt

                try { Clear-Host } catch {}
                Write-Host ""
                Write-Host "  DELTA HA LONG STRATEGY | $symbol | $TimeFrame | WS ${RefreshMs}ms" -ForegroundColor Green
                Format-CandleTable -Candles $ha -Show $CandlesToShow -Label 'HA'

                $posStatus = if ($script:LongInPosition) { "IN POSITION @ $($script:LongEntryPrice)" } else { "WAITING" }
                $posColor  = if ($script:LongInPosition) { 'Green' } else { 'DarkGray' }
                Write-Host ""
                Write-Host "  Status: $posStatus | Trades: $($script:LongTradeCount) | Total PnL: $($script:LongTotalPnL.ToString('N2'))" -ForegroundColor $posColor

                if ($script:LongInPosition) {
                    $unrealized = $ltp - $script:LongEntryPrice
                    $uColor = if ($unrealized -ge 0) { 'Green' } else { 'Red' }
                    Write-Host "  Unrealized: $($unrealized.ToString('N2')) | LTP: $ltp" -ForegroundColor $uColor
                }

                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $symbol @ $ltp | WS streaming" -ForegroundColor DarkGray
            }
        }
    } finally {
        try { $ws.Dispose() } catch {}
    }

        # Auto-reconnect
        Write-Host "  WebSocket dropped. Reconnecting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    } # end while ($true) reconnect loop
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Invoke-DeltaHAShortStrategy  (WebSocket streaming)
# Heikin-Ashi Short-only strategy — signals on RUNNING candle
# Entry: current HA Close < previous HA Low
# Exit:  current HA Close > previous HA High
# ══════════════════════════════════════════════════════════════

function Invoke-DeltaHAShortStrategy {
    param(
        [string]$TradingSymbol = 'BTCUSD',
        [string]$TimeFrame     = '3m',
        [int]$CandlesToShow    = 10,
        [int]$RefreshMs        = 100,
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$OrdersFolder,
        [switch]$ListSymbols
    )

    if ($ListSymbols) { Show-DeltaPresets; return }

    $preset    = Resolve-DeltaSymbol $TradingSymbol
    $resSec    = Get-ResolutionSeconds $TimeFrame
    $symbol    = $preset.Symbol
    $wsChannel = "candlestick_$TimeFrame"

    if (-not (Test-Path $OrdersFolder)) { New-Item -ItemType Directory -Path $OrdersFolder -Force | Out-Null }

    $script:ShortInPosition = $false
    $script:ShortEntryPrice = 0
    $script:ShortEntryTime  = ''
    $script:ShortTotalPnL   = 0
    $script:ShortTradeCount = 0

    # Restore position state
    $posFile = Join-Path $OrdersFolder 'Short-Position.json'
    if (Test-Path $posFile) {
        $saved = Get-Content $posFile -Raw | ConvertFrom-Json
        $script:ShortInPosition = $true
        $script:ShortEntryPrice = $saved.Price
        $script:ShortEntryTime  = $saved.Time
        $script:ShortTotalPnL   = if ($saved.TotalPnL) { $saved.TotalPnL } else { 0 }
        Write-Host "  Restored Short position: Entry=$($script:ShortEntryPrice) at $($script:ShortEntryTime)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  DELTA HA SHORT STRATEGY | $symbol | $TimeFrame | WS ${RefreshMs}ms" -ForegroundColor Red
    Write-Host "  Signals on RUNNING candle (real-time)" -ForegroundColor Red
    Write-Host "  Entry: HA Close < prev HA Low | Exit: HA Close > prev HA High" -ForegroundColor Red
    Write-Host "  Signal folder: $OrdersFolder" -ForegroundColor Red
    Write-Host "  ═══════════════════════════════════════════════════════════" -ForegroundColor Red

    # Bootstrap
    $now   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $start = $now - ($resSec * ($CandlesToShow + 15))
    $restCandles = Get-DeltaCandles -Symbol $symbol -Resolution $TimeFrame -Start $start -End $now

    $candleMap = [ordered]@{}
    if ($restCandles) {
        foreach ($c in ($restCandles | Sort-Object { $_.time })) {
            $candleMap[[int64]$c.time] = [PSCustomObject]@{ time=[int64]$c.time; open=[double]$c.open; high=[double]$c.high; low=[double]$c.low; close=[double]$c.close; volume=0 }
        }
    }
    Write-Host "  Bootstrapped $($candleMap.Count) candles from REST" -ForegroundColor DarkGray

    # Connect WebSocket (with auto-reconnect)
    $buffer      = New-Object byte[] 32768
    $lastRedraw  = [DateTime]::MinValue
    $ltp         = if ($candleMap.Count -gt 0) { [double](@($candleMap.Values)[-1].close) } else { 0 }
    $signalFired = $false
    $wsTickReceived = $false

    while ($true) {
        Write-Host "  Connecting WebSocket to $wsChannel..." -ForegroundColor Yellow
        $ws = New-DeltaStreamWebSocket -Channels @($wsChannel) -Symbols @($symbol)
        if (-not $ws) {
            Write-Host "  WebSocket failed. Retrying in 3s..." -ForegroundColor Red
            Start-Sleep -Seconds 3
            continue
        }
        Write-Host "  WebSocket connected - streaming live" -ForegroundColor Green

    try {
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $data = Receive-DeltaWsMessage -Ws $ws -Buffer $buffer -TimeoutMs $RefreshMs

            # WS fields: o=open, h=high, l=low, c=close, cst=candle_start (microseconds), v=volume
            if ($data -and $data.cst -and $null -ne $data.o) {
                $t = [int64]($data.cst / 1000000)
                $candleMap[$t] = [PSCustomObject]@{ time=$t; open=[double]$data.o; high=[double]$data.h; low=[double]$data.l; close=[double]$data.c; volume=[double]$data.v }
                $ltp = [double]$data.c
                $signalFired = $false
                $wsTickReceived = $true
            }

            $checkSignals = ($candleMap.Count -ge 3 -and -not $signalFired -and $wsTickReceived)

            if ($checkSignals) {
            $arr = @($candleMap.Values) | Sort-Object { $_.time }
            $ha  = ConvertTo-HeikinAshi -Candles $arr

            if ($ha.Count -ge 2) {

            $latestHA = $ha[-1]
            $prevHA   = $ha[-2]

            # ── SHORT ENTRY: HA Close < previous HA Low ──
            if (-not $script:ShortInPosition) {
                if ($latestHA.Close -lt $prevHA.Low) {
                    $ts       = (Get-Date).ToString('HH:mm:ss')
                    $fileName = "Short-Entry-$($ts.Replace(':','-')).txt"
                    $filePath = Join-Path $OrdersFolder $fileName

                    "SHORT ENTRY | $symbol | HA Close $($latestHA.Close) < prev HA Low $($prevHA.Low) | LTP: $ltp | $ts" |
                        Set-Content $filePath -Force

                    $script:ShortInPosition = $true
                    $script:ShortEntryPrice = $ltp
                    $script:ShortEntryTime  = $ts
                    $script:ShortTradeCount++
                    $signalFired = $true

                    @{ Price=$script:ShortEntryPrice; Time=$script:ShortEntryTime; Symbol=$symbol; TotalPnL=$script:ShortTotalPnL } |
                        ConvertTo-Json | Set-Content $posFile -Force

                    Write-Host ""
                    Write-Host "  [$ts] ▼ SHORT ENTRY | HA Close $($latestHA.Close) < prev Low $($prevHA.Low) | LTP: $ltp" -ForegroundColor Red
                }
            }

            # ── SHORT EXIT: HA Close > previous HA High ──
            if ($script:ShortInPosition -and -not $signalFired) {
                if ($latestHA.Close -gt $prevHA.High) {
                    $ts       = (Get-Date).ToString('HH:mm:ss')
                    $fileName = "Short-Exit-$($ts.Replace(':','-')).txt"
                    $filePath = Join-Path $OrdersFolder $fileName

                    $tradePnL = $script:ShortEntryPrice - $ltp
                    $script:ShortTotalPnL += $tradePnL

                    "SHORT EXIT | $symbol | HA Close $($latestHA.Close) > prev HA High $($prevHA.High) | LTP: $ltp | PnL: $($tradePnL.ToString('N2')) | $ts" |
                        Set-Content $filePath -Force

                    $pnlColor = if ($tradePnL -ge 0) { 'Green' } else { 'Red' }
                    Write-Host ""
                    Write-Host "  [$ts] ▲ SHORT EXIT | HA Close $($latestHA.Close) > prev High $($prevHA.High) | LTP: $ltp | PnL: $($tradePnL.ToString('N2'))" -ForegroundColor $pnlColor

                    $script:ShortInPosition = $false
                    $script:ShortEntryPrice = 0
                    $script:ShortEntryTime  = ''
                    $signalFired = $true
                    Remove-Item $posFile -Force -ErrorAction SilentlyContinue
                }
            }

            } # end if ($ha.Count -ge 2)
            } # end if ($checkSignals)

            # Build HA for display (always, even before WS tick)
            if ($candleMap.Count -ge 2) {
                $arr = @($candleMap.Values) | Sort-Object { $_.time }
                $ha  = ConvertTo-HeikinAshi -Candles $arr
            }

            # Redraw display
            $nowDt = [DateTime]::UtcNow
            if (($nowDt - $lastRedraw).TotalMilliseconds -ge 250) {
                $lastRedraw = $nowDt

                try { Clear-Host } catch {}
                Write-Host ""
                Write-Host "  DELTA HA SHORT STRATEGY | $symbol | $TimeFrame | WS ${RefreshMs}ms" -ForegroundColor Red
                Format-CandleTable -Candles $ha -Show $CandlesToShow -Label 'HA'

                $posStatus = if ($script:ShortInPosition) { "IN POSITION @ $($script:ShortEntryPrice)" } else { "WAITING" }
                $posColor  = if ($script:ShortInPosition) { 'Red' } else { 'DarkGray' }
                Write-Host ""
                Write-Host "  Status: $posStatus | Trades: $($script:ShortTradeCount) | Total PnL: $($script:ShortTotalPnL.ToString('N2'))" -ForegroundColor $posColor

                if ($script:ShortInPosition) {
                    $unrealized = $script:ShortEntryPrice - $ltp
                    $uColor = if ($unrealized -ge 0) { 'Green' } else { 'Red' }
                    Write-Host "  Unrealized: $($unrealized.ToString('N2')) | LTP: $ltp" -ForegroundColor $uColor
                }

                Write-Host "  [$(Get-Date -Format 'HH:mm:ss.fff')] $symbol @ $ltp | WS streaming" -ForegroundColor DarkGray
            }
        }
    } finally {
        try { $ws.Dispose() } catch {}
    }

        # Auto-reconnect
        Write-Host "  WebSocket dropped. Reconnecting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    } # end while ($true) reconnect loop
}

# ══════════════════════════════════════════════════════════════
# OPTION HELPERS
# ══════════════════════════════════════════════════════════════

function Get-DeltaOptionChain {
    param(
        [string]$UnderlyingAsset = 'BTC',
        [string]$ContractType,
        [string]$ExpiryDate
    )

    $q = @{ underlying_asset_symbols = $UnderlyingAsset }
    if ($ContractType) {
        $q.contract_types = $ContractType
    } else {
        $q.contract_types = 'call_options,put_options'
    }
    if ($ExpiryDate) { $q.expiry_date = $ExpiryDate }

    $r = Invoke-DeltaApi -Method GET -Endpoint '/tickers' -Query $q -Public
    if ($r -and $r.success) { return $r.result }
    return @()
}

function Get-DeltaOptionProducts {
    param(
        [string]$ContractType = 'call_options',
        [string]$States       = 'live'
    )
    $products = Get-DeltaProducts -ContractTypes $ContractType -States $States
    return $products
}

function Get-DeltaNearestExpiry {
    param(
        [string]$UnderlyingAsset = 'BTC',
        [string]$ContractType    = 'call_options'
    )

    $products = Get-DeltaProducts -ContractTypes $ContractType -States 'live'
    if (-not $products) { return $null }

    # Filter by underlying asset and find nearest expiry
    $filtered = $products | Where-Object {
        $_.symbol -match "^[CP]-${UnderlyingAsset}-"
    } | Sort-Object { $_.settlement_time }

    if ($filtered -and $filtered.Count -gt 0) {
        # Extract expiry from first product's settlement_time
        $nearest = $filtered[0]
        # Parse expiry from symbol: C-BTC-90000-310125 -> 310125 -> 31-01-2025
        if ($nearest.symbol -match '-(\d{6})$') {
            $expiryStr = $Matches[1]
            $day   = $expiryStr.Substring(0, 2)
            $month = $expiryStr.Substring(2, 2)
            $year  = '20' + $expiryStr.Substring(4, 2)
            return "$day-$month-$year"
        }
    }
    return $null
}

function Get-DeltaATMOption {
    param(
        [double]$SpotPrice,
        [string]$UnderlyingAsset = 'BTC',
        [string]$OptionType      = 'call_options',
        [string]$ExpiryDate,
        [int]$Offset             = 0
    )

    if (-not $ExpiryDate) {
        $ExpiryDate = Get-DeltaNearestExpiry -UnderlyingAsset $UnderlyingAsset -ContractType $OptionType
        if (-not $ExpiryDate) {
            Write-Host "  Could not determine nearest expiry for $UnderlyingAsset" -ForegroundColor Red
            return $null
        }
    }

    $chain = Get-DeltaOptionChain -UnderlyingAsset $UnderlyingAsset -ContractType $OptionType -ExpiryDate $ExpiryDate
    if (-not $chain -or $chain.Count -eq 0) {
        Write-Host "  No options found for $UnderlyingAsset expiry $ExpiryDate" -ForegroundColor Red
        return $null
    }

    # Extract strikes and find ATM
    $options = @()
    foreach ($opt in $chain) {
        if ($opt.strike_price) {
            $strike = [double]$opt.strike_price
            $options += [PSCustomObject]@{
                Symbol     = $opt.symbol
                ProductId  = $opt.product_id
                Strike     = $strike
                MarkPrice  = if ($opt.mark_price) { [double]$opt.mark_price } else { 0 }
                LTP        = if ($opt.close) { [double]$opt.close } else { 0 }
                Distance   = [Math]::Abs($strike - $SpotPrice)
            }
        }
    }

    if ($options.Count -eq 0) {
        Write-Host "  No options with strike prices found" -ForegroundColor Red
        return $null
    }

    # Sort by distance to spot price
    $sorted = $options | Sort-Object Distance
    $idx    = [Math]::Min($Offset, $sorted.Count - 1)

    return $sorted[$idx]
}

# ══════════════════════════════════════════════════════════════
# WebSocket connection for live streaming (advanced)
# ══════════════════════════════════════════════════════════════

function Connect-DeltaPublicWebSocket {
    param(
        [string[]]$Channels,
        [string[]]$Symbols,
        [scriptblock]$OnMessage
    )

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = [System.Uri]::new($script:WsPublicUrl)

    try {
        $cts = New-Object System.Threading.CancellationTokenSource
        $ws.ConnectAsync($uri, $cts.Token).Wait(10000)
    } catch {
        Write-Host "  WebSocket connection failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        Write-Host "  WebSocket not connected" -ForegroundColor Red
        return $null
    }

    # Subscribe
    $channelList = @()
    for ($i = 0; $i -lt $Channels.Count; $i++) {
        $channelList += @{
            name    = $Channels[$i]
            symbols = $Symbols
        }
    }

    $subscribeMsg = @{
        type    = 'subscribe'
        payload = @{ channels = $channelList }
    } | ConvertTo-Json -Compress -Depth 5

    $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($subscribeMsg)
    $segment   = [System.ArraySegment[byte]]::new($sendBytes)
    $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(5000)

    Write-Host "  WebSocket connected and subscribed" -ForegroundColor Green

    # Receive loop
    $buffer = New-Object byte[] 16384
    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            $result = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), [System.Threading.CancellationToken]::None).Result
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                Write-Host "  WebSocket closed by server" -ForegroundColor Yellow
                break
            }
            $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            $data    = $message | ConvertFrom-Json
            if ($OnMessage) { & $OnMessage $data }
        } catch {
            Write-Host "  WebSocket receive error: $($_.Exception.Message)" -ForegroundColor Red
            break
        }
    }

    try { $ws.Dispose() } catch {}
}

function Connect-DeltaPrivateWebSocket {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string[]]$Channels,
        [string[]]$Symbols,
        [scriptblock]$OnMessage
    )

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = [System.Uri]::new($script:WsPrivateUrl)

    try {
        $cts = New-Object System.Threading.CancellationTokenSource
        $ws.ConnectAsync($uri, $cts.Token).Wait(10000)
    } catch {
        Write-Host "  Private WebSocket connection failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    # Authenticate
    $timestamp     = [string][int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $signatureData = 'GET' + $timestamp + '/live'
    $signature     = New-DeltaSignature -Secret $ApiSecret -Message $signatureData

    $authMsg = @{
        type    = 'key-auth'
        payload = @{
            'api-key'   = $ApiKey
            signature   = $signature
            timestamp   = $timestamp
        }
    } | ConvertTo-Json -Compress -Depth 5

    $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($authMsg)
    $ws.SendAsync([System.ArraySegment[byte]]::new($sendBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(5000)

    # Wait for auth response
    $buffer = New-Object byte[] 8192
    $result = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), [System.Threading.CancellationToken]::None).Result
    $authResponse = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count) | ConvertFrom-Json

    if (-not $authResponse.success) {
        Write-Host "  WebSocket auth failed: $($authResponse.status)" -ForegroundColor Red
        $ws.Dispose()
        return $null
    }
    Write-Host "  Private WebSocket authenticated" -ForegroundColor Green

    # Subscribe to private channels
    if ($Channels) {
        $channelList = @()
        foreach ($ch in $Channels) {
            $channelList += @{ name = $ch; symbols = $Symbols }
        }
        $subscribeMsg = @{
            type    = 'subscribe'
            payload = @{ channels = $channelList }
        } | ConvertTo-Json -Compress -Depth 5

        $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($subscribeMsg)
        $ws.SendAsync([System.ArraySegment[byte]]::new($sendBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(5000)
    }

    # Receive loop
    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            $result  = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), [System.Threading.CancellationToken]::None).Result
            $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            $data    = $message | ConvertFrom-Json
            if ($OnMessage) { & $OnMessage $data }
        } catch {
            Write-Host "  WebSocket error: $($_.Exception.Message)" -ForegroundColor Red
            break
        }
    }
    try { $ws.Dispose() } catch {}
}

# ── Module Exports ──────────────────────────────────────────
Export-ModuleMember -Function `
    New-DeltaSignature, Invoke-DeltaApi, `
    Get-DeltaProducts, Get-DeltaProductBySymbol, `
    Get-DeltaTicker, Get-DeltaTickers, Get-DeltaSpotPrice, `
    Get-DeltaCandles, Get-DeltaOrderbook, `
    Place-DeltaOrder, Edit-DeltaOrder, Remove-DeltaOrder, Remove-DeltaAllOrders, `
    Get-DeltaActiveOrders, Get-DeltaPositions, Get-DeltaPosition, `
    Close-DeltaAllPositions, Get-DeltaWalletBalances, Set-DeltaLeverage, `
    ConvertTo-HeikinAshi, Format-CandleTable, Get-ResolutionSeconds, `
    Show-DeltaPresets, Resolve-DeltaSymbol, `
    Get-DeltaLiveCandles, Get-DeltaHeikinAshiCandles, `
    Invoke-DeltaHALongStrategy, Invoke-DeltaHAShortStrategy, `
    Get-DeltaOptionChain, Get-DeltaOptionProducts, Get-DeltaNearestExpiry, Get-DeltaATMOption, `
    New-DeltaStreamWebSocket, Receive-DeltaWsMessage, `
    Connect-DeltaPublicWebSocket, Connect-DeltaPrivateWebSocket
