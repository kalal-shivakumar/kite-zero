# ============================================================
# KiteData.psm1 — Zerodha Kite Market Data Module
#
# Supports ALL exchanges: NSE, BSE, NFO, BFO, MCX, CDS, BCD
# Instruments: Equity, Futures, Options, Commodities, Currency
#
# Shared functions: Presets, Auth, Binary parsing, Intervals
#
# SETUP:
#   Import-Module .\KiteData.psm1
# ============================================================

# ── Predefined popular instruments ──────────────────────────
$script:Presets = @{
    # --- Indices ---
    'NIFTY'            = @{ Token = 256265;    Exchange = 'NSE';  Symbol = 'NIFTY 50';           Label = 'NIFTY 50' }
    'NIFTY50'          = @{ Token = 256265;    Exchange = 'NSE';  Symbol = 'NIFTY 50';           Label = 'NIFTY 50' }
    'SENSEX'           = @{ Token = 265;       Exchange = 'BSE';  Symbol = 'SENSEX';             Label = 'SENSEX' }
    'BANKNIFTY'        = @{ Token = 260105;    Exchange = 'NSE';  Symbol = 'NIFTY BANK';         Label = 'BANK NIFTY' }
    'FINNIFTY'         = @{ Token = 257801;    Exchange = 'NSE';  Symbol = 'NIFTY FIN SERVICE';  Label = 'FIN NIFTY' }
    'MIDCPNIFTY'       = @{ Token = 288009;    Exchange = 'NSE';  Symbol = 'NIFTY MID SELECT';   Label = 'MIDCAP NIFTY' }

    # --- Equity (NSE) ---
    'RELIANCE'         = @{ Token = 738561;    Exchange = 'NSE';  Symbol = 'RELIANCE';    Label = 'RELIANCE' }
    'TCS'              = @{ Token = 2953217;   Exchange = 'NSE';  Symbol = 'TCS';         Label = 'TCS' }
    'INFY'             = @{ Token = 408065;    Exchange = 'NSE';  Symbol = 'INFY';        Label = 'INFOSYS' }
    'HDFCBANK'         = @{ Token = 341249;    Exchange = 'NSE';  Symbol = 'HDFCBANK';    Label = 'HDFC BANK' }
    'ICICIBANK'        = @{ Token = 1270529;   Exchange = 'NSE';  Symbol = 'ICICIBANK';   Label = 'ICICI BANK' }
    'SBIN'             = @{ Token = 779521;    Exchange = 'NSE';  Symbol = 'SBIN';        Label = 'SBI' }
    'TATAMOTORS'       = @{ Token = 884737;    Exchange = 'NSE';  Symbol = 'TATAMOTORS';  Label = 'TATA MOTORS' }
    'ITC'              = @{ Token = 424961;    Exchange = 'NSE';  Symbol = 'ITC';         Label = 'ITC' }
    'WIPRO'            = @{ Token = 969473;    Exchange = 'NSE';  Symbol = 'WIPRO';       Label = 'WIPRO' }
    'BHARTIARTL'       = @{ Token = 2714625;   Exchange = 'NSE';  Symbol = 'BHARTIARTL';  Label = 'BHARTI AIRTEL' }
    'KOTAKBANK'        = @{ Token = 492033;    Exchange = 'NSE';  Symbol = 'KOTAKBANK';   Label = 'KOTAK BANK' }
    'LT'               = @{ Token = 2939649;   Exchange = 'NSE';  Symbol = 'LT';          Label = 'L&T' }
    'HINDUNILVR'       = @{ Token = 356865;    Exchange = 'NSE';  Symbol = 'HINDUNILVR';  Label = 'HUL' }
    'AXISBANK'         = @{ Token = 1510401;   Exchange = 'NSE';  Symbol = 'AXISBANK';    Label = 'AXIS BANK' }
    'MARUTI'           = @{ Token = 2815745;   Exchange = 'NSE';  Symbol = 'MARUTI';      Label = 'MARUTI' }
    'ADANIENT'         = @{ Token = 6401;      Exchange = 'NSE';  Symbol = 'ADANIENT';    Label = 'ADANI ENT' }
    'ADANIPORTS'       = @{ Token = 3861249;   Exchange = 'NSE';  Symbol = 'ADANIPORTS';  Label = 'ADANI PORTS' }
    'BAJFINANCE'       = @{ Token = 81153;     Exchange = 'NSE';  Symbol = 'BAJFINANCE';  Label = 'BAJ FINANCE' }
    'SUNPHARMA'        = @{ Token = 857857;    Exchange = 'NSE';  Symbol = 'SUNPHARMA';   Label = 'SUN PHARMA' }
    'TITAN'            = @{ Token = 897537;    Exchange = 'NSE';  Symbol = 'TITAN';       Label = 'TITAN' }

    # --- MCX Commodities ---
    'SILVERM'          = @{ Token = 117128455; Exchange = 'MCX';  Symbol = 'SILVERM26APRFUT';     Label = 'SILVERM FUT' }
    'SILVERM26APRFUT'  = @{ Token = 117128455; Exchange = 'MCX';  Symbol = 'SILVERM26APRFUT';     Label = 'SILVERM FUT' }
    'GOLDM'            = @{ Token = 116768775; Exchange = 'MCX';  Symbol = 'GOLDM26APRFUT';       Label = 'GOLDM FUT' }
    'GOLDM26APRFUT'    = @{ Token = 116768775; Exchange = 'MCX';  Symbol = 'GOLDM26APRFUT';       Label = 'GOLDM FUT' }
    'CRUDEOIL'         = @{ Token = 116544263; Exchange = 'MCX';  Symbol = 'CRUDEOIL26APRFUT';    Label = 'CRUDE OIL FUT' }
    'CRUDEOIL26APRFUT' = @{ Token = 116544263; Exchange = 'MCX';  Symbol = 'CRUDEOIL26APRFUT';    Label = 'CRUDE OIL FUT' }
    'NATURALGAS'       = @{ Token = 116853511; Exchange = 'MCX';  Symbol = 'NATURALGAS26APRFUT';  Label = 'NATURAL GAS FUT' }
    'NATURALGAS26APRFUT' = @{ Token = 116853511; Exchange = 'MCX'; Symbol = 'NATURALGAS26APRFUT'; Label = 'NATURAL GAS FUT' }
}

