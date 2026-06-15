<#
.SYNOPSIS
  Heikin-Ashi Swing Low Stop Loss Monitor.
.DESCRIPTION
  Monitors open CE/PE positions. For any position without a stop-loss,
  calculates swing low from HA candles and places an SL order automatically.
  Uses KiteData.psm1 module and input.json config (same as CALL/PUT-Hedge scripts).
.EXAMPLE
  .\Stop_Loss_Creater_Swinglow.ps1
#>

# ================================================================
# Module & Config (same pattern as CALL/PUT-Hedge scripts)
# ================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force

$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) {
    Write-Host '  ERROR: input.json not found.' -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

$API_Key    = $cfg.API_Key
$API_Secret = $cfg.API_Secret
$TimeFrame  = if ($cfg.TimeFrame -eq 'minute') { '1' } elseif ($cfg.TimeFrame -eq 'day') { 'day' } elseif ($cfg.TimeFrame -match '^\d+$') { $cfg.TimeFrame } else { '1' }
$Product    = $cfg.Product
$Variety    = if ($cfg.Variety) { $cfg.Variety } else { 'regular' }
$MarketProtection = if ($cfg.MarketProtection) { [int]$cfg.MarketProtection } else { 3 }
$NoOfLotsPurchaseAtaTime = [int]$cfg.NoOfLotsPurchaseAtaTime
$SLCandlesLookback = if ($cfg.SLCandlesLookback) { [int]$cfg.SLCandlesLookback } else { 1 }
$SLTriggerOffset = if ($cfg.SLTriggerOffset) { [double]$cfg.SLTriggerOffset } else { 0.5 }

# Resolve IndexChoosen
$rawIdx = $cfg.IndexChoosen
$idxMap = @{ 'NIFTY'='NIFTY'; 'BANKNIFTY'='BANKNIFTY'; 'FINNIFTY'='FinNifty'; 'MIDCPNIFTY'='MIDCPNIFTY'; 'SENSEX'='SENSEX' }
$IndexChoosen = if ($idxMap.ContainsKey($rawIdx.ToUpper())) { $idxMap[$rawIdx.ToUpper()] } else { $rawIdx }

Write-Host "  Loaded config from input.json" -ForegroundColor DarkGray

# ================================================================
# Auth (same as CALL/PUT-Hedge scripts)
# ================================================================
if (-not $API_Key -or -not $API_Secret) {
    Write-Host '  ERROR: API_Key/API_Secret not found.' -ForegroundColor Red
    exit 1
}

$tokenFile = Join-Path $scriptDir 'accesstoken.json'
$AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }

$headers = @{
    'X-Kite-Version' = '3'
    'Authorization'  = "token ${API_Key}:${AccessToken}"
}
$Global:common_header = $headers

# Validate token
$tokenValid = $false
try {
    $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
    if ($profile.data -and $profile.data.user_id) {
        $tokenValid = $true
        Write-Host "  Token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    }
} catch {}

if (-not $tokenValid) {
    Write-Host '  Access token INVALID or EXPIRED. Requesting new token...' -ForegroundColor Red
    Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
    $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
    if (-not $AccessToken) { Write-Host '  Login failed. Exiting.' -ForegroundColor Red; exit 1 }
    $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
    $Global:common_header = $headers
    try {
        $profile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
        Write-Host "  New token valid. Logged in as: $($profile.data.user_name) ($($profile.data.user_id))" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: New token also failed." -ForegroundColor Red
        exit 1
    }
}

# ================================================================
# Index Config
# ================================================================
$IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots $NoOfLotsPurchaseAtaTime
if (-not $IndexConfig) { exit 1 }

$SearchKeyWord = $IndexConfig.SearchKeyWord
$exchange      = $IndexConfig.exchange
$optExchange   = $IndexConfig.OptExchange

Write-Host ""
Write-Host "  Index: $SearchKeyWord | Exchange: $exchange | TimeFrame: $TimeFrame | SL Lookback: $SLCandlesLookback candle(s)" -ForegroundColor Green

# ================================================================
# Helper: Get LTP for a trading symbol
# ================================================================
function Get-OptionLTP {
    param([string]$Symbol, [string]$Exchange)
    try {
        $encodedKey = [System.Uri]::EscapeDataString("${Exchange}:${Symbol}")
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/quote/ltp?i=$encodedKey" -Headers $headers -Method Get -ErrorAction Stop
        foreach ($prop in $resp.data.PSObject.Properties) {
            if ($prop.Value.last_price -gt 0) { return $prop.Value.last_price }
        }
    } catch {}
    return 0
}

# ================================================================
# Helper: Get all pending SL orders
# ================================================================
function Get-PendingSLOrders {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/orders" -Headers $headers -Method Get -ErrorAction Stop
        return @($resp.data | Where-Object { $_.order_type -eq 'SL' -and $_.status -eq 'TRIGGER PENDING' })
    } catch {
        return @()
    }
}

