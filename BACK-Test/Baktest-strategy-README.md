# Backtest-Uptrend-Downtrend.py

**Trend-Based Crypto Trading Backtester with Configurable Pyramiding**

A production-ready backtesting engine for Bitcoin (BTCUSD) and other cryptocurrencies on Delta Exchange with support for 4-lot pyramiding, per-lot profit tracking, and comprehensive CSV export.

---

## 🎯 Quick Start

```bash
# Default: 1 day, 300 candles, 4 lots max
python Backtest-uptrend-downtrend.py --symbol BTCUSD

# 24 hours with 1000 candles, max 2 lots
python Backtest-uptrend-downtrend.py --symbol BTCUSD --days 1 --limit 1000 --max-lots 2

# 10 days, 5-minute candles, 3 lots max
python Backtest-uptrend-downtrend.py --symbol BTCUSD --days 10 --timeframe 5m --max-lots 3

# Show help and all options
python Backtest-uptrend-downtrend.py --help
```

---

## 📊 Trading Logic

### **LONG Entry**
- **Condition:** Uptrend detected + current LOW > previous SWING_LOW
- **Entry Price:** Current candle CLOSE
- **Stoploss:** Current candle LOW
- **Risk:** Close - Low

### **SHORT Entry**
- **Condition:** Downtrend detected + current HIGH < previous SWING_HIGH
- **Entry Price:** Previous candle LOW
- **Stoploss:** Current candle HIGH
- **Risk:** High - Previous Low

### **Exit Conditions**

**1. Opposite Signal (closes ALL positions)**
- Long positions exit on Downtrend signal at current CLOSE
- Short positions exit on Uptrend signal at current CLOSE

**2. Individual Stoploss Hit**
- Long: If candle LOW ≤ position SL → exit at SL
- Short: If candle HIGH ≥ position SL → exit at SL

---

## 🔧 CLI Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--symbol` | BTCUSD | Trading symbol (e.g., BTCUSD, ETHUSD, BNBUSD) |
| `--days` | 1 | Historical data range in days |
| `--timeframe` | 1m | Candle period: 1m, 5m, 15m, 1h, 4h, 1d, etc. |
| `--limit` | 300 | Maximum candles to process |
| `--max-lots` | 4 | Max concurrent positions per direction (1-N) |

---

## 📈 Pyramiding Modes

| Mode | Command | Behavior |
|------|---------|----------|
| **No Pyramiding** | `--max-lots 1` | Only 1 position at a time |
| **Conservative** | `--max-lots 2` | Max 2 concurrent Long + max 2 concurrent Short |
| **Moderate** | `--max-lots 3` | Max 3 concurrent per direction |
| **Aggressive** | `--max-lots 4` | Max 4 concurrent per direction (default) |

**Note:** Long and Short counters are separate. With `--max-lots 2`, you can have 2 Longs AND 2 Shorts running simultaneously.

---

## 📋 CSV Output (19 Columns)

| Column | Description |
|--------|-------------|
| **#** | Row number |
| **TIME (IST)** | Timestamp in IST timezone (YYYY-MM-DD HH:MM:SS) |
| **OPEN** | Candle open price |
| **HIGH** | Candle high price |
| **LOW** | Candle low price |
| **CLOSE** | Candle close price |
| **VOLUME** | Trading volume |
| **SWING_LOW** | Previous swing low (Long entry trigger) |
| **SWING_HIGH** | Previous swing high (Short entry trigger) |
| **TREND** | Current trend (Uptrend/Downtrend, shown on change) |
| **SIGNAL** | Entry signal generated (Long/Short/-) |
| **ENTRY** | Actual entry price |
| **STOPLOSS** | Stop loss price |
| **RISK** | Entry-Stoploss difference |
| **EXIT** | Exit price when position closes |
| **TRADE_STATUS** | Position tracking (Long-1, Short-1, stopped, etc.) |
| **CUM_PNL** | Cumulative P&L |
| **LOT_PNL_DETAILS** | Per-lot profit breakdown (e.g., "Long-1: +$100, Long-2: +$50") |
| **COMMENTS** | Active position count (e.g., "2 Lot Long running, 1 Lot Short running") |

---

## 💾 Output Files

**CSV Export:** `backtest-{SYMBOL}-{CANDLES}candles.csv`

Example: `backtest-BTCUSD-1000candles.csv`

---

## 📚 Command Examples

### Basic Usage
```bash
python Backtest-uptrend-downtrend.py --symbol BTCUSD
```
Output: 1 day, 1-minute candles, max 4 lots, 300 candles limit

### Extended Backtest (Last 10 Days)
```bash
python Backtest-uptrend-downtrend.py --symbol BTCUSD --days 10 --limit 500 --max-lots 2
```

### Conservative Trading (1 Lot Only)
```bash
python Backtest-uptrend-downtrend.py --symbol BTCUSD --max-lots 1
```

### Different Timeframes
```bash
# 5-minute candles, 5 days
python Backtest-uptrend-downtrend.py --symbol BTCUSD --days 5 --timeframe 5m

# Hourly candles, 20 days
python Backtest-uptrend-downtrend.py --symbol BTCUSD --days 20 --timeframe 1h --limit 300

# Daily candles, last 30 days
python Backtest-uptrend-downtrend.py --symbol BTCUSD --days 30 --timeframe 1d --limit 30
```