# ── Resolve a symbol name to preset data ───────────────────
function Resolve-KiteSymbol {
    param([string]$Name)
    $key = $Name.ToUpper().Trim()
    if ($script:Presets.ContainsKey($key)) { return $script:Presets[$key] }
    return $null
}

# ── List all preset symbols ────────────────────────────────
function Show-KiteSymbols {
    Write-Host ''
    Write-Host '  Available Trading Symbols:' -ForegroundColor Cyan
    Write-Host '  -------------------------' -ForegroundColor DarkGray
    $f = '  {0,-20} {1,12}  {2,-8} {3}'
    Write-Host ($f -f 'Symbol','Token','Exchange','Label') -ForegroundColor Cyan
    $seen = @{}
    foreach ($k in ($script:Presets.Keys | Sort-Object)) {
        $v = $script:Presets[$k]
        $uid = "$($v.Token)"
        if ($seen.ContainsKey($uid)) { continue }
        $seen[$uid] = $true
        Write-Host ($f -f $k, $v.Token, $v.Exchange, $v.Label)
    }
    Write-Host ''
}

# ══════════════════════════════════════════════════════════════
# Binary helpers (Big-Endian) for WebSocket tick parsing
# ══════════════════════════════════════════════════════════════
function Read-Int16BE([byte[]]$buf, [int]$pos) {
    return ([int]$buf[$pos] -shl 8) -bor [int]$buf[$pos + 1]
}
function Read-Int32BE([byte[]]$buf, [int]$pos) {
    $v = ([uint32]$buf[$pos] -shl 24) -bor ([uint32]$buf[$pos+1] -shl 16) -bor ([uint32]$buf[$pos+2] -shl 8) -bor [uint32]$buf[$pos+3]
    return [int]$v
}

# ══════════════════════════════════════════════════════════════
# Parse binary tick message per Kite WebSocket docs
# Ref: https://kite.trade/docs/connect/v3/websocket/
# ══════════════════════════════════════════════════════════════
function Parse-KiteTicks([byte[]]$data, [int]$len) {
    if ($len -lt 4) { return @() }
    $np = Read-Int16BE $data 0
    $ticks = [System.Collections.Generic.List[hashtable]]::new($np)
    $off = 2
    for ($p = 0; $p -lt $np; $p++) {
        if (($off + 2) -gt $len) { break }
        $pl = Read-Int16BE $data $off
        $off += 2
        if (($pl -lt 4) -or (($off + $pl) -gt $len)) { break }
        $s = $off
        $div = 100.0
        $t = @{ Tok=(Read-Int32BE $data $s); LTP=0.0; Vol=0; O=0.0; H=0.0; L=0.0; C=0.0; OI=0 }
        switch ($pl) {
            8   { $t.LTP = (Read-Int32BE $data ($s+4)) / $div }
            28  { $t.LTP=(Read-Int32BE $data ($s+4))/$div; $t.H=(Read-Int32BE $data ($s+8))/$div; $t.L=(Read-Int32BE $data ($s+12))/$div; $t.O=(Read-Int32BE $data ($s+16))/$div; $t.C=(Read-Int32BE $data ($s+20))/$div }
            32  { $t.LTP=(Read-Int32BE $data ($s+4))/$div; $t.H=(Read-Int32BE $data ($s+8))/$div; $t.L=(Read-Int32BE $data ($s+12))/$div; $t.O=(Read-Int32BE $data ($s+16))/$div; $t.C=(Read-Int32BE $data ($s+20))/$div }
            44  { $t.LTP=(Read-Int32BE $data ($s+4))/$div; $t.Vol=Read-Int32BE $data ($s+16); $t.O=(Read-Int32BE $data ($s+28))/$div; $t.H=(Read-Int32BE $data ($s+32))/$div; $t.L=(Read-Int32BE $data ($s+36))/$div; $t.C=(Read-Int32BE $data ($s+40))/$div }
            184 { $t.LTP=(Read-Int32BE $data ($s+4))/$div; $t.Vol=Read-Int32BE $data ($s+16); $t.O=(Read-Int32BE $data ($s+28))/$div; $t.H=(Read-Int32BE $data ($s+32))/$div; $t.L=(Read-Int32BE $data ($s+36))/$div; $t.C=(Read-Int32BE $data ($s+40))/$div; $t.OI=Read-Int32BE $data ($s+48) }
            default {
                if ($pl -ge 8)  { $t.LTP = (Read-Int32BE $data ($s+4)) / $div }
                if ($pl -ge 44) { $t.Vol=Read-Int32BE $data ($s+16); $t.O=(Read-Int32BE $data ($s+28))/$div; $t.H=(Read-Int32BE $data ($s+32))/$div; $t.L=(Read-Int32BE $data ($s+36))/$div; $t.C=(Read-Int32BE $data ($s+40))/$div }
                if ($pl -ge 52) { $t.OI = Read-Int32BE $data ($s+48) }
            }
        }
        $ticks.Add($t)
        $off += $pl
    }
    return $ticks
}