# ================================================================
# Helper: Get day P&L from positions
# ================================================================
function Get-DayPnL {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $headers -Method Get -ErrorAction Stop
        $dayPositions = @($resp.data.day | Where-Object { $_.tradingsymbol -Match "$SearchKeyWord" })
        $openPositions = @($dayPositions | Where-Object { $_.quantity -ne 0 })
        $closedPositions = @($dayPositions | Where-Object { $_.quantity -eq 0 })

        $closedPNL = 0.0
        foreach ($p in $closedPositions) { $closedPNL += [double]$p.pnl }

        $openPNL = 0.0
        foreach ($p in $openPositions) {
            $ltp = Get-OptionLTP -Symbol $p.tradingsymbol -Exchange $p.exchange
            if ($ltp -gt 0) {
                $openPNL += ([double]$p.sell_value - [double]$p.buy_value) + ([int]$p.quantity * $ltp)
            } else {
                $openPNL += [double]$p.pnl
            }
        }
        return [Math]::Round($closedPNL + $openPNL, 2)
    } catch { return 0.0 }
}

# ================================================================
# Main Loop: Monitor positions and place SL orders
# ================================================================
Write-Host ""
Write-Host "  Starting Stop Loss Monitor..." -ForegroundColor Cyan
Write-Host ""

