<#
.SYNOPSIS
  Fetch NFO option chain — all CE/PE strikes with instrument tokens and live prices.
.DESCRIPTION
  Fetches all option instruments for a given underlying (e.g. NIFTY, BANKNIFTY)
  from Kite Connect API, filters by nearest expiry (or specified expiry), and
  fetches live prices via quote API.
.PARAMETER Underlying
  The underlying symbol. Default: NIFTY. Also supports BANKNIFTY, FINNIFTY, etc.
.PARAMETER Expiry
  Specific expiry date (yyyy-MM-dd). If not set, picks the nearest expiry.
.PARAMETER OptionType
  Filter by option type: CE, PE, or ALL (both). Default: ALL.
.PARAMETER StrikeRange
  Number of strikes above and below ATM to show. Default: 10 (shows 21 strikes total).
.PARAMETER ShowAll
  Show all strikes instead of filtering around ATM.
.PARAMETER CEPrice
  Target CE option price. Picks the 1 CE strike whose LTP is closest to (but <= ) this value.
.PARAMETER PEPrice
  Target PE option price. Picks the 1 PE strike whose LTP is closest to (but <= ) this value.
.EXAMPLE
  .\Get-NFOOptionChain.ps1
  .\Get-NFOOptionChain.ps1 -Underlying BANKNIFTY
  .\Get-NFOOptionChain.ps1 -Underlying NIFTY -Expiry "2026-04-28"
  .\Get-NFOOptionChain.ps1 -Underlying NIFTY -OptionType CE -StrikeRange 5
  .\Get-NFOOptionChain.ps1 -Underlying NIFTY -ShowAll  .\.\Get-NFOOptionChain.ps1 -CEPrice 500 -PEPrice 500
  .\.\Get-NFOOptionChain.ps1 -Underlying BANKNIFTY -CEPrice 300 -PEPrice 200#>

