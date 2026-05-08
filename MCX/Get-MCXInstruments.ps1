<#
.SYNOPSIS
  List all MCX commodity instruments with current prices.
.EXAMPLE
  .\Get-MCXInstruments.ps1
#>

param(
    [string]$API_Key    = '0fvxhlacu555dhp0',
    [string]$API_Secret = '69wajxn41hj77pze3xnhw1dp442auw8t'
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$tokenFile = Join-Path $scriptDir 'accesstoken.json'

# Load access token
if (Test-Path $tokenFile) {
    $tokenData = Get-Content $tokenFile -Raw | ConvertFrom-Json
    $AccessToken = $tokenData.access_token
} else {
    Write-Host "  No access token found. Run Get-KiteLiveCandles.ps1 first." -ForegroundColor Red
    exit 1
}

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

# MCX standard lot sizes (exchange-defined, quantity per lot)
$mcxLotSizes = @{
    'GOLD'        = 100     # grams
    'GOLDM'       = 10      # grams (Mini)
    'GOLDGUINEA'  = 8       # grams
    'GOLDPETAL'   = 1       # gram
    'GOLDTEN'     = 10      # grams
    'SILVER'      = 30      # kg
    'SILVERM'     = 5       # kg (Mini)
    'SILVERMIC'   = 1       # kg (Micro)
    'CRUDEOIL'    = 100     # barrels
    'CRUDEOILM'   = 10      # barrels (Mini)
    'NATURALGAS'  = 1250    # mmBtu
    'NATGASMINI'  = 250     # mmBtu (Mini)
    'COPPER'      = 2500    # kg
    'ALUMINIUM'   = 5000    # kg
    'ALUMINI'     = 1000    # kg (Mini)
    'ZINC'        = 5000    # kg
    'ZINCMINI'    = 1000    # kg (Mini)
    'LEAD'        = 5000    # kg
    'LEADMINI'    = 1000    # kg (Mini)
    'NICKEL'      = 1500    # kg
    'COTTON'      = 25      # bales
    'MENTHAOIL'   = 360     # kg
    'CARDAMOM'    = 100     # kg
    'KAPAS'       = 20      # bales
    'COTTONOIL'   = 10      # MT
    'STEELREBAR'  = 10      # MT
    'ELECDMBL'    = 1       # unit
    'MCXBULLDEX'  = 50      # unit
    'MCXMETLDEX'  = 50      # unit
}

# Step 1: Fetch all MCX instruments
Write-Host ""
Write-Host "  Fetching MCX instruments..." -ForegroundColor Cyan
try {
    $resp = Invoke-WebRequest -Uri 'https://api.kite.trade/instruments/MCX' -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Host "  Failed to fetch instruments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 2: Parse CSV - get nearest-month FUT contracts (one per commodity)
$lines = ($resp.Content -split "`n") | Where-Object { $_ -match ',FUT,MCX-FUT,MCX' }

# Parse into objects
$instruments = foreach ($line in $lines) {
    $cols = $line -split ','
    if ($cols.Count -ge 12) {
        [PSCustomObject]@{
            Token     = $cols[0]
            ExchToken = $cols[1]
            Symbol    = $cols[2]
            Name      = ($cols[3] -replace '"','')
            Expiry    = $cols[5]
            LotSize   = $cols[8]
        }
    }
}

# Group by name + pick nearest expiry per commodity
$nearest = $instruments | Group-Object Name | ForEach-Object {
    $_.Group | Sort-Object Expiry | Select-Object -First 1
}

# Step 3: Fetch quotes for all nearest-month futures
Write-Host "  Fetching live prices for $($nearest.Count) commodities..." -ForegroundColor Cyan

# Build query string (Kite quote API accepts multiple i= params)
$queryParts = ($nearest | ForEach-Object { "i=MCX:$($_.Symbol)" }) -join '&'
$quoteUrl = "https://api.kite.trade/quote?$queryParts"

try {
    $quoteResp = Invoke-RestMethod -Uri $quoteUrl -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Host "  Failed to fetch quotes: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Listing instruments without prices..." -ForegroundColor Yellow
    $quoteResp = $null
}

# Step 4: Display table
Write-Host ""
$fmt = "  {0,-30} {1,12} {2,10} {3,10} {4,10} {5,10} {6,8} {7,-12}"
Write-Host ($fmt -f "Symbol", "Token", "LTP", "Open", "High", "Low", "LotSize", "Expiry") -ForegroundColor Cyan
Write-Host ("  " + ("-" * 108)) -ForegroundColor DarkGray

foreach ($inst in ($nearest | Sort-Object Name)) {
    $key = "MCX:$($inst.Symbol)"
    $ltp  = '-'
    $open = '-'
    $high = '-'
    $low  = '-'

    if ($quoteResp -and $quoteResp.data -and $quoteResp.data.PSObject.Properties[$key]) {
        $q = $quoteResp.data.$key
        $ltp  = '{0:N2}' -f $q.last_price
        $open = '{0:N2}' -f $q.ohlc.open
        $high = '{0:N2}' -f $q.ohlc.high
        $low  = '{0:N2}' -f $q.ohlc.low
    }

    $lot = if ($mcxLotSizes.ContainsKey($inst.Name)) { $mcxLotSizes[$inst.Name] } else { $inst.LotSize }

    Write-Host ($fmt -f $inst.Symbol, $inst.Token, $ltp, $open, $high, $low, $lot, $inst.Expiry)
}

Write-Host ""
Write-Host "  Total: $($nearest.Count) commodities" -ForegroundColor Green
Write-Host ""
