<#
.SYNOPSIS
  Running-bar (v2) Heikin-Ashi pyramiding bot: same strategy as HeikinAshi-Position-trading.ps1, evaluated on the forming candle.
.DESCRIPTION
  Every tick the forming HA candle is checked: green -> BUY CE, red -> BUY PE, at most one add per bar, up to MaxLotSize.
  If the forming candle turns the opposite colour the whole position is sold and a fresh Lotsize position opens on the
  other side, at most once per bar so a choppy bar cannot churn orders. Broker net quantity is the truth.
  State, lock and audit files are shared with the close-based script: only one of the two can trade live at a time.
.EXAMPLE
  .\HeikinAshi-Position-trading-v2.ps1 -DryRun
  .\HeikinAshi-Position-trading-v2.ps1 -TimeFrame minute -CleanupPosition no
#>

param(
    [string]$TradingSymbol,
    [long]$InstrumentToken,
    [ValidateSet('5second','15second','30second','minute','2minute','3minute','4minute','5minute','10minute','15minute','30minute','60minute')]
    [string]$TimeFrame,
    [int]$CandlesToShow,
    [switch]$ListSymbols,
    [switch]$GetLoginUrl,
    [string]$RequestToken,
    [string]$AccessToken,
    [string]$API_Key,
    [string]$API_Secret,
    [ValidateSet('NIFTY','BANKNIFTY','FinNifty','MIDCPNIFTY','SENSEX')]
    [string]$IndexChoosen,
    [int]$Lotsize,
    [int]$MaxLotSize,
    [ValidateSet('NRML','MIS')]
    [string]$Product,
    [datetime]$StartTime,
    [datetime]$StopTime,
    [string]$Order_type,
    [ValidateSet('Option_Buyer','Option_Seller')]
    [string]$ModeOfTrading,
    [int]$ATMOffset,
    [string]$Variety,
    [int]$MarketProtection,
    [ValidateSet('yes','no')]
    [string]$ExitTrade,
    [ValidateSet('yes','no','auto')]
    [string]$CleanupPosition = 'auto',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module "$scriptDir\KiteData.psm1" -Force -WarningAction SilentlyContinue

# ================================================================
# Pure helpers (no broker access)
# ================================================================
function Get-HAPColour($Candle) {
    if ($Candle.Close -gt $Candle.Open) { return 'GREEN' }
    if ($Candle.Close -lt $Candle.Open) { return 'RED' }
    return 'DOJI'
}

function ConvertTo-HAPBucket($Value) {
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) }
    $s = ([string]$Value) -replace 'T', ' '
    if ($s.Length -ge 19) { return $s.Substring(0, 19) }
    return $s
}

function Get-HAPPrevBucket([string]$Bucket, [int]$IntervalSeconds) {
    $d = [datetime]::ParseExact($Bucket, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
    return $d.AddSeconds(-$IntervalSeconds).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
}

# Time only for today's candles, month-day plus time for older ones.
function Get-HAPLabel([string]$Bucket) {
    if ($Bucket.StartsWith((Get-Date).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture))) { return $Bucket.Substring(11) }
    return $Bucket.Substring(5)
}

# A state save inside the current bar means that bar's add is already used (e.g. switching over from the close-based script).
function Test-HAPSwitchover([string]$Side, [string]$UpdatedAt, [string]$AddedBucket, [string]$BucketNow) {
    return [bool]($Side -ne '' -and $UpdatedAt -and [string]::CompareOrdinal($UpdatedAt, $BucketNow) -ge 0 -and $AddedBucket -ne $BucketNow)
}

function ConvertFrom-HAPHistorical($Candles) {
    foreach ($c in @($Candles)) {
        @{ Bucket = (ConvertTo-HAPBucket $c[0]); Open = [double]$c[1]; High = [double]$c[2]; Low = [double]$c[3]; Close = [double]$c[4] }
    }
}

function Build-HAPChain($Raw, [string]$CurrentBucket) {
    $prev = $null; $forming = $null
    $done = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (@($Raw) | Sort-Object { $_.Bucket })) {
        $cmp = [string]::CompareOrdinal($r.Bucket, $CurrentBucket)
        if ($cmp -ge 0) { if ($cmp -eq 0) { $forming = $r }; continue }
        $ha = Convert-ToHACandle $r $prev
        $prev = @{ Open = $ha.Open; High = $ha.High; Low = $ha.Low; Close = $ha.Close }
        $done.Add(@{ Bucket = $r.Bucket; Open = $ha.Open; High = $ha.High; Low = $ha.Low; Close = $ha.Close; Colour = (Get-HAPColour $ha); Partial = $false })
    }
    return @{ Candles = $done; PrevHA = $prev; Forming = $forming }
}

function New-HAPState {
    @{
        Active = $null; PrevHA = $null; PartialBucket = ''
        Candles = [System.Collections.Generic.List[object]]::new()
        Current = $null; BarNotes = [System.Collections.Generic.List[string]]::new()
        Side = ''; Symbol = ''; Token = 0; Strike = 0.0; HeldLots = 0; HeldQty = 0; AvgEntry = 0.0
        TotalPnL = 0.0; LastActedBucket = ''; AddedBucket = ''; ExitedBucket = ''; UpdatedAt = ''; Adds = 0; Exits = 0
        Events = [System.Collections.Generic.List[object]]::new()
        DryNet = @{}
        LastDraw = [datetime]::MinValue; ForceDraw = $true; CanClear = $true
        LastWarn = [datetime]::MinValue; RetryAfter = [datetime]::MinValue; Done = $false; StopNotice = $false
    }
}

# What the forming candle asks for. One add per bar; one exit-all-and-reverse per bar (the reversal lot belongs to the exit).
function Get-HAPRunningDecision {
    param([string]$Colour, [string]$HeldSide, [int]$HeldLots, [int]$LotsPerAdd, [int]$MaxLots, [bool]$InWindow, [bool]$AddedThisBar, [bool]$ExitedThisBar)
    if ($Colour -ne 'GREEN' -and $Colour -ne 'RED') { return @(@{ Op = 'NONE'; Reason = 'DOJI' }) }
    $want = if ($Colour -eq 'GREEN') { 'CE' } else { 'PE' }
    $steps = [System.Collections.Generic.List[object]]::new()
    $addUsed = $AddedThisBar
    if ($HeldSide -ne '' -and $HeldSide -ne $want) {
        if ($ExitedThisBar) { return @(@{ Op = 'NONE'; Reason = 'EXIT_USED' }) }
        $steps.Add(@{ Op = 'EXIT'; Side = $HeldSide })
        $HeldLots = 0; $addUsed = $false
    }
    $room = $MaxLots - $HeldLots
    if ($addUsed) { $steps.Add(@{ Op = 'NONE'; Reason = 'ADD_USED' }) }
    elseif ($room -le 0) { $steps.Add(@{ Op = 'HOLD'; Reason = 'MAX' }) }
    elseif (-not $InWindow) { $steps.Add(@{ Op = 'NONE'; Reason = 'OUT_OF_WINDOW' }) }
    else { $steps.Add(@{ Op = 'ADD'; Side = $want; Lots = [Math]::Min($LotsPerAdd, $room) }) }
    return @($steps)
}

