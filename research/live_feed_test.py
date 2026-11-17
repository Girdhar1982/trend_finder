"""
Feeds a monitor's LIVE loop with real history as if time were passing, to prove the live loop fires alerts.
    python research/live_feed_test.py breakout_monitor  "2026-11-12 17:00" "2026-11-12 19:30" [extra args...]
    python research/live_feed_test.py nowick_monitor    "2026-11-11 16:00" "2026-11-11 19:30" --breakout
    python research/live_feed_test.py sweep_reclaim_monitor "2026-11-12 17:00" "2026-11-12 19:30"
"""
import importlib
import sys
import time

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

sys.path.insert(0, "research")
name, start, end, extra = sys.argv[1], pd.Timestamp(sys.argv[2]), pd.Timestamp(sys.argv[3]), sys.argv[4:]
mt5.initialize()
real_rates = mt5.copy_rates_from_pos
FULL, TFSEC = {}, {mt5.TIMEFRAME_M5: 300, mt5.TIMEFRAME_M15: 900, mt5.TIMEFRAME_M30: 1800, mt5.TIMEFRAME_H1: 3600, mt5.TIMEFRAME_M1: 60}
now = [start.value // 10**9]
toasts = []


def fake_rates(sym, tf, pos, count):
    if tf not in FULL:
        FULL[tf] = real_rates(sym, tf, 0, 99000)
    arr = FULL[tf]
    closed = int(np.searchsorted(arr["time"] + TFSEC[tf], now[0], side="right"))     # bars whose close time <= now
    last = closed + 1 if pos == 0 else closed                                             # forming bar included when pos == 0
    return arr[max(0, last - count - (0 if pos == 0 else 0)):last]


def fake_sleep(_):
    now[0] += 300
    if now[0] > end.value // 10**9:
        raise KeyboardInterrupt


class Tick:
    pass


def fake_tick(sym):
    arr = FULL[mt5.TIMEFRAME_M15] if mt5.TIMEFRAME_M15 in FULL else next(iter(FULL.values()))
    k = int(np.searchsorted(arr["time"], now[0], side="right")) - 1
    t = Tick()
    t.bid = t.ask = float(arr["close"][k])
    t.time = now[0]
    return t


mt5.copy_rates_from_pos = fake_rates
mt5.symbol_info_tick = fake_tick
time.sleep = fake_sleep
mod = importlib.import_module(name)
bm = importlib.import_module("breakout_monitor")
bm.winsound = None
bm.toast = lambda t, b: toasts.append((t, b))
bm.popup = lambda t, b: toasts.append(("POPUP " + t, b))
mod.LOG = "research/_live_feed_test.log"
sys.argv = [name, "--poll", "0", "--no-beep"] + extra
print(f"--- simulated live feed for {name}: {start} -> {end}")
mod.main()
print(f"--- done. Windows alerts raised: {len(toasts)}")
for t, b in toasts[:12]:
    print("   TOAST:", t, "|", b[:110])
