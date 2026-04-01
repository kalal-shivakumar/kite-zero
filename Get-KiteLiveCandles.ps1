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
    [ValidateSet('minute','3minute','5minute','10minute','15minute','30minute','60minute')]
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

#region --- Symbol Presets ---
$script:SymbolPresets = @{
    'NIFTY'       = @{ Token=256265;    Label='NIFTY 50' }
    'NIFTY50'     = @{ Token=256265;    Label='NIFTY 50' }
    'BANKNIFTY'   = @{ Token=260105;    Label='BANK NIFTY' }
    'FINNIFTY'    = @{ Token=257801;    Label='FIN NIFTY' }
    'MIDCPNIFTY'  = @{ Token=288009;    Label='MIDCAP NIFTY' }
    'SENSEX'      = @{ Token=265;       Label='SENSEX' }
    'RELIANCE'    = @{ Token=738561;    Label='RELIANCE' }
    'TCS'         = @{ Token=2953217;   Label='TCS' }
    'INFY'        = @{ Token=408065;    Label='INFOSYS' }
    'HDFCBANK'    = @{ Token=341249;    Label='HDFC BANK' }
    'ICICIBANK'   = @{ Token=1270529;   Label='ICICI BANK' }
    'SBIN'        = @{ Token=779521;    Label='SBI' }
    'TATAMOTORS'  = @{ Token=884737;    Label='TATA MOTORS' }
    'ITC'         = @{ Token=424961;    Label='ITC' }
    'WIPRO'       = @{ Token=969473;    Label='WIPRO' }
    'BHARTIARTL'  = @{ Token=2714625;   Label='BHARTI AIRTEL' }
    'KOTAKBANK'   = @{ Token=492033;    Label='KOTAK BANK' }
    'LT'          = @{ Token=2939649;   Label='L&T' }
    'HINDUNILVR'  = @{ Token=356865;    Label='HUL' }
    'AXISBANK'    = @{ Token=1510401;   Label='AXIS BANK' }
    'MARUTI'      = @{ Token=2815745;   Label='MARUTI' }
    'ADANIENT'    = @{ Token=6401;      Label='ADANI ENT' }
    'ADANIPORTS'  = @{ Token=3861249;   Label='ADANI PORTS' }
    'BAJFINANCE'  = @{ Token=81153;     Label='BAJ FINANCE' }
    'SUNPHARMA'   = @{ Token=857857;    Label='SUN PHARMA' }
    'TITAN'       = @{ Token=897537;    Label='TITAN' }
    'SILVERM'     = @{ Token=117128455; Label='SILVERM FUT' }
    'GOLDM'       = @{ Token=116768775; Label='GOLDM FUT' }
    'CRUDEOIL'    = @{ Token=116544263; Label='CRUDE OIL FUT' }
    'NATURALGAS'  = @{ Token=116853511; Label='NATURAL GAS FUT' }
}
#endregion

#region --- Binary helpers ---
function Read-Int16BE([byte[]]$buf, [int]$pos) {
    return ([int]$buf[$pos] -shl 8) -bor [int]$buf[$pos + 1]
}
function Read-Int32BE([byte[]]$buf, [int]$pos) {
    $v = ([uint32]$buf[$pos] -shl 24) -bor ([uint32]$buf[$pos+1] -shl 16) -bor ([uint32]$buf[$pos+2] -shl 8) -bor [uint32]$buf[$pos+3]
    return [int]$v
}
#endregion

#region --- Parse binary ticks ---
function Parse-Ticks([byte[]]$data, [int]$len) {
    if ($len -lt 4) { return @() }
    $np = Read-Int16BE $data 0
    $ticks = @()
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
        $ticks += $t
        $off += $pl
    }
    return $ticks
}
#endregion

