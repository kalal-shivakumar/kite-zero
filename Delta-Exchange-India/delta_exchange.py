"""
Delta Exchange India Trading Module
====================================
Uses official delta-rest-client SDK for REST and websocket-client for streaming.
Strategy: Heikin-Ashi candle-based, signals on RUNNING candle.

WebSocket candlestick fields:
  o=open, h=high, l=low, c=close, cst=candle_start (microseconds), v=volume
"""

import json
import os
import sys
import time
import threading
import queue
from datetime import datetime, timezone, timedelta
from collections import OrderedDict

import websocket
from delta_rest_client import DeltaRestClient, OrderType

# ═══════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════

WS_PUBLIC_URL = "wss://public-socket.india.delta.exchange"
BASE_URL = "https://api.india.delta.exchange"

RESOLUTION_SECONDS = {
    "1m": 60, "3m": 180, "5m": 300, "15m": 900, "30m": 1800,
    "1h": 3600, "2h": 7200, "4h": 14400, "6h": 21600,
    "12h": 43200, "1d": 86400, "1w": 604800,
}


# ═══════════════════════════════════════════════════════════════
# CONFIG LOADER
# ═══════════════════════════════════════════════════════════════

def load_config(config_path=None):
    if config_path is None:
        config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "input.json")
    with open(config_path, "r") as f:
        return json.load(f)


# ═══════════════════════════════════════════════════════════════
# HEIKIN-ASHI CONVERSION
# ═══════════════════════════════════════════════════════════════

def convert_to_heikin_ashi(candles):
    """Convert OHLC candles to Heikin-Ashi candles."""
    if not candles:
        return []
    ha = []
    for i, c in enumerate(candles):
        if i == 0:
            ha_open = (c["open"] + c["close"]) / 2
        else:
            ha_open = (ha[i - 1]["open"] + ha[i - 1]["close"]) / 2
        ha_close = (c["open"] + c["high"] + c["low"] + c["close"]) / 4
        ha_high = max(c["high"], ha_open, ha_close)
        ha_low = min(c["low"], ha_open, ha_close)
        ha.append({
            "time": c["time"],
            "open": round(ha_open, 2),
            "high": round(ha_high, 2),
            "low": round(ha_low, 2),
            "close": round(ha_close, 2),
        })
    return ha


# ═══════════════════════════════════════════════════════════════
# DISPLAY HELPERS
# ═══════════════════════════════════════════════════════════════

def clear_screen():
    os.system("cls" if os.name == "nt" else "clear")


