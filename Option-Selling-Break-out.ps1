<#
.SYNOPSIS
    Regular-candle intraday breakout OPTION-SELLING bot for Zerodha Kite (NIFTY/index options).
    All trading parameters are read from input.json; no values are hard-coded.

.DESCRIPTION
    ENTRY LOGIC (intra-candle breakout, evaluated live on every websocket tick):
      The current forming candle's live close (= latest LTP) is compared against the
      PREVIOUS completed candle's High/Low:
        * LONG (bullish)  : forming Close > previous candle High  ->  SHORT PE (sell put)
        * SHORT (bearish) : forming Close < previous candle Low   ->  SHORT CE (sell call)
      i.e. a bullish breakout SELLS a put and a bearish breakdown SELLS a call
      (premium-collection / option-writing). This is the mirror of the option-buying bot.

    ENTRY GATES (all must pass before an order is placed):
        1. Time is inside the [StartTime, StopTime] trading window.
        2. The target side is FLAT per /orders  (net COMPLETE BUY - SELL qty = 0).
        3. Second confirmation: /portfolio/positions ALSO shows that side flat
           (Confirm-Flat), guarding against a false-empty /orders read.
      After a SELL-to-open is accepted, Enter BLOCKS up to 30s polling /orders until the
      short fill is confirmed COMPLETE, so a single breakout cannot fire duplicate entries.

    POSITION SIZING:
        * AmountToTrade > 0  -> lots = floor(AmountToTrade / (optionLTP * lotSize)), min 1 (dynamic).
        * AmountToTrade = 0  -> uses NoOfLotsPurchaseAtaTime (fixed).
        quantity = lots * lotSize.
        NOTE: selling options requires margin; size accordingly.

    EXIT / STOP-AND-REVERSE (ExitTrade in input.json):
        * ExitTrade = 'yes' : on an opposite-side signal, the running SHORT is closed
                              first (its resting stop-losses are cancelled, then a market
                              BUY buys it back) BEFORE the new reverse entry is taken.
        * ExitTrade = 'no'  : Close() is a no-op - existing positions are never auto-closed.
                              Entries are unaffected.

    RUNNING-POSITION SOURCE:
        A short is a NET SELL: per symbol net = (COMPLETE BUY - COMPLETE SELL) filled qty.
        net < 0  => an open short lot (RunningQuantity = |net|).
        PRIMARY  = /orders   (stable under load).
        CONFIRM  = /portfolio/positions (short shows as a negative quantity).
        Bullish view holds PE (short put) -> "Up" trend; bearish view holds CE (short call) -> "Down" trend.

    DATA FEED:
        Kite websocket (wss://ws.kite.trade) streams LTP ticks bucketed into fixed-interval
        candles (TimeFrame in input.json, e.g. 'minute' = 60s).

    REQUIREMENTS:
        KiteData.psm1, input.json, accesstoken.json, and PlacedOrders\Position.json.
        The machine's PUBLIC IP must be whitelisted in the Kite developer console,
        otherwise order POSTs return HTTP 403 PermissionException (market data still works).

.NOTES
    Places REAL orders against the live account. Ctrl+C to stop.
#>
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $dir 'KiteData.psm1') -Force -WarningAction SilentlyContinue
$cfg = Get-Content (Join-Path $dir 'input.json') | ConvertFrom-Json
$at  = Get-Content (Join-Path $dir 'accesstoken.json') | ConvertFrom-Json
$key = $at.api_key; $acc = $at.access_token
$hdr = @{ Authorization="token ${key}:${acc}"; 'X-Kite-Version'='3' }

# --- All trading inputs read from input.json ---
$IndexChoosen = $cfg.IndexChoosen
$Lots         = [int]$cfg.NoOfLotsPurchaseAtaTime
$Amount       = [double]$cfg.AmountToTrade
$ATMOffset    = [int]$cfg.ATMOffset
$OffLbl       = if($ATMOffset -gt 0){"ITM$ATMOffset"}elseif($ATMOffset -lt 0){"OTM$([Math]::Abs($ATMOffset))"}else{'ATM'}
$Product      = $cfg.Product
$OrderType    = $cfg.Order_type
$Variety      = $cfg.Variety
$MktProt      = [int]$cfg.MarketProtection
$ExitTrade    = $cfg.ExitTrade
$StartTime    = [datetime]::Parse($cfg.StartTime)
$StopTime     = [datetime]::Parse($cfg.StopTime)