while ($true) {
    # Check open positions (use 1 lot to detect ANY open position regardless of configured lot size)
    $positionStatus = Check-AlreadyAnyOrderRunning -SearchKeyWord $SearchKeyWord -NoOfLotsPurchaseAtaTime 1 -Headers $headers
    if ($null -eq $positionStatus -or @($positionStatus).Count -eq 0) {
        Write-Host "  Either error or null value detected, will retry open positions again" -ForegroundColor DarkYellow
        Start-Sleep -Seconds 3
        continue
    }
    $UpTrendCheck   = $positionStatus | Where-Object { $_.Type -eq 'UPTrend' }
    $DownTrendCheck = $positionStatus | Where-Object { $_.Type -eq 'DownTrend' }

    # Get individual positions for per-symbol SL handling (handles multiple CE/PE positions)
    $individualPositions = @()
    try {
        $posResp = Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $headers -Method Get -ErrorAction Stop
        $individualPositions = @($posResp.data.net | Where-Object { $_.tradingsymbol -Match $SearchKeyWord -and $_.quantity -gt 0 })
    } catch {
        Write-Host "  Error fetching individual positions: $_" -ForegroundColor Red
    }
    $cePositions = @($individualPositions | Where-Object { $_.tradingsymbol -match "CE$" })
    $pePositions = @($individualPositions | Where-Object { $_.tradingsymbol -match "PE$" })

    # Get pending SL orders
    $pendingSLOrders = Get-PendingSLOrders

    # Get day P&L
    $TotalPNL = Get-DayPnL

    # ── Display Header ──
    Clear-Host
    $border = [string]::new([char]0x2550, 80)
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host "  HEIKIN ASHI STOP LOSS MONITOR | $SearchKeyWord | TimeFrame: $TimeFrame | SL Lookback: $SLCandlesLookback candle(s)" -ForegroundColor White
    Write-Host "  $(Get-Date -Format 'dd-MMM-yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host ""
    $totalColor = if ($TotalPNL -ge 0) { "Green" } else { "Red" }
    Write-Host ("  {0,-20} {1,12}" -f "Total Day PNL:", $TotalPNL) -ForegroundColor $totalColor
    Write-Host ""
    Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "TREND","SYMBOL","LTP","QTY","PRODUCT","SL STATUS") -ForegroundColor Yellow
    Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f ([string]::new([char]0x2500,12)),([string]::new([char]0x2500,25)),([string]::new([char]0x2500,8)),([string]::new([char]0x2500,6)),([string]::new([char]0x2500,8)),([string]::new([char]0x2500,20))) -ForegroundColor DarkGray

    $anyPositionFound = $false

    # ── CE (UpTrend) Positions ──
    if ($UpTrendCheck.Running -eq $true) {
        $anyPositionFound = $true
        foreach ($pos in $cePositions) {
            $ceSymbol  = $pos.tradingsymbol
            $ceQty     = $pos.quantity
            $ceProduct = if ($pos.product) { $pos.product } else { $Product }
            $ceToken   = $pos.instrument_token
            $ceLTP     = $pos.last_price

            $existingSL = $pendingSLOrders | Where-Object { $_.tradingsymbol -eq $ceSymbol }
            if ($existingSL) {
                $slStatus = "SL @ $($existingSL.trigger_price)"
                Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  UpTrend",$ceSymbol,$ceLTP,$ceQty,$ceProduct,$slStatus) -ForegroundColor Green
            } else {
                Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  UpTrend",$ceSymbol,$ceLTP,$ceQty,$ceProduct,"NO SL - Placing...") -ForegroundColor Red
                try {
                    $haCandles = Get-ZerodhaCandleData -tradingsymbol $ceSymbol -instrument_token $ceToken -TimeFrame $TimeFrame
                    if ($haCandles -and $haCandles.Count -ge $SLCandlesLookback) {
                        $lastNLows = $haCandles[-$SLCandlesLookback..-1] | ForEach-Object { $_.low }
                        $slPrice = [Math]::Round(($lastNLows | Measure-Object -Minimum).Minimum, 1)
                        $triggerPrice = [Math]::Round($slPrice + $SLTriggerOffset, 1)

                        Write-Host "  Last $SLCandlesLookback candle lows: $($lastNLows -join ', ')  SL=$slPrice  Trigger=$triggerPrice" -ForegroundColor Yellow

                        Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
                            -Tradingsymbol $ceSymbol -Quantity $ceQty `
                            -OrderType "SL" -Product $ceProduct -Exchange $exchange `
                            -Price $slPrice -TriggerPrice $triggerPrice -Tag "SL-CE"
                        Write-Host "  CE SL ORDER PLACED" -ForegroundColor Green
                        Start-Sleep -Seconds 1
                    } else {
                        Write-Host "  Not enough candle data" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  Error: $_" -ForegroundColor Red
                }
            }
        }
    }

    # ── PE (DownTrend) Positions ──
    if ($DownTrendCheck.Running -eq $true) {
        $anyPositionFound = $true
        foreach ($pos in $pePositions) {
            $peSymbol  = $pos.tradingsymbol
            $peQty     = $pos.quantity
            $peProduct = if ($pos.product) { $pos.product } else { $Product }
            $peToken   = $pos.instrument_token
            $peLTP     = $pos.last_price

            $existingSL = $pendingSLOrders | Where-Object { $_.tradingsymbol -eq $peSymbol }
            if ($existingSL) {
                $slStatus = "SL @ $($existingSL.trigger_price)"
                Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  DownTrend",$peSymbol,$peLTP,$peQty,$peProduct,$slStatus) -ForegroundColor Green
            } else {
                Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  DownTrend",$peSymbol,$peLTP,$peQty,$peProduct,"NO SL - Placing...") -ForegroundColor Red
                try {
                    $haCandles = Get-ZerodhaCandleData -tradingsymbol $peSymbol -instrument_token $peToken -TimeFrame $TimeFrame
                    if ($haCandles -and $haCandles.Count -ge $SLCandlesLookback) {
                        $lastNLows = $haCandles[-$SLCandlesLookback..-1] | ForEach-Object { $_.low }
                        $slPrice = [Math]::Round(($lastNLows | Measure-Object -Minimum).Minimum, 1)
                        $triggerPrice = [Math]::Round($slPrice + $SLTriggerOffset, 1)

                        Write-Host "  Last $SLCandlesLookback candle lows: $($lastNLows -join ', ')  SL=$slPrice  Trigger=$triggerPrice" -ForegroundColor Yellow

                        Place-ZerodhaOrder -CommonHeader $headers -Type "SELL" -Variety $Variety `
                            -Tradingsymbol $peSymbol -Quantity $peQty `
                            -OrderType "SL" -Product $peProduct -Exchange $exchange `
                            -Price $slPrice -TriggerPrice $triggerPrice -Tag "SL-PE"
                        Write-Host "  PE SL ORDER PLACED" -ForegroundColor Green
                        Start-Sleep -Seconds 1
                    } else {
                        Write-Host "  Not enough candle data" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  Error: $_" -ForegroundColor Red
                }
            }
        }
    }

    # ── Cancel orphaned SL orders (position exited but SL still pending) ──
    if ($pendingSLOrders.Count -gt 0) {
        $openSymbols = @($individualPositions | Select-Object -ExpandProperty tradingsymbol)
        $orphanedSLs = @($pendingSLOrders | Where-Object { $_.tradingsymbol -match $SearchKeyWord -and $_.tradingsymbol -notin $openSymbols })
        foreach ($orphan in $orphanedSLs) {
            Write-Host "  Cancelling orphaned SL: $($orphan.tradingsymbol) | OrderID: $($orphan.order_id) | Trigger: $($orphan.trigger_price)" -ForegroundColor Magenta
            try {
                Invoke-RestMethod -Uri "https://api.kite.trade/orders/regular/$($orphan.order_id)" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
                Write-Host "  Cancelled." -ForegroundColor Green
            } catch {
                Write-Host "  Failed to cancel: $_" -ForegroundColor Red
            }
        }
    }

    if (-not $anyPositionFound) {
        Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  --","No active positions","--","--","--","Waiting...") -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host $border -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3
}