# ============================================================
# Get-KiteCandles.ps1 — Quick launcher for Kite market data
#
# USAGE:
#   $env:KITE_ENCTOKEN = "your_enctoken_here"
#
#   .\Get-KiteCandles.ps1                                          # SILVERM default
#   .\Get-KiteCandles.ps1 -Preset NIFTY                           # NIFTY 50 index
#   .\Get-KiteCandles.ps1 -Preset RELIANCE -Interval 5minute      # Reliance 5-min
#   .\Get-KiteCandles.ps1 -Preset SENSEX -CandleCount 20          # Sensex last 20
#   .\Get-KiteCandles.ps1 -Search "BANKNIFTY"                     # Search instruments
#   .\Get-KiteCandles.ps1 -ListPresets                             # Show all presets
#   .\Get-KiteCandles.ps1 -InstrumentToken 260105 -TradingSymbol "NIFTY BANK" -Exchange NSE
#
# EXCHANGES: NSE, BSE, NFO, BFO, MCX, CDS, BCD
# INTERVALS: minute, 3minute, 5minute, 10minute, 15minute, 30minute, 60minute, day
# ============================================================

param(
    [string]$Preset,
    [int]$InstrumentToken     = 117128455,
    [string]$TradingSymbol    = "SILVERM26APRFUT",
    [string]$Exchange         = "MCX",
    [string]$Interval         = "minute",
    [int]$CandleCount         = 10,
    [string]$Search,
    [switch]$ListPresets,
    [switch]$Continuous,
    [switch]$Raw
)

# Import the module
Import-Module "$PSScriptRoot\KiteData.psm1" -Force

# Dispatch
if ($ListPresets) {
    Show-KitePresets
}
elseif ($Search) {
    Search-KiteInstrument -Query $Search
}
elseif ($Preset) {
    $params = @{ Preset = $Preset; Interval = $Interval; CandleCount = $CandleCount }
    if ($Continuous) { $params.Continuous = $true }
    if ($Raw)        { $params.Raw = $true }
    Get-KiteCandles @params
}
else {
    $params = @{
        InstrumentToken = $InstrumentToken
        TradingSymbol   = $TradingSymbol
        Exchange        = $Exchange
        Interval        = $Interval
        CandleCount     = $CandleCount
    }
    if ($Continuous) { $params.Continuous = $true }
    if ($Raw)        { $params.Raw = $true }
    Get-KiteCandles @params
}
