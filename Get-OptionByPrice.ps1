<#
.SYNOPSIS
  Fetches option chain for a specified index and finds CE/PE options at or below a target price.
.DESCRIPTION
  Gets the full option chain for the nearest expiry, fetches live LTP for all strikes,
  then returns the CE and/or PE option whose price is closest to (but not exceeding) the specified target price.
.EXAMPLE
  .\Get-OptionByPrice.ps1 -CEPrice 100 -PEPrice 80
  .\Get-OptionByPrice.ps1 -IndexName BANKNIFTY -CEPrice 150
  .\Get-OptionByPrice.ps1 -IndexName SENSEX -PEPrice 200
  .\Get-OptionByPrice.ps1 -IndexName NIFTY -CEPrice 50 -PEPrice 50
#>

param(
    [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
    [string]$IndexName,
    [double]$CEPrice = 0,
    [double]$PEPrice = 0,
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
    if (-not $PSBoundParameters.ContainsKey('IndexName') -and $cfg.IndexChoosen) { $IndexName = $cfg.IndexChoosen }
    if (-not $PSBoundParameters.ContainsKey('API_Key'))    { $API_Key    = $cfg.API_Key }
    if (-not $PSBoundParameters.ContainsKey('API_Secret')) { $API_Secret = $cfg.API_Secret }
}
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  API_Key/API_Secret not found. Set them in input.json.' -ForegroundColor Red; exit 1
}

if (-not $IndexName) { $IndexName = 'NIFTY' }

