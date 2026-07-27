# Swing Low/High Strategy Pine Script Indicator

## Overview
This Pine Script indicator implements the Swing Low/High breakout strategy with visual entry/exit markers and labels on TradingView charts.

## Features

### 1. **Heikin Ashi Calculation**
- Calculates Heikin Ashi candles from raw OHLC data
- Uses HA Close for breakout detection
- Formula:
  - HA Close = (Open + High + Low + Close) / 4
  - HA Open = (Prev HA Open + Prev HA Close) / 2
  - HA High = MAX(High, HA Open, HA Close)
  - HA Low = MIN(Low, HA Open, HA Close)

### 2. **Entry Signals**

#### LONG Entry (Green Label "L")
**Conditions:**
- Current HA Close > Previous HA High (breakout signal)
- Current Swing Low > Previous Swing Low (perfect entry filter)
- Displays: "ENTRY LONG" with SL value

#### SHORT Entry (Red Label "S")
**Conditions:**
- Current HA Close < Previous HA Low (breakdown signal)
- Current Swing High < Previous Swing High (perfect entry filter)
- Displays: "ENTRY SHORT" with SH value

### 3. **Exit Signals**

#### LONG Exit (Orange X)
**Conditions:**
- SHORT signal triggered (HA Close < Previous HA Low)
- Current Swing High < Previous Swing Low (swing comparison)
- Displays: "EXIT LONG" with SH value

#### SHORT Exit (Orange X)
**Conditions:**
- LONG signal triggered (HA Close > Previous HA High)
- Current Swing Low > Previous Swing High (swing comparison)
- Displays: "EXIT SHORT" with SL value

## Chart Visualization

### Markers
- **Green "L"** → LONG Entry
- **Red "S"** → SHORT Entry
- **Orange X** → Exit (both LONG and SHORT)

### Labels
- Green boxes → LONG entries with SL level
- Red boxes → SHORT entries with SH level
- Orange boxes → Exits with swing level reference

### Bar Colors
- Green highlighted → LONG entry bar
- Red highlighted → SHORT entry bar

### Plots
- Blue line → Heikin Ashi Close
- Gray lines → HA High and HA Low (for reference)

## Settings & Inputs

```
Heikin Ashi Method: "Traditional" (dropdown)
Show Entry/Exit Labels: Toggle (default: ON)
Show Signal Markers: Toggle (default: ON)
Label Offset: 20 pips (adjustable based on timeframe)
```

### How to Adjust Label Offset
- **1-minute chart**: 5-10 pips
- **5-minute chart**: 15-20 pips
- **15-minute chart**: 20-30 pips
- **1-hour chart**: 30-50 pips

## How to Use in TradingView

### Step 1: Copy the Script
1. Copy the full Pine Script code from `swing-low-high-indicator.pine`

### Step 2: Create New Indicator
1. Open TradingView
2. Go to Chart → Pine Script Editor (or Shift+Click on chart)
3. Click "New Study" or "Create New"
4. Paste the entire script into the editor

### Step 3: Save & Apply
1. Click "Save" and give it a name: "Swing Low/High Strategy"
2. Click "Add to Chart"
3. The indicator will overlay on your chart

### Step 4: Customize Settings
1. Right-click on the indicator name
2. Select "Settings"
3. Adjust:
   - Show Entry/Exit Labels
   - Show Signal Markers
   - Label Offset (based on your timeframe)

## Signal Logic

### Perfect Entry Concept
The indicator uses "perfect entry" filtering to avoid low-quality entries:

**LONG Perfect Entry**
```
Entry occurs if:
  1. HA Close > Previous HA High (breakout)
  2. AND Current SL > Previous SL (swing improved)
```

**SHORT Perfect Entry**
```
Entry occurs if:
  1. HA Close < Previous HA Low (breakdown)
  2. AND Current SH < Previous SH (swing improved)
```

### Swing-Level Exit Concept
Exits use swing level comparisons for better exit timing:

