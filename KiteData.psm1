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
    'NATURALGAS'       = @{ Token = 124791047; Exchange = 'MCX';  Symbol = 'NATURALGAS26APRFUT';  Label = 'NATURAL GAS FUT' }
    'NATURALGAS26APRFUT' = @{ Token = 124791047; Exchange = 'MCX'; Symbol = 'NATURALGAS26APRFUT'; Label = 'NATURAL GAS FUT' }
    'NATGASMINI'       = @{ Token = 124791303; Exchange = 'MCX';  Symbol = 'NATGASMINI26APRFUT';  Label = 'NATGAS MINI FUT' }
    'NATGASMINI26APRFUT' = @{ Token = 124791303; Exchange = 'MCX'; Symbol = 'NATGASMINI26APRFUT'; Label = 'NATGAS MINI FUT' }
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
function Parse-KiteTicks([byte[]]$packetData, [int]$packetLength) {
    if ($packetLength -lt 4) { return @() }
    $packetCount = Read-Int16BE $packetData 0
    $parsedTicks = [System.Collections.Generic.List[hashtable]]::new($packetCount)
    $offset = 2
    for ($packetIndex = 0; $packetIndex -lt $packetCount; $packetIndex++) {
        if (($offset + 2) -gt $packetLength) { break }
        $payloadSize = Read-Int16BE $packetData $offset
        $offset += 2
        if (($payloadSize -lt 4) -or (($offset + $payloadSize) -gt $packetLength)) { break }
        $payloadStart = $offset
        $priceDivisor = 100.0
        $tick = @{
            InstrumentToken = Read-Int32BE $packetData $payloadStart
            LastPrice       = 0.0
            Volume          = 0
            DayOpen         = 0.0
            DayHigh         = 0.0
            DayLow          = 0.0
            DayClose        = 0.0
            OpenInterest    = 0
        }
        switch ($payloadSize) {
            8   { $tick.LastPrice = (Read-Int32BE $packetData ($payloadStart+4)) / $priceDivisor }
            28  { $tick.LastPrice=(Read-Int32BE $packetData ($payloadStart+4))/$priceDivisor; $tick.DayHigh=(Read-Int32BE $packetData ($payloadStart+8))/$priceDivisor; $tick.DayLow=(Read-Int32BE $packetData ($payloadStart+12))/$priceDivisor; $tick.DayOpen=(Read-Int32BE $packetData ($payloadStart+16))/$priceDivisor; $tick.DayClose=(Read-Int32BE $packetData ($payloadStart+20))/$priceDivisor }
            32  { $tick.LastPrice=(Read-Int32BE $packetData ($payloadStart+4))/$priceDivisor; $tick.DayHigh=(Read-Int32BE $packetData ($payloadStart+8))/$priceDivisor; $tick.DayLow=(Read-Int32BE $packetData ($payloadStart+12))/$priceDivisor; $tick.DayOpen=(Read-Int32BE $packetData ($payloadStart+16))/$priceDivisor; $tick.DayClose=(Read-Int32BE $packetData ($payloadStart+20))/$priceDivisor }
            44  { $tick.LastPrice=(Read-Int32BE $packetData ($payloadStart+4))/$priceDivisor; $tick.Volume=Read-Int32BE $packetData ($payloadStart+16); $tick.DayOpen=(Read-Int32BE $packetData ($payloadStart+28))/$priceDivisor; $tick.DayHigh=(Read-Int32BE $packetData ($payloadStart+32))/$priceDivisor; $tick.DayLow=(Read-Int32BE $packetData ($payloadStart+36))/$priceDivisor; $tick.DayClose=(Read-Int32BE $packetData ($payloadStart+40))/$priceDivisor }
            184 { $tick.LastPrice=(Read-Int32BE $packetData ($payloadStart+4))/$priceDivisor; $tick.Volume=Read-Int32BE $packetData ($payloadStart+16); $tick.DayOpen=(Read-Int32BE $packetData ($payloadStart+28))/$priceDivisor; $tick.DayHigh=(Read-Int32BE $packetData ($payloadStart+32))/$priceDivisor; $tick.DayLow=(Read-Int32BE $packetData ($payloadStart+36))/$priceDivisor; $tick.DayClose=(Read-Int32BE $packetData ($payloadStart+40))/$priceDivisor; $tick.OpenInterest=Read-Int32BE $packetData ($payloadStart+48) }
            default {
                if ($payloadSize -ge 8)  { $tick.LastPrice = (Read-Int32BE $packetData ($payloadStart+4)) / $priceDivisor }
                if ($payloadSize -ge 44) { $tick.Volume=Read-Int32BE $packetData ($payloadStart+16); $tick.DayOpen=(Read-Int32BE $packetData ($payloadStart+28))/$priceDivisor; $tick.DayHigh=(Read-Int32BE $packetData ($payloadStart+32))/$priceDivisor; $tick.DayLow=(Read-Int32BE $packetData ($payloadStart+36))/$priceDivisor; $tick.DayClose=(Read-Int32BE $packetData ($payloadStart+40))/$priceDivisor }
                if ($payloadSize -ge 52) { $tick.OpenInterest = Read-Int32BE $packetData ($payloadStart+48) }
            }
        }
        $parsedTicks.Add($tick)
        $offset += $payloadSize
    }
    return $parsedTicks
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
    $url = 'https://kite.zerodha.com/connect/login?api_key=' + $ApiKey
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
function Get-IntervalSeconds([string]$Interval) {
    switch ($Interval) {
        '5second'  { return 5 }
        '15second' { return 15 }
        '30second' { return 30 }
        'minute'   { return 60 }
        '3minute'  { return 180 }
        '5minute'  { return 300 }
        '10minute' { return 600 }
        '15minute' { return 900 }
        '30minute' { return 1800 }
        '60minute' { return 3600 }
        default    { return 60 }
    }
}

# Backward compatibility wrapper
function Get-IntervalMinutes([string]$Interval) {
    return [Math]::Max(1, [int]([Math]::Floor((Get-IntervalSeconds $Interval) / 60)))
}

function Get-IntervalLabel([int]$Seconds) {
    if ($Seconds -lt 60)   { return "$($Seconds)-Sec" }
    if ($Seconds -eq 60)   { return '1-Min' }
    if ($Seconds -eq 3600) { return '1-Hour' }
    return "$([int]($Seconds / 60))-Min"
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
        [ValidateSet('5second','15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
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
    $intSec   = Get-IntervalSeconds $TimeFrame
    $intMin   = Get-IntervalMinutes $TimeFrame
    $intLabel = Get-IntervalLabel $intSec

    # --- Auth ---
    if (-not $AccessToken) {
        Write-Host '  No token. Exiting.' -ForegroundColor Red; return
    }

    # --- Candle state ---
    $script:CompletedCandles   = @{}   # token -> List of closed candle objects
    $script:ActiveCandle       = @{}   # token -> current building candle hashtable
    $script:TickCount          = 0
    $script:IntervalSeconds    = $intSec
    $script:DisplayConfig      = @{
        SymbolName      = $sym
        SymbolLabel     = $label
        InstrumentToken = $instToken
        TimeFrame       = $TimeFrame
        IntervalLabel   = $intLabel
        MaxCandles      = $CandlesToShow
    }
    $script:LastDisplayTime    = [datetime]::MinValue
    $script:DisplayIntervalMs  = 250    # throttle: refresh display max 4x/sec

    function script:Get-CandleTimeBucket {
        $now = Get-Date
        $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
        $bucket = [Math]::Floor($totalSeconds / $script:IntervalSeconds) * $script:IntervalSeconds
        $bH = [int][Math]::Floor($bucket / 3600)
        $bM = [int][Math]::Floor(($bucket % 3600) / 60)
        $bS = [int]($bucket % 60)
        return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
    }

    function script:Update-CandleFromTick([int]$instrumentToken, [double]$lastPrice, [int]$volume, [double]$dayOpen, [double]$dayHigh, [double]$dayLow, [double]$dayClose, [int]$openInterest) {
        $script:TickCount++
        $timeBucket = script:Get-CandleTimeBucket
        if (-not $script:CompletedCandles.ContainsKey($instrumentToken)) {
            $script:CompletedCandles[$instrumentToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $currentCandle = $script:ActiveCandle[$instrumentToken]
        if (($null -eq $currentCandle) -or ($currentCandle.TimeBucket -ne $timeBucket)) {
            # Close previous candle and start new one
            if ($null -ne $currentCandle) {
                $script:CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                    TimeBucket=$currentCandle.TimeBucket; Open=$currentCandle.Open; High=$currentCandle.High
                    Low=$currentCandle.Low; Close=$currentCandle.Close; Volume=$currentCandle.Volume
                    OpenInterest=$currentCandle.OpenInterest; TicksInCandle=$currentCandle.TicksInCandle
                })
            }
            $script:ActiveCandle[$instrumentToken] = @{
                TimeBucket=$timeBucket; Open=$lastPrice; High=$lastPrice; Low=$lastPrice; Close=$lastPrice
                Volume=0; PreviousVolume=$volume; OpenInterest=$openInterest; TicksInCandle=1
                DayOpen=$dayOpen; DayHigh=$dayHigh; DayLow=$dayLow; DayClose=$dayClose
            }
        } else {
            $currentCandle.High  = [Math]::Max($currentCandle.High, $lastPrice)
            $currentCandle.Low   = [Math]::Min($currentCandle.Low, $lastPrice)
            $currentCandle.Close = $lastPrice
            $currentCandle.OpenInterest = $openInterest
            $currentCandle.TicksInCandle++
            if ($dayHigh -gt 0)  { $currentCandle.DayHigh  = $dayHigh }
            if ($dayLow -gt 0)   { $currentCandle.DayLow   = $dayLow }
            if ($dayOpen -gt 0)  { $currentCandle.DayOpen  = $dayOpen }
            if ($dayClose -gt 0) { $currentCandle.DayClose = $dayClose }
            if (($volume -gt $currentCandle.PreviousVolume) -and ($currentCandle.PreviousVolume -gt 0)) {
                $currentCandle.Volume += ($volume - $currentCandle.PreviousVolume)
            }
            $currentCandle.PreviousVolume = $volume
        }
    }

    function script:Render-CandleDisplay([int]$instrumentToken) {
        # Throttle: skip if last render was < 250ms ago
        $now = [datetime]::Now
        if (($now - $script:LastDisplayTime).TotalMilliseconds -lt $script:DisplayIntervalMs) { return }
        $script:LastDisplayTime = $now

        $config = $script:DisplayConfig
        $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()
        $closedCandles = $script:CompletedCandles[$instrumentToken]
        if ($closedCandles -and $closedCandles.Count -gt 0) { $allCandles.AddRange($closedCandles) }
        $currentCandle = $script:ActiveCandle[$instrumentToken]
        if ($null -ne $currentCandle) {
            $allCandles.Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket; Open=$currentCandle.Open; High=$currentCandle.High
                Low=$currentCandle.Low; Close=$currentCandle.Close; Volume=$currentCandle.Volume
                OpenInterest=$currentCandle.OpenInterest; TicksInCandle=$currentCandle.TicksInCandle
            })
        }
        if ($allCandles.Count -eq 0) { return }
        $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
        $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

        # Build output as single string for faster console write
        $sb = [System.Text.StringBuilder]::new(2048)
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  $($config.SymbolLabel) - Live $($config.IntervalLabel) Candles (WebSocket)")
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TimeFrame: $($config.TimeFrame)")
        $null = $sb.AppendLine("  Ticks   : $($script:TickCount)")
        $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
        $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        if ($null -ne $currentCandle) {
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
        }
        $null = $sb.AppendLine('')
        $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,8} {7,5}'
        $null = $sb.AppendLine(($rowFormat -f 'Time','Open','High','Low','Close','Volume','OI','Ticks'))
        $null = $sb.AppendLine(' ' + ('-' * 102))
        for ($rowIndex = 0; $rowIndex -lt $visibleCandles.Count; $rowIndex++) {
            $candle = $visibleCandles[$rowIndex]
            $null = $sb.AppendLine(($rowFormat -f $candle.TimeBucket, ('{0:N2}' -f $candle.Open), ('{0:N2}' -f $candle.High), ('{0:N2}' -f $candle.Low), ('{0:N2}' -f $candle.Close), ('{0:N0}' -f $candle.Volume), ('{0:N0}' -f $candle.OpenInterest), $candle.TicksInCandle))
        }
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('  Press Ctrl+C to stop')

        Clear-Host
        Write-Host $sb.ToString()
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
    Write-Host "  TimeFrame: $TimeFrame ($intLabel candles)"
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

            if ($ticksProcessed) { $retryCount = 0 }; $ticksProcessed = $false
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
                    foreach ($tick in $ticks) {
                        if ($tick.LastPrice -gt 0) { script:Update-CandleFromTick $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest }
                    }
                    $ticksProcessed = $true
                    script:Render-CandleDisplay $instToken
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
    if ($script:CompletedCandles[$instToken]) { $cnt += $script:CompletedCandles[$instToken].Count }
    if ($script:ActiveCandle[$instToken]) { $cnt++ }
    Write-Host "  $label : $cnt candle(s) from $($script:TickCount) ticks" -ForegroundColor Gray
    Write-Host ''
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Get-KiteHeikinAshiCandles
# WebSocket streaming + real-time Heikin-Ashi candle builder
# ══════════════════════════════════════════════════════════════
function Get-KiteHeikinAshiCandles {
    param(
        [string]$TradingSymbol  = 'NIFTY',
        [int]$InstrumentToken,
        [ValidateSet('5second','15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
        [string]$TimeFrame      = '5minute',
        [int]$CandlesToShow     = 10,
        [switch]$FullMode,
        [switch]$ListSymbols,
        [string]$AccessToken,
        [string]$API_Key        = '0fvxhlacu555dhp0'
    )

    if ($ListSymbols) { Show-KiteSymbols; return }

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

    $intSec   = Get-IntervalSeconds $TimeFrame
    $intMin   = Get-IntervalMinutes $TimeFrame
    $intLabel = Get-IntervalLabel $intSec

    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; return }

    # --- Heikin-Ashi state ---
    $script:HA_CompletedCandles = @{}   # token -> List of closed HA candles
    $script:HA_ActiveCandle     = @{}   # token -> current building raw candle
    $script:HA_PreviousCandle   = @{}   # token -> previous closed HA candle (for HA calc)
    $script:HA_TickCount        = 0
    $script:HA_IntervalSeconds  = $intSec
    $script:HA_DisplayConfig    = @{
        SymbolName      = $sym
        SymbolLabel     = $label
        InstrumentToken = $instToken
        TimeFrame       = $TimeFrame
        IntervalLabel   = $intLabel
        MaxCandles      = $CandlesToShow
    }
    $script:HA_LastDisplayTime   = [datetime]::MinValue
    $script:HA_DisplayIntervalMs = 250

    function script:Get-HA-TimeBucket {
        $now = Get-Date
        $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
        $bucket = [Math]::Floor($totalSeconds / $script:HA_IntervalSeconds) * $script:HA_IntervalSeconds
        $bH = [int][Math]::Floor($bucket / 3600)
        $bM = [int][Math]::Floor(($bucket % 3600) / 60)
        $bS = [int]($bucket % 60)
        return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
    }

    function script:Convert-ToHeikinAshi([hashtable]$rawCandle, [hashtable]$previousHA) {
        # Heikin-Ashi formulas:
        #   HA_Close = (Open + High + Low + Close) / 4
        #   HA_Open  = (prev_HA_Open + prev_HA_Close) / 2   (or raw Open for first candle)
        #   HA_High  = Max(High, HA_Open, HA_Close)
        #   HA_Low   = Min(Low, HA_Open, HA_Close)
        $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
        if ($null -ne $previousHA) {
            $haOpen = ($previousHA.Open + $previousHA.Close) / 2.0
        } else {
            $haOpen = ($rawCandle.Open + $rawCandle.Close) / 2.0
        }
        $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
        $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
        return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
    }

    function script:Update-HeikinAshiFromTick([int]$instrumentToken, [double]$lastPrice, [int]$volume, [double]$dayOpen, [double]$dayHigh, [double]$dayLow, [double]$dayClose, [int]$openInterest) {
        $script:HA_TickCount++
        $timeBucket = script:Get-HA-TimeBucket

        if (-not $script:HA_CompletedCandles.ContainsKey($instrumentToken)) {
            $script:HA_CompletedCandles[$instrumentToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        $currentCandle = $script:HA_ActiveCandle[$instrumentToken]

        if (($null -eq $currentCandle) -or ($currentCandle.TimeBucket -ne $timeBucket)) {
            # Close previous candle — convert to Heikin-Ashi and store
            if ($null -ne $currentCandle) {
                $prevHA = $script:HA_PreviousCandle[$instrumentToken]
                $ha = script:Convert-ToHeikinAshi $currentCandle $prevHA

                $closedHA = @{
                    Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close
                }
                $script:HA_PreviousCandle[$instrumentToken] = $closedHA

                $script:HA_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                    TimeBucket=$currentCandle.TimeBucket
                    Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                    Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                    Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                    TicksInCandle=$currentCandle.TicksInCandle
                })
            }
            # Start new raw candle
            $script:HA_ActiveCandle[$instrumentToken] = @{
                TimeBucket=$timeBucket; Open=$lastPrice; High=$lastPrice; Low=$lastPrice; Close=$lastPrice
                Volume=0; PreviousVolume=$volume; OpenInterest=$openInterest; TicksInCandle=1
                DayOpen=$dayOpen; DayHigh=$dayHigh; DayLow=$dayLow; DayClose=$dayClose
            }
        } else {
            $currentCandle.High  = [Math]::Max($currentCandle.High, $lastPrice)
            $currentCandle.Low   = [Math]::Min($currentCandle.Low, $lastPrice)
            $currentCandle.Close = $lastPrice
            $currentCandle.OpenInterest = $openInterest
            $currentCandle.TicksInCandle++
            if ($dayHigh -gt 0)  { $currentCandle.DayHigh  = $dayHigh }
            if ($dayLow -gt 0)   { $currentCandle.DayLow   = $dayLow }
            if ($dayOpen -gt 0)  { $currentCandle.DayOpen  = $dayOpen }
            if ($dayClose -gt 0) { $currentCandle.DayClose = $dayClose }
            if (($volume -gt $currentCandle.PreviousVolume) -and ($currentCandle.PreviousVolume -gt 0)) {
                $currentCandle.Volume += ($volume - $currentCandle.PreviousVolume)
            }
            $currentCandle.PreviousVolume = $volume
        }
    }

    function script:Render-HeikinAshiDisplay([int]$instrumentToken) {
        $now = [datetime]::Now
        if (($now - $script:HA_LastDisplayTime).TotalMilliseconds -lt $script:HA_DisplayIntervalMs) { return }
        $script:HA_LastDisplayTime = $now

        $config = $script:HA_DisplayConfig
        $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()

        $closedCandles = $script:HA_CompletedCandles[$instrumentToken]
        if ($closedCandles -and $closedCandles.Count -gt 0) { $allCandles.AddRange($closedCandles) }

        # Convert current building candle to live HA preview
        $currentCandle = $script:HA_ActiveCandle[$instrumentToken]
        if ($null -ne $currentCandle) {
            $prevHA = $script:HA_PreviousCandle[$instrumentToken]
            $ha = script:Convert-ToHeikinAshi $currentCandle $prevHA
            $allCandles.Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
            })
        }
        if ($allCandles.Count -eq 0) { return }

        $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
        $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

        # Determine candle direction for coloring
        $sb = [System.Text.StringBuilder]::new(2048)
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  $($config.SymbolLabel) - Live $($config.IntervalLabel) Heikin-Ashi (WebSocket)")
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TimeFrame: $($config.TimeFrame)")
        $null = $sb.AppendLine("  Ticks   : $($script:HA_TickCount)")
        $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
        $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        if ($null -ne $currentCandle) {
            $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
        }
        $null = $sb.AppendLine('')
        $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,8} {7,5} {8,6}'
        $null = $sb.AppendLine(($rowFormat -f 'Time','HA Open','HA High','HA Low','HA Close','Volume','OI','Ticks','Trend'))
        $null = $sb.AppendLine(' ' + ('-' * 112))

        Clear-Host
        Write-Host $sb.ToString()

        # Write candle rows with color (green=bullish, red=bearish)
        for ($rowIndex = 0; $rowIndex -lt $visibleCandles.Count; $rowIndex++) {
            $candle = $visibleCandles[$rowIndex]
            $trend = if ($candle.Close -ge $candle.Open) { '  UP' } else { 'DOWN' }
            $color = if ($candle.Close -ge $candle.Open) { 'Green' } else { 'Red' }
            $line = $rowFormat -f $candle.TimeBucket, ('{0:N2}' -f $candle.Open), ('{0:N2}' -f $candle.High), ('{0:N2}' -f $candle.Low), ('{0:N2}' -f $candle.Close), ('{0:N0}' -f $candle.Volume), ('{0:N0}' -f $candle.OpenInterest), $candle.TicksInCandle, $trend
            if ($rowIndex -eq ($visibleCandles.Count - 1)) {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line -ForegroundColor $color
            }
        }
        Write-Host ''
        Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
    }

    # --- WebSocket ---
    $wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
    $modeStr = if ($FullMode) { 'full' } else { 'quote' }

    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host '  Zerodha WebSocket - Live Heikin-Ashi Candles' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host "  Symbol   : $label ($sym)"
    Write-Host "  Token    : $instToken"
    Write-Host "  TimeFrame: $TimeFrame ($intLabel candles)"
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
                    foreach ($tick in $ticks) {
                        if ($tick.LastPrice -gt 0) {
                            script:Update-HeikinAshiFromTick $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest
                        }
                    }
                    script:Render-HeikinAshiDisplay $instToken
                }
            }

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
    if ($script:HA_CompletedCandles[$instToken]) { $cnt += $script:HA_CompletedCandles[$instToken].Count }
    if ($script:HA_ActiveCandle[$instToken]) { $cnt++ }
    Write-Host "  $label : $cnt Heikin-Ashi candle(s) from $($script:HA_TickCount) ticks" -ForegroundColor Gray
    Write-Host ''
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Invoke-KiteHALongStrategy
# Heikin-Ashi Long-only strategy with order file logging
# Entry: current HA Close > previous HA High
# Exit:  current HA Close < previous HA Low
# ══════════════════════════════════════════════════════════════
function Invoke-KiteHALongStrategy {
    param(
        [string]$TradingSymbol  = 'NIFTY',
        [int]$InstrumentToken,
        [ValidateSet('5second','15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
        [string]$TimeFrame      = '5minute',
        [int]$CandlesToShow     = 10,
        [switch]$FullMode,
        [switch]$ListSymbols,
        [string]$AccessToken,
        [string]$API_Key        = '0fvxhlacu555dhp0',
        [string]$OrdersFolder
    )

    if ($ListSymbols) { Show-KiteSymbols; return }

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

    $intSec   = Get-IntervalSeconds $TimeFrame
    $intMin   = Get-IntervalMinutes $TimeFrame
    $intLabel = Get-IntervalLabel $intSec

    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; return }

    # --- Ensure PlacedOrders folder exists ---
    if (-not $OrdersFolder) { $OrdersFolder = Join-Path (Split-Path $MyInvocation.ScriptName -Parent) 'PlacedOrders' }
    if (-not (Test-Path $OrdersFolder)) { New-Item -ItemType Directory -Path $OrdersFolder -Force | Out-Null }

    # --- HA + Strategy state ---
    $script:STR_CompletedCandles = @{}
    $script:STR_ActiveCandle     = @{}
    $script:STR_PreviousHA       = @{}
    $script:STR_TickCount        = 0
    $script:STR_IntervalSeconds  = $intSec
    $script:STR_DisplayConfig    = @{
        SymbolName=$sym; SymbolLabel=$label; InstrumentToken=$instToken
        TimeFrame=$TimeFrame; IntervalLabel=$intLabel; MaxCandles=$CandlesToShow
    }
    $script:STR_LastDisplayTime   = [datetime]::MinValue
    $script:STR_DisplayIntervalMs = 250

    # Strategy state
    $script:LongOrderPlaced      = $false
    $script:LongEntryPrice       = 0.0
    $script:LongEntryTime        = ''
    $script:OrdersFolder         = $OrdersFolder
    $script:StrategySignals      = [System.Collections.Generic.List[string]]::new()

    function script:Get-STR-TimeBucket {
        $now = Get-Date
        $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
        $bucket = [Math]::Floor($totalSeconds / $script:STR_IntervalSeconds) * $script:STR_IntervalSeconds
        $bH = [int][Math]::Floor($bucket / 3600)
        $bM = [int][Math]::Floor(($bucket % 3600) / 60)
        $bS = [int]($bucket % 60)
        return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
    }

    function script:Convert-ToHA([hashtable]$rawCandle, [hashtable]$previousHA) {
        $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
        if ($null -ne $previousHA) {
            $haOpen = ($previousHA.Open + $previousHA.Close) / 2.0
        } else {
            $haOpen = ($rawCandle.Open + $rawCandle.Close) / 2.0
        }
        $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
        $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
        return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
    }

    function script:Check-LongStrategy([int]$instrumentToken, [double]$lastPrice) {
        $completedList = $script:STR_CompletedCandles[$instrumentToken]
        if (-not $completedList -or $completedList.Count -lt 1) { return }

        # Previous completed HA candle
        $previousCandle = $completedList[$completedList.Count - 1]

        # Current live HA values
        $currentRaw = $script:STR_ActiveCandle[$instrumentToken]
        if ($null -eq $currentRaw) { return }
        $prevHA = $script:STR_PreviousHA[$instrumentToken]
        $liveHA = script:Convert-ToHA $currentRaw $prevHA

        $timeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

        # LONG ENTRY: current HA Close > previous HA High (and no open position)
        if ((-not $script:LongOrderPlaced) -and ($liveHA.Close -gt $previousCandle.High)) {
            $script:LongOrderPlaced = $true
            $script:LongEntryPrice  = $lastPrice
            $script:LongEntryTime   = $timeStamp

            $fileName = "Long-Entry-$($lastPrice.ToString('F2'))-$timeStamp.txt"
            $filePath = Join-Path $script:OrdersFolder $fileName
            $content  = "LONG ENTRY`nSymbol: $($script:STR_DisplayConfig.SymbolName)`nLTP: $lastPrice`nHA Close: $([Math]::Round($liveHA.Close,2))`nPrev HA High: $($previousCandle.High)`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Set-Content -Path $filePath -Value $content
            $script:StrategySignals.Add("ENTRY @ $lastPrice ($timeStamp)")
        }

        # LONG EXIT: current HA Close < previous HA Low (and position is open)
        if ($script:LongOrderPlaced -and ($liveHA.Close -lt $previousCandle.Low)) {
            $pnl = $lastPrice - $script:LongEntryPrice

            $fileName = "Long-Exit-$($lastPrice.ToString('F2'))-$timeStamp.txt"
            $filePath = Join-Path $script:OrdersFolder $fileName
            $content  = "LONG EXIT`nSymbol: $($script:STR_DisplayConfig.SymbolName)`nLTP: $lastPrice`nHA Close: $([Math]::Round($liveHA.Close,2))`nPrev HA Low: $($previousCandle.Low)`nEntry: $($script:LongEntryPrice) @ $($script:LongEntryTime)`nP&L: $([Math]::Round($pnl,2))`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Set-Content -Path $filePath -Value $content
            $script:StrategySignals.Add("EXIT  @ $lastPrice  P&L: $([Math]::Round($pnl,2)) ($timeStamp)")

            $script:LongOrderPlaced = $false
            $script:LongEntryPrice  = 0.0
            $script:LongEntryTime   = ''
        }
    }

    function script:Update-StrategyFromTick([int]$instrumentToken, [double]$lastPrice, [int]$volume, [double]$dayOpen, [double]$dayHigh, [double]$dayLow, [double]$dayClose, [int]$openInterest) {
        $script:STR_TickCount++
        $timeBucket = script:Get-STR-TimeBucket

        if (-not $script:STR_CompletedCandles.ContainsKey($instrumentToken)) {
            $script:STR_CompletedCandles[$instrumentToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        $currentCandle = $script:STR_ActiveCandle[$instrumentToken]

        if (($null -eq $currentCandle) -or ($currentCandle.TimeBucket -ne $timeBucket)) {
            if ($null -ne $currentCandle) {
                $prevHA = $script:STR_PreviousHA[$instrumentToken]
                $ha = script:Convert-ToHA $currentCandle $prevHA
                $closedHA = @{ Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close }
                $script:STR_PreviousHA[$instrumentToken] = $closedHA

                $script:STR_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                    TimeBucket=$currentCandle.TimeBucket
                    Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                    Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                    Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                    TicksInCandle=$currentCandle.TicksInCandle
                })
            }
            $script:STR_ActiveCandle[$instrumentToken] = @{
                TimeBucket=$timeBucket; Open=$lastPrice; High=$lastPrice; Low=$lastPrice; Close=$lastPrice
                Volume=0; PreviousVolume=$volume; OpenInterest=$openInterest; TicksInCandle=1
                DayOpen=$dayOpen; DayHigh=$dayHigh; DayLow=$dayLow; DayClose=$dayClose
            }
        } else {
            $currentCandle.High  = [Math]::Max($currentCandle.High, $lastPrice)
            $currentCandle.Low   = [Math]::Min($currentCandle.Low, $lastPrice)
            $currentCandle.Close = $lastPrice
            $currentCandle.OpenInterest = $openInterest
            $currentCandle.TicksInCandle++
            if ($dayHigh -gt 0)  { $currentCandle.DayHigh  = $dayHigh }
            if ($dayLow -gt 0)   { $currentCandle.DayLow   = $dayLow }
            if ($dayOpen -gt 0)  { $currentCandle.DayOpen  = $dayOpen }
            if ($dayClose -gt 0) { $currentCandle.DayClose = $dayClose }
            if (($volume -gt $currentCandle.PreviousVolume) -and ($currentCandle.PreviousVolume -gt 0)) {
                $currentCandle.Volume += ($volume - $currentCandle.PreviousVolume)
            }
            $currentCandle.PreviousVolume = $volume
        }

        # Check strategy signals on every tick
        script:Check-LongStrategy $instrumentToken $lastPrice
    }

    function script:Render-StrategyDisplay([int]$instrumentToken) {
        $now = [datetime]::Now
        if (($now - $script:STR_LastDisplayTime).TotalMilliseconds -lt $script:STR_DisplayIntervalMs) { return }
        $script:STR_LastDisplayTime = $now

        $config = $script:STR_DisplayConfig
        $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()

        $closedCandles = $script:STR_CompletedCandles[$instrumentToken]
        if ($closedCandles -and $closedCandles.Count -gt 0) { $allCandles.AddRange($closedCandles) }

        $currentCandle = $script:STR_ActiveCandle[$instrumentToken]
        if ($null -ne $currentCandle) {
            $prevHA = $script:STR_PreviousHA[$instrumentToken]
            $ha = script:Convert-ToHA $currentCandle $prevHA
            $allCandles.Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
            })
        }
        if ($allCandles.Count -eq 0) { return }

        $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
        $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

        $sb = [System.Text.StringBuilder]::new(2048)
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  $($config.SymbolLabel) - HA Long Strategy (WebSocket)")
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TimeFrame: $($config.TimeFrame)")
        $null = $sb.AppendLine("  Ticks   : $($script:STR_TickCount)")
        $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
        $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

        # Strategy status
        if ($script:LongOrderPlaced) {
            $null = $sb.AppendLine("  POSITION: LONG ACTIVE  Entry: $($script:LongEntryPrice.ToString('N2')) @ $($script:LongEntryTime)")
            if ($null -ne $currentCandle) {
                $unrealizedPnL = $currentCandle.Close - $script:LongEntryPrice
                $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized P&L: $($unrealizedPnL.ToString('N2'))")
            }
        } else {
            $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for Long Entry signal)")
            if ($null -ne $currentCandle) {
                $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
            }
        }

        $null = $sb.AppendLine('')
        $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,5} {7,6}'
        $null = $sb.AppendLine(($rowFormat -f 'Time','HA Open','HA High','HA Low','HA Close','Volume','Ticks','Trend'))
        $null = $sb.AppendLine(' ' + ('-' * 102))

        Clear-Host
        Write-Host $sb.ToString()

        for ($rowIndex = 0; $rowIndex -lt $visibleCandles.Count; $rowIndex++) {
            $candle = $visibleCandles[$rowIndex]
            $trend = if ($candle.Close -ge $candle.Open) { '  UP' } else { 'DOWN' }
            $color = if ($candle.Close -ge $candle.Open) { 'Green' } else { 'Red' }
            $line = $rowFormat -f $candle.TimeBucket, ('{0:N2}' -f $candle.Open), ('{0:N2}' -f $candle.High), ('{0:N2}' -f $candle.Low), ('{0:N2}' -f $candle.Close), ('{0:N0}' -f $candle.Volume), $candle.TicksInCandle, $trend
            if ($rowIndex -eq ($visibleCandles.Count - 1)) {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line -ForegroundColor $color
            }
        }

        # Show recent signals
        if ($script:StrategySignals.Count -gt 0) {
            Write-Host ''
            Write-Host '  --- Order Signals ---' -ForegroundColor Cyan
            $showCount = [Math]::Min(5, $script:StrategySignals.Count)
            for ($si = $script:StrategySignals.Count - $showCount; $si -lt $script:StrategySignals.Count; $si++) {
                $sigColor = if ($script:StrategySignals[$si] -match 'ENTRY') { 'Green' } else { 'Red' }
                Write-Host "    $($script:StrategySignals[$si])" -ForegroundColor $sigColor
            }
        }

        Write-Host ''
        Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
    }

    # --- WebSocket ---
    $wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
    $modeStr = if ($FullMode) { 'full' } else { 'quote' }

    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host '  Zerodha HA Long Strategy - Live' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host "  Symbol   : $label ($sym)"
    Write-Host "  Token    : $instToken"
    Write-Host "  TimeFrame: $TimeFrame ($intLabel candles)"
    Write-Host "  Mode     : $modeStr"
    Write-Host "  Orders   : $OrdersFolder"
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
                    foreach ($tick in $ticks) {
                        if ($tick.LastPrice -gt 0) {
                            script:Update-StrategyFromTick $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest
                        }
                    }
                    script:Render-StrategyDisplay $instToken
                }
            }

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
    Write-Host "  Signals: $($script:StrategySignals.Count) total" -ForegroundColor Gray
    foreach ($sig in $script:StrategySignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
    Write-Host ''
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Invoke-KiteHAShortStrategy
# Heikin-Ashi Short-only strategy with order file logging
# Entry: current HA Close < previous HA Low
# Exit:  current HA Close > previous HA High
# ══════════════════════════════════════════════════════════════
function Invoke-KiteHAShortStrategy {
    param(
        [string]$TradingSymbol  = 'NIFTY',
        [int]$InstrumentToken,
        [ValidateSet('5second','15second','30second','minute','3minute','5minute','10minute','15minute','30minute','60minute')]
        [string]$TimeFrame      = '5minute',
        [int]$CandlesToShow     = 10,
        [switch]$FullMode,
        [switch]$ListSymbols,
        [string]$AccessToken,
        [string]$API_Key        = '0fvxhlacu555dhp0',
        [string]$OrdersFolder
    )

    if ($ListSymbols) { Show-KiteSymbols; return }

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

    $intSec   = Get-IntervalSeconds $TimeFrame
    $intMin   = Get-IntervalMinutes $TimeFrame
    $intLabel = Get-IntervalLabel $intSec

    if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; return }

    # --- Ensure PlacedOrders folder exists ---
    if (-not $OrdersFolder) { $OrdersFolder = Join-Path (Split-Path $MyInvocation.ScriptName -Parent) 'PlacedOrders' }
    if (-not (Test-Path $OrdersFolder)) { New-Item -ItemType Directory -Path $OrdersFolder -Force | Out-Null }

    # --- HA + Strategy state ---
    $script:SHR_CompletedCandles = @{}
    $script:SHR_ActiveCandle     = @{}
    $script:SHR_PreviousHA       = @{}
    $script:SHR_TickCount        = 0
    $script:SHR_IntervalSeconds  = $intSec
    $script:SHR_DisplayConfig    = @{
        SymbolName=$sym; SymbolLabel=$label; InstrumentToken=$instToken
        TimeFrame=$TimeFrame; IntervalLabel=$intLabel; MaxCandles=$CandlesToShow
    }
    $script:SHR_LastDisplayTime   = [datetime]::MinValue
    $script:SHR_DisplayIntervalMs = 250

    # Strategy state
    $script:ShortOrderPlaced     = $false
    $script:ShortEntryPrice      = 0.0
    $script:ShortEntryTime       = ''
    $script:ShortOrdersFolder    = $OrdersFolder
    $script:ShortSignals         = [System.Collections.Generic.List[string]]::new()

    function script:Get-SHR-TimeBucket {
        $now = Get-Date
        $totalSeconds = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
        $bucket = [Math]::Floor($totalSeconds / $script:SHR_IntervalSeconds) * $script:SHR_IntervalSeconds
        $bH = [int][Math]::Floor($bucket / 3600)
        $bM = [int][Math]::Floor(($bucket % 3600) / 60)
        $bS = [int]($bucket % 60)
        return $now.ToString('yyyy-MM-dd ') + ('{0:D2}:{1:D2}:{2:D2}' -f $bH, $bM, $bS)
    }

    function script:Convert-ToHA-Short([hashtable]$rawCandle, [hashtable]$previousHA) {
        $haClose = ($rawCandle.Open + $rawCandle.High + $rawCandle.Low + $rawCandle.Close) / 4.0
        if ($null -ne $previousHA) {
            $haOpen = ($previousHA.Open + $previousHA.Close) / 2.0
        } else {
            $haOpen = ($rawCandle.Open + $rawCandle.Close) / 2.0
        }
        $haHigh = [Math]::Max($rawCandle.High, [Math]::Max($haOpen, $haClose))
        $haLow  = [Math]::Min($rawCandle.Low,  [Math]::Min($haOpen, $haClose))
        return @{ Open=$haOpen; High=$haHigh; Low=$haLow; Close=$haClose }
    }

    function script:Check-ShortStrategy([int]$instrumentToken, [double]$lastPrice) {
        $completedList = $script:SHR_CompletedCandles[$instrumentToken]
        if (-not $completedList -or $completedList.Count -lt 1) { return }

        $previousCandle = $completedList[$completedList.Count - 1]

        $currentRaw = $script:SHR_ActiveCandle[$instrumentToken]
        if ($null -eq $currentRaw) { return }
        $prevHA = $script:SHR_PreviousHA[$instrumentToken]
        $liveHA = script:Convert-ToHA-Short $currentRaw $prevHA

        $timeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

        # SHORT ENTRY: current HA Close < previous HA Low (and no open position)
        if ((-not $script:ShortOrderPlaced) -and ($liveHA.Close -lt $previousCandle.Low)) {
            $script:ShortOrderPlaced = $true
            $script:ShortEntryPrice  = $lastPrice
            $script:ShortEntryTime   = $timeStamp

            $fileName = "Short-Entry-$($lastPrice.ToString('F2'))-$timeStamp.txt"
            $filePath = Join-Path $script:ShortOrdersFolder $fileName
            $content  = "SHORT ENTRY`nSymbol: $($script:SHR_DisplayConfig.SymbolName)`nLTP: $lastPrice`nHA Close: $([Math]::Round($liveHA.Close,2))`nPrev HA Low: $($previousCandle.Low)`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Set-Content -Path $filePath -Value $content
            $script:ShortSignals.Add("ENTRY @ $lastPrice ($timeStamp)")
        }

        # SHORT EXIT: current HA Close > previous HA High (and position is open)
        if ($script:ShortOrderPlaced -and ($liveHA.Close -gt $previousCandle.High)) {
            $pnl = $script:ShortEntryPrice - $lastPrice

            $fileName = "Short-Exit-$($lastPrice.ToString('F2'))-$timeStamp.txt"
            $filePath = Join-Path $script:ShortOrdersFolder $fileName
            $content  = "SHORT EXIT`nSymbol: $($script:SHR_DisplayConfig.SymbolName)`nLTP: $lastPrice`nHA Close: $([Math]::Round($liveHA.Close,2))`nPrev HA High: $($previousCandle.High)`nEntry: $($script:ShortEntryPrice) @ $($script:ShortEntryTime)`nP&L: $([Math]::Round($pnl,2))`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Set-Content -Path $filePath -Value $content
            $script:ShortSignals.Add("EXIT  @ $lastPrice  P&L: $([Math]::Round($pnl,2)) ($timeStamp)")

            $script:ShortOrderPlaced = $false
            $script:ShortEntryPrice  = 0.0
            $script:ShortEntryTime   = ''
        }
    }

    function script:Update-ShortStrategyFromTick([int]$instrumentToken, [double]$lastPrice, [int]$volume, [double]$dayOpen, [double]$dayHigh, [double]$dayLow, [double]$dayClose, [int]$openInterest) {
        $script:SHR_TickCount++
        $timeBucket = script:Get-SHR-TimeBucket

        if (-not $script:SHR_CompletedCandles.ContainsKey($instrumentToken)) {
            $script:SHR_CompletedCandles[$instrumentToken] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        $currentCandle = $script:SHR_ActiveCandle[$instrumentToken]

        if (($null -eq $currentCandle) -or ($currentCandle.TimeBucket -ne $timeBucket)) {
            if ($null -ne $currentCandle) {
                $prevHA = $script:SHR_PreviousHA[$instrumentToken]
                $ha = script:Convert-ToHA-Short $currentCandle $prevHA
                $closedHA = @{ Open=$ha.Open; High=$ha.High; Low=$ha.Low; Close=$ha.Close }
                $script:SHR_PreviousHA[$instrumentToken] = $closedHA

                $script:SHR_CompletedCandles[$instrumentToken].Add([PSCustomObject]@{
                    TimeBucket=$currentCandle.TimeBucket
                    Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                    Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                    Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                    TicksInCandle=$currentCandle.TicksInCandle
                })
            }
            $script:SHR_ActiveCandle[$instrumentToken] = @{
                TimeBucket=$timeBucket; Open=$lastPrice; High=$lastPrice; Low=$lastPrice; Close=$lastPrice
                Volume=0; PreviousVolume=$volume; OpenInterest=$openInterest; TicksInCandle=1
                DayOpen=$dayOpen; DayHigh=$dayHigh; DayLow=$dayLow; DayClose=$dayClose
            }
        } else {
            $currentCandle.High  = [Math]::Max($currentCandle.High, $lastPrice)
            $currentCandle.Low   = [Math]::Min($currentCandle.Low, $lastPrice)
            $currentCandle.Close = $lastPrice
            $currentCandle.OpenInterest = $openInterest
            $currentCandle.TicksInCandle++
            if ($dayHigh -gt 0)  { $currentCandle.DayHigh  = $dayHigh }
            if ($dayLow -gt 0)   { $currentCandle.DayLow   = $dayLow }
            if ($dayOpen -gt 0)  { $currentCandle.DayOpen  = $dayOpen }
            if ($dayClose -gt 0) { $currentCandle.DayClose = $dayClose }
            if (($volume -gt $currentCandle.PreviousVolume) -and ($currentCandle.PreviousVolume -gt 0)) {
                $currentCandle.Volume += ($volume - $currentCandle.PreviousVolume)
            }
            $currentCandle.PreviousVolume = $volume
        }

        script:Check-ShortStrategy $instrumentToken $lastPrice
    }

    function script:Render-ShortStrategyDisplay([int]$instrumentToken) {
        $now = [datetime]::Now
        if (($now - $script:SHR_LastDisplayTime).TotalMilliseconds -lt $script:SHR_DisplayIntervalMs) { return }
        $script:SHR_LastDisplayTime = $now

        $config = $script:SHR_DisplayConfig
        $allCandles = [System.Collections.Generic.List[PSCustomObject]]::new()

        $closedCandles = $script:SHR_CompletedCandles[$instrumentToken]
        if ($closedCandles -and $closedCandles.Count -gt 0) { $allCandles.AddRange($closedCandles) }

        $currentCandle = $script:SHR_ActiveCandle[$instrumentToken]
        if ($null -ne $currentCandle) {
            $prevHA = $script:SHR_PreviousHA[$instrumentToken]
            $ha = script:Convert-ToHA-Short $currentCandle $prevHA
            $allCandles.Add([PSCustomObject]@{
                TimeBucket=$currentCandle.TimeBucket
                Open=[Math]::Round($ha.Open, 2); High=[Math]::Round($ha.High, 2)
                Low=[Math]::Round($ha.Low, 2); Close=[Math]::Round($ha.Close, 2)
                Volume=$currentCandle.Volume; OpenInterest=$currentCandle.OpenInterest
                TicksInCandle=$currentCandle.TicksInCandle
            })
        }
        if ($allCandles.Count -eq 0) { return }

        $skipCount = [Math]::Max(0, $allCandles.Count - $config.MaxCandles)
        $visibleCandles = if ($skipCount -gt 0) { $allCandles.GetRange($skipCount, $allCandles.Count - $skipCount) } else { $allCandles }

        $sb = [System.Text.StringBuilder]::new(2048)
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  $($config.SymbolLabel) - HA Short Strategy (WebSocket)")
        $null = $sb.AppendLine("  ================================================")
        $null = $sb.AppendLine("  Symbol  : $($config.SymbolName)  |  Token: $($config.InstrumentToken)  |  TimeFrame: $($config.TimeFrame)")
        $null = $sb.AppendLine("  Ticks   : $($script:SHR_TickCount)")
        $null = $sb.AppendLine("  Candles : $($allCandles.Count) total | Showing $($visibleCandles.Count)")
        $null = $sb.AppendLine("  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

        if ($script:ShortOrderPlaced) {
            $null = $sb.AppendLine("  POSITION: SHORT ACTIVE  Entry: $($script:ShortEntryPrice.ToString('N2')) @ $($script:ShortEntryTime)")
            if ($null -ne $currentCandle) {
                $unrealizedPnL = $script:ShortEntryPrice - $currentCandle.Close
                $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Unrealized P&L: $($unrealizedPnL.ToString('N2'))")
            }
        } else {
            $null = $sb.AppendLine("  POSITION: FLAT  (Waiting for Short Entry signal)")
            if ($null -ne $currentCandle) {
                $null = $sb.AppendLine("  LTP     : $($currentCandle.Close.ToString('N2'))  |  Day O/H/L/C: $($currentCandle.DayOpen.ToString('N2'))/$($currentCandle.DayHigh.ToString('N2'))/$($currentCandle.DayLow.ToString('N2'))/$($currentCandle.DayClose.ToString('N2'))")
            }
        }

        $null = $sb.AppendLine('')
        $rowFormat = ' {0,-18} {1,14} {2,14} {3,14} {4,14} {5,10} {6,5} {7,6}'
        $null = $sb.AppendLine(($rowFormat -f 'Time','HA Open','HA High','HA Low','HA Close','Volume','Ticks','Trend'))
        $null = $sb.AppendLine(' ' + ('-' * 102))

        Clear-Host
        Write-Host $sb.ToString()

        for ($rowIndex = 0; $rowIndex -lt $visibleCandles.Count; $rowIndex++) {
            $candle = $visibleCandles[$rowIndex]
            $trend = if ($candle.Close -ge $candle.Open) { '  UP' } else { 'DOWN' }
            $color = if ($candle.Close -ge $candle.Open) { 'Green' } else { 'Red' }
            $line = $rowFormat -f $candle.TimeBucket, ('{0:N2}' -f $candle.Open), ('{0:N2}' -f $candle.High), ('{0:N2}' -f $candle.Low), ('{0:N2}' -f $candle.Close), ('{0:N0}' -f $candle.Volume), $candle.TicksInCandle, $trend
            if ($rowIndex -eq ($visibleCandles.Count - 1)) {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line -ForegroundColor $color
            }
        }

        if ($script:ShortSignals.Count -gt 0) {
            Write-Host ''
            Write-Host '  --- Order Signals ---' -ForegroundColor Cyan
            $showCount = [Math]::Min(5, $script:ShortSignals.Count)
            for ($si = $script:ShortSignals.Count - $showCount; $si -lt $script:ShortSignals.Count; $si++) {
                $sigColor = if ($script:ShortSignals[$si] -match 'ENTRY') { 'Magenta' } else { 'Cyan' }
                Write-Host "    $($script:ShortSignals[$si])" -ForegroundColor $sigColor
            }
        }

        Write-Host ''
        Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
    }

    # --- WebSocket ---
    $wsUri = "wss://ws.kite.trade?api_key=$API_Key" + "&access_token=$AccessToken"
    $modeStr = if ($FullMode) { 'full' } else { 'quote' }

    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host '  Zerodha HA Short Strategy - Live' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor Cyan
    Write-Host "  Symbol   : $label ($sym)"
    Write-Host "  Token    : $instToken"
    Write-Host "  TimeFrame: $TimeFrame ($intLabel candles)"
    Write-Host "  Mode     : $modeStr"
    Write-Host "  Orders   : $OrdersFolder"
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
                    foreach ($tick in $ticks) {
                        if ($tick.LastPrice -gt 0) {
                            script:Update-ShortStrategyFromTick $tick.InstrumentToken $tick.LastPrice $tick.Volume $tick.DayOpen $tick.DayHigh $tick.DayLow $tick.DayClose $tick.OpenInterest
                        }
                    }
                    script:Render-ShortStrategyDisplay $instToken
                }
            }

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
    Write-Host "  Signals: $($script:ShortSignals.Count) total" -ForegroundColor Gray
    foreach ($sig in $script:ShortSignals) { Write-Host "    $sig" -ForegroundColor DarkGray }
    Write-Host ''
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Place-ZerodhaOrder
# Places BUY/SELL orders with Market Protection Price (MPP) support
# ══════════════════════════════════════════════════════════════
<#
.SYNOPSIS
Places a BUY or SELL order on Zerodha Kite API with Market Protection Price (MPP).

.DESCRIPTION
Supports multiple order types (LIMIT, MARKET, SL, SL-M) with Market Protection Price for MARKET orders.

Market Protection Price (MPP) for MARKET orders:
- SELL MARKET with MPP: Price = minimum acceptable sell price (won't sell below this)
- BUY MARKET with MPP: Price = maximum acceptable buy price (won't buy above this)

.EXAMPLE
# SELL MARKET with 1% price protection (376.75 as minimum)
Place-ZerodhaOrder -AccessToken $token -CommonHeader $headers `
  -Type SELL -Variety regular -Tradingsymbol "NIFTY24MAY25000CE" `
  -Quantity 1500 -OrderType MARKET -Product NRML `
  -Exchange NFO -Validity DAY -Price 376.75 -Tag "MPP-SELL"

.EXAMPLE
# BUY LIMIT order
Place-ZerodhaOrder -AccessToken $token -CommonHeader $headers `
  -Type BUY -Variety regular -Tradingsymbol "NIFTY50" `
  -Quantity 1 -OrderType LIMIT -Product NRML `
  -Exchange NSE -Validity DAY -Price 24000 -Tag "LIMIT-BUY"
#>
function Place-ZerodhaOrder {
    param(
        [string]$AccessToken,
        [hashtable]$CommonHeader,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("BUY", "SELL")]
        [string]$Type,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("regular", "amo", "co")]
        [string]$Variety,
        
        [Parameter(Mandatory=$true)]
        [string]$Tradingsymbol,
        
        [Parameter(Mandatory=$true)]
        [int]$Quantity,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("LIMIT", "MARKET", "SL", "SL-M")]
        [string]$OrderType,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("MIS", "CNC", "NRML")]
        [string]$Product,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("NFO", "BFO", "NSE", "BSE", "MCX")]
        [string]$Exchange,
        
        [ValidateSet("DAY", "IOC")]
        [string]$Validity = "DAY",
        
        [double]$Price = 0,
        [double]$TriggerPrice = 0,
        [ValidateRange(0, 100)]
        [int]$MarketProtection = 3,
        [string]$Tag = ""
    )

    Write-Host "  Order Details | Type: $Type | Symbol: $Tradingsymbol | Qty: $Quantity | OrderType: $OrderType | Price: $Price | Trigger: $TriggerPrice | MktProtection: ${MarketProtection}%" -ForegroundColor Cyan

    try {
        $ErrorActionPreference = "Stop"
        
        # Build order body - ALL required fields for Zerodha API
        $Body = @{
            'tradingsymbol'    = $Tradingsymbol
            'exchange'         = $Exchange
            'transaction_type' = $Type
            'order_type'       = $OrderType
            'quantity'         = [string]$Quantity
            'product'          = $Product
            'validity'         = $Validity
        }
        
        # Add tag if provided
        if ($Tag) { $Body['tag'] = $Tag }

        # Handle different order types
        switch ($OrderType) {
            "MARKET" {
                # MARKET orders use market_protection percentage (0-100) to limit price deviation
                # See: https://kite.trade/docs/connect/v3/orders/#market-protection
                if ($MarketProtection -gt 0) {
                    $Body['market_protection'] = [string]$MarketProtection
                    Write-Host "  ✓ MARKET order with ${MarketProtection}% market protection" -ForegroundColor Green
                } else {
                    Write-Host "  ✓ MARKET order (no market protection)" -ForegroundColor Green
                }
            }
            "LIMIT" {
                # LIMIT orders require price
                if ($Price -le 0) {
                    throw "LIMIT order requires valid Price parameter"
                }
                $Body['price'] = [string]$Price
                Write-Host "  ✓ LIMIT order with price $Price" -ForegroundColor Green
            }
            "SL" {
                # Stop Loss requires trigger_price and optional price
                if ($TriggerPrice -le 0) {
                    throw "SL order requires valid TriggerPrice parameter"
                }
                $Body['trigger_price'] = [string]$TriggerPrice
                
                # For SL, if price is provided use it (execution limit), else Zerodha uses trigger price
                if ($Price -gt 0) {
                    $Body['price'] = [string]$Price
                    Write-Host "  ✓ SL order: trigger=$TriggerPrice, limit=$Price" -ForegroundColor Green
                } else {
                    Write-Host "  ✓ SL order: trigger=$TriggerPrice" -ForegroundColor Green
                }
            }
            "SL-M" {
                # Stop Loss Market requires trigger_price and market_protection
                if ($TriggerPrice -le 0) {
                    throw "SL-M order requires valid TriggerPrice parameter"
                }
                $Body['trigger_price'] = [string]$TriggerPrice
                if ($MarketProtection -gt 0) {
                    $Body['market_protection'] = [string]$MarketProtection
                }
                Write-Host "  ✓ SL-M order: trigger=$TriggerPrice, market_protection=${MarketProtection}%" -ForegroundColor Green
            }
        }

        # Build API URL
        $url = "https://api.kite.trade/orders/$Variety"
        
        Write-Host "  POST $url" -ForegroundColor DarkGray
        Write-Host "  Body: $($Body | ConvertTo-Json)" -ForegroundColor DarkGray

        # Place order via Kite API
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $CommonHeader -Body $Body -ErrorAction Stop
        
        # Check response
        if ($response.status -eq "success" -and $response.data.order_id) {
            $orderId = $response.data.order_id
            Write-Host "  ✅ Order placed successfully!" -ForegroundColor Green
            Write-Host "     Order ID: $orderId" -ForegroundColor Green
            Write-Host "     Type: $Type | Symbol: $Tradingsymbol | Qty: $Quantity" -ForegroundColor Green
            return $response.data
        } else {
            $errorMsg = $response.message ?? "Unknown error"
            throw "API returned: $errorMsg"
        }
    }
    catch {
        Write-Host "  ❌ Error placing order: $_" -ForegroundColor Red
        if ($_.Exception.Response) {
            try {
                $errorContent = $_.Exception.Response.Content.ReadAsStringAsync().Result
                $errorJson = ConvertFrom-Json $errorContent
                Write-Host "  API Error: $($errorJson.message)" -ForegroundColor Red
                if ($errorJson.error_type) {
                    Write-Host "  Error Type: $($errorJson.error_type)" -ForegroundColor Red
                }
            } catch {}
        }
        return $null
    }
}

