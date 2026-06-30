# docker-entrypoint.ps1
# Generates input.json from environment variables and starts the trading bot

$ErrorActionPreference = 'Stop'

Write-Host "  Starting Trading Bot Container..." -ForegroundColor Cyan
Write-Host "  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# Build input.json from environment variables
$config = @{
    API_Key                  = $env:KITE_API_KEY
    API_Secret               = $env:KITE_API_SECRET
    TradingSymbol            = if ($env:TRADING_SYMBOL) { $env:TRADING_SYMBOL } else { 'Nifty' }
    InstrumentToken          = if ($env:INSTRUMENT_TOKEN) { [int]$env:INSTRUMENT_TOKEN } else { 0 }
    TimeFrame                = if ($env:TIME_FRAME) { $env:TIME_FRAME } else { '30second' }
    CandlesToShow            = if ($env:CANDLES_TO_SHOW) { [int]$env:CANDLES_TO_SHOW } else { 10 }
    FullMode                 = if ($env:FULL_MODE -eq 'true') { $true } else { $false }
    IndexChoosen             = if ($env:INDEX_CHOOSEN) { $env:INDEX_CHOOSEN } else { 'Nifty' }
    NoOfLotsPurchaseAtaTime  = if ($env:NO_OF_LOTS) { [int]$env:NO_OF_LOTS } else { 1 }
    AmountToTrade            = if ($env:AMOUNT_TO_TRADE) { [double]$env:AMOUNT_TO_TRADE } else { 0 }
    Product                  = if ($env:PRODUCT) { $env:PRODUCT } else { 'NRML' }
    StartTime                = if ($env:START_TIME) { $env:START_TIME } else { '09:16:01' }
    StopTime                 = if ($env:STOP_TIME) { $env:STOP_TIME } else { '15:30:00' }
    Order_type               = if ($env:ORDER_TYPE) { $env:ORDER_TYPE } else { 'MARKET' }
    ModeOfTrading            = if ($env:MODE_OF_TRADING) { $env:MODE_OF_TRADING } else { 'Option_Buyer' }
    ATMOffset                = if ($env:ATM_OFFSET) { [int]$env:ATM_OFFSET } else { 1 }
    Variety                  = if ($env:VARIETY) { $env:VARIETY } else { 'regular' }
    MarketProtection         = if ($env:MARKET_PROTECTION) { [int]$env:MARKET_PROTECTION } else { 2 }
    ExitTrade                = if ($env:EXIT_TRADE) { $env:EXIT_TRADE } else { 'yes' }
    SLCandlesLookback        = if ($env:SL_CANDLES_LOOKBACK) { [int]$env:SL_CANDLES_LOOKBACK } else { 1 }
    SLTriggerOffset          = if ($env:SL_TRIGGER_OFFSET) { [double]$env:SL_TRIGGER_OFFSET } else { 0.5 }
}

$config | ConvertTo-Json | Set-Content -Path '/app/input.json' -Force

# Write access token file if provided
if ($env:KITE_ACCESS_TOKEN) {
    @{
        access_token = $env:KITE_ACCESS_TOKEN
        saved_at     = (Get-Date -Format 'o')
        user         = 'container'
    } | ConvertTo-Json | Set-Content -Path '/app/accesstoken.json' -Force
    Write-Host "  Access token configured." -ForegroundColor Green
}

Write-Host "  Config:" -ForegroundColor Yellow
Write-Host "    Symbol: $($config.TradingSymbol) | Index: $($config.IndexChoosen)" -ForegroundColor Gray
Write-Host "    TimeFrame: $($config.TimeFrame) | Product: $($config.Product)" -ForegroundColor Gray
Write-Host "    Lots: $($config.NoOfLotsPurchaseAtaTime) | Window: $($config.StartTime)-$($config.StopTime)" -ForegroundColor Gray

# Run the trading bot
Write-Host "`n  Launching Long-Short-Combined strategy..." -ForegroundColor Cyan
& /app/Long-Short-Combined.ps1 -AccessToken $env:KITE_ACCESS_TOKEN