# Bar roll-over is clock-driven so sparse option ticks cannot delay it; the closed bar keeps the actions taken during it.
function Update-HAPClock {
    param([hashtable]$S, [string]$BucketNow)
    $a = $S.Active
    if ($null -eq $a -or $a.Bucket -eq $BucketNow) { return $null }
    $ha = Convert-ToHACandle $a $S.PrevHA
    $S.PrevHA = @{ Open = $ha.Open; High = $ha.High; Low = $ha.Low; Close = $ha.Close }
    $c = @{ Bucket = $a.Bucket; Open = $ha.Open; High = $ha.High; Low = $ha.Low; Close = $ha.Close; Colour = (Get-HAPColour $ha); Partial = [bool]$a.Partial; Action = ($S.BarNotes -join ', '); Lots = '' }
    $S.BarNotes.Clear()
    $S.Candles.Add($c)
    while ($S.Candles.Count -gt 200) { $S.Candles.RemoveAt(0) }
    $S.Active = $null
    return $c
}

function Add-HAPTick {
    param([hashtable]$S, [string]$BucketNow, [double]$Price)
    $a = $S.Active
    if ($null -eq $a) {
        $S.Active = @{ Bucket = $BucketNow; Open = $Price; High = $Price; Low = $Price; Close = $Price; Ticks = 1; Partial = ($S.PartialBucket -eq $BucketNow) }
        return
    }
    if ($Price -gt $a.High) { $a.High = $Price }
    if ($Price -lt $a.Low) { $a.Low = $Price }
    $a.Close = $Price
    $a.Ticks++
}

# ================================================================
# Logging, state file, broker access (use script-level config and $S)
# ================================================================
function Write-HAPEvent([string]$Text, [string]$Color = 'Gray') {
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text
    $S.Events.Add(@{ Text = $line; Color = $Color })
    while ($S.Events.Count -gt 50) { $S.Events.RemoveAt(0) }
    $S.ForceDraw = $true
    Write-Host "  $line" -ForegroundColor $Color
}

function Write-HAPAudit {
    param([string]$Action, [string]$Symbol = '', $ReqQty = '', $Before = '', $After = '', [string]$Result = '', [string]$Note = '')
    try {
        if (-not (Test-Path $auditFile)) { 'time,candle,colour,action,symbol,reqQty,beforeNet,afterNet,result,note' | Set-Content -Path $auditFile }
        $cur = $S.Current
        $candle = if ($cur) { $cur.Bucket } else { '-' }
        $colour = if ($cur) { $cur.Colour } else { '-' }
        $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f (Get-Date).ToString('HH:mm:ss'), $candle, $colour, $Action, $Symbol, $ReqQty, $Before, $After, $Result, ($Note -replace ',', ';')
        Add-Content -Path $auditFile -Value $line
    } catch { }  # an unwritable log must never stop trading
}

function Save-HAPState {
    $o = [ordered]@{
        Side = $S.Side; Symbol = $S.Symbol; Token = $S.Token; Strike = $S.Strike
        HeldLots = $S.HeldLots; HeldQty = $S.HeldQty; AvgEntry = $S.AvgEntry
        TotalPnL = $S.TotalPnL; LastActedBucket = $S.LastActedBucket; AddedBucket = $S.AddedBucket; ExitedBucket = $S.ExitedBucket
        UpdatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
    }
    if ($DryRun) { $o['DryNet'] = $S.DryNet }
    $tmp = "$stateFile.tmp"
    ($o | ConvertTo-Json) | Set-Content -Path $tmp -Force
    Move-Item -Path $tmp -Destination $stateFile -Force
}

function Import-HAPState {
    $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
    $S.Side = [string]$saved.Side; $S.Symbol = [string]$saved.Symbol; $S.Token = [long]$saved.Token; $S.Strike = [double]$saved.Strike
    $S.HeldLots = [int]$saved.HeldLots; $S.HeldQty = [int]$saved.HeldQty; $S.AvgEntry = [double]$saved.AvgEntry
    $S.TotalPnL = [double]$saved.TotalPnL; $S.LastActedBucket = ConvertTo-HAPBucket $saved.LastActedBucket
    $S.AddedBucket = ConvertTo-HAPBucket $saved.AddedBucket; $S.ExitedBucket = ConvertTo-HAPBucket $saved.ExitedBucket; $S.UpdatedAt = ConvertTo-HAPBucket $saved.UpdatedAt
    if ($DryRun -and $saved.DryNet) { foreach ($p in $saved.DryNet.PSObject.Properties) { $S.DryNet[$p.Name] = [int]$p.Value } }
}

function Reset-HAPPosition {
    $S.Side = ''; $S.Symbol = ''; $S.Token = 0; $S.Strike = 0.0
    $S.HeldLots = 0; $S.HeldQty = 0; $S.AvgEntry = 0.0
}

function Test-HAPInWindow {
    $t = [datetime]::Now.TimeOfDay
    return ($t -ge $StartTime.TimeOfDay -and $t -le $StopTime.TimeOfDay)
}

# ,@() keeps an empty list distinct from $null (= read failure)
function Get-HAPPositions {
    try { $resp = Invoke-RestMethod 'https://api.kite.trade/portfolio/positions' -Headers $headers -Method Get -ErrorAction Stop }
    catch { return $null }
    if ($null -eq $resp -or $null -eq $resp.data) { return $null }
    return , @($resp.data.net | Where-Object { $_ })
}

function Get-HAPNetFrom($Positions, [string]$Symbol, [string]$ProductType) {
    $rows = @($Positions | Where-Object { $_.tradingsymbol -eq $Symbol -and $_.product -eq $ProductType })
    if ($rows.Count -eq 0) { return 0 }
    return [int](($rows | Measure-Object -Property quantity -Sum).Sum)
}

function Get-HAPNet([string]$Symbol) {
    if ($DryRun) { return [int]($S.DryNet[$Symbol] ?? 0) }
    $pos = Get-HAPPositions
    if ($null -eq $pos) { return $null }
    return Get-HAPNetFrom $pos $Symbol $Product
}

