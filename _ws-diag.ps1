$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$at  = Get-Content (Join-Path $dir 'accesstoken.json') | ConvertFrom-Json
$key = $at.api_key; $acc = $at.access_token
$tok = 265   # SENSEX index token from presets

function I16($b,$p){([int]$b[$p]-shl 8)-bor[int]$b[$p+1]}
function I32($b,$p){[int](([uint32]$b[$p]-shl 24)-bor([uint32]$b[$p+1]-shl 16)-bor([uint32]$b[$p+2]-shl 8)-bor[uint32]$b[$p+3])}

$ws=[System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync("wss://ws.kite.trade?api_key=${key}&access_token=${acc}",[Threading.CancellationToken]::None).Wait(10000)
Write-Host "WS State after connect: $($ws.State)"
$ws.SendAsync([ArraySegment[byte]][Text.Encoding]::UTF8.GetBytes("{`"a`":`"subscribe`",`"v`":[$tok]}"),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)
Write-Host "Subscribed to $tok (NO mode message). Listening 15s..."

$buf=[byte[]]::new(65536)
$deadline=(Get-Date).AddSeconds(15)
$msgCount=0;$binCount=0;$textCount=0
while((Get-Date) -lt $deadline -and $ws.State -eq 'Open'){
    $rtask=$ws.ReceiveAsync([ArraySegment[byte]]$buf,[Threading.CancellationToken]::None)
    if(-not $rtask.Wait(5000)){ Write-Host "  (no message in 5s)"; continue }
    $res=$rtask.Result
    $msgCount++
    if($res.MessageType -eq 'Text'){
        $textCount++
        $txt=[Text.Encoding]::UTF8.GetString($buf,0,$res.Count)
        Write-Host "  TEXT msg: $txt" -f Yellow
    } else {
        $binCount++
        $len=$res.Count
        if($len -lt 4){ Write-Host "  BIN heartbeat (len=$len)" -f DarkGray; continue }
        $numPackets=I16 $buf 0
        Write-Host "  BIN msg len=$len packets=$numPackets" -f Cyan
        if($numPackets -ge 1){
            $o=2; $plen=I16 $buf $o; $o+=2
            $ptok=I32 $buf $o; $ltp=(I32 $buf ($o+4))/100.0
            Write-Host "    packet0 plen=$plen token=$ptok ltp=$ltp" -f Green
        }
    }
}
Write-Host "DONE. total=$msgCount text=$textCount bin=$binCount"
$ws.Dispose()