# ── Option Trading Helper Functions ─────────────────────────

function Get-IndexOptionConfig {
    <#
    .SYNOPSIS
      Returns index configuration for option trading.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
        [string]$IndexName,
        [int]$NoOfLots = 1
    )

    $IndexConfigs = @{
        'NIFTY' = @{
            tradingsymbol    = 'NIFTY 50'
            instrument_token = '256265'
            SpotQuoteKey     = 'NSE:NIFTY 50'
            SearchKeyWord    = 'NIFTY'
            Lot              = 65
            exchange         = 'NFO'
            Segment          = 'NFO-OPT'
            SpotExchange     = 'NSE'
            OptExchange      = 'NFO'
        }
        'BANKNIFTY' = @{
            tradingsymbol    = 'NIFTY BANK'
            instrument_token = '260105'
            SpotQuoteKey     = 'NSE:NIFTY BANK'
            SearchKeyWord    = 'BANKNIFTY'
            Lot              = 15
            exchange         = 'NFO'
            Segment          = 'NFO-OPT'
            SpotExchange     = 'NSE'
            OptExchange      = 'NFO'
        }
        'FinNifty' = @{
            tradingsymbol    = 'NIFTY FIN SERVICE'
            instrument_token = '257801'
            SpotQuoteKey     = 'NSE:NIFTY FIN SERVICE'
            SearchKeyWord    = 'FINNIFTY'
            Lot              = 40
            exchange         = 'NFO'
            Segment          = 'NFO-OPT'
            SpotExchange     = 'NSE'
            OptExchange      = 'NFO'
        }
        'MIDCPNIFTY' = @{
            tradingsymbol    = 'NIFTY MID SELECT'
            instrument_token = '288009'
            SpotQuoteKey     = 'NSE:NIFTY MID SELECT'
            SearchKeyWord    = 'MIDCPNIFTY'
            Lot              = 75
            exchange         = 'NFO'
            Segment          = 'NFO-OPT'
            SpotExchange     = 'NSE'
            OptExchange      = 'NFO'
        }
        'SENSEX' = @{
            tradingsymbol    = 'SENSEX'
            instrument_token = '265'
            SpotQuoteKey     = 'BSE:SENSEX'
            SearchKeyWord    = 'SENSEX'
            Lot              = 20
            exchange         = 'BFO'
            Segment          = 'BFO-OPT'
            SpotExchange     = 'BSE'
            OptExchange      = 'BFO'
        }
    }

    if (-not $IndexConfigs.ContainsKey($IndexName)) {
        Write-Error "Unknown Index: $IndexName. Supported: NIFTY, BANKNIFTY, FinNifty, MIDCPNIFTY, SENSEX"
        return $null
    }

    $config = $IndexConfigs[$IndexName]
    $config.Quantity = $config.Lot * $NoOfLots
    return $config
}

