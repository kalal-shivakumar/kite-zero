<#
.SYNOPSIS
  Heikin-Ashi Short-only strategy for Natural Gas Mini (MCX).
.DESCRIPTION
  Streams live HA candles via Kite WebSocket for NATGASMINI. When the current
  HA candle's Close drops below the previous HA candle's Low, a Short Entry
  file is created. When it rises above the previous HA candle's High, a Short
  Exit file is created. Only one Short position at a time.
  Order files are saved to PlacedOrders/ in the script directory.
.EXAMPLE
  .\Invoke-KiteHAShortStrategy-NatGasMini.ps1
  .\Invoke-KiteHAShortStrategy-NatGasMini.ps1 -TimeFrame 3minute
  .\Invoke-KiteHAShortStrategy-NatGasMini.ps1 -TimeFrame 5minute -FullMode
#>

param(
    [string]$TradingSymbol  = 'NATGASMINI',
    [int]$InstrumentToken,
    [ValidateSet('minute','3minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame      = 'minute',
    [int]$CandlesToShow     = 10,
    [switch]$FullMode,
    [switch]$ListSymbols,
    [switch]$GetLoginUrl,
    [string]$RequestToken,
    [string]$AccessToken,
    [string]$API_Key        = '0fvxhlacu555dhp0',
    [string]$API_Secret     = '69wajxn41hj77pze3xnhw1dp442auw8t'
)

# Import the module
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

# ================================================================
# Entry point — validate & load token immediately
# ================================================================
if ($GetLoginUrl) {
    $url = 'https://kite.trade/connect/login?v=3&api_key=' + $API_Key
    Write-Host "  Login URL: $url" -ForegroundColor White
    try { Start-Process $url } catch {}
    exit 0
}

$tokenFile = Join-Path $scriptDir 'accesstoken.json'

# Resolve token: param > env > file (10h) > interactive login
if (-not $AccessToken) {
    if ($RequestToken) {
        $AccessToken = Exchange-KiteRequestToken -ApiKey $API_Key -ApiSecret $API_Secret -ReqToken $RequestToken -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    } else {
        $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
    }
}
Write-Host "  Access token ready." -ForegroundColor Green

# Build params and call module function
$ordersDir = Join-Path $scriptDir 'PlacedOrders'

$splat = @{
    TradingSymbol = $TradingSymbol
    TimeFrame     = $TimeFrame
    CandlesToShow = $CandlesToShow
    AccessToken   = $AccessToken
    API_Key       = $API_Key
    OrdersFolder  = $ordersDir
}
if ($InstrumentToken -gt 0) { $splat.InstrumentToken = $InstrumentToken }
if ($FullMode)     { $splat.FullMode     = $true }
if ($ListSymbols)  { $splat.ListSymbols  = $true }

Invoke-KiteHAShortStrategy @splat