**LONG Exit**
```
Exit occurs if:
  1. SHORT signal triggered (HA Close < Prev Low)
  2. AND Current SH < Previous SL (break below support)
```

**SHORT Exit**
```
Exit occurs if:
  1. LONG signal triggered (HA Close > Prev High)
  2. AND Current SL > Previous SH (break above resistance)
```

## Example Signals on Chart

```
Entry: LONG @ 23,781.35
SL: 23,776.10
(Previous SL: 23,779.15) ← Perfect - SL improved

↓ (No exit yet, holding position)

Exit Signal: SHORT @ 23,777.95
SH: 23,775.35
(Previous SL: 23,776.10) → SH < Prev SL? Check if true
(If true → EXIT LONG)

Entry: SHORT @ 23,774.90
SH: 23,775.60
(Previous SH: 23,775.95) ← Perfect - SH improved
```

## Multi-Timeframe Usage

The indicator works across all timeframes:
- **1m, 5m, 15m** → Intraday scalping/swing
- **1h, 4h** → Swing trading
- **Daily** → Position trading

Adjust the `Label Offset` for each timeframe to prevent label overlapping.

## Alerts (Optional)

The indicator includes built-in alerts:
- "LONG ENTRY - SL: [value]"
- "SHORT ENTRY - SH: [value]"
- "LONG EXIT - SH: [value]"
- "SHORT EXIT - SL: [value]"

To enable alerts:
1. Click the indicator settings (gear icon)
2. Enable "Create Alert" for each trigger
3. Set notification method (popup, email, webhook, SMS)

## Limitations

1. **Backtest Mode**: Alerts trigger only once per bar close
2. **Repaint Risk**: Some values recalculate during bar formation
3. **Past Performance**: Not indicative of future results
4. **Market Hours**: No built-in trading window filter (add manually if needed)

## Customization Tips

### Add Risk/Reward Label
```pine
riskPoints = currSwingLow
rewardPoints = high - close
rrRatio = rewardPoints / riskPoints
label.new(..., text="R/R: " + str.tostring(rrRatio, "0.00"))
```

### Filter by Session
```pine
inSession = time >= timestamp("01 Jan 2024 09:16") and time <= timestamp("01 Jan 2024 16:00")
longPerfectEntry = longPerfectEntry and inSession
```

### Add Volume Confirmation
```pine
volumeCondition = volume > ta.sma(volume, 20)
longPerfectEntry = longPerfectEntry and volumeCondition
```

## Troubleshooting

### Labels Not Showing
- Increase `Label Offset` value
- Check "Show Entry/Exit Labels" is enabled
- Zoom in on chart

### Signals Appearing Late
- This is normal - strategy confirms on bar close
- For real-time alerts, modify `alert.freq_once_per_bar_close` to `alert.freq_once_per_bar`

### Inaccurate Swing Levels
- Verify OHLC data is correct
- Check that Heikin Ashi calculation is enabled in chart settings
- Ensure using correct timeframe

## Performance Optimization

For charts with long history (1000+ bars):
- Reduce chart range displayed
- Disable "Show Signal Markers" if only labels needed
- Increase `max_bars_back` if receiving "history not available" errors

## Integration with PowerShell Bot

To sync this Pine Script with your PowerShell trading bot:

1. **Entry Confirmation**
   - Pine Script: Shows entry signal with SL/SH
   - PowerShell: Execute trade when signal confirmed
   - Sync: Use the same swing low/high calculation

2. **Exit Management**
   - Pine Script: Visual exit indicators
   - PowerShell: Automatic exit at swing level
   - Sync: Match swing level filters exactly

3. **Performance Tracking**
   - Pine Script: P&L on chart
   - PowerShell: Logged to Position.json
   - Sync: Compare P&L between systems

## Notes

- This is a strategy indicator for **educational purposes**
- Past performance does not guarantee future results
- Always backtest before live trading
- Use with proper risk management
- Test on paper trading first (like your PowerShell bot does)

---

**Version**: 1.0  
**Last Updated**: 2026-07-24  
**Strategy**: Swing Low/High Breakout with Perfect Entry Filter
