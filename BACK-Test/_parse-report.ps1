param([Parameter(Mandatory)][string]$File, [string]$CsvOut)

$lines = Get-Content $File
$data = @()
$curDate = $null
foreach ($l in $lines) {
    if ($l -match '^\s*(\d{4}-\d{2}-\d{2})\s*$') { $curDate = $Matches[1]; continue }
    if ($l -match 'NIFTY 50 minute\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*$') {
        $data += [PSCustomObject]@{ Date=$curDate; Long=[double]$Matches[1]; Short=[double]$Matches[2]; Combined=[double]$Matches[3] }
    }
}
$tot = [Math]::Round(($data.Combined | Measure-Object -Sum).Sum, 2)
$win = @($data | Where-Object Combined -gt 0).Count
$los = @($data | Where-Object Combined -lt 0).Count
$avg = [Math]::Round($tot / $data.Count, 2)
$best  = $data | Sort-Object Combined -Descending | Select-Object -First 3
$worst = $data | Sort-Object Combined | Select-Object -First 3

Write-Host "Days with data: $($data.Count)"
Write-Host "Total: $tot | Avg/day: $avg"
Write-Host "Win days: $win  Lose days: $los  Win%: $([Math]::Round($win / $data.Count * 100, 1))"
Write-Host "Best:  $(($best  | ForEach-Object { "$($_.Date) $($_.Combined)" }) -join ' | ')"
Write-Host "Worst: $(($worst | ForEach-Object { "$($_.Date) $($_.Combined)" }) -join ' | ')"

if ($CsvOut) {
    $data | Select-Object Date, Long, Short, Combined | Export-Csv $CsvOut -NoTypeInformation
    Write-Host "CSV written: $CsvOut"
}