# ══════════════════════════════════════════════════════════════
# Kite Connect OAuth: Exchange request_token -> access_token
# ══════════════════════════════════════════════════════════════
function Exchange-KiteRequestToken {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$ReqToken,
        [string]$TokenFilePath
    )
    Write-Host '  Exchanging request_token for access_token...' -ForegroundColor Cyan
    $raw = $ApiKey + $ReqToken + $ApiSecret
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hb  = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    $sha.Dispose()
    $chk = -join ($hb | ForEach-Object { $_.ToString('x2') })
    $body = @{ api_key=$ApiKey; request_token=$ReqToken; checksum=$chk }
    $hdrs = @{ 'X-Kite-Version' = '3' }
    try {
        $r = Invoke-RestMethod -Uri 'https://api.kite.trade/session/token' -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers $hdrs -ErrorAction Stop
        if ($r.data -and $r.data.access_token) {
            $env:KITE_ACCESS_TOKEN = $r.data.access_token
            @{ access_token=$r.data.access_token; saved_at=(Get-Date).ToString('o'); user="$($r.data.user_name) ($($r.data.user_id))" } | ConvertTo-Json | Set-Content $TokenFilePath
            Write-Host "  OK! access_token saved to accesstoken.json" -ForegroundColor Green
            Write-Host "  User: $($r.data.user_name) ($($r.data.user_id))" -ForegroundColor Gray
            return $r.data.access_token
        }
        Write-Host '  Unexpected response.' -ForegroundColor Red
        return $null
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host "  $($_.ErrorDetails.Message)" -ForegroundColor Yellow }
        return $null
    }
}

