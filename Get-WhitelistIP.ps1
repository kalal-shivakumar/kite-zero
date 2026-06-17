<#
.SYNOPSIS
    Finds your PUBLIC IP address for Zerodha Kite Connect API whitelisting.

.DESCRIPTION
    Zerodha Kite Connect requires you to whitelist your PUBLIC IP address 
    (the IP that external servers see) in the Developer Portal.
    
    This is NOT your local ipconfig IP (192.168.x.x) or router gateway address.
    Your PUBLIC IP is what your ISP assigns to your router/modem. All devices 
    on your home network share this single public IP via NAT.

    STEPS AFTER RUNNING THIS SCRIPT:
    1. Copy the Public IP shown below
    2. Login to https://developers.kite.trade
    3. Go to your App settings
    4. Paste the IP in the "IP Whitelist" field
    5. Save

    NOTE: If your ISP gives you a dynamic IP, it may change periodically.
    You'll need to update the whitelist if your IP changes.
#>

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  ZERODHA KITE CONNECT - IP WHITELIST FINDER" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

# ============================================================
# 1. FETCH YOUR PUBLIC IP (This is what you whitelist)
# ============================================================
Write-Host "[1] YOUR PUBLIC IP ADDRESS (Whitelist THIS in Kite Developer Portal)" -ForegroundColor Green
Write-Host "--------------------------------------------------------------------" -ForegroundColor Green

$publicIPv4 = $null
$publicIPv6 = $null

# --- Fetch IPv4 ---
$ipv4Services = @(
    @{ Uri = "https://api.ipify.org"; Name = "ipify.org" },
    @{ Uri = "https://ifconfig.me/ip"; Name = "ifconfig.me" },
    @{ Uri = "https://checkip.amazonaws.com"; Name = "AWS checkip" }
)

foreach ($svc in $ipv4Services) {
    try {
        $response = Invoke-RestMethod -Uri $svc.Uri -TimeoutSec 5 -ErrorAction Stop
        $ip = ($response).Trim()
        if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            $publicIPv4 = $ip
            Write-Host "  [IPv4] Source: $($svc.Name)" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  >>> YOUR PUBLIC IPv4: $publicIPv4 <<<" -ForegroundColor Yellow
            Write-Host ""
            break
        }
    }
    catch {
        Write-Host "  [!] Could not reach $($svc.Name) for IPv4, trying next..." -ForegroundColor DarkGray
    }
}

if (-not $publicIPv4) {
    Write-Host "  [WARNING] Could not determine public IPv4." -ForegroundColor Red
}

# --- Fetch IPv6 ---
$ipv6Services = @(
    @{ Uri = "https://api6.ipify.org"; Name = "ipify.org (IPv6)" },
    @{ Uri = "https://v6.ident.me"; Name = "ident.me (IPv6)" }
)

foreach ($svc in $ipv6Services) {
    try {
        $response = Invoke-RestMethod -Uri $svc.Uri -TimeoutSec 5 -ErrorAction Stop
        $ip = ($response).Trim()
        # Match IPv6 pattern (contains colons)
        if ($ip -match ':') {
            $publicIPv6 = $ip
            Write-Host "  [IPv6] Source: $($svc.Name)" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  >>> YOUR PUBLIC IPv6: $publicIPv6 <<<" -ForegroundColor Yellow
            Write-Host ""
            break
        }
    }
    catch {
        Write-Host "  [!] Could not reach $($svc.Name) for IPv6, trying next..." -ForegroundColor DarkGray
    }
}

if (-not $publicIPv6) {
    Write-Host "  [INFO] No public IPv6 detected (your ISP may not support IPv6)" -ForegroundColor DarkYellow
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
if ($publicIPv4) {
    Write-Host "  IPv4: $publicIPv4" -ForegroundColor Green
}
if ($publicIPv6) {
    Write-Host "  IPv6: $publicIPv6" -ForegroundColor Green
}
# Copy to clipboard
$clipText = @()
if ($publicIPv4) { $clipText += $publicIPv4 }
if ($publicIPv6) { $clipText += $publicIPv6 }
($clipText -join ", ") | Set-Clipboard
Write-Host ""
Write-Host "  (Copied to clipboard)" -ForegroundColor DarkGreen
Write-Host "============================================================`n" -ForegroundColor Cyan
