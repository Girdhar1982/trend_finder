"""
Sweep/reclaim study on USDJPY M5  (bar times = server time = NY+7h, see memory note).

Setup (long version; the short version is the exact mirror, done by negating prices):
  1. BOX    : last L bars before the bait form a range no wider than W_MAX * ATR14.
  2. BAIT   : first bar that CLOSES above the box high by >= BAIT_MIN * ATR  (the early "breakout").
  3. TOUCH  : within MAXW bars price comes back to the box low (low <= box_low + TOL*ATR).
              type 'sweep' if low < box_low, else 'retest'.
  4. RECLAIM: within RECL bars of the touch, a bullish bar closing above box_low
              (optionally with tick volume >= VMULT * 20-bar average).
Compared entries (same events, same exits):
  E1 = buy at the bait close (what "entering early" looks like)
  E2 = buy at the reclaim close
Exit model: bracket SL=SL_ATR*ATR / TP=TP_ATR*ATR, timeout TMAX bars; stop wins ties.
Cost: bar spread (points*0.001) charged on every entry.
Baseline: every bar in the same hours, long and short, same bracket.

usage: python -I sweep_reclaim_study.py [hour_from hour_to]   (server hours, default 6 13)
"""
import sys, datetime as dt
import numpy as np
import MetaTrader5 as mt5

H0, H1 = (int(sys.argv[1]), int(sys.argv[2])) if len(sys.argv) > 2 else (6, 13)
L, W_MAX, BAIT_MIN, MAXW, TOL, RECL, VMULT = 24, 5.0, 0.3, 24, 0.3, 3, 1.0
SL_ATR, TP_ATR, TMAX = 1.5, 2.5, 48
PIP = 0.01

mt5.initialize(); mt5.symbol_select("USDJPY", True)
r = mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 50000)
t = r['time'].astype('int64')
o, h, l, c = (r[k].astype(float) for k in ('open', 'high', 'low', 'close'))
v = r['tick_volume'].astype(float); sp = r['spread'].astype(float) * 0.001
n = len(r)
hour = ((t % 86400) // 3600).astype(int)
tstr = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime('%m-%d %H:%M')

pc = np.r_[c[0], c[:-1]]
tr = np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))
atr = np.convolve(tr, np.ones(14) / 14, 'full')[:n]; atr[:14] = np.nan
vavg = np.convolve(v, np.ones(20) / 20, 'full')[:n]; vavg[:20] = np.nan


def bracket(O, Hh, Ll, C, i, entry, atr_i, cost):
    """long trade entered at close of bar i. returns (R, mae_pips, mfe_pips, fwd12, fwd24, fwd48)"""
    sl, tp = entry - SL_ATR * atr_i, entry + TP_ATR * atr_i
    R = None; end = min(n - 1, i + TMAX)
    for k in range(i + 1, end + 1):
        if Ll[k] <= sl: R = -SL_ATR; break
        if Hh[k] >= tp: R = TP_ATR; break
    if R is None: R = (C[end] - entry) / atr_i
    R = (R * atr_i - cost) / (SL_ATR * atr_i)          # in units of risk (1R = stop distance)
    seg = slice(i + 1, end + 1)
    mae = (entry - Ll[seg].min()) / PIP; mfe = (Hh[seg].max() - entry) / PIP
    f = [((C[min(n - 1, i + m)] - entry) / PIP) for m in (12, 24, 48)]
    return R, mae, mfe, *f


def find_events(sign):
    O, Hh, Ll, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
    ev = []; i = L + 20
    while i < n - TMAX - 2:
        if hour[i] < H0 or hour[i] >= H1: i += 1; continue
        a = atr[i - 1]
        top, bot = Hh[i - L:i].max(), Ll[i - L:i].min()
        if (top - bot) <= W_MAX * a and C[i] > top + BAIT_MIN * a and C[i - 1] <= top:
            touch = None
            for j in range(i + 1, min(i + MAXW, n - TMAX - 4)):
                if Ll[j] <= bot + TOL * a: touch = j; break
            if touch is not None:
                rec = None
                for k in range(touch, touch + RECL + 1):
                    if C[k] > bot and C[k] > O[k]: rec = k; break
                if rec is not None:
                    ev.append(dict(sign=sign, bait=i, touch=touch, rec=rec, bot=bot, top=top, a=a,
                                   typ='sweep' if Ll[touch:rec + 1].min() < bot else 'retest',
                                   volx=v[rec] / vavg[rec]))
                    i = rec + 1; continue
        i += 1
    return ev, (O, Hh, Ll, C)


