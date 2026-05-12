# Delta Exchange India — API Documentation

Complete reference for the **Delta Exchange India** REST & WebSocket APIs (v2).

---

## Table of Contents

- [Introduction](#introduction)
- [Base URLs](#base-urls)
- [General Information](#general-information)
  - [Definitions](#definitions)
  - [Symbology](#symbology)
  - [Pagination](#pagination)
- [Authentication](#authentication)
  - [Generating an API Key](#generating-an-api-key)
  - [API Key Permissions](#api-key-permissions)
  - [Creating a Request](#creating-a-request)
  - [Signing a Message](#signing-a-message)
  - [Common Auth Errors](#common-authentication-errors)
- [Rate Limits](#rate-limits)
- [Types & Response Formats](#types--response-formats)
- [REST API Endpoints](#rest-api-endpoints)
  - [Assets](#assets)
  - [Indices](#indices)
  - [Products](#products)
  - [Orders](#orders)
  - [Positions](#positions)
  - [Trade History](#trade-history)
  - [Orderbook](#orderbook)
  - [Trades](#trades)
  - [Wallet](#wallet)
  - [Stats](#stats)
  - [MMP (Market Maker Protection)](#mmp-market-maker-protection)
  - [Account](#account)
  - [Heartbeat Management (Deadman Switch)](#heartbeat-management-deadman-switch)
  - [Settlement Prices](#settlement-prices)
  - [Historical OHLC Candles & Sparklines](#historical-ohlc-candles--sparklines)
- [WebSocket Feed](#websocket-feed)
  - [Connection Details](#connection-details)
  - [Subscribing to Channels](#subscribing-to-channels)
  - [WebSocket Authentication](#websocket-authentication)
  - [Public Channels](#public-channels)
  - [Private Channels](#private-channels)
- [Order Error Codes](#order-error-codes)
- [HTTP Error Codes](#http-error-codes)
- [REST Clients & SDKs](#rest-clients--sdks)
- [Schemas Reference](#schemas-reference)

---

## Introduction

The Delta Exchange India API allows you to programmatically place orders, manage positions, fetch market data, and stream real-time feeds via WebSocket. The API supports **perpetual futures**, **call options**, and **put options** on crypto assets (BTC, ETH, SOL, etc.) settled in INR/USD.

---

## Base URLs

| Environment | REST API | WebSocket (Private) | WebSocket (Public) |
|---|---|---|---|
| **Production** | `https://api.india.delta.exchange` | `wss://socket.india.delta.exchange` | `wss://public-socket.india.delta.exchange` |
| **Testnet (Demo)** | `https://cdn-ind.testnet.deltaex.org` | `wss://socket-ind.testnet.deltaex.org` | `wss://socket-ind-pub.testnet.deltaex.org` |

> **Important:** `https://api.delta.exchange` is for Delta **Global** — do **not** use it with India API keys.

---

## General Information

### Definitions

| Term | Description |
|---|---|
| **Underlying Asset** | The asset over which a contract is defined (e.g. BTC for BTCUSD). |
| **Quoting Asset** | The asset in which the price is quoted (e.g. USD for BTCUSD). |
| **Settling Asset** | The asset in which margin & P/L are denominated (e.g. USD for BTCUSD). |
| **Product** | A derivative contract listed on Delta Exchange, referenced by **Product ID** (integer) or **Symbol** (string). |
| **Mark Price** | Unique per-contract price used for liquidations. Subscribe via `MARK:<Symbol>`. |
| **Index Price** | Underlying spot price aggregated from multiple exchanges. |

**Sample Products:**

| Product ID | Symbol | Contract Type | Description |
|---|---|---|---|
| 27 | BTCUSD | perpetual_futures | Bitcoin Perpetual futures settled in INR |
| 3136 | ETHUSD | perpetual_futures | Ethereum perpetual futures settled in INR |
| 2000 | P-BTC-38100-230124 | put_options | BTC put option strike $38,100 expiring 23/01/2024 |
| 5000 | C-BTC-55800-170224 | call_options | BTC call option strike $55,800 expiring 17/02/2024 |

### Symbology

**Futures/Perpetuals:** `<UnderlyingAsset><QuotingAsset>` — e.g. `BTCUSD`, `ETHUSD`

**Options:** `<Type>-<Asset>-<Strike>-<ddMMYY>` — e.g. `C-BTC-90000-310125` (Call, BTC, $90,000 strike, expires 31 Jan 2025)

### Pagination

Cursor-based pagination is used across multiple endpoints. Each response's `meta` contains `after` and `before` cursors:

```json
{
  "success": true,
  "result": [],
  "meta": {
    "after": "cursor_string",
    "before": "another_cursor_string"
  }
}
```

**Pagination parameters:**

| Parameter | Description |
|---|---|
| `after` | After cursor to fetch the next page |
| `before` | Before cursor to fetch the previous page |
| `page_size` | Number of records per page (default: 100) |

**Paginated endpoints:** `/v2/products`, `/v2/orders`, `/v2/orders/history`, `/v2/fills`, `/v2/wallet/transactions`

---

## Authentication

### Generating an API Key

Create API keys at: [https://www.delta.exchange/app/account/manageapikeys](https://www.delta.exchange/app/account/manageapikeys)

- Trading-permission keys require **whitelisted IP(s)**.
- Multiple IPs can be whitelisted (IPv4 and IPv6 supported).
- Keys are environment-specific — India Production keys only work with `api.india.delta.exchange`.

### API Key Permissions

| Permission | Scope |
|---|---|
| **Read Data** | Market data, account info |
| **Trading** | Place/cancel/edit orders, change margin & leverage |

### Creating a Request

All authenticated requests must include these headers:

| Header | Value |
|---|---|
| `api-key` | Your API key string |
| `signature` | Hex-encoded HMAC-SHA256 signature |
| `timestamp` | Current Unix epoch timestamp (seconds) |
| `User-Agent` | Your language/library (e.g. `python-3.10`) |
| `Content-Type` | `application/json` |

### Signing a Message

The signature is an HMAC-SHA256 of the **prehash string**: `method + timestamp + requestPath + queryParams + body`

The signature must reach Delta servers within **5 seconds** of the timestamp.

**Python example:**

```python
import hashlib
import hmac
import requests
import time

base_url = 'https://api.india.delta.exchange'
api_key = 'YOUR_API_KEY'
api_secret = 'YOUR_API_SECRET'

def generate_signature(secret, message):
    message = bytes(message, 'utf-8')
    secret = bytes(secret, 'utf-8')
    hash = hmac.new(secret, message, hashlib.sha256)
    return hash.hexdigest()

# Example: GET open orders
method = 'GET'
timestamp = str(int(time.time()))
path = '/v2/orders'
query_string = '?product_id=1&state=open'
payload = ''
signature_data = method + timestamp + path + query_string + payload
signature = generate_signature(api_secret, signature_data)

headers = {
    'api-key': api_key,
    'timestamp': timestamp,
    'signature': signature,
    'User-Agent': 'python-rest-client',
    'Content-Type': 'application/json'
}

response = requests.get(f'{base_url}{path}', params={"product_id": 1, "state": "open"}, headers=headers)

# Example: POST place order
method = 'POST'
timestamp = str(int(time.time()))
path = '/v2/orders'
query_string = ''
payload = '{"order_type":"limit_order","size":3,"side":"buy","limit_price":"0.0005","product_id":16}'
signature_data = method + timestamp + path + query_string + payload
signature = generate_signature(api_secret, signature_data)

headers = {
    'api-key': api_key,
    'timestamp': timestamp,
    'signature': signature,
    'User-Agent': 'python-rest-client',
    'Content-Type': 'application/json'
}

response = requests.post(f'{base_url}{path}', data=payload, headers=headers)
```

### Common Authentication Errors

| Error Code | Message | Cause |
|---|---|---|
| `SignatureExpired` | Your signature has expired | Timestamp >5 seconds old |
| `InvalidApiKey` | Api Key not found | Wrong key or wrong environment |
| `UnauthorizedApiAccess` | Api Key not authorised | Missing permissions (Read/Trading) |
| `ip_not_whitelisted_for_api_key` | IP not whitelisted | Request from non-whitelisted IP |
| `Forbidden` | Request blocked by CDN | Missing `User-Agent` header or hidden/blocked IP |
| `Signature Mismatch` | Signature mismatch | Incorrect method/timestamp/payload in signature generation |

> **Note:** Entering wrong OTP/MFA code >5 times blocks API key creation for 30 minutes.

---

## Rate Limits

REST API uses a **weighted, 5-minute sliding window** quota system.

**Endpoint weights:**

| Weight | Endpoints |
|---|---|
| 3 | Get Products, Get Orderbook, Get Tickers, Get Open Orders, Get Open Positions, Get Balances, OHLC Candles |
| 5 | Place/Edit/Delete Order, Add Position Margin |
| 10 | Get Order History, Get Fills, Get Txn Logs |
| 25 | Batch Order APIs |

Exceeding quota returns **HTTP 429**. Check current quota:

```
GET /v2/rate_limits/quota
```

```json
{
  "current_quota": 42,
  "remaining_time_in_milliseconds": 120632
}
```

Contact [support@delta.exchange](mailto:support@delta.exchange) to request increased limits.

---

## Types & Response Formats

**Timestamps:** ISO 8601 format with microseconds — `2019-09-18T10:41:20Z`

**Numbers:** Big decimal values are returned as **strings** to preserve precision. Send numbers as strings in requests.

**Response format:**

```json
// Success
{
  "success": true,
  "result": {},
  "meta": {
    "after": "...",
    "before": null
  }
}

// Error
{
  "success": false,
  "error": {
    "code": "insufficient_margin",
    "context": {
      "additional_margin_required": "0.121"
    }
  }
}
```

---

## REST API Endpoints

### Assets

#### Get All Assets

```
GET /v2/assets
```

No authentication required.

```python
r = requests.get('https://api.india.delta.exchange/v2/assets')
```

**Response (200):**

```json
{
  "success": true,
  "result": [
    {
      "id": 14,
      "symbol": "USD",
      "precision": 8,
      "deposit_status": "enabled",
      "withdrawal_status": "enabled",
      "base_withdrawal_fee": "0.000000000000000000",
      "min_withdrawal_amount": "0.000000000000000000"
    }
  ]
}
```

---

### Indices

#### Get Indices

```
GET /v2/indices
```

No authentication required. Returns spot price indices composed from multiple exchanges.

**Response (200):**

```json
{
  "success": true,
  "result": [
    {
      "id": 14,
      "symbol": ".DEXBTUSD",
      "constituent_exchanges": [
        { "name": "ExchangeA", "weight": 0.25 }
      ],
      "underlying_asset_id": 13,
      "quoting_asset_id": 14,
      "tick_size": "0.5",
      "index_type": "spot_pair"
    }
  ]
}
```

---

### Products

#### Get All Products

```
GET /v2/products
```

No authentication required.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `contract_types` | string | No | Comma separated: `perpetual_futures`, `call_options`, `put_options` |
| `states` | string | No | Comma separated: `upcoming`, `live`, `expired`, `settled` |
| `after` | string | No | Pagination cursor |
| `before` | string | No | Pagination cursor |
| `page_size` | string | No | Default: 100 |
| `expiry` | string | No | `YYYY-MM-DD` format to filter by expiry date |

#### Get Product by Symbol

```
GET /v2/products/{symbol}
```

No authentication required.

| Parameter | Location | Required | Description |
|---|---|---|---|
| `symbol` | path | Yes | Product symbol (e.g. `BTCUSD`, `ETHUSD`) |

#### Get Tickers for Products

```
GET /v2/tickers
```

No authentication required.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `contract_types` | string | No | Comma separated: `perpetual_futures`, `call_options`, `put_options` |
| `underlying_asset_symbols` | string | No | Comma separated: `BTC`, `ETH`, `SOL` |
| `expiry_date` | string | No | Format: `DD-MM-YYYY` |

**Response includes:** close, open, high, low, mark_price, mark_vol, oi, volume, turnover, greeks (for options), quotes (bid/ask), price_band, spot_price, strike_price.

#### Get Ticker by Symbol

```
GET /v2/tickers/{symbol}
```

No authentication required. Maximum **10 comma-separated symbols**.

#### Get Option Chain

```
GET /v2/tickers?contract_types=call_options,put_options&underlying_asset_symbols={symbol}&expiry_date={DD-MM-YYYY}
```

No authentication required. Example:

```
GET /v2/tickers?contract_types=call_options,put_options&underlying_asset_symbols=BTC&expiry_date=04-04-2025
```

---

### Orders

> Rate limit: 500 operations/sec per product.

#### Place Order

```
POST /v2/orders
```

**Requires authentication.**

**Request body:**

```json
{
  "product_id": 27,
  "product_symbol": "BTCUSD",
  "limit_price": "59000",
  "size": 10,
  "side": "buy",
  "order_type": "limit_order",
  "stop_order_type": "stop_loss_order",
  "stop_price": "56000",
  "trail_amount": "50",
  "stop_trigger_method": "last_traded_price",
  "bracket_stop_trigger_method": "last_traded_price",
  "bracket_stop_loss_limit_price": "57000",
  "bracket_stop_loss_price": "56000",
  "bracket_trail_amount": "50",
  "bracket_take_profit_limit_price": "62000",
  "bracket_take_profit_price": "61000",
  "time_in_force": "gtc",
  "mmp": "disabled",
  "post_only": false,
  "reduce_only": false,
  "client_order_id": "my_signal_345212",
  "cancel_orders_accepted": false
}
```

**Key fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `product_id` / `product_symbol` | int/string | Yes (one of) | Product identifier |
| `size` | int | Yes | Order size in contracts |
| `side` | string | Yes | `buy` or `sell` |
| `order_type` | string | Yes | `limit_order` or `market_order` |
| `limit_price` | string | No | Required for limit orders |
| `stop_order_type` | string | No | `stop_loss_order` or `take_profit_order` |
| `stop_price` | string | No | Trigger price for stop orders |
| `trail_amount` | string | No | For trailing stop orders |
| `stop_trigger_method` | string | No | `mark_price`, `last_traded_price`, `spot_price` |
| `time_in_force` | string | No | `gtc` or `ioc` |
| `mmp` | string | No | `disabled`, `mmp1`-`mmp5` |
| `post_only` | bool | No | Post-only order |
| `reduce_only` | bool | No | Only close positions |
| `client_order_id` | string | No | Custom ID (max 32 chars) |

**Response (200):**

```json
{
  "success": true,
  "result": {
    "id": 123,
    "user_id": 453671,
    "size": 10,
    "unfilled_size": 2,
    "side": "buy",
    "order_type": "limit_order",
    "limit_price": "59000",
    "stop_order_type": "stop_loss_order",
    "stop_price": "55000",
    "paid_commission": "0.5432",
    "commission": "0.5432",
    "reduce_only": false,
    "client_order_id": "my_signal_34521712",
    "state": "open",
    "created_at": "1725865012000000",
    "product_id": 27,
    "product_symbol": "BTCUSD"
  }
}
```

**Order states:** `open`, `pending`, `closed`, `cancelled`

#### Edit Order

```
PUT /v2/orders
```

**Requires authentication.**

```json
{
  "id": 34521712,
  "product_id": 27,
  "limit_price": "59000",
  "size": 15,
  "mmp": "disabled",
  "post_only": false,
  "stop_price": "56000",
  "trail_amount": "50"
}
```

#### Cancel Order

```
DELETE /v2/orders
```

**Requires authentication.**

```json
{
  "id": 13452112,
  "client_order_id": "my_signal_34521712",
  "product_id": 27
}
```

#### Get Active Orders

```
GET /v2/orders
```

**Requires authentication.**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `product_ids` | string | No | Comma separated (max 10) |
| `states` | string | No | `open`, `pending` |
| `contract_types` | string | No | `futures`, `perpetual_futures`, `call_options`, `put_options` |
| `order_types` | string | No | `market`, `limit`, `stop_market`, `stop_limit`, `all_stop` |
| `start_time` | int | No | Epoch microseconds |
| `end_time` | int | No | Epoch microseconds |
| `after` / `before` | string | No | Pagination cursors |
| `page_size` | int | No | Records per page |

#### Get Order by ID

```
GET /v2/orders/{order_id}
```

#### Get Order by Client Order ID

```
GET /v2/orders/client_order_id/{client_oid}
```

#### Place Bracket Order

```
POST /v2/orders/bracket
```

**Requires authentication.** A bracket order is a TP + SL pair that closes the entire position.

```json
{
  "product_id": 27,
  "stop_loss_order": {
    "order_type": "limit_order",
    "stop_price": "56000",
    "trail_amount": "50",
    "limit_price": "55000"
  },
  "take_profit_order": {
    "order_type": "limit_order",
    "stop_price": "65000",
    "limit_price": "64000"
  },
  "bracket_stop_trigger_method": "last_traded_price"
}
```

#### Edit Bracket Order

```
PUT /v2/orders/bracket
```

#### Cancel All Open Orders

```
DELETE /v2/orders/all
```

```json
{
  "product_id": 27,
  "contract_types": "perpetual_futures,put_options,call_options",
  "cancel_limit_orders": false,
  "cancel_stop_orders": false,
  "cancel_reduce_only_orders": false
}
```

#### Batch Create Orders

```
POST /v2/orders/batch
```

Max 50 orders per batch. All must be for the same product. Only limit orders (no IOC).

```json
{
  "product_id": 27,
  "orders": [
    {
      "limit_price": "59000",
      "size": 10,
      "side": "buy",
      "order_type": "limit_order",
      "client_order_id": "my_signal_34521712"
    }
  ]
}
```

#### Batch Edit Orders

```
PUT /v2/orders/batch
```

#### Batch Delete Orders

```
DELETE /v2/orders/batch
```

```json
{
  "product_id": 27,
  "orders": [
    { "id": 13452112, "client_order_id": "my_signal_34521712" }
  ]
}
```

#### Change Order Leverage

```
POST /v2/products/{product_id}/orders/leverage
```

```json
{ "leverage": 10 }
```

#### Get Order Leverage

```
GET /v2/products/{product_id}/orders/leverage
```

---

### Positions

#### Get Margined Positions

```
GET /v2/positions/margined
```

**Requires authentication.** Changes may take up to 10 seconds to reflect.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `product_ids` | string | No | Comma separated (max 10) |
| `contract_types` | string | No | `perpetual_futures`, `call_options`, `put_options` |

**Response:**

```json
{
  "success": true,
  "result": [
    {
      "user_id": 0,
      "size": 0,
      "entry_price": "string",
      "margin": "string",
      "liquidation_price": "string",
      "bankruptcy_price": "string",
      "adl_level": 0,
      "product_id": 0,
      "product_symbol": "string",
      "commission": "string",
      "realized_pnl": "string",
      "realized_funding": "string"
    }
  ]
}
```

> `size` is negative for short positions, positive for long.

#### Get Position (Real-time)

```
GET /v2/positions?product_id={id}
```

**Requires authentication.** Returns only size and entry price — use for real-time data.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `product_id` | int | Yes* | Product ID (*one of product_id or underlying_asset_symbol) |
| `underlying_asset_symbol` | string | No | e.g. `BTC`, `ETH` — returns all positions for that asset |

#### Auto Topup

```
PUT /v2/positions/auto_topup
```

```json
{ "product_id": 0, "auto_topup": false }
```

#### Add/Remove Position Margin

```
POST /v2/positions/change_margin
```

```json
{
  "product_id": 0,
  "delta_margin": "100"
}
```

Positive `delta_margin` adds margin; negative removes it.

#### Close All Positions

```
POST /v2/positions/close_all
```

```json
{
  "close_all_portfolio": true,
  "close_all_isolated": true,
  "user_id": 0
}
```

---

### Trade History

#### Get Order History (Cancelled & Closed)

```
GET /v2/orders/history
```

**Requires authentication.**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `product_ids` | string | No | Comma separated (max 10) |
| `contract_types` | string | No | Comma separated list |
| `order_types` | string | No | `market`, `limit`, `stop_market`, `stop_limit`, `all_stop` |
| `start_time` / `end_time` | int | No | Epoch microseconds |
| `after` / `before` | string | No | Pagination cursors |
| `page_size` | int | No | Max 50 |

#### Get User Fills

```
GET /v2/fills
```

**Requires authentication.**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `product_ids` | string | No | Comma separated (max 10) |
| `contract_types` | string | No | Comma separated list |
| `start_time` / `end_time` | int | No | Epoch microseconds |
| `after` / `before` | string | No | Pagination cursors |
| `page_size` | int | No | Max 50 |

**Fill types:** `normal`, `adl`, `liquidation`, `settlement`, `otc`

**Roles:** `taker`, `maker`

#### Download Fills (CSV)

```
GET /v2/fills/history/download/csv
```

---

### Orderbook

#### Get L2 Orderbook

```
GET /v2/l2orderbook/{symbol}
```

No authentication required.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `symbol` | path | Yes | Product symbol |
| `depth` | query | No | Number of levels per side |

**Response:**

```json
{
  "success": true,
  "result": {
    "buy": [{ "depth": "983", "price": "9187.5", "size": 205640 }],
    "sell": [{ "depth": "1185", "price": "9188.0", "size": 113752 }],
    "last_updated_at": 1654589595784000,
    "symbol": "BTCUSD"
  }
}
```

---

### Trades

#### Get Public Trades

```
GET /v2/trades/{symbol}
```

No authentication required.

**Response:**

```json
{
  "success": true,
  "result": {
    "trades": [
      { "side": "buy", "size": 0, "price": "string", "timestamp": 0 }
    ]
  }
}
```

---

### Wallet

#### Get Wallet Balances

```
GET /v2/wallet/balances
```

**Requires authentication.**

**Response includes:** `balance`, `available_balance`, `blocked_margin`, `order_margin`, `position_margin`, `portfolio_margin`, `commission`, cross-margin fields, etc.

#### Get Wallet Transactions

```
GET /v2/wallet/transactions
```

**Requires authentication.**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `asset_ids` | int | No | Comma separated |
| `start_time` / `end_time` | int | No | Epoch microseconds |
| `after` / `before` | string | No | Pagination cursors |
| `page_size` | int | No | Records per page |
| `transaction_types` | string | No | Filter by type |

**Transaction types:** `cashflow`, `deposit`, `withdrawal`, `commission`, `conversion`, `funding`, `settlement`, `liquidation_fee`, `spot_trade`, `withdrawal_cancellation`, `referral_bonus`, `sub_account_transfer`, `commission_rebate`, `promo_credit`, `trading_credits`, `interest_credit`, `external_deposit`, `credit_line`, `trading_competition`, `fund_deposit`, `fund_withdrawal`, `fund_reward`, `trade_farming_reward`, `revert`, `raf_bonus`, `fill_appropriation`, `incident_compensation`, and more.

#### Download Wallet Transactions (CSV)

```
GET /v2/wallet/transactions/download
```

#### Subaccount Asset Transfer

```
POST /v2/wallets/sub_account_balance_transfer
```

```json
{
  "transferrer_user_id": "string",
  "transferee_user_id": "string",
  "asset_symbol": "string",
  "amount": 100.0
}
```

Both subaccounts must belong to the same parent account. Use API key from the parent/main account.

#### Subaccount Transfer History

```
GET /v2/wallets/sub_accounts_transfer_history
```

---

### Stats

#### Get Volume Stats

```
GET /v2/stats
```

No authentication required.

```json
{
  "success": true,
  "result": {
    "last_30_days_volume": 0,
    "last_7_days_volume": 0,
    "total_volume": 0
  }
}
```

---

### MMP (Market Maker Protection)

Available to registered market makers. Others can contact support.

#### Update MMP Config

```
PUT /v2/users/update_mmp
```

**Requires authentication.**

```json
{
  "asset": "BTC",
  "window_interval": 60,
  "freeze_interval": 300,
  "trade_limit": "100000",
  "delta_limit": "50000",
  "vega_limit": "10000",
  "mmp": "mmp1"
}
```

| Field | Description |
|---|---|
| `window_interval` | Window in seconds |
| `freeze_interval` | Freeze duration in seconds (0 = manual reset required) |
| `trade_limit` | Notional trade limit in USD |
| `delta_limit` | Delta-adjusted notional limit in USD |
| `vega_limit` | Vega traded limit in USD |
| `mmp` | MMP level: `mmp1` through `mmp5` |

#### Reset MMP

```
PUT /v2/users/reset_mmp
```

```json
{ "asset": "BTC", "mmp": "mmp1" }
```

---

### Account

#### Get User Profile

```
GET /v2/profile
```

**Requires authentication.**

```json
{
  "success": true,
  "result": {
    "id": "98765432",
    "email": "user@example.com",
    "account_name": "Main",
    "first_name": "Rajesh",
    "last_name": "Sharma",
    "country": "India",
    "margin_mode": "isolated",
    "is_sub_account": false,
    "is_kyc_done": true
  }
}
```

#### Get Trading Preferences

```
GET /v2/users/trading_preferences
```

#### Update Trading Preferences

```
PUT /v2/users/trading_preferences
```

```json
{
  "default_auto_topup": true,
  "interest_credit": false,
  "email_preferences": {
    "adl": true, "liquidation": true, "order_fill": true,
    "stop_order_trigger": true, "order_cancel": true, "marketing": true
  },
  "notification_preferences": {
    "adl": false, "liquidation": true, "order_fill": true,
    "stop_order_trigger": true, "price_alert": true, "marketing": true
  }
}
```

#### Get Subaccounts

```
GET /v2/sub_accounts
```

#### Change Margin Mode

```
PUT /v2/users/margin_mode
```

```json
{ "margin_mode": "isolated", "subaccount_user_id": "5112346" }
```

Values: `isolated` or `portfolio`.

#### Get Rate Limit Quota

```
GET /v2/rate_limits/quota
```

No authentication required.

---

### Heartbeat Management (Deadman Switch)

A safety mechanism that automatically cancels orders or widens spreads when your trading bot stops responding.

#### Create Heartbeat

```
POST /v2/heartbeat/create
```

**Requires authentication.**

```json
{
  "heartbeat_id": "my_trading_bot_001",
  "impact": "contracts",
  "contract_types": ["perpetual_futures", "call_options"],
  "underlying_assets": ["BTC", "ETH"],
  "product_symbols": ["BTCUSD", "ETHUSD"],
  "config": [
    { "action": "cancel_orders", "unhealthy_count": 1 },
    { "action": "spreads", "unhealthy_count": 3, "value": 100 }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `heartbeat_id` | Yes | Unique identifier |
| `impact` | Yes | `contracts` or `products` |
| `config[].action` | Yes | `cancel_orders` or `spreads` |
| `config[].unhealthy_count` | Yes | Missed heartbeats before action triggers |

#### Send Heartbeat Acknowledgment

```
POST /v2/heartbeat
```

```json
{ "heartbeat_id": "my_trading_bot_001", "ttl": 30000 }
```

Set `ttl` to `0` to disable.

**Response:**

```json
{
  "success": true,
  "result": {
    "heartbeat_timestamp": "1243453435",
    "process_enabled": "true"
  }
}
```

#### Get Heartbeats

```
GET /v2/heartbeat?heartbeat_id={id}
```

---

### Settlement Prices

```
GET /v2/products/?states=expired
```

Returns expired products with settlement data.

---

### Historical OHLC Candles & Sparklines

#### Get OHLC Candles

```
GET /v2/history/candles
```

No authentication required. Returns up to **2000 candles** per request.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `resolution` | string | Yes | `1m`, `3m`, `5m`, `15m`, `30m`, `1h`, `2h`, `4h`, `6h`, `1d`, `1w` |
| `symbol` | string | Yes | Product symbol. Use `FUNDING:BTCUSD` for funding history, `MARK:BTCUSD` for mark price, `OI:BTCUSD` for open interest. |
| `start` | int | Yes | Unix timestamp (seconds) |
| `end` | int | Yes | Unix timestamp (seconds) |

```python
r = requests.get('https://api.india.delta.exchange/v2/history/candles', params={
    'resolution': '5m',
    'symbol': 'BTCUSD',
    'start': '1685618835',
    'end': '1722511635'
})
```

**Response:**

```json
{
  "success": true,
  "result": [
    { "time": 0, "open": 0, "high": 0, "low": 0, "close": 0, "volume": 0 }
  ]
}
```

#### Get Sparklines

```
GET /v2/history/sparklines?symbols=ETHUSD,MARK:BTCUSD
```

Returns `[timestamp, close_price]` arrays for each symbol.

---

## WebSocket Feed

### Connection Details

| Channel Type | URL |
|---|---|
| **Production Private** | `wss://socket.india.delta.exchange` |
| **Production Public** | `wss://public-socket.india.delta.exchange` |
| **Testnet Private** | `wss://socket-ind.testnet.deltaex.org` |
| **Testnet Public** | `wss://socket-ind-pub.testnet.deltaex.org` |

**Connection limit:** 150 connections per IP per 5 minutes (429 if exceeded).

### Subscribing to Channels

```json
{
  "type": "subscribe",
  "payload": {
    "channels": [
      { "name": "v2/ticker", "symbols": ["BTCUSD", "ETHUSD"] },
      { "name": "l2_orderbook", "symbols": ["BTCUSD"] },
      { "name": "funding_rate", "symbols": ["all"] }
    ]
  }
}
```

Use `["all"]` to receive updates for all contracts. Snapshots are only sent for explicitly listed symbols.

### WebSocket Authentication

Required for private channels. Send after opening the connection:

```json
{
  "type": "key-auth",
  "payload": {
    "api-key": "YOUR_API_KEY",
    "signature": "HMAC_SHA256_OF('GET' + timestamp + '/live')",
    "timestamp": "1234567890"
  }
}
```

**Python authentication example:**

```python
import websocket
import hashlib
import hmac
import json
import time

WEBSOCKET_URL = "wss://socket.india.delta.exchange"
API_KEY = 'YOUR_API_KEY'
API_SECRET = 'YOUR_API_SECRET'

def generate_signature(secret, message):
    message = bytes(message, 'utf-8')
    secret = bytes(secret, 'utf-8')
    hash = hmac.new(secret, message, hashlib.sha256)
    return hash.hexdigest()

def on_open(ws):
    method = 'GET'
    timestamp = str(int(time.time()))
    path = '/live'
    signature = generate_signature(API_SECRET, method + timestamp + path)
    ws.send(json.dumps({
        "type": "key-auth",
        "payload": {
            "api-key": API_KEY,
            "signature": signature,
            "timestamp": timestamp
        }
    }))

def on_message(ws, message):
    data = json.loads(message)
    if data['type'] == 'key-auth':
        if data['success']:
            # Subscribe to private channels
            ws.send(json.dumps({
                "type": "subscribe",
                "payload": {
                    "channels": [
                        {"name": "orders", "symbols": ["all"]},
                        {"name": "positions", "symbols": ["all"]}
                    ]
                }
            }))
    else:
        print(data)

ws = websocket.WebSocketApp(WEBSOCKET_URL, on_message=on_message, on_open=on_open)
ws.run_forever()
```

**Auth success response:**

```json
{"type": "key-auth", "success": true, "status_code": 200, "status": "authenticated"}
```

**To unsubscribe from private channels:**

```json
{"type": "unauth", "payload": {}}
```

### Public Channels

#### `ticker`

Price data updated every 5 seconds. Subscribe with specific symbols or option chain (`BTC-310326` for all BTC options expiring 31 Mar 2026).

**Response fields:** product_id, symbol, OHLC, mark_price, greeks (delta/gamma/theta/vega/rho), quotes (bid/ask/IV), open interest, turnover, spot_price.

#### `ob_l1`

Best bid/ask (top of book). Publish interval: 100ms. Supports option chain subscriptions.

#### `ob_l2`

Top 15 levels of orderbook. Max 100 symbols per connection. Publish interval: 500ms.

#### `ob_updates`

Full orderbook via snapshot + incremental updates. Publish interval: 100ms. Uses `seq` field for gap detection and `cs` checksum for validation.

#### `trades`

Real-time public trades feed. Supports category subscriptions (`perpetual_futures`, `call_options`), option chains (`BTC-150426`), or `all`.

**Response:** `{p: price, s: size, S: side, sy: symbol, t: timestamp}`

#### `mark_price`

Mark prices at 2-second intervals. Prefix symbols with `MARK:` (e.g. `MARK:C-BTC-69500-150426`).

#### `candlesticks`

OHLC candle updates. Channel name: `candlestick_{resolution}` (e.g. `candlestick_5m`).

Resolutions: `1m`, `3m`, `5m`, `15m`, `30m`, `1h`, `2h`, `4h`, `6h`, `12h`, `1d`, `1w`

Use `MARK:BTCUSD` for mark price candles, `BTCUSD` for last traded price candles.

#### `spot_price`

Underlying index prices (real-time). Symbols must be specified — `all` not supported.

#### `spot_30mtwap_price`

30-minute TWAP of underlying index prices (used for options settlement).

#### `funding_rate`

Real-time funding rates for perpetual contracts.

**Response:** `{fr: funding_rate, nfr: next_funding_realization, sy: symbol}`

#### `product_updates`

Market disruption, auction start/finish events. Auto-subscribes to all products.

#### `system_status`

System state updates: `live`, `maintenance`, `api_fallback`, `degraded_mode`.

### Private Channels

> All private channels require authentication first.

#### `margins`

Wallet balance and margin updates per asset. Triggered on any change.

**Fields:** `balance`, `available_balance`, `blocked_margin`, `order_margin`, `position_margin`, `commission`, cross-margin fields, `portfolio_margin`.

#### `positions`

Position updates on trade executions. Sends snapshot on subscribe, then incremental updates.

**Actions:** `create`, `update`, `delete`

**Key fields:** `size` (negative=short, positive=long), `entry_price`, `margin`, `liquidation_price`, `bankruptcy_price`, `commission`, `realized_pnl`.

#### `orders`

Order lifecycle updates. Snapshot of open/pending orders on subscribe, then incremental updates with `seq_no`.

**Actions:** `create`, `update`, `delete`

**Reasons:** `fill`, `stop_update`, `stop_trigger`, `stop_cancel`, `liquidation`, `self_trade`

#### `user_trades`

Fill notifications. Includes `reason` (`normal` or `adl`), `side`, `size`, `price`, `role` (taker/maker).

#### `v2/user_trades`

Faster version of user_trades (without commission data). Includes `reason`: `normal`, `adl`, `liquidation`.

#### `portfolio_margins`

Portfolio margin updates every 2 seconds (only if portfolio margin is enabled).

**Fields:** `blocked_margin`, `im_w_ucf`, `mm_w_ucf`, `positions_upl`, `risk_margin`, `liquidation_risk`, `margin_shortfall`.

#### `mmp_trigger`

Triggered when MMP is activated.

```json
{
  "user_id": 1,
  "asset": "BTC",
  "frozen_till": 1561634049751430
}
```

---

## Order Error Codes

| Code | Description |
|---|---|
| `insufficient_margin` | Not enough margin for order |
| `order_size_exceed_available` | Insufficient orderbook liquidity |
| `risk_limits_breached` | Would breach risk limits |
| `invalid_contract` | Product doesn't exist or expired |
| `immediate_liquidation` | Order would cause immediate liquidation |
| `out_of_bankruptcy` | Price beyond bankruptcy limits |
| `self_matching_disrupted_post_only` | Self-matching during auction |
| `immediate_execution_post_only` | Post-only order would execute immediately |

---

## HTTP Error Codes

| Status | Description |
|---|---|
| 400 | Bad Request — Invalid request |
| 401 | Unauthorized — Wrong API key/signature |
| 403 | Forbidden — Request blocked by CDN (missing User-Agent or blocked IP) |
| 404 | Not Found |
| 405 | Method Not Allowed |
| 406 | Not Acceptable — Non-JSON format requested |
| 429 | Too Many Requests — Rate limit exceeded |
| 500 | Internal Server Error |
| 503 | Service Unavailable — Maintenance |

---

## REST Clients & SDKs

| Language | Package |
|---|---|
| **Python** | [delta-rest-client (PyPI)](https://pypi.org/project/delta-rest-client) |
| **Node.js** | [delta-rest-client (npm)](https://www.npmjs.com/package/delta-rest-client) |
| **CCXT** | [ccxt.trade](https://ccxt.trade/) — Authorized SDK provider |

Swagger spec: [https://docs.delta.exchange/api/swagger_v2.json](https://docs.delta.exchange/api/swagger_v2.json)

---

## Schemas Reference

### Asset

```json
{
  "id": 14,
  "symbol": "USD",
  "precision": 8,
  "deposit_status": "enabled",
  "withdrawal_status": "enabled",
  "base_withdrawal_fee": "0.000000000000000000",
  "min_withdrawal_amount": "0.000000000000000000"
}
```

### Product

| Field | Type | Description |
|---|---|---|
| `id` | int | Unique product identifier |
| `symbol` | string | e.g. `BTCUSD` |
| `contract_type` | string | `perpetual_futures`, `call_options`, `put_options` |
| `state` | string | `live`, `expired`, `upcoming` |
| `trading_status` | string | `operational`, `disrupted_cancel_only`, `disrupted_post_only` |
| `notional_type` | string | `vanilla`, `inverse` |
| `tick_size` | string | Minimum price increment |
| `contract_value` | string | Notional value of one contract |
| `initial_margin` | string | Required to open position |
| `maintenance_margin` | string | Required to maintain position |
| `taker_commission_rate` | string | Taker fee rate |
| `maker_commission_rate` | string | Maker fee rate |
| `max_leverage_notional` | string | Max notional at highest leverage |
| `default_leverage` | string | Default leverage |
| `price_band` | string | Allowed range around mark price (%) |
| `underlying_asset` | Asset | Underlying asset details |
| `quoting_asset` | Asset | Quoting asset details |
| `settling_asset` | Asset | Settling asset details |
| `spot_index` | Index | Index details |

### Order

| Field | Type | Description |
|---|---|---|
| `id` | int | Order ID |
| `user_id` | int | User ID |
| `size` | int | Order size |
| `unfilled_size` | int | Remaining unfilled size |
| `side` | string | `buy` / `sell` |
| `order_type` | string | `limit_order` / `market_order` |
| `limit_price` | string | Limit price |
| `stop_order_type` | string | `stop_loss_order` |
| `stop_price` | string | Stop trigger price |
| `paid_commission` | string | Commission paid |
| `reduce_only` | bool | Close-only order |
| `client_order_id` | string | Custom order ID (max 32 chars) |
| `state` | string | `open` / `pending` / `closed` / `cancelled` |
| `created_at` | string | Unix timestamp (microseconds) |
| `product_id` | int | Product ID |
| `product_symbol` | string | Product symbol |

### Position

| Field | Type | Description |
|---|---|---|
| `user_id` | int | User ID |
| `size` | int | Negative = short, positive = long |
| `entry_price` | string | Average entry price |
| `margin` | string | Blocked margin |
| `liquidation_price` | string | Liquidation trigger price |
| `bankruptcy_price` | string | Bankruptcy price |
| `adl_level` | int | ADL level |
| `product_id` | int | Product ID |
| `product_symbol` | string | Product symbol |
| `commission` | string | Commissions blocked |
| `realized_pnl` | string | Net realized PnL |
| `realized_funding` | string | Net realized funding |

### Fill

| Field | Type | Description |
|---|---|---|
| `id` | int | Fill ID |
| `size` | int | Fill size |
| `fill_type` | string | `normal`, `adl`, `liquidation`, `settlement`, `otc` |
| `side` | string | `buy` / `sell` |
| `price` | string | Fill price |
| `role` | string | `taker` / `maker` |
| `commission` | string | Commission paid |
| `order_id` | string | Order ID |
| `product_id` | int | Product ID |

### Wallet

| Field | Type | Description |
|---|---|---|
| `asset_id` | int | Asset ID |
| `asset_symbol` | string | Asset symbol |
| `balance` | string | Total wallet balance |
| `available_balance` | string | Balance available for trading |
| `blocked_margin` | string | Total blocked margin |
| `order_margin` | string | Margin in open orders (isolated) |
| `position_margin` | string | Margin in positions (isolated) |
| `portfolio_margin` | string | Portfolio margin mode blocked |
| `commission` | string | Commissions blocked |
| `cross_order_margin` | string | Cross margin orders |
| `cross_position_margin` | string | Cross margin positions |

### Greeks (Options)

| Field | Description |
|---|---|
| `delta` | Sensitivity to underlying price |
| `gamma` | Rate of change of delta |
| `theta` | Time decay |
| `vega` | Sensitivity to volatility |
| `rho` | Sensitivity to interest rate |

### L2 Orderbook

```json
{
  "buy": [{ "depth": "983", "price": "9187.5", "size": 205640 }],
  "sell": [{ "depth": "1185", "price": "9188.0", "size": 113752 }],
  "last_updated_at": 1654589595784000,
  "symbol": "BTCUSD"
}
```

### OHLC Data

```json
{ "time": 0, "open": 0, "high": 0, "low": 0, "close": 0, "volume": 0 }
```

---

## Source

Official documentation: [https://docs.delta.exchange](https://docs.delta.exchange)

Delta Exchange India: [https://www.delta.exchange](https://www.delta.exchange)
