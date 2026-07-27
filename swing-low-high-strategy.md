# Swing Low/High Strategy Documentation

## Overview
This document describes the Swing Low/High breakout trading strategy implemented in the Zerodha Trading Bot. The strategy uses Heikin Ashi candles to identify swing levels and execute trades based on breakout signals.

---

## Trading Logic

### Signal Generation

#### LONG Entry Signal
**Condition:** Current Heikin Ashi Close > Previous Candle High
```
HA Close(current) > HA High(previous)
```
- Represents a breakout above the previous resistance level
- Entry occurs when price exceeds the previous candle's high
- Indicates upward momentum continuation

#### SHORT Entry Signal
**Condition:** Current Heikin Ashi Close < Previous Candle Low
```
HA Close(current) < HA Low(previous)
```
- Represents a breakdown below the previous support level
- Entry occurs when price falls below the previous candle's low
- Indicates downward momentum continuation

#### Exit Signals
**LONG Exit:** Current HA Close < Previous Candle Low
- Exit position when price breaks below the previous low
- Locks in profit or cuts losses

**SHORT Exit:** Current HA Close > Previous Candle High
- Exit position when price breaks above the previous high
- Locks in profit or cuts losses

### Position States
- **FLAT**: No active position, waiting for entry signal
- **LONG**: Long position active, monitoring for exit signal
- **SHORT**: Short position active, monitoring for exit signal

---

## How to Identify Swing Low

### Parameters for Swing Low Identification

1. **HA Close > Previous HA High** (Primary Condition)
   - Current Heikin Ashi close must break above the previous candle's high
   - This is the entry trigger condition
   - Indicates swing low setup is valid

2. **Current Candle's Low Value** (Swing Low Level)
   - The lowest price within the entry candle
   - Used as stop loss for LONG position
   - Calculated from raw OHLC data

3. **Trading Window** (Time Constraint)
   - Must be within market hours: 09:16:01 to 16:00:00
   - Prevents entry outside trading hours
   - IST timezone based

4. **Position State** (Trade Management)
   - No existing position: `Direction == ''`
   - Cannot enter new position if already in a trade
   - Ensures single position at a time

5. **Timeframe/Candle Interval** (Technical Parameter)
   - 15-second Heikin Ashi candles (configurable)
   - HA Close = (Open + High + Low + Close) / 4
   - HA Open = (Previous HA Open + Previous HA Close) / 2
   - HA High = MAX(High, HA Open, HA Close)
   - HA Low = MIN(Low, HA Open, HA Close)

### Swing Low Detection Summary
```
Swing Low = The Low price of the candle where:
  ✓ HA Close > Previous HA High (breakout signal)
  ✓ Within trading window (09:16:01 - 16:00:00)
  ✓ No active position exists
  ✓ Using 15-second HA candles
```

---

## Value of Swing Low (SL)

### What SL Represents
- **Support Level**: The lowest price point at the moment of entry
- **Stop Loss Level**: Price level below which the trade is exited (loss containment)
- **Risk Reference**: Used to calculate maximum risk per trade

### Which Candle Values Become SL

| Entry Type | Signal Trigger | SL Source |
|-----------|----------------|-----------|
| **LONG** | HA Close > Previous High | **Current** Candle's **Low** |
| **SHORT** | HA Close < Previous Low | **Current** Candle's **High** |

### Example from Live Trading
```
2026-07-24 15:27:00      23,781.35      23,775.41      23,779.30     LONG 23,775.41
                         High           Low            Close          SL
```

**Calculation:**
- Entry Signal: HA Close (23,779.30) > Previous High (23,773.98) ✓
- SL Assignment: SL = Current Candle Low = 23,775.41
- This becomes the stop loss for the LONG position

### SL Formula
```powershell
For LONG Entry:
  $State.SwingLow = $currentRaw.Low

For SHORT Entry:
  $State.SwingHigh = $currentRaw.High
```

---

## Perfect Entry Calculation

### Perfect Entry Definition
A **perfect entry** occurs when the stop loss level improves compared to the previous entry of the same direction, indicating better entry conditions and tighter risk management.

### Perfect Entry Conditions

#### LONG Perfect Entry
**Condition:** Current SL > Previous SL
```
Current SwingLow > Previous SwingLow
```
- The new swing low is higher than the previous one
- Indicates stronger support (lower risk)
- Better entry than the previous LONG trade

**Example:**
```
Previous LONG Entry SL: 23,779.15
Current LONG Entry SL:  23,776.10
Result: 23,776.10 < 23,779.15 → NOT Perfect (SL worsened)

Previous LONG Entry SL: 23,772.90
Current LONG Entry SL:  23,776.10
Result: 23,776.10 > 23,772.90 → ✓ PERFECT (SL improved)
```

#### SHORT Perfect Entry
**Condition:** Current SH < Previous SH
```
Current SwingHigh < Previous SwingHigh
```
- The new swing high is lower than the previous one
- Indicates weaker resistance (lower risk)
- Better entry than the previous SHORT trade

**Example:**
```
Previous SHORT Entry SH: 23,775.95
Current SHORT Entry SH:  23,775.35
Result: 23,775.35 < 23,775.95 → ✓ PERFECT (SH improved)

Previous SHORT Entry SH: 23,775.35
Current SHORT Entry SH:  23,775.95
Result: 23,775.95 > 23,775.35 → NOT Perfect (SH worsened)
```

