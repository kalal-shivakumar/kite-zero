# Regular-Candle Long+Short Auto-Trade (minimal). ALL inputs from input.json. LONG: Close>prevHigh->BUY CE | SHORT: Close<prevLow->BUY PE
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

$tok = (Resolve-KiteSymbol $cfg.TradingSymbol).Token
$ix  = Get-IndexOptionConfig $IndexChoosen $Lots
$ce  = Get-KiteOptionInstruments $ix.OptExchange $ix.SearchKeyWord 'CE' $hdr
$pe  = Get-KiteOptionInstruments $ix.OptExchange $ix.SearchKeyWord 'PE' $hdr
$sec = @{'5second'=5;'15second'=15;'30second'=30;'minute'=60;'2minute'=120;'5minute'=300;'10minute'=600;'15minute'=900;'30minute'=1800;'60minute'=3600}[$cfg.TimeFrame] ?? 300
$pf  = Join-Path $dir 'PlacedOrders\Position.json'
$st  = if (Test-Path $pf) { Get-Content $pf|ConvertFrom-Json } else { @{Direction='';Symbol='';Qty=$ix.Quantity} }

function I16($b,$p){([int]$b[$p]-shl 8)-bor[int]$b[$p+1]}
function I32($b,$p){[int](([uint32]$b[$p]-shl 24)-bor([uint32]$b[$p+1]-shl 16)-bor([uint32]$b[$p+2]-shl 8)-bor[uint32]$b[$p+3])}
function Ticks($b,$l){$t=@();if($l -lt 4){return $t};$c=I16 $b 0;$o=2;for($i=0;$i -lt $c;$i++){if(($o+2)-gt $l){break};$s=I16 $b $o;$o+=2;if($s -lt 4 -or ($o+$s)-gt $l){break};$t+=@{Tok=I32 $b $o;LTP=(I32 $b ($o+4))/100.0};$o+=$s};$t}
function Spot{(Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$($ix.SpotQuoteKey)" -Headers $hdr -EA 0).data.($ix.SpotQuoteKey).last_price}
function OptLTP($sym){try{(Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([uri]::EscapeDataString("$($ix.OptExchange):$sym"))" -Headers $hdr -EA Stop).data.PSObject.Properties.Value.last_price}catch{0}}
function ATM($sp,$ot){$d=if($ot -eq 'CE'){$ce}else{$pe};$srt=$d.Strikes|Sort-Object;$a=$srt|Sort-Object{[Math]::Abs($_-$sp)}|Select-Object -First 1;$ai=[array]::IndexOf($srt,$a);$off=if($ot -eq 'CE'){-$ATMOffset}else{$ATMOffset};$i=[Math]::Max(0,[Math]::Min($ai+$off,$srt.Count-1));($d.Options|Where-Object{$_.Strike -eq $srt[$i]}).Symbol}
function Order($ty,$sym,$qty){Write-Host "[$(Get-Date -f HH:mm:ss)] $ty $sym x$qty" -f Cyan;$bd=@{tradingsymbol=$sym;exchange=$ix.exchange;transaction_type=$ty;order_type=$OrderType;quantity=$qty;product=$Product;validity='DAY';market_protection=$MktProt};try{$r=Invoke-RestMethod "https://api.kite.trade/orders/$Variety" -Method Post -Headers $hdr -Body $bd -EA Stop;if($r.status -eq 'success'){Write-Host "  ok $($r.data.order_id)" -f Green;return $true}}catch{Write-Host "  fail $_" -f Red};$false}
function Close{
    if(-not $st.Direction){return}
    $xp=OptLTP $st.Symbol;Order SELL $st.Symbol $st.Qty
    if($g.Open){$pnl=[Math]::Round(($xp-$g.Open.Entry)*$st.Qty,2);$bk=if($pnl -ge 0){'PROFIT'}else{'LOSS'};$g.Trades=@($g.Trades)+@{ET=$g.Open.ET;Dir=$g.Open.Dir;Entry=$g.Open.Entry;XT=(Get-Date -f 'HH:mm:ss');Exit=$xp;PnL=$pnl;Booked=$bk};$g.Open=$null}
    $st.Direction='';$st.Symbol='';@{Direction='';Symbol='';Qty=$st.Qty}|ConvertTo-Json|Set-Content $pf
}
function Enter($d,$ot){
    if($st.Direction -and $ExitTrade -eq 'yes'){ Close }
    $sym=ATM (Spot) $ot;if(-not $sym){return}
    $ltp=OptLTP $sym
    $lots=if($Amount -gt 0 -and $ltp -gt 0){[int][Math]::Max(1,[Math]::Floor($Amount/($ltp*$ix.Lot)))}else{$Lots}
    $qty=$lots*$ix.Lot
    if(Order BUY $sym $qty){$st.Direction=$d;$st.Symbol=$sym;$st.Qty=$qty;@{Direction=$d;Symbol=$sym;Qty=$qty}|ConvertTo-Json|Set-Content $pf;$g.Open=@{ET=(Get-Date -f 'HH:mm:ss');Dir=$d;Sym=$sym;Entry=$ltp;Qty=$qty}}
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
function Ctr($s,$w){$s=[string]$s;$p=$w-$s.Length;if($p -lt 0){return $s.Substring(0,$w)};$l=[int][Math]::Floor($p/2);(' '*$l)+$s+(' '*($p-$l))}
function PC($v){' '+('{0,10:N2}' -f [double]$v)+' '}
$g=@{Sig='(waiting for signal)';Trades=@();Open=$null}
function Draw($hist,$raw,$ltp,$tbSec){
    Clear-Host
    Write-Host ''
    Write-Host ('   ╔'+('═'*68)+'╗') -f DarkCyan
    Write-Host ('   ║'+(Ctr "$Sym  REGULAR-CANDLE BOT   •   ${sec}s   •   LIVE - REAL ORDERS" 68)+'║') -f Red
    Write-Host ('   ╠'+('═'*68)+'╣') -f DarkCyan
    Write-Host ('   ║'+(Ctr "Idx $IndexChoosen | Lots $Lots | Amt $Amount | $OffLbl | $Product | Win $WinStr" 68)+'║') -f Gray
    Write-Host ('   ╚'+('═'*68)+'╝') -f DarkCyan
    Write-Host ''
    Write-Host "   LAST 5 CANDLES  (${sec}s)" -f DarkYellow
    Write-Host $Ttop -f DarkGray
    Write-Host ('   │'+(Ctr 'Time' 10)+'│'+(Ctr 'Open' 12)+'│'+(Ctr 'High' 12)+'│'+(Ctr 'Low' 12)+'│'+(Ctr 'Close' 12)+'│'+(Ctr '▲▼' 5)+'│') -f Cyan
    Write-Host $Tmid -f DarkGray
    if(@($hist).Count -eq 0){ Write-Host ('   │'+(Ctr 'building first candle...' 63)+'│') -f DarkGray }
    else{ foreach($c in $hist){ $up=$c.C -ge $c.O;$arw=if($up){'▲'}else{'▼'};$clr=if($up){'Green'}else{'Red'};Write-Host ('   │'+(Ctr $c.T 10)+'│'+(PC $c.O)+'│'+(PC $c.H)+'│'+(PC $c.L)+'│'+(PC $c.C)+'│'+(Ctr $arw 5)+'│') -f $clr } }
    Write-Host $Tbot -f DarkGray
    Write-Host ''
    if($raw){ $fu=$raw.C -ge $raw.O;$fc=if($fu){'Green'}else{'Red'};$ft=[timespan]::FromSeconds($tbSec).ToString('hh\:mm\:ss');Write-Host ("   FORMING       $ft   O {0:N2}  H {1:N2}  L {2:N2}  C {3:N2}   LTP {4:N2}" -f $raw.O,$raw.H,$raw.L,$raw.C,$ltp) -f $fc }
    Write-Host ''
    $tot=0;foreach($tr in $g.Trades){$tot+=$tr.PnL}
    $tc=if($tot -ge 0){'Green'}else{'Red'}
    Write-Host ("   TRADES   realized P&L: {0:+#,##0.00;-#,##0.00;0.00}   ({1} closed)" -f $tot,@($g.Trades).Count) -f $tc
    Write-Host $Xtop -f DarkGray
    Write-Host ('   │'+(Ctr 'Entry' 8)+'│'+(Ctr 'Dir' 5)+'│'+(Ctr 'EntryPx' 8)+'│'+(Ctr 'ExitPx' 8)+'│'+(Ctr 'P&L' 8)+'│'+(Ctr 'Booked' 10)+'│') -f Cyan
    Write-Host $Xmid -f DarkGray
    $rows=@($g.Trades)|Select-Object -Last 5
    foreach($tr in $rows){$rc=if($tr.PnL -ge 0){'Green'}else{'Red'};Write-Host ('   │'+(Ctr $tr.ET 8)+'│'+(Ctr $tr.Dir 5)+'│'+(Ctr ('{0:N2}' -f $tr.Entry) 8)+'│'+(Ctr ('{0:N2}' -f $tr.Exit) 8)+'│'+(Ctr ('{0:N2}' -f $tr.PnL) 8)+'│'+(Ctr $tr.Booked 10)+'│') -f $rc}
    if($g.Open){Write-Host ('   │'+(Ctr $g.Open.ET 8)+'│'+(Ctr $g.Open.Dir 5)+'│'+(Ctr ('{0:N2}' -f $g.Open.Entry) 8)+'│'+(Ctr 'OPEN' 8)+'│'+(Ctr '...' 8)+'│'+(Ctr '-' 10)+'│') -f Yellow}
    if(@($rows).Count -eq 0 -and -not $g.Open){Write-Host ('   │'+(Ctr 'no trades yet' 52)+'│') -f DarkGray}
    Write-Host $Xbot -f DarkGray
    Write-Host ''
    if($st.Direction){ $pc=if($st.Direction -eq 'LONG'){'Green'}else{'Red'};Write-Host ("   POSITION   {0}  {1}  x{2}" -f $st.Direction,$st.Symbol,$st.Qty) -f $pc }
    else{ Write-Host '   POSITION   FLAT' -f DarkGray }
    Write-Host ("   SIGNAL     $($g.Sig)") -f Yellow
    Write-Host ("   UPDATED     $(Get-Date -f 'HH:mm:ss')   (Ctrl+C to stop)") -f DarkGray
}

$ws=[System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync("wss://ws.kite.trade?api_key=${key}&access_token=${acc}",[Threading.CancellationToken]::None).Wait(10000)
$ws.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes("{`"a`":`"subscribe`",`"v`":[$tok]}"),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)

$buf=[byte[]]::new(65536);$tb=0;$raw=$null;$prev=$null;$hist=@();$ltp=0;$lastDraw=[datetime]::MinValue
Draw $hist $raw $ltp $tb
while($ws.State -eq 'Open'){
    try{
        $res=$ws.ReceiveAsync([ArraySegment[byte]]$buf,[Threading.CancellationToken]::None).Result
        foreach($t in (Ticks $buf $res.Count)){
            if($t.Tok -ne $tok){continue}
            $ltp=$t.LTP;$n=[datetime]::Now;$bk=[int]([Math]::Floor(($n.Hour*3600+$n.Minute*60+$n.Second)/$sec))*$sec;$upd=$false
            if($tb -ne $bk){ if($raw){$prev=$raw;$hist=(@($hist)+@{T=[timespan]::FromSeconds($tb).ToString('hh\:mm\:ss');O=[Math]::Round($raw.O,2);H=[Math]::Round($raw.H,2);L=[Math]::Round($raw.L,2);C=[Math]::Round($raw.C,2)})|Select-Object -Last 5;$upd=$true};$raw=@{O=$ltp;H=$ltp;L=$ltp;C=$ltp};$tb=$bk }
            else{ $raw.H=[Math]::Max($raw.H,$ltp);$raw.L=[Math]::Min($raw.L,$ltp);$raw.C=$ltp }
            $cur=$raw
            if($prev -and $cur){
                $inWin=$n.TimeOfDay -ge $StartTime.TimeOfDay -and $n.TimeOfDay -le $StopTime.TimeOfDay
                if($inWin -and $cur.C -gt $prev.H -and $st.Direction -ne 'LONG'){ $g.Sig="[$($n.ToString('HH:mm:ss'))] LONG  $([Math]::Round($cur.C,2)) > $([Math]::Round($prev.H,2))";Enter LONG CE;$upd=$true }
                elseif($inWin -and $cur.C -lt $prev.L -and $st.Direction -ne 'SHORT'){ $g.Sig="[$($n.ToString('HH:mm:ss'))] SHORT $([Math]::Round($cur.C,2)) < $([Math]::Round($prev.L,2))";Enter SHORT PE;$upd=$true }
            }
            if($upd -or ([datetime]::Now-$lastDraw).TotalMilliseconds -gt 700){ Draw $hist $cur $ltp $tb;$lastDraw=[datetime]::Now }
        }
    }catch{Start-Sleep -Milliseconds 200}
}
$ws.Dispose()
