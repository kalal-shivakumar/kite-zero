<#
.SYNOPSIS
  Renko (ATR 14) pyramiding bot for index options: adds Lotsize lots per Renko brick, up to MaxLotSize.
.DESCRIPTION
  Period-close Renko, built the way TradingView, stocktrends and mplfinance build it:
    * Brick size = ATR(14) (Wilder) of the TimeFrame candles, taken when the day's chart is created and then fixed
      for the day. It is saved, so a restart keeps the same bricks. -BrickSize overrides it.
    * Bricks come from the CLOSES of closed candles only (no repainting). A close one brick above the top of the last
      brick makes an UP brick, one brick below its bottom a DOWN brick, a big jump makes several bricks, and a flip
      therefore needs 2 bricks from the last close (bricks never overlap).
    * Each brick is one signal: UP buys CE, DOWN buys PE, a candle close that completes N bricks adds N x Lotsize
      lots, never above MaxLotSize. The first brick against the open side sells the whole position and opens a fresh
      Lotsize position on the other side.
  The chain starts at the first closed candle of the trading day (no overnight gap bricks). Kite has no history for
  5/15/30-second, 2 and 4-minute candles: ATR then uses minute (or 3-minute) candles and the chain is live-only.
  Broker net quantity is the truth. PlacedOrders\HA-PositionTrading.json (shared with the Heikin-Ashi versions on
  purpose, so only one of them manages the position) remembers the contract, the last candle acted on and the day's
  brick size and chain.
.EXAMPLE
  .\Renko-Position-trading-v3.ps1 -DryRun
  .\Renko-Position-trading-v3.ps1 -TimeFrame 5minute -CleanupPosition yes
  .\Renko-Position-trading-v3.ps1 -BrickSize 40
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
    [double]$BrickSize,
    [int]$AtrPeriod = 14,
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
function ConvertTo-RNKBucket($Value) {
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) }
    $s = ([string]$Value) -replace 'T', ' '
    if ($s.Length -ge 19) { return $s.Substring(0, 19) }
    return $s
}

function ConvertTo-RNKDay($Value) {
    if ($null -eq $Value) { return '' }
    $t = ConvertTo-RNKBucket $Value
    if ($t.Length -ge 10) { return $t.Substring(0, 10) }
    return $t
}

function Get-RNKPrevBucket([string]$Bucket, [int]$IntervalSeconds) {
    $d = [datetime]::ParseExact($Bucket, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
    return $d.AddSeconds(-$IntervalSeconds).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
}

# Time only for today's candles, month-day plus time for older ones.
function Get-RNKLabel([string]$Bucket) {
    if ($Bucket.Length -lt 19) { return $Bucket }
    if ($Bucket.StartsWith((Get-Date).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture))) { return $Bucket.Substring(11) }
    return $Bucket.Substring(5)
}

function ConvertFrom-RNKHistorical($Candles) {
    foreach ($c in @($Candles)) {
        @{ Bucket = (ConvertTo-RNKBucket $c[0]); Open = [double]$c[1]; High = [double]$c[2]; Low = [double]$c[3]; Close = [double]$c[4] }
    }
}

# Candles older than the current bucket, oldest first. The history API also returns the candle still forming.
function Select-RNKClosed($Raw, [string]$CurrentBucket) {
    return , @(@($Raw) | Sort-Object { $_.Bucket } | Where-Object { [string]::CompareOrdinal($_.Bucket, $CurrentBucket) -lt 0 })
}

# Kite has no history for sub-minute, 2 and 4-minute candles: ATR then uses the nearest shorter interval it has.
function Get-RNKAtrInterval([string]$Frame) {
    switch ($Frame) {
        { $_ -in '5second', '15second', '30second', '2minute' } { return 'minute' }
        '4minute' { return '3minute' }
        default { return $Frame }
    }
}

# Wilder ATR as of the last candle: TR = max(H-L, |H-prevC|, |L-prevC|); first ATR = mean of the first Period TRs,
# then ATR = ((Period-1) x previous ATR + TR) / Period. Returns $null until Period candles exist.
function Get-RNKAtr {
    param($Candles, [int]$Period)
    $atr = $null; $sum = 0.0; $n = 0; $prevClose = $null
    foreach ($k in @($Candles)) {
        $tr = $k.High - $k.Low
        if ($null -ne $prevClose) { $tr = [Math]::Max($tr, [Math]::Max([Math]::Abs($k.High - $prevClose), [Math]::Abs($k.Low - $prevClose))) }
        $prevClose = $k.Close
        $n++
        if ($n -le $Period) {
            $sum += $tr
            if ($n -eq $Period) { $atr = $sum / $Period }
        } else { $atr = (($atr * ($Period - 1)) + $tr) / $Period }
    }
    return $atr
}

# What brick size to use today. A size saved earlier today for the same TimeFrame wins over a new ATR (fixed for the day).
function Get-RNKBrickPlan {
    param($Saved, [string]$Today, [string]$Frame, [double]$Manual)
    $sameDay = ($null -ne $Saved -and $Saved.Day -eq $Today -and $Saved.Tf -eq $Frame -and $Saved.Size -gt 0)
    if ($Manual -gt 0) {
        $size = [Math]::Round($Manual, 2)
        return @{ Size = $size; Source = 'MANUAL'; NeedAtr = $false; Reuse = ($sameDay -and [Math]::Abs($Saved.Size - $size) -lt 0.005); Fresh = $true }
    }
    if ($sameDay) {
        return @{ Size = [double]$Saved.Size; Source = $(if ($Saved.Source) { $Saved.Source } else { 'ATR' }); NeedAtr = $false; Reuse = $true; Fresh = $false }
    }
    return @{ Size = 0.0; Source = 'ATR'; NeedAtr = $true; Reuse = $false; Fresh = $true }
}

function New-RNKChain([double]$Size) {
    if ($Size -le 0) { throw "Brick size must be greater than 0 (got $Size)." }
    return @{ Size = [Math]::Round($Size, 2); Anchor = $null; Last = $null; Seq = 0 }
}

# Where the next brick forms. Before the first brick both levels are one brick away from the anchor (first close of the day).
function Get-RNKLevels([hashtable]$Chain) {
    $size = $Chain.Size
    $lb = $Chain.Last
    if ($null -ne $lb) {
        if ($lb.Dir -eq 'UP') { return @{ Up = [Math]::Round($lb.Close + $size, 2); Down = [Math]::Round($lb.Open - $size, 2) } }
        return @{ Up = [Math]::Round($lb.Open + $size, 2); Down = [Math]::Round($lb.Close - $size, 2) }
    }
    if ($null -ne $Chain.Anchor) { return @{ Up = [Math]::Round($Chain.Anchor + $size, 2); Down = [Math]::Round($Chain.Anchor - $size, 2) } }
    return $null
}