# SUBSCRIPTION (trading-decision feed): driven by TradingSymbol in input.json. Index names (e.g. Nifty)
# resolve via the preset table; any other tradable symbol (e.g. an option contract) uses its InstrumentToken.
$preset = Resolve-KiteSymbol $cfg.TradingSymbol
if($preset){ $tok = [int]$preset.Token }
elseif([int]$cfg.InstrumentToken -gt 0){ $tok = [int]$cfg.InstrumentToken }
else{ Write-Host "  ERROR: TradingSymbol '$($cfg.TradingSymbol)' not in preset table and InstrumentToken is 0. Cannot subscribe." -f Red; exit 1 }
# STRIKE SELECTION only (independent of the subscription above): IndexChoosen drives the option chain.
$ix  = Get-IndexOptionConfig $IndexChoosen $Lots
$ce  = Get-KiteOptionInstruments $ix.OptExchange $ix.SearchKeyWord 'CE' $hdr
$pe  = Get-KiteOptionInstruments $ix.OptExchange $ix.SearchKeyWord 'PE' $hdr
$sec = @{'5second'=5;'15second'=15;'30second'=30;'minute'=60;'2minute'=120;'5minute'=300;'10minute'=600;'15minute'=900;'30minute'=1800;'60minute'=3600}[$cfg.TimeFrame] ?? 300
$pf  = Join-Path $dir 'PlacedOrders\Position.json'

