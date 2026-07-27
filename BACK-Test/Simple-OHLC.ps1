<#
.SYNOPSIS
  Ultra-simple OHLC display script
.EXAMPLE
  .\Simple-OHLC.ps1
#>

param(
    [string]$Symbol = 'NIFTY',
    [string]$Date = '2026-07-24'
)

$ErrorActionPreference = 'Continue'

# Load config
$cfg = Get-Content "..\input.json" -Raw | ConvertFrom-Json
$token = Get-Content "..\accesstoken.json" -Raw | ConvertFrom-Json
$headers = @{
    'X-Kite-Version' = '3'
    'Authorization' = "token $($cfg.API_Key):$($token.access_token)"
}

# Symbol mapping
$symbols = @{ "NIFTY" = 256265; "BANKNIFTY" = 260105; "SENSEX" = 265 }
$token = $symbols[$Symbol]

# Fetch
Write-Host "`n  Fetching $Symbol - $Date...`n" -ForegroundColor Cyan
$resp = Invoke-RestMethod -Uri "https://api.kite.trade/instruments/historical/$token/minute?from=$Date&to=$Date" -Headers $headers

# Create objects
$data = @()
$resp.data.candles | ForEach-Object {
    $data += [PSCustomObject]@{
        TIME = $_[0]
        O = [Math]::Round([double]$_[1], 2)
        H = [Math]::Round([double]$_[2], 2)
        L = [Math]::Round([double]$_[3], 2)
        C = [Math]::Round([double]$_[4], 2)
    }
}

# Display
$data | Format-Table -AutoSize
Write-Host "  Total: $($data.Count) candles`n" -ForegroundColor Green
