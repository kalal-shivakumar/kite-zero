# Copilot Instructions — Kite Trading Bot

## Project Context (20 Key Points)

1. **Heikin-Ashi Strategy**: The bot uses Heikin-Ashi (HA) candles for signal generation. LONG entry when HA Close > previous HA High; SHORT entry when HA Close < previous HA Low. Exits are the reverse conditions.

2. **Bidirectional Trading**: Only one direction active at a time (LONG or SHORT). LONG buys CE (Call) options, SHORT buys PE (Put) options. On exit, the opposite direction can immediately be entered.

3. **WebSocket Real-Time Ticks**: Connects to `wss://ws.kite.trade` using Kite Connect WebSocket API v3. Binary tick protocol is parsed manually (Big-Endian int16/int32). Supports `quote` and `full` modes.

4. **ATM Option Selection**: On entry, the bot finds the At-The-Money (ATM) option strike closest to spot price. `ATMOffset` parameter shifts the strike (negative = ITM for CE, positive = OTM for PE).

5. **Kite Connect API Auth**: Uses `API_Key` + `API_Secret` to generate login URL → user logs in → redirect with `request_token` → exchange for `access_token` via SHA256 checksum. Token valid ~10 hours.

6. **Web App Flow**: User enters API Key + Secret on webapp → generates Kite login URL → user authenticates → callback receives `request_token` → exchanges for `access_token` → stores all secrets in Azure Key Vault → dashboard shown.

7. **Azure Key Vault**: All sensitive data (API Key, API Secret, Access Token) stored per-user in Azure Key Vault (`trading-bot-kv-sk`). Secrets named as `kite-api-key-{userId}`, `kite-api-secret-{userId}`, `kite-access-token-{userId}`.

8. **Multi-User In-Process Engine**: After authentication, each user gets an isolated `TradingBot` instance running in the Node.js server process. The bot connects to Kite WebSocket, processes ticks, builds HA candles, and places orders. Real-time data is streamed to the browser via Server-Sent Events (SSE). PowerShell scripts (`Long-Short-Combined.ps1`) are also available as Docker containers via ACI for standalone execution.

9. **Trading Window**: Indian market hours 9:15 AM to 3:30 PM IST. Bot only generates signals within `StartTime`–`StopTime` window. Force-exits any open position at stop time.

10. **Index Support**: Supports NIFTY, BANKNIFTY, FinNifty, MIDCPNIFTY, SENSEX. Each index has specific lot sizes (NIFTY=75, BANKNIFTY=15, FINNIFTY=40, MIDCPNIFTY=75, SENSEX=20), exchanges (NFO/BFO), and spot quote keys.

11. **Order Placement**: Uses Kite Connect REST API `POST /orders/{variety}`. Supports MARKET (with market_protection %), LIMIT, SL, SL-M order types. The `Place-ZerodhaOrder` function handles all order types.

12. **Stop Loss Monitor**: `Stop_Loss_Creater_Swinglow.ps1` runs separately to monitor open CE/PE positions. If no SL order exists, it calculates swing low from candle data and places an SL order. Cancels orphaned SL orders when positions close.

13. **Position Persistence**: Active positions saved to `PlacedOrders/Position.json`. On script restart, checks for existing position and offers to resume or clear. Container passes position state via env vars.

14. **Infrastructure**: Azure Resource Group `trading-bot` in Central India. App Service Plan (B1 Linux), Web App (`trading-bot-kite`), Key Vault, ACR, Storage Account for Terraform state.

15. **CI/CD Pipeline**: GitHub Actions workflow on push to `master`. Steps: Docker build/push to ACR → Terraform plan/apply → Deploy webapp. Uses OIDC federated credentials (no stored Azure passwords).

16. **Terraform State**: Remote backend in Azure Storage (`tradingbottfstate` account, `tfstate` container). Manages: resource group, app service plan, key vault, ACR, web app, RBAC role assignments.