### Perfect Entry Detection Logic

```powershell
# LONG Perfect Entry
if ($State.PreviousSwingLow -gt 0 -and $State.SwingLow -gt $State.PreviousSwingLow) {
    Write-Host "---------> perfect Long entry"
}

# SHORT Perfect Entry
if ($State.PreviousSwingHigh -gt 0 -and $State.SwingHigh -lt $State.PreviousSwingHigh) {
    Write-Host "---------> perfect Short entry"
}
```

### Perfect Entry Requirements
1. **Previous Level Exists**: Must have at least one prior entry of the same direction
   - `PreviousSwingLow > 0` for LONG
   - `PreviousSwingHigh > 0` for SHORT

2. **Improved Condition**:
   - LONG: Current SL > Previous SL (higher support)
   - SHORT: Current SH < Previous SH (lower resistance)

3. **Swing History Tracking**:
   - Maintains last 2 swing levels for each direction
   - `SwingLowHistory` for LONG entries
   - `SwingHighHistory` for SHORT entries

### Perfect Entry Signal Display
```
ENTRY SHORT @ 23772.4 | SH: 23,775.35 | Previous SH: 23,775.95
---------> perfect Short entry

ENTRY LONG @ 23781.35 | SL: 23,776.10 | Previous SL: 23,779.15
```

The signal displays both current and previous values for easy comparison.

### Benefits of Perfect Entry
- **Improved Risk**: Tighter stop loss = smaller maximum loss
- **Better Entry Quality**: Indicates swing pattern strengthening
- **Reduced Risk/Reward Ratio**: Better risk management
- **Trend Confirmation**: Successive improved entries confirm trend strength

---

## Implementation Details

### State Variables
```powershell
$State.SwingLow              # Current LONG entry swing low
$State.SwingHigh             # Current SHORT entry swing high
$State.PreviousSwingLow      # Previous LONG entry swing low (for perfect entry check)
$State.PreviousSwingHigh     # Previous SHORT entry swing high (for perfect entry check)
$State.SwingLowHistory       # List of last 2 swing lows
$State.SwingHighHistory      # List of last 2 swing highs
$State.Direction             # 'LONG' | 'SHORT' | ''
$State.EntryPrice            # Entry price of current position
$State.EntryTime             # Timestamp of entry
```

### Candle Building
- **TimeFrame**: 15-second intervals (configurable in input.json)
- **Aggregation**: Ticks grouped by 15-second buckets
- **HA Conversion**: Applied after candle completion
- **Display**: Last 5-19 visible candles (depends on data available)

### Entry/Exit Workflow
1. Monitor incoming ticks for signal conditions
2. Detect breakout (HA Close crossing previous High/Low)
3. Record swing level from current candle
4. Compare with previous swing level
5. Mark if perfect entry condition met
6. Execute paper trade (simulated, no real order)
7. Monitor for exit signal
8. Record exit with P&L
9. Clear position state for next signal

---

## Configuration

### input.json Parameters
```json
{
  "TimeFrame": "15second",        // Candle interval
  "AmountToTrade": 10000,         // Capital per trade
  "NoOfLotsPurchaseAtaTime": 1,   // Lot size multiplier
  "LotSize": 65,                  // Nifty lot size
  "Product": "NRML",              // Product type
  "Order_type": "MARKET",         // Order execution type
  "StartTime": "09:16:01",        // Trading window start
  "StopTime": "16:00:00",         // Trading window end
  "ATMOffset": 1                  // Option strike selection
}
```

---

## Test Results Summary

### Sample Trading Session
```
Total Candles: 19
Total P&L: -292.50

Trade Signals:
1. ENTRY LONG @ 23782.1 | SL: 23,779.15
   EXIT LONG @ 23773.85 | P&L: -8.25

2. ENTRY SHORT @ 23774.65 | SH: 23,775.95
   EXIT SHORT @ 23777.75 | P&L: +3.10

3. ENTRY SHORT @ 23772.4 | SH: 23,775.35 | Previous SH: 23,775.95
   ---------> perfect Short entry
   EXIT SHORT @ 23779.2 | P&L: +6.80

4. ENTRY LONG @ 23781.35 | SL: 23,776.10 | Previous SL: 23,779.15
   (Active position)
```

**Key Observations:**
- ✅ Swing low/high correctly identified and recorded
- ✅ Perfect entry detection working (SHORT entry showed improvement)
- ✅ Previous swing values displayed for comparison
- ✅ Entry and exit signals triggering as expected
- ✅ Table display showing signals only on entry rows

---

## Summary

The Swing Low/High strategy is a breakout-based approach that:
1. **Identifies swing levels** using Heikin Ashi close price breakouts
2. **Sets stop loss** at the candle's extreme (low for LONG, high for SHORT)
3. **Validates entry quality** by comparing with previous entries (perfect entry)
4. **Manages risk** through systematic position entry/exit
5. **Tracks history** of last 2 swing levels for trend analysis

Perfect entries indicate strengthening trends with improved stop loss placement, providing higher quality trade setups.
