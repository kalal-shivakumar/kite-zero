"""
PE (Put) Option Buyer - Delta Exchange India
==============================================
Monitors PlacedOrders/ for Short-Entry-*.txt and Short-Exit-*.txt signal files.
When entry signal appears: gets spot, finds ITM PE, places BUY order.
When exit signal appears: places SELL order to close position.
Works alongside short_delta_signal_generator.py.
"""

import json, os, sys, time, glob, argparse
from datetime import datetime
from delta_rest_client import DeltaRestClient, OrderType

BASE_URL = "https://api.india.delta.exchange"


def load_config(path=None):
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "input.json")
    with open(path) as f:
        return json.load(f)


def find_nearest_expiry(client, underlying):
    from datetime import timezone
    products = client.get_products(query={"contract_types": "call_options,put_options"})
    now = datetime.now(timezone.utc)
    expiries = {}
    for p in products:
        ua = p.get("underlying_asset", {})
        if ua.get("symbol") != underlying:
            continue
        st = p.get("settlement_time")
        if not st:
            continue
        try:
            if isinstance(st, str):
                dt = datetime.fromisoformat(st.replace("Z", "+00:00"))
            else:
                dt = datetime.fromtimestamp(int(st) / 1_000_000, tz=timezone.utc)
            if dt > now:
                key = dt.strftime("%d-%m-%Y")
                if key not in expiries or dt < expiries[key]:
                    expiries[key] = dt
        except Exception:
            continue
    return min(expiries.items(), key=lambda x: x[1])[0] if expiries else None


def get_spot_price(client, symbol):
    try:
        return float(client.get_ticker(symbol).get("spot_price", 0))
    except Exception:
        return 0.0


def get_option_ltp(client, sym):
    try:
        t = client.get_ticker(sym)
        ltp = float(t.get("close", 0))
        return ltp if ltp > 0 else float(t.get("mark_price", 0))
    except Exception:
        return 0.0


