# Stress tester: calls the positions API in a tight loop (NO delay) for 5 minutes.
# Classifies each call: OK (valid data) / EMPTY (null response or no data) / ERROR (exception, e.g. HTTP 429 rate limit).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$at  = Get-Content (Join-Path $dir 'accesstoken.json') | ConvertFrom-Json
$key = $at.api_key; $acc = $at.access_token
$hdr = @{ Authorization="token ${key}:${acc}"; 'X-Kite-Version'='3' }

$RunMinutes = 5
$start    = Get-Date
$deadline = $start.AddMinutes($RunMinutes)
$calls=0; $ok=0; $empty=0; $err=0
$errTypes=@{}
$lastReport=$start

Write-Host "Stress-testing /portfolio/positions with NO delay for $RunMinutes min..." -f Yellow
Write-Host "Start: $($start.ToString('HH:mm:ss'))  End: $($deadline.ToString('HH:mm:ss'))`n" -f DarkGray

while((Get-Date) -lt $deadline){
    $calls++
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    try{
        $resp = Invoke-RestMethod "https://api.kite.trade/portfolio/positions" -Headers $hdr -Method Get -EA Stop
        if($null -eq $resp -or $null -eq $resp.data){
            $empty++
            Write-Host ("[{0}] #{1,-5} EMPTY  null/no-data response" -f $ts,$calls) -f DarkYellow
        } else {
            $ok++
            $net = @($resp.data.net)
            $open = @($net | Where-Object { $_.quantity -ne 0 })
            $summ = if($open.Count -eq 0){ "flat" } else { ($open | ForEach-Object { "$($_.tradingsymbol)x$($_.quantity)" }) -join ',' }
            Write-Host ("[{0}] #{1,-5} OK     status={2} net={3} open={4} => {5}" -f $ts,$calls,$resp.status,$net.Count,$open.Count,$summ) -f Green
        }
    }catch{
        $err++
        $code=$null
        try{ if($_.Exception.Response){ $code=[int]$_.Exception.Response.StatusCode } }catch{}
        $k = if($code){ "HTTP $code" } else { $_.Exception.Message }
        if($errTypes.ContainsKey($k)){ $errTypes[$k]++ } else { $errTypes[$k]=1 }
        # Show the ACTUAL response body returned on error
        $body = $null
        try{ if($_.ErrorDetails -and $_.ErrorDetails.Message){ $body = $_.ErrorDetails.Message } }catch{}
        if(-not $body){
            try{
                if($_.Exception.Response){
                    $rs = $_.Exception.Response.GetResponseStream()
                    $sr = New-Object System.IO.StreamReader($rs)
                    $body = $sr.ReadToEnd(); $sr.Close()
                }
            }catch{}
        }
        if(-not $body){ $body = $_.Exception.Message }
        Write-Host ("[{0}] #{1,-5} ERROR  {2}  {3}" -f $ts,$calls,$k,(($body -replace '\s+',' ').Trim())) -f Red
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
Write-Host ("OK (data)    : {0}" -f $ok) -f Green
Write-Host ("EMPTY        : {0}" -f $empty) -f DarkYellow
Write-Host ("ERROR        : {0}" -f $err) -f Red
if($errTypes.Count -gt 0){
    Write-Host "Error breakdown:" -f Red
    $errTypes.GetEnumerator()|Sort-Object Value -Descending|ForEach-Object{ Write-Host ("   {0,-45} {1}" -f $_.Name,$_.Value) -f Red }
}else{
    Write-Host "No errors encountered." -f Green
}
Write-Host "=============================================" -f Yellow
