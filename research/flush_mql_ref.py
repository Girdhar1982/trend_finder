"""Bar-by-bar replica of Sweep_Reclaim_Alert v4.80 FLUSH (defaults). Prints recent signals = expected chart arrows."""
import datetime as dt, numpy as np, pandas as pd, MetaTrader5 as mt5
N, DEPTH, WAIT, RECL, PIP = 4, 3.0, 12, 2, 0.01
mt5.initialize()
d = pd.DataFrame(mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 1, 99000))   # closed bars only
t = d.time.values.astype("int64"); h, l, c = d.high.values, d.low.values, d.close.values; n = len(c)
ts = lambda i: dt.datetime.fromtimestamp(int(t[i]), dt.timezone.utc).strftime("%Y-%m-%d %H:%M")
sig = []
for s in (1, -1):
    H, L, C = (h, l, c) if s > 0 else (-l, -h, -c)
    brk, R, BL, drop, low, last = -1, 0, 0, -1, 0, -1000
    for i in range(3 * N + 10, n):
        if brk >= 0:
            if drop < 0:
                if i - brk > WAIT: brk = -1
                elif L[i] < BL - DEPTH * PIP: drop, low = i, L[i]
            else: low = min(low, L[i])
            if brk >= 0 and drop >= 0:
                if i - drop <= RECL:
                    if C[i] > R and i > last:
                        sig.append((i, s, s * R, s * low, brk)); last = i; brk = drop = -1; continue
                else: brk = drop = -1
        if drop < 0 and (t[i] + 300) % 900 == 0 and t[i] - t[i - 2] == 600:
            r = H[i - 2 - 3 * N:i - 2].max()
            bl = L[i - 2:i + 1].min()
            if C[i] > r and C[i - 3] <= r and bl <= r: brk, R, drop, BL = i, r, -1, bl
sig.sort()
days = (t[-1] - t[0]) / 86400 * 5 / 7
print(f"{len(sig)} signals, {len(sig)/days:.2f}/day (buys {sum(x[1]>0 for x in sig)}, sells {sum(x[1]<0 for x in sig)})")
for i, s, lv, lo, b in sig:
    if t[i] >= t[-1] - 8 * 86400:
        print(f"  {ts(i)} {'BUY ' if s>0 else 'SELL'}  M15 broke {lv:.3f} (M15 closed {ts(b+1)[11:]}), {'low' if s>0 else 'high'} {lo:.3f}, close {c[i]:.3f}, stop {lo - s*PIP:.3f} ({s*(c[i]-(lo-s*PIP))/PIP:.1f}p)")
