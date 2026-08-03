<#
.SYNOPSIS
    Heikin-Ashi intraday Long+Short auto-trade bot for Zerodha Kite (NIFTY/index options).
    Identical trading logic to Regular-Long-Short-Combined-Simple.ps1 - the ONLY difference is
    that signals are computed from Heikin-Ashi candles instead of regular OHLC candles.
    All trading parameters are read from input.json; no values are hard-coded.

.DESCRIPTION
    ENTRY LOGIC (intra-candle breakout, evaluated live on every websocket tick):
      The current forming Heikin-Ashi candle's live HA-Close is compared against the
      PREVIOUS completed HA candle's High/Low:
        * LONG  : forming HA-Close > previous HA candle High  ->  BUY CE (call)
        * SHORT : forming HA-Close < previous HA candle Low   ->  BUY PE (put)

      Heikin-Ashi construction (from the raw tick candle O/H/L/C):
        HA-Close = (O + H + L + C) / 4
        HA-Open  = (previous HA-Open + previous HA-Close) / 2   (seed = (O + C) / 2)
        HA-High  = max(H, HA-Open, HA-Close)
        HA-Low   = min(L, HA-Open, HA-Close)

    ENTRY GATES (all must pass before an order is placed):
        1. Time is inside the [StartTime, StopTime] trading window.
        2. The target side is FLAT per /orders  (net COMPLETE BUY - SELL qty = 0).
        3. Second confirmation: /portfolio/positions ALSO shows that side flat
           (Confirm-Flat), guarding against a false-empty /orders read.
      After a BUY is accepted, Enter BLOCKS up to 30s polling /orders until the fill
      is confirmed COMPLETE, so a single breakout cannot fire duplicate entries.

    POSITION SIZING:
        * AmountToTrade > 0  -> lots = floor(AmountToTrade / (optionLTP * lotSize)), min 1 (dynamic).
        * AmountToTrade = 0  -> uses NoOfLotsPurchaseAtaTime (fixed).
        quantity = lots * lotSize.

    EXIT / STOP-AND-REVERSE (ExitTrade in input.json):
        * ExitTrade = 'yes' : on an opposite-side signal, the running position is closed
                              first (its resting stop-losses are cancelled, then a market
                              SELL squares it off) BEFORE the new reverse entry is taken.
        * ExitTrade = 'no'  : Close() is a no-op - existing positions are never auto-closed.
                              Entries are unaffected.

    RUNNING-POSITION SOURCE:
        PRIMARY  = /orders   (net of COMPLETE BUY - SELL fills per symbol; stable under load).
        CONFIRM  = /portfolio/positions (used only at entry time as a second flat-check).

    DATA FEED:
        Kite websocket (wss://ws.kite.trade) streams LTP ticks that are bucketed into
        fixed-interval raw candles (TimeFrame in input.json, e.g. 'minute' = 60s), which
        are then converted to Heikin-Ashi candles for signal evaluation.

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

# SUBSCRIPTION (trading-decision feed): InstrumentToken wins so ANY instrument (option/future/
# index) can be streamed; fall back to the preset-table name only when InstrumentToken = 0.
$InstrumentToken = [int]$cfg.InstrumentToken
if($InstrumentToken -gt 0){ $tok = $InstrumentToken }
else{
    $preset = Resolve-KiteSymbol $cfg.TradingSymbol
    if(-not $preset){ Write-Host "  ERROR: '$($cfg.TradingSymbol)' not in preset table and InstrumentToken is 0. Cannot subscribe." -f Red; exit 1 }
    $tok = [int]$preset.Token
}
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
# ONE API call -> every open position, classified into UPTrend (CE) / DownTrend (PE) with running quantity.
# Returns $null when the API errors / gives no usable response, so the caller can `continue` and skip the tick.
function Open-Positions{
    try{ $resp = Invoke-RestMethod "https://api.kite.trade/portfolio/positions" -Headers $hdr -Method Get -EA Stop }catch{ return $null }
    if($null -eq $resp -or $null -eq $resp.data){ return $null }   # no/empty response -> unreliable
    $net = @($resp.data.net)                                        # empty array = genuinely flat (valid)
    $upSyms='';$upQty=0;$upTok=$null;$dnSyms='';$dnQty=0;$dnTok=$null
    foreach($p in $net){
        if($null -eq $p){continue}
        $q=[int]$p.quantity
        if($q -le 0){continue}
        if($p.tradingsymbol -like '*CE'){$upSyms+="$($p.tradingsymbol),";$upQty+=$q;$upTok=$p.instrument_token}
        elseif($p.tradingsymbol -like '*PE'){$dnSyms+="$($p.tradingsymbol),";$dnQty+=$q;$dnTok=$p.instrument_token}
    }
    $maxQty=$Lots*$ix.Lot
    [PSCustomObject]@{
        Up   = [PSCustomObject]@{Source='Positions';Type='UPTrend';  TradingSymbols=$upSyms.Trim(',');Running=($upQty -gt 0);RunningQuantity=$upQty;MaxQuantityReached=($upQty -ge $maxQty);instrument_token=$upTok}
        Down = [PSCustomObject]@{Source='Positions';Type='DownTrend';TradingSymbols=$dnSyms.Trim(',');Running=($dnQty -gt 0);RunningQuantity=$dnQty;MaxQuantityReached=($dnQty -ge $maxQty);instrument_token=$dnTok}
    }
}
# PRIMARY running source: derived from /orders (more stable than /portfolio/positions under load - 0 errors at ~14/s in testing).
# Per symbol: (COMPLETE BUY filled qty) - (COMPLETE SELL filled qty). net>0 => a filled BUY with no matching SELL => still RUNNING.
# Same Up/Down shape as Open-Positions. Returns $null on API error / no usable response so the caller can `continue`.
function Open-Orders{
    try{ $resp = Invoke-RestMethod "https://api.kite.trade/orders" -Headers $hdr -Method Get -EA Stop }catch{ return $null }
    if($null -eq $resp -or $null -eq $resp.data){ return $null }
    $orders = @($resp.data)
    $net = @{}          # sym -> net running qty (COMPLETE BUY - SELL)
    $buys = @{}         # sym -> list of @{Ts;Qty;Price} for each COMPLETE BUY (used to derive entry price)
    foreach($o in $orders){
        if($null -eq $o){continue}
        if($o.status -ne 'COMPLETE'){continue}                 # only fully-completed fills count
        $sym=[string]$o.tradingsymbol; $fq=[int]$o.filled_quantity
        if($fq -le 0){continue}
        if(-not $net.ContainsKey($sym)){$net[$sym]=0}
        if($o.transaction_type -eq 'BUY'){ $net[$sym]+=$fq; if(-not $buys.ContainsKey($sym)){$buys[$sym]=@()}; $buys[$sym]+=@{Ts=[string]$o.order_timestamp;Qty=$fq;Price=[double]$o.average_price} }
        elseif($o.transaction_type -eq 'SELL'){ $net[$sym]-=$fq }
    }
    # entry price of the still-open lot = qty-weighted avg of the MOST RECENT BUY fills that cover the net running qty
    $entryOf = {
        param($sym,$runQty)
        $bl=@(@($buys[$sym])|Sort-Object Ts)                 # keep as array even for a single BUY (else .Count/indexing break)
        $need=$runQty;$cost=0.0;$got=0
        for($i=$bl.Count-1;$i -ge 0 -and $need -gt 0;$i--){ $take=[Math]::Min($need,[int]$bl[$i].Qty);$cost+=$take*[double]$bl[$i].Price;$got+=$take;$need-=$take }
        if($got -gt 0){[Math]::Round($cost/$got,2)}else{0}
    }
    $upSyms='';$upQty=0;$upCost=0.0;$dnSyms='';$dnQty=0;$dnCost=0.0
    foreach($k in $net.Keys){
        $q=[int]$net[$k]; if($q -le 0){continue}
        $e=[double](& $entryOf $k $q)
        if($k -like '*CE'){$upSyms+="$k,";$upQty+=$q;$upCost+=$e*$q}
        elseif($k -like '*PE'){$dnSyms+="$k,";$dnQty+=$q;$dnCost+=$e*$q}
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
function Confirm-Flat($ot){
    $p=Open-Positions
    if($null -eq $p){ return $false }
    $side=if($ot -eq 'CE'){$p.Up}else{$p.Down}
    return (-not $side.Running)
}
function Close($t){
    if($ExitTrade -eq 'no'){return}                # ExitTrade=no -> never close (does not affect entry)
    if(-not $t.Running){return}
    # cancel this trend's resting stop-losses BEFORE the market SELL (CE for Long, PE for Short) so none are orphaned
    $trendSel=if($t.Type -eq 'UPTrend'){'CE'}else{'PE'}
    Cancel-AllStopLosses -TrendEntrySelection $trendSel -Headers $hdr | Out-Null
    foreach($sym in ($t.TradingSymbols -split ',' | Where-Object{$_})){
        $xp=OptLTP $sym;Order SELL $sym $t.RunningQuantity
        if($g.Open -and $g.Open.Sym -eq $sym){$pnl=[Math]::Round(($xp-$g.Open.Entry)*$t.RunningQuantity,2);$bk=if($pnl -ge 0){'PROFIT'}else{'LOSS'};$g.Trades=@($g.Trades)+@{ET=$g.Open.ET;Dir=$g.Open.Dir;Entry=$g.Open.Entry;XT=(Get-Date -f 'HH:mm:ss');Exit=$xp;PnL=$pnl;Booked=$bk};$g.Open=$null}
    }
    @{Direction='';Symbol='';Qty=0}|ConvertTo-Json|Set-Content $pf
}
function Enter($d,$ot,$trend){
    if($ExitTrade -eq 'yes'){ $opp=if($ot -eq 'CE'){$trend.Down}else{$trend.Up}; if($opp.Running){ Close $opp } }
    $sym=ATM (Spot) $ot;if(-not $sym){return}
    $ltp=OptLTP $sym
    $lots=if($Amount -gt 0 -and $ltp -gt 0){[int][Math]::Max(1,[Math]::Floor($Amount/($ltp*$ix.Lot)))}else{$Lots}
    $qty=$lots*$ix.Lot
    if(Order BUY $sym $qty){
        $g.Open=@{ET=(Get-Date -f 'HH:mm:ss');Dir=$d;Sym=$sym;Entry=$ltp;Qty=$qty};@{Direction=$d;Symbol=$sym;Qty=$qty}|ConvertTo-Json|Set-Content $pf
        # BLOCK until the order actually fills (COMPLETE shows in /orders). Prevents duplicate entries during settlement lag:
        # the tick loop cannot fire another signal until /orders confirms this fill.
        $confDeadline=(Get-Date).AddSeconds(30)
        while((Get-Date) -lt $confDeadline){
            $conf=Open-Orders
            if($null -eq $conf){ continue }                          # API error -> retry, don't exit
            $side=if($ot -eq 'CE'){$conf.Up}else{$conf.Down}
            if($side.Running -and $side.RunningQuantity -ge $qty){    # fill confirmed via /orders
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
    Write-Host ('   ║'+(Ctr "$Sym    •    HEIKIN-ASHI BOT    •    ${sec}s    •    ● LIVE" 68)+'║') -f Red
    Write-Host ('   ╟'+('─'*68)+'╢') -f DarkCyan
    Write-Host ('   ║'+(Ctr "Idx $IndexChoosen     Lots $Lots     Amt $Amount     $OffLbl     $Product     Win $WinStr" 68)+'║') -f Gray
    Write-Host ('   ╚'+('═'*68)+'╝') -f DarkCyan
    Write-Host ''
    Write-Host "   ▸ LAST 5 HA CANDLES  (${sec}s)" -f DarkYellow
    Write-Host $Ttop -f DarkGray
    Write-Host ('   │'+(Ctr 'Time' 10)+'│'+(Ctr 'HA-Open' 12)+'│'+(Ctr 'HA-High' 12)+'│'+(Ctr 'HA-Low' 12)+'│'+(Ctr 'HA-Close' 12)+'│'+(Ctr '▲▼' 5)+'│') -f Cyan
    Write-Host $Tmid -f DarkGray
    if(@($hist).Count -eq 0){ Write-Host ('   │'+(Ctr 'building first candle...' 63)+'│') -f DarkGray }
    else{ foreach($c in $hist){ $up=$c.C -ge $c.O;$arw=if($up){'▲'}else{'▼'};$clr=if($up){'Green'}else{'Red'};Write-Host ('   │'+(Ctr $c.T 10)+'│'+(PC $c.O)+'│'+(PC $c.H)+'│'+(PC $c.L)+'│'+(PC $c.C)+'│'+(Ctr $arw 5)+'│') -f $clr } }
    Write-Host $Tbot -f DarkGray
    Write-Host ''
    if($raw){ $fu=$raw.C -ge $raw.O;$fc=if($fu){'Green'}else{'Red'};$fa=if($fu){'▲'}else{'▼'};$ft=[timespan]::FromSeconds($tbSec).ToString('hh\:mm\:ss');Write-Host ("   ▸ FORMING HA   $ft    O {0:N2}   H {1:N2}   L {2:N2}   C {3:N2}     LTP {4:N2} {5}" -f $raw.O,$raw.H,$raw.L,$raw.C,$ltp,$fa) -f $fc }
    Write-Host ''
    $tot=0;foreach($tr in $g.Trades){$tot+=$tr.PnL}
    $tc=if($tot -ge 0){'Green'}else{'Red'}
    Write-Host ("   ▸ TRADES   realized P&L: {0:+#,##0.00;-#,##0.00;0.00}   ({1} closed)" -f $tot,@($g.Trades).Count) -f $tc
    Write-Host ''
    $tr=$g.Trend
    $pv=$g.Prev
    Write-Host "   ▸ PER-TICK SIGNAL STATUS  (HA-Close vs previous HA candle)" -f DarkYellow
    Write-Host $Stop -f DarkGray
    Write-Host ('   │'+(Ctr 'Side' 7)+'│'+(Ctr 'Condition' 26)+'│'+(Ctr 'Signal' 11)+'│'+(Ctr 'Entry' 9)+'│'+(Ctr 'Running Position' 28)+'│') -f Cyan
    Write-Host $Smid -f DarkGray
    if($pv -and $raw){
        $cc=[Math]::Round($raw.C,2)
        $isUp=$cc -gt $pv.H
        $upSig=if($isUp){'▲ UPTREND'}else{'–'}
        $upRun=if($tr -and $tr.Up.Running){"$($tr.Up.TradingSymbols) x$($tr.Up.RunningQuantity)$(if($tr.Up.MaxQuantityReached){' [MAX]'}else{''})"}else{'none'}
        $upEnt=if($tr -and $tr.Up.Running){'{0:N2}' -f $tr.Up.EntryPrice}else{'–'}
        $upClr=if($isUp){'Green'}else{'DarkGray'}
        Write-Host ('   │'+(Ctr 'LONG' 7)+'│'+(Ctr ("{0} > {1}" -f $cc,[Math]::Round($pv.H,2)) 26)+'│'+(Ctr $upSig 11)+'│'+(Ctr $upEnt 9)+'│'+(Ctr $upRun 28)+'│') -f $upClr
        $isDn=$cc -lt $pv.L
        $dnSig=if($isDn){'▼ DOWNTREND'}else{'–'}
        $dnRun=if($tr -and $tr.Down.Running){"$($tr.Down.TradingSymbols) x$($tr.Down.RunningQuantity)$(if($tr.Down.MaxQuantityReached){' [MAX]'}else{''})"}else{'none'}
        $dnEnt=if($tr -and $tr.Down.Running){'{0:N2}' -f $tr.Down.EntryPrice}else{'–'}
        $dnClr=if($isDn){'Red'}else{'DarkGray'}
        Write-Host ('   │'+(Ctr 'SHORT' 7)+'│'+(Ctr ("{0} < {1}" -f $cc,[Math]::Round($pv.L,2)) 26)+'│'+(Ctr $dnSig 11)+'│'+(Ctr $dnEnt 9)+'│'+(Ctr $dnRun 28)+'│') -f $dnClr
    } else {
        Write-Host ('   │'+(Ctr 'waiting for previous candle...' 85)+'│') -f DarkGray
    }
    Write-Host $Sbot -f DarkGray
    Write-Host ''
    Write-Host ("   ● SIGNAL    $($g.Sig)") -f Yellow
    Write-Host ("   ▸ UPDATED   $(Get-Date -f 'HH:mm:ss')      Ctrl+C to stop") -f DarkGray
}

$ws=[System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync("wss://ws.kite.trade?api_key=${key}&access_token=${acc}",[Threading.CancellationToken]::None).Wait(10000)
$ws.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes("{`"a`":`"subscribe`",`"v`":[$tok]}"),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)

$buf=[byte[]]::new(65536);$tb=0;$raw=$null;$prev=$null;$hist=@();$ltp=0;$lastDraw=[datetime]::MinValue;$haPrev=$null
Draw $hist $raw $ltp $tb
while($ws.State -eq 'Open'){
    try{
        $res=$ws.ReceiveAsync([ArraySegment[byte]]$buf,[Threading.CancellationToken]::None).Result
        foreach($t in (Ticks $buf $res.Count)){
            if($t.Tok -ne $tok){continue}
            $ltp=$t.LTP;$n=[datetime]::Now;$bk=[int]([Math]::Floor(($n.Hour*3600+$n.Minute*60+$n.Second)/$sec))*$sec;$upd=$false
            if($tb -ne $bk){
                if($raw){
                    # finalize the just-completed raw candle into a Heikin-Ashi candle (this becomes the "previous" candle for signals)
                    $haC=($raw.O+$raw.H+$raw.L+$raw.C)/4
                    $haO=if($haPrev){($haPrev.O+$haPrev.C)/2}else{($raw.O+$raw.C)/2}
                    $haH=[Math]::Max($raw.H,[Math]::Max($haO,$haC));$haL=[Math]::Min($raw.L,[Math]::Min($haO,$haC))
                    $haPrev=@{O=$haO;H=$haH;L=$haL;C=$haC};$prev=$haPrev
                    $hist=(@($hist)+@{T=[timespan]::FromSeconds($tb).ToString('hh\:mm\:ss');O=[Math]::Round($haO,2);H=[Math]::Round($haH,2);L=[Math]::Round($haL,2);C=[Math]::Round($haC,2)})|Select-Object -Last 5;$upd=$true
                }
                $raw=@{O=$ltp;H=$ltp;L=$ltp;C=$ltp};$tb=$bk
            }
            else{ $raw.H=[Math]::Max($raw.H,$ltp);$raw.L=[Math]::Min($raw.L,$ltp);$raw.C=$ltp }
            # forming Heikin-Ashi candle: HA-Close from the live raw O/H/L/C, HA-Open from the previous HA candle
            $haCloseCur=($raw.O+$raw.H+$raw.L+$raw.C)/4
            $haOpenCur=if($haPrev){($haPrev.O+$haPrev.C)/2}else{($raw.O+$raw.C)/2}
            $haHighCur=[Math]::Max($raw.H,[Math]::Max($haOpenCur,$haCloseCur));$haLowCur=[Math]::Min($raw.L,[Math]::Min($haOpenCur,$haCloseCur))
            $cur=@{O=$haOpenCur;H=$haHighCur;L=$haLowCur;C=$haCloseCur}
            # PRIMARY running check on EVERY tick = /orders (stable). If unreadable, skip this tick entirely.
            $trend=Open-Orders
            if($null -eq $trend){ continue }
            $g.Trend=$trend
            $g.Prev=$prev
            if($prev -and $cur){
                $inWin=$n.TimeOfDay -ge $StartTime.TimeOfDay -and $n.TimeOfDay -le $StopTime.TimeOfDay
                # enter only when /orders shows the side flat AND /positions second-confirms flat (guards a false-empty)
                if($inWin -and $cur.C -gt $prev.H -and -not $trend.Up.Running -and (Confirm-Flat 'CE')){ $g.Sig="[$($n.ToString('HH:mm:ss'))] LONG  $([Math]::Round($cur.C,2)) > $([Math]::Round($prev.H,2))";Enter LONG CE $trend;$upd=$true }
                elseif($inWin -and $cur.C -lt $prev.L -and -not $trend.Down.Running -and (Confirm-Flat 'PE')){ $g.Sig="[$($n.ToString('HH:mm:ss'))] SHORT $([Math]::Round($cur.C,2)) < $([Math]::Round($prev.L,2))";Enter SHORT PE $trend;$upd=$true }
            }
            if($upd -or ([datetime]::Now-$lastDraw).TotalMilliseconds -gt 700){ Draw $hist $cur $ltp $tb;$lastDraw=[datetime]::Now }
        }
    }catch{Start-Sleep -Milliseconds 200}
}
$ws.Dispose()