# Feeds one candle close into the chain and emits every brick it completes (all in one direction).
# Same rules as the stocktrends period-close algorithm: continue at last close +/- brick, reverse only one full brick
# beyond the opposite end of the last brick (2 bricks from its close).
function Add-RNKClose {
    param([hashtable]$Chain, [double]$Close, [string]$Bucket)
    $size = $Chain.Size
    $px = [Math]::Round($Close, 2)
    if ($null -eq $Chain.Last -and $null -eq $Chain.Anchor) { $Chain.Anchor = $px; return }
    while ($true) {
        $lv = Get-RNKLevels $Chain
        if ($px -ge $lv.Up) { $nb = @{ Dir = 'UP'; Open = [Math]::Round($lv.Up - $size, 2); Close = $lv.Up } }
        elseif ($px -le $lv.Down) { $nb = @{ Dir = 'DOWN'; Open = [Math]::Round($lv.Down + $size, 2); Close = $lv.Down } }
        else { return }
        $Chain.Seq++
        $nb.Seq = $Chain.Seq; $nb.Bucket = $Bucket; $nb.Action = ''; $nb.Lots = ''
        $Chain.Last = $nb
        $nb
    }
}

# Runs one closed candle through the chain and records the result on the candle.
function Step-RNKCandle {
    param([hashtable]$Chain, [hashtable]$Candle, $BrickList)
    $new = @(Add-RNKClose $Chain $Candle.Close $Candle.Bucket)
    $Candle.BrickCount = $new.Count
    if ($new.Count -gt 0) {
        $Candle.BrickDir = $new[-1].Dir
        $Candle.Brick = '{0} x{1}' -f $new[-1].Dir, $new.Count
        foreach ($nb in $new) { $BrickList.Add($nb) }
        while ($BrickList.Count -gt 200) { $BrickList.RemoveAt(0) }
    }
}

# Rebuilds today's chain from the closes of today's closed candles. Older candles are only kept for the display.
function Build-RNKDayChain {
    param($Raw, [string]$Today, [string]$CurrentBucket, [double]$Size)
    $chain = New-RNKChain $Size
    $done = [System.Collections.Generic.List[object]]::new()
    $bricks = [System.Collections.Generic.List[object]]::new()
    $forming = $null
    foreach ($r in (@($Raw) | Sort-Object { $_.Bucket })) {
        $cmp = [string]::CompareOrdinal($r.Bucket, $CurrentBucket)
        if ($cmp -ge 0) { if ($cmp -eq 0) { $forming = $r }; continue }
        $c = @{ Bucket = $r.Bucket; Open = $r.Open; High = $r.High; Low = $r.Low; Close = $r.Close; Partial = $false; Brick = '-'; BrickDir = ''; BrickCount = 0; Action = ''; Lots = '' }
        if ($r.Bucket.StartsWith($Today)) { Step-RNKCandle $chain $c $bricks }
        $done.Add($c)
    }
    return @{ Chain = $chain; Candles = $done; Bricks = $bricks; Forming = $forming }
}

# A restart acts only on bricks completed by the candle that just closed and not acted on yet; older bricks are history.
function Get-RNKStartupPending($Candles, [string]$PrevBucket, [string]$LastActed) {
    if (@($Candles).Count -eq 0) { return $null }
    $last = @($Candles)[-1]
    if ($last.Bucket -eq $PrevBucket -and $last.BrickCount -gt 0 -and [string]::CompareOrdinal($last.Bucket, $LastActed) -gt 0) {
        return @{ Bucket = $last.Bucket; Dir = $last.BrickDir; Bricks = $last.BrickCount }
    }
    return $null
}

# Live-only restart: continue the chain saved earlier today.
function Restore-RNKChain([hashtable]$Chain, $Saved) {
    if ($null -ne $Saved.Anchor) { $Chain.Anchor = [double]$Saved.Anchor }
    $Chain.Seq = [int]$Saved.Seq
    if ($Saved.Dir -eq 'UP' -or $Saved.Dir -eq 'DOWN') {
        $Chain.Last = @{ Seq = $Chain.Seq; Bucket = ''; Dir = [string]$Saved.Dir; Open = [double]$Saved.Open; Close = [double]$Saved.Close; Action = ''; Lots = '' }
    }
}

function New-RNKState {
    @{
        Active = $null; PartialBucket = ''
        Candles = [System.Collections.Generic.List[object]]::new()
        Bricks = [System.Collections.Generic.List[object]]::new()
        Chain = $null; Brick = $null; Saved = $null
        Pending = $null; Current = $null
        Side = ''; Symbol = ''; Token = 0; Strike = 0.0; HeldLots = 0; HeldQty = 0; AvgEntry = 0.0
        TotalPnL = 0.0; LastActedBucket = ''; Adds = 0; Exits = 0
        Events = [System.Collections.Generic.List[object]]::new()
        DryNet = @{}
        LastDraw = [datetime]::MinValue; ForceDraw = $true; CanClear = $true
        LastWarn = [datetime]::MinValue; RetryAfter = [datetime]::MinValue; Done = $false; StopNotice = $false
    }
}

# The whole strategy: what to do for the bricks one candle close completed. Always returns at least one step.
function Get-RNKDecision {
    param([string]$Dir, [int]$Bricks, [string]$HeldSide, [int]$HeldLots, [int]$LotsPerAdd, [int]$MaxLots, [bool]$InWindow)
    if ($Dir -ne 'UP' -and $Dir -ne 'DOWN') { return @(@{ Op = 'NONE'; Reason = 'NO_BRICK' }) }
    $want = if ($Dir -eq 'UP') { 'CE' } else { 'PE' }
    $steps = [System.Collections.Generic.List[object]]::new()
    if ($HeldSide -ne '' -and $HeldSide -ne $want) { $steps.Add(@{ Op = 'EXIT'; Side = $HeldSide }); $HeldLots = 0 }
    $room = $MaxLots - $HeldLots
    if ($room -le 0) { $steps.Add(@{ Op = 'HOLD'; Reason = 'MAX' }) }
    elseif (-not $InWindow) { $steps.Add(@{ Op = 'NONE'; Reason = 'OUT_OF_WINDOW' }) }
    else { $steps.Add(@{ Op = 'ADD'; Side = $want; Lots = [Math]::Min([Math]::Max(1, $Bricks) * $LotsPerAdd, $room) }) }
    return @($steps)
}