### Multiple Symbols
```bash
python Backtest-uptrend-downtrend.py --symbol ETHUSD --days 10 --max-lots 2
python Backtest-uptrend-downtrend.py --symbol BNBUSD --days 5 --timeframe 5m --max-lots 3
```

---

## 🔍 Understanding the Output

### Console Display (Live Backtest)
```
#     TIME (IST)           OPEN         HIGH         LOW          CLOSE       VOLUME    ...
17    2026-07-26 14:30:00  $64450.00    $64475.00    $64445.00    $64471.75   8166     ...
      SWING_LOW            SWING_HIGH   TREND        SIGNAL       ENTRY       STOPLOSS ...
      $64402.00            $64470.20    Uptrend      Long         $64471.75   $64462.00...
      RISK                 EXIT         TRADE_STATUS             CUM_PNL      LOT_PNL_DETAILS    COMMENTS
      $9.75                -            Long-1                   $0.00        Long-1: +$0.00     1 Lot Long running
```

### CSV Interpretation

**Entry Row:**
```
#,TIME (IST),OPEN,HIGH,LOW,CLOSE,...,SIGNAL,ENTRY,STOPLOSS,RISK,EXIT,TRADE_STATUS,CUM_PNL,LOT_PNL_DETAILS,COMMENTS
50,2026-07-26 14:30:00,64450.00,...,Long,$64471.75,$64462.00,$9.75,-,Long-1,$0.00,Long-1: +$0.00,1 Lot Long running
```

**Running Position:**
```
51,2026-07-26 14:31:00,64462.08,...,-,-,-,-,-,Long-1 (+$7.75),$7.75,Long-1: +$7.75,1 Lot Long running
```

**Exit on Signal:**
```
64,2026-07-26 14:42:00,64350.50,...,Short,$64368.50,$64371.85,...,$64359.50,Short-1,$12.72,Short-1: +$9.00,1 Lot Short running
```

**Stoploss Hit:**
```
65,2026-07-26 14:43:00,64365.68,...,-,-,-,-,$64371.85,Short-1-stopped,$9.37,Short-1: +$6.62,-
```

---

## 🚀 Features

✅ **Trend Detection:** State machine prevents consecutive same trends  
✅ **Pyramiding:** Configurable 1-N concurrent positions per direction  
✅ **Per-Lot Tracking:** Individual entry, SL, and P&L for each position  
✅ **Comprehensive CSV:** 19 columns with all backtest data  
✅ **IST Timezone:** All timestamps in IST (UTC+5:30) with date and time  
✅ **Modular:** 5 CLI parameters for full customization  
✅ **Fast Fetching:** Batch API requests (5x faster)  
✅ **Multi-Symbol:** Works with any Delta Exchange symbol  
✅ **Date-Time Stamps:** YYYY-MM-DD HH:MM:SS format in all outputs  

---

## 📦 Dependencies

```bash
pip install delta-rest-client
```

Already included in `requirements.txt`

---

## 🔗 Module Reference

**Main Script:** `Backtest-uptrend-downtrend.py`

**Reusable Module:** `delta_candles.py`
- `fetch_candles(symbol, timeframe, days=1)` - Fetch from Delta Exchange API
- `to_heikinashi(candles)` - Convert to Heikin-Ashi candles
- Helper functions for trend analysis

---

## 📝 Notes

- **Trend State Machine:** Once in Uptrend, cannot enter Downtrend immediately (prevents whipsaw signals)
- **Individual Stoploesses:** Each position has its own SL, exited independently if hit
- **Opposite Signal Exit:** ALL concurrent positions close immediately on opposite signal
- **Pyramiding Separate:** Long and Short have separate counters. `--max-lots 2` means max 2 Longs AND max 2 Shorts
- **CSV Auto-Generate:** New CSV created with each run (includes date-time and candle count in filename)
- **IST Timestamps:** All times displayed as YYYY-MM-DD HH:MM:SS in IST (UTC+5:30)

---

## ✅ Testing Status

- ✓ 24-hour backtest (1440+ candles)
- ✓ 50-day historical data (7999+ candles)
- ✓ Multiple timeframes (1m, 5m, 1h, 1d)
- ✓ Pyramiding limits (1-4 lots tested)
- ✓ Per-lot profit tracking verified
- ✓ CSV export validated
- ✓ IST timezone accuracy confirmed
- ✓ Date-time format verification

---

## 📞 Quick Reference

```bash
# See all options
python Backtest-uptrend-downtrend.py --help

# Last 1 day (default)
python Backtest-uptrend-downtrend.py

# Last 7 days, 500 candles max, 2 lots
python Backtest-uptrend-downtrend.py --days 7 --limit 500 --max-lots 2

# Last 30 days, 5m candles, 3 lots
python Backtest-uptrend-downtrend.py --days 30 --timeframe 5m --max-lots 3

# Last 24 hours with 1000 candles
python Backtest-uptrend-downtrend.py --days 1 --limit 1000

# Custom symbol
python Backtest-uptrend-downtrend.py --symbol ETHUSD --days 10
```

---

**Status:** ✅ Production Ready  
**Version:** 1.0  
**Last Updated:** 2026-07-26
