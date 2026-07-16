# Fetch all Kite orders and compute P&L using the same BUY/SELL pairing logic as the dashboard (loadOrd)
$tok = Get-Content -Raw 'accesstoken.json' | ConvertFrom-Json
$headers = @{ 'Authorization' = "token $($tok.api_key):$($tok.access_token)"; 'X-Kite-Version' = '3' }
$resp = Invoke-RestMethod -Uri 'https://api.kite.trade/orders' -Headers $headers -Method Get
$orders = $resp.data
Write-Host "Total orders returned: $($orders.Count)"

$completed = $orders | Where-Object { $_.status -eq 'COMPLETE' }
Write-Host "COMPLETE orders: $($completed.Count)"

$buys  = @($completed | Where-Object { $_.transaction_type -eq 'BUY' }  | Sort-Object { [datetime]$_.order_timestamp })
$sells = @($completed | Where-Object { $_.transaction_type -eq 'SELL' } | Sort-Object { [datetime]$_.order_timestamp })
Write-Host "BUY: $($buys.Count)  SELL: $($sells.Count)"

$usedSells = New-Object System.Collections.Generic.HashSet[string]
$records = @()
foreach ($buy in $buys) {
    $sell = $sells | Where-Object {
        $_.tradingsymbol -eq $buy.tradingsymbol -and
        (-not $usedSells.Contains([string]$_.order_id)) -and
        ([datetime]$_.order_timestamp -ge [datetime]$buy.order_timestamp)
    } | Select-Object -First 1
    if ($sell) {
        [void]$usedSells.Add([string]$sell.order_id)
        $entry = [double]$buy.average_price; $exit = [double]$sell.average_price; $qty = [double]$buy.quantity
        $pnl = ($exit - $entry) * $qty
        $records += [pscustomobject]@{ Symbol = $buy.tradingsymbol; Entry = $entry; Exit = $exit; Qty = $qty; PnL = [math]::Round($pnl, 2) }
    }
    else {
        $records += [pscustomobject]@{ Symbol = $buy.tradingsymbol; Entry = [double]$buy.average_price; Exit = $null; Qty = [double]$buy.quantity; PnL = $null }
    }
}

$closed = @($records | Where-Object { $null -ne $_.PnL })
$open   = @($records | Where-Object { $null -eq $_.PnL })
$records | Format-Table -AutoSize

$total = ($closed | Measure-Object -Property PnL -Sum).Sum
$wins  = @($closed | Where-Object { $_.PnL -gt 0 }).Count
$loss  = @($closed | Where-Object { $_.PnL -lt 0 }).Count
$gp    = ($closed | Where-Object { $_.PnL -gt 0 } | Measure-Object -Property PnL -Sum).Sum
$gl    = ($closed | Where-Object { $_.PnL -lt 0 } | Measure-Object -Property PnL -Sum).Sum

Write-Host "-----------------------------------------"
Write-Host ("Closed trades  : {0}" -f $closed.Count)
Write-Host ("Open (unpaired): {0}" -f $open.Count)
Write-Host ("Winners        : {0}" -f $wins)
Write-Host ("Losers         : {0}" -f $loss)
Write-Host ("Gross Profit   : {0:N2}" -f ([double]$gp))
Write-Host ("Gross Loss     : {0:N2}" -f ([double]$gl))
Write-Host ("NET P&L        : {0:N2}" -f ([double]$total))