# Candle close is clock-driven so sparse ticks cannot delay a decision. The chain always advances (bricks are facts);
# a decision is only created for a complete candle that closed right now.
function Update-RNKClock {
    param([hashtable]$S, [string]$BucketNow, [int]$IntervalSeconds)
    $a = $S.Active
    if ($null -eq $a -or $a.Bucket -eq $BucketNow) { return $null }
    $c = @{ Bucket = $a.Bucket; Open = $a.Open; High = $a.High; Low = $a.Low; Close = $a.Close; Partial = [bool]$a.Partial; Brick = '-'; BrickDir = ''; BrickCount = 0; Action = ''; Lots = '' }
    $S.Active = $null
    Step-RNKCandle $S.Chain $c $S.Bricks
    $S.Candles.Add($c)
    while ($S.Candles.Count -gt 200) { $S.Candles.RemoveAt(0) }
    $result = @{ Closed = $c; Decision = $false; Superseded = ''; Skipped = '' }
    if ($c.BrickCount -eq 0) { return $result }
    if ($c.Partial) { $result.Skipped = 'PARTIAL' }
    elseif ($a.Bucket -ne (Get-RNKPrevBucket $BucketNow $IntervalSeconds)) { $result.Skipped = 'STALE' }
    else {
        if ($null -ne $S.Pending) { $result.Superseded = $S.Pending.Bucket }
        $S.Pending = @{ Bucket = $c.Bucket; Dir = $c.BrickDir; Bricks = $c.BrickCount }
        $result.Decision = $true
    }
    return $result
}

