<#
.SYNOPSIS
  Fetches and displays the complete option chain for an index with live LTP,
  and provides a function to find the strike for a given spot price + offset.
.DESCRIPTION
  - Loads all CE & PE instruments for the nearest expiry from Kite API
  - Fetches live LTP for spot and all option strikes in bulk
  - Displays a formatted option chain table
  - Exposes Find-StrikeByOffset to get the exact strike symbol/token/LTP
    given the current index LTP and an ATM offset
.EXAMPLE
  .\Get-NFOOptionChain.ps1
  .\Get-NFOOptionChain.ps1 -IndexChoosen BANKNIFTY
  .\Get-NFOOptionChain.ps1 -IndexChoosen NIFTY -ATMOffset -2
  .\Get-NFOOptionChain.ps1 -IndexChoosen NIFTY -ATMOffset 3 -OptionType PE
#>

param(
    [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
    [string]$IndexChoosen,
    [int]$ATMOffset = 0,
    [ValidateSet('CE','PE','BOTH')]
    [string]$OptionType = 'BOTH',
    [int]$StrikesAroundATM = 15,
    [string]$API_Key,
    [string]$API_Secret
)

# ================================================================
# Module & Config
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) {
    Write-Host '  ERROR: input.json not found.' -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

if (-not $PSBoundParameters.ContainsKey('API_Key'))       { $API_Key       = $cfg.API_Key }
if (-not $PSBoundParameters.ContainsKey('API_Secret'))    { $API_Secret    = $cfg.API_Secret }
if (-not $PSBoundParameters.ContainsKey('IndexChoosen'))  { $IndexChoosen  = $cfg.IndexChoosen }

# Normalize index name
$idxMap = @{ 'NIFTY'='NIFTY'; 'BANKNIFTY'='BANKNIFTY'; 'FINNIFTY'='FinNifty'; 'MIDCPNIFTY'='MIDCPNIFTY'; 'SENSEX'='SENSEX' }
if ($idxMap.ContainsKey($IndexChoosen.ToUpper())) { $IndexChoosen = $idxMap[$IndexChoosen.ToUpper()] }

# ================================================================
# Auth
# ================================================================
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  ERROR: API_Key/API_Secret missing.' -ForegroundColor Red
    exit 1
}

$tokenFile = Join-Path $scriptDir 'accesstoken.json'
$AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}

# Validate token
try {
    $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
    Write-Host "  Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
} catch {
    Write-Host "  Token invalid. Re-authenticating..." -ForegroundColor Yellow
    Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
}

# ================================================================
# Index config
# ================================================================
$IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots 1
if (-not $IndexConfig) { exit 1 }

$optExchange    = $IndexConfig.OptExchange
$underlyingName = $IndexConfig.SearchKeyWord
$spotQuoteKey   = $IndexConfig.SpotQuoteKey
$exchange       = $IndexConfig.exchange
$lotSize        = $IndexConfig.Lot

# ================================================================
# Fetch instruments (full CSV from exchange)
# ================================================================
Write-Host ""
Write-Host "  Fetching $optExchange instruments for $underlyingName..." -ForegroundColor Yellow

