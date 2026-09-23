<#
.SYNOPSIS
  Swing High Stop Loss Monitor (OPTION SELLING).
.DESCRIPTION
  Mirror of Stop_Loss_Creater_Swinglow.ps1 for SHORT (option-selling) positions.
  Continuously checks for open CE/PE SHORT positions (negative net quantity) and
  ensures each one has a protective stop-loss. For any short without an SL, it
  calculates the swing HIGH from the last N regular (OHLC) candles and places a
  BUY SL order (buy-back) automatically. Also cancels orphaned BUY-SL orders once
  their short position is closed.

  Why swing HIGH / BUY: a sold option is a short. It loses money when the option
  price RISES, so the stop is a BUY order triggered above the market. The SL price
  is the highest high of the last N candles (with SLCandlesLookback=1 this is the
  current/most-recent candle's high).

  Quantity handling:
    - The SL quantity is the absolute value of the live short quantity (|pos.quantity|),
      so it protects the full running short of each symbol regardless of lot count,
      and handles multiple strikes (each gets its own SL).
    - NOTE: An SL is only placed when no pending BUY-SL already exists for that
      symbol. It does NOT reconcile quantity, so if lots are added after an SL was
      placed, the extra quantity stays unprotected until the SL is recreated.

  Driven by input.json config (same as the Swing Low script):
    - SLCandlesLookback : number of recent candles scanned for the swing high (SL price = highest high)
    - SLTriggerOffset   : amount SUBTRACTED from the SL price to derive the trigger price
    - TimeFrame         : candle interval used for the lookback
    - IndexChoosen / NoOfLotsPurchaseAtaTime / Product / Variety : instrument & order settings

  Uses KiteData.psm1 module for auth, candle data, and order placement.
.EXAMPLE
  .\Stop_Loss_Creater_SwingHigh.ps1
#>

# ================================================================
# Module & Config (same pattern as the Swing Low script)
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
$TimeFrame  = if ($cfg.TimeFrame -eq 'minute') { '1' } elseif ($cfg.TimeFrame -eq 'day') { 'day' } elseif ($cfg.TimeFrame -match '^\d+$') { $cfg.TimeFrame } elseif ($cfg.TimeFrame -match '^(\d+)minute$') { $Matches[1] } elseif ($cfg.TimeFrame -match '^(\d+)second$') { '1' } else { '1' }
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
# Auth (same as the Swing Low script)
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
# Helper: Get all pending BUY stop-loss orders (this script's SLs)
# ================================================================
function Get-PendingBuySLOrders {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/orders" -Headers $headers -Method Get -ErrorAction Stop
        return @($resp.data | Where-Object { $_.order_type -eq 'SL' -and $_.transaction_type -eq 'BUY' -and $_.status -eq 'TRIGGER PENDING' })
    } catch {
        return @()
    }
}

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
# Main Loop: Monitor SHORT positions and place BUY stop-loss orders
# ================================================================
Write-Host ""
Write-Host "  Starting Swing High Stop Loss Monitor (option selling)..." -ForegroundColor Cyan
Write-Host ""