function Get-HAPOptLTP([string]$Symbol) {
    try {
        $r = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([uri]::EscapeDataString("${optExchange}:$Symbol"))" -Headers $headers -ErrorAction Stop
        foreach ($p in $r.data.PSObject.Properties) { return [double]$p.Value.last_price }
    } catch { }
    return 0.0
}

function Send-HAPOrder([string]$Type, [string]$Symbol, [int]$Qty, [string]$Tag) {
    if ($DryRun) {
        $cur = [int]($S.DryNet[$Symbol] ?? 0)
        $S.DryNet[$Symbol] = if ($Type -eq 'BUY') { $cur + $Qty } else { $cur - $Qty }
        return $true
    }
    $r = Place-ZerodhaOrder -CommonHeader $headers -Type $Type -Variety $Variety -Tradingsymbol $Symbol -Quantity $Qty `
        -OrderType $Order_type -Product $Product -Exchange $exchange -Tag $Tag -MarketProtection $MarketProtection
    return [bool]$r
}

# Place-ZerodhaOrder only confirms acceptance, so poll broker net quantity until the fill shows up.
function Wait-HAPNet {
    param([string]$Symbol, [int]$Target, [ValidateSet('GE', 'LE')][string]$Cmp)
    $last = $null
    for ($i = 0; $i -lt 10; $i++) {
        $n = Get-HAPNet $Symbol
        if ($null -ne $n) {
            $last = $n
            if (($Cmp -eq 'GE' -and $n -ge $Target) -or ($Cmp -eq 'LE' -and $n -le $Target)) { return @{ Ok = $true; Net = $n } }
        }
        Start-Sleep -Milliseconds 400
    }
    return @{ Ok = $false; Net = $last }
}

# ================================================================
# Execution
# ================================================================
function Invoke-HAPExit {
    $sym = $S.Symbol; $side = $S.Side
    $before = Get-HAPNet $sym
    if ($null -eq $before) { return 'RETRY' }
    if ($before -le 0) {
        Write-HAPAudit 'EXIT' $sym 0 $before $before 'ALREADY_FLAT'
        Reset-HAPPosition; Save-HAPState
        return 'OK'
    }
    if ($DryRun) { Write-HAPEvent "DRY: would cancel resting stop-loss orders on $sym" 'DarkGray' }
    else {
        try { [void](Cancel-AllStopLosses -TrendEntrySelection ([regex]::Escape($sym)) -Headers $headers) }
        catch { Write-HAPEvent "Stop-loss cancel failed: $($_.Exception.Message)" 'Red' }
    }
    $ltp = Get-HAPOptLTP $sym
    if (-not (Send-HAPOrder 'SELL' $sym $before "HAP${side}EXIT")) {
        Write-HAPAudit 'EXIT' $sym $before $before $before 'FAIL' 'order not accepted'
        Write-HAPEvent "EXIT $side $sym x$before FAILED - order not accepted" 'Red'
        return 'FAILED'
    }
    $w = Wait-HAPNet $sym 0 'LE'
    if ($w.Ok) {
        $pnl = if ($ltp -gt 0 -and $S.AvgEntry -gt 0) { ($ltp - $S.AvgEntry) * $before } else { 0.0 }
        $S.TotalPnL += $pnl
        $S.Exits++
        Write-HAPAudit 'EXIT' $sym $before $before $w.Net 'CONFIRMED' ('pnl~{0:N2}' -f $pnl)
        Write-HAPEvent ('EXIT {0} {1} x{2} CONFIRMED | approx P&L {3:N2} | total {4:N2}' -f $side, $sym, $before, $pnl, $S.TotalPnL) 'Magenta'
        Reset-HAPPosition; Save-HAPState
        return 'OK'
    }
    if ($null -ne $w.Net -and $w.Net -gt 0) { $S.HeldQty = $w.Net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($w.Net / $ContractLot)) }
    Write-HAPAudit 'EXIT' $sym $before $before $w.Net 'NOT_CONFIRMED'
    Write-HAPEvent "EXIT $side $sym NOT confirmed (broker net $($w.Net)) - no reversal this candle" 'Red'
    Save-HAPState
    return 'FAILED'
}

function Invoke-HAPAdd([string]$Side, [int]$Lots) {
    $isNew = ($S.Side -eq '')
    if ($isNew) {
        $spot = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers
        if ($spot -le 0) { return 'RETRY' }
        $opts = if ($Side -eq 'CE') { $ceOptions } else { $peOptions }
        $strikes = if ($Side -eq 'CE') { $ceStrikes } else { $peStrikes }
        $offset = if ($Side -eq 'CE') { -$ATMOffset } else { $ATMOffset }
        $opt = Get-ATMOption -SpotPrice $spot -Options $opts -AllStrikes $strikes -Offset $offset
        if (-not $opt) {
            Write-HAPAudit 'ADD' '' '' '' '' 'FAIL' 'no ATM contract'
            Write-HAPEvent "ADD $Side FAILED - no ATM contract found" 'Red'
            return 'FAILED'
        }
        $sym = $opt.Symbol; $tok = $opt.Token; $strike = $opt.Strike
    } else {
        $sym = $S.Symbol; $tok = $S.Token; $strike = $S.Strike
    }
    $qty = $Lots * $ContractLot
    $before = Get-HAPNet $sym
    if ($null -eq $before) { return 'RETRY' }
    if ($isNew -and $before -gt 0) {
        Write-HAPAudit 'ADD' $sym $qty $before $before 'BLOCKED' 'symbol already held outside the bot'
        Write-HAPEvent "ADD $Side $sym BLOCKED - broker already holds $before outside this bot" 'Red'
        return 'FAILED'
    }
    $ltp = Get-HAPOptLTP $sym
    if (-not (Send-HAPOrder 'BUY' $sym $qty "HAP${Side}ADD")) {
        Write-HAPAudit 'ADD' $sym $qty $before $before 'FAIL' 'order not accepted'
        Write-HAPEvent "ADD $Side $sym x$qty FAILED - order not accepted" 'Red'
        return 'FAILED'
    }
    $w = Wait-HAPNet $sym ($before + $qty) 'GE'
    $after = if ($null -ne $w.Net) { $w.Net } else { $before }
    $bought = [Math]::Max(0, $after - $before)
    $prevQty = if ($isNew) { 0 } else { $S.HeldQty }
    $prevAvg = if ($isNew) { 0.0 } else { $S.AvgEntry }
    # Adopt the contract even when unconfirmed so a late fill is picked up from the broker next time.
    $S.Side = $Side; $S.Symbol = $sym; $S.Token = $tok; $S.Strike = $strike
    $S.HeldQty = $after; $S.HeldLots = [int][Math]::Floor($after / $ContractLot)
    if ($bought -gt 0 -and $ltp -gt 0) { $S.AvgEntry = (($prevQty * $prevAvg) + ($bought * $ltp)) / ($prevQty + $bought) }
    $res = if ($w.Ok) { 'CONFIRMED' } else { 'NOT_CONFIRMED' }
    if ($w.Ok) { $S.Adds++ }
    Write-HAPAudit 'ADD' $sym $qty $before $after $res ('ltp~{0}' -f $ltp)
    $color = if ($w.Ok) { 'Green' } else { 'Red' }
    Write-HAPEvent ('ADD {0} {1} +{2} lot(s) {3} | net {4}->{5} | now {6}/{7} lots | avg {8:N2}' -f $Side, $sym, $Lots, $res, $before, $after, $S.HeldLots, $MaxLots, $S.AvgEntry) $color
    Save-HAPState
    return $(if ($w.Ok) { 'OK' } else { 'FAILED' })
}

function Add-HAPBarNote([string]$Text) { $S.BarNotes.Add($Text) }

# Only for failures where no order was sent; once an order may be out, that action is not repeated in the same bar.
function Set-HAPRetry([string]$Why) {
    $S.RetryAfter = [datetime]::Now.AddSeconds(3)
    if (([datetime]::Now - $S.LastWarn).TotalSeconds -ge 10) {
        $S.LastWarn = [datetime]::Now
        Write-HAPEvent "$Why - will retry" 'Yellow'
    }
}

function Test-HAPActs($Steps, [string]$Op) { return (@($Steps | Where-Object { $_.Op -eq $Op }).Count -gt 0) }

function Get-HAPRunningSteps([string]$Colour, [string]$Bucket) {
    $held = if ($S.Side -ne '') { $S.HeldLots } else { 0 }
    return @(Get-HAPRunningDecision -Colour $Colour -HeldSide $S.Side -HeldLots $held -LotsPerAdd $LotsPerAdd -MaxLots $MaxLots -InWindow (Test-HAPInWindow) -AddedThisBar ($S.AddedBucket -eq $Bucket) -ExitedThisBar ($S.ExitedBucket -eq $Bucket))
}

# Runs every loop pass: judges the forming candle and trades only when a step is due.
function Invoke-HAPRunning {
    $a = $S.Active
    if ($null -eq $a -or $null -eq $S.PrevHA -or $a.Partial -or [datetime]::Now -lt $S.RetryAfter) { return }
    $bucket = $a.Bucket
    $colour = Get-HAPColour (Convert-ToHACandle $a $S.PrevHA)
    $steps = @(Get-HAPRunningSteps $colour $bucket)
    if (-not (Test-HAPActs $steps 'EXIT') -and -not (Test-HAPActs $steps 'ADD')) { return }
    $S.Current = @{ Bucket = $bucket; Colour = $colour }
    try {
        if ($S.Side -ne '') {
            $net = Get-HAPNet $S.Symbol
            if ($null -eq $net) { Set-HAPRetry 'Broker positions unreadable'; return }
            if ($net -le 0) {
                Write-HAPAudit 'RESET' $S.Symbol '' $S.HeldQty 0 'POSITION_GONE' 'not held at broker; treated as flat'
                Write-HAPEvent "$($S.Symbol) is no longer held at the broker - treating as flat" 'Yellow'
                Reset-HAPPosition
            } else {
                $S.HeldQty = $net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($net / $ContractLot))
            }
            $steps = @(Get-HAPRunningSteps $colour $bucket)
            if (-not (Test-HAPActs $steps 'EXIT') -and -not (Test-HAPActs $steps 'ADD')) { return }
        }

        # Persist before ordering so a crash can skip an action but never repeat one in the same bar.
        $old = @{ Added = $S.AddedBucket; Exited = $S.ExitedBucket; Acted = $S.LastActedBucket }
        if (Test-HAPActs $steps 'ADD') { $S.AddedBucket = $bucket }
        if (Test-HAPActs $steps 'EXIT') { $S.ExitedBucket = $bucket }
        $S.LastActedBucket = $bucket
        try { Save-HAPState }
        catch {
            $S.AddedBucket = $old.Added; $S.ExitedBucket = $old.Exited; $S.LastActedBucket = $old.Acted
            Set-HAPRetry "State file not writable ($($_.Exception.Message))"
            return
        }

        $plan = [System.Collections.Generic.List[string]]::new()
        foreach ($st in $steps) {
            if ($st.Op -eq 'EXIT') { $plan.Add("EXIT $($st.Side)") }
            elseif ($st.Op -eq 'ADD') { $plan.Add("ADD $($st.Side) +$($st.Lots)") }
        }
        Write-HAPEvent ('bar {0} forming {1} -> {2}' -f (Get-HAPLabel $bucket), $colour, ($plan -join ', then ')) 'Cyan'

        $retry = ''; $addTried = $false
        foreach ($st in $steps) {
            if ($st.Op -eq 'EXIT') {
                $exitSide = $S.Side
                $r = Invoke-HAPExit
                if ($r -eq 'OK') { Add-HAPBarNote "EXIT $exitSide" }
                else {
                    if ($r -eq 'RETRY') { $retry = 'exit' } else { Add-HAPBarNote "EXIT $exitSide FAILED" }
                    break
                }
            }
            elseif ($st.Op -eq 'ADD') {
                $addTried = $true
                $r = Invoke-HAPAdd $st.Side $st.Lots
                if ($r -eq 'OK') { Add-HAPBarNote "ADD $($st.Side) +$($st.Lots)" }
                elseif ($r -eq 'RETRY') { $retry = 'add' }
                else { Add-HAPBarNote "ADD $($st.Side) FAILED" }
            }
        }
        if ($retry -eq 'add' -or -not $addTried) { $S.AddedBucket = $old.Added }
        if ($retry -eq 'exit') { $S.ExitedBucket = $old.Exited; $S.LastActedBucket = $old.Acted }
        if ($retry) { Set-HAPRetry "Broker data unavailable for the $retry" }
    } finally { $S.Current = $null }
}

function Test-HAPStop {
    if ([datetime]::Now.TimeOfDay -le $StopTime.TimeOfDay) { return }
    if ($S.Side -eq '') {
        Write-HAPEvent 'Stop time reached and no open position - stopping.' 'Yellow'
        $S.Done = $true
    } elseif (-not $S.StopNotice) {
        $S.StopNotice = $true
        Write-HAPEvent "Stop time reached - no new lots; holding $($S.HeldLots) lot(s) until the opposite colour exits." 'Yellow'
    }
}

# ================================================================
# Startup helpers
# ================================================================
function Enter-HAPLock {
    if (Test-Path $lockFile) {
        $oldPid = 0
        $txt = Get-Content $lockFile -Raw -ErrorAction SilentlyContinue
        if ($txt -and [int]::TryParse($txt.Trim(), [ref]$oldPid) -and $oldPid -ne $PID) {
            $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match '^(pwsh|powershell)') {
                Write-Host "  ERROR: another instance is already running (PID $oldPid)." -ForegroundColor Red
                exit 1
            }
        }
    }
    Set-Content -Path $lockFile -Value $PID
}

function Get-HAPHistory {
    param([long]$Token, [string]$Interval)
    $fmt = 'yyyy-MM-dd+HH:mm:ss'
    $to = (Get-Date).ToString($fmt, [cultureinfo]::InvariantCulture)
    $from = (Get-Date).AddDays(-5).ToString($fmt, [cultureinfo]::InvariantCulture)
    $resp = Invoke-RestMethod "https://api.kite.trade/instruments/historical/$Token/${Interval}?from=$from&to=$to" -Headers $headers -Method Get -ErrorAction Stop
    return , @($resp.data.candles)
}

# Broker net quantity wins over the saved state on any mismatch.
function Sync-HAPStartup {
    if ($DryRun) {
        if ($S.Side -ne '') {
            $net = [int]($S.DryNet[$S.Symbol] ?? 0)
            if ($net -le 0) { Write-Host "  Dry-run ledger shows $($S.Symbol) flat - state reset." -ForegroundColor Yellow; Reset-HAPPosition; Save-HAPState }
            else { $S.HeldQty = $net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($net / $ContractLot)) }
        }
        return
    }
    $pos = $null
    for ($i = 0; $i -lt 3 -and $null -eq $pos; $i++) { $pos = Get-HAPPositions; if ($null -eq $pos) { Start-Sleep -Milliseconds 500 } }
    if ($null -eq $pos) { Write-Host '  ERROR: cannot read broker positions - not starting blind.' -ForegroundColor Red; exit 1 }
    if ($S.Side -ne '') {
        $net = Get-HAPNetFrom $pos $S.Symbol $Product
        if ($net -le 0) {
            Write-Host "  Saved $($S.Side) $($S.Symbol) is not held at the broker - state reset to flat." -ForegroundColor Yellow
            Reset-HAPPosition; Save-HAPState
        } else {
            if ($net -ne $S.HeldQty) { Write-Host "  Saved qty $($S.HeldQty) differs from broker $net - using broker." -ForegroundColor Yellow }
            $S.HeldQty = $net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($net / $ContractLot))
        }
    } else {
        $un = @($pos | Where-Object { $_.quantity -ne 0 -and $_.tradingsymbol -like "$underlyingName*" -and $_.tradingsymbol -match '(CE|PE)$' })
        foreach ($u in $un) { Write-Host "  WARNING: unmanaged position $($u.tradingsymbol) qty $($u.quantity) - this bot will not trade or exit it." -ForegroundColor Yellow }
    }
}

function Show-HAPDisplay {
    $now = [datetime]::Now
    if (-not $S.ForceDraw -and ($now - $S.LastDraw).TotalMilliseconds -lt 1000) { return }
    $S.LastDraw = $now; $S.ForceDraw = $false
    if ($S.CanClear) { try { Clear-Host } catch { $S.CanClear = $false } }

    $modeText = if ($DryRun) { 'DRY RUN - no orders are sent' } else { 'LIVE - real orders' }
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  HA POSITION TRADING v2 (running bar) | $label | $modeText" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Cyan' })
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  Feed     : token $instToken | $TimeFrame ($intLabel) | Expiry $nearestExpiry"
    Write-Host "  Sizing   : add $LotsPerAdd lot(s) per bar | max $MaxLots | contract lot $ContractLot | ATM offset $ATMOffset | $Product"
    $winText = if (Test-HAPInWindow) { 'in window' } else { 'OUT of window - exits only' }
    Write-Host "  Window   : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss')) | now $($now.ToString('HH:mm:ss')) ($winText)"
    if ($S.Side -ne '') {
        Write-Host ('  LOTS RUNNING : {0} {1} of {2} lots | qty {3} | {4} | avg {5:N2}' -f $S.Side, $S.HeldLots, $MaxLots, $S.HeldQty, $S.Symbol, $S.AvgEntry) -ForegroundColor Green
    } else {
        Write-Host '  LOTS RUNNING : none (FLAT)' -ForegroundColor Gray
    }
    Write-Host ('  Realized P&L : {0:N2} (LTP based) | adds {1} | exits {2}' -f $S.TotalPnL, $S.Adds, $S.Exits)

    $fmt = ' {0,-14} {1,10} {2,10} {3,10} {4,10}  {5,-8} {6,-31} {7}'
    Write-Host ''
    Write-Host ($fmt -f 'Candle', 'HA Open', 'HA High', 'HA Low', 'HA Close', 'Colour', 'Action', 'Lots running') -ForegroundColor Cyan
    foreach ($c in @($S.Candles | Select-Object -Last $CandlesToShow)) {
        $tag = if ($c.Partial) { "$($c.Colour) ~" } else { $c.Colour }
        $rowColor = switch ($c.Colour) { 'GREEN' { 'Green' } 'RED' { 'Red' } default { 'Gray' } }
        $act = if ($c.Action) { [string]$c.Action } else { '-' }
        if ($act.Length -gt 31) { $act = $act.Substring(0, 31) }
        $lots = if ($c.Lots) { $c.Lots } else { '-' }
        Write-Host ($fmt -f (Get-HAPLabel $c.Bucket), ('{0:N2}' -f $c.Open), ('{0:N2}' -f $c.High), ('{0:N2}' -f $c.Low), ('{0:N2}' -f $c.Close), $tag, $act, $lots) -ForegroundColor $rowColor
    }
    if ($S.Active) {
        $f = Convert-ToHACandle $S.Active $S.PrevHA
        $nowLots = if ($S.Side -ne '') { '{0} {1}/{2}' -f $S.Side, $S.HeldLots, $MaxLots } else { 'FLAT' }
        $formAct = if ($S.BarNotes.Count -gt 0) { $S.BarNotes -join ', ' } else { 'running' }
        if ($formAct.Length -gt 31) { $formAct = $formAct.Substring(0, 31) }
        Write-Host ($fmt -f "$(Get-HAPLabel $S.Active.Bucket)*", ('{0:N2}' -f $f.Open), ('{0:N2}' -f $f.High), ('{0:N2}' -f $f.Low), ('{0:N2}' -f $f.Close), (Get-HAPColour $f), $formAct, $nowLots) -ForegroundColor Yellow
    }

    if ($S.Events.Count -gt 0) {
        Write-Host ''
        Write-Host '  --- Recent events ---' -ForegroundColor Cyan
        foreach ($e in @($S.Events | Select-Object -Last 8)) { Write-Host "    $($e.Text)" -ForegroundColor $e.Color }
    }
    Write-Host ''
    Write-Host '  Press Ctrl+C to stop (open lots stay open; state is saved).' -ForegroundColor DarkGray
}

# ================================================================
# Config
# ================================================================
$inputFile = Join-Path $scriptDir 'input.json'
if (-not (Test-Path $inputFile)) { Write-Host '  ERROR: input.json not found.' -ForegroundColor Red; exit 1 }
$cfg = Get-Content $inputFile -Raw | ConvertFrom-Json

if (-not $PSBoundParameters.ContainsKey('TradingSymbol')) { $TradingSymbol = $cfg.TradingSymbol }
if (-not $PSBoundParameters.ContainsKey('InstrumentToken') -and $cfg.InstrumentToken) { $InstrumentToken = [long]$cfg.InstrumentToken }
if (-not $PSBoundParameters.ContainsKey('TimeFrame')) { $TimeFrame = $cfg.TimeFrame }
if (-not $PSBoundParameters.ContainsKey('CandlesToShow')) { $CandlesToShow = if ($cfg.CandlesToShow) { [int]$cfg.CandlesToShow } else { 10 } }
if (-not $PSBoundParameters.ContainsKey('API_Key')) { $API_Key = $cfg.API_Key }
if (-not $PSBoundParameters.ContainsKey('API_Secret')) { $API_Secret = $cfg.API_Secret }
if (-not $PSBoundParameters.ContainsKey('IndexChoosen')) {
    $rawIdx = [string]$cfg.IndexChoosen
    $idxMap = @{ 'NIFTY' = 'NIFTY'; 'BANKNIFTY' = 'BANKNIFTY'; 'FINNIFTY' = 'FinNifty'; 'MIDCPNIFTY' = 'MIDCPNIFTY'; 'SENSEX' = 'SENSEX' }
    $IndexChoosen = if ($idxMap.ContainsKey($rawIdx.ToUpper())) { $idxMap[$rawIdx.ToUpper()] } else { $rawIdx }
}
if (-not $PSBoundParameters.ContainsKey('Product')) { $Product = $cfg.Product }
if (-not $PSBoundParameters.ContainsKey('StartTime')) { $StartTime = [datetime]($cfg.StartTime ?? '09:16:01') }
if (-not $PSBoundParameters.ContainsKey('StopTime')) { $StopTime = [datetime]($cfg.StopTime ?? '15:30:00') }
if (-not $PSBoundParameters.ContainsKey('Order_type')) { $Order_type = $cfg.Order_type }
if (-not $PSBoundParameters.ContainsKey('ModeOfTrading')) { $ModeOfTrading = $cfg.ModeOfTrading }
if (-not $PSBoundParameters.ContainsKey('ATMOffset')) { $ATMOffset = [int]$cfg.ATMOffset }
if (-not $PSBoundParameters.ContainsKey('Variety')) { $Variety = if ($cfg.Variety) { $cfg.Variety } else { 'regular' } }
if (-not $PSBoundParameters.ContainsKey('MarketProtection')) { $MarketProtection = if ($cfg.MarketProtection) { [int]$cfg.MarketProtection } else { 3 } }
if (-not $PSBoundParameters.ContainsKey('ExitTrade')) { $ExitTrade = if ($cfg.ExitTrade) { $cfg.ExitTrade } else { 'yes' } }

# PowerShell variables are case-insensitive: $Lotsize and $LotSize are the same variable, so the contract lot is $ContractLot.
$LotsPerAdd = if ($PSBoundParameters.ContainsKey('Lotsize')) { $Lotsize } else { $cfg.Lotsize }
$MaxLots = if ($PSBoundParameters.ContainsKey('MaxLotSize')) { $MaxLotSize } else { $cfg.MaxLotSize }

$cfgErrors = [System.Collections.Generic.List[string]]::new()
$n = 0
if (-not [int]::TryParse([string]$LotsPerAdd, [ref]$n) -or $n -lt 1) { $cfgErrors.Add("Lotsize must be a whole number >= 1 (got '$LotsPerAdd').") } else { $LotsPerAdd = $n }
if (-not [int]::TryParse([string]$MaxLots, [ref]$n) -or $n -lt 1) { $cfgErrors.Add("MaxLotSize must be a whole number >= 1 (got '$MaxLots').") } else { $MaxLots = $n }
if ($cfgErrors.Count -eq 0 -and $MaxLots -lt $LotsPerAdd) { $cfgErrors.Add("MaxLotSize ($MaxLots) must be >= Lotsize ($LotsPerAdd).") }
if ($ModeOfTrading -eq 'Option_Seller') { $cfgErrors.Add('ModeOfTrading Option_Seller is not supported: this bot only buys options.') }
if ($ExitTrade -eq 'no') { $cfgErrors.Add('ExitTrade=no disables the exit-all rule this strategy depends on; set it to yes.') }
if ($cfgErrors.Count -gt 0) {
    foreach ($e in $cfgErrors) { Write-Host "  ERROR: $e" -ForegroundColor Red }
    exit 1
}
Write-Host '  Loaded config from input.json. Sizing comes only from Lotsize and MaxLotSize (AmountToTrade and NoOfLotsPurchaseAtaTime are not used).' -ForegroundColor DarkGray

if (-not $API_Key -or -not $API_Secret) { Write-Host '  ERROR: API_Key/API_Secret not found.' -ForegroundColor Red; exit 1 }
if ($GetLoginUrl) { Start-Process "https://kite.zerodha.com/connect/login?api_key=$API_Key"; exit 0 }
if ($ListSymbols) { Show-KiteSymbols; exit 0 }

$PlacedOrdersDir = Join-Path $scriptDir 'PlacedOrders'
if (-not (Test-Path $PlacedOrdersDir)) { New-Item -ItemType Directory -Path $PlacedOrdersDir -Force | Out-Null }
$suffix = if ($DryRun) { '.dryrun' } else { '' }
$stateFile = Join-Path $PlacedOrdersDir "HA-PositionTrading$suffix.json"
$lockFile = Join-Path $PlacedOrdersDir "HA-PositionTrading$suffix.lock"
$auditFile = Join-Path $PlacedOrdersDir "HA-PositionTrading$suffix-log.csv"

Enter-HAPLock
try {
    # ================================================================
    # Auth
    # ================================================================
    $tokenFile = Join-Path $scriptDir 'accesstoken.json'
    if (-not $AccessToken) {
        if ($RequestToken) { $AccessToken = Exchange-KiteRequestToken -ApiKey $API_Key -ApiSecret $API_Secret -ReqToken $RequestToken -TokenFilePath $tokenFile }
        else { $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile }
        if (-not $AccessToken) { Write-Host '  No token. Exiting.' -ForegroundColor Red; exit 1 }
    }
    $headers = @{ 'X-Kite-Version' = '3'; 'Authorization' = "token ${API_Key}:${AccessToken}" }

    $tokenValid = $false
    try {
        $kiteProfile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
        if ($kiteProfile.data.user_id) { $tokenValid = $true; Write-Host "  Logged in as: $($kiteProfile.data.user_name) ($($kiteProfile.data.user_id))" -ForegroundColor Green }
    } catch { Write-Host "  Token validation failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (-not $tokenValid) {
        Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue
        $AccessToken = Resolve-KiteAccessToken -ApiKey $API_Key -ApiSecret $API_Secret -TokenFilePath $tokenFile
        if (-not $AccessToken) { Write-Host '  Login failed.' -ForegroundColor Red; exit 1 }
        $headers['Authorization'] = "token ${API_Key}:${AccessToken}"
        try {
            $kiteProfile = Invoke-RestMethod 'https://api.kite.trade/user/profile' -Headers $headers -ErrorAction Stop
            Write-Host "  Logged in as: $($kiteProfile.data.user_name) ($($kiteProfile.data.user_id))" -ForegroundColor Green
        } catch { Write-Host '  ERROR: Token failed.' -ForegroundColor Red; exit 1 }
    }

    # ================================================================
    # Feed and option chain
    # ================================================================
    $sym = ([string]$TradingSymbol).ToUpper().Trim()
    if ($InstrumentToken -gt 0) { $instToken = $InstrumentToken; $label = $sym }
    else {
        $preset = Resolve-KiteSymbol $sym
        if ($preset) { $instToken = $preset.Token; $label = $preset.Label }
        else { Write-Host "  Unknown symbol: $TradingSymbol" -ForegroundColor Red; exit 1 }
    }
    $intSec = Get-IntervalSeconds $TimeFrame
    $intLabel = Get-IntervalLabel $intSec

    $IndexConfig = Get-IndexOptionConfig -IndexName $IndexChoosen -NoOfLots $LotsPerAdd
    if (-not $IndexConfig) { exit 1 }
    $exchange = $IndexConfig.exchange
    $optExchange = $IndexConfig.OptExchange
    $underlyingName = $IndexConfig.SearchKeyWord

    Write-Host "  Fetching $optExchange CE+PE instruments..." -ForegroundColor Yellow
    $ceData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'CE' -Headers $headers
    $peData = Get-KiteOptionInstruments -OptExchange $optExchange -UnderlyingName $underlyingName -OptionType 'PE' -Headers $headers
    if (-not $ceData -or -not $peData) { exit 1 }
    $ceOptions = $ceData.Options; $ceStrikes = $ceData.Strikes
    $peOptions = $peData.Options; $peStrikes = $peData.Strikes
    $nearestExpiry = $ceData.Expiry

    # Exchange lot size from the instrument list beats the hard-coded table.
    $ContractLot = [int]($ceOptions | Select-Object -First 1).LotSize
    if ($ContractLot -lt 1) { $ContractLot = [int]$IndexConfig.Lot }
    if ($ContractLot -ne [int]$IndexConfig.Lot) { Write-Host "  NOTE: exchange lot size $ContractLot differs from the module table ($($IndexConfig.Lot)); using $ContractLot." -ForegroundColor Yellow }
    Write-Host "  Expiry: $nearestExpiry | CE: $($ceStrikes.Count) strikes | PE: $($peStrikes.Count) strikes | Lot: $ContractLot" -ForegroundColor Green

    # ================================================================
    # State: load, reconcile with broker, seed candles
    # ================================================================
    $S = New-HAPState
    if (Test-Path $stateFile) {
        if ($CleanupPosition -eq 'yes') {
            Remove-Item $stateFile -Force
            Write-Host '  Saved state cleared (broker positions untouched).' -ForegroundColor Green
        } else {
            try { Import-HAPState }
            catch { Write-Host "  ERROR: $stateFile is unreadable ($($_.Exception.Message)). Fix it or run with -CleanupPosition yes." -ForegroundColor Red; exit 1 }
            if ($S.Side -ne '') {
                Write-Host "`n  Saved position: $($S.Side) | $($S.Symbol) | $($S.HeldLots) lot(s) | qty $($S.HeldQty)" -ForegroundColor Yellow
                if ($CleanupPosition -eq 'auto') {
                    $nonInteractive = try { [Console]::IsInputRedirected } catch { $true }
                    if ($nonInteractive) { Write-Host '  Non-interactive mode: resuming.' -ForegroundColor DarkGray }
                    elseif ((Read-Host '  Forget saved state and start fresh? (y/n)') -match '^(y|yes)$') {
                        Remove-Item $stateFile -Force
                        $S = New-HAPState
                        Write-Host '  Cleared (broker positions untouched).' -ForegroundColor Green
                    }
                }
            }
        }
    }
    Sync-HAPStartup
    if ($S.Side -ne '') { Write-Host "  Resuming: $($S.Side) | $($S.Symbol) | $($S.HeldLots)/$MaxLots lot(s) | qty $($S.HeldQty)" -ForegroundColor Yellow }

    $bucketNow = Get-HAStrategyTimeBucket $intSec
    $intoBucket = ([datetime]::Now - [datetime]::ParseExact($bucketNow, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)).TotalSeconds
    if (Test-HAPSwitchover $S.Side $S.UpdatedAt $S.AddedBucket $bucketNow) { $S.AddedBucket = $bucketNow }
    $histMap = @{ 'minute' = 'minute'; '3minute' = '3minute'; '5minute' = '5minute'; '10minute' = '10minute'; '15minute' = '15minute'; '30minute' = '30minute'; '60minute' = '60minute' }
    $formingSeeded = $false
    if ($TimeFrame -and $histMap.ContainsKey($TimeFrame)) {
        try {
            $chain = Build-HAPChain @(ConvertFrom-HAPHistorical (Get-HAPHistory -Token $instToken -Interval $histMap[$TimeFrame])) $bucketNow
            if ($chain.Candles.Count -ge 2) {
                $S.Candles = $chain.Candles; $S.PrevHA = $chain.PrevHA
                if ($chain.Forming) {
                    $f = $chain.Forming
                    $S.Active = @{ Bucket = $bucketNow; Open = $f.Open; High = $f.High; Low = $f.Low; Close = $f.Close; Ticks = 0; Partial = $false }
                    $formingSeeded = $true
                }
                $last = $S.Candles[$S.Candles.Count - 1]
                Write-Host "  History seeded: $($S.Candles.Count) candles, last $($last.Bucket) $($last.Colour)." -ForegroundColor Green
            } else { Write-Host '  History returned too few candles - running live-only.' -ForegroundColor Yellow }
        } catch { Write-Host "  History unavailable ($($_.Exception.Message)) - running live-only." -ForegroundColor Yellow }
    } else { Write-Host "  History seeding is not available for '$TimeFrame' - running live-only." -ForegroundColor Yellow }
    # A candle already under way that the bot did not see from its start is never acted on.
    if (-not $formingSeeded -and $intoBucket -gt 2) { $S.PartialBucket = $bucketNow }

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  HA POSITION TRADING v2 (running bar) | $(if ($DryRun) { 'DRY RUN - no orders are sent' } else { 'LIVE - real orders' })" -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  Feed    : $label | token $instToken | $TimeFrame ($intLabel)"
    Write-Host "  Sizing  : +$LotsPerAdd lot(s) per bar, max $MaxLots, contract lot $ContractLot, ATM offset $ATMOffset, $Product"
    Write-Host "  Window  : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss')) (adds only; exits always allowed)"
    Write-Host '  Connecting...' -ForegroundColor Yellow

    # ================================================================
    # WebSocket loop (1-second heartbeat drives candle close, decisions, stop time)
    # ================================================================
    $wsUri = "wss://ws.kite.trade?api_key=$API_Key&access_token=$AccessToken"
    $maxRetries = 3; $retryCount = 0; $buf = New-Object byte[] 65536

    while ($retryCount -le $maxRetries -and -not $S.Done) {
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.Options.SetRequestHeader('X-Kite-Version', '3')
        $cts = [System.Threading.CancellationTokenSource]::new()
        $recv = $null
        try {
            $ct = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
            if (-not $ct.Wait(15000) -or $ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw 'WebSocket connect failed or timed out.' }
            $retryCount = 0
            Write-Host '  Connected!' -ForegroundColor Green
            $subB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"subscribe","v":[' + $instToken + ']}')
            [void]$ws.SendAsync([System.ArraySegment[byte]]::new($subB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
            $modB = [System.Text.Encoding]::UTF8.GetBytes('{"a":"mode","v":["quote",[' + $instToken + ']]}')
            [void]$ws.SendAsync([System.ArraySegment[byte]]::new($modB), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
            Write-Host '  Subscribed. Waiting for ticks...' -ForegroundColor Green
            $seg = [System.ArraySegment[byte]]::new($buf)

            while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $S.Done) {
                $got = $false
                try {
                    # The next receive is only issued once the previous one completed.
                    if ($null -eq $recv) { $recv = $ws.ReceiveAsync($seg, $cts.Token) }
                    $got = $recv.Wait(1000)
                } catch {
                    $recv = $null
                    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
                    Start-Sleep -Milliseconds 200
                    continue
                }
                $res = $null
                if ($got) { $res = $recv.Result; $recv = $null }

                try {
                    $bucketNow = Get-HAStrategyTimeBucket $intSec
                    $closed = Update-HAPClock $S $bucketNow
                    if ($closed) {
                        $closed.Lots = if ($S.Side -ne '') { '{0} {1}/{2}' -f $S.Side, $S.HeldLots, $MaxLots } else { 'FLAT' }
                        $did = if ($closed.Action) { $closed.Action } else { 'no action' }
                        Write-HAPEvent ('bar {0} closed {1} | HA O {2:N2} C {3:N2} | {4} | {5}' -f $closed.Bucket.Substring(11), $closed.Colour, $closed.Open, $closed.Close, $did, $closed.Lots) 'Cyan'
                    }
                    if ($res) {
                        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { Write-Host '  Server closed the feed.' -ForegroundColor Yellow; break }
                        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                            if ($res.Count -gt 1) { try { $jm = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count) | ConvertFrom-Json; if ($jm.type -eq 'error') { Write-HAPEvent "Feed error: $($jm.data)" 'Red' } } catch { } }
                        } elseif ($res.Count -gt 2) {
                            foreach ($tick in (Parse-KiteTicks $buf $res.Count)) {
                                if ($tick.LastPrice -gt 0 -and $tick.InstrumentToken -eq $instToken) { Add-HAPTick $S $bucketNow $tick.LastPrice }
                            }
                        }
                    }
                    Invoke-HAPRunning
                    Test-HAPStop
                    Show-HAPDisplay
                } catch {
                    Write-HAPEvent "Loop error: $($_.Exception.Message)" 'Red'
                    Start-Sleep -Milliseconds 200
                }
            }
            if (-not $S.Done) {
                $retryCount++
                if ($retryCount -le $maxRetries) { $w = $retryCount * 5; Write-Host "  Reconnecting in ${w}s..." -ForegroundColor Yellow; Start-Sleep $w }
            }
        } catch {
            Write-Host "  Feed error: $($_.Exception.Message)" -ForegroundColor Red
            $retryCount++
            if ($retryCount -le $maxRetries) { $w = $retryCount * 5; Write-Host "  Retry in ${w}s..." -ForegroundColor Yellow; Start-Sleep $w }
        } finally {
            if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { try { [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done', $cts.Token).Wait(5000) } catch { } }
            if ($ws) { $ws.Dispose() }
            if ($cts) { $cts.Dispose() }
        }
    }

    Write-Host ''
    Write-Host '  Stopped.' -ForegroundColor Yellow
    Write-Host ("  Adds: {0} | Exits: {1} | Realized P&L (LTP based): {2:N2}" -f $S.Adds, $S.Exits, $S.TotalPnL) -ForegroundColor Gray
    if ($S.Side -ne '') { Write-Host "  WARNING: $($S.HeldLots) lot(s) of $($S.Symbol) are still OPEN. Restart the bot or square off manually." -ForegroundColor Red }
    Write-Host ''
}
finally {
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
