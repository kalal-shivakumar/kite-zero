# HA Long+Short Auto-Trade (minimal). ALL inputs from input.json. LONG: HA Close>prevHigh->BUY CE | SHORT: HA Close<prevLow->BUY PE
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'KiteData.psm1') -Force -WarningAction SilentlyContinue
$config      = Get-Content (Join-Path $scriptDir 'input.json') | ConvertFrom-Json
$auth        = Get-Content (Join-Path $scriptDir 'accesstoken.json') | ConvertFrom-Json
$apiKey      = $auth.api_key
$accessToken = $auth.access_token
$headers     = @{ Authorization = "token ${apiKey}:${accessToken}"; 'X-Kite-Version' = '3' }

# --- Single-instance lock: refuse to start if another bot is already running in a different terminal ---
$lockFile = Join-Path $scriptDir 'PlacedOrders\bot.lock'
if (Test-Path $lockFile) {
    $existingPid = (Get-Content $lockFile -EA 0 | Select-Object -First 1)
    if ($existingPid) { $existingPid = "$existingPid".Trim() }
    if ($existingPid -and $existingPid -ne "$PID" -and (Get-Process -Id ([int]$existingPid) -EA 0)) {
        Write-Host "ANOTHER BOT IS ALREADY RUNNING (PID $existingPid). Exiting to prevent duplicate orders / rejected sells." -f Red
        exit 1
    }
}
"$PID" | Set-Content $lockFile

# --- All trading inputs read from input.json ---
$IndexName        = $config.IndexChoosen
$Lots             = [int]$config.NoOfLotsPurchaseAtaTime
$Amount           = [double]$config.AmountToTrade
$AtmOffset        = [int]$config.ATMOffset
$OffsetLabel      = if($AtmOffset -gt 0){"ITM$AtmOffset"}elseif($AtmOffset -lt 0){"OTM$([Math]::Abs($AtmOffset))"}else{'ATM'}
$Product          = $config.Product
$OrderType        = $config.Order_type
$Variety          = $config.Variety
$MarketProtection = [int]$config.MarketProtection
$ExitTrade        = $config.ExitTrade
$StartTime        = [datetime]::Parse($config.StartTime)
$StopTime         = [datetime]::Parse($config.StopTime)

$instrumentToken  = (Resolve-KiteSymbol $config.TradingSymbol).Token
$indexConfig      = Get-IndexOptionConfig $IndexName $Lots
$callInstruments  = Get-KiteOptionInstruments $indexConfig.OptExchange $indexConfig.SearchKeyWord 'CE' $headers
$putInstruments   = Get-KiteOptionInstruments $indexConfig.OptExchange $indexConfig.SearchKeyWord 'PE' $headers
$timeframeSeconds = @{'5second'=5;'15second'=15;'30second'=30;'minute'=60;'2minute'=120;'5minute'=300;'10minute'=600;'15minute'=900;'30minute'=1800;'60minute'=3600}[$config.TimeFrame] ?? 300
$positionFile     = Join-Path $scriptDir 'PlacedOrders\Position.json'
$state            = if (Test-Path $positionFile) { Get-Content $positionFile | ConvertFrom-Json } else { @{ Direction=''; Symbol=''; Qty=$indexConfig.Quantity } }

function Read-Int16($bytes,$pos){
    ([int]$bytes[$pos] -shl 8) -bor [int]$bytes[$pos+1]
}

function Read-Int32($bytes,$pos){
    [int](
        ([uint32]$bytes[$pos]   -shl 24) -bor
        ([uint32]$bytes[$pos+1] -shl 16) -bor
        ([uint32]$bytes[$pos+2] -shl 8)  -bor
         [uint32]$bytes[$pos+3]
    )
}