def format_candle_table(ha_candles, show=5):
    """Print an HA candle table to stdout."""
    display = ha_candles[-show:] if len(ha_candles) > show else ha_candles
    header = (
        f"  {'Time':<20} {'HA Open':>12} {'HA High':>12} "
        f"{'HA Low':>12} {'HA Close':>12} {'Color':>5}"
    )
    sep = "  " + "-" * 78
    print(sep)
    print(header)
    print(sep)
    for c in display:
        ts = datetime.fromtimestamp(c["time"], tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
        color_label = "G" if c["close"] >= c["open"] else "R"
        # ANSI colors: green=32, red=31
        color_code = 32 if color_label == "G" else 31
        line = (
            f"  {ts:<20} {c['open']:>12,.2f} {c['high']:>12,.2f} "
            f"  {c['low']:>12,.2f} {c['close']:>12,.2f}   {color_label}"
        )
        print(f"\033[{color_code}m{line}\033[0m")
    print(sep)


# ═══════════════════════════════════════════════════════════════
# WEBSOCKET STREAMING
# ═══════════════════════════════════════════════════════════════

class DeltaWebSocket:
    """Manages a WebSocket connection to Delta Exchange India public feed."""

    def __init__(self, channels, symbols):
        self.channels = channels
        self.symbols = symbols
        self.msg_queue = queue.Queue()
        self._ws = None
        self._thread = None
        self._stop = threading.Event()

    def _on_message(self, ws, message):
        try:
            data = json.loads(message)
            self.msg_queue.put(data)
        except json.JSONDecodeError:
            pass

    def _on_error(self, ws, error):
        pass

    def _on_close(self, ws, close_status, close_msg):
        pass

    def _on_open(self, ws):
        # Subscribe to channels
        channel_list = [{"name": ch, "symbols": self.symbols} for ch in self.channels]
        sub = {"type": "subscribe", "payload": {"channels": channel_list}}
        ws.send(json.dumps(sub))
        # Enable heartbeat to keep connection alive
        hb = {"type": "enable_heartbeat", "payload": {"interval": 15}}
        ws.send(json.dumps(hb))

    def connect(self):
        """Start WebSocket in background thread."""
        self._stop.clear()
        self._ws = websocket.WebSocketApp(
            WS_PUBLIC_URL,
            on_message=self._on_message,
            on_error=self._on_error,
            on_close=self._on_close,
            on_open=self._on_open,
        )
        self._thread = threading.Thread(
            target=self._ws.run_forever,
            kwargs={"ping_interval": 10, "ping_timeout": 5},
            daemon=True,
        )
        self._thread.start()
        # Wait for subscription confirmation
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                msg = self.msg_queue.get(timeout=0.5)
                if msg.get("type") == "subscriptions":
                    return True
                # Put back non-subscription messages
                if msg.get("cst"):
                    self.msg_queue.put(msg)
            except queue.Empty:
                continue
        return False

    def disconnect(self):
        self._stop.set()
        if self._ws:
            self._ws.close()
        if self._thread:
            self._thread.join(timeout=3)

    def get_message(self, timeout=0.1):
        """Non-blocking get. Returns parsed dict or None."""
        try:
            return self.msg_queue.get(timeout=timeout)
        except queue.Empty:
            return None

    @property
    def connected(self):
        return self._thread is not None and self._thread.is_alive()


# ═══════════════════════════════════════════════════════════════
# BOOTSTRAP: fetch historical candles via REST
# ═══════════════════════════════════════════════════════════════

def fetch_bootstrap_candles(symbol, resolution, count, api_key=None, api_secret=None):
    """Fetch historical candles using the official delta-rest-client."""
    client = DeltaRestClient(
        base_url=BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
    )
    res_sec = RESOLUTION_SECONDS.get(resolution, 60)
    now = int(time.time())
    start = now - (res_sec * (count + 10))
    candles = client.get_candles(
        symbol=symbol,
        resolution=resolution,
        start=start,
        end=now,
    )
    result = OrderedDict()
    if candles:
        for c in sorted(candles, key=lambda x: x["time"]):
            t = int(c["time"])
            result[t] = {
                "time": t,
                "open": float(c["open"]),
                "high": float(c["high"]),
                "low": float(c["low"]),
                "close": float(c["close"]),
                "volume": float(c.get("volume", 0)),
            }
    return result


# ═══════════════════════════════════════════════════════════════
# STRATEGY: Heikin-Ashi Long
# Entry: HA Close > previous HA High
# Exit:  HA Close < previous HA Low
# Signals on RUNNING candle (real-time)
# ═══════════════════════════════════════════════════════════════

def run_ha_long_strategy(
    symbol="BTCUSD",
    timeframe="1m",
    candles_to_show=5,
    api_key=None,
    api_secret=None,
    orders_folder=None,
):
    """Run the Heikin-Ashi Long-only strategy with WebSocket streaming."""

    ws_channel = f"candlestick_{timeframe}"
    if orders_folder is None:
        orders_folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PlacedOrders")
    os.makedirs(orders_folder, exist_ok=True)
    pos_file = os.path.join(orders_folder, "Long-Position.json")

    # State
    in_position = False
    entry_price = 0.0
    entry_time = ""
    trade_count = 0
    total_pnl = 0.0

    # Restore position
    if os.path.exists(pos_file):
        with open(pos_file, "r") as f:
            pos = json.load(f)
        in_position = True
        entry_price = float(pos.get("Price", 0))
        entry_time = pos.get("Time", "")
        total_pnl = float(pos.get("TotalPnL", 0))
        print(f"  Restored Long position: Entry={entry_price} at {entry_time}")

    print()
    print("  " + "=" * 58)
    print(f"  DELTA HA LONG STRATEGY | {symbol} | {timeframe} | WebSocket")
    print("  Signals on RUNNING candle (real-time)")
    print("  Entry: HA Close > prev HA High | Exit: HA Close < prev HA Low")
    print(f"  Signal folder: {orders_folder}")
    print("  " + "=" * 58)

    # Bootstrap candles from REST
    print("  Bootstrapping candles from REST...", end=" ", flush=True)
    candle_map = fetch_bootstrap_candles(symbol, timeframe, candles_to_show + 15, api_key, api_secret)
    print(f"{len(candle_map)} candles")

    ltp = list(candle_map.values())[-1]["close"] if candle_map else 0
    ws_tick_received = False
    signal_fired = False
    last_redraw = 0

    # Auto-reconnect loop
    while True:
        print(f"  Connecting WebSocket to {ws_channel}...", flush=True)
        ws = DeltaWebSocket(channels=[ws_channel], symbols=[symbol])
        ok = ws.connect()
        if not ok:
            print("  WebSocket failed. Retrying in 3s...")
            time.sleep(3)
            continue
        print("  WebSocket connected - streaming live")

        try:
            while ws.connected:
                data = ws.get_message(timeout=0.1)

                # Parse candlestick data
                # WS fields: o, h, l, c, cst (microseconds), v
                if data and data.get("cst") and data.get("o") is not None:
                    t = int(data["cst"]) // 1_000_000  # microseconds -> seconds
                    candle_map[t] = {
                        "time": t,
                        "open": float(data["o"]),
                        "high": float(data["h"]),
                        "low": float(data["l"]),
                        "close": float(data["c"]),
                        "volume": float(data.get("v", 0)),
                    }
                    ltp = float(data["c"])
                    signal_fired = False
                    ws_tick_received = True

                # Signal checking (only after first WS tick)
                if len(candle_map) >= 3 and not signal_fired and ws_tick_received:
                    sorted_candles = sorted(candle_map.values(), key=lambda x: x["time"])
                    ha = convert_to_heikin_ashi(sorted_candles)

                    if len(ha) >= 2:
                        latest = ha[-1]
                        prev = ha[-2]

                        # LONG ENTRY: HA Close > prev HA High
                        if not in_position:
                            if latest["close"] > prev["high"]:
                                ts = datetime.now().strftime("%H:%M:%S")
                                fname = f"Long-Entry-{ts.replace(':', '-')}.txt"
                                fpath = os.path.join(orders_folder, fname)
                                with open(fpath, "w") as f:
                                    f.write(
                                        f"LONG ENTRY | {symbol} | HA Close {latest['close']} > "
                                        f"prev HA High {prev['high']} | LTP: {ltp} | {ts}"
                                    )
                                in_position = True
                                entry_price = ltp
                                entry_time = ts
                                trade_count += 1
                                signal_fired = True
                                with open(pos_file, "w") as f:
                                    json.dump({"Price": entry_price, "Time": entry_time,
                                               "Symbol": symbol, "TotalPnL": total_pnl}, f)
                                print(f"\n  \033[32m[{ts}] ▲ LONG ENTRY | HA Close {latest['close']} > "
                                      f"prev High {prev['high']} | LTP: {ltp}\033[0m")

                        # LONG EXIT: HA Close < prev HA Low
                        if in_position and not signal_fired:
                            if latest["close"] < prev["low"]:
                                ts = datetime.now().strftime("%H:%M:%S")
                                fname = f"Long-Exit-{ts.replace(':', '-')}.txt"
                                fpath = os.path.join(orders_folder, fname)
                                trade_pnl = ltp - entry_price
                                total_pnl += trade_pnl
                                with open(fpath, "w") as f:
                                    f.write(
                                        f"LONG EXIT | {symbol} | HA Close {latest['close']} < "
                                        f"prev HA Low {prev['low']} | LTP: {ltp} | "
                                        f"PnL: {trade_pnl:.2f} | {ts}"
                                    )
                                pnl_color = 32 if trade_pnl >= 0 else 31
                                print(f"\n  \033[{pnl_color}m[{ts}] ▼ LONG EXIT | HA Close {latest['close']} < "
                                      f"prev Low {prev['low']} | LTP: {ltp} | PnL: {trade_pnl:.2f}\033[0m")
                                in_position = False
                                entry_price = 0
                                entry_time = ""
                                signal_fired = True
                                if os.path.exists(pos_file):
                                    os.remove(pos_file)

                # Redraw display every 250ms
                now = time.time()
                if now - last_redraw >= 0.25 and len(candle_map) >= 2:
                    last_redraw = now
                    sorted_candles = sorted(candle_map.values(), key=lambda x: x["time"])
                    ha = convert_to_heikin_ashi(sorted_candles)

                    clear_screen()
                    print()
                    print(f"  \033[32mDELTA HA LONG STRATEGY | {symbol} | {timeframe} | WebSocket\033[0m")
                    format_candle_table(ha, show=candles_to_show)

                    if in_position:
                        unrealized = ltp - entry_price
                        u_color = 32 if unrealized >= 0 else 31
                        print(f"\n  \033[32mStatus: IN POSITION @ {entry_price}\033[0m | "
                              f"Trades: {trade_count} | Total PnL: {total_pnl:.2f}")
                        print(f"  \033[{u_color}mUnrealized: {unrealized:.2f} | LTP: {ltp}\033[0m")
                    else:
                        print(f"\n  Status: WAITING | Trades: {trade_count} | Total PnL: {total_pnl:.2f}")

                    ts_now = datetime.now().strftime("%H:%M:%S.%f")[:-3]
                    print(f"  [{ts_now}] {symbol} @ {ltp} | WS streaming")

        except KeyboardInterrupt:
            print("\n  Stopped by user.")
            ws.disconnect()
            return
        except Exception:
            pass
        finally:
            ws.disconnect()

        print("  WebSocket dropped. Reconnecting...")
        time.sleep(1)


# ═══════════════════════════════════════════════════════════════
# STRATEGY: Heikin-Ashi Short
# Entry: HA Close < previous HA Low
# Exit:  HA Close > previous HA High
# Signals on RUNNING candle (real-time)
# ═══════════════════════════════════════════════════════════════

def run_ha_short_strategy(
    symbol="BTCUSD",
    timeframe="1m",
    candles_to_show=5,
    api_key=None,
    api_secret=None,
    orders_folder=None,
):
    """Run the Heikin-Ashi Short-only strategy with WebSocket streaming."""

    ws_channel = f"candlestick_{timeframe}"
    if orders_folder is None:
        orders_folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PlacedOrders")
    os.makedirs(orders_folder, exist_ok=True)
    pos_file = os.path.join(orders_folder, "Short-Position.json")

    # State
    in_position = False
    entry_price = 0.0
    entry_time = ""
    trade_count = 0
    total_pnl = 0.0

    # Restore position
    if os.path.exists(pos_file):
        with open(pos_file, "r") as f:
            pos = json.load(f)
        in_position = True
        entry_price = float(pos.get("Price", 0))
        entry_time = pos.get("Time", "")
        total_pnl = float(pos.get("TotalPnL", 0))
        print(f"  Restored Short position: Entry={entry_price} at {entry_time}")

    print()
    print("  " + "=" * 58)
    print(f"  DELTA HA SHORT STRATEGY | {symbol} | {timeframe} | WebSocket")
    print("  Signals on RUNNING candle (real-time)")
    print("  Entry: HA Close < prev HA Low | Exit: HA Close > prev HA High")
    print(f"  Signal folder: {orders_folder}")
    print("  " + "=" * 58)

    # Bootstrap
    print("  Bootstrapping candles from REST...", end=" ", flush=True)
    candle_map = fetch_bootstrap_candles(symbol, timeframe, candles_to_show + 15, api_key, api_secret)
    print(f"{len(candle_map)} candles")

    ltp = list(candle_map.values())[-1]["close"] if candle_map else 0
    ws_tick_received = False
    signal_fired = False
    last_redraw = 0

    while True:
        print(f"  Connecting WebSocket to {ws_channel}...", flush=True)
        ws = DeltaWebSocket(channels=[ws_channel], symbols=[symbol])
        ok = ws.connect()
        if not ok:
            print("  WebSocket failed. Retrying in 3s...")
            time.sleep(3)
            continue
        print("  WebSocket connected - streaming live")

        try:
            while ws.connected:
                data = ws.get_message(timeout=0.1)

                if data and data.get("cst") and data.get("o") is not None:
                    t = int(data["cst"]) // 1_000_000
                    candle_map[t] = {
                        "time": t,
                        "open": float(data["o"]),
                        "high": float(data["h"]),
                        "low": float(data["l"]),
                        "close": float(data["c"]),
                        "volume": float(data.get("v", 0)),
                    }
                    ltp = float(data["c"])
                    signal_fired = False
                    ws_tick_received = True

                if len(candle_map) >= 3 and not signal_fired and ws_tick_received:
                    sorted_candles = sorted(candle_map.values(), key=lambda x: x["time"])
                    ha = convert_to_heikin_ashi(sorted_candles)

                    if len(ha) >= 2:
                        latest = ha[-1]
                        prev = ha[-2]

                        # SHORT ENTRY: HA Close < prev HA Low
                        if not in_position:
                            if latest["close"] < prev["low"]:
                                ts = datetime.now().strftime("%H:%M:%S")
                                fname = f"Short-Entry-{ts.replace(':', '-')}.txt"
                                fpath = os.path.join(orders_folder, fname)
                                with open(fpath, "w") as f:
                                    f.write(
                                        f"SHORT ENTRY | {symbol} | HA Close {latest['close']} < "
                                        f"prev HA Low {prev['low']} | LTP: {ltp} | {ts}"
                                    )
                                in_position = True
                                entry_price = ltp
                                entry_time = ts
                                trade_count += 1
                                signal_fired = True
                                with open(pos_file, "w") as f:
                                    json.dump({"Price": entry_price, "Time": entry_time,
                                               "Symbol": symbol, "TotalPnL": total_pnl}, f)
                                print(f"\n  \033[31m[{ts}] ▼ SHORT ENTRY | HA Close {latest['close']} < "
                                      f"prev Low {prev['low']} | LTP: {ltp}\033[0m")

                        # SHORT EXIT: HA Close > prev HA High
                        if in_position and not signal_fired:
                            if latest["close"] > prev["high"]:
                                ts = datetime.now().strftime("%H:%M:%S")
                                fname = f"Short-Exit-{ts.replace(':', '-')}.txt"
                                fpath = os.path.join(orders_folder, fname)
                                trade_pnl = entry_price - ltp
                                total_pnl += trade_pnl
                                with open(fpath, "w") as f:
                                    f.write(
                                        f"SHORT EXIT | {symbol} | HA Close {latest['close']} > "
                                        f"prev HA High {prev['high']} | LTP: {ltp} | "
                                        f"PnL: {trade_pnl:.2f} | {ts}"
                                    )
                                pnl_color = 32 if trade_pnl >= 0 else 31
                                print(f"\n  \033[{pnl_color}m[{ts}] ▲ SHORT EXIT | HA Close {latest['close']} > "
                                      f"prev High {prev['high']} | LTP: {ltp} | PnL: {trade_pnl:.2f}\033[0m")
                                in_position = False
                                entry_price = 0
                                entry_time = ""
                                signal_fired = True
                                if os.path.exists(pos_file):
                                    os.remove(pos_file)

                # Redraw display every 250ms
                now = time.time()
                if now - last_redraw >= 0.25 and len(candle_map) >= 2:
                    last_redraw = now
                    sorted_candles = sorted(candle_map.values(), key=lambda x: x["time"])
                    ha = convert_to_heikin_ashi(sorted_candles)

                    clear_screen()
                    print()
                    print(f"  \033[31mDELTA HA SHORT STRATEGY | {symbol} | {timeframe} | WebSocket\033[0m")
                    format_candle_table(ha, show=candles_to_show)

                    if in_position:
                        unrealized = entry_price - ltp
                        u_color = 32 if unrealized >= 0 else 31
                        print(f"\n  \033[31mStatus: IN POSITION @ {entry_price}\033[0m | "
                              f"Trades: {trade_count} | Total PnL: {total_pnl:.2f}")
                        print(f"  \033[{u_color}mUnrealized: {unrealized:.2f} | LTP: {ltp}\033[0m")
                    else:
                        print(f"\n  Status: WAITING | Trades: {trade_count} | Total PnL: {total_pnl:.2f}")

                    ts_now = datetime.now().strftime("%H:%M:%S.%f")[:-3]
                    print(f"  [{ts_now}] {symbol} @ {ltp} | WS streaming")

        except KeyboardInterrupt:
            print("\n  Stopped by user.")
            ws.disconnect()
            return
        except Exception:
            pass
        finally:
            ws.disconnect()

        print("  WebSocket dropped. Reconnecting...")
        time.sleep(1)
