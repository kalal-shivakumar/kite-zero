param(
    [string[]]$Days = @('2026-07-24','2026-07-27'),
    [string[]]$TimeFrames = @('minute','3minute'),
    [string[]]$Instruments,
    [int]$SLLookback = 1,
    [string]$EntryStartTime,
    [string]$EntryStopTime,
    [string]$MarketCloseTime
)

$extra = @{}
if ($EntryStartTime)  { $extra['EntryStartTime']  = $EntryStartTime }
if ($EntryStopTime)   { $extra['EntryStopTime']   = $EntryStopTime }
if ($MarketCloseTime) { $extra['MarketCloseTime'] = $MarketCloseTime }

$here = $PSScriptRoot
if ($Instruments) {
    $insts = foreach ($i in $Instruments) {
        $p = $i -split '/'
        @{ Name=$p[0]; Tok=[int]$p[1]; Side=$(if ($p[0] -match 'CE$') { 'CE' } elseif ($p[0] -match 'PE$') { 'PE' } else { $p[0] }) }
    }
} else {
    $insts = @(
        @{ Name='NIFTY26JUL23950CE'; Tok=16367874; Side='CE' },
        @{ Name='NIFTY26JUL24200PE'; Tok=16370690; Side='PE' }
    )
}
$tfs = $TimeFrames
$rows = @()

foreach ($d in $Days) {
    foreach ($ins in $insts) {
        foreach ($tf in $tfs) {
            $out = (& (Join-Path $here 'Quick-HA-Analysis.ps1') `
                        -TradingSymbol $ins.Name -InstrumentToken $ins.Tok `
                        -Date $d -TimeFrame $tf -SLLookback $SLLookback @extra 6>&1) | Out-String
            if ($out -match 'Long:\s*([+-]?\d+(?:\.\d+)?)\s*\+\s*Short:\s*([+-]?\d+(?:\.\d+)?)\s*=\s*([+-]?\d+(?:\.\d+)?)') {
                $rows += [PSCustomObject]@{
                    Date=$d; Side=$ins.Side; TF=$tf
                    Long=[double]$Matches[1]; Short=[double]$Matches[2]; Combined=[double]$Matches[3]
                }
            } else {
                $rows += [PSCustomObject]@{ Date=$d; Side=$ins.Side; TF=$tf; Long=$null; Short=$null; Combined=$null }
            }
        }
    }
}

Write-Host "`n================ DAY-WISE REPORT (SL Lookback $SLLookback) ================" -ForegroundColor Cyan
foreach ($d in $Days) {
    Write-Host "`n  $d" -ForegroundColor Yellow
    Write-Host ("  {0,-6} {1,-8} {2,10} {3,10} {4,12}" -f 'Side','TF','Long','Short','Combined') -ForegroundColor DarkGray
    foreach ($r in ($rows | Where-Object Date -eq $d)) {
        $cl = if ($r.Combined -ge 0) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-6} {1,-8} {2,10} {3,10} {4,12}" -f $r.Side, $r.TF, $r.Long, $r.Short, $r.Combined) -ForegroundColor $cl
    }
    $dayTot = [Math]::Round((($rows | Where-Object Date -eq $d).Combined | Measure-Object -Sum).Sum, 2)
    $dcl = if ($dayTot -ge 0) { 'Cyan' } else { 'Red' }
    Write-Host ("  {0,-6} {1,-8} {2,10} {3,10} {4,12}" -f 'DAY','TOTAL','','',$dayTot) -ForegroundColor $dcl
}
Write-Host "`n=========================================================================" -ForegroundColor Cyan