while ($true) {
    # Get individual SHORT positions (net quantity < 0) for per-symbol SL handling
    $shortPositions = $null
    try {
        $posResp = Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $headers -Method Get -ErrorAction Stop
        $shortPositions = @($posResp.data.net | Where-Object { $_.tradingsymbol -Match $SearchKeyWord -and $_.quantity -lt 0 })
    } catch {
        Write-Host "  Either error or null value detected, will retry open positions again" -ForegroundColor DarkYellow
        Start-Sleep -Seconds 3
        continue
    }
    $cePositions = @($shortPositions | Where-Object { $_.tradingsymbol -match "CE$" })
    $pePositions = @($shortPositions | Where-Object { $_.tradingsymbol -match "PE$" })

    # Get pending BUY-SL orders and day P&L
    $pendingSLOrders = Get-PendingBuySLOrders
    $TotalPNL = Get-DayPnL

    # -- Display Header --
    Clear-Host
    $border = [string]::new([char]0x2550, 80)
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host "  SWING HIGH STOP LOSS MONITOR (SELLING) | $SearchKeyWord | TimeFrame: $TimeFrame | SL Lookback: $SLCandlesLookback candle(s)" -ForegroundColor White
    Write-Host "  $(Get-Date -Format 'dd-MMM-yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host ""
    $totalColor = if ($TotalPNL -ge 0) { "Green" } else { "Red" }
    Write-Host ("  {0,-20} {1,12}" -f "Total Day PNL:", $TotalPNL) -ForegroundColor $totalColor
    Write-Host ""
    Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "TREND","SYMBOL","LTP","QTY","PRODUCT","SL STATUS") -ForegroundColor Yellow
    Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f ([string]::new([char]0x2500,12)),([string]::new([char]0x2500,25)),([string]::new([char]0x2500,8)),([string]::new([char]0x2500,6)),([string]::new([char]0x2500,8)),([string]::new([char]0x2500,20))) -ForegroundColor DarkGray

    $anyPositionFound = $false

    # -- CE shorts (bearish/DownTrend) --
    foreach ($pos in $cePositions) {
        $anyPositionFound = $true
        $ceSymbol  = $pos.tradingsymbol
        $ceQty     = [Math]::Abs([int]$pos.quantity)              # short qty is negative; SL qty is positive
        $ceProduct = if ($pos.product) { $pos.product } else { $Product }
        $ceToken   = $pos.instrument_token
        $ceLTP     = $pos.last_price

        $existingSL = $pendingSLOrders | Where-Object { $_.tradingsymbol -eq $ceSymbol }
        if ($existingSL) {
            $slStatus = "SL @ $($existingSL.trigger_price)"
            Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  DownTrend",$ceSymbol,$ceLTP,$ceQty,$ceProduct,$slStatus) -ForegroundColor Green
        } else {
            Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  DownTrend",$ceSymbol,$ceLTP,$ceQty,$ceProduct,"NO SL - Placing...") -ForegroundColor Red
            try {
                $haCandles = Get-ZerodhaCandleData -tradingsymbol $ceSymbol -instrument_token $ceToken -TimeFrame $TimeFrame
                if ($haCandles -and $haCandles.Count -ge $SLCandlesLookback) {
                    $lastNHighs = $haCandles[-$SLCandlesLookback..-1] | ForEach-Object { $_.high }
                    $slPrice = [Math]::Round(($lastNHighs | Measure-Object -Maximum).Maximum, 1)
                    $triggerPrice = [Math]::Round($slPrice - $SLTriggerOffset, 1)

                    Write-Host "  Last $SLCandlesLookback candle highs: $($lastNHighs -join ', ')  SL=$slPrice  Trigger=$triggerPrice" -ForegroundColor Yellow

                    Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
                        -Tradingsymbol $ceSymbol -Quantity $ceQty `
                        -OrderType "SL" -Product $ceProduct -Exchange $exchange `
                        -Price $slPrice -TriggerPrice $triggerPrice -Tag "SLH-CE"
                    Write-Host "  CE BUY-SL ORDER PLACED" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                } else {
                    Write-Host "  Not enough candle data" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  Error: $_" -ForegroundColor Red
            }
        }
    }

    # -- PE shorts (bullish/UpTrend) --
    foreach ($pos in $pePositions) {
        $anyPositionFound = $true
        $peSymbol  = $pos.tradingsymbol
        $peQty     = [Math]::Abs([int]$pos.quantity)              # short qty is negative; SL qty is positive
        $peProduct = if ($pos.product) { $pos.product } else { $Product }
        $peToken   = $pos.instrument_token
        $peLTP     = $pos.last_price

        $existingSL = $pendingSLOrders | Where-Object { $_.tradingsymbol -eq $peSymbol }
        if ($existingSL) {
            $slStatus = "SL @ $($existingSL.trigger_price)"
            Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  UpTrend",$peSymbol,$peLTP,$peQty,$peProduct,$slStatus) -ForegroundColor Green
        } else {
            Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  UpTrend",$peSymbol,$peLTP,$peQty,$peProduct,"NO SL - Placing...") -ForegroundColor Red
            try {
                $haCandles = Get-ZerodhaCandleData -tradingsymbol $peSymbol -instrument_token $peToken -TimeFrame $TimeFrame
                if ($haCandles -and $haCandles.Count -ge $SLCandlesLookback) {
                    $lastNHighs = $haCandles[-$SLCandlesLookback..-1] | ForEach-Object { $_.high }
                    $slPrice = [Math]::Round(($lastNHighs | Measure-Object -Maximum).Maximum, 1)
                    $triggerPrice = [Math]::Round($slPrice - $SLTriggerOffset, 1)

                    Write-Host "  Last $SLCandlesLookback candle highs: $($lastNHighs -join ', ')  SL=$slPrice  Trigger=$triggerPrice" -ForegroundColor Yellow

                    Place-ZerodhaOrder -CommonHeader $headers -Type "BUY" -Variety $Variety `
                        -Tradingsymbol $peSymbol -Quantity $peQty `
                        -OrderType "SL" -Product $peProduct -Exchange $exchange `
                        -Price $slPrice -TriggerPrice $triggerPrice -Tag "SLH-PE"
                    Write-Host "  PE BUY-SL ORDER PLACED" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                } else {
                    Write-Host "  Not enough candle data" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  Error: $_" -ForegroundColor Red
            }
        }
    }

    # -- Cancel orphaned BUY-SL orders (short closed but SL still pending) --
    if ($pendingSLOrders.Count -gt 0) {
        $openSymbols = @($shortPositions | Select-Object -ExpandProperty tradingsymbol)
        $orphanedSLs = @($pendingSLOrders | Where-Object { $_.tradingsymbol -match $SearchKeyWord -and $_.tradingsymbol -notin $openSymbols })
        foreach ($orphan in $orphanedSLs) {
            Write-Host "  Cancelling orphaned BUY-SL: $($orphan.tradingsymbol) | OrderID: $($orphan.order_id) | Trigger: $($orphan.trigger_price)" -ForegroundColor Magenta
            try {
                Invoke-RestMethod -Uri "https://api.kite.trade/orders/regular/$($orphan.order_id)" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
                Write-Host "  Cancelled." -ForegroundColor Green
            } catch {
                Write-Host "  Failed to cancel: $_" -ForegroundColor Red
            }
        }
    }

    if (-not $anyPositionFound) {
        Write-Host ("{0,-12} {1,-25} {2,8} {3,6} {4,8} {5,-20}" -f "  --","No active short positions","--","--","--","Waiting...") -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host $border -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3
}
