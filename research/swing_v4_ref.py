"""Reference output for the Swing Radar (Sweep_Reclaim_Alert v4) indicator: union of 5 causal detectors, tiered A/B/C."""
import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from stretch_core import S
from swing_recall import det_trap, det_pivot, det_choch
t, o, h, l, c, v, atr, n = sd.t, sd.o, sd.h, sd.l, sd.c, sd.v, sd.atr, sd.n
tstr = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime('%Y-%m-%d %H:%M')
types = {'trap30': det_trap(6), 'trap60': det_trap(12), 'sweep': det_pivot(3, 'sweep'), 'retest': det_pivot(3, 'retest'), 'choch': det_choch(24, 3)}
U = {}
for nm, sig in types.items():
    for i, s in sig: U.setdefault((i, s), []).append(nm)
vavg = pd.Series(v).rolling(20).mean().values
rows = []
for (i, s), k in sorted(U.items()):
    if i < 700: continue
    a = atr[i]; st = S[s][i]; vx = v[i] / vavg[i]
    d24 = (c[i] - l[i - 288:i].min()) / a if s > 0 else (h[i - 288:i].max() - c[i]) / a
    tier = 'A' if (st >= 0 and vx >= 1.0) else ('B' if (st >= 0 or d24 <= 3) else 'C')
    rows.append((i, s, tier, '+'.join(k), st, vx, d24))
df = pd.DataFrame(rows, columns=['i', 's', 'tier', 'types', 'stretch', 'volx', 'd24'])
days = (t[-1] - t[700]) / 86400 * 5 / 7
print(df.tier.value_counts().sort_index().apply(lambda x: f"{x} ({x/days:.1f}/day)").to_dict())
print("last 15 A/B signals:")
for r in df[df.tier.isin(['A', 'B'])].tail(15).itertuples():
    print(f"  {tstr(r.i)} {'BUY ' if r.s > 0 else 'SELL'} {r.tier} {r.types:22s} stretch {r.stretch:5.2f} vol {r.volx:4.2f} d24 {r.d24:5.2f}")