rows = []
for sign in (1, -1):
    ev, (O, Hh, Ll, C) = find_events(sign)
    for e in ev:
        for name, idx in (('E1', e['bait']), ('E2', e['rec'])):
            res = bracket(O, Hh, Ll, C, idx, C[idx], e['a'], sp[idx])
            rows.append((name, e, res, idx))

# baseline: every bar in session hours, both directions, same bracket
base = []
for sign in (1, -1):
    O, Hh, Ll, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
    for i in range(40, n - TMAX - 2):
        if H0 <= hour[i] < H1 and not np.isnan(atr[i]):
            base.append(bracket(O, Hh, Ll, C, i, C[i], atr[i], sp[i]))
base = np.array(base)


def summ(label, res):
    a = np.array(res)
    if len(a) == 0: print(f"{label:34s} n=0"); return
    print(f"{label:34s} n={len(a):3d}  win={np.mean(a[:,0]>0)*100:4.0f}%  avgR={a[:,0].mean():+.2f}  "
          f"MAE={np.median(a[:,1]):5.1f}p MFE={np.median(a[:,2]):5.1f}p  "
          f"fwd12/24/48 med={np.median(a[:,3]):+5.1f}/{np.median(a[:,4]):+5.1f}/{np.median(a[:,5]):+5.1f}p")


print(f"hours {H0}-{H1} server | bars {tstr(0)} .. {tstr(n-1)} | events long={sum(1 for x in rows if x[0]=='E1' and x[1]['sign']>0)} "
      f"short={sum(1 for x in rows if x[0]=='E1' and x[1]['sign']<0)}")
summ("BASELINE (every bar, both dirs)", base[:, :6])
mid = t[0] + (t[-1] - t[0]) // 2
for typ in ('all', 'sweep', 'retest'):
    for vol in (False, True):
        for name in ('E1', 'E2'):
            sel = [x for x in rows if x[0] == name and (typ == 'all' or x[1]['typ'] == typ)
                   and (not vol or x[1]['volx'] >= 1.3)]
            summ(f"{name} {typ}{' vol>=1.3x' if vol else ''}", [x[2] for x in sel])
print("\nstability, E2 all, split by half of the sample:")
for lab, f in (("first half", lambda x: t[x[3]] < mid), ("second half", lambda x: t[x[3]] >= mid)):
    summ(lab, [x[2] for x in rows if x[0] == 'E2' and f(x)])
    summ(lab + " (E1)", [x[2] for x in rows if x[0] == 'E1' and f(x)])

print("\nevents on 5-6 Nov (validation):")
for name, e, res, idx in rows:
    if name == 'E2' and tstr(e['bait'])[:5] in ('11-05', '11-06'):
        print(f"  dir={'L' if e['sign']>0 else 'S'} bait {tstr(e['bait'])} touch {tstr(e['touch'])} reclaim {tstr(e['rec'])} {e['typ']} volx={e['volx']:.2f}")
print("\nlast 10 events:")
for name, e, res, idx in [x for x in rows if x[0] == 'E2'][-10:]:
    print(f"  {'L' if e['sign']>0 else 'S'} bait {tstr(e['bait'])} -> reclaim {tstr(e['rec'])} {e['typ']:6s} R={res[0]:+.2f}")

# ---- unbiased view: ALL baits, no hindsight (can't know at bait time whether it will fail) ----
print("\nALL breakouts from the box (no hindsight):")
allb = []
for sign in (1, -1):
    O, Hh, Ll, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
    for i in range(L + 20, n - TMAX - 2):
        if not (H0 <= hour[i] < H1): continue
        a = atr[i - 1]; top, bot = Hh[i - L:i].max(), Ll[i - L:i].min()
        if (top - bot) <= W_MAX * a and C[i] > top + BAIT_MIN * a and C[i - 1] <= top:
            failed = bool((Ll[i + 1:i + MAXW + 1] <= bot + TOL * a).any())
            longR = bracket(O, Hh, Ll, C, i, C[i], a, sp[i])
            shortR = bracket(-O, -Ll, -Hh, -C, i, -C[i], a, sp[i])   # fade it (short at bait close)
            allb.append((failed, longR, shortR))
nf = sum(x[0] for x in allb)
print(f"  breakouts={len(allb)}  failed (back to box low within {MAXW} bars)={nf} ({nf/len(allb)*100:.0f}%)")
summ("  follow breakout (long)", [x[1] for x in allb])
summ("  fade breakout (short at bait close)", [x[2] for x in allb])