function Get-KiteSpotPrice {
    <#
    .SYNOPSIS
      Fetches current spot/LTP price for an index using EXCHANGE:TRADINGSYMBOL format.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$SpotQuoteKey,
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers
    )
    try {
        $encodedKey = [System.Uri]::EscapeDataString($SpotQuoteKey)
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/quote/ltp?i=$encodedKey" -Headers $Headers -Method Get -ErrorAction Stop
        foreach ($prop in $resp.data.PSObject.Properties) {
            if ($prop.Value.last_price -gt 0) { return $prop.Value.last_price }
        }
    } catch {}
    return 0
}

function Get-KiteOptionInstruments {
    <#
    .SYNOPSIS
      Fetches and parses option instruments for a given index, filtered by type and nearest expiry.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$OptExchange,
        [Parameter(Mandatory=$true)]
        [string]$UnderlyingName,
        [Parameter(Mandatory=$true)]
        [ValidateSet('CE','PE')]
        [string]$OptionType,
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers
    )

    try {
        $resp = Invoke-WebRequest -Uri "https://api.kite.trade/instruments/$OptExchange" -Headers $Headers -Method Get -ErrorAction Stop
    } catch {
        Write-Host "  Failed to fetch instruments: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $lines = ($resp.Content -split "`n") | Select-Object -Skip 1 | Where-Object { $_.Length -gt 10 }

    $options = foreach ($line in $lines) {
        $cols = $line -split ','
        if ($cols.Count -ge 12) {
            $name = ($cols[3] -replace '"','').Trim()
            $instType = ($cols[9] -replace '"','').Trim()
            if (($name -eq $UnderlyingName) -and ($instType -eq $OptionType)) {
                [PSCustomObject]@{
                    Token   = [long]$cols[0]
                    Symbol  = ($cols[2] -replace '"','').Trim()
                    Name    = $name
                    Expiry  = ($cols[5] -replace '"','').Trim()
                    Strike  = [double]$cols[6]
                    LotSize = [int]$cols[8]
                    Type    = $instType
                }
            }
        }
    }

    if (-not $options -or @($options).Count -eq 0) {
        Write-Host "  No $OptionType options found for '$UnderlyingName'." -ForegroundColor Red
        return $null
    }

    # Pick nearest expiry
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $allExpiries = @($options | Select-Object -ExpandProperty Expiry -Unique | Sort-Object)
    $nearestExpiry = $allExpiries | Where-Object { $_ -ge $today } | Select-Object -First 1

    if (-not $nearestExpiry) {
        Write-Host "  No valid expiry found." -ForegroundColor Red
        return $null
    }

    $filtered = @($options | Where-Object { $_.Expiry -eq $nearestExpiry })
    $strikes = @($filtered | Select-Object -ExpandProperty Strike -Unique | Sort-Object)

    return @{
        Options = $filtered
        Strikes = $strikes
        Expiry  = $nearestExpiry
    }
}

function Get-ATMOption {
    <#
    .SYNOPSIS
      Finds the ATM option closest to spot price, with optional strike offset.
      Offset 0 = ATM, 1 = 1 strike OTM, -1 = 1 strike ITM, etc.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [double]$SpotPrice,
        [Parameter(Mandatory=$true)]
        [array]$Options,
        [Parameter(Mandatory=$true)]
        [array]$AllStrikes,
        [int]$Offset = 0
    )
    $sorted = $AllStrikes | Sort-Object
    $atmStrike = $sorted | Sort-Object { [Math]::Abs($_ - $SpotPrice) } | Select-Object -First 1
    $atmIndex = [array]::IndexOf($sorted, $atmStrike)
    $targetIndex = $atmIndex + $Offset
    if ($targetIndex -lt 0) { $targetIndex = 0 }
    if ($targetIndex -ge $sorted.Count) { $targetIndex = $sorted.Count - 1 }
    $targetStrike = $sorted[$targetIndex]
    return ($Options | Where-Object { $_.Strike -eq $targetStrike } | Select-Object -First 1)
}

# ══════════════════════════════════════════════════════════════
# FUNCTION: Get-KiteOpenPositions
# Fetches all open (net qty != 0) positions from Kite API.
# Also fetches live LTP for each open position to compute
# real-time P&L that updates continuously.
# ══════════════════════════════════════════════════════════════
function Get-KiteOpenPositions {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers
    )

    try {
        $resp = Invoke-RestMethod -Uri "https://api.kite.trade/portfolio/positions" -Headers $Headers -Method Get -ErrorAction Stop

        $dayPositions = $resp.data.day
        if (-not $dayPositions -or $dayPositions.Count -eq 0) {
            return @{ Positions = @(); DisplayLines = @("  POSITIONS: None today  |  $(Get-Date -Format 'HH:mm:ss')"); TotalPnL = 0.0 }
        }

        # Collect open positions
        $openPositions = @()
        $closedPnL = 0.0

        foreach ($pos in $dayPositions) {
            $qty = [int]$pos.quantity
            if ($qty -eq 0) {
                $closedPnL += [double]$pos.pnl
                continue
            }

            $openPositions += @{
                Symbol   = $pos.tradingsymbol
                Exchange = $pos.exchange
                Qty      = $qty
                BuyAvg   = [double]$pos.average_price
                SellAvg  = [double]$pos.sell_price
                Product  = $pos.product
                Side     = if ($qty -gt 0) { 'LONG' } else { 'SHORT' }
                Multiplier = [double]$pos.multiplier
            }
        }

        if ($openPositions.Count -eq 0) {
            $totalStr = $closedPnL.ToString('N2')
            return @{ Positions = @(); DisplayLines = @("  POSITIONS: All closed  |  Day P&L: $totalStr  |  $(Get-Date -Format 'HH:mm:ss')"); TotalPnL = $closedPnL }
        }

        # Fetch live LTP for all open positions in one API call
        $ltpMap = @{}
        try {
            $queryParts = @()
            foreach ($p in $openPositions) {
                $queryParts += "i=$([System.Uri]::EscapeDataString("$($p.Exchange):$($p.Symbol)"))"
            }
            $ltpUrl = "https://api.kite.trade/quote/ltp?" + ($queryParts -join '&')
            $ltpResp = Invoke-RestMethod -Uri $ltpUrl -Headers $Headers -Method Get -ErrorAction Stop
            if ($ltpResp.data) {
                foreach ($key in $ltpResp.data.PSObject.Properties) {
                    $ltpMap[$key.Name] = [double]$key.Value.last_price
                }
            }
        } catch {}

        # Build position details with live P&L
        $results = @()
        $totalPnL = $closedPnL

        foreach ($p in $openPositions) {
            $ltpKey = "$($p.Exchange):$($p.Symbol)"
            $ltp = if ($ltpMap.ContainsKey($ltpKey)) { $ltpMap[$ltpKey] } else { 0.0 }

            # Calculate real-time P&L
            if ($p.Qty -gt 0) {
                $unrealized = ($ltp - $p.BuyAvg) * $p.Qty * $p.Multiplier
            } else {
                $unrealized = ($p.SellAvg - $ltp) * [Math]::Abs($p.Qty) * $p.Multiplier
            }
            $totalPnL += $unrealized

            $results += [PSCustomObject]@{
                Symbol     = $p.Symbol
                Exchange   = $p.Exchange
                Qty        = $p.Qty
                BuyAvg     = $p.BuyAvg
                LTP        = $ltp
                PnL        = $unrealized
                Product    = $p.Product
                Side       = $p.Side
            }
        }

        # Build display lines
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("  ── Open Positions ($($results.Count)) ─────────────────────────────── $(Get-Date -Format 'HH:mm:ss')")
        $fmt = '  {0,-26} {1,5} {2,6} {3,10} {4,10} {5,12}'
        $lines.Add(($fmt -f 'Symbol', 'Side', 'Qty', 'Avg', 'LTP', 'P&L'))

        foreach ($r in $results) {
            $pnlStr = $r.PnL.ToString('N2')
            $line = $fmt -f $r.Symbol, $r.Side, $r.Qty, $r.BuyAvg.ToString('N2'), $r.LTP.ToString('N2'), $pnlStr
            $lines.Add($line)
        }

        $lines.Add(("  Total P&L: " + $totalPnL.ToString('N2') + "  (closed: " + $closedPnL.ToString('N2') + ")"))
        $lines.Add("  ─────────────────────────────────────────────────────────────────")

        return @{ Positions = $results; DisplayLines = $lines.ToArray(); TotalPnL = $totalPnL }
    }
    catch {
        return @{ Positions = @(); DisplayLines = @("  POSITIONS: Error - $($_.Exception.Message)"); TotalPnL = 0.0 }
    }
}

# ── REST API: Fetch historical candle data ─────────────────
function Get-ZerodhaCandleData {
    param(
        $tradingsymbol,
        $instrument_token,
        [string]$TimeFrame = "1",
        $FromDate,
        $TODate,
        [int]$LastNCandles = 20
    )

    $interval = switch($TimeFrame){ "day"{"day"} "1"{"minute"} default{"${TimeFrame}minute"} }
    $now = Get-Date
    $fmt = 'yyyy-MM-dd+HH:mm:ss'
    $to = if($TODate){ Get-Date $TODate -Format $fmt } else { Get-Date $now -Format $fmt }
    if($FromDate){ $from = Get-Date $FromDate -Format $fmt }
    else{
        $mins = if($interval -eq "day"){ ($LastNCandles+5)*1440 } else { [Math]::Max(($LastNCandles+10)*($(if($TimeFrame -eq "1"){1}else{[int]$TimeFrame})), 1440) }
        $from = Get-Date $now.AddMinutes(-$mins) -Format $fmt
    }

    $candles = $null
    for($i=0; $i -lt 3; $i++){
        try{
            $candles = (Invoke-RestMethod "https://api.kite.trade/instruments/historical/$instrument_token/${interval}?from=$from&to=$to" -Headers $Global:common_header -Method Get -ErrorAction Stop).data.candles
            break
        }catch{ Start-Sleep -Seconds 1 }
    }
    if(-not $candles){ return $null }

    if($candles.Count -gt $LastNCandles){ $candles = $candles[-$LastNCandles..-1] }

    $out = foreach($c in $candles){
        [PSCustomObject]@{ timestamp=$c[0]; open=[double]$c[1]; high=[double]$c[2]; low=[double]$c[3]; close=[double]$c[4]; volume=[long]$c[5] }
    }
    return $out
}

# ── REST API: Fetch Heikin-Ashi candle data ────────────────
function Get-HeikinAshiCandlesData {
    param(
        $tradingsymbol,
        $instrument_token,
        $TimeFrame = "1",
        $FromDate,
        $TODate,
        [int]$LastNCandles = 20
    )

    $interval = switch($TimeFrame){ "day"{"day"} "1"{"minute"} default{"${TimeFrame}minute"} }
    $now = Get-Date
    $fmt = 'yyyy-MM-dd+HH:mm:ss'
    $to = if($TODate){ Get-Date $TODate -Format $fmt } else { Get-Date $now -Format $fmt }
    if($FromDate){ $from = Get-Date $FromDate -Format $fmt }
    else{
        $need = $LastNCandles + 10
        $mins = if($interval -eq "day"){ $need*1440 } else { [Math]::Max($need*($(if($TimeFrame -eq "1"){1}else{[int]$TimeFrame})), 1440) }
        $from = Get-Date $now.AddMinutes(-$mins) -Format $fmt
    }

    $candles = $null
    for($i=0; $i -lt 3; $i++){
        try{
            $candles = (Invoke-RestMethod "https://api.kite.trade/instruments/historical/$instrument_token/${interval}?from=$from&to=$to" -Headers $Global:common_header -Method Get -ErrorAction Stop).data.candles
            break
        }catch{ Start-Sleep -Seconds 1 }
    }
    if(-not $candles -or $candles.Count -eq 0){ return $null }

    $HACandlesData = @()
    foreach($c in $candles){
        [double]$o=$c[1]; [double]$h=$c[2]; [double]$l=$c[3]; [double]$cl=$c[4]
        $prev = $HACandlesData[-1]
        if($HACandlesData.Count -eq 0){
            $haO=$o; $haH=$h; $haL=$l; $haC=$cl
        } else {
            $haC = ($o+$h+$l+$cl)/4
            $haO = ($prev.Open+$prev.Close)/2
            $haH = [Math]::Max($h, [Math]::Max($haO,$haC))
            $haL = [Math]::Min($l, [Math]::Min($haO,$haC))
        }
        $HACandlesData += [PSCustomObject]@{ Open=$haO; High=$haH; Low=$haL; Close=$haC; TimeStamp=$c[0] }
    }

    if($HACandlesData.Count -gt $LastNCandles){ $HACandlesData = $HACandlesData[-$LastNCandles..-1] }
    return $HACandlesData
}

# ── Module exports (single consolidated statement) ─────────
Export-ModuleMember -Function Search-KiteInstrument, Show-KitePresets, Get-KiteLiveCandles, Get-KiteHeikinAshiCandles, Invoke-KiteHALongStrategy, Invoke-KiteHAShortStrategy, Resolve-KiteAccessToken, Exchange-KiteRequestToken, Show-KiteSymbols, Resolve-KiteSymbol, Place-ZerodhaOrder, Get-IndexOptionConfig, Get-KiteSpotPrice, Get-KiteOptionInstruments, Get-ATMOption, Get-IntervalSeconds, Get-IntervalLabel, Parse-KiteTicks, Get-KiteOpenPositions, Get-ZerodhaCandleData, Get-HeikinAshiCandlesData
