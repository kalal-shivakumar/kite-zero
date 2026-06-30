<#
.SYNOPSIS
    Start the trading bot webapp locally.
.DESCRIPTION
    Installs deps, sets env vars, starts the Node.js server on port 5000.
.EXAMPLE
    .\start-webapp.ps1
#>

$ErrorActionPreference = 'Stop'
$RepoRoot   = $PSScriptRoot
$WebappDir  = Join-Path $RepoRoot 'webapp'

Write-Host "`n+==========================================+" -ForegroundColor Cyan
Write-Host "|   Starting Webapp locally on :5000       |" -ForegroundColor Cyan
Write-Host "+==========================================+`n" -ForegroundColor Cyan

# 1. npm install
Write-Host "[1/2] Installing dependencies..." -ForegroundColor Yellow
Push-Location $WebappDir
try {
    npm install --silent 2>&1 | Out-Null
    Write-Host "      npm install done" -ForegroundColor Green
} finally {
    Pop-Location
}

# 2. Set env vars and start
Write-Host "[2/2] Starting server on http://localhost:5000 ...`n" -ForegroundColor Yellow

$env:PORT             = '5000'
$env:NODE_ENV         = 'development'
$env:SESSION_SECRET   = 'local-dev-secret-change-me'

Write-Host "      Press Ctrl+C to stop.`n" -ForegroundColor DarkGray

Start-Process "http://localhost:5000"

Push-Location $WebappDir
try {
    node server.js
} finally {
    Pop-Location
    Remove-Item Env:\PORT -ErrorAction SilentlyContinue
    Remove-Item Env:\NODE_ENV -ErrorAction SilentlyContinue
    Remove-Item Env:\SESSION_SECRET -ErrorAction SilentlyContinue
}