17. **Real-Time Streaming (SSE)**: The webapp uses Server-Sent Events (`/api/stream`) to push live tick data, completed HA candles, trade signals, and log entries to each user's browser in real-time. Each user's SSE stream is isolated. The dashboard updates LTP, HA values, candle table, signal log, and position status without polling.

18. **GitHub Secrets**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (OIDC), `ACR_LOGIN_SERVER`, `ACR_USERNAME`, `ACR_PASSWORD`, `AZURE_KEYVAULT_NAME`, `KITE_API_KEY`, `KITE_API_SECRET`, `ARM_ACCESS_KEY` (TF state).

19. **PowerShell Module (`KiteData.psm1`)**: Shared module with 23+ exported functions including: `Resolve-KiteSymbol`, `Parse-KiteTicks`, `Place-ZerodhaOrder`, `Get-IndexOptionConfig`, `Get-ATMOption`, `Get-KiteOptionInstruments`, `Get-KiteOpenPositions`, `Cancel-AllStopLosses`, `Check-AlreadyAnyOrderRunning`.

20. **Candle Building**: Raw ticks are aggregated into time-bucketed candles (configurable: 5s to 60min). Each completed raw candle is converted to Heikin-Ashi using previous HA candle's Open/Close. The active (forming) candle is also converted to live HA for real-time signal checks.

## Architecture Diagram

```
User Browser (per-user isolated)
    │
    ├── GET /  → Login page (enter API Key + Secret)
    ├── POST /api/login → Store in session, generate Kite login URL
    ├── Redirect to kite.zerodha.com → OAuth login
    ├── GET /callback?request_token=xxx → Exchange token
    │     ├── Store API Key/Secret/Token in Azure Key Vault (per-user)
    │     └── Redirect to /dashboard
    ├── GET /dashboard → Profile + Config form + Start/Stop buttons
    ├── GET /api/profile → Fetch Kite user profile
    ├── POST /api/bot/start → Create in-process TradingBot instance
    │     ├── Fetch option chain (CE+PE instruments)
    │     └── Connect Kite WebSocket → stream ticks
    ├── GET /api/stream → SSE: real-time ticks, candles, signals, logs
    ├── GET /api/bot/state → Snapshot (poll fallback)
    └── POST /api/bot/stop → Disconnect WS, clear bot
```

## File Structure

```
├── .github/
│   ├── copilot-instructions.md    ← This file
│   └── workflows/deploy.yml      ← CI/CD pipeline
├── webapp/
│   ├── server.js                  ← Express server (multi-user, KV, SSE, WS)
│   ├── package.json               ← Node.js dependencies
│   └── public/
│       ├── index.html             ← Login page
│       └── dashboard.html         ← Trading dashboard
├── terraform/
│   └── main.tf                    ← Infrastructure as Code
├── Dockerfile                     ← PowerShell bot container
├── docker-entrypoint.ps1          ← Container entry point
├── KiteData.psm1                  ← Trading module (shared)
├── Long-Short-Combined.ps1        ← Main trading strategy
├── Stop_Loss_Creater_Swinglow.ps1 ← SL monitor
└── input.json                     ← Local config (not used in prod)
```

## Key Commands

```bash
# Local dev
cd webapp && npm install && node server.js

# Build container
docker build -t trading-bot .

# Deploy
git push origin master  # triggers GitHub Actions

# Azure CLI
az webapp browse --name trading-bot-kite --resource-group trading-bot
```

## Trading Logic Summary

The strategy is a **zero-latency Heikin-Ashi reversal system**:
- Streams real-time ticks via WebSocket
- Builds HA candles at configurable intervals
- Checks signals on EVERY tick (not just candle close)
- Entry/exit decisions compare live HA values against previous completed HA candle
- Automatically selects nearest-expiry ATM CE/PE options
- Places MARKET orders with configurable market protection
- Supports position persistence across restarts
- Force-exits at market close (3:30 PM IST)
