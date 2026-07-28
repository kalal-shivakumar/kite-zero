<#
.SYNOPSIS
  Fetch NIFTY option chain, find spot/ATM, and list the N nearest ITM strikes
  for CE and PE with tradingsymbol + instrument token.
.EXAMPLE
  .\Get-ITMStrikes.ps1
  .\Get-ITMStrikes.ps1 -Underlying BANKNIFTY -Count 5
#>
param(
    [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
    [string]$Underlying = 'NIFTY',
    [int]$Count = 5
)

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'KiteData.psm1') -Force

# Auth header
$cfg = Get-Content (Join-Path $root 'input.json') -Raw | ConvertFrom-Json
$ak  = $cfg.API_Key
$tok = (Get-Content (Join-Path $root 'accesstoken.json') -Raw | ConvertFrom-Json).access_token
$headers = @{ 'X-Kite-Version' = '3'; 'Authorization' = "token ${ak}:${tok}" }

$conf = Get-IndexOptionConfig -IndexName $Underlying
$spot = Get-KiteSpotPrice -SpotQuoteKey $conf.SpotQuoteKey -Headers $headers
if ($spot -le 0) { Write-Host "  Could not fetch spot price." -ForegroundColor Red; return }

$ce = Get-KiteOptionInstruments -OptExchange $conf.OptExchange -UnderlyingName $conf.SearchKeyWord -OptionType 'CE' -Headers $headers
$pe = Get-KiteOptionInstruments -OptExchange $conf.OptExchange -UnderlyingName $conf.SearchKeyWord -OptionType 'PE' -Headers $headers
if (-not $ce -or -not $pe) { Write-Host "  Could not fetch option instruments." -ForegroundColor Red; return }

$strikes = $ce.Strikes
$atm = $strikes | Sort-Object { [Math]::Abs($_ - $spot) } | Select-Object -First 1

Write-Host ""
Write-Host "  $Underlying  Spot: $spot  |  ATM Strike: $atm  |  Expiry: $($ce.Expiry)" -ForegroundColor Yellow
Write-Host ""

# CE ITM = strikes at/below ATM (option in the money when spot > strike)
$ceItmStrikes = @($strikes | Where-Object { $_ -le $atm } | Sort-Object -Descending | Select-Object -First $Count)
# PE ITM = strikes at/above ATM (option in the money when spot < strike)
$peItmStrikes = @($strikes | Where-Object { $_ -ge $atm } | Sort-Object | Select-Object -First $Count)

Write-Host "  ── $Count ITM CALLS (CE) ──" -ForegroundColor Green
Write-Host ("  {0,-10} {1,-22} {2,-14}" -f 'Strike','TradingSymbol','InstrumentToken') -ForegroundColor DarkGray
foreach ($s in $ceItmStrikes) {
    $o = $ce.Options | Where-Object { $_.Strike -eq $s } | Select-Object -First 1
    $tag = if ($s -eq $atm) { ' (ATM)' } else { '' }
    Write-Host ("  {0,-10} {1,-22} {2,-14}{3}" -f $s, $o.Symbol, $o.Token, $tag) -ForegroundColor White
}

Write-Host ""
Write-Host "  ── $Count ITM PUTS (PE) ──" -ForegroundColor Magenta
Write-Host ("  {0,-10} {1,-22} {2,-14}" -f 'Strike','TradingSymbol','InstrumentToken') -ForegroundColor DarkGray
foreach ($s in $peItmStrikes) {
    $o = $pe.Options | Where-Object { $_.Strike -eq $s } | Select-Object -First 1
    $tag = if ($s -eq $atm) { ' (ATM)' } else { '' }
    Write-Host ("  {0,-10} {1,-22} {2,-14}{3}" -f $s, $o.Symbol, $o.Token, $tag) -ForegroundColor White
}
Write-Host ""