param(
    [string]$Underlying   = 'NIFTY',
    [string]$Expiry,
    [ValidateSet('CE','PE','ALL')]
    [string]$OptionType   = 'ALL',
    [int]$StrikeRange     = 10,
    [switch]$ShowAll,
    [double]$CEPrice      = 0,
    [double]$PEPrice      = 0,
    [string]$API_Key      = '0fvxhlacu555dhp0',
    [string]$API_Secret   = '69wajxn41hj77pze3xnhw1dp442auw8t'
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

# ================================================================
# Step 1: Fetch NFO instruments
# ================================================================
Write-Host ""
Write-Host "  Fetching NFO instruments..." -ForegroundColor Cyan

try {
    $resp = Invoke-WebRequest -Uri 'https://api.kite.trade/instruments/NFO' -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Host "  Failed to fetch instruments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ================================================================
# Step 2: Parse CSV — filter options for the underlying
# ================================================================
# CSV columns: instrument_token,exchange_token,tradingsymbol,name,last_price,expiry,strike,tick_size,lot_size,instrument_type,segment,exchange
$header = ($resp.Content -split "`n")[0]
$lines = ($resp.Content -split "`n") | Select-Object -Skip 1 | Where-Object { $_.Length -gt 10 }

$underlying_upper = $Underlying.ToUpper().Trim()

$options = foreach ($line in $lines) {
    $cols = $line -split ','
    if ($cols.Count -ge 12) {
        $name = ($cols[3] -replace '"','')
        $instType = $cols[9]
        if (($name -eq $underlying_upper) -and ($instType -eq 'CE' -or $instType -eq 'PE')) {
            [PSCustomObject]@{
                Token      = [long]$cols[0]
                Symbol     = $cols[2]
                Name       = $name
                Expiry     = $cols[5]
                Strike     = [double]$cols[6]
                LotSize    = [int]$cols[8]
                Type       = $instType
            }
        }
    }
}

if (-not $options -or @($options).Count -eq 0) {
    Write-Host "  No options found for '$underlying_upper'. Try NIFTY, BANKNIFTY, FINNIFTY, etc." -ForegroundColor Red
    exit 1
}

Write-Host "  Found $(@($options).Count) option contracts for $underlying_upper." -ForegroundColor Green

# ================================================================
# Step 3: Pick expiry
# ================================================================
$allExpiries = @($options | Select-Object -ExpandProperty Expiry -Unique | Sort-Object)

if ($Expiry) {
    $selectedExpiry = $Expiry
} else {
    $selectedExpiry = $allExpiries[0]
}

$expiryOptions = @($options | Where-Object { $_.Expiry -eq $selectedExpiry })

if ($expiryOptions.Count -eq 0) {
    Write-Host "  No options for expiry '$selectedExpiry'." -ForegroundColor Red
    Write-Host "  Available expiries: $($allExpiries -join ', ')" -ForegroundColor Yellow
    exit 1
}

# Filter by option type
if ($OptionType -ne 'ALL') {
    $expiryOptions = @($expiryOptions | Where-Object { $_.Type -eq $OptionType })
}

Write-Host "  Expiry: $selectedExpiry | Contracts: $($expiryOptions.Count) | Lot Size: $($expiryOptions[0].LotSize)" -ForegroundColor White

# ================================================================
# Step 4: Get spot/underlying price to find ATM
# ================================================================
# Resolve underlying token for spot price
$spotTokenMap = @{
    'NIFTY'      = '256265'; 'BANKNIFTY'  = '260105'; 'FINNIFTY'   = '257801'
    'MIDCPNIFTY' = '288009'; 'SENSEX'     = '265'
}

$spotKey = $null
$spotPrice = 0
if ($spotTokenMap.ContainsKey($underlying_upper)) {
    $spotToken = $spotTokenMap[$underlying_upper]
    $exchange = if ($underlying_upper -eq 'SENSEX') { 'BSE' } else { 'NSE' }
    try {
        $spotResp = Invoke-RestMethod -Uri "https://api.kite.trade/quote?i=${exchange}:${spotToken}" -Headers $headers -Method Get -ErrorAction Stop
        # Kite quote keys can vary — iterate to find the right one
        foreach ($prop in $spotResp.data.PSObject.Properties) {
            if ($prop.Value.last_price -gt 0) {
                $spotPrice = $prop.Value.last_price
                break
            }
        }
        if ($spotPrice -gt 0) {
            Write-Host "  Spot Price: $spotPrice" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Could not fetch spot price." -ForegroundColor DarkGray
    }
}

# ================================================================
# Step 5: Filter strikes around ATM
# ================================================================
$allStrikes = @($expiryOptions | Select-Object -ExpandProperty Strike -Unique | Sort-Object)

if (-not $ShowAll -and $spotPrice -gt 0) {
    # Find nearest ATM strike
    $atmStrike = $allStrikes | Sort-Object { [Math]::Abs($_ - $spotPrice) } | Select-Object -First 1
    $atmIdx = [array]::IndexOf($allStrikes, $atmStrike)
    $startIdx = [Math]::Max(0, $atmIdx - $StrikeRange)
    $endIdx = [Math]::Min($allStrikes.Count - 1, $atmIdx + $StrikeRange)
    $filteredStrikes = $allStrikes[$startIdx..$endIdx]
    $expiryOptions = @($expiryOptions | Where-Object { $filteredStrikes -contains $_.Strike })
    Write-Host "  ATM Strike: $atmStrike | Showing $($filteredStrikes.Count) strikes ($StrikeRange above/below)" -ForegroundColor White
} elseif (-not $ShowAll) {
    Write-Host "  Showing all $($allStrikes.Count) strikes (no spot price to determine ATM)" -ForegroundColor DarkGray
}

# ================================================================
# Step 6: Fetch live prices in batches (Kite allows ~500 per request)
# ================================================================
Write-Host "  Fetching live prices for $($expiryOptions.Count) contracts..." -ForegroundColor Cyan

$batchSize = 400
$quoteData = @{}

for ($b = 0; $b -lt $expiryOptions.Count; $b += $batchSize) {
    $batch = $expiryOptions[$b..([Math]::Min($b + $batchSize - 1, $expiryOptions.Count - 1))]
    $queryParts = ($batch | ForEach-Object { "i=NFO:$($_.Symbol)" }) -join '&'
    $quoteUrl = "https://api.kite.trade/quote?$queryParts"
    try {
        $qResp = Invoke-RestMethod -Uri $quoteUrl -Headers $headers -Method Get -ErrorAction Stop
        if ($qResp.data) {
            foreach ($prop in $qResp.data.PSObject.Properties) {
                $quoteData[$prop.Name] = $prop.Value
            }
        }
    } catch {
        Write-Host "  Warning: Failed to fetch batch $([Math]::Floor($b/$batchSize)+1): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ================================================================
# Step 7: Price-based single-pick filter (CEPrice / PEPrice) — live loop
# ================================================================
if ($CEPrice -gt 0 -or $PEPrice -gt 0) {
    Write-Host ""
    Write-Host "  PRICE PICK MODE: $underlying_upper | Expiry: $selectedExpiry | Refreshing every 30s (Ctrl+C to exit)" -ForegroundColor Cyan
    Write-Host ""

    $iteration = 0
    while ($true) {
        $iteration++
        $now = Get-Date -Format 'HH:mm:ss'

        # Re-fetch quotes for all expiry options each cycle
        $quoteData = @{}
        for ($b = 0; $b -lt $expiryOptions.Count; $b += $batchSize) {
            $batch = $expiryOptions[$b..([Math]::Min($b + $batchSize - 1, $expiryOptions.Count - 1))]
            $queryParts = ($batch | ForEach-Object { "i=NFO:$($_.Symbol)" }) -join '&'
            $quoteUrl = "https://api.kite.trade/quote?$queryParts"
            try {
                $qResp = Invoke-RestMethod -Uri $quoteUrl -Headers $headers -Method Get -ErrorAction Stop
                if ($qResp.data) {
                    foreach ($prop in $qResp.data.PSObject.Properties) {
                        $quoteData[$prop.Name] = $prop.Value
                    }
                }
            } catch {
                Write-Host "  [$now] Warning: quote fetch failed — $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Re-fetch spot price
        if ($spotTokenMap.ContainsKey($underlying_upper)) {
            $spotToken = $spotTokenMap[$underlying_upper]
            $exchange = if ($underlying_upper -eq 'SENSEX') { 'BSE' } else { 'NSE' }
            try {
                $spotResp = Invoke-RestMethod -Uri "https://api.kite.trade/quote?i=${exchange}:${spotToken}" -Headers $headers -Method Get -ErrorAction Stop
                foreach ($prop in $spotResp.data.PSObject.Properties) {
                    if ($prop.Value.last_price -gt 0) { $spotPrice = $prop.Value.last_price; break }
                }
            } catch { }
        }

        # Pick best CE
        $pickedCE = $null
        if ($CEPrice -gt 0) {
            $ceCandidates = foreach ($opt in ($expiryOptions | Where-Object { $_.Type -eq 'CE' })) {
                $key = "NFO:$($opt.Symbol)"
                if ($quoteData.ContainsKey($key) -and $quoteData[$key].last_price -gt 0 -and $quoteData[$key].last_price -le $CEPrice) {
                    [PSCustomObject]@{ Option = $opt; LTP = $quoteData[$key].last_price; Quote = $quoteData[$key] }
                }
            }
            if ($ceCandidates) {
                $pickedCE = @($ceCandidates) | Sort-Object { $CEPrice - $_.LTP } | Select-Object -First 1
            }
        }

        # Pick best PE
        $pickedPE = $null
        if ($PEPrice -gt 0) {
            $peCandidates = foreach ($opt in ($expiryOptions | Where-Object { $_.Type -eq 'PE' })) {
                $key = "NFO:$($opt.Symbol)"
                if ($quoteData.ContainsKey($key) -and $quoteData[$key].last_price -gt 0 -and $quoteData[$key].last_price -le $PEPrice) {
                    [PSCustomObject]@{ Option = $opt; LTP = $quoteData[$key].last_price; Quote = $quoteData[$key] }
                }
            }
            if ($peCandidates) {
                $pickedPE = @($peCandidates) | Sort-Object { $PEPrice - $_.LTP } | Select-Object -First 1
            }
        }

        # Clear previous output and display
        Clear-Host
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor Cyan
        Write-Host "  PRICE PICK: $underlying_upper | Expiry: $selectedExpiry" -ForegroundColor Cyan
        Write-Host "  Spot: $spotPrice | Refresh #$iteration @ $now | Every 30s" -ForegroundColor Cyan
        Write-Host "  Target: CE <= $CEPrice | PE <= $PEPrice" -ForegroundColor Cyan
        Write-Host "  ============================================================" -ForegroundColor Cyan
        Write-Host ""

        $fmt = "  {0,4} {1,12} {2,-30} {3,8} {4,10} {5,10} {6,10} {7,10}"
        Write-Host ($fmt -f "Type","Token","Symbol","Strike","LTP","OI","Volume","LotSize") -ForegroundColor Cyan
        Write-Host ("  " + ("-" * 105)) -ForegroundColor DarkGray

        if ($CEPrice -gt 0) {
            if ($pickedCE) {
                $o = $pickedCE.Option; $q = $pickedCE.Quote
                Write-Host ($fmt -f "CE", $o.Token, $o.Symbol, $o.Strike, ('{0:N2}' -f $q.last_price), $q.oi, $q.volume, $o.LotSize) -ForegroundColor Green
            } else {
                Write-Host "  CE: No option found with LTP <= $CEPrice" -ForegroundColor Red
            }
        }
        if ($PEPrice -gt 0) {
            if ($pickedPE) {
                $o = $pickedPE.Option; $q = $pickedPE.Quote
                Write-Host ($fmt -f "PE", $o.Token, $o.Symbol, $o.Strike, ('{0:N2}' -f $q.last_price), $q.oi, $q.volume, $o.LotSize) -ForegroundColor Green
            } else {
                Write-Host "  PE: No option found with LTP <= $PEPrice" -ForegroundColor Red
            }
        }

        Write-Host ("  " + ("-" * 105)) -ForegroundColor DarkGray
        Write-Host "  Lot: $($expiryOptions[0].LotSize) | Press Ctrl+C to stop" -ForegroundColor DarkGray
        Write-Host ""

        # Write picked CE/PE to shared JSON so other scripts (CE-Trader.ps1) can read
        $sharedFile = Join-Path $scriptDir 'OptionPick.json'
        $sharedData = @{
            Underlying = $underlying_upper
            Expiry     = $selectedExpiry
            Spot       = $spotPrice
            Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Iteration  = $iteration
            LotSize    = $expiryOptions[0].LotSize
        }
        if ($pickedCE) {
            $sharedData.CE = @{
                Token  = $pickedCE.Option.Token
                Symbol = $pickedCE.Option.Symbol
                Strike = $pickedCE.Option.Strike
                LTP    = $pickedCE.Quote.last_price
                OI     = $pickedCE.Quote.oi
                Volume = $pickedCE.Quote.volume
            }
        }
        if ($pickedPE) {
            $sharedData.PE = @{
                Token  = $pickedPE.Option.Token
                Symbol = $pickedPE.Option.Symbol
                Strike = $pickedPE.Option.Strike
                LTP    = $pickedPE.Quote.last_price
                OI     = $pickedPE.Quote.oi
                Volume = $pickedPE.Quote.volume
            }
        }
        $sharedData | ConvertTo-Json -Depth 3 | Set-Content $sharedFile -Force

        # Wait 30 seconds before next refresh
        Start-Sleep -Seconds 30
    }
}

# ================================================================
# Step 8: Display option chain
# ================================================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  OPTION CHAIN: $underlying_upper | Expiry: $selectedExpiry" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

if ($OptionType -eq 'ALL') {
    # Display as option chain with CE on left, PE on right
    $strikes = @($expiryOptions | Select-Object -ExpandProperty Strike -Unique | Sort-Object)

    $fmt = "  {0,12} {1,10} {2,10} {3,10} {4,10} {5,8} {6,10} {7,10} {8,10} {9,10} {10,12}"
    Write-Host ($fmt -f "CE Token","CE LTP","CE OI","CE Vol","CE Chg","Strike","PE Chg","PE Vol","PE OI","PE LTP","PE Token") -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 125)) -ForegroundColor DarkGray

    foreach ($strike in $strikes) {
        $ce = $expiryOptions | Where-Object { $_.Strike -eq $strike -and $_.Type -eq 'CE' } | Select-Object -First 1
        $pe = $expiryOptions | Where-Object { $_.Strike -eq $strike -and $_.Type -eq 'PE' } | Select-Object -First 1

        $ceToken = '-'; $ceLTP = '-'; $ceOI = '-'; $ceVol = '-'; $ceChg = '-'
        $peToken = '-'; $peLTP = '-'; $peOI = '-'; $peVol = '-'; $peChg = '-'

        if ($ce) {
            $ceToken = $ce.Token
            $ceKey = "NFO:$($ce.Symbol)"
            if ($quoteData.ContainsKey($ceKey)) {
                $q = $quoteData[$ceKey]
                $ceLTP = '{0:N2}' -f $q.last_price
                $ceOI = $q.oi
                $ceVol = $q.volume
                $ceChg = '{0:N2}' -f ($q.last_price - $q.ohlc.close)
            }
        }

        if ($pe) {
            $peToken = $pe.Token
            $peKey = "NFO:$($pe.Symbol)"
            if ($quoteData.ContainsKey($peKey)) {
                $q = $quoteData[$peKey]
                $peLTP = '{0:N2}' -f $q.last_price
                $peOI = $q.oi
                $peVol = $q.volume
                $peChg = '{0:N2}' -f ($q.last_price - $q.ohlc.close)
            }
        }

        # Highlight ATM strike
        $isATM = ($spotPrice -gt 0 -and [Math]::Abs($strike - $spotPrice) -eq ($allStrikes | Sort-Object { [Math]::Abs($_ - $spotPrice) } | Select-Object -First 1 | ForEach-Object { [Math]::Abs($_ - $spotPrice) }))
        $strikeStr = '{0:N0}' -f $strike
        $color = if ($isATM) { 'Yellow' } else { 'White' }

        Write-Host ($fmt -f $ceToken, $ceLTP, $ceOI, $ceVol, $ceChg, $strikeStr, $peChg, $peVol, $peOI, $peLTP, $peToken) -ForegroundColor $color
    }
} else {
    # Single type — flat list
    $sorted = $expiryOptions | Sort-Object Strike
    $fmt = "  {0,12} {1,-30} {2,8} {3,10} {4,10} {5,10} {6,10}"
    Write-Host ($fmt -f "Token","Symbol","Strike","LTP","OI","Volume","Change") -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 95)) -ForegroundColor DarkGray

    foreach ($opt in $sorted) {
        $key = "NFO:$($opt.Symbol)"
        $ltp = '-'; $oi = '-'; $vol = '-'; $chg = '-'

        if ($quoteData.ContainsKey($key)) {
            $q = $quoteData[$key]
            $ltp = '{0:N2}' -f $q.last_price
            $oi  = $q.oi
            $vol = $q.volume
            $chg = '{0:N2}' -f ($q.last_price - $q.ohlc.close)
        }

        Write-Host ($fmt -f $opt.Token, $opt.Symbol, $opt.Strike, $ltp, $oi, $vol, $chg)
    }
}

Write-Host ""
Write-Host ("  " + ("-" * 125)) -ForegroundColor DarkGray
Write-Host "  Underlying: $underlying_upper | Spot: $spotPrice | Expiry: $selectedExpiry | Contracts: $($expiryOptions.Count) | Lot: $($expiryOptions[0].LotSize)" -ForegroundColor Green
Write-Host ""
Write-Host "  Available expiries: $($allExpiries[0..5] -join ', ')$(if($allExpiries.Count -gt 6){', ...'})" -ForegroundColor DarkGray
Write-Host "  Use -Expiry `"yyyy-MM-dd`" to select a different expiry" -ForegroundColor DarkGray
Write-Host ""