def get_atm_put(chain, spot, offset=0):
    puts = [o for o in chain if o.get("contract_type") == "put_options"]
    if not puts:
        return None
    strikes = sorted(set(float(p["strike_price"]) for p in puts))
    if not strikes:
        return None
    atm = min(strikes, key=lambda s: abs(s - spot))
    idx = max(0, min(strikes.index(atm) + offset, len(strikes) - 1))
    target = strikes[idx]
    return next((p for p in puts if float(p["strike_price"]) == target), None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=None)
    args = parser.parse_args()

    cfg = load_config(args.config)
    api_key    = cfg["API_Key"]
    api_secret = cfg["API_Secret"]
    symbol     = cfg.get("TradingSymbol", "BTCUSD")
    underlying = cfg.get("UnderlyingAsset", "BTC")
    order_size = int(cfg.get("OrderSize", 1))
    atm_offset = int(cfg.get("ATMOffset_PE", 4))
    start_time = cfg.get("StartTime", "00:00:01")
    stop_time  = cfg.get("StopTime", "23:59:00")
    poll_interval = 0.1

    script_dir = os.path.dirname(os.path.abspath(__file__))
    orders_dir = os.path.join(script_dir, "PlacedOrders")
    os.makedirs(orders_dir, exist_ok=True)
    pos_file = os.path.join(orders_dir, "PE-Position.json")

    client = DeltaRestClient(base_url=BASE_URL, api_key=api_key, api_secret=api_secret)

    print(f"\n  Finding nearest expiry for {underlying}...")
    expiry = find_nearest_expiry(client, underlying)
    if not expiry:
        print("  ERROR: No expiries found."); sys.exit(1)
    print(f"  Expiry: {expiry}")

    chain = client.option_chain(underlying, expiry)
    spot  = get_spot_price(client, symbol)

    in_position      = False
    entry_product_id = 0
    entry_symbol     = ""
    entry_strike     = 0.0
    entry_spot       = 0.0
    entry_ltp        = 0.0
    entry_time       = ""
    total_pnl        = 0.0
    trade_count      = 0
    processed_files  = set()

    if os.path.exists(pos_file):
        try:
            with open(pos_file) as f:
                pos = json.load(f)
            in_position      = True
            entry_product_id = pos.get("ProductId", 0)
            entry_symbol     = pos.get("Symbol", "")
            entry_strike     = pos.get("Strike", 0)
            entry_spot       = pos.get("SpotPrice", 0)
            entry_ltp        = pos.get("EntryLTP", 0)
            entry_time       = pos.get("Time", "")
            total_pnl        = pos.get("TotalPnL", 0)
            print(f"  Restored position: {entry_symbol} | Strike: {entry_strike} | Entry LTP: {entry_ltp}")
            # Clean any stale entry files to prevent duplicate orders
            for f_path in glob.glob(os.path.join(orders_dir, "Short-Entry-*.txt")):
                try: os.remove(f_path)
                except OSError: pass
        except Exception:
            print("  Corrupt position file, removing.")
            os.remove(pos_file)
    else:
        # No position — clean any stale signal files from previous runs
        for pat in ["Short-Entry-*.txt", "Short-Exit-*.txt"]:
            for f_path in glob.glob(os.path.join(orders_dir, pat)):
                try: os.remove(f_path)
                except OSError: pass
        print("  No position. Cleaned stale Short signal files.")

    print()
    print("  " + "=" * 66)
    print(f"  PE-BUY | {underlying} PUT OPTIONS | Expiry: {expiry}")
    print(f"  Order Size: {order_size} contracts | ATM Offset: {atm_offset}")
    print(f"  Window: {start_time} - {stop_time}")
    print(f"  Monitoring: {orders_dir}")
    print("  Entry: Short-Entry-*.txt | Exit: Short-Exit-*.txt")
    print("  " + "=" * 66)
    print()

    last_api_fetch    = 0
    cached_spot       = spot
    cached_curr_ltp   = 0.0
    cached_atm_symbol = "--"
    cached_atm_strike = 0.0
    cached_atm_ltp    = 0.0

    while True:
        try:
            now = datetime.now()
            now_str = now.strftime("%H:%M:%S.") + f"{now.microsecond // 1000:03d}"
            now_time_str = now.strftime("%H:%M:%S")

            if now_time_str < start_time:
                print(f"\r  [{now_time_str}] Waiting for start time {start_time}...   ", end="", flush=True)
                time.sleep(2)
                continue
            if now_time_str > stop_time:
                if in_position:
                    print(f"\n  [{now_time_str}] \033[31mSTOP TIME - Force exit {entry_symbol}\033[0m")
                    try:
                        client.place_order(product_id=entry_product_id, size=order_size,
                            side="sell", order_type=OrderType.MARKET, reduce_only="true")
                        print(f"  Force exit order placed for {entry_symbol}")
                    except Exception as e:
                        print(f"  Force exit failed: {e}")
                    in_position = False
                    if os.path.exists(pos_file):
                        os.remove(pos_file)
                print(f"\n  Stop time {stop_time} reached. Exiting.")
                break

            if not in_position:
                entry_files = glob.glob(os.path.join(orders_dir, "Short-Entry-*.txt"))
                for ef in entry_files:
                    if ef in processed_files:
                        continue
                    print(f"\n  [{now_time_str}] \033[33m SHORT ENTRY SIGNAL: {os.path.basename(ef)}\033[0m")
                    try:
                        chain = client.option_chain(underlying, expiry)
                    except Exception as e:
                        print(f"  Failed to refresh chain: {e}")
                        processed_files.add(ef)
                        continue
                    spot = get_spot_price(client, symbol)
                    if spot <= 0:
                        for o in chain:
                            if o.get("spot_price"):
                                spot = float(o["spot_price"])
                                break
                    if spot <= 0:
                        print("  Could not get spot price. Skipping.")
                        processed_files.add(ef)
                        continue
                    atm = get_atm_put(chain, spot, atm_offset)
                    if not atm:
                        print("  Could not find ATM PE. Skipping.")
                        processed_files.add(ef)
                        continue
                    opt_ltp = float(atm.get("close", 0) or atm.get("mark_price", 0))
                    print(f"  Spot: {spot} | Strike: {atm['strike_price']} | PE: {atm['symbol']} | LTP: {opt_ltp}")
                    # Delete all entry files BEFORE placing order to prevent duplicates
                    for f_path in glob.glob(os.path.join(orders_dir, "Short-Entry-*.txt")):
                        try: os.remove(f_path)
                        except OSError: pass
                    try:
                        result = client.place_order(product_id=atm["product_id"], size=order_size,
                            side="buy", order_type=OrderType.MARKET)
                        print(f"  \033[35m BUY ORDER PLACED | {atm['symbol']} | Size: {order_size}\033[0m")
                        if result:
                            print(f"  Order: {result}")
                        in_position = True
                        entry_product_id = atm["product_id"]
                        entry_symbol = atm["symbol"]
                        entry_strike = float(atm["strike_price"])
                        entry_spot = spot
                        entry_ltp = opt_ltp
                        entry_time = now_time_str
                        trade_count += 1
                        last_api_fetch = 0
                        with open(pos_file, "w") as f:
                            json.dump({"ProductId": entry_product_id, "Symbol": entry_symbol,
                                "Strike": entry_strike, "SpotPrice": entry_spot,
                                "EntryLTP": entry_ltp, "Time": entry_time,
                                "TotalPnL": total_pnl}, f)
                    except Exception as e:
                        print(f"  \033[31m BUY ORDER FAILED: {e}\033[0m")
                    break

            if in_position:
                exit_files = glob.glob(os.path.join(orders_dir, "Short-Exit-*.txt"))
                for xf in exit_files:
                    if xf in processed_files:
                        continue
                    print(f"\n  [{now_time_str}] \033[33m SHORT EXIT SIGNAL: {os.path.basename(xf)}\033[0m")
                    exit_ltp = get_option_ltp(client, entry_symbol)
                    # Delete all exit files BEFORE placing order to prevent duplicates
                    for f_path in glob.glob(os.path.join(orders_dir, "Short-Exit-*.txt")):
                        try: os.remove(f_path)
                        except OSError: pass
                    try:
                        result = client.place_order(product_id=entry_product_id, size=order_size,
                            side="sell", order_type=OrderType.MARKET, reduce_only="true")
                        trade_pnl = (exit_ltp - entry_ltp) * order_size if exit_ltp > 0 and entry_ltp > 0 else 0
                        total_pnl += trade_pnl
                        pnl_color = 32 if trade_pnl >= 0 else 31
                        print(f"  \033[{pnl_color}m SELL ORDER | {entry_symbol} | "
                              f"Entry: {entry_ltp:.2f} -> Exit: {exit_ltp:.2f} | "
                              f"PnL: {trade_pnl:.2f} | Total: {total_pnl:.2f}\033[0m")
                        if result:
                            print(f"  Order: {result}")
                        in_position = False
                        entry_product_id = 0
                        entry_symbol = ""
                        entry_strike = 0
                        entry_spot = 0
                        entry_ltp = 0
                        entry_time = ""
                        last_api_fetch = 0
                        if os.path.exists(pos_file):
                            os.remove(pos_file)
                    except Exception as e:
                        print(f"  \033[31m SELL ORDER FAILED: {e}\033[0m")
                    break

            t = time.time()
            if t - last_api_fetch >= 2.0:
                last_api_fetch = t
                cached_spot = get_spot_price(client, symbol)
                if in_position:
                    cached_curr_ltp = get_option_ltp(client, entry_symbol)
                else:
                    atm = get_atm_put(chain, cached_spot, atm_offset) if cached_spot > 0 else None
                    cached_atm_symbol = atm["symbol"] if atm else "--"
                    cached_atm_strike = float(atm["strike_price"]) if atm else 0
                    cached_atm_ltp = get_option_ltp(client, cached_atm_symbol) if atm else 0

            os.system("cls" if os.name == "nt" else "clear")
            print()
            print(f"  \033[35m+==============================================================+\033[0m")
            print(f"  \033[35m|  PE-BUY | {underlying} PUT OPTIONS | Expiry: {expiry:<15}     |\033[0m")
            print(f"  \033[35m+==============================================================+\033[0m")

            if in_position:
                unrealized = (cached_curr_ltp - entry_ltp) * order_size if cached_curr_ltp > 0 else 0
                u_color = 32 if unrealized >= 0 else 31
                pnl_display = total_pnl + unrealized
                p_color = 32 if pnl_display >= 0 else 31
                print(f"  \033[35m|\033[0m  Status    : \033[33mWAITING FOR EXIT\033[0m                             \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Signal    : Short-Exit-*.txt                         \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  --------------------------------------------------------\033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Symbol    : \033[36m{entry_symbol:<40}\033[0m      \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Strike    : {entry_strike:<42.1f}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Spot      : {cached_spot:<42,.2f}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  --------------------------------------------------------\033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Entry LTP : {entry_ltp:<42.2f}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Curr  LTP : \033[36m{cached_curr_ltp:<41.2f}\033[0m    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Entry Time: {entry_time:<42}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  --------------------------------------------------------\033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Unrealized: \033[{u_color}m{unrealized:<41.2f}\033[0m    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Total PnL : \033[{p_color}m{pnl_display:<41.2f}\033[0m    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Trades    : {trade_count:<42}    \033[35m|\033[0m")
            else:
                print(f"  \033[35m|\033[0m  Status    : \033[33mWAITING FOR ENTRY\033[0m                            \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Signal    : Short-Entry-*.txt                        \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  --------------------------------------------------------\033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  ATM PE    : \033[36m{cached_atm_symbol:<40}\033[0m      \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Strike    : {cached_atm_strike:<42.1f}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Spot      : {cached_spot:<42,.2f}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  PE Price  : \033[36m{cached_atm_ltp:<41.2f}\033[0m    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  --------------------------------------------------------\033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Total PnL : {total_pnl:<42.2f}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Trades    : {trade_count:<42}    \033[35m|\033[0m")
                print(f"  \033[35m|\033[0m  Size      : {order_size:<42}    \033[35m|\033[0m")

            print(f"  \033[35m+==============================================================+\033[0m")
            print(f"  \033[35m|\033[0m  [{now_str}] Polling every 100ms                        \033[35m|\033[0m")
            print(f"  \033[35m+==============================================================+\033[0m")

            time.sleep(poll_interval)

        except KeyboardInterrupt:
            print("\n\n  Stopped by user.")
            break
        except Exception as e:
            print(f"\n  Error: {e}")
            time.sleep(2)


if __name__ == "__main__":
    main()
