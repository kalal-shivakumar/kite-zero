<#
.SYNOPSIS
  Continuously fetches open positions and writes CE and PE positions to separate CSV files.
.DESCRIPTION
  Polls the Kite positions API every 2 seconds, splits positions into CE and PE,
  fetches live LTP for each, and writes to CE-Positions.csv and PE-Positions.csv.
.EXAMPLE
  .\Monitor-Positions.ps1
#>

param(
    [int]$RefreshSeconds = 1,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret
)

# ================================================================
# Module & Config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (Test-Path $inputFile) {
    $cfg = Get-Content $inputFile -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('API_Key'))    { $API_Key    = $cfg.API_Key }
    if (-not $PSBoundParameters.ContainsKey('API_Secret')) { $API_Secret = $cfg.API_Secret }
}
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  API_Key/API_Secret not found. Set them in input.json.' -ForegroundColor Red; exit 1
}

# ================================================================
# Auth
# ================================================================
$tokenFile = Join-Path $scriptDir 'accesstoken.json'
if (-not $AccessToken) {
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  No access token. Please login first.' -ForegroundColor Red; exit 1 }
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

# CSV file paths
$ceCsvFile = Join-Path $scriptDir 'CE-Positions.csv'
$peCsvFile = Join-Path $scriptDir 'PE-Positions.csv'

Write-Host ''
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host '  Position Monitor — CE & PE Tracker' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host "  CE CSV: $ceCsvFile"
Write-Host "  PE CSV: $peCsvFile"
Write-Host "  Refresh: every ${RefreshSeconds}s"
Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
Write-Host ''

# ================================================================
# Main Loop
# ================================================================
$loopCount = 0

while ($true) {
    $loopCount++

    try {
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $headers -Method Get -ErrorAction Stop

        $dayPositions = $resp.data.day
        $cePositions = @()
        $pePositions = @()
        $totalCEPnL = 0.0
        $totalPEPnL = 0.0

        if ($dayPositions -and $dayPositions.Count -gt 0) {
            # Separate CE and PE open positions
            foreach ($pos in $dayPositions) {
                $symbol = $pos.tradingsymbol
                $qty    = [int]$pos.quantity

                if ($symbol -match 'CE$') {
                    $cePositions += $pos
                } elseif ($symbol -match 'PE$') {
                    $pePositions += $pos
                }
            }
        }

        # Fetch live LTP for all option positions
        $allOptions = @($cePositions) + @($pePositions) | Where-Object { [int]$_.quantity -ne 0 }
        $ltpMap = @{}

        if ($allOptions.Count -gt 0) {
            $queryParts = @()
            foreach ($pos in $allOptions) {
                $queryParts += "i=$([System.Uri]::EscapeDataString("$($pos.exchange):$($pos.tradingsymbol)"))"
            }
            try {
                $ltpUrl = "https://api.kite.trade/quote/ltp?" + ($queryParts -join '&')
                $ltpResp = Invoke-RestMethod -Uri $ltpUrl -Headers $headers -Method Get -ErrorAction Stop
                if ($ltpResp.data) {
                    foreach ($prop in $ltpResp.data.PSObject.Properties) {
                        $ltpMap[$prop.Name] = [double]$prop.Value.last_price
                    }
                }
            } catch {}
        }

        # Build CE rows
        $ceRows = @()
        foreach ($pos in $cePositions) {
            $qty     = [int]$pos.quantity
            $buyAvg  = [double]$pos.average_price
            $sellAvg = [double]$pos.sell_price
            $ltpKey  = "$($pos.exchange):$($pos.tradingsymbol)"
            $ltp     = if ($ltpMap.ContainsKey($ltpKey)) { $ltpMap[$ltpKey] } else { [double]$pos.last_price }
            $mult    = if ($pos.multiplier) { [double]$pos.multiplier } else { 1.0 }

            if ($qty -gt 0) {
                $pnl = ($ltp - $buyAvg) * $qty * $mult
            } elseif ($qty -lt 0) {
                $pnl = ($sellAvg - $ltp) * [Math]::Abs($qty) * $mult
            } else {
                $pnl = [double]$pos.pnl
            }
            $totalCEPnL += $pnl

            $status = if ($qty -ne 0) { 'OPEN' } else { 'CLOSED' }

            $ceRows += [PSCustomObject]@{
                Symbol    = $pos.tradingsymbol
                Exchange  = $pos.exchange
                Qty       = $qty
                BuyAvg    = [Math]::Round($buyAvg, 2)
                SellAvg   = [Math]::Round($sellAvg, 2)
                LTP       = [Math]::Round($ltp, 2)
                PnL       = [Math]::Round($pnl, 2)
                Product   = $pos.product
                Status    = $status
                Side      = if ($qty -gt 0) { 'LONG' } elseif ($qty -lt 0) { 'SHORT' } else { 'FLAT' }
                FetchedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }

        # Build PE rows
        $peRows = @()
        foreach ($pos in $pePositions) {
            $qty     = [int]$pos.quantity
            $buyAvg  = [double]$pos.average_price
            $sellAvg = [double]$pos.sell_price
            $ltpKey  = "$($pos.exchange):$($pos.tradingsymbol)"
            $ltp     = if ($ltpMap.ContainsKey($ltpKey)) { $ltpMap[$ltpKey] } else { [double]$pos.last_price }
            $mult    = if ($pos.multiplier) { [double]$pos.multiplier } else { 1.0 }

            if ($qty -gt 0) {
                $pnl = ($ltp - $buyAvg) * $qty * $mult
            } elseif ($qty -lt 0) {
                $pnl = ($sellAvg - $ltp) * [Math]::Abs($qty) * $mult
            } else {
                $pnl = [double]$pos.pnl
            }
            $totalPEPnL += $pnl

            $status = if ($qty -ne 0) { 'OPEN' } else { 'CLOSED' }

            $peRows += [PSCustomObject]@{
                Symbol    = $pos.tradingsymbol
                Exchange  = $pos.exchange
                Qty       = $qty
                BuyAvg    = [Math]::Round($buyAvg, 2)
                SellAvg   = [Math]::Round($sellAvg, 2)
                LTP       = [Math]::Round($ltp, 2)
                PnL       = [Math]::Round($pnl, 2)
                Product   = $pos.product
                Status    = $status
                Side      = if ($qty -gt 0) { 'LONG' } elseif ($qty -lt 0) { 'SHORT' } else { 'FLAT' }
                FetchedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }

        # Write to CSV (overwrite with latest)
        if ($ceRows.Count -gt 0) {
            $ceRows | Export-Csv -Path $ceCsvFile -NoTypeInformation -Force
        }
        if ($peRows.Count -gt 0) {
            $peRows | Export-Csv -Path $peCsvFile -NoTypeInformation -Force
        }

        # Display
        Clear-Host
        Write-Host ''
        Write-Host "  ================================================" -ForegroundColor Cyan
        Write-Host "  Position Monitor — CE & PE  (Loop #$loopCount)" -ForegroundColor Cyan
        Write-Host "  ================================================" -ForegroundColor Cyan
        Write-Host "  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Refresh: ${RefreshSeconds}s"
        Write-Host ''

        $fmt = '  {0,-28} {1,5} {2,6} {3,10} {4,10} {5,12} {6,6}'

        # CE Section
        $ceOpen = @($cePositions | Where-Object { [int]$_.quantity -ne 0 })
        Write-Host "  ── CE Positions ($($ceOpen.Count) open / $($cePositions.Count) total) ──" -ForegroundColor Green
        if ($ceRows.Count -gt 0) {
            Write-Host ($fmt -f 'Symbol', 'Side', 'Qty', 'Avg', 'LTP', 'P&L', 'Status') -ForegroundColor Cyan
            Write-Host ('  ' + ('-' * 82))
            foreach ($r in $ceRows) {
                $color = if ($r.PnL -ge 0) { 'Green' } else { 'Red' }
                Write-Host ($fmt -f $r.Symbol, $r.Side, $r.Qty, $r.BuyAvg.ToString('N2'), $r.LTP.ToString('N2'), $r.PnL.ToString('N2'), $r.Status) -ForegroundColor $color
            }
            $ceColor = if ($totalCEPnL -ge 0) { 'Green' } else { 'Red' }
            Write-Host "  CE Total P&L: $($totalCEPnL.ToString('N2'))" -ForegroundColor $ceColor
        } else {
            Write-Host '  No CE positions' -ForegroundColor DarkGray
        }
        Write-Host ''

        # PE Section
        $peOpen = @($pePositions | Where-Object { [int]$_.quantity -ne 0 })
        Write-Host "  ── PE Positions ($($peOpen.Count) open / $($pePositions.Count) total) ──" -ForegroundColor Red
        if ($peRows.Count -gt 0) {
            Write-Host ($fmt -f 'Symbol', 'Side', 'Qty', 'Avg', 'LTP', 'P&L', 'Status') -ForegroundColor Cyan
            Write-Host ('  ' + ('-' * 82))
            foreach ($r in $peRows) {
                $color = if ($r.PnL -ge 0) { 'Green' } else { 'Red' }
                Write-Host ($fmt -f $r.Symbol, $r.Side, $r.Qty, $r.BuyAvg.ToString('N2'), $r.LTP.ToString('N2'), $r.PnL.ToString('N2'), $r.Status) -ForegroundColor $color
            }
            $peColor = if ($totalPEPnL -ge 0) { 'Green' } else { 'Red' }
            Write-Host "  PE Total P&L: $($totalPEPnL.ToString('N2'))" -ForegroundColor $peColor
        } else {
            Write-Host '  No PE positions' -ForegroundColor DarkGray
        }

        # Combined
        Write-Host ''
        Write-Host '  ────────────────────────────────────────────────' -ForegroundColor Cyan
        $combinedPnL = $totalCEPnL + $totalPEPnL
        $combColor = if ($combinedPnL -ge 0) { 'Green' } else { 'Red' }
        Write-Host "  Combined P&L: $($combinedPnL.ToString('N2'))  (CE: $($totalCEPnL.ToString('N2')) | PE: $($totalPEPnL.ToString('N2')))" -ForegroundColor $combColor
        Write-Host ''
        Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] Error: $($_.Exception.Message)" -ForegroundColor Red
    }

    Start-Sleep -Seconds $RefreshSeconds
}