if ($CEPrice -le 0 -and $PEPrice -le 0) {
    Write-Host "  Please specify at least one: -CEPrice or -PEPrice" -ForegroundColor Red
    Write-Host "  Example: .\Get-OptionByPrice.ps1 -CEPrice 100 -PEPrice 80" -ForegroundColor Yellow
    exit 1
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

# ================================================================
# Get Index Config & Spot Price
# ================================================================
$idxConfig = Get-IndexOptionConfig -IndexName $IndexName
if (-not $idxConfig) { exit 1 }

$spotPrice = Get-KiteSpotPrice -SpotQuoteKey $idxConfig.SpotQuoteKey -Headers $headers
if ($spotPrice -le 0) {
    Write-Host "  Failed to fetch spot price for $IndexName" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  Option Chain - Find by Price" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  Index : $IndexName  |  Spot: $($spotPrice.ToString('N2'))  |  Lot: $($idxConfig.Lot)"
if ($CEPrice -gt 0) { Write-Host "  Target CE Price: <= $($CEPrice.ToString('N2'))" -ForegroundColor Green }
if ($PEPrice -gt 0) { Write-Host "  Target PE Price: <= $($PEPrice.ToString('N2'))" -ForegroundColor Green }
Write-Host ''

# ================================================================
# Fetch Option Chain & LTP
# ================================================================
function Find-OptionByPrice {
    param(
        [string]$OptionType,
        [double]$TargetPrice,
        [hashtable]$Headers,
        [hashtable]$IdxConfig
    )

    Write-Host "  Fetching $OptionType options..." -ForegroundColor DarkGray
    $optData = Get-KiteOptionInstruments -OptExchange $IdxConfig.OptExchange -UnderlyingName $IdxConfig.SearchKeyWord -OptionType $OptionType -Headers $Headers
    if (-not $optData) { return $null }

    $options = $optData.Options
    $expiry  = $optData.Expiry
    Write-Host "  Expiry: $expiry  |  Strikes: $($optData.Strikes.Count)" -ForegroundColor DarkGray

    # Fetch LTP for all strikes in batches (Kite allows ~500 instruments per call)
    $batchSize = 40
    $ltpMap = @{}

    for ($i = 0; $i -lt $options.Count; $i += $batchSize) {
        $batch = $options[$i..[Math]::Min($i + $batchSize - 1, $options.Count - 1)]
        $queryParts = @()
        foreach ($opt in $batch) {
            $queryParts += "i=$([System.Uri]::EscapeDataString("$($IdxConfig.OptExchange):$($opt.Symbol)"))"
        }
        $url = "https://api.kite.trade/quote/ltp?" + ($queryParts -join '&')

        try {
            $resp = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -ErrorAction Stop
            if ($resp.data) {
                foreach ($prop in $resp.data.PSObject.Properties) {
                    $ltpMap[$prop.Name] = [double]$prop.Value.last_price
                }
            }
        } catch {
            Write-Host "  Warning: LTP batch fetch failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Match options with LTP and find the one closest to (but <= ) target price
    $candidates = @()
    foreach ($opt in $options) {
        $key = "$($IdxConfig.OptExchange):$($opt.Symbol)"
        $ltp = if ($ltpMap.ContainsKey($key)) { $ltpMap[$key] } else { 0 }
        if ($ltp -gt 0 -and $ltp -le $TargetPrice) {
            $candidates += [PSCustomObject]@{
                Symbol  = $opt.Symbol
                Token   = $opt.Token
                Strike  = $opt.Strike
                Expiry  = $opt.Expiry
                LotSize = $opt.LotSize
                LTP     = $ltp
                Type    = $OptionType
                Diff    = $TargetPrice - $ltp
            }
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Host "  No $OptionType option found with price <= $($TargetPrice.ToString('N2'))" -ForegroundColor Yellow
        return $null
    }

    # Sort by price descending (closest to target = highest price that's still <= target)
    $best = $candidates | Sort-Object LTP -Descending | Select-Object -First 1

    # Also show top 5 candidates
    $top5 = $candidates | Sort-Object LTP -Descending | Select-Object -First 5
    return @{ Best = $best; Top5 = $top5; TotalFound = $candidates.Count }
}

# ================================================================
# Main Loop — refreshes every 30 seconds
# ================================================================
$csvFile = Join-Path $scriptDir "OptionChaindata.csv"
$loopCount = 0

while ($true) {
    $loopCount++
    $ceResult = $null
    $peResult = $null

    # Refresh spot price
    $spotPrice = Get-KiteSpotPrice -SpotQuoteKey $idxConfig.SpotQuoteKey -Headers $headers

    # ── Find CE Option ──
    if ($CEPrice -gt 0) {
        $ceResult = Find-OptionByPrice -OptionType 'CE' -TargetPrice $CEPrice -Headers $headers -IdxConfig $idxConfig
    }

    # ── Find PE Option ──
    if ($PEPrice -gt 0) {
        $peResult = Find-OptionByPrice -OptionType 'PE' -TargetPrice $PEPrice -Headers $headers -IdxConfig $idxConfig
    }

    # ── Display ──
    Clear-Host
    Write-Host ''
    Write-Host "  ================================================" -ForegroundColor Cyan
    Write-Host "  Option Chain - Find by Price (Loop #$loopCount)" -ForegroundColor Cyan
    Write-Host "  ================================================" -ForegroundColor Cyan
    Write-Host "  Index : $IndexName  |  Spot: $($spotPrice.ToString('N2'))  |  Lot: $($idxConfig.Lot)"
    if ($CEPrice -gt 0) { Write-Host "  Target CE Price: <= $($CEPrice.ToString('N2'))" -ForegroundColor Green }
    if ($PEPrice -gt 0) { Write-Host "  Target PE Price: <= $($PEPrice.ToString('N2'))" -ForegroundColor Green }
    Write-Host "  Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Refresh: 30s"
    Write-Host ''

    $fmt = '  {0,-26} {1,10} {2,10} {3,12} {4,8}'

    if ($ceResult) {
        Write-Host "  ── CE Option (closest to <= $($CEPrice.ToString('N2'))) ──" -ForegroundColor Green
        Write-Host ($fmt -f 'Symbol', 'Strike', 'LTP', 'Expiry', 'LotSize') -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * 70))
        foreach ($c in $ceResult.Top5) {
            $marker = if ($c.Symbol -eq $ceResult.Best.Symbol) { ' <-- BEST' } else { '' }
            $color = if ($c.Symbol -eq $ceResult.Best.Symbol) { 'Green' } else { 'White' }
            Write-Host (($fmt -f $c.Symbol, $c.Strike.ToString('N0'), $c.LTP.ToString('N2'), $c.Expiry, $c.LotSize) + $marker) -ForegroundColor $color
        }
        Write-Host "  ($($ceResult.TotalFound) CE options found <= $($CEPrice.ToString('N2')))" -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($peResult) {
        Write-Host "  ── PE Option (closest to <= $($PEPrice.ToString('N2'))) ──" -ForegroundColor Red
        Write-Host ($fmt -f 'Symbol', 'Strike', 'LTP', 'Expiry', 'LotSize') -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * 70))
        foreach ($c in $peResult.Top5) {
            $marker = if ($c.Symbol -eq $peResult.Best.Symbol) { ' <-- BEST' } else { '' }
            $color = if ($c.Symbol -eq $peResult.Best.Symbol) { 'Red' } else { 'White' }
            Write-Host (($fmt -f $c.Symbol, $c.Strike.ToString('N0'), $c.LTP.ToString('N2'), $c.Expiry, $c.LotSize) + $marker) -ForegroundColor $color
        }
        Write-Host "  ($($peResult.TotalFound) PE options found <= $($PEPrice.ToString('N2')))" -ForegroundColor DarkGray
        Write-Host ''
    }

    # ── Summary ──
    Write-Host "  ────────────────────────────────────────────────" -ForegroundColor Cyan
    if ($ceResult) {
        $b = $ceResult.Best
        Write-Host "  CE: $($b.Symbol) | Strike: $($b.Strike.ToString('N0')) | LTP: $($b.LTP.ToString('N2')) | Token: $($b.Token)" -ForegroundColor Green
    }
    if ($peResult) {
        $b = $peResult.Best
        Write-Host "  PE: $($b.Symbol) | Strike: $($b.Strike.ToString('N0')) | LTP: $($b.LTP.ToString('N2')) | Token: $($b.Token)" -ForegroundColor Red
    }

    # ── Export to CSV (overwrite with latest data) ──
    $csvRows = @()
    if ($ceResult -and $ceResult.Top5) {
        foreach ($c in $ceResult.Top5) {
            $csvRows += [PSCustomObject]@{
                Index    = $IndexName
                Type     = 'CE'
                Symbol   = $c.Symbol
                Strike   = $c.Strike
                LTP      = $c.LTP
                Expiry   = $c.Expiry
                Token    = $c.Token
                LotSize  = $c.LotSize
                Spot     = $spotPrice
                Target   = $CEPrice
                IsBest   = ($c.Symbol -eq $ceResult.Best.Symbol)
                FetchedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }
    }
    if ($peResult -and $peResult.Top5) {
        foreach ($c in $peResult.Top5) {
            $csvRows += [PSCustomObject]@{
                Index    = $IndexName
                Type     = 'PE'
                Symbol   = $c.Symbol
                Strike   = $c.Strike
                LTP      = $c.LTP
                Expiry   = $c.Expiry
                Token    = $c.Token
                LotSize  = $c.LotSize
                Spot     = $spotPrice
                Target   = $PEPrice
                IsBest   = ($c.Symbol -eq $peResult.Best.Symbol)
                FetchedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }
    }

    if ($csvRows.Count -gt 0) {
        $csvRows | Export-Csv -Path $csvFile -NoTypeInformation -Force
        Write-Host "  CSV: $csvFile (updated)" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  Press Ctrl+C to stop  |  Next refresh in 30s...' -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
}
