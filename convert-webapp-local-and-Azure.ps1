<#
.SYNOPSIS
    Deploy the trading bot webapp locally or to Azure.
.DESCRIPTION
    - local : Installs deps, sets env vars for local dev (port 5000, no KV), starts server.
    - azure : Stages, commits, pushes to master, and monitors the GitHub Actions workflow.
.PARAMETER Mode
    "local" or "azure"
.EXAMPLE
    .\convert-webapp-local-and-Azure.ps1 -Mode local
    .\convert-webapp-local-and-Azure.ps1 -Mode azure
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('local', 'azure')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$RepoRoot   = $PSScriptRoot
$WebappDir  = Join-Path $RepoRoot 'webapp'

# ─────────────────────────────────────────────────────────────
#  LOCAL MODE
# ─────────────────────────────────────────────────────────────
if ($Mode -eq 'local') {
    Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   Deploying Webapp LOCALLY on :5000      ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝`n" -ForegroundColor Cyan

    # 1. npm install
    Write-Host "[1/3] Installing dependencies..." -ForegroundColor Yellow
    Push-Location $WebappDir
    try {
        npm install --silent 2>&1 | Out-Null
        Write-Host "      npm install ✓" -ForegroundColor Green
    } finally {
        Pop-Location
    }

    # 2. Set local env vars
    Write-Host "[2/3] Setting environment variables for local mode..." -ForegroundColor Yellow

    $env:PORT                     = '5000'
    $env:NODE_ENV                 = 'development'
    $env:AZURE_KEYVAULT_NAME      = ''           # Disable Key Vault locally
    $env:SESSION_SECRET           = 'local-dev-secret-change-me'

    Write-Host "      PORT              = $env:PORT"
    Write-Host "      NODE_ENV          = $env:NODE_ENV"
    Write-Host "      AZURE_KEYVAULT_NAME = (disabled)" -ForegroundColor DarkGray
    Write-Host "      Environment set ✓" -ForegroundColor Green

    # 3. Start server
    Write-Host "[3/3] Starting server on http://localhost:5000 ...`n" -ForegroundColor Yellow
    Write-Host "      Press Ctrl+C to stop.`n" -ForegroundColor DarkGray

    Push-Location $WebappDir
    try {
        node server.js
    } finally {
        Pop-Location
        # Clean up env vars
        Remove-Item Env:\PORT -ErrorAction SilentlyContinue
        Remove-Item Env:\NODE_ENV -ErrorAction SilentlyContinue
        Remove-Item Env:\AZURE_KEYVAULT_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:\SESSION_SECRET -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────
#  AZURE MODE
# ─────────────────────────────────────────────────────────────
if ($Mode -eq 'azure') {
    Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║   Deploying Webapp to AZURE via CI/CD    ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════╝`n" -ForegroundColor Magenta

    Push-Location $RepoRoot
    try {
        # 1. Check for changes
        Write-Host "[1/5] Checking for changes..." -ForegroundColor Yellow
        $status = git status --porcelain
        if (-not $status) {
            Write-Host "      No changes to commit." -ForegroundColor DarkGray
            $response = Read-Host "      Push existing commits anyway? (y/n)"
            if ($response -ne 'y') {
                Write-Host "      Aborted." -ForegroundColor Red
                return
            }
        } else {
            Write-Host "      Changed files:" -ForegroundColor DarkGray
            $status | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }

            # 2. Stage all
            Write-Host "`n[2/5] Staging changes..." -ForegroundColor Yellow
            git add -A
            Write-Host "      git add -A ✓" -ForegroundColor Green

            # 3. Commit
            Write-Host "[3/5] Committing..." -ForegroundColor Yellow
            $msg = Read-Host "      Commit message (Enter for default)"
            if (-not $msg) { $msg = "Update webapp $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
            git commit -m $msg
            Write-Host "      Committed ✓" -ForegroundColor Green
        }

        # 4. Push
        Write-Host "[4/5] Pushing to origin/master..." -ForegroundColor Yellow
        git push origin master
        Write-Host "      Pushed ✓" -ForegroundColor Green

        # 5. Monitor workflow
        Write-Host "`n[5/5] Monitoring GitHub Actions workflow..." -ForegroundColor Yellow
        Write-Host "      Waiting for workflow to start..." -ForegroundColor DarkGray

        $maxWait = 30
        $runId   = $null
        for ($i = 0; $i -lt $maxWait; $i++) {
            Start-Sleep -Seconds 2
            $runs = gh run list --limit 1 --json databaseId,status,headSha | ConvertFrom-Json
            if ($runs -and $runs[0].status -ne 'completed') {
                $runId = $runs[0].databaseId
                break
            }
            if ($runs -and $runs[0].status -eq 'completed') {
                # Check if this is a new run (just completed very fast) vs old run
                $headSha = (git rev-parse HEAD)
                if ($runs[0].headSha -eq $headSha) {
                    $runId = $runs[0].databaseId
                    break
                }
            }
        }

        if (-not $runId) {
            Write-Host "      Could not detect workflow run. Check manually:" -ForegroundColor Red
            Write-Host "      gh run list" -ForegroundColor DarkGray
            return
        }

        Write-Host "      Run ID: $runId" -ForegroundColor Cyan
        Write-Host ""

        # Poll status
        do {
            Start-Sleep -Seconds 10
            $run = gh run view $runId --json status,conclusion,jobs | ConvertFrom-Json
            $status = $run.status
            $conclusion = $run.conclusion
            $jobInfo = ""
            if ($run.jobs) {
                $activeJob = $run.jobs | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1
                if ($activeJob) {
                    $activeStep = $activeJob.steps | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1
                    if ($activeStep) { $jobInfo = " → $($activeStep.name)" }
                }
            }
            $ts = Get-Date -Format 'HH:mm:ss'
            if ($status -eq 'in_progress') {
                Write-Host "      [$ts] ⏳ Running$jobInfo" -ForegroundColor Yellow
            }
        } while ($status -eq 'in_progress' -or $status -eq 'queued' -or $status -eq 'waiting')

        # Final result
        Write-Host ""
        if ($conclusion -eq 'success') {
            Write-Host "      ✅ Workflow SUCCEEDED!" -ForegroundColor Green
            Write-Host "      🌐 https://trading-bot-kite.azurewebsites.net" -ForegroundColor Cyan
        } else {
            Write-Host "      ❌ Workflow FAILED (conclusion: $conclusion)" -ForegroundColor Red
            Write-Host "      View logs: gh run view $runId --log-failed" -ForegroundColor DarkGray
        }
    } finally {
        Pop-Location
    }
}