function Add-RNKTick {
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

# Decides the day's brick size and builds the chain. History is fetched through $GetHistory (called with an interval name)
# so the logic can be tested without the network. Returns Ok/Error/Notes; fills $S.
function Initialize-RNKChain {
    param(
        [hashtable]$S, [string]$Today, [string]$BucketNow, [string]$AtrBucketNow, [int]$IntervalSeconds, [string]$Frame,
        [double]$Manual, [int]$Period, [bool]$HasHistory, [scriptblock]$GetHistory
    )
    $notes = [System.Collections.Generic.List[object]]::new()
    $plan = Get-RNKBrickPlan -Saved $S.Saved -Today $Today -Frame $Frame -Manual $Manual
    $atrInterval = Get-RNKAtrInterval $Frame
    $tfRaw = $null
    if ($HasHistory) {
        try { $tfRaw = @(& $GetHistory $Frame) }
        catch { $notes.Add(@{ Text = "History unavailable ($($_.Exception.Message)) - running live-only."; Color = 'Yellow' }) }
    } else { $notes.Add(@{ Text = "History seeding is not available for '$Frame' - running live-only."; Color = 'Yellow' }) }

    $atrValue = 0.0; $atrCount = 0
    if ($plan.NeedAtr) {
        $atrRaw = $null
        if ($atrInterval -eq $Frame -and $tfRaw) { $atrRaw = $tfRaw }
        else {
            try { $atrRaw = @(& $GetHistory $atrInterval) }
            catch { return @{ Ok = $false; Error = "ATR history unavailable ($($_.Exception.Message)). Use -BrickSize to set the brick size yourself."; Notes = $notes; FormingSeeded = $false } }
        }
        $atrClosed = Select-RNKClosed $atrRaw $AtrBucketNow
        $atrValue = Get-RNKAtr $atrClosed $Period
        if ($null -eq $atrValue -or $atrValue -le 0) {
            return @{ Ok = $false; Error = "Only $(@($atrClosed).Count) closed $atrInterval candle(s): not enough for ATR($Period). Use -BrickSize to set the brick size yourself."; Notes = $notes; FormingSeeded = $false }
        }
        $atrCount = @($atrClosed).Count
        $plan.Size = [Math]::Round($atrValue, 2)
        if ($atrInterval -ne $Frame) { $notes.Add(@{ Text = "Kite has no $Frame history: ATR uses $atrInterval candles."; Color = 'Yellow' }) }
        $notes.Add(@{ Text = ('Brick size {0:N2} = ATR({1}) {2:N4} of {3} closed {4} candles (fixed for {5}).' -f $plan.Size, $Period, $atrValue, $atrCount, $atrInterval, $Today); Color = 'Green' })
    } elseif (-not $plan.Fresh) {
        $kind = if ($plan.Source -eq 'MANUAL') { 'manual -BrickSize' } else { "ATR($Period)" }
        $notes.Add(@{ Text = ('Brick size {0:N2} reused from the state saved earlier today ({1}).' -f $plan.Size, $kind); Color = 'Green' })
    } else {
        $notes.Add(@{ Text = ('Brick size {0:N2} (manual -BrickSize, fixed for {1}).' -f $plan.Size, $Today); Color = 'Green' })
    }
    if ($plan.Size -lt 0.05) {
        return @{ Ok = $false; Error = "Brick size $($plan.Size) is too small to trade."; Notes = $notes; FormingSeeded = $false }
    }
    $S.Brick = @{ Size = $plan.Size; Day = $Today; Tf = $Frame; Source = $plan.Source; AtrInterval = $atrInterval; AtrPeriod = $Period }

    $built = $null
    if ($tfRaw) {
        $built = Build-RNKDayChain $tfRaw $Today $BucketNow $plan.Size
        if ($built.Candles.Count -lt 1) { $built = $null; $notes.Add(@{ Text = 'History returned no candles - running live-only.'; Color = 'Yellow' }) }
    }
    $forming = $false
    if ($built) {
        $S.Chain = $built.Chain; $S.Candles = $built.Candles; $S.Bricks = $built.Bricks
        while ($S.Candles.Count -gt 200) { $S.Candles.RemoveAt(0) }
        if ($built.Forming) {
            $f = $built.Forming
            $S.Active = @{ Bucket = $BucketNow; Open = $f.Open; High = $f.High; Low = $f.Low; Close = $f.Close; Ticks = 0; Partial = $false }
            $forming = $true
        }
        $todays = @($built.Candles | Where-Object { $_.Bucket.StartsWith($Today) }).Count
        $lastBrick = $S.Chain.Last
        $tail = if ($lastBrick) { ('last brick #{0} {1} {2:N2} -> {3:N2}' -f $lastBrick.Seq, $lastBrick.Dir, $lastBrick.Open, $lastBrick.Close) } else { 'no brick yet' }
        $notes.Add(@{ Text = "Chain rebuilt from $todays closed candle(s) of today: $($S.Chain.Seq) brick(s), $tail."; Color = 'Green' })
        $pend = Get-RNKStartupPending $S.Candles (Get-RNKPrevBucket $BucketNow $IntervalSeconds) $S.LastActedBucket
        if ($pend) {
            $S.Pending = $pend
            $notes.Add(@{ Text = "The candle that just closed completed $($pend.Bricks) $($pend.Dir) brick(s) and was not acted on - acting now."; Color = 'Yellow' })
        }
    } else {
        $S.Chain = New-RNKChain $plan.Size
        if ($plan.Reuse -and $null -ne $S.Saved -and ($null -ne $S.Saved.Anchor -or $S.Saved.Dir)) {
            Restore-RNKChain $S.Chain $S.Saved
            $notes.Add(@{ Text = "Chain restored from the saved state ($($S.Chain.Seq) brick(s) so far)."; Color = 'Green' })
        } else { $notes.Add(@{ Text = 'New chain: it starts at the close of the next completed candle.'; Color = 'Yellow' }) }
    }
    $S.Saved = $null
    return @{ Ok = $true; Error = ''; Notes = $notes; FormingSeeded = $forming }
}

# ================================================================
# Logging, state file, broker access (use script-level config and $S)
# ================================================================
function Write-RNKEvent([string]$Text, [string]$Color = 'Gray') {
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text
    $S.Events.Add(@{ Text = $line; Color = $Color })
    while ($S.Events.Count -gt 50) { $S.Events.RemoveAt(0) }
    $S.ForceDraw = $true
    Write-Host "  $line" -ForegroundColor $Color
}

function Write-RNKAudit {
    param([string]$Action, [string]$Symbol = '', $ReqQty = '', $Before = '', $After = '', [string]$Result = '', [string]$Note = '')
    try {
        if (-not (Test-Path $auditFile)) { 'time,candle,colour,action,symbol,reqQty,beforeNet,afterNet,result,note' | Set-Content -Path $auditFile }
        $cur = $S.Current
        $candle = if ($cur) { $cur.Bucket } else { '-' }
        $dirText = if ($cur) { $cur.Dir } else { '-' }
        $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f (Get-Date).ToString('HH:mm:ss'), $candle, $dirText, $Action, $Symbol, $ReqQty, $Before, $After, $Result, ($Note -replace ',', ';')
        Add-Content -Path $auditFile -Value $line
    } catch { }  # an unwritable log must never stop trading
}

# Brick size and chain, kept next to the position so a restart reuses the same bricks.
function Get-RNKBrickKeys {
    $k = [ordered]@{}
    if ($S.Brick -and $S.Chain) {
        $k['BrickSize'] = $S.Brick.Size; $k['BrickDay'] = $S.Brick.Day; $k['BrickTf'] = $S.Brick.Tf
        $k['BrickSource'] = $S.Brick.Source; $k['BrickAtrInterval'] = $S.Brick.AtrInterval; $k['BrickAtrPeriod'] = $S.Brick.AtrPeriod
        $k['BrickAnchor'] = $S.Chain.Anchor; $k['BrickSeq'] = $S.Chain.Seq
        $lb = $S.Chain.Last
        if ($lb) { $k['BrickDir'] = $lb.Dir; $k['BrickOpen'] = $lb.Open; $k['BrickClose'] = $lb.Close }
    } elseif ($S.Saved) {
        $sv = $S.Saved
        $k['BrickSize'] = $sv.Size; $k['BrickDay'] = $sv.Day; $k['BrickTf'] = $sv.Tf
        $k['BrickSource'] = $sv.Source; $k['BrickAtrInterval'] = $sv.AtrInterval; $k['BrickAtrPeriod'] = $sv.AtrPeriod
        $k['BrickAnchor'] = $sv.Anchor; $k['BrickSeq'] = $sv.Seq
        if ($sv.Dir) { $k['BrickDir'] = $sv.Dir; $k['BrickOpen'] = $sv.Open; $k['BrickClose'] = $sv.Close }
    }
    return $k
}

function Save-RNKState {
    $o = [ordered]@{
        Side = $S.Side; Symbol = $S.Symbol; Token = $S.Token; Strike = $S.Strike
        HeldLots = $S.HeldLots; HeldQty = $S.HeldQty; AvgEntry = $S.AvgEntry
        TotalPnL = $S.TotalPnL; LastActedBucket = $S.LastActedBucket
        UpdatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
    }
    $bk = Get-RNKBrickKeys
    foreach ($key in $bk.Keys) { $o[$key] = $bk[$key] }
    if ($DryRun) { $o['DryNet'] = $S.DryNet }
    $tmp = "$stateFile.tmp"
    ($o | ConvertTo-Json) | Set-Content -Path $tmp -Force
    Move-Item -Path $tmp -Destination $stateFile -Force
}

function Import-RNKState {
    $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
    $S.Side = [string]$saved.Side; $S.Symbol = [string]$saved.Symbol; $S.Token = [long]$saved.Token; $S.Strike = [double]$saved.Strike
    $S.HeldLots = [int]$saved.HeldLots; $S.HeldQty = [int]$saved.HeldQty; $S.AvgEntry = [double]$saved.AvgEntry
    $S.TotalPnL = [double]$saved.TotalPnL; $S.LastActedBucket = ConvertTo-RNKBucket $saved.LastActedBucket
    if ($DryRun -and $saved.DryNet) { foreach ($p in $saved.DryNet.PSObject.Properties) { $S.DryNet[$p.Name] = [int]$p.Value } }
    $S.Saved = $null
    if ([double]($saved.BrickSize ?? 0) -gt 0) {
        $S.Saved = @{
            Size = [double]$saved.BrickSize; Day = (ConvertTo-RNKDay $saved.BrickDay); Tf = [string]$saved.BrickTf
            Source = [string]$saved.BrickSource; AtrInterval = [string]$saved.BrickAtrInterval; AtrPeriod = [int]($saved.BrickAtrPeriod ?? 0)
            Anchor = $(if ($null -ne $saved.BrickAnchor) { [double]$saved.BrickAnchor } else { $null })
            Seq = [int]($saved.BrickSeq ?? 0)
            Dir = [string]$saved.BrickDir; Open = [double]($saved.BrickOpen ?? 0); Close = [double]($saved.BrickClose ?? 0)
        }
    }
}

function Reset-RNKPosition {
    $S.Side = ''; $S.Symbol = ''; $S.Token = 0; $S.Strike = 0.0
    $S.HeldLots = 0; $S.HeldQty = 0; $S.AvgEntry = 0.0
}

function Test-RNKInWindow {
    $t = [datetime]::Now.TimeOfDay
    return ($t -ge $StartTime.TimeOfDay -and $t -le $StopTime.TimeOfDay)
}

# ,@() keeps an empty list distinct from $null (= read failure)
function Get-RNKPositions {
    try { $resp = Invoke-RestMethod 'https://api.kite.trade/portfolio/positions' -Headers $headers -Method Get -ErrorAction Stop }
    catch { return $null }
    if ($null -eq $resp -or $null -eq $resp.data) { return $null }
    return , @($resp.data.net | Where-Object { $_ })
}

function Get-RNKNetFrom($Positions, [string]$Symbol, [string]$ProductType) {
    $rows = @($Positions | Where-Object { $_.tradingsymbol -eq $Symbol -and $_.product -eq $ProductType })
    if ($rows.Count -eq 0) { return 0 }
    return [int](($rows | Measure-Object -Property quantity -Sum).Sum)
}

function Get-RNKNet([string]$Symbol) {
    if ($DryRun) { return [int]($S.DryNet[$Symbol] ?? 0) }
    $pos = Get-RNKPositions
    if ($null -eq $pos) { return $null }
    return Get-RNKNetFrom $pos $Symbol $Product
}

function Get-RNKOptLTP([string]$Symbol) {
    try {
        $r = Invoke-RestMethod "https://api.kite.trade/quote/ltp?i=$([uri]::EscapeDataString("${optExchange}:$Symbol"))" -Headers $headers -ErrorAction Stop
        foreach ($p in $r.data.PSObject.Properties) { return [double]$p.Value.last_price }
    } catch { }
    return 0.0
}

function Send-RNKOrder([string]$Type, [string]$Symbol, [int]$Qty, [string]$Tag) {
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
function Wait-RNKNet {
    param([string]$Symbol, [int]$Target, [ValidateSet('GE', 'LE')][string]$Cmp)
    $last = $null
    for ($i = 0; $i -lt 10; $i++) {
        $n = Get-RNKNet $Symbol
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
function Invoke-RNKExit {
    $sym = $S.Symbol; $side = $S.Side
    $before = Get-RNKNet $sym
    if ($null -eq $before) { return 'RETRY' }
    if ($before -le 0) {
        Write-RNKAudit 'EXIT' $sym 0 $before $before 'ALREADY_FLAT'
        Reset-RNKPosition; Save-RNKState
        return 'OK'
    }
    if ($DryRun) { Write-RNKEvent "DRY: would cancel resting stop-loss orders on $sym" 'DarkGray' }
    else {
        try { [void](Cancel-AllStopLosses -TrendEntrySelection ([regex]::Escape($sym)) -Headers $headers) }
        catch { Write-RNKEvent "Stop-loss cancel failed: $($_.Exception.Message)" 'Red' }
    }
    $ltp = Get-RNKOptLTP $sym
    if (-not (Send-RNKOrder 'SELL' $sym $before "RNK${side}EXIT")) {
        Write-RNKAudit 'EXIT' $sym $before $before $before 'FAIL' 'order not accepted'
        Write-RNKEvent "EXIT $side $sym x$before FAILED - order not accepted" 'Red'
        return 'FAILED'
    }
    $w = Wait-RNKNet $sym 0 'LE'
    if ($w.Ok) {
        $pnl = if ($ltp -gt 0 -and $S.AvgEntry -gt 0) { ($ltp - $S.AvgEntry) * $before } else { 0.0 }
        $S.TotalPnL += $pnl
        $S.Exits++
        Write-RNKAudit 'EXIT' $sym $before $before $w.Net 'CONFIRMED' ('pnl~{0:N2}' -f $pnl)
        Write-RNKEvent ('EXIT {0} {1} x{2} CONFIRMED | approx P&L {3:N2} | total {4:N2}' -f $side, $sym, $before, $pnl, $S.TotalPnL) 'Magenta'
        Reset-RNKPosition; Save-RNKState
        return 'OK'
    }
    if ($null -ne $w.Net -and $w.Net -gt 0) { $S.HeldQty = $w.Net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($w.Net / $ContractLot)) }
    Write-RNKAudit 'EXIT' $sym $before $before $w.Net 'NOT_CONFIRMED'
    Write-RNKEvent "EXIT $side $sym NOT confirmed (broker net $($w.Net)) - no reversal this candle" 'Red'
    Save-RNKState
    return 'FAILED'
}

function Invoke-RNKAdd([string]$Side, [int]$Lots) {
    $isNew = ($S.Side -eq '')
    if ($isNew) {
        $spot = Get-KiteSpotPrice -SpotQuoteKey $IndexConfig.SpotQuoteKey -Headers $headers
        if ($spot -le 0) { return 'RETRY' }
        $opts = if ($Side -eq 'CE') { $ceOptions } else { $peOptions }
        $strikes = if ($Side -eq 'CE') { $ceStrikes } else { $peStrikes }
        $offset = if ($Side -eq 'CE') { -$ATMOffset } else { $ATMOffset }
        $opt = Get-ATMOption -SpotPrice $spot -Options $opts -AllStrikes $strikes -Offset $offset
        if (-not $opt) {
            Write-RNKAudit 'ADD' '' '' '' '' 'FAIL' 'no ATM contract'
            Write-RNKEvent "ADD $Side FAILED - no ATM contract found" 'Red'
            return 'FAILED'
        }
        $sym = $opt.Symbol; $tok = $opt.Token; $strike = $opt.Strike
    } else {
        $sym = $S.Symbol; $tok = $S.Token; $strike = $S.Strike
    }
    $qty = $Lots * $ContractLot
    $before = Get-RNKNet $sym
    if ($null -eq $before) { return 'RETRY' }
    if ($isNew -and $before -gt 0) {
        Write-RNKAudit 'ADD' $sym $qty $before $before 'BLOCKED' 'symbol already held outside the bot'
        Write-RNKEvent "ADD $Side $sym BLOCKED - broker already holds $before outside this bot" 'Red'
        return 'FAILED'
    }
    $ltp = Get-RNKOptLTP $sym
    if (-not (Send-RNKOrder 'BUY' $sym $qty "RNK${Side}ADD")) {
        Write-RNKAudit 'ADD' $sym $qty $before $before 'FAIL' 'order not accepted'
        Write-RNKEvent "ADD $Side $sym x$qty FAILED - order not accepted" 'Red'
        return 'FAILED'
    }
    $w = Wait-RNKNet $sym ($before + $qty) 'GE'
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
    Write-RNKAudit 'ADD' $sym $qty $before $after $res ('ltp~{0}' -f $ltp)
    $color = if ($w.Ok) { 'Green' } else { 'Red' }
    Write-RNKEvent ('ADD {0} {1} +{2} lot(s) {3} | net {4}->{5} | now {6}/{7} lots | avg {8:N2}' -f $Side, $sym, $Lots, $res, $before, $after, $S.HeldLots, $MaxLots, $S.AvgEntry) $color
    Save-RNKState
    return $(if ($w.Ok) { 'OK' } else { 'FAILED' })
}

# Shows what the bot did on the candle and on the bricks it completed.
function Set-RNKCandleNote([string]$Bucket, $Notes) {
    $text = $Notes -join ', '
    $lots = if ($S.Side -ne '') { '{0} {1}/{2}' -f $S.Side, $S.HeldLots, $MaxLots } else { 'FLAT' }
    $cd = $S.Candles | Where-Object { $_.Bucket -eq $Bucket } | Select-Object -Last 1
    if ($cd) { $cd.Action = $text; $cd.Lots = $lots }
    foreach ($br in @($S.Bricks | Where-Object { $_.Bucket -eq $Bucket })) { $br.Action = $text; $br.Lots = $lots }
}

# Only for failures where no order was sent; once an order may be out, the candle is never retried.
function Set-RNKRetry([string]$Why) {
    $S.RetryAfter = [datetime]::Now.AddSeconds(3)
    if (([datetime]::Now - $S.LastWarn).TotalSeconds -ge 10) {
        $S.LastWarn = [datetime]::Now
        Write-RNKEvent "$Why - decision stays pending and will be retried" 'Yellow'
    }
}

function Invoke-RNKPending {
    $p = $S.Pending
    if ($null -eq $p -or [datetime]::Now -lt $S.RetryAfter) { return }
    $S.Current = $p
    try {
        if ($S.Side -ne '') {
            $net = Get-RNKNet $S.Symbol
            if ($null -eq $net) { Set-RNKRetry 'Broker positions unreadable'; return }
            if ($net -le 0) {
                Write-RNKAudit 'RESET' $S.Symbol '' $S.HeldQty 0 'POSITION_GONE' 'not held at broker; treated as flat'
                Write-RNKEvent "$($S.Symbol) is no longer held at the broker - treating as flat" 'Yellow'
                Reset-RNKPosition
            } else {
                $S.HeldQty = $net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($net / $ContractLot))
            }
        }

        # Persist before ordering so a crash can skip an add but never repeat one.
        $oldActed = $S.LastActedBucket
        $S.Pending = $null; $S.LastActedBucket = $p.Bucket
        try { Save-RNKState }
        catch {
            $S.Pending = $p; $S.LastActedBucket = $oldActed
            Set-RNKRetry "State file not writable ($($_.Exception.Message))"
            return
        }

        $held = if ($S.Side -ne '') { $S.HeldLots } else { 0 }
        $steps = @(Get-RNKDecision -Dir $p.Dir -Bricks $p.Bricks -HeldSide $S.Side -HeldLots $held -LotsPerAdd $LotsPerAdd -MaxLots $MaxLots -InWindow (Test-RNKInWindow))
        $retry = ''
        $notes = [System.Collections.Generic.List[string]]::new()
        foreach ($st in $steps) {
            if ($st.Op -eq 'EXIT') {
                $exitSide = $S.Side
                $r = Invoke-RNKExit
                if ($r -eq 'OK') { $notes.Add("EXIT $exitSide") }
                else {
                    if ($r -eq 'RETRY') { $retry = 'exit' } else { $notes.Add("EXIT $exitSide FAILED") }
                    break
                }
            }
            elseif ($st.Op -eq 'ADD') {
                $r = Invoke-RNKAdd $st.Side $st.Lots
                if ($r -eq 'OK') { $notes.Add("ADD $($st.Side) +$($st.Lots)") }
                elseif ($r -eq 'RETRY') { $retry = 'add' }
                else { $notes.Add("ADD $($st.Side) FAILED") }
            }
            else {
                $notes.Add("$($st.Op) $($st.Reason)")
                Write-RNKAudit $st.Op $S.Symbol '' $held $held $st.Reason
                Write-RNKEvent ('{0} {1} x{2} -> {3} ({4})' -f $p.Bucket.Substring(11), $p.Dir, $p.Bricks, $st.Op, $st.Reason) 'DarkGray'
            }
        }
        if ($retry) {
            $S.Pending = $p; $S.LastActedBucket = $oldActed
            Set-RNKRetry "Broker data unavailable for the $retry"
        } else { Set-RNKCandleNote $p.Bucket $notes }
    } finally { $S.Current = $null }
}

function Test-RNKStop {
    if ([datetime]::Now.TimeOfDay -le $StopTime.TimeOfDay) { return }
    if ($S.Side -eq '' -and $null -eq $S.Pending) {
        Write-RNKEvent 'Stop time reached and no open position - stopping.' 'Yellow'
        $S.Done = $true
    } elseif (-not $S.StopNotice) {
        $S.StopNotice = $true
        Write-RNKEvent "Stop time reached - no new lots; holding $($S.HeldLots) lot(s) until a brick on the other side exits." 'Yellow'
    }
}

# ================================================================
# Startup helpers
# ================================================================
function Enter-RNKLock {
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

function Get-RNKHistory {
    param([long]$Token, [string]$Interval)
    $fmt = 'yyyy-MM-dd+HH:mm:ss'
    $to = (Get-Date).ToString($fmt, [cultureinfo]::InvariantCulture)
    $from = (Get-Date).AddDays(-10).ToString($fmt, [cultureinfo]::InvariantCulture)
    $resp = Invoke-RestMethod "https://api.kite.trade/instruments/historical/$Token/${Interval}?from=$from&to=$to" -Headers $headers -Method Get -ErrorAction Stop
    return , @($resp.data.candles)
}

# Broker net quantity wins over the saved state on any mismatch.
function Sync-RNKStartup {
    if ($DryRun) {
        if ($S.Side -ne '') {
            $net = [int]($S.DryNet[$S.Symbol] ?? 0)
            if ($net -le 0) { Write-Host "  Dry-run ledger shows $($S.Symbol) flat - state reset." -ForegroundColor Yellow; Reset-RNKPosition; Save-RNKState }
            else { $S.HeldQty = $net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($net / $ContractLot)) }
        }
        return
    }
    $pos = $null
    for ($i = 0; $i -lt 3 -and $null -eq $pos; $i++) { $pos = Get-RNKPositions; if ($null -eq $pos) { Start-Sleep -Milliseconds 500 } }
    if ($null -eq $pos) { Write-Host '  ERROR: cannot read broker positions - not starting blind.' -ForegroundColor Red; exit 1 }
    if ($S.Side -ne '') {
        $net = Get-RNKNetFrom $pos $S.Symbol $Product
        if ($net -le 0) {
            Write-Host "  Saved $($S.Side) $($S.Symbol) is not held at the broker - state reset to flat." -ForegroundColor Yellow
            Reset-RNKPosition; Save-RNKState
        } else {
            if ($net -ne $S.HeldQty) { Write-Host "  Saved qty $($S.HeldQty) differs from broker $net - using broker." -ForegroundColor Yellow }
            $S.HeldQty = $net; $S.HeldLots = [Math]::Max(1, [int][Math]::Floor($net / $ContractLot))
        }
    } else {
        $un = @($pos | Where-Object { $_.quantity -ne 0 -and $_.tradingsymbol -like "$underlyingName*" -and $_.tradingsymbol -match '(CE|PE)$' })
        foreach ($u in $un) { Write-Host "  WARNING: unmanaged position $($u.tradingsymbol) qty $($u.quantity) - this bot will not trade or exit it." -ForegroundColor Yellow }
    }
}

function Show-RNKDisplay {
    $now = [datetime]::Now
    if (-not $S.ForceDraw -and ($now - $S.LastDraw).TotalMilliseconds -lt 1000) { return }
    $S.LastDraw = $now; $S.ForceDraw = $false
    if ($S.CanClear) { try { Clear-Host } catch { $S.CanClear = $false } }

    $modeText = if ($DryRun) { 'DRY RUN - no orders are sent' } else { 'LIVE - real orders' }
    $bk = $S.Brick
    $sizeSrc = if ($bk.Source -eq 'MANUAL') { 'manual -BrickSize' } else { "ATR($($bk.AtrPeriod)) of $($bk.AtrInterval) candles" }
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  RENKO POSITION TRADING v3 | $label | $modeText" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Cyan' })
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  Feed     : token $instToken | $TimeFrame ($intLabel) | Expiry $nearestExpiry"
    Write-Host ('  Renko    : brick {0:N2} pts = {1} | fixed for {2} | flip needs 2 bricks' -f $bk.Size, $sizeSrc, $bk.Day)
    Write-Host "  Sizing   : add $LotsPerAdd lot(s) per brick | max $MaxLots | contract lot $ContractLot | ATM offset $ATMOffset | $Product"
    $winText = if (Test-RNKInWindow) { 'in window' } else { 'OUT of window - exits only' }
    Write-Host "  Window   : $($StartTime.ToString('HH:mm:ss')) - $($StopTime.ToString('HH:mm:ss')) | now $($now.ToString('HH:mm:ss')) ($winText)"
    if ($S.Side -ne '') {
        Write-Host ('  LOTS RUNNING : {0} {1} of {2} lots | qty {3} | {4} | avg {5:N2}' -f $S.Side, $S.HeldLots, $MaxLots, $S.HeldQty, $S.Symbol, $S.AvgEntry) -ForegroundColor Green
    } else {
        Write-Host '  LOTS RUNNING : none (FLAT)' -ForegroundColor Gray
    }
    Write-Host ('  Realized P&L : {0:N2} (LTP based) | adds {1} | exits {2}' -f $S.TotalPnL, $S.Adds, $S.Exits)

    $lv = Get-RNKLevels $S.Chain
    $lb = $S.Chain.Last
    if ($lb) {
        $when = if ($lb.Bucket) { " (formed $(Get-RNKLabel $lb.Bucket))" } else { '' }
        Write-Host ('  Last brick   : #{0} {1} {2:N2} -> {3:N2}{4} | next UP: close >= {5:N2} | next DOWN: close <= {6:N2}' -f $lb.Seq, $lb.Dir, $lb.Open, $lb.Close, $when, $lv.Up, $lv.Down) -ForegroundColor $(if ($lb.Dir -eq 'UP') { 'Green' } else { 'Red' })
    } elseif ($lv) {
        Write-Host ('  Last brick   : none yet | anchor {0:N2} | UP brick: close >= {1:N2} | DOWN brick: close <= {2:N2}' -f $S.Chain.Anchor, $lv.Up, $lv.Down) -ForegroundColor Gray
    } else {
        Write-Host '  Last brick   : none yet | the chain starts at the close of the next completed candle' -ForegroundColor Gray
    }

    $fmt = ' {0,-14} {1,10} {2,10} {3,10} {4,10}  {5,-9} {6,-26} {7}'
    Write-Host ''
    Write-Host ($fmt -f 'Candle', 'Open', 'High', 'Low', 'Close', 'Brick', 'Action', 'Lots running') -ForegroundColor Cyan
    foreach ($cd in @($S.Candles | Select-Object -Last $CandlesToShow)) {
        $tag = if ($cd.Partial) { "$($cd.Brick) ~" } else { $cd.Brick }
        $rowColor = switch ($cd.BrickDir) { 'UP' { 'Green' } 'DOWN' { 'Red' } default { 'Gray' } }
        $act = if ($cd.Action) { [string]$cd.Action } else { '-' }
        if ($act.Length -gt 26) { $act = $act.Substring(0, 26) }
        $lots = if ($cd.Lots) { $cd.Lots } else { '-' }
        Write-Host ($fmt -f (Get-RNKLabel $cd.Bucket), ('{0:N2}' -f $cd.Open), ('{0:N2}' -f $cd.High), ('{0:N2}' -f $cd.Low), ('{0:N2}' -f $cd.Close), $tag, $act, $lots) -ForegroundColor $rowColor
    }
    if ($S.Active) {
        $fc = $S.Active
        $nowLots = if ($S.Side -ne '') { '{0} {1}/{2}' -f $S.Side, $S.HeldLots, $MaxLots } else { 'FLAT' }
        Write-Host ($fmt -f "$(Get-RNKLabel $fc.Bucket)*", ('{0:N2}' -f $fc.Open), ('{0:N2}' -f $fc.High), ('{0:N2}' -f $fc.Low), ('{0:N2}' -f $fc.Close), '(forming)', 'forming', $nowLots) -ForegroundColor Yellow
    }

    if ($S.Bricks.Count -gt 0) {
        $bf = ' {0,-6} {1,-14} {2,-6} {3,11} {4,11}  {5,-26} {6}'
        Write-Host ''
        Write-Host ($bf -f 'Brick', 'Formed', 'Dir', 'From', 'To', 'Action', 'Lots running') -ForegroundColor Cyan
        foreach ($br in @($S.Bricks | Select-Object -Last 6)) {
            $rowColor = if ($br.Dir -eq 'UP') { 'Green' } else { 'Red' }
            $act = if ($br.Action) { [string]$br.Action } else { '-' }
            if ($act.Length -gt 26) { $act = $act.Substring(0, 26) }
            $lots = if ($br.Lots) { $br.Lots } else { '-' }
            Write-Host ($bf -f ('#' + $br.Seq), (Get-RNKLabel $br.Bucket), $br.Dir, ('{0:N2}' -f $br.Open), ('{0:N2}' -f $br.Close), $act, $lots) -ForegroundColor $rowColor
        }
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
if ($PSBoundParameters.ContainsKey('BrickSize') -and $BrickSize -lt 0.05) { $cfgErrors.Add("BrickSize must be at least 0.05 points (got '$BrickSize'); leave it out to use ATR.") }
if ($AtrPeriod -lt 2 -or $AtrPeriod -gt 100) { $cfgErrors.Add("AtrPeriod must be between 2 and 100 (got '$AtrPeriod').") }
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

Enter-RNKLock
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
    # State: load, reconcile with broker
    # ================================================================
    $S = New-RNKState
    if (Test-Path $stateFile) {
        if ($CleanupPosition -eq 'yes') {
            Remove-Item $stateFile -Force
            Write-Host '  Saved state cleared (broker positions untouched).' -ForegroundColor Green
        } else {
            try { Import-RNKState }
            catch { Write-Host "  ERROR: $stateFile is unreadable ($($_.Exception.Message)). Fix it or run with -CleanupPosition yes." -ForegroundColor Red; exit 1 }
            if ($S.Side -ne '') {
                Write-Host "`n  Saved position: $($S.Side) | $($S.Symbol) | $($S.HeldLots) lot(s) | qty $($S.HeldQty)" -ForegroundColor Yellow
                if ($CleanupPosition -eq 'auto') {
                    $nonInteractive = try { [Console]::IsInputRedirected } catch { $true }
                    if ($nonInteractive) { Write-Host '  Non-interactive mode: resuming.' -ForegroundColor DarkGray }
                    elseif ((Read-Host '  Forget saved state and start fresh? (y/n)') -match '^(y|yes)$') {
                        Remove-Item $stateFile -Force
                        $S = New-RNKState
                        Write-Host '  Cleared (broker positions untouched).' -ForegroundColor Green
                    }
                }
            }
        }
    }
    Sync-RNKStartup
    if ($S.Side -ne '') { Write-Host "  Resuming: $($S.Side) | $($S.Symbol) | $($S.HeldLots)/$MaxLots lot(s) | qty $($S.HeldQty)" -ForegroundColor Yellow }

    # ================================================================
    # Brick size and today's chain
    # ================================================================
    $today = (Get-Date).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $bucketNow = Get-HAStrategyTimeBucket $intSec
    $intoBucket = ([datetime]::Now - [datetime]::ParseExact($bucketNow, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)).TotalSeconds
    $histMap = @{ 'minute' = 'minute'; '3minute' = '3minute'; '5minute' = '5minute'; '10minute' = '10minute'; '15minute' = '15minute'; '30minute' = '30minute'; '60minute' = '60minute' }
    $atrInterval = Get-RNKAtrInterval $TimeFrame
    $atrBucketNow = if ($atrInterval -eq $TimeFrame) { $bucketNow } else { Get-HAStrategyTimeBucket (Get-IntervalSeconds $atrInterval) }
    $manualBrick = if ($PSBoundParameters.ContainsKey('BrickSize')) { $BrickSize } else { 0.0 }
    $historyFetcher = { param($iv) @(ConvertFrom-RNKHistorical (Get-RNKHistory -Token $instToken -Interval $iv)) }
    $init = Initialize-RNKChain -S $S -Today $today -BucketNow $bucketNow -AtrBucketNow $atrBucketNow -IntervalSeconds $intSec -Frame $TimeFrame `
        -Manual $manualBrick -Period $AtrPeriod -HasHistory ([bool]($TimeFrame -and $histMap.ContainsKey($TimeFrame))) -GetHistory $historyFetcher
    foreach ($note in $init.Notes) { Write-Host "  $($note.Text)" -ForegroundColor $note.Color }
    if (-not $init.Ok) { Write-Host "  ERROR: $($init.Error)" -ForegroundColor Red; exit 1 }
    # A candle already under way that the bot did not see from its start is never acted on.
    if (-not $init.FormingSeeded -and $intoBucket -gt 2) { $S.PartialBucket = $bucketNow }
    try { Save-RNKState }
    catch { Write-Host "  ERROR: state file not writable ($($_.Exception.Message)) - not starting without it." -ForegroundColor Red; exit 1 }

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  RENKO POSITION TRADING v3 | $(if ($DryRun) { 'DRY RUN - no orders are sent' } else { 'LIVE - real orders' })" -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host "  Feed    : $label | token $instToken | $TimeFrame ($intLabel)"
    Write-Host ("  Renko   : brick {0:N2} pts ({1}), flip needs 2 bricks, bricks from closed {2} candles" -f $S.Brick.Size, $(if ($S.Brick.Source -eq 'MANUAL') { 'manual' } else { "ATR $AtrPeriod of $atrInterval candles" }), $TimeFrame)
    Write-Host "  Sizing  : +$LotsPerAdd lot(s) per brick, max $MaxLots, contract lot $ContractLot, ATM offset $ATMOffset, $Product"
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
                    $closed = Update-RNKClock $S $bucketNow $intSec
                    if ($closed) {
                        $cc = $closed.Closed
                        $brickText = if ($cc.BrickCount -gt 0) { 'brick {0} x{1}' -f $cc.BrickDir, $cc.BrickCount } else { 'no new brick' }
                        $note = if ($closed.Skipped) { "no decision ($($closed.Skipped))" } elseif ($closed.Decision) { 'decision pending' } else { '' }
                        if ($closed.Superseded) { $note += "; superseded unexecuted decision for $($closed.Superseded)" }
                        Write-RNKEvent ('candle {0} closed {1:N2} | {2}{3}' -f $cc.Bucket.Substring(11), $cc.Close, $brickText, $(if ($note) { " | $note" } else { '' })) 'Cyan'
                        if ($cc.BrickCount -gt 0) { try { Save-RNKState } catch { } }  # keep the chain current even when no decision follows
                    }
                    if ($res) {
                        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { Write-Host '  Server closed the feed.' -ForegroundColor Yellow; break }
                        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                            if ($res.Count -gt 1) { try { $jm = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count) | ConvertFrom-Json; if ($jm.type -eq 'error') { Write-RNKEvent "Feed error: $($jm.data)" 'Red' } } catch { } }
                        } elseif ($res.Count -gt 2) {
                            foreach ($tick in (Parse-KiteTicks $buf $res.Count)) {
                                if ($tick.LastPrice -gt 0 -and $tick.InstrumentToken -eq $instToken) { Add-RNKTick $S $bucketNow $tick.LastPrice }
                            }
                        }
                    }
                    Invoke-RNKPending
                    Test-RNKStop
                    Show-RNKDisplay
                } catch {
                    Write-RNKEvent "Loop error: $($_.Exception.Message)" 'Red'
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
