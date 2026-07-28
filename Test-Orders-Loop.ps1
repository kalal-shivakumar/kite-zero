# Loop tester for /orders  ->  used as SECOND confirmation of an open position.
# Logic: for each COMPLETE order, sum filled_quantity per symbol (BUY adds, SELL subtracts).
#        net > 0  =>  a BUY filled with no matching SELL yet  =>  position still RUNNING.
# Prints one row per hit (like the positions loop) + running-position summary. Read-only (GET /orders).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$at  = Get-Content (Join-Path $dir 'accesstoken.json') | ConvertFrom-Json
$key = $at.api_key; $acc = $at.access_token
$hdr = @{ Authorization="token ${key}:${acc}"; 'X-Kite-Version'='3' }

# Derives running positions from the raw /orders list.
# Returns @{ Running=@{sym=qty;...}; TotalOrders=n; Complete=n } or $null on error/no-data.
function Get-RunningFromOrders($hdr){
    try{ $resp = Invoke-RestMethod "https://api.kite.trade/orders" -Headers $hdr -Method Get -EA Stop }catch{ return $null }
    if($null -eq $resp -or $null -eq $resp.data){ return $null }
    $orders = @($resp.data)
    $net = @{}
    $complete = 0
    foreach($o in $orders){
        if($o.status -ne 'COMPLETE'){ continue }
        $complete++
        $sym = [string]$o.tradingsymbol
        $fq  = [int]$o.filled_quantity
        if(-not $net.ContainsKey($sym)){ $net[$sym]=0 }
        if($o.transaction_type -eq 'BUY'){ $net[$sym]+=$fq }
        elseif($o.transaction_type -eq 'SELL'){ $net[$sym]-=$fq }
    }
    $running = @{}
    foreach($k in $net.Keys){ if($net[$k] -gt 0){ $running[$k]=$net[$k] } }
    return @{ Running=$running; TotalOrders=$orders.Count; Complete=$complete }
}

$RunMinutes = 2
$start    = Get-Date
$deadline = $start.AddMinutes($RunMinutes)
$calls=0; $ok=0; $empty=0; $err=0
$errTypes=@{}
$lastReport=$start

Write-Host "Testing /orders (BUY-COMPLETE minus SELL-COMPLETE = running) for $RunMinutes min..." -f Yellow
Write-Host "Start: $($start.ToString('HH:mm:ss'))  End: $($deadline.ToString('HH:mm:ss'))`n" -f DarkGray

while((Get-Date) -lt $deadline){
    $calls++
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    try{
        $r = Get-RunningFromOrders $hdr
        if($null -eq $r){
            $empty++
            Write-Host ("[{0}] #{1,-5} EMPTY  null/no-data" -f $ts,$calls) -f DarkYellow
        } else {
            $ok++
            $run = $r.Running
            $summ = if($run.Count -eq 0){ "flat (no running)" } else { ($run.GetEnumerator()|Sort-Object Name|ForEach-Object{ "$($_.Name)x$($_.Value)" }) -join ',' }
            Write-Host ("[{0}] #{1,-5} OK     orders={2,-3} complete={3,-3} running={4} => {5}" -f $ts,$calls,$r.TotalOrders,$r.Complete,$run.Count,$summ) -f Green
        }
    }catch{
        $err++
        $code=$null
        try{ if($_.Exception.Response){ $code=[int]$_.Exception.Response.StatusCode } }catch{}
        $k = if($code){ "HTTP $code" } else { $_.Exception.Message }
        if($errTypes.ContainsKey($k)){ $errTypes[$k]++ } else { $errTypes[$k]=1 }
        $body=$null
        try{ if($_.ErrorDetails -and $_.ErrorDetails.Message){ $body=$_.ErrorDetails.Message } }catch{}
        if(-not $body){ try{ if($_.Exception.Response){ $rs=$_.Exception.Response.GetResponseStream();$sr=New-Object System.IO.StreamReader($rs);$body=$sr.ReadToEnd();$sr.Close() } }catch{} }
        if(-not $body){ $body=$_.Exception.Message }
        Write-Host ("[{0}] #{1,-5} ERROR  {2}  {3}" -f $ts,$calls,$k,(($body -replace '\s+',' ').Trim())) -f Red
        Start-Sleep -Milliseconds 250
    }
    if(((Get-Date)-$lastReport).TotalSeconds -ge 5){
        $elapsed=[Math]::Max(1,((Get-Date)-$start).TotalSeconds)
        Write-Host ("---- [{0,4}s] calls={1} ok={2} empty={3} err={4} rate={5:N1}/s ----" -f [int]$elapsed,$calls,$ok,$empty,$err,($calls/$elapsed)) -f Cyan
        $lastReport=Get-Date
    }
}

$elapsed=[Math]::Max(1,((Get-Date)-$start).TotalSeconds)
Write-Host "`n================ FINAL REPORT ================" -f Yellow
Write-Host ("Duration     : {0:N1}s" -f $elapsed)
Write-Host ("Total calls  : {0}" -f $calls)
Write-Host ("Avg rate     : {0:N1} calls/sec" -f ($calls/$elapsed))
Write-Host ("OK           : {0}" -f $ok) -f Green
Write-Host ("EMPTY        : {0}" -f $empty) -f DarkYellow
Write-Host ("ERROR        : {0}" -f $err) -f Red
if($errTypes.Count -gt 0){ $errTypes.GetEnumerator()|Sort-Object Value -Descending|ForEach-Object{ Write-Host ("   {0,-45} {1}" -f $_.Name,$_.Value) -f Red } }
Write-Host "=============================================" -f Yellow

# One detailed dump of the latest raw orders (key fields) so we can verify the structure.
Write-Host "`n---- RAW ORDERS (latest snapshot, key fields) ----" -f Magenta
try{
    $d = @((Invoke-RestMethod "https://api.kite.trade/orders" -Headers $hdr -Method Get -EA Stop).data)
    if($d.Count -eq 0){ Write-Host "(no orders today)" -f DarkGray }
    else{ $d | Select-Object order_id,order_timestamp,tradingsymbol,transaction_type,status,quantity,filled_quantity | Format-Table -AutoSize | Out-String | Write-Host }
}catch{ Write-Host "raw dump failed: $_" -f Red }
