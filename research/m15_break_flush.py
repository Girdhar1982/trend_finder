"""
User's pattern (buy side; sell = mirror):
  1. BREAK  : an M15 candle CLOSES above the high of the previous N M15 candles (the 15m resistance R).
              That M15 candle = the breakout candle; its low = BL.
  2. FLUSH  : within the next WIN M5 bars after the breakout candle closed, an M5 bar trades below BL by >= DEPTH.
  3. RECLAIM: that M5 bar or one of the next RB bars (5-10 min) CLOSES back above the level LV
              (LV = R the broken resistance, or BL the breakout candle low).
  -> BUY at the next M5 open (+spread). Stop = flush low - 1 pip.
Also reports how often a flush is reclaimed at all (the "it happens many times" part).
Metrics over 36 M5 bars: hit20 (+20 before -10, break-even 33%), br10 (+/-10 bracket avg), st20 (structural stop, TP 20, avg),
st2R (structural stop, TP 2x risk, avg). Train = first 60% of bars, test = last 40%.
usage: python research/m15_break_flush.py
"""
import datetime as dt
import itertools
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PIP, HOLD = 0.01, 36
mt5.initialize()
d = pd.DataFrame(mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 99000))
t = d.time.values.astype("int64")
o, h, l, c = (d[k].values.astype(float) for k in ("open", "high", "low", "close"))
sp = d.spread.values * 0.001
n = len(c)
pc = np.r_[c[0], c[:-1]]
atr = pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean().values
SPLIT = int(n * 0.6)
ts = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime("%Y-%m-%d %H:%M")

# M15 candles built from M5 (aligned to :00/:15/:30/:45); keep only complete ones (3 M5 bars)
g = t // 900
starts = np.r_[0, np.nonzero(np.diff(g))[0] + 1]
ends = np.r_[starts[1:], n] - 1
full = (ends - starts) == 2
starts, ends = starts[full], ends[full]
H15 = np.array([h[a:b + 1].max() for a, b in zip(starts, ends)])
L15 = np.array([l[a:b + 1].min() for a, b in zip(starts, ends)])
C15 = c[ends]
m = len(starts)


def outcome(i, s, stopT):
    e = i + 1
    if e + HOLD >= n: return None
    entry = o[e] + sp[e] if s > 0 else o[e]
    lo = l[e:e + HOLD] if s > 0 else -(h[e:e + HOLD] + sp[e:e + HOLD])
    hi = h[e:e + HOLD] if s > 0 else -(l[e:e + HOLD] + sp[e:e + HOLD])
    E = s * entry
    endpx = s * (c[e + HOLD - 1] if s > 0 else c[e + HOLD - 1] + sp[e + HOLD - 1])

    def br(stop, tp):
        for k in range(HOLD):
            if lo[k] <= stop: return (stop - E) / PIP, 0
            if hi[k] >= tp: return (tp - E) / PIP, 1
        return (endpx - E) / PIP, 0
    hit = br(E - 10 * PIP, E + 20 * PIP)[1]
    b10 = br(E - 10 * PIP, E + 10 * PIP)[0]
    stp = stopT - PIP
    risk = E - stp
    if risk < 1 * PIP: return hit, b10, np.nan, np.nan, np.nan
    return hit, b10, br(stp, E + 20 * PIP)[0], br(stp, E + 2 * risk)[0], risk / PIP


def detect(N, depth, rb, lv_kind, win=12):
    """returns signals [(i, s, flushLowT)] and flush stats (flushes, reclaimed)."""
    sigs, nflush, nrec = [], 0, 0
    for s in (1, -1):
        HH, LL, CC = (H15, L15, C15) if s > 0 else (-L15, -H15, -C15)
        H, L, C = (h, l, c) if s > 0 else (-l, -h, -c)
        last = -10**9
        for k in range(N, m - 1):
            R = HH[k - N:k].max()
            if not (CC[k] > R and CC[k - 1] <= R): continue      # first M15 close above resistance
            BL = LL[k]
            j0 = ends[k] + 1
            a = atr[ends[k]]
            dep = depth[1] * a if depth[0] == "atr" else depth[1] * PIP
            flush = next((j for j in range(j0, min(j0 + win, n - HOLD - 2)) if L[j] < BL - dep), None)
            if flush is None: continue
            nflush += 1
            LV = R if lv_kind == "R" else BL
            rec = next((j for j in range(flush, min(flush + rb + 1, n - HOLD - 2)) if C[j] > LV), None)
            if rec is None or rec <= last: continue
            nrec += 1
            sigs.append((rec, s, L[flush:rec + 1].min())); last = rec
    return sorted(sigs), nflush, nrec


def stats(sigs):
    out = {}
    for i, s, st in sigs:
        oc = outcome(i, s, st)
        if oc is None: continue
        out.setdefault(("train" if i < SPLIT else "test", s), []).append(oc)
    return out


def line(rows):
    if not rows: return "n=0"
    r = np.array(rows, dtype=float)
    se = np.nanstd(r[:, 2]) / np.sqrt(np.sum(~np.isnan(r[:, 2])))
    return (f"n={len(r):4d} hit20 {100*r[:,0].mean():4.1f}%  br10 {r[:,1].mean():+5.2f}  "
            f"st20 {np.nanmean(r[:,2]):+5.2f} (se {se:.2f})  st2R {np.nanmean(r[:,3]):+5.2f}  risk {np.nanmedian(r[:,4]):4.1f}p")


days = (t[-1] - t[0]) / 86400 * 5 / 7
print(f"USDJPY M5 {ts(0)} -> {ts(n-1)}, split {ts(SPLIT)}")
rnd = {}
for s in (1, -1):
    for i in range(300, n - HOLD - 2, 7):
        oc = outcome(i, s, l[i] if s > 0 else -h[i])
        if oc: rnd.setdefault(("train" if i < SPLIT else "test", s), []).append(oc)
print("RANDOM")
for half in ("train", "test"):
    for s in (1, -1): print(f"   {half:5s} {'BUY ' if s>0 else 'SELL'} {line(rnd[(half, s)])}")

best = []
for N, depth, rb, lv in itertools.product((4, 8), (("pip", 0), ("pip", 3), ("atr", 0.5)), (1, 2), ("R", "BL")):
    sigs, nf, nr = detect(N, depth, rb, lv)
    st = stats(sigs)
    dname = "any" if depth[1] == 0 else (f"{depth[1]}p" if depth[0] == "pip" else f"{depth[1]}ATR")
    print(f"\nres={N*15}min drop>{dname:6s} reclaim<= {rb*5+5}min above {'resistance' if lv=='R' else 'M15 low':10s} "
          f"| flushes {nf} reclaimed {nr} ({100*nr/max(nf,1):.0f}%) {len(sigs)/days:.2f}/day")
    for half in ("train", "test"):
        for s in (1, -1): print(f"   {half:5s} {'BUY ' if s>0 else 'SELL'} {line(st.get((half, s), []))}")
    allb = [x for x in sigs if x[1] > 0]
    best.append((N, dname, rb, lv, sigs))