try {
    $resp = Invoke-WebRequest -Uri "https://api.kite.trade/instruments/$optExchange" -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Host "  Failed to fetch instruments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$lines = ($resp.Content -split "`n") | Select-Object -Skip 1 | Where-Object { $_.Length -gt 10 }

# Parse ALL options for this underlying (both CE and PE)
$allOptions = foreach ($line in $lines) {
    $cols = $line -split ','
    if ($cols.Count -ge 12) {
        $name     = ($cols[3] -replace '"','').Trim()
        $instType = ($cols[9] -replace '"','').Trim()
        if (($name -eq $underlyingName) -and ($instType -eq 'CE' -or $instType -eq 'PE')) {
            [PSCustomObject]@{
                Token      = [long]$cols[0]
                Exchange   = ($cols[1] -replace '"','').Trim()
                Symbol     = ($cols[2] -replace '"','').Trim()
                Name       = $name
                LastPrice  = [double]$cols[4]
                Expiry     = ($cols[5] -replace '"','').Trim()
                Strike     = [double]$cols[6]
                TickSize   = [double]$cols[7]
                LotSize    = [int]$cols[8]
                Type       = $instType
                Segment    = ($cols[10] -replace '"','').Trim()
                ExchangeToken = ($cols[11] -replace '"','').Trim()
            }
        }
    }
}

if (-not $allOptions -or @($allOptions).Count -eq 0) {
    Write-Host "  No options found for '$underlyingName'." -ForegroundColor Red
    exit 1
}

# Pick nearest expiry
$today = (Get-Date).ToString('yyyy-MM-dd')
$allExpiries = @($allOptions | Select-Object -ExpandProperty Expiry -Unique | Sort-Object)
$nearestExpiry = $allExpiries | Where-Object { $_ -ge $today } | Select-Object -First 1
if (-not $nearestExpiry) {
    Write-Host "  No valid future expiry found." -ForegroundColor Red
    exit 1
}

# Filter to nearest expiry
$expiryOptions = @($allOptions | Where-Object { $_.Expiry -eq $nearestExpiry })
$ceOptions = @($expiryOptions | Where-Object { $_.Type -eq 'CE' } | Sort-Object Strike)
$peOptions = @($expiryOptions | Where-Object { $_.Type -eq 'PE' } | Sort-Object Strike)
[double[]]$allStrikes = @($expiryOptions | Select-Object -ExpandProperty Strike -Unique | Sort-Object)

# Update lot size from exchange data
$exchangeLotSize = if ($ceOptions.Count -gt 0) { [int]$ceOptions[0].LotSize } elseif ($peOptions.Count -gt 0) { [int]$peOptions[0].LotSize } else { $lotSize }
if ($exchangeLotSize -gt 0) { $lotSize = $exchangeLotSize }

Write-Host "  Expiry: $nearestExpiry | All Expiries: $($allExpiries.Count) | CE: $($ceOptions.Count) | PE: $($peOptions.Count) | Strikes: $($allStrikes.Count) | Lot: $lotSize" -ForegroundColor Green

# ================================================================
# Fetch spot price
# ================================================================
$spotPrice = Get-KiteSpotPrice -SpotQuoteKey $spotQuoteKey -Headers $headers
if ($spotPrice -le 0) {
    Write-Host "  WARNING: Could not fetch spot price for $spotQuoteKey" -ForegroundColor Yellow
}
Write-Host "  Spot LTP: $($spotPrice.ToString('N2'))" -ForegroundColor Cyan

# ================================================================
# Find ATM and filter strikes around it
# ================================================================
$atmIndex = 0
$minDist = [Math]::Abs($allStrikes[0] - $spotPrice)
for ($i = 1; $i -lt $allStrikes.Count; $i++) {
    $dist = [Math]::Abs($allStrikes[$i] - $spotPrice)
    if ($dist -lt $minDist) {
        $minDist = $dist
        $atmIndex = $i
    }
}
$atmStrike = $allStrikes[$atmIndex]

$startIdx = [Math]::Max(0, $atmIndex - $StrikesAroundATM)
$endIdx   = [Math]::Min($allStrikes.Count - 1, $atmIndex + $StrikesAroundATM)
$visibleStrikes = $allStrikes[$startIdx..$endIdx]

Write-Host "  ATM Strike: $atmStrike | Showing $($visibleStrikes.Count) strikes around ATM" -ForegroundColor Cyan

# ================================================================
# Fetch live LTP for visible strikes (batch API call)
# ================================================================
Write-Host "  Fetching live LTP for $($visibleStrikes.Count * 2) options..." -ForegroundColor Yellow

$ltpMap = @{}
$queryParts = [System.Collections.Generic.List[string]]::new()

foreach ($strike in $visibleStrikes) {
    $ce = $ceOptions | Where-Object { $_.Strike -eq $strike } | Select-Object -First 1
    $pe = $peOptions | Where-Object { $_.Strike -eq $strike } | Select-Object -First 1
    if ($ce) { $queryParts.Add("i=$([System.Uri]::EscapeDataString("${optExchange}:$($ce.Symbol)"))") }
    if ($pe) { $queryParts.Add("i=$([System.Uri]::EscapeDataString("${optExchange}:$($pe.Symbol)"))") }
}

# Kite API allows ~200 instruments per call, batch if needed
$batchSize = 200
for ($b = 0; $b -lt $queryParts.Count; $b += $batchSize) {
    $batchEnd = [Math]::Min($b + $batchSize - 1, $queryParts.Count - 1)
    $batch = $queryParts[$b..$batchEnd]
    $ltpUrl = "https://api.kite.trade/quote/ltp?" + ($batch -join '&')
    try {
        $ltpResp = Invoke-RestMethod -Uri $ltpUrl -Headers $headers -Method Get -ErrorAction Stop
        if ($ltpResp.data) {
            foreach ($key in $ltpResp.data.PSObject.Properties) {
                $sym = ($key.Name -split ':')[1]
                $ltpMap[$sym] = [double]$key.Value.last_price
            }
        }
    } catch {
        Write-Host "  LTP fetch failed for batch: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# (Option chain display + ATM details are now in the continuous loop below)

# ================================================================
# FUNCTION: Find-StrikeByOffset
# Given spot LTP and offset, returns the CE/PE option details
# Offset: 0 = ATM, +1 = 1 OTM, -1 = 1 ITM (relative to CE)
# For PE: signs are inverted internally
# ================================================================
function Find-StrikeByOffset {
    param(
        [Parameter(Mandatory=$true)]
        [double]$SpotLTP,
        [int]$Offset = 0,
        [ValidateSet('CE','PE')]
        [string]$Side = 'CE'
    )

    # Find ATM index using manual loop (reliable with typed array)
    $idx = 0
    $best = [Math]::Abs($allStrikes[0] - $SpotLTP)
    for ($i = 1; $i -lt $allStrikes.Count; $i++) {
        $d = [Math]::Abs($allStrikes[$i] - $SpotLTP)
        if ($d -lt $best) {
            $best = $d
            $idx = $i
        }
    }

    $targetIdx = $idx + $Offset
    if ($targetIdx -lt 0) { $targetIdx = 0 }
    if ($targetIdx -ge $allStrikes.Count) { $targetIdx = $allStrikes.Count - 1 }
    $targetStrike = $allStrikes[$targetIdx]
    $atmStrikeVal = $allStrikes[$idx]

    $pool = if ($Side -eq 'CE') { $ceOptions } else { $peOptions }
    $match = $pool | Where-Object { [double]$_.Strike -eq [double]$targetStrike } | Select-Object -First 1

    if (-not $match) {
        Write-Host "  No $Side option at strike $targetStrike" -ForegroundColor Red
        return $null
    }

    $ltp = if ($ltpMap.ContainsKey($match.Symbol)) { $ltpMap[$match.Symbol] } else { 0 }

    return [PSCustomObject]@{
        Side          = $Side
        Strike        = $match.Strike
        ATMStrike     = $atmStrikeVal
        Offset        = $Offset
        Symbol        = $match.Symbol
        Token         = $match.Token
        Exchange      = $match.Exchange
        LotSize       = $match.LotSize
        Expiry        = $match.Expiry
        LTP           = $ltp
        SpotLTP       = $SpotLTP
        Moneyness     = if ($Side -eq 'CE') {
                            if ($match.Strike -lt $SpotLTP) { 'ITM' } elseif ($match.Strike -eq $atmStrikeVal) { 'ATM' } else { 'OTM' }
                        } else {
                            if ($match.Strike -gt $SpotLTP) { 'ITM' } elseif ($match.Strike -eq $atmStrikeVal) { 'ATM' } else { 'OTM' }
                        }
    }
}

# ================================================================
# CONTINUOUS LOOP: Refresh spot + LTP + ATM details every cycle
# Press Ctrl+C to stop
# ================================================================
$refreshInterval = 3  # seconds between refreshes
$iteration = 0
$nullCount = 0

Write-Host ""
Write-Host "  Starting continuous option chain monitor (refresh every ${refreshInterval}s)..." -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $iteration++
    $loopStart = Get-Date
    $nullsThisLoop = [System.Collections.Generic.List[string]]::new()

    # ── 1. Refresh spot price ──
    $spotPrice = Get-KiteSpotPrice -SpotQuoteKey $spotQuoteKey -Headers $headers
    if ($spotPrice -le 0) {
        $nullsThisLoop.Add("SpotPrice returned 0/null")
    }

    # ── 2. Recalculate ATM ──
    $atmIndex = 0
    $minDist = [Math]::Abs($allStrikes[0] - $spotPrice)
    for ($i = 1; $i -lt $allStrikes.Count; $i++) {
        $dist = [Math]::Abs($allStrikes[$i] - $spotPrice)
        if ($dist -lt $minDist) {
            $minDist = $dist
            $atmIndex = $i
        }
    }
    $atmStrike = $allStrikes[$atmIndex]

    $startIdx = [Math]::Max(0, $atmIndex - $StrikesAroundATM)
    $endIdx   = [Math]::Min($allStrikes.Count - 1, $atmIndex + $StrikesAroundATM)
    $visibleStrikes = $allStrikes[$startIdx..$endIdx]

    # ── 3. Refresh LTP for all visible strikes ──
    $ltpMap = @{}
    $queryParts = [System.Collections.Generic.List[string]]::new()

    foreach ($strike in $visibleStrikes) {
        $ce = $ceOptions | Where-Object { $_.Strike -eq $strike } | Select-Object -First 1
        $pe = $peOptions | Where-Object { $_.Strike -eq $strike } | Select-Object -First 1
        if ($ce) { $queryParts.Add("i=$([System.Uri]::EscapeDataString("${optExchange}:$($ce.Symbol)"))") }
        if ($pe) { $queryParts.Add("i=$([System.Uri]::EscapeDataString("${optExchange}:$($pe.Symbol)"))") }
    }

    $batchSize = 200
    for ($b = 0; $b -lt $queryParts.Count; $b += $batchSize) {
        $batchEnd = [Math]::Min($b + $batchSize - 1, $queryParts.Count - 1)
        $batch = $queryParts[$b..$batchEnd]
        $ltpUrl = "https://api.kite.trade/quote/ltp?" + ($batch -join '&')
        try {
            $ltpResp = Invoke-RestMethod -Uri $ltpUrl -Headers $headers -Method Get -ErrorAction Stop
            if ($ltpResp.data) {
                foreach ($key in $ltpResp.data.PSObject.Properties) {
                    $sym = ($key.Name -split ':')[1]
                    $ltpMap[$sym] = [double]$key.Value.last_price
                }
            } else {
                $nullsThisLoop.Add("LTP batch response .data is null (batch $b)")
            }
        } catch {
            $nullsThisLoop.Add("LTP API error: $($_.Exception.Message)")
        }
    }

    # ── 4. Find-StrikeByOffset for all offsets around ATM ──
    $offsetRange = @(-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5)
    $ceResults = @()
    $peResults = @()

    foreach ($off in $offsetRange) {
        $ceR = Find-StrikeByOffset -SpotLTP $spotPrice -Offset $off -Side 'CE'
        $peR = Find-StrikeByOffset -SpotLTP $spotPrice -Offset $off -Side 'PE'

        if (-not $ceR) { $nullsThisLoop.Add("CE offset=$off returned NULL") }
        if (-not $peR) { $nullsThisLoop.Add("PE offset=$off returned NULL") }

        $ceResults += $ceR
        $peResults += $peR
    }

    # ── 5. Render ──
    Clear-Host

    $sb = [System.Text.StringBuilder]::new(4096)
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("  ════════════════════════════════════════════════════════════════════════════════════════════════════════════")
    $null = $sb.AppendLine("  $underlyingName OPTION CHAIN (LIVE)  |  Expiry: $nearestExpiry  |  Spot: $($spotPrice.ToString('N2'))  |  ATM: $atmStrike  |  Lot: $lotSize")
    $null = $sb.AppendLine("  Iteration: $iteration  |  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')  |  Nulls this loop: $($nullsThisLoop.Count)  |  Total nulls: $nullCount")
    $null = $sb.AppendLine("  ════════════════════════════════════════════════════════════════════════════════════════════════════════════")
    $null = $sb.AppendLine("")

    $headerFmt = '  {0,12} {1,16} {2,10} {3,10}  {4,3}  {5,10} {6,10} {7,16} {8,12}'
    $null = $sb.AppendLine(($headerFmt -f 'CE Token', 'CE Symbol', 'CE LTP', 'CE Lot', '', 'PE Lot', 'PE LTP', 'PE Symbol', 'PE Token'))
    $null = $sb.AppendLine("  $('-' * 115)")

    Write-Host $sb.ToString()

    foreach ($strike in $visibleStrikes) {
        $ce = $ceOptions | Where-Object { $_.Strike -eq $strike } | Select-Object -First 1
        $pe = $peOptions | Where-Object { $_.Strike -eq $strike } | Select-Object -First 1

        $ceToken  = if ($ce) { $ce.Token } else { 'NULL' }
        $ceSym    = if ($ce) { $ce.Symbol } else { 'NULL' }
        $ceLTP    = if ($ce -and $ltpMap.ContainsKey($ce.Symbol)) { $ltpMap[$ce.Symbol].ToString('N2') } else { 'NULL' }
        $ceLot    = if ($ce) { $ce.LotSize } else { 'NULL' }

        $peToken  = if ($pe) { $pe.Token } else { 'NULL' }
        $peSym    = if ($pe) { $pe.Symbol } else { 'NULL' }
        $peLTP    = if ($pe -and $ltpMap.ContainsKey($pe.Symbol)) { $ltpMap[$pe.Symbol].ToString('N2') } else { 'NULL' }
        $peLot    = if ($pe) { $pe.LotSize } else { 'NULL' }

        # Track nulls
        if ($ceLTP -eq 'NULL' -or $peLTP -eq 'NULL' -or $ceToken -eq 'NULL' -or $peToken -eq 'NULL') {
            $nullsThisLoop.Add("Strike $strike has NULL: CE_LTP=$ceLTP PE_LTP=$peLTP CE_Token=$ceToken PE_Token=$peToken")
        }

        $isATM = ($strike -eq $atmStrike)
        $color = if ($ceLTP -eq 'NULL' -or $peLTP -eq 'NULL') { 'Magenta' } elseif ($isATM) { 'Yellow' } elseif ($strike -lt $atmStrike) { 'Green' } else { 'Red' }
        $marker = if ($isATM) { 'ATM' } else { '   ' }

        $line = $headerFmt -f $ceToken, $ceSym, $ceLTP, $ceLot, $marker, $peLot, $peLTP, $peSym, $peToken
        Write-Host $line -ForegroundColor $color

        if ($isATM) {
            Write-Host "  $('-' * 115)" -ForegroundColor Yellow
        }
    }

    # ── 6. ATM Detail Table (all offsets) ──
    Write-Host ""
    Write-Host "  ──── Find-StrikeByOffset Results (Spot: $($spotPrice.ToString('N2'))) ────" -ForegroundColor Cyan

    $detailFmt = '  {0,7} {1,8} {2,10} {3,18} {4,14} {5,10} {6,8} {7,5}'
    Write-Host ($detailFmt -f 'Offset', 'Side', 'Strike', 'Symbol', 'Token', 'LTP', 'Money', 'Null?') -ForegroundColor White
    Write-Host "  $('-' * 90)" -ForegroundColor DarkGray

    foreach ($off in $offsetRange) {
        $ceR = $ceResults | Where-Object { $_.Offset -eq $off } | Select-Object -First 1
        $peR = $peResults | Where-Object { $_.Offset -eq $off } | Select-Object -First 1

        # CE row
        $isNull = if (-not $ceR) { 'YES' } else { 'no' }
        $ceStrike = if ($ceR) { $ceR.Strike } else { '-' }
        $ceSym    = if ($ceR) { $ceR.Symbol } else { '-' }
        $ceToken  = if ($ceR) { $ceR.Token } else { '-' }
        $ceLtp    = if ($ceR -and $ceR.LTP) { $ceR.LTP.ToString('N2') } else { 'NULL' }
        $ceMoney  = if ($ceR) { $ceR.Moneyness } else { '-' }
        $ceColor  = if ($isNull -eq 'YES' -or $ceLtp -eq 'NULL') { 'Magenta' } elseif ($off -eq 0) { 'Yellow' } else { 'Green' }
        Write-Host ($detailFmt -f $off, 'CE', $ceStrike, $ceSym, $ceToken, $ceLtp, $ceMoney, $isNull) -ForegroundColor $ceColor

        # PE row
        $isNull = if (-not $peR) { 'YES' } else { 'no' }
        $peStrike = if ($peR) { $peR.Strike } else { '-' }
        $peSym    = if ($peR) { $peR.Symbol } else { '-' }
        $peToken  = if ($peR) { $peR.Token } else { '-' }
        $peLtp    = if ($peR -and $peR.LTP) { $peR.LTP.ToString('N2') } else { 'NULL' }
        $peMoney  = if ($peR) { $peR.Moneyness } else { '-' }
        $peColor  = if ($isNull -eq 'YES' -or $peLtp -eq 'NULL') { 'Magenta' } elseif ($off -eq 0) { 'Yellow' } else { 'Red' }
        Write-Host ($detailFmt -f $off, 'PE', $peStrike, $peSym, $peToken, $peLtp, $peMoney, $isNull) -ForegroundColor $peColor
    }

    # ── 7. Null summary ──
    $nullCount += $nullsThisLoop.Count
    if ($nullsThisLoop.Count -gt 0) {
        Write-Host ""
        Write-Host "  ⚠ NULLS DETECTED THIS ITERATION ($($nullsThisLoop.Count)):" -ForegroundColor Magenta
        foreach ($msg in $nullsThisLoop) {
            Write-Host "    • $msg" -ForegroundColor Magenta
        }
    } else {
        Write-Host ""
        Write-Host "  ✓ No nulls this iteration" -ForegroundColor Green
    }

    $elapsed = ((Get-Date) - $loopStart).TotalMilliseconds
    Write-Host ""
    Write-Host "  Loop time: $([Math]::Round($elapsed))ms  |  Total nulls across all iterations: $nullCount  |  Next refresh in ${refreshInterval}s  |  Ctrl+C to stop" -ForegroundColor DarkGray

    # Wait before next cycle — but don't use Start-Sleep, use a short polling loop so Ctrl+C is responsive
    $waitEnd = (Get-Date).AddSeconds($refreshInterval)
    while ((Get-Date) -lt $waitEnd) {
        [System.Threading.Thread]::Sleep(100)
    }
}