#region --- Token auth ---
function Exchange-RequestToken([string]$ApiKey, [string]$ApiSecret, [string]$ReqToken, [string]$FilePath) {
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
            @{ access_token=$r.data.access_token; saved_at=(Get-Date).ToString('o'); user="$($r.data.user_name) ($($r.data.user_id))" } | ConvertTo-Json | Set-Content $FilePath
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

function Resolve-AccessToken([string]$ApiKey, [string]$ApiSecret, [string]$FilePath) {
    # Check env
    if ($env:KITE_ACCESS_TOKEN) { return $env:KITE_ACCESS_TOKEN }
    # Check file with 10-hour expiry (uses file last-modified time)
    if (Test-Path $FilePath) {
        try {
            $d = Get-Content $FilePath -Raw | ConvertFrom-Json
            $h = ((Get-Date) - (Get-Item $FilePath).LastWriteTime).TotalHours
            if ($h -lt 10 -and $d.access_token) {
                Write-Host "  Loaded access_token (age: $([Math]::Round($h,1))h)" -ForegroundColor DarkGray
                return $d.access_token
            }
            Write-Host "  access_token expired ($([Math]::Round($h,1))h old)." -ForegroundColor Yellow
        } catch { Write-Host "  Invalid accesstoken.json: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    # Interactive login
    $url = 'https://kite.trade/connect/login?v=3&api_key=' + $ApiKey
    Write-Host ''
    Write-Host '  No valid access_token. Opening login...' -ForegroundColor Cyan
    Write-Host "  $url" -ForegroundColor DarkGray
    try { Start-Process $url } catch {}
    Write-Host ''
    Write-Host '  After login, copy the request_token from the redirect URL.' -ForegroundColor Yellow
    Write-Host ''
    $input = Read-Host '  Paste the request_token here'
    $input = $input.Trim()
    if (-not $input) { return $null }
    return (Exchange-RequestToken $ApiKey $ApiSecret $input $FilePath)
}
#endregion

# ================================================================
# Function: Get-ZerodhaCandleData
# ================================================================
Function Get-ZerodhaCandleData {
    param(
        [string]$TradingSymbol  = 'NIFTY',
        [int]$InstrumentToken,
        [ValidateSet('minute','3minute','5minute','10minute','15minute','30minute','60minute')]
        [string]$TimeFrame      = 'minute',
        [int]$CandlesToShow     = 10,
        [switch]$FullMode,
        [switch]$ListSymbols,
        [string]$RequestToken,
        [string]$AccessToken,
        [string]$API_Key        = '0fvxhlacu555dhp0',
        [string]$API_Secret     = '69wajxn41hj77pze3xnhw1dp442auw8t'
    )

    # --- List symbols ---
    if ($ListSymbols) {
        Write-Host ''
        Write-Host '  Available Trading Symbols:' -ForegroundColor Cyan
        Write-Host '  -------------------------' -ForegroundColor DarkGray
        $f = '  {0,-16} {1,12}   {2}'
        Write-Host ($f -f 'Symbol','Token','Label') -ForegroundColor Cyan
        foreach ($k in ($script:SymbolPresets.Keys | Sort-Object)) {
            $v = $script:SymbolPresets[$k]
            Write-Host ($f -f $k, $v.Token, $v.Label)
        }
        Write-Host ''
        Write-Host '  Usage: .\Get-KiteLiveCandles.ps1 -TradingSymbol BANKNIFTY -TimeFrame 5minute' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    # --- Resolve symbol ---
    $sym = $TradingSymbol.ToUpper().Trim()
    if ($InstrumentToken -gt 0) {
        $instToken = $InstrumentToken
        $label = $sym
    } elseif ($script:SymbolPresets.ContainsKey($sym)) {
        $p = $script:SymbolPresets[$sym]
        $instToken = $p.Token
        $label = $p.Label
    } else {
        Write-Host "  Unknown symbol: $TradingSymbol. Use -ListSymbols to see presets." -ForegroundColor Red
        return
    }

    # --- Interval minutes ---
    $intMin = switch ($TimeFrame) {
        'minute'   { 1 }
        '3minute'  { 3 }
        '5minute'  { 5 }
        '10minute' { 10 }
        '15minute' { 15 }
        '30minute' { 30 }
        '60minute' { 60 }
        default    { 1 }
    }

    # --- Auth (token is pre-resolved at script entry point) ---
    if (-not $AccessToken) {
        Write-Host '  No token. Exiting.' -ForegroundColor Red; return
    }

    # --- Candle state ---
    $script:candleStore = @{}
    $script:buildingCdl = @{}
    $script:totalTicks  = 0

    function Get-CandleKey {
        $now = Get-Date
        $bucket = [Math]::Floor($now.Minute / $intMin) * $intMin
        return $now.ToString('yyyy-MM-dd HH:') + $bucket.ToString('00')
    }

    function Update-Candle([int]$tk, [double]$ltp, [int]$vol, [double]$opn, [double]$hi, [double]$lo, [double]$cls, [int]$oi) {
        $script:totalTicks++
        $mk = Get-CandleKey
        if (-not $script:candleStore.ContainsKey($tk)) {
            $script:candleStore[$tk] = [System.Collections.ArrayList]::new()
        }
        $cur = $script:buildingCdl[$tk]
        if (($null -eq $cur) -or ($cur.MK -ne $mk)) {
            if ($null -ne $cur) {
                $null = $script:candleStore[$tk].Add([PSCustomObject]@{
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

    function Show-Table([int]$tk) {
        $all = @()
        $done = $script:candleStore[$tk]
        if ($done -and $done.Count -gt 0) { $all += $done.ToArray() }
        $cur = $script:buildingCdl[$tk]
        if ($null -ne $cur) {
            $all += [PSCustomObject]@{ MK=$cur.MK; O=$cur.O; H=$cur.H; L=$cur.L; C=$cur.C; V=$cur.V; OI=$cur.OI; T=$cur.T }
        }
        if ($all.Count -eq 0) { return }
        $disp = $all | Select-Object -Last $CandlesToShow

        Clear-Host
        Write-Host ''
        $intLabel = if ($intMin -eq 1) { '1-Min' } elseif ($intMin -eq 60) { '1-Hour' } else { "$($intMin)-Min" }
        Write-Host '  ================================================' -ForegroundColor Cyan
        Write-Host "  $label - Live $intLabel Candles (WebSocket)" -ForegroundColor Cyan
        Write-Host '  ================================================' -ForegroundColor Cyan
        Write-Host "  Symbol  : $sym  |  Token: $instToken  |  TimeFrame: $TimeFrame"
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

    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader('X-Kite-Version', '3')
    $cts = [System.Threading.CancellationTokenSource]::new()

    try {
        $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
        if (-not $ct.Wait(15000)) { Write-Host '  Connection timed out.' -ForegroundColor Red; return }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host "  Connection failed. State: $($ws.State)" -ForegroundColor Red; return
        }
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

        $buf = New-Object byte[] 65536

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
                $mb = New-Object byte[] $res.Count
                [Array]::Copy($buf, $mb, $res.Count)
                $ticks = Parse-Ticks $mb $res.Count
                foreach ($tk in $ticks) {
                    if ($tk.LTP -gt 0) { Update-Candle $tk.Tok $tk.LTP $tk.Vol $tk.O $tk.H $tk.L $tk.C $tk.OI }
                }
                Show-Table $instToken
            }
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) { Write-Host "  Detail: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
    }
    finally {
        if ($ws -and ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open)) {
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done', $cts.Token).Wait(5000) } catch {}
        }
        if ($ws)  { $ws.Dispose() }
        if ($cts) { $cts.Dispose() }
        Write-Host ''
        Write-Host '  Disconnected.' -ForegroundColor Yellow
        $cnt = 0
        if ($script:candleStore[$instToken]) { $cnt += $script:candleStore[$instToken].Count }
        if ($script:buildingCdl[$instToken]) { $cnt++ }
        Write-Host "  $label : $cnt candle(s) from $($script:totalTicks) ticks" -ForegroundColor Gray
        Write-Host ''
    }
}

# ================================================================
# Entry point — validate & load token immediately
# ================================================================
if ($GetLoginUrl) {
    $url = 'https://kite.trade/connect/login?v=3&api_key=' + $API_Key
    Write-Host "  Login URL: $url" -ForegroundColor White
    try { Start-Process $url } catch {}
    exit 0
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$tokenFile = Join-Path $scriptDir 'accesstoken.json'

# Resolve token: param > env > file (10h) > interactive login
if (-not $AccessToken) {
    if ($RequestToken) {
        $AccessToken = Exchange-RequestToken $API_Key $API_Secret $RequestToken $tokenFile
        if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
    } else {
        $AccessToken = Resolve-AccessToken $API_Key $API_Secret $tokenFile
        if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
    }
}
Write-Host "  Access token ready." -ForegroundColor Green

$splat = @{
    TradingSymbol = $TradingSymbol
    TimeFrame     = $TimeFrame
    CandlesToShow = $CandlesToShow
    AccessToken   = $AccessToken
    API_Key       = $API_Key
    API_Secret    = $API_Secret
}
if ($InstrumentToken -gt 0) { $splat.InstrumentToken = $InstrumentToken }
if ($FullMode)     { $splat.FullMode     = $true }
if ($ListSymbols)  { $splat.ListSymbols  = $true }

Get-ZerodhaCandleData @splat