function I16($b,$p){([int]$b[$p]-shl 8)-bor[int]$b[$p+1]}
function I32($b,$p){[int](([uint32]$b[$p]-shl 24)-bor([uint32]$b[$p+1]-shl 16)-bor([uint32]$b[$p+2]-shl 8)-bor[uint32]$b[$p+3])}
function Ticks($b,$l){$t=@();if($l -lt 4){return $t};$c=I16 $b 0;$o=2;for($i=0;$i -lt $c;$i++){if(($o+2)-gt $l){break};$s=I16 $b $o;$o+=2;if($s -lt 4 -or ($o+$s)-gt $l){break};$t+=@{Tok=I32 $b $o;LTP=(I32 $b ($o+4))/100.0};$o+=$s};$t}
function Spot{(Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$($ix.SpotQuoteKey)" -Headers $hdr -EA 0).data.($ix.SpotQuoteKey).last_price}
function OptLTP($sym){try{(Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([uri]::EscapeDataString("$($ix.OptExchange):$sym"))" -Headers $hdr -EA Stop).data.PSObject.Properties.Value.last_price}catch{0}}
function ATM($sp,$ot){$d=if($ot -eq 'CE'){$ce}else{$pe};$srt=$d.Strikes|Sort-Object;$a=$srt|Sort-Object{[Math]::Abs($_-$sp)}|Select-Object -First 1;$ai=[array]::IndexOf($srt,$a);$off=if($ot -eq 'CE'){-$ATMOffset}else{$ATMOffset};$i=[Math]::Max(0,[Math]::Min($ai+$off,$srt.Count-1));($d.Options|Where-Object{$_.Strike -eq $srt[$i]}).Symbol}
function Order($ty,$sym,$qty){Write-Host "[$(Get-Date -f HH:mm:ss)] $ty $sym x$qty" -f Cyan;$bd=@{tradingsymbol=$sym;exchange=$ix.exchange;transaction_type=$ty;order_type=$OrderType;quantity=$qty;product=$Product;validity='DAY';market_protection=$MktProt};try{$r=Invoke-RestMethod "https://api.kite.trade/orders/$Variety" -Method Post -Headers $hdr -Body $bd -EA Stop;if($r.status -eq 'success'){Write-Host "  ok $($r.data.order_id)" -f Green;return $true}}catch{Write-Host "  fail $_" -f Red};$false}
# ONE API call -> every open position, classified into UPTrend (short PE) / DownTrend (short CE) with running quantity.
# A short shows as a NEGATIVE quantity; only negative-qty positions count. Returns $null when the API errors so the
# caller can `continue` and skip the tick.
function Open-Positions{
    try{ $resp = Invoke-RestMethod "https://api.kite.trade/portfolio/positions" -Headers $hdr -Method Get -EA Stop }catch{ return $null }
    if($null -eq $resp -or $null -eq $resp.data){ return $null }   # no/empty response -> unreliable
    $net = @($resp.data.net)                                        # empty array = genuinely flat (valid)
    $upSyms='';$upQty=0;$upTok=$null;$dnSyms='';$dnQty=0;$dnTok=$null
    foreach($p in $net){
        if($null -eq $p){continue}
        $q=[int]$p.quantity
        if($q -ge 0){continue}                                      # shorts are negative; skip flat/long
        $sq=[Math]::Abs($q)
        if($p.tradingsymbol -like '*PE'){$upSyms+="$($p.tradingsymbol),";$upQty+=$sq;$upTok=$p.instrument_token}   # short PE = bullish/Up
        elseif($p.tradingsymbol -like '*CE'){$dnSyms+="$($p.tradingsymbol),";$dnQty+=$sq;$dnTok=$p.instrument_token} # short CE = bearish/Down
    }
    $maxQty=$Lots*$ix.Lot
    [PSCustomObject]@{
        Up   = [PSCustomObject]@{Source='Positions';Type='UPTrend';  TradingSymbols=$upSyms.Trim(',');Running=($upQty -gt 0);RunningQuantity=$upQty;MaxQuantityReached=($upQty -ge $maxQty);instrument_token=$upTok}
        Down = [PSCustomObject]@{Source='Positions';Type='DownTrend';TradingSymbols=$dnSyms.Trim(',');Running=($dnQty -gt 0);RunningQuantity=$dnQty;MaxQuantityReached=($dnQty -ge $maxQty);instrument_token=$dnTok}
    }
}
# PRIMARY running source: derived from /orders (more stable than /portfolio/positions under load).
# Per symbol: (COMPLETE BUY filled qty) - (COMPLETE SELL filled qty). net<0 => a filled SELL-to-open with no matching
# BUY-back => still a RUNNING short. Same Up/Down shape as Open-Positions. Returns $null on API error / no usable response.
function Open-Orders{
    try{ $resp = Invoke-RestMethod "https://api.kite.trade/orders" -Headers $hdr -Method Get -EA Stop }catch{ return $null }
    if($null -eq $resp -or $null -eq $resp.data){ return $null }
    $orders = @($resp.data)
    $net = @{}          # sym -> net qty (COMPLETE BUY - SELL); negative = net SHORT
    $sells = @{}        # sym -> list of @{Ts;Qty;Price} for each COMPLETE SELL (used to derive the sold/entry price)
    foreach($o in $orders){
        if($null -eq $o){continue}
        if($o.status -ne 'COMPLETE'){continue}                 # only fully-completed fills count
        $sym=[string]$o.tradingsymbol; $fq=[int]$o.filled_quantity
        if($fq -le 0){continue}
        if(-not $net.ContainsKey($sym)){$net[$sym]=0}
        if($o.transaction_type -eq 'SELL'){ $net[$sym]-=$fq; if(-not $sells.ContainsKey($sym)){$sells[$sym]=@()}; $sells[$sym]+=@{Ts=[string]$o.order_timestamp;Qty=$fq;Price=[double]$o.average_price} }
        elseif($o.transaction_type -eq 'BUY'){ $net[$sym]+=$fq }
    }
    # sold/entry price of the still-open short lot = qty-weighted avg of the MOST RECENT SELL fills that cover the net short qty
    $entryOf = {
        param($sym,$runQty)
        $sl=@(@($sells[$sym])|Sort-Object Ts)                 # keep as array even for a single SELL (else .Count/indexing break)
        $need=$runQty;$cost=0.0;$got=0
        for($i=$sl.Count-1;$i -ge 0 -and $need -gt 0;$i--){ $take=[Math]::Min($need,[int]$sl[$i].Qty);$cost+=$take*[double]$sl[$i].Price;$got+=$take;$need-=$take }
        if($got -gt 0){[Math]::Round($cost/$got,2)}else{0}
    }
    $upSyms='';$upQty=0;$upCost=0.0;$dnSyms='';$dnQty=0;$dnCost=0.0
    foreach($k in $net.Keys){
        $q=[int]$net[$k]; if($q -ge 0){continue}              # only net SHORT positions
        $sq=[Math]::Abs($q)
        $e=[double](& $entryOf $k $sq)
        if($k -like '*PE'){$upSyms+="$k,";$upQty+=$sq;$upCost+=$e*$sq}       # short PE = bullish/Up
        elseif($k -like '*CE'){$dnSyms+="$k,";$dnQty+=$sq;$dnCost+=$e*$sq}   # short CE = bearish/Down
    }
    $upEntry=if($upQty -gt 0){[Math]::Round($upCost/$upQty,2)}else{0}
    $dnEntry=if($dnQty -gt 0){[Math]::Round($dnCost/$dnQty,2)}else{0}
    $maxQty=$Lots*$ix.Lot
    [PSCustomObject]@{
        Up   = [PSCustomObject]@{Source='Orders';Type='UPTrend';  TradingSymbols=$upSyms.Trim(',');Running=($upQty -gt 0);RunningQuantity=$upQty;EntryPrice=$upEntry;MaxQuantityReached=($upQty -ge $maxQty);instrument_token=$null}
        Down = [PSCustomObject]@{Source='Orders';Type='DownTrend';TradingSymbols=$dnSyms.Trim(',');Running=($dnQty -gt 0);RunningQuantity=$dnQty;EntryPrice=$dnEntry;MaxQuantityReached=($dnQty -ge $maxQty);instrument_token=$null}
    }
}
# SECOND confirmation (only called at entry time, i.e. when /orders shows the side flat): verify /portfolio/positions
# ALSO shows that side flat before entering, to guard against a false-empty. Unknown ($null) -> treat as NOT flat (no entry).
# $ot is the option being SOLD: PE -> Up side (bullish), CE -> Down side (bearish).
function Confirm-Flat($ot){
    $p=Open-Positions
    if($null -eq $p){ return $false }
    $side=if($ot -eq 'PE'){$p.Up}else{$p.Down}
    return (-not $side.Running)
}
function Close($t){
    if($ExitTrade -eq 'no'){return}                # ExitTrade=no -> never close (does not affect entry)
    if(-not $t.Running){return}
    # cancel this trend's resting stop-losses BEFORE the market BUY-back (PE for bullish, CE for bearish) so none are orphaned
    $trendSel=if($t.Type -eq 'UPTrend'){'PE'}else{'CE'}
    Cancel-AllStopLosses -TrendEntrySelection $trendSel -Headers $hdr | Out-Null
    foreach($sym in ($t.TradingSymbols -split ',' | Where-Object{$_})){
        $xp=OptLTP $sym;Order BUY $sym $t.RunningQuantity      # BUY back to close the short
        if($g.Open -and $g.Open.Sym -eq $sym){$pnl=[Math]::Round(($g.Open.Entry-$xp)*$t.RunningQuantity,2);$bk=if($pnl -ge 0){'PROFIT'}else{'LOSS'};$g.Trades=@($g.Trades)+@{ET=$g.Open.ET;Dir=$g.Open.Dir;Entry=$g.Open.Entry;XT=(Get-Date -f 'HH:mm:ss');Exit=$xp;PnL=$pnl;Booked=$bk};$g.Open=$null}
    }
    @{Direction='';Symbol='';Qty=0}|ConvertTo-Json|Set-Content $pf
}
function Enter($d,$ot,$trend){
    if($ExitTrade -eq 'yes'){ $opp=if($ot -eq 'PE'){$trend.Down}else{$trend.Up}; if($opp.Running){ Close $opp } }
    $sym=ATM (Spot) $ot;if(-not $sym){return}
    $ltp=OptLTP $sym
    $lots=if($Amount -gt 0 -and $ltp -gt 0){[int][Math]::Max(1,[Math]::Floor($Amount/($ltp*$ix.Lot)))}else{$Lots}
    $qty=$lots*$ix.Lot
    if(Order SELL $sym $qty){                                   # SELL-to-open (write the option)
        $g.Open=@{ET=(Get-Date -f 'HH:mm:ss');Dir=$d;Sym=$sym;Entry=$ltp;Qty=$qty};@{Direction=$d;Symbol=$sym;Qty=$qty}|ConvertTo-Json|Set-Content $pf
        # BLOCK until the short actually fills (COMPLETE shows in /orders). Prevents duplicate entries during settlement lag:
        # the tick loop cannot fire another signal until /orders confirms this fill.
        $confDeadline=(Get-Date).AddSeconds(30)
        while((Get-Date) -lt $confDeadline){
            $conf=Open-Orders
            if($null -eq $conf){ continue }                          # API error -> retry, don't exit
            $side=if($ot -eq 'PE'){$conf.Up}else{$conf.Down}
            if($side.Running -and $side.RunningQuantity -ge $qty){    # short fill confirmed via /orders
                Write-Host "  filled $sym x$qty confirmed" -f Green
                $g.Trend=$conf
                break
            }
            Start-Sleep -Milliseconds 250                            # gentle poll while waiting for fill
        }
    }
}

try{[Console]::OutputEncoding=[System.Text.Encoding]::UTF8}catch{}
$Sym=([string]$cfg.TradingSymbol).ToUpper()
$WinStr="$($StartTime.ToString('HH:mm'))-$($StopTime.ToString('HH:mm'))"
$cw=@(10,12,12,12,12,5)
$Ttop='   '+'┌'+(($cw|ForEach-Object{'─'*$_}) -join '┬')+'┐'
$Tmid='   '+'├'+(($cw|ForEach-Object{'─'*$_}) -join '┼')+'┤'
$Tbot='   '+'└'+(($cw|ForEach-Object{'─'*$_}) -join '┴')+'┘'
$xw=@(8,5,8,8,8,10)
$Xtop='   '+'┌'+(($xw|ForEach-Object{'─'*$_}) -join '┬')+'┐'
$Xmid='   '+'├'+(($xw|ForEach-Object{'─'*$_}) -join '┼')+'┤'
$Xbot='   '+'└'+(($xw|ForEach-Object{'─'*$_}) -join '┴')+'┘'
$sw=@(7,26,11,9,28)
$Stop='   '+'┌'+(($sw|ForEach-Object{'─'*$_}) -join '┬')+'┐'
$Smid='   '+'├'+(($sw|ForEach-Object{'─'*$_}) -join '┼')+'┤'
$Sbot='   '+'└'+(($sw|ForEach-Object{'─'*$_}) -join '┴')+'┘'
function Ctr($s,$w){$s=[string]$s;$p=$w-$s.Length;if($p -lt 0){return $s.Substring(0,$w)};$l=[int][Math]::Floor($p/2);(' '*$l)+$s+(' '*($p-$l))}
function PC($v){' '+('{0,10:N2}' -f [double]$v)+' '}
$g=@{Sig='(waiting for signal)';Trades=@();Open=$null;Trend=$null;Prev=$null;TrendAt=[datetime]::MinValue}
function Draw($hist,$raw,$ltp,$tbSec){
    Clear-Host
    Write-Host ''
    Write-Host ('   ╔'+('═'*68)+'╗') -f DarkCyan
    Write-Host ('   ║'+(Ctr "$Sym    •    OPTION-SELLING BOT    •    ${sec}s    •    ● LIVE" 68)+'║') -f Red
    Write-Host ('   ╟'+('─'*68)+'╢') -f DarkCyan
    Write-Host ('   ║'+(Ctr "Idx $IndexChoosen     Lots $Lots     Amt $Amount     $OffLbl     $Product     Win $WinStr" 68)+'║') -f Gray
    Write-Host ('   ╚'+('═'*68)+'╝') -f DarkCyan
    Write-Host ''
    Write-Host "   ▸ LAST 5 CANDLES  (${sec}s)" -f DarkYellow
    Write-Host $Ttop -f DarkGray
    Write-Host ('   │'+(Ctr 'Time' 10)+'│'+(Ctr 'Open' 12)+'│'+(Ctr 'High' 12)+'│'+(Ctr 'Low' 12)+'│'+(Ctr 'Close' 12)+'│'+(Ctr '▲▼' 5)+'│') -f Cyan
    Write-Host $Tmid -f DarkGray
    if(@($hist).Count -eq 0){ Write-Host ('   │'+(Ctr 'building first candle...' 63)+'│') -f DarkGray }
    else{ foreach($c in $hist){ $up=$c.C -ge $c.O;$arw=if($up){'▲'}else{'▼'};$clr=if($up){'Green'}else{'Red'};Write-Host ('   │'+(Ctr $c.T 10)+'│'+(PC $c.O)+'│'+(PC $c.H)+'│'+(PC $c.L)+'│'+(PC $c.C)+'│'+(Ctr $arw 5)+'│') -f $clr } }
    Write-Host $Tbot -f DarkGray
    Write-Host ''
    if($raw){ $fu=$raw.C -ge $raw.O;$fc=if($fu){'Green'}else{'Red'};$fa=if($fu){'▲'}else{'▼'};$ft=[timespan]::FromSeconds($tbSec).ToString('hh\:mm\:ss');Write-Host ("   ▸ FORMING   $ft    O {0:N2}   H {1:N2}   L {2:N2}   C {3:N2}     LTP {4:N2} {5}" -f $raw.O,$raw.H,$raw.L,$raw.C,$ltp,$fa) -f $fc }
    Write-Host ''
    $tot=0;foreach($tr in $g.Trades){$tot+=$tr.PnL}
    $tc=if($tot -ge 0){'Green'}else{'Red'}
    Write-Host ("   ▸ TRADES   realized P&L: {0:+#,##0.00;-#,##0.00;0.00}   ({1} closed)" -f $tot,@($g.Trades).Count) -f $tc
    Write-Host ''
    $tr=$g.Trend
    $pv=$g.Prev
    Write-Host "   ▸ PER-TICK SIGNAL STATUS  (Close vs previous candle)" -f DarkYellow
    Write-Host $Stop -f DarkGray
    Write-Host ('   │'+(Ctr 'Side' 7)+'│'+(Ctr 'Condition' 26)+'│'+(Ctr 'Signal' 11)+'│'+(Ctr 'Sold' 9)+'│'+(Ctr 'Running Short' 28)+'│') -f Cyan
    Write-Host $Smid -f DarkGray
    $hp=[bool]($pv -and $raw)
    $cc=if($raw){[Math]::Round($raw.C,2)}else{0}
    $isUp=if($hp){$cc -gt $pv.H}else{$false}
    $upCond=if($hp){"{0} > {1}" -f $cc,[Math]::Round($pv.H,2)}else{'waiting for candle...'}
    $upSig=if($isUp){'▲ SELL PE'}else{'–'}
    $upRun=if($tr -and $tr.Up.Running){"$($tr.Up.TradingSymbols) x$($tr.Up.RunningQuantity)$(if($tr.Up.MaxQuantityReached){' [MAX]'}else{''})"}else{'none'}
    $upEnt=if($tr -and $tr.Up.Running){'{0:N2}' -f $tr.Up.EntryPrice}else{'–'}
    $upClr=if($isUp){'Green'}else{'DarkGray'}
    Write-Host ('   │'+(Ctr 'LONG' 7)+'│'+(Ctr $upCond 26)+'│'+(Ctr $upSig 11)+'│'+(Ctr $upEnt 9)+'│'+(Ctr $upRun 28)+'│') -f $upClr
    $isDn=if($hp){$cc -lt $pv.L}else{$false}
    $dnCond=if($hp){"{0} < {1}" -f $cc,[Math]::Round($pv.L,2)}else{'waiting for candle...'}
    $dnSig=if($isDn){'▼ SELL CE'}else{'–'}
    $dnRun=if($tr -and $tr.Down.Running){"$($tr.Down.TradingSymbols) x$($tr.Down.RunningQuantity)$(if($tr.Down.MaxQuantityReached){' [MAX]'}else{''})"}else{'none'}
    $dnEnt=if($tr -and $tr.Down.Running){'{0:N2}' -f $tr.Down.EntryPrice}else{'–'}
    $dnClr=if($isDn){'Red'}else{'DarkGray'}
    Write-Host ('   │'+(Ctr 'SHORT' 7)+'│'+(Ctr $dnCond 26)+'│'+(Ctr $dnSig 11)+'│'+(Ctr $dnEnt 9)+'│'+(Ctr $dnRun 28)+'│') -f $dnClr
    Write-Host $Sbot -f DarkGray
    Write-Host ''
    Write-Host ("   ● SIGNAL    $($g.Sig)") -f Yellow
    Write-Host ("   ▸ UPDATED   $(Get-Date -f 'HH:mm:ss')      Ctrl+C to stop") -f DarkGray
}

# (re)connect the market-data websocket and subscribe; returns a live ClientWebSocket.
function Connect-WS{
    $w=[System.Net.WebSockets.ClientWebSocket]::new()
    # [void] the Wait() booleans or they leak into the return value, making $ws an array instead of the socket.
    [void]$w.ConnectAsync("wss://ws.kite.trade?api_key=${key}&access_token=${acc}",[Threading.CancellationToken]::None).Wait(10000)
    [void]$w.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes("{`"a`":`"subscribe`",`"v`":[$tok]}"),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)
    $w
}
$ws=Connect-WS

$buf=[byte[]]::new(65536);$tb=0;$raw=$null;$prev=$null;$hist=@();$ltp=0;$lastDraw=[datetime]::MinValue;$lastTrendPoll=[datetime]::MinValue
# Detect any already-open short up front (retry until /orders responds) so it shows before the first candle forms.
for($i=0;$i -lt 10;$i++){ $init=Open-Orders; if($null -ne $init){ $g.Trend=$init; break }; Start-Sleep -Milliseconds 300 }
Draw $hist $raw $ltp $tb
# Stay alive across websocket drops: if the socket leaves Open, dispose and reconnect instead of exiting (would abandon the live short).
while($true){
  try{
    if($ws.State -ne 'Open'){
        try{$ws.Dispose()}catch{}
        Write-Host "  websocket $($ws.State) - reconnecting..." -f Yellow
        try{ $ws=Connect-WS }catch{ Start-Sleep -Seconds 2 }
        continue
    }
    try{
        $rtask=$ws.ReceiveAsync([ArraySegment[byte]]$buf,[Threading.CancellationToken]::None)
        if(-not $rtask.Wait(20000)){ try{$ws.Abort()}catch{}; continue }   # 20s total silence (Kite heartbeats ~1s) = dead socket -> reconnect
        $res=$rtask.Result
        foreach($t in (Ticks $buf $res.Count)){
            if($t.Tok -ne $tok){continue}
            $ltp=$t.LTP;$n=[datetime]::Now;$bk=[int]([Math]::Floor(($n.Hour*3600+$n.Minute*60+$n.Second)/$sec))*$sec;$upd=$false
            if($tb -ne $bk){ if($raw){$prev=$raw;$hist=(@($hist)+@{T=[timespan]::FromSeconds($tb).ToString('hh\:mm\:ss');O=[Math]::Round($raw.O,2);H=[Math]::Round($raw.H,2);L=[Math]::Round($raw.L,2);C=[Math]::Round($raw.C,2)})|Select-Object -Last 5;$upd=$true};$raw=@{O=$ltp;H=$ltp;L=$ltp;C=$ltp};$tb=$bk }
            else{ $raw.H=[Math]::Max($raw.H,$ltp);$raw.L=[Math]::Min($raw.L,$ltp);$raw.C=$ltp }
            $cur=$raw
            # Running check throttled to ~1/s: calling /orders on every tick trips Kite's REST rate limit and
            # starves the display. Between polls reuse the cached trend so candles/redraw keep flowing.
            if(([datetime]::Now-$lastTrendPoll).TotalMilliseconds -gt 1000){ $tp=Open-Orders; if($null -ne $tp){$g.Trend=$tp}; $lastTrendPoll=[datetime]::Now }
            $trend=$g.Trend
            if($null -eq $trend){ continue }
            $g.Prev=$prev
            if($prev -and $cur){
                $inWin=$n.TimeOfDay -ge $StartTime.TimeOfDay -and $n.TimeOfDay -le $StopTime.TimeOfDay
                # LONG breakout -> SELL PE ; SHORT breakdown -> SELL CE. Enter only when that short side is flat per /orders
                # AND /positions second-confirms flat (guards a false-empty).
                if($inWin -and $cur.C -gt $prev.H -and -not $trend.Up.Running -and (Confirm-Flat 'PE')){ $g.Sig="[$($n.ToString('HH:mm:ss'))] LONG  SELL PE  $([Math]::Round($cur.C,2)) > $([Math]::Round($prev.H,2))";Enter LONG PE $trend;$upd=$true }
                elseif($inWin -and $cur.C -lt $prev.L -and -not $trend.Down.Running -and (Confirm-Flat 'CE')){ $g.Sig="[$($n.ToString('HH:mm:ss'))] SHORT SELL CE  $([Math]::Round($cur.C,2)) < $([Math]::Round($prev.L,2))";Enter SHORT CE $trend;$upd=$true }
            }
            if($upd -or ([datetime]::Now-$lastDraw).TotalMilliseconds -gt 700){ Draw $hist $cur $ltp $tb;$lastDraw=[datetime]::Now }
        }
    }catch{Start-Sleep -Milliseconds 200}
  }catch{
    # Supervisor: log any error that escaped the inner loop and keep going so a live short is never abandoned.
    "$([datetime]::Now.ToString('o')) FATAL: $($_ | Out-String)" | Add-Content (Join-Path $dir 'PlacedOrders\bot-fatal.log')
    Start-Sleep -Seconds 1
    try{ if($ws.State -ne 'Open'){ $ws=Connect-WS } }catch{}
  }
}
$ws.Dispose()
