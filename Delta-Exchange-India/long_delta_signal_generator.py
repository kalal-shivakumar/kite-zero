#!/usr/bin/env python3
"""
Heikin-Ashi Long-only signal generator for Delta Exchange India.
WebSocket streaming with real-time updates.

Entry: current HA Close > previous HA High
Exit:  current HA Close < previous HA Low

Usage:
  python long_signal_generator.py
  python long_signal_generator.py --symbol ETHUSD --timeframe 5m
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from delta_exchange import load_config, run_ha_long_strategy


def main():
    parser = argparse.ArgumentParser(description="Delta Exchange HA Long Strategy")
    parser.add_argument("--symbol", type=str, default=None, help="Trading symbol (e.g. BTCUSD)")
    parser.add_argument("--timeframe", type=str, default=None, help="Candle timeframe (e.g. 1m, 3m, 5m)")
    parser.add_argument("--candles", type=int, default=None, help="Number of candles to show")
    parser.add_argument("--config", type=str, default=None, help="Path to input.json")
    args = parser.parse_args()

    # Load config
    config_path = args.config or os.path.join(os.path.dirname(os.path.abspath(__file__)), "input.json")
    cfg = load_config(config_path)
    print(f"  Loaded config from {os.path.basename(config_path)}")

    symbol = args.symbol or cfg.get("TradingSymbol", "BTCUSD")
    timeframe = args.timeframe or cfg.get("TimeFrame", "1m")
    candles_to_show = args.candles or int(cfg.get("CandlesToShow", 5))
    api_key = cfg.get("API_Key", "")
    api_secret = cfg.get("API_Secret", "")

    orders_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PlacedOrders")

    print()
    print(f"  Starting Delta Exchange HA Long Strategy (Python/WebSocket)...")
    print(f"  Symbol: {symbol} | TimeFrame: {timeframe}")
    print()

    run_ha_long_strategy(
        symbol=symbol,
        timeframe=timeframe,
        candles_to_show=candles_to_show,
        api_key=api_key,
        api_secret=api_secret,
        orders_folder=orders_dir,
    )


if __name__ == "__main__":
    main()
