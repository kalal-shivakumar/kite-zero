<#
.SYNOPSIS
  Continuously monitors total P&L from Kite positions.
.DESCRIPTION
  Polls the Kite positions API every 2 seconds and displays
  a live-updating total P&L summary (realized + unrealized).
.EXAMPLE
  .\Monitor-PNL.ps1
#>

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

# Load config
$inputFile = Join-Path $scriptDir 'input.json'
$API_Key    = '0fvxhlacu555dhp0'
$API_Secret = '69wajxn41hj77pze3xnhw1dp442auw8t'

if (Test-Path $inputFile) {
    $cfg = Get-Content $inputFile -Raw | ConvertFrom-Json
    if ($cfg.API_Key)    { $API_Key    = $cfg.API_Key }
    if ($cfg.API_Secret) { $API_Secret = $cfg.API_Secret }
}

# Auth
$tokenFile   = Join-Path $scriptDir 'accesstoken.json'
$AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
if (-not $AccessToken) { Write-Host "  No access token. Please login first." -ForegroundColor Red; exit 1 }

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  Kite P&L Monitor — Live Positions" -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $headers -Method Get -ErrorAction Stop

        $now = Get-Date -Format 'HH:mm:ss'
        $dayPositions = $resp.data.day
        $netPositions = $resp.data.net

        $totalPnL       = 0.0
        $totalRealized   = 0.0
        $totalUnrealized = 0.0
        $openCount       = 0
        $closedCount     = 0

        $sb = [System.Text.StringBuilder]::new(2048)
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("  ========================================")
        $null = $sb.AppendLine("  Kite P&L Monitor | $now")
        $null = $sb.AppendLine("  ========================================")

        if ($dayPositions -and $dayPositions.Count -gt 0) {
            $rowFmt = '  {0,-28} {1,6} {2,8} {3,10} {4,12} {5,12}'
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine(($rowFmt -f 'Symbol', 'Qty', 'Buy Avg', 'Sell Avg', 'Realized', 'Unrealized'))
            $null = $sb.AppendLine('  ' + ('-' * 82))

            foreach ($pos in $dayPositions) {
                $realized   = [double]$pos.pnl - [double]$pos.unrealised
                $unrealized = [double]$pos.unrealised
                $pnl        = [double]$pos.pnl
                $qty        = [int]$pos.quantity

                $totalRealized   += $realized
                $totalUnrealized += $unrealized
                $totalPnL        += $pnl

                if ($qty -ne 0) { $openCount++ } else { $closedCount++ }

                $buyAvg  = if ($pos.average_price)      { [double]$pos.average_price }      else { 0 }
                $sellAvg = if ($pos.sell_price)          { [double]$pos.sell_price }          else { 0 }

                $null = $sb.AppendLine(($rowFmt -f $pos.tradingsymbol, $qty, $buyAvg.ToString('N2'), $sellAvg.ToString('N2'), $realized.ToString('N2'), $unrealized.ToString('N2')))
            }
        } else {
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("  No positions today.")
        }

        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("  ----------------------------------------")
        $null = $sb.AppendLine("  Open: $openCount | Closed: $closedCount")
        $null = $sb.AppendLine("  Realized P&L   : $($totalRealized.ToString('N2'))")
        $null = $sb.AppendLine("  Unrealized P&L : $($totalUnrealized.ToString('N2'))")

        Clear-Host
        Write-Host $sb.ToString()

        $pnlColor = if ($totalPnL -ge 0) { 'Green' } else { 'Red' }
        Write-Host "  TOTAL P&L      : $($totalPnL.ToString('N2'))" -ForegroundColor $pnlColor
        Write-Host ""
        Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] Error fetching positions: $($_.Exception.Message)" -ForegroundColor Red
    }

    Start-Sleep -Seconds 2
}
