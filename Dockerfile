# PowerShell Trading Bot Container
# Runs Long-Short-Combined.ps1 with Kite WebSocket streaming
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

WORKDIR /app

# Copy all PowerShell scripts and module
COPY KiteData.psm1 ./
COPY Long-Short-Combined.ps1 ./
COPY Stop_Loss_Creater_Swinglow.ps1 ./

# Create required directories
RUN mkdir -p /app/PlacedOrders /app/DayLowDetectedFiles

# The container expects these env vars at runtime:
#   KITE_API_KEY, KITE_API_SECRET, KITE_ACCESS_TOKEN
#   TRADING_SYMBOL, TIME_FRAME, INDEX_CHOOSEN, etc.
# input.json is generated at container start from env vars

COPY docker-entrypoint.ps1 ./
RUN chmod +x docker-entrypoint.ps1

ENTRYPOINT ["pwsh", "-File", "/app/docker-entrypoint.ps1"]
