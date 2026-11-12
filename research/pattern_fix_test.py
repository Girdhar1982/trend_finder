"""Do the fixes suggested after the 10 Nov 05:00 failed BUY improve Swing Radar PATTERN mode?
PATTERN = deep range sweep (depth>=0.7 ATR, vol>=1.3x) OR 1h trap (det_trap(12)), any trend.
Fixes tested (each alone, then combined):
  F1 stretch gate : stretch score (same formula as the indicator's Score()) >= cut
  F2 bigger push  : 1h trap needs the push close >= BAIT ATR beyond the range edge (indicator: 0.3)
  F3 no flip      : drop a signal if an OPPOSITE signal fired within N bars before it
                    (variant: ...unless that earlier signal had already hit its -10 stop)
Outcome = fwd(): +20 pips before -10 within 36 bars from next open + spread. Break-even 33%.
Train = first 60% of bars, test = last 40%."""
import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from swing_recall import det_trap
from trend_range_sweep import detect, fwd

t, n, o, h, l, c, atr, sp = sd.t, sd.n, sd.o, sd.h, sd.l, sd.c, sd.atr, sd.sp
PIP = 0.01
MU = (-1.5647647681, -1.9859023515, -2.6433684188); SDV = (1.3383025567, 5.7488277428, 9.3743545638)
cut = int(n * 0.6)
dtr = (t[cut] - t[700]) / 86400 * 5 / 7; dte = (t[n - 40] - t[cut]) / 86400 * 5 / 7
tstr = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime('%m-%d %H:%M')


def stretch(i, s):
    a = atr[i]
    z = [(s * (c[i] - sd.ema48[i]) / a - MU[0]) / SDV[0],
         (s * (c[i] - sd.ema288[i]) / a - MU[1]) / SDV[1],
         (s * (c[i] - sd.day_open[i]) / a - MU[2]) / SDV[2]]
    return -np.mean(z)


def stop_bar(i, s, dn=10, H=36):
    """bar index where the -10 stop of a signal at i is hit (or None)"""
    O, Hh, L = (o, h, l) if s > 0 else (-o, -l, -h)
    ent = O[i + 1] + sp[i + 1]
    for j in range(i + 1, min(n, i + H + 1)):
        if L[j] <= ent - dn * PIP: return j
        if Hh[j] >= ent + 20 * PIP: return None
    return None


def build(bait=0.3):
    ev = detect()
    sw = ev[(ev.depth >= 0.7) & (ev.volx >= 1.3)][['i', 's']].assign(kind='sweep')
    tr = pd.DataFrame([(i, s) for i, s in det_trap(12, BAIT=bait) if 700 <= i < n - 40], columns=['i', 's']).assign(kind='trap')
    U = pd.concat([sw, tr]).groupby(['i', 's']).kind.apply(lambda x: '+'.join(sorted(set(x)))).reset_index().sort_values('i')
    U['w20'] = [fwd(i, s) for i, s in zip(U.i, U.s)]
    U['st'] = [stretch(i, s) for i, s in zip(U.i, U.s)]
    return U.reset_index(drop=True)


def flip_mask(U, N, unless_failed=False):
    keep = np.ones(len(U), bool)
    idx, sides = U.i.values, U.s.values
    for k in range(len(U)):
        for m in range(k - 1, -1, -1):
            if idx[k] - idx[m] > N: break
            if sides[m] != sides[k]:
                if unless_failed:
                    sb = stop_bar(idx[m], sides[m])
                    if sb is not None and sb <= idx[k]: continue   # earlier one already failed -> allow
                keep[k] = False; break
    return keep


def rep(lab, d):
    a = d[d.i < cut]; b = d[d.i >= cut]
    print(f"{lab:46s} train {a.w20.mean()*100:5.1f}% ({len(a)/dtr:4.1f}/d, n={len(a):4d})   "
          f"test {b.w20.mean()*100:5.1f}% ({len(b)/dte:4.1f}/d, n={len(b):4d})")


U = build(0.3)
print(f"data {tstr(700)} .. {tstr(n-41)}   train/test split at {tstr(cut)}")
print("break-even 33%; random bars ~27-30%\n")
rep("BASELINE: PATTERN mode as it is now", U)
rep("  sweep only", U[U.kind.str.contains('sweep')])
rep("  trap only", U[U.kind == 'trap'])

print("\nF1  stretch gate (score >= cut):")
for ct in (-1.0, -0.5, 0.0, 0.25, 0.5):
    rep(f"  stretch >= {ct:+.2f}", U[U.st >= ct])
print("  ...on the trap signals only (sweeps untouched):")
for ct in (-0.5, 0.0):
    rep(f"  trap needs stretch >= {ct:+.2f}", U[(U.kind != 'trap') | (U.st >= ct)])

print("\nF2  bigger push for the 1h trap (BAIT, ATR):")
UB = {}
for b in (0.3, 0.5, 0.7, 1.0):
    UB[b] = U if b == 0.3 else build(b)
    rep(f"  BAIT {b:.1f}  (all PATTERN)", UB[b])
    rep(f"  BAIT {b:.1f}  (trap only)", UB[b][UB[b].kind == 'trap'])

print("\nF3  no opposite signal within N bars before:")
for N in (6, 12, 24):
    rep(f"  block flips, N={N}", U[flip_mask(U, N)])
    rep(f"  block flips unless 1st already failed, N={N}", U[flip_mask(U, N, True)])

print("\nCOMBINED:")
for b, ct, N in ((0.3, 0.0, 12), (0.7, 0.0, 12), (0.7, -0.5, 12), (0.5, 0.0, 0)):
    d = UB[b]; d = d[d.st >= ct]
    if N: d = d[flip_mask(d, N, True)]
    rep(f"  BAIT {b} + stretch>={ct:+.1f}" + (f" + no-flip {N}" if N else ""), d)

print("\n10 Nov signals under baseline:")
for r in U[U.i >= np.searchsorted(t, dt.datetime(2026, 11, 10, tzinfo=dt.timezone.utc).timestamp())].itertuples():
    print(f"  {tstr(r.i)} {'BUY ' if r.s > 0 else 'SELL'} {r.kind:11s} stretch {r.st:+.2f} -> "
          f"{'+20 first' if r.w20 == 1 else ('-10 first' if r.w20 == 0 else 'timeout +')}")