function Read-Ticks($bytes,$length){
    $ticks = @()
    if($length -lt 4){ return $ticks }
    $count  = Read-Int16 $bytes 0
    $offset = 2
    for($i=0; $i -lt $count; $i++){
        if(($offset+2) -gt $length){ break }
        $size = Read-Int16 $bytes $offset
        $offset += 2
        if($size -lt 4 -or ($offset+$size) -gt $length){ break }
        $ticks += @{ Tok = Read-Int32 $bytes $offset; LTP = (Read-Int32 $bytes ($offset+4)) / 100.0 }
        $offset += $size
    }
    $ticks
}

function Get-HeikinAshiCandle($raw,$prevHa){
    $haClose = ($raw.O + $raw.H + $raw.L + $raw.C) / 4
    $haOpen  = if($prevHa){ ($prevHa.O + $prevHa.C) / 2 } else { ($raw.O + $raw.C) / 2 }
    @{
        O = $haOpen
        C = $haClose
        H = [Math]::Max($raw.H, [Math]::Max($haOpen,$haClose))
        L = [Math]::Min($raw.L, [Math]::Min($haOpen,$haClose))
    }
}

function Get-SpotPrice{
    (Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$($indexConfig.SpotQuoteKey)" -Headers $headers -EA 0).data.($indexConfig.SpotQuoteKey).last_price
}

function Get-OptionLtp($symbol){
    try{
        (Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([uri]::EscapeDataString("$($indexConfig.OptExchange):$symbol"))" -Headers $headers -EA Stop).data.PSObject.Properties.Value.last_price
    }catch{
        0
    }
}

function Resolve-OptionSymbol($spot,$optionType){
    $instruments   = if($optionType -eq 'CE'){ $callInstruments } else { $putInstruments }
    $sortedStrikes = $instruments.Strikes | Sort-Object
    $nearest       = $sortedStrikes | Sort-Object { [Math]::Abs($_ - $spot) } | Select-Object -First 1
    $nearestIndex  = [array]::IndexOf($sortedStrikes, $nearest)
    $offset        = if($optionType -eq 'CE'){ -$AtmOffset } else { $AtmOffset }
    $targetIndex   = [Math]::Max(0, [Math]::Min($nearestIndex + $offset, $sortedStrikes.Count - 1))
    ($instruments.Options | Where-Object { $_.Strike -eq $sortedStrikes[$targetIndex] }).Symbol
}

function Get-NetPositions{
    try{
        (Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $headers -Method Get -EA Stop).data.net
    }catch{
        @()
    }
}

function Get-PositionQuantity($symbol){
    $pos = Get-NetPositions | Where-Object { $_.tradingsymbol -eq $symbol } | Select-Object -First 1
    if($pos){ [int]$pos.quantity } else { 0 }
}

function Write-TradeLog($action,$symbol,$quantity,$beforeNet,$afterNet,$result){
    $logFile = 'PlacedOrders\trade-log.csv'
    if(-not (Test-Path $logFile)){
        'time,action,symbol,reqQty,beforeNet,afterNet,result' | Set-Content $logFile
    }
    ('{0},{1},{2},{3},{4},{5},{6}' -f (Get-Date -f 'HH:mm:ss'),$action,$symbol,$quantity,$beforeNet,$afterNet,$result) | Add-Content $logFile
}
function Send-Order($transactionType,$symbol,$quantity){
    Write-Host "[$(Get-Date -f HH:mm:ss)] $transactionType $symbol x$quantity" -f Cyan
    $beforeNet = Get-PositionQuantity $symbol
    $targetNet = if($transactionType -eq 'BUY'){ $beforeNet + $quantity } else { $beforeNet - $quantity }
    $body = @{
        tradingsymbol     = $symbol
        exchange          = $indexConfig.exchange
        transaction_type  = $transactionType
        order_type        = $OrderType
        quantity          = $quantity
        product           = $Product
        validity          = 'DAY'
        market_protection = $MarketProtection
    }
    try{
        $response = Invoke-RestMethod "https://api.kite.trade/orders/$Variety" -Method Post -Headers $headers -Body $body -EA Stop
        $orderId = $response.data.order_id
        if(-not $orderId){
            Write-Host "  no order_id returned" -f Red
            Write-TradeLog $transactionType $symbol $quantity $beforeNet $beforeNet 'NO_ORDER_ID'
            return $false
        }
        Write-Host "  placed $orderId - confirming via /positions (net -> $targetNet) ..." -f DarkGray
        for($attempt=0; $attempt -lt 10; $attempt++){
            Start-Sleep -Milliseconds 400
            if((Get-PositionQuantity $symbol) -eq $targetNet){
                Write-Host "  CONFIRMED position net=$targetNet $orderId" -f Green
                Write-TradeLog $transactionType $symbol $quantity $beforeNet $targetNet 'CONFIRMED'
                return $true
            }
        }
        $finalNet = Get-PositionQuantity $symbol
        Write-Host "  NOT confirmed in positions (net=$finalNet target=$targetNet) $orderId" -f Yellow
        Write-TradeLog $transactionType $symbol $quantity $beforeNet $finalNet 'NOT_CONFIRMED'
        return $false
    }catch{
        Write-Host "  fail $_" -f Red
        Write-TradeLog $transactionType $symbol $quantity $beforeNet (Get-PositionQuantity $symbol) 'FAIL'
    }
    $false
}
function Close-Position{
    if(-not $state.Direction){ return }
    $exitPrice = Get-OptionLtp $state.Symbol
    Send-Order SELL $state.Symbol $state.Qty
    if($dashboard.Open){
        $pnl    = [Math]::Round(($exitPrice - $dashboard.Open.Entry) * $state.Qty, 2)
        $booked = if($pnl -ge 0){ 'PROFIT' } else { 'LOSS' }
        $dashboard.Trades = @($dashboard.Trades) + @{
            ET     = $dashboard.Open.ET
            Dir    = $dashboard.Open.Dir
            Entry  = $dashboard.Open.Entry
            XT     = (Get-Date -f 'HH:mm:ss')
            Exit   = $exitPrice
            PnL    = $pnl
            Booked = $booked
        }
        $dashboard.Open = $null
    }
    $state.Direction = ''
    $state.Symbol    = ''
    @{ Direction=''; Symbol=''; Qty=$state.Qty } | ConvertTo-Json | Set-Content $positionFile
}
function Open-Position($direction,$optionType){
    if($state.Direction -and $ExitTrade -eq 'yes'){ Close-Position }
    $symbol = Resolve-OptionSymbol (Get-SpotPrice) $optionType
    if(-not $symbol){ return }
    if((Get-PositionQuantity $symbol) -gt 0){
        Write-Host "  already holding $symbol (net $(Get-PositionQuantity $symbol)) - skip duplicate" -f Yellow
        Write-TradeLog 'BUY' $symbol 0 (Get-PositionQuantity $symbol) (Get-PositionQuantity $symbol) 'SKIP_DUP'
        $state.Direction = $direction
        $state.Symbol    = $symbol
        return
    }
    $ltp      = Get-OptionLtp $symbol
    $lots     = if($Amount -gt 0 -and $ltp -gt 0){ [int][Math]::Max(1, [Math]::Floor($Amount / ($ltp * $indexConfig.Lot))) } else { $Lots }
    $quantity = $lots * $indexConfig.Lot
    if(Send-Order BUY $symbol $quantity){
        $state.Direction = $direction
        $state.Symbol    = $symbol
        $state.Qty       = $quantity
        @{ Direction=$direction; Symbol=$symbol; Qty=$quantity } | ConvertTo-Json | Set-Content $positionFile
        $dashboard.Open = @{
            ET    = (Get-Date -f 'HH:mm:ss')
            Dir   = $direction
            Sym   = $symbol
            Entry = $ltp
            Qty   = $quantity
        }
    }
}

try{ [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 }catch{}
$symbolLabel     = ([string]$config.TradingSymbol).ToUpper()
$windowLabel     = "$($StartTime.ToString('HH:mm'))-$($StopTime.ToString('HH:mm'))"
$candleColWidths = @(10,12,12,12,12,5)
$candleTop       = '   '+'┌'+(($candleColWidths|ForEach-Object{'─'*$_}) -join '┬')+'┐'
$candleMid       = '   '+'├'+(($candleColWidths|ForEach-Object{'─'*$_}) -join '┼')+'┤'
$candleBot       = '   '+'└'+(($candleColWidths|ForEach-Object{'─'*$_}) -join '┴')+'┘'
$tradeColWidths  = @(8,5,8,8,8,10)
$tradeTop        = '   '+'┌'+(($tradeColWidths|ForEach-Object{'─'*$_}) -join '┬')+'┐'
$tradeMid        = '   '+'├'+(($tradeColWidths|ForEach-Object{'─'*$_}) -join '┼')+'┤'
$tradeBot        = '   '+'└'+(($tradeColWidths|ForEach-Object{'─'*$_}) -join '┴')+'┘'

function Format-Centered($text,$width){
    $text = [string]$text
    $pad  = $width - $text.Length
    if($pad -lt 0){ return $text.Substring(0,$width) }
    $left = [int][Math]::Floor($pad/2)
    (' '*$left)+$text+(' '*($pad-$left))
}

function Format-PriceCell($value){
    ' '+('{0,10:N2}' -f [double]$value)+' '
}

$dashboard = @{ Sig='(waiting for signal)'; Trades=@(); Open=$null }

function Show-Dashboard($candles,$formingRaw,$ltp,$bucketStartSec){
    Clear-Host
    Write-Host ''
    Write-Host ('   ╔'+('═'*68)+'╗') -f DarkCyan
    Write-Host ('   ║'+(Format-Centered "$symbolLabel  HEIKIN-ASHI BOT   •   ${timeframeSeconds}s   •   LIVE - REAL ORDERS" 68)+'║') -f Red
    Write-Host ('   ╠'+('═'*68)+'╣') -f DarkCyan
    Write-Host ('   ║'+(Format-Centered "Idx $IndexName | Lots $Lots | Amt $Amount | $OffsetLabel | $Product | Win $windowLabel" 68)+'║') -f Gray
    Write-Host ('   ╚'+('═'*68)+'╝') -f DarkCyan
    Write-Host ''
    Write-Host "   LAST 5 HEIKIN-ASHI CANDLES  (${timeframeSeconds}s)" -f DarkYellow
    Write-Host $candleTop -f DarkGray
    Write-Host ('   │'+(Format-Centered 'Time' 10)+'│'+(Format-Centered 'Open' 12)+'│'+(Format-Centered 'High' 12)+'│'+(Format-Centered 'Low' 12)+'│'+(Format-Centered 'Close' 12)+'│'+(Format-Centered '▲▼' 5)+'│') -f Cyan
    Write-Host $candleMid -f DarkGray
    if(@($candles).Count -eq 0){
        Write-Host ('   │'+(Format-Centered 'building first candle...' 63)+'│') -f DarkGray
    }
    else{
        foreach($candle in $candles){
            $isUp  = $candle.C -ge $candle.O
            $arrow = if($isUp){'▲'}else{'▼'}
            $color = if($isUp){'Green'}else{'Red'}
            Write-Host ('   │'+(Format-Centered $candle.T 10)+'│'+(Format-PriceCell $candle.O)+'│'+(Format-PriceCell $candle.H)+'│'+(Format-PriceCell $candle.L)+'│'+(Format-PriceCell $candle.C)+'│'+(Format-Centered $arrow 5)+'│') -f $color
        }
    }
    Write-Host $candleBot -f DarkGray
    Write-Host ''
    if($formingRaw){
        $isUp       = $formingRaw.C -ge $formingRaw.O
        $color      = if($isUp){'Green'}else{'Red'}
        $bucketTime = [timespan]::FromSeconds($bucketStartSec).ToString('hh\:mm\:ss')
        Write-Host ("   FORMING (HA)  $bucketTime   O {0:N2}  H {1:N2}  L {2:N2}  C {3:N2}   LTP {4:N2}" -f $formingRaw.O,$formingRaw.H,$formingRaw.L,$formingRaw.C,$ltp) -f $color
    }
    Write-Host ''
    $totalPnl = 0
    foreach($trade in $dashboard.Trades){ $totalPnl += $trade.PnL }
    $totalColor = if($totalPnl -ge 0){'Green'}else{'Red'}
    Write-Host ("   TRADES   realized P&L: {0:+#,##0.00;-#,##0.00;0.00}   ({1} closed)" -f $totalPnl,@($dashboard.Trades).Count) -f $totalColor
    Write-Host $tradeTop -f DarkGray
    Write-Host ('   │'+(Format-Centered 'Entry' 8)+'│'+(Format-Centered 'Dir' 5)+'│'+(Format-Centered 'EntryPx' 8)+'│'+(Format-Centered 'ExitPx' 8)+'│'+(Format-Centered 'P&L' 8)+'│'+(Format-Centered 'Booked' 10)+'│') -f Cyan
    Write-Host $tradeMid -f DarkGray
    $recentTrades = @($dashboard.Trades)|Select-Object -Last 5
    foreach($trade in $recentTrades){
        $rowColor = if($trade.PnL -ge 0){'Green'}else{'Red'}
        Write-Host ('   │'+(Format-Centered $trade.ET 8)+'│'+(Format-Centered $trade.Dir 5)+'│'+(Format-Centered ('{0:N2}' -f $trade.Entry) 8)+'│'+(Format-Centered ('{0:N2}' -f $trade.Exit) 8)+'│'+(Format-Centered ('{0:N2}' -f $trade.PnL) 8)+'│'+(Format-Centered $trade.Booked 10)+'│') -f $rowColor
    }
    if($dashboard.Open){
        Write-Host ('   │'+(Format-Centered $dashboard.Open.ET 8)+'│'+(Format-Centered $dashboard.Open.Dir 5)+'│'+(Format-Centered ('{0:N2}' -f $dashboard.Open.Entry) 8)+'│'+(Format-Centered 'OPEN' 8)+'│'+(Format-Centered '...' 8)+'│'+(Format-Centered '-' 10)+'│') -f Yellow
    }
    if(@($recentTrades).Count -eq 0 -and -not $dashboard.Open){
        Write-Host ('   │'+(Format-Centered 'no trades yet' 52)+'│') -f DarkGray
    }
    Write-Host $tradeBot -f DarkGray
    Write-Host ''
    if($state.Direction){
        $posColor = if($state.Direction -eq 'LONG'){'Green'}else{'Red'}
        Write-Host ("   POSITION   {0}  {1}  x{2}" -f $state.Direction,$state.Symbol,$state.Qty) -f $posColor
    }
    else{
        Write-Host '   POSITION   FLAT' -f DarkGray
    }
    Write-Host ("   SIGNAL     $($dashboard.Sig)") -f Yellow
    Write-Host ("   UPDATED     $(Get-Date -f 'HH:mm:ss')   (Ctrl+C to stop)") -f DarkGray
}

function Connect-TickerSocket{
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync("wss://ws.kite.trade?api_key=${apiKey}&access_token=${accessToken}",[Threading.CancellationToken]::None).Wait(10000)
    $socket.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes("{`"a`":`"subscribe`",`"v`":[$instrumentToken]}"),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)
    $socket
}
$socket = Connect-TickerSocket

# Sync state from live broker positions (source of truth) so a restart resumes the running position and never re-buys
$livePosition = Get-NetPositions | Where-Object { [int]$_.quantity -gt 0 -and $_.exchange -eq $indexConfig.OptExchange -and ($_.tradingsymbol -like '*CE' -or $_.tradingsymbol -like '*PE') } | Select-Object -First 1
if($livePosition){
    $state.Direction = if($livePosition.tradingsymbol -like '*CE'){'LONG'}else{'SHORT'}
    $state.Symbol    = $livePosition.tradingsymbol
    $state.Qty       = [int]$livePosition.quantity
    $dashboard.Open  = @{ ET=(Get-Date -f 'HH:mm:ss'); Dir=$state.Direction; Sym=$state.Symbol; Entry=[double]$livePosition.average_price; Qty=$state.Qty }
    @{ Direction=$state.Direction; Symbol=$state.Symbol; Qty=$state.Qty } | ConvertTo-Json | Set-Content $positionFile
    Write-Host "resumed from live position: $($state.Direction) $($state.Symbol) x$($state.Qty)" -f Yellow
}


$buffer     = [byte[]]::new(65536)
$bucket     = 0
$prevHa     = $null
$formingRaw = $null
$prevCandle = $null
$candles    = @()
$ltp        = 0
$lastRender = [datetime]::MinValue
Show-Dashboard $candles $formingRaw $ltp $bucket
while($true){
    while($socket.State -eq 'Open'){
        try{
            $result = $socket.ReceiveAsync([ArraySegment[byte]]$buffer,[Threading.CancellationToken]::None).Result
            foreach($tick in (Read-Ticks $buffer $result.Count)){
                if($tick.Tok -ne $instrumentToken){ continue }
                $ltp = $tick.LTP
                $now = [datetime]::Now
                $currentBucket = [int]([Math]::Floor(($now.Hour*3600+$now.Minute*60+$now.Second)/$timeframeSeconds))*$timeframeSeconds
                $needsRender = $false
                if($bucket -ne $currentBucket){
                    if($formingRaw){
                        $prevHa = Get-HeikinAshiCandle $formingRaw $prevHa
                        $prevCandle = $prevHa
                        $candles = (@($candles)+@{ T=[timespan]::FromSeconds($bucket).ToString('hh\:mm\:ss'); O=[Math]::Round($prevHa.O,2); H=[Math]::Round($prevHa.H,2); L=[Math]::Round($prevHa.L,2); C=[Math]::Round($prevHa.C,2) })|Select-Object -Last 5
                        $needsRender = $true
                    }
                    $formingRaw = @{ O=$ltp; H=$ltp; L=$ltp; C=$ltp }
                    $bucket = $currentBucket
                }
                else{
                    $formingRaw.H = [Math]::Max($formingRaw.H,$ltp)
                    $formingRaw.L = [Math]::Min($formingRaw.L,$ltp)
                    $formingRaw.C = $ltp
                }
                $currentHa = if($formingRaw){ Get-HeikinAshiCandle $formingRaw $prevHa } else { $null }
                if($prevCandle -and $currentHa){
                    $inWindow = $now.TimeOfDay -ge $StartTime.TimeOfDay -and $now.TimeOfDay -le $StopTime.TimeOfDay
                    if($inWindow -and $currentHa.C -gt $prevCandle.H -and $state.Direction -ne 'LONG'){
                        $dashboard.Sig = "[$($now.ToString('HH:mm:ss'))] LONG  $([Math]::Round($currentHa.C,2)) > $([Math]::Round($prevCandle.H,2))"
                        Open-Position LONG CE
                        $needsRender = $true
                    }
                    elseif($inWindow -and $currentHa.C -lt $prevCandle.L -and $state.Direction -ne 'SHORT'){
                        $dashboard.Sig = "[$($now.ToString('HH:mm:ss'))] SHORT $([Math]::Round($currentHa.C,2)) < $([Math]::Round($prevCandle.L,2))"
                        Open-Position SHORT PE
                        $needsRender = $true
                    }
                }
                if($needsRender -or ([datetime]::Now-$lastRender).TotalMilliseconds -gt 700){
                    Show-Dashboard $candles $currentHa $ltp $bucket
                    $lastRender = [datetime]::Now
                }
            }
        }catch{ Start-Sleep -Milliseconds 200 }
    }
    try{ $socket.Dispose() }catch{}
    Write-Host "WebSocket disconnected - reconnecting in 2s..." -f Yellow
    Start-Sleep -Seconds 2
    try{ $socket = Connect-TickerSocket }catch{ Write-Host "  reconnect failed, retrying in 3s..." -f Red; Start-Sleep -Seconds 3 }
}