# ══════════════════════════════════════════════════════════════
# Resolve access_token: env > file (10h expiry) > interactive
# ══════════════════════════════════════════════════════════════
function Resolve-KiteAccessToken {
    param(
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$TokenFilePath
    )
    if ($env:KITE_ACCESS_TOKEN) { return $env:KITE_ACCESS_TOKEN }
    if (Test-Path $TokenFilePath) {
        try {
            $d = Get-Content $TokenFilePath -Raw | ConvertFrom-Json
            $h = ((Get-Date) - (Get-Item $TokenFilePath).LastWriteTime).TotalHours
            if ($h -lt 10 -and $d.access_token) {
                Write-Host "  Loaded access_token (age: $([Math]::Round($h,1))h)" -ForegroundColor DarkGray
                return $d.access_token
            }
            Write-Host "  access_token expired ($([Math]::Round($h,1))h old)." -ForegroundColor Yellow
        } catch { Write-Host "  Invalid accesstoken.json: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $url = 'https://kite.trade/connect/login?v=3&api_key=' + $ApiKey
    Write-Host ''
    Write-Host '  No valid access_token. Opening login...' -ForegroundColor Cyan
    Write-Host "  $url" -ForegroundColor DarkGray
    try { Start-Process $url } catch {}
    Write-Host ''
    Write-Host '  After login, copy the request_token from the redirect URL.' -ForegroundColor Yellow
    Write-Host ''
    $userInput = Read-Host '  Paste the request_token here'
    $userInput = $userInput.Trim()
    if (-not $userInput) { return $null }
    return (Exchange-KiteRequestToken -ApiKey $ApiKey -ApiSecret $ApiSecret -ReqToken $userInput -TokenFilePath $TokenFilePath)
}

# ══════════════════════════════════════════════════════════════
# Interval helpers
# ══════════════════════════════════════════════════════════════
function Get-IntervalMinutes([string]$Interval) {
    switch ($Interval) {
        'minute'   { return 1 }
        '3minute'  { return 3 }
        '5minute'  { return 5 }
        '10minute' { return 10 }
        '15minute' { return 15 }
        '30minute' { return 30 }
        '60minute' { return 60 }
        default    { return 1 }
    }
}

function Get-IntervalLabel([int]$Minutes) {
    if ($Minutes -eq 1)  { return '1-Min' }
    if ($Minutes -eq 60) { return '1-Hour' }
    return "$($Minutes)-Min"
}

# ── Helper: Parse Kite datetime safely ──────────────────────
function ParseKiteDateTime {
    param([string]$Raw)
    $s = $Raw -replace 'T', ' '
    if ($s.Length -ge 19) {
        try   { return [DateTime]::ParseExact($s.Substring(0,19), "yyyy-MM-dd HH:mm:ss", $null) }
        catch {}
    }
    try   { return [DateTime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

# ── Helper: Validate enctoken ──────────────────────────────
function Assert-EncToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Host @"

  ============================================================
  Zerodha Kite authentication required (enctoken)
  ============================================================

  1. Log in at https://kite.zerodha.com
  2. Press F12 > Application > Cookies > kite.zerodha.com
  3. Copy the 'enctoken' value
  4. Set it:
       `$env:KITE_ENCTOKEN = "paste_here"

"@ -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ── Helper: Build auth headers ─────────────────────────────
function Get-KiteHeaders {
    param([string]$EncToken, [string]$Referer = "https://kite.zerodha.com")
    return @{
        "Authorization" = "enctoken $EncToken"
        "User-Agent"    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        "Accept"        = "application/json"
        "Referer"       = $Referer
    }
}

# ── Interval metadata ──────────────────────────────────────
function Get-IntervalMeta {
    param([string]$Interval)
    $map = @{
        'minute'   = @{ Label = '1 Min';   LookbackMin = 120 }
        '3minute'  = @{ Label = '3 Min';   LookbackMin = 360 }
        '5minute'  = @{ Label = '5 Min';   LookbackMin = 600 }
        '10minute' = @{ Label = '10 Min';  LookbackMin = 1200 }
        '15minute' = @{ Label = '15 Min';  LookbackMin = 1800 }
        '30minute' = @{ Label = '30 Min';  LookbackMin = 3600 }
        '60minute' = @{ Label = '1 Hour';  LookbackMin = 7200 }
        'day'      = @{ Label = 'Daily';   LookbackMin = 43200 }
    }
    $meta = $map[$Interval]
    if (-not $meta) { $meta = @{ Label = $Interval; LookbackMin = 120 } }
    return $meta
}

# ════════════════════════════════════════════════════════════
# FUNCTION: Get-KiteCandles
# Fetches historical candle data for ANY instrument
# ════════════════════════════════════════════════════════════
function Get-KiteCandles {
    [CmdletBinding(DefaultParameterSetName = 'ByToken')]
    param(
        # --- Instrument identification ---
        [Parameter(ParameterSetName = 'ByToken', Mandatory = $false)]
        [int]$InstrumentToken = 117128455,

        [Parameter(ParameterSetName = 'ByToken', Mandatory = $false)]
        [string]$TradingSymbol = "SILVERM26APRFUT",

        [Parameter(ParameterSetName = 'ByToken', Mandatory = $false)]
        [ValidateSet('NSE','BSE','NFO','BFO','MCX','CDS','BCD')]
        [string]$Exchange = "MCX",

        [Parameter(ParameterSetName = 'ByPreset', Mandatory = $true)]
        [string]$Preset,

        # --- Candle settings ---
        [ValidateSet('minute','3minute','5minute','10minute','15minute','30minute','60minute','day')]
        [string]$Interval = "minute",

        [ValidateRange(1, 500)]
        [int]$CandleCount = 10,

        # --- Time range (optional override) ---
        [DateTime]$From,
        [DateTime]$To,

        # --- Auth ---
        [string]$EncToken = $env:KITE_ENCTOKEN,

        # --- Output ---
        [switch]$Raw,
        [switch]$Continuous
    )

    # Validate auth
    if (-not (Assert-EncToken $EncToken)) { return }

    # Resolve preset
    if ($PSCmdlet.ParameterSetName -eq 'ByPreset') {
        $key = $Preset.ToUpper()
        if ($script:Presets.ContainsKey($key)) {
            $p = $script:Presets[$key]
            $InstrumentToken = $p.Token
            $TradingSymbol   = $p.Symbol
            $Exchange        = $p.Exchange
        }
        else {
            Write-Host "  Unknown preset: '$Preset'" -ForegroundColor Red
            Write-Host "  Available presets:" -ForegroundColor Yellow
            $script:Presets.Keys | Sort-Object | ForEach-Object {
                $p = $script:Presets[$_]
                Write-Host ("    {0,-25} {1,-6} {2}" -f $_, $p.Exchange, $p.Token) -ForegroundColor Gray
            }
            return
        }
    }

    # Time window
    $meta = Get-IntervalMeta $Interval
    $now  = Get-Date
    if (-not $To)   { $To   = $now }
    if (-not $From) { $From = $To.AddMinutes(-$meta.LookbackMin) }

    $fromStr = $From.ToString("yyyy-MM-dd+HH:mm:ss")
    $toStr   = $To.ToString("yyyy-MM-dd+HH:mm:ss")

    # API call
    $uri = "https://kite.zerodha.com/oms/instruments/historical/${InstrumentToken}/${Interval}?from=${fromStr}&to=${toStr}&oi=1"
    $headers = Get-KiteHeaders -EncToken $EncToken

    do {
        # Banner
        Write-Host ""
        Write-Host "  ================================================" -ForegroundColor Cyan
        Write-Host "  $TradingSymbol - $($meta.Label) Candles ($Exchange)" -ForegroundColor Cyan
        Write-Host "  ================================================" -ForegroundColor Cyan
        Write-Host "  Exchange : $Exchange"
        Write-Host "  Symbol   : $TradingSymbol"
        Write-Host "  Token    : $InstrumentToken"
        Write-Host "  Interval : $($meta.Label) ($Interval)"
        Write-Host "  Window   : $($From.ToString('yyyy-MM-dd HH:mm')) -> $($To.ToString('yyyy-MM-dd HH:mm'))"
        Write-Host ""

        # Recalculate time for continuous mode
        if ($Continuous) {
            $To      = Get-Date
            $From    = $To.AddMinutes(-$meta.LookbackMin)
            $fromStr = $From.ToString("yyyy-MM-dd+HH:mm:ss")
            $toStr   = $To.ToString("yyyy-MM-dd+HH:mm:ss")
            $uri     = "https://kite.zerodha.com/oms/instruments/historical/${InstrumentToken}/${Interval}?from=${fromStr}&to=${toStr}&oi=1"
        }

        # Fetch
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        }
        catch {
            $sc = $null
            if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            if ($sc -eq 403 -or $sc -eq 401) {
                Write-Host "  Enctoken expired. Log in again and copy a fresh token." -ForegroundColor Yellow
            }
            return
        }

        # Validate
        if (-not $response.data -or -not $response.data.candles -or $response.data.candles.Count -eq 0) {
            Write-Host "  No candle data. Market may be closed or instrument inactive." -ForegroundColor Yellow
            if ($Continuous) {
                Write-Host "  Retrying in 60s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 60
                continue
            }
            return
        }

        $allCandles = $response.data.candles
        $total      = $allCandles.Count
        $display    = $allCandles | Select-Object -Last $CandleCount

        # Raw output mode — return objects instead of formatted text
        if ($Raw) {
            $result = foreach ($c in $display) {
                $parsed = ParseKiteDateTime $c[0]
                [PSCustomObject]@{
                    DateTime = if ($parsed) { $parsed } else { $c[0] }
                    Open     = $c[1]
                    High     = $c[2]
                    Low      = $c[3]
                    Close    = $c[4]
                    Volume   = $c[5]
                    OI       = if ($c.Count -gt 6) { $c[6] } else { 0 }
                    Exchange = $Exchange
                    Symbol   = $TradingSymbol
                }
            }
            return $result
        }

        # Formatted table output
        Write-Host "  Total: $total candle(s) | Showing last $($display.Count)" -ForegroundColor Green
        Write-Host ""

        # Detect if this is equity (no OI) or F&O/commodity (has OI)
        $hasOI = $false
        foreach ($c in $display) {
            if ($c.Count -gt 6 -and $c[6] -ne 0) { $hasOI = $true; break }
        }

        if ($hasOI) {
            $fmt = " {0,-20} {1,14} {2,14} {3,14} {4,14} {5,10} {6,10}"
            Write-Host ($fmt -f "DateTime", "Open", "High", "Low", "Close", "Volume", "OI") -ForegroundColor Cyan
            Write-Host (" " + ("-" * 100)) -ForegroundColor DarkGray
        }
        else {
            $fmt = " {0,-20} {1,14} {2,14} {3,14} {4,14} {5,12}"
            Write-Host ($fmt -f "DateTime", "Open", "High", "Low", "Close", "Volume") -ForegroundColor Cyan
            Write-Host (" " + ("-" * 92)) -ForegroundColor DarkGray
        }

        foreach ($c in $display) {
            $parsed = ParseKiteDateTime $c[0]
            $dt   = if ($parsed) { $parsed.ToString("yyyy-MM-dd HH:mm:ss") } else { $c[0] }
            $open = "{0:N2}" -f $c[1]
            $high = "{0:N2}" -f $c[2]
            $low  = "{0:N2}" -f $c[3]
            $cls  = "{0:N2}" -f $c[4]
            $vol  = "{0:N0}" -f $c[5]

            if ($hasOI) {
                $oi = "{0:N0}" -f $(if ($c.Count -gt 6) { $c[6] } else { 0 })
                Write-Host ($fmt -f $dt, $open, $high, $low, $cls, $vol, $oi)
            }
            else {
                Write-Host ($fmt -f $dt, $open, $high, $low, $cls, $vol)
            }
        }

        Write-Host ""

        if ($Continuous) {
            $sleepSec = switch ($Interval) {
                'minute'   { 60 }
                '3minute'  { 180 }
                '5minute'  { 300 }
                default    { 60 }
            }
            Write-Host "  Refreshing in ${sleepSec}s... (Ctrl+C to stop)" -ForegroundColor DarkGray
            Start-Sleep -Seconds $sleepSec
        }
    } while ($Continuous)
}

# ════════════════════════════════════════════════════════════
# FUNCTION: Search-KiteInstrument
# Search instruments by name across all exchanges
# ════════════════════════════════════════════════════════════
function Search-KiteInstrument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [ValidateSet('NSE','BSE','NFO','BFO','MCX','CDS','BCD','ALL')]
        [string]$Exchange = "ALL",

        [int]$MaxResults = 20,

        [string]$EncToken = $env:KITE_ENCTOKEN
    )

    if (-not (Assert-EncToken $EncToken)) { return }

    $headers = Get-KiteHeaders -EncToken $EncToken

    $searchExchange = if ($Exchange -eq 'ALL') { '' } else { $Exchange }

    Write-Host ""
    Write-Host "  Searching for '$Query'..." -ForegroundColor Cyan

    try {
        # Try the market-watch search API
        $searchUri = "https://kite.zerodha.com/oms/marketwatch/search?q=$([uri]::EscapeDataString($Query))&exchange=$searchExchange"
        $resp = Invoke-RestMethod -Uri $searchUri -Headers $headers -Method Get -ErrorAction Stop

        if (-not $resp.data -or $resp.data.Count -eq 0) {
            Write-Host "  No instruments found for '$Query'" -ForegroundColor Yellow
            return
        }

        $results = $resp.data | Select-Object -First $MaxResults

        Write-Host "  Found $($resp.data.Count) instrument(s). Showing top $($results.Count):" -ForegroundColor Green
        Write-Host ""

        $fmt = " {0,-8} {1,-30} {2,12} {3,-15} {4,-12}"
        Write-Host ($fmt -f "Exchange", "Symbol", "Token", "Type", "Segment") -ForegroundColor Cyan
        Write-Host (" " + ("-" * 80)) -ForegroundColor DarkGray

        foreach ($inst in $results) {
            $ex   = $inst.exchange
            $sym  = $inst.tradingsymbol
            $tok  = $inst.instrument_token
            $type = $inst.instrument_type
            $seg  = $inst.segment

            Write-Host ($fmt -f $ex, $sym, $tok, $type, $seg)
        }

        Write-Host ""
        Write-Host "  Use the token with:" -ForegroundColor DarkGray
        Write-Host '  Get-KiteCandles -InstrumentToken <TOKEN> -TradingSymbol "<SYMBOL>" -Exchange "<EX>"' -ForegroundColor White
        Write-Host ""

        # Return objects for pipeline use
        return $results | ForEach-Object {
            [PSCustomObject]@{
                Exchange        = $_.exchange
                TradingSymbol   = $_.tradingsymbol
                InstrumentToken = $_.instrument_token
                InstrumentType  = $_.instrument_type
                Segment         = $_.segment
                Expiry          = $_.expiry
                Strike          = $_.strike
                LotSize         = $_.lot_size
            }
        }
    }
    catch {
        Write-Host "  Search failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}

# ════════════════════════════════════════════════════════════
# FUNCTION: Show-KitePresets
# List all preset instruments
# ════════════════════════════════════════════════════════════
function Show-KitePresets {
    Write-Host ""
    Write-Host "  Available Preset Instruments" -ForegroundColor Cyan
    Write-Host "  ============================" -ForegroundColor Cyan
    Write-Host ""

    $fmt = " {0,-25} {1,-6} {2,-25} {3,12}"
    Write-Host ($fmt -f "Preset Name", "Exch", "Symbol", "Token") -ForegroundColor Cyan
    Write-Host (" " + ("-" * 72)) -ForegroundColor DarkGray

    $groups = @{
        'Indices'     = @('NIFTY','SENSEX','BANKNIFTY','FINNIFTY','MIDCPNIFTY')
        'Equity'      = @('RELIANCE','TCS','INFY','HDFCBANK','ICICIBANK','SBIN','TATAMOTORS','ITC','WIPRO','BHARTIARTL','KOTAKBANK','LT','HINDUNILVR','AXISBANK','MARUTI')
        'Commodities' = @('SILVERM26APRFUT','GOLDM26APRFUT','CRUDEOIL26APRFUT','NATURALGAS26APRFUT')
    }

    foreach ($group in @('Indices','Equity','Commodities')) {
        Write-Host ""
        Write-Host "  ── $group ──" -ForegroundColor Yellow
        foreach ($key in $groups[$group]) {
            if ($script:Presets.ContainsKey($key)) {
                $p = $script:Presets[$key]
                Write-Host ($fmt -f $key, $p.Exchange, $p.Symbol, $p.Token)
            }
        }
    }

    Write-Host ""
    Write-Host '  Usage:  Get-KiteCandles -Preset NIFTY' -ForegroundColor DarkGray
    Write-Host '          Get-KiteCandles -Preset RELIANCE -Interval 5minute -CandleCount 20' -ForegroundColor DarkGray
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Get-KiteLiveCandles
# WebSocket streaming + real-time candle builder
# ══════════════════════════════════════════════════════════════
function Get-KiteLiveCandles {
    param(
        [string]$TradingSymbol  = 'NIFTY',
        [int]$InstrumentToken,
        [ValidateSet('minute','3minute','5minute','10minute','15minute','30minute','60minute')]
        [string]$TimeFrame      = '5minute',
        [int]$CandlesToShow     = 10,
        [switch]$FullMode,
        [switch]$ListSymbols,
        [string]$AccessToken,
        [string]$API_Key        = '0fvxhlacu555dhp0'
    )

    # --- List symbols ---
    if ($ListSymbols) {
        Show-KiteSymbols
        return
    }

    # --- Resolve symbol ---
    $sym = $TradingSymbol.ToUpper().Trim()
    if ($InstrumentToken -gt 0) {
        $instToken = $InstrumentToken
        $label = $sym
    } else {
        $preset = Resolve-KiteSymbol $sym
        if ($preset) {
            $instToken = $preset.Token
            $label = $preset.Label
        } else {
            Write-Host "  Unknown symbol: $TradingSymbol. Use -ListSymbols to see presets." -ForegroundColor Red
            return
        }
    }

    # --- Interval ---
    $intMin   = Get-IntervalMinutes $TimeFrame
    $intLabel = Get-IntervalLabel $intMin

    # --- Auth ---
    if (-not $AccessToken) {
        Write-Host '  No token. Exiting.' -ForegroundColor Red; return
    }

    # --- Candle state ---
    $script:candleStore = @{}
    $script:buildingCdl = @{}
    $script:totalTicks  = 0
    $script:liveIntMin  = $intMin
    $script:liveMeta    = @{ Sym=$sym; Label=$label; Token=$instToken; TF=$TimeFrame; IntLabel=$intLabel; Show=$CandlesToShow }

    function script:Get-LiveCandleKey {
        $now = Get-Date
        $bucket = [Math]::Floor($now.Minute / $script:liveIntMin) * $script:liveIntMin
        return $now.ToString('yyyy-MM-dd HH:') + $bucket.ToString('00')
    }

    function script:Update-LiveCandle([int]$tk, [double]$ltp, [int]$vol, [double]$opn, [double]$hi, [double]$lo, [double]$cls, [int]$oi) {
        $script:totalTicks++
        $mk = script:Get-LiveCandleKey
        if (-not $script:candleStore.ContainsKey($tk)) {
            $script:candleStore[$tk] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $cur = $script:buildingCdl[$tk]
        if (($null -eq $cur) -or ($cur.MK -ne $mk)) {
            if ($null -ne $cur) {
                $script:candleStore[$tk].Add([PSCustomObject]@{
                    MK=$cur.MK; O=$cur.O; H=$cur.H; L=$cur.L; C=$cur.C; V=$cur.V; OI=$cur.OI; T=$cur.T
                })
            }
            $script:buildingCdl[$tk] = @{
                MK=$mk; O=$ltp; H=$ltp; L=$ltp; C=$ltp; V=0; LV=$vol; OI=$oi; T=1
                DO=$opn; DH=$hi; DL=$lo; DC=$cls
            }
        } else {
            $cur.H  = [Math]::Max($cur.H, $ltp)
            $cur.L  = [Math]::Min($cur.L, $ltp)
            $cur.C  = $ltp
            $cur.OI = $oi
            $cur.T++
            if ($hi -gt 0)  { $cur.DH = $hi }
            if ($lo -gt 0)  { $cur.DL = $lo }
            if ($opn -gt 0) { $cur.DO = $opn }
            if ($cls -gt 0) { $cur.DC = $cls }
            if (($vol -gt $cur.LV) -and ($cur.LV -gt 0)) { $cur.V += ($vol - $cur.LV) }
            $cur.LV = $vol
        }
    }

    function script:Show-LiveTable([int]$tk) {
        $m = $script:liveMeta
        $all = [System.Collections.Generic.List[PSCustomObject]]::new()
        $done = $script:candleStore[$tk]
        if ($done -and $done.Count -gt 0) { $all.AddRange($done) }
        $cur = $script:buildingCdl[$tk]
        if ($null -ne $cur) {
            $all.Add([PSCustomObject]@{ MK=$cur.MK; O=$cur.O; H=$cur.H; L=$cur.L; C=$cur.C; V=$cur.V; OI=$cur.OI; T=$cur.T })
        }
        if ($all.Count -eq 0) { return }
        $skip = [Math]::Max(0, $all.Count - $m.Show)
        $disp = if ($skip -gt 0) { $all.GetRange($skip, $all.Count - $skip) } else { $all }

        Clear-Host
        Write-Host ''
        Write-Host '  ================================================' -ForegroundColor Cyan
        Write-Host "  $($m.Label) - Live $($m.IntLabel) Candles (WebSocket)" -ForegroundColor Cyan
        Write-Host '  ================================================' -ForegroundColor Cyan
        Write-Host "  Symbol  : $($m.Sym)  |  Token: $($m.Token)  |  TimeFrame: $($m.TF)"
        Write-Host "  Ticks   : $($script:totalTicks)"
        Write-Host "  Candles : $($all.Count) total | Showing $($disp.Count)"
        Write-Host "  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        if ($null -ne $cur) {
            Write-Host "  LTP     : $($cur.C.ToString('N2'))  |  Day O/H/L/C: $($cur.DO.ToString('N2'))/$($cur.DH.ToString('N2'))/$($cur.DL.ToString('N2'))/$($cur.DC.ToString('N2'))" -ForegroundColor Green
        }
        Write-Host ''
        $fmt = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,8} {7,5}'
        Write-Host ($fmt -f 'Time','Open','High','Low','Close','Volume','OI','Ticks') -ForegroundColor Cyan
        Write-Host (' ' + ('-' * 102)) -ForegroundColor DarkGray
        for ($i = 0; $i -lt $disp.Count; $i++) {
            $c = $disp[$i]
            $ln = $fmt -f $c.MK, ('{0:N2}' -f $c.O), ('{0:N2}' -f $c.H), ('{0:N2}' -f $c.L), ('{0:N2}' -f $c.C), ('{0:N0}' -f $c.V), ('{0:N0}' -f $c.OI), $c.T
            if ($i -eq ($disp.Count - 1)) { Write-Host $ln -ForegroundColor Yellow } else { Write-Host $ln }
        }
        Write-Host ''
        Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
    }

    # --- WebSocket ---
    $wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
    $modeStr = if ($FullMode) { 'full' } else { 'quote' }

    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host '  Zerodha WebSocket - Live Candle Data' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host "  Symbol   : $label ($sym)"
    Write-Host "  Token    : $instToken"
    Write-Host "  TimeFrame: $TimeFrame ($($intMin)m candles)"
    Write-Host "  Mode     : $modeStr"
    Write-Host ''
    Write-Host '  Connecting...' -ForegroundColor Yellow

    $maxRetries = 3
    $retryCount = 0
    $buf = New-Object byte[] 65536

    while ($retryCount -le $maxRetries) {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.Options.SetRequestHeader('X-Kite-Version', '3')
        $cts = [System.Threading.CancellationTokenSource]::new()

        try {
            $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
            if (-not $ct.Wait(15000)) {
                Write-Host '  Connection timed out.' -ForegroundColor Red
                $retryCount++
                if ($retryCount -le $maxRetries) {
                    $wait = $retryCount * 5
                    Write-Host "  Retrying in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    Start-Sleep -Seconds $wait
                    continue
                }
                return
            }
            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                Write-Host "  Connection failed. State: $($ws.State)" -ForegroundColor Red
                return
            }

            $retryCount = 0
            Write-Host '  Connected!' -ForegroundColor Green

            # Subscribe + set mode
            $subB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"subscribe","v":[' + $instToken + ']}')
            $ws.SendAsync([System.ArraySegment[byte]]::new($subB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
            Write-Host "  Subscribed to $label" -ForegroundColor Green

            $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["' + $modeStr + '",[' + $instToken + ']]}')
            $ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
            Write-Host "  Mode: $modeStr" -ForegroundColor Green
            Write-Host ''
            Write-Host '  Waiting for market ticks...' -ForegroundColor Yellow

            while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $seg = [System.ArraySegment[byte]]::new($buf)
                try {
                    $rt = $ws.ReceiveAsync($seg, $cts.Token)
                    if (-not $rt.Wait(30000)) { continue }
                    $res = $rt.Result
                } catch {
                    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
                    continue
                }

                if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    Write-Host '  Server closed connection.' -ForegroundColor Yellow; break
                }
                if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                    if ($res.Count -gt 1) {
                        $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
                        try { $jm = $txt | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($jm.type -eq 'error') { Write-Host "  ERROR: $($jm.data)" -ForegroundColor Red } } catch {}
                    }
                    continue
                }
                if (($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) -and ($res.Count -gt 2)) {
                    $ticks = Parse-KiteTicks $buf $res.Count
                    foreach ($tk in $ticks) {
                        if ($tk.LTP -gt 0) { script:Update-LiveCandle $tk.Tok $tk.LTP $tk.Vol $tk.O $tk.H $tk.L $tk.C $tk.OI }
                    }
                    script:Show-LiveTable $instToken
                }
            }

            # Connection dropped — try reconnect
            $retryCount++
            if ($retryCount -le $maxRetries) {
                $wait = $retryCount * 5
                Write-Host "  Connection lost. Reconnecting in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
            }
        }
        catch {
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.InnerException) { Write-Host "  Detail: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
            $retryCount++
            if ($retryCount -le $maxRetries) {
                $wait = $retryCount * 5
                Write-Host "  Retrying in ${wait}s... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
            }
        }
        finally {
            if ($ws -and ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open)) {
                try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done', $cts.Token).Wait(5000) } catch {}
            }
            if ($ws)  { $ws.Dispose() }
            if ($cts) { $cts.Dispose() }
        }
    }

    Write-Host ''
    Write-Host '  Disconnected.' -ForegroundColor Yellow
    $cnt = 0
    if ($script:candleStore[$instToken]) { $cnt += $script:candleStore[$instToken].Count }
    if ($script:buildingCdl[$instToken]) { $cnt++ }
    Write-Host "  $label : $cnt candle(s) from $($script:totalTicks) ticks" -ForegroundColor Gray
    Write-Host ''
}

# ── Module exports (single consolidated statement) ─────────
Export-ModuleMember -Function Get-KiteCandles, Search-KiteInstrument, Show-KitePresets, Get-KiteLiveCandles, Resolve-KiteAccessToken, Exchange-KiteRequestToken, Show-KiteSymbols, Resolve-KiteSymbol
