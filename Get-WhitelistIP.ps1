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
    @{ Uri = "https://v6.ident.me"; Name = "ident.me (IPv6)" },
    @{ Uri = "https://ifconfig.co"; Name = "ifconfig.co" }
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
# 2. SHOW LOCAL IPs (for comparison - DO NOT whitelist these)
# ============================================================
Write-Host "`n[2] YOUR LOCAL/PRIVATE IPs (DO NOT whitelist these)" -ForegroundColor DarkYellow
Write-Host "--------------------------------------------------------------------" -ForegroundColor DarkYellow

# Get active network adapters with IPv4
$adapters = Get-NetIPAddress -AddressFamily IPv4 | 
    Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.InterfaceAlias -notlike '*Loopback*' } |
    Select-Object InterfaceAlias, IPAddress

foreach ($adapter in $adapters) {
    Write-Host "  [IPv4] $($adapter.InterfaceAlias): $($adapter.IPAddress)" -ForegroundColor Gray
}

# Get active network adapters with IPv6
$adapters6 = Get-NetIPAddress -AddressFamily IPv6 | 
    Where-Object { $_.IPAddress -ne '::1' -and $_.InterfaceAlias -notlike '*Loopback*' -and $_.PrefixOrigin -ne 'WellKnown' } |
    Select-Object InterfaceAlias, IPAddress

foreach ($adapter in $adapters6) {
    Write-Host "  [IPv6] $($adapter.InterfaceAlias): $($adapter.IPAddress)" -ForegroundColor Gray
}

# ============================================================
# 3. SHOW DEFAULT GATEWAY (Router address - DO NOT whitelist)
# ============================================================
Write-Host "`n[3] YOUR ROUTER/GATEWAY ADDRESS (DO NOT whitelist this either)" -ForegroundColor DarkYellow
Write-Host "--------------------------------------------------------------------" -ForegroundColor DarkYellow

$gateways = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | 
    Select-Object -ExpandProperty NextHop -Unique

foreach ($gw in $gateways) {
    if ($gw -ne '0.0.0.0') {
        Write-Host "  Default Gateway (Router): $gw" -ForegroundColor Gray
    }
}

# ============================================================
# 4. SUMMARY & INSTRUCTIONS
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  IP(s) to WHITELIST in Zerodha Kite Developer Portal:" -ForegroundColor White
if ($publicIPv4) {
    Write-Host "  ==>  IPv4: $publicIPv4" -ForegroundColor Green
}
if ($publicIPv6) {
    Write-Host "  ==>  IPv6: $publicIPv6" -ForegroundColor Green
}
# Copy both to clipboard
$clipText = @()
if ($publicIPv4) { $clipText += $publicIPv4 }
if ($publicIPv6) { $clipText += $publicIPv6 }
($clipText -join ", ") | Set-Clipboard
Write-Host ""
Write-Host "  (Copied to clipboard: $($clipText -join ', '))" -ForegroundColor DarkGreen
Write-Host ""
Write-Host "  WHAT IS THIS IP?" -ForegroundColor White
Write-Host "  - This is your ISP-assigned public IP (seen by all external servers)" -ForegroundColor Gray
Write-Host "  - All devices on your network share this IP via NAT" -ForegroundColor Gray
Write-Host "  - ipconfig shows PRIVATE IPs (192.168.x.x) - these are internal only" -ForegroundColor Gray
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor White
Write-Host "  1. Go to https://developers.kite.trade" -ForegroundColor Gray
Write-Host "  2. Login and open your App" -ForegroundColor Gray
Write-Host "  3. Paste the public IP in the 'IP Whitelist' field" -ForegroundColor Gray
Write-Host "  4. Save the settings" -ForegroundColor Gray
Write-Host ""
Write-Host "  IMPORTANT NOTES:" -ForegroundColor White
Write-Host "  - If ISP gives DYNAMIC IP, it may change (restart router/daily)" -ForegroundColor Yellow
Write-Host "    Run this script again if API calls start failing with 403" -ForegroundColor Yellow
Write-Host "  - For STATIC IP, ask your ISP or use a VPS/cloud server" -ForegroundColor Yellow
Write-Host "  - Multiple IPs can be whitelisted (comma-separated)" -ForegroundColor Yellow
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  COPY THESE (plain text):" -ForegroundColor White
if ($publicIPv4) { Write-Host "  $publicIPv4" }
if ($publicIPv6) { Write-Host "  $publicIPv6" }
Write-Host ""
Write-Host "============================================================`n" -ForegroundColor Cyan
