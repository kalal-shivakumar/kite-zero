<#
.SYNOPSIS
  Live tick streaming via Kite Connect WebSocket + candle builder.
.DESCRIPTION
  Connects to wss://ws.kite.trade, subscribes to instruments,
  parses binary tick packets per Kite docs, builds OHLCV candles.
  On first run (or after 10 hours), automatically prompts for login.
  Ref: https://kite.trade/docs/connect/v3/websocket/
.EXAMPLE
  .\Get-KiteLiveCandles.ps1
  .\Get-KiteLiveCandles.ps1 -TradingSymbol BANKNIFTY
  .\Get-KiteLiveCandles.ps1 -TradingSymbol RELIANCE -TimeFrame 5minute
  .\Get-KiteLiveCandles.ps1 -TradingSymbol SILVERM -TimeFrame 3minute -FullMode
  .\Get-KiteLiveCandles.ps1 -InstrumentToken 260105 -TradingSymbol BANKNIFTY
  .\Get-KiteLiveCandles.ps1 -ListSymbols
#>

param(
    [string]$TradingSymbol  = 'NIFTY',
    [int]$InstrumentToken,
    [ValidateSet('15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame      = '5minute',
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
    $url = 'https://kite.zerodha.com/connect/login?api_key=' + $API_Key
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
$splat = @{
    TradingSymbol = $TradingSymbol
    TimeFrame     = $TimeFrame
    CandlesToShow = $CandlesToShow
    AccessToken   = $AccessToken
    API_Key       = $API_Key
}
if ($InstrumentToken -gt 0) { $splat.InstrumentToken = $InstrumentToken }
if ($FullMode)     { $splat.FullMode     = $true }
if ($ListSymbols)  { $splat.ListSymbols  = $true }

Get-KiteLiveCandles @splat
