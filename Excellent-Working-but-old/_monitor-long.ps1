# TEMP monitor: mirrors the bot's 60s candle + LONG rule (close>prevHigh) and logs every LONG signal for 15 min.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $dir 'KiteData.psm1') -Force -WarningAction SilentlyContinue
$cfg = Get-Content (Join-Path $dir 'input.json') | ConvertFrom-Json
$at  = Get-Content (Join-Path $dir 'accesstoken.json') | ConvertFrom-Json
$key = $at.api_key; $acc = $at.access_token
$hdr = @{ Authorization="token ${key}:${acc}"; 'X-Kite-Version'='3' }
$tok = (Resolve-KiteSymbol $cfg.TradingSymbol).Token
$sec = @{'5second'=5;'15second'=15;'30second'=30;'minute'=60;'2minute'=120;'5minute'=300;'10minute'=600;'15minute'=900;'30minute'=1800;'60minute'=3600}[$cfg.TimeFrame] ?? 300
$log = Join-Path $dir '_monitor-long.log'
"[$(Get-Date -f HH:mm:ss)] MONITOR START  timeframe=${sec}s  rule: LONG when formingClose > prevCandleHigh" | Tee-Object $log

function I16($b,$p){([int]$b[$p]-shl 8)-bor[int]$b[$p+1]}
function I32($b,$p){[int](([uint32]$b[$p]-shl 24)-bor([uint32]$b[$p+1]-shl 16)-bor([uint32]$b[$p+2]-shl 8)-bor[uint32]$b[$p+3])}
function Ticks($b,$l){$t=@();if($l -lt 4){return $t};$c=I16 $b 0;$o=2;for($i=0;$i -lt $c;$i++){if(($o+2)-gt $l){break};$s=I16 $b $o;$o+=2;if($s -lt 4 -or ($o+$s)-gt $l){break};$t+=@{Tok=I32 $b $o;LTP=(I32 $b ($o+4))/100.0};$o+=$s};$t}

# running CE qty from /orders (to note whether a LONG could actually enter)
function CeRunning{
    try{ $r=Invoke-RestMethod "https://api.kite.trade/orders" -Headers $hdr -EA Stop }catch{ return $null }
    $net=@{}; foreach($o in @($r.data)){ if($o.status -ne 'COMPLETE'){continue}; $s=[string]$o.tradingsymbol; if($s -notlike '*CE'){continue}; $fq=[int]$o.filled_quantity; if($fq -le 0){continue}; if(-not $net.ContainsKey($s)){$net[$s]=0}; if($o.transaction_type -eq 'BUY'){$net[$s]+=$fq}else{$net[$s]-=$fq} }
    $q=0; foreach($k in $net.Keys){ if($net[$k] -gt 0){$q+=$net[$k]} }; $q
}

$ws=[System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync("wss://ws.kite.trade?api_key=${key}&access_token=${acc}",[Threading.CancellationToken]::None).Wait(10000)
$ws.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes("{`"a`":`"subscribe`",`"v`":[$tok]}"),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)

$buf=[byte[]]::new(65536);$tb=0;$raw=$null;$prev=$null;$ltp=0
$deadline=(Get-Date).AddMinutes(15)
$loggedThisCandle=$false
while($ws.State -eq 'Open' -and (Get-Date) -lt $deadline){
    try{
        $res=$ws.ReceiveAsync([ArraySegment[byte]]$buf,[Threading.CancellationToken]::None).Result
        foreach($t in (Ticks $buf $res.Count)){
            if($t.Tok -ne $tok){continue}
            $ltp=$t.LTP;$n=[datetime]::Now;$bk=[int]([Math]::Floor(($n.Hour*3600+$n.Minute*60+$n.Second)/$sec))*$sec
            if($tb -ne $bk){
                if($raw){ $prev=$raw; "[$(Get-Date -f HH:mm:ss)] candle closed  O $($raw.O) H $($raw.H) L $($raw.L) C $($raw.C)" | Tee-Object $log -Append }
                $raw=@{O=$ltp;H=$ltp;L=$ltp;C=$ltp};$tb=$bk;$loggedThisCandle=$false
            } else { $raw.H=[Math]::Max($raw.H,$ltp);$raw.L=[Math]::Min($raw.L,$ltp);$raw.C=$ltp }
            if($prev -and $raw -and -not $loggedThisCandle -and $raw.C -gt $prev.H){
                $ce=CeRunning
                $state=if($ce -gt 0){"CE already running x$ce (no new entry expected)"}else{'CE flat (entry SHOULD fire)'}
                "[$(Get-Date -f HH:mm:ss)] >>> LONG SIGNAL  close $([Math]::Round($raw.C,2)) > prevHigh $([Math]::Round($prev.H,2))  | $state" | Tee-Object $log -Append
                $loggedThisCandle=$true
            }
        }
    }catch{ Start-Sleep -Milliseconds 200 }
}
"[$(Get-Date -f HH:mm:ss)] MONITOR END" | Tee-Object $log -Append
$ws.Dispose()
