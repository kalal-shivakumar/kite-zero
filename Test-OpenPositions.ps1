# Standalone tester: loads config + headers, calls Open-Positions ONCE, prints the result. Read-only (GET /positions).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $dir 'KiteData.psm1') -Force -WarningAction SilentlyContinue
$cfg = Get-Content (Join-Path $dir 'input.json') | ConvertFrom-Json
$at  = Get-Content (Join-Path $dir 'accesstoken.json') | ConvertFrom-Json
$key = $at.api_key; $acc = $at.access_token
$hdr = @{ Authorization="token ${key}:${acc}"; 'X-Kite-Version'='3' }

$IndexChoosen = $cfg.IndexChoosen
$Lots         = [int]$cfg.NoOfLotsPurchaseAtaTime
$ix           = Get-IndexOptionConfig $IndexChoosen $Lots

function Open-Positions{
    try{ $resp = Invoke-RestMethod "https://api.kite.trade/portfolio/positions" -Headers $hdr -Method Get -EA Stop }catch{ return $null }
    if($null -eq $resp -or $null -eq $resp.data){ return $null }
    $net = @($resp.data.net)
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

$result = Open-Positions
if($null -eq $result){
    Write-Host "Open-Positions returned: `$null (API error / no usable response)" -f Red
}else{
    Write-Host "Open-Positions returned:" -f Green
    $result | ConvertTo-Json -Depth 5
}
