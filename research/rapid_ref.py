"""Replica of Sweep_Reclaim_Alert v4.90 RAPID (defaults) + live-alert timing from ticks.
usage: python research/rapid_ref.py [YYYY-MM-DD]   (day to list, default 2026-11-12)"""
import sys, datetime as dt, numpy as np, pandas as pd, MetaTrader5 as mt5
P, K, N, BRKN, AFTER = 12.0, 2.5, 2, 24, 12
PIP = 0.01
DAY = sys.argv[1] if len(sys.argv) > 1 else "2026-11-12"
mt5.initialize()
d = pd.DataFrame(mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 1, 99000))
t = d.time.values.astype("int64"); o, h, l, c = (d[k].values for k in ("open", "high", "low", "close")); n = len(c)
pc = np.r_[c[0], c[:-1]]
atr = pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean().values
ts = lambda x: dt.datetime.fromtimestamp(int(x), dt.timezone.utc).strftime("%Y-%m-%d %H:%M")
ev = []
for s in (1, -1):
    H, L, O, C = (h, l, o, c) if s > 0 else (-l, -h, -o, -c)
    brk, last = -10**6, -1000
    for i in range(BRKN + 3, n):
        mx = H[i - BRKN:i].max()
        rb = H[i] > mx or brk >= i - N + 1 - AFTER
        if H[i] > mx: brk = i
        if not (rb and i - last > N): continue
        top = H[i - N + 1:i + 1].max()
        if H[i] >= top and O[i] <= C[i]: top = H[i - N + 1:i].max()
        mv = (top - L[i]) / PIP
        if mv >= max(P, K * atr[i - 1] / PIP):
            last = i; ev.append((i, s, mv, s * top))
ev.sort()
days = (t[-1] - t[0]) / 86400 * 5 / 7
print(f"RAPID: {len(ev)} events = {len(ev)/days:.1f}/day (drops {sum(e[1]>0 for e in ev)}, jumps {sum(e[1]<0 for e in ev)})")
for i, s, mv, top in ev:
    if ts(t[i]).startswith(DAY):
        thr = max(P, K * atr[i - 1] / PIP)
        # live timing: first tick inside bar i where (top of window so far) - price >= threshold
        tk = mt5.copy_ticks_range("USDJPY", dt.datetime.fromtimestamp(int(t[i]), dt.timezone.utc),
                                  dt.datetime.fromtimestamp(int(t[i]) + 300, dt.timezone.utc), mt5.COPY_TICKS_ALL)
        when = "?"
        if tk is not None and len(tk):
            prev_top = (h[i - N + 1:i].max() if s > 0 else -l[i - N + 1:i].min())
            run = prev_top
            for x in tk:
                px = s * x["bid"]; run = max(run, px)
                if (run - px) / PIP >= thr: when = f"{dt.datetime.fromtimestamp(int(x['time']), dt.timezone.utc):%H:%M:%S} at {x['bid']:.3f}"; break
        print(f"  {ts(t[i])} {'DROP' if s>0 else 'JUMP'} {mv:5.1f}p from {top:.3f} (threshold {thr:.1f}p) | live alert first tick: {when}")
