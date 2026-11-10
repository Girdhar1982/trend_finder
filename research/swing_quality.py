"""Can we tell, at the signal bar, which candidates start an important swing? Train first 60% / test last 40%."""
import numpy as np, pandas as pd, warnings; warnings.filterwarnings('ignore')
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import roc_auc_score
import sweep_dataset as sd
from stretch_core import S
from swing_recall import det_trap, det_pivot, det_choch, PIP
t, o, h, l, c, v, atr, n, hour = sd.t, sd.o, sd.h, sd.l, sd.c, sd.v, sd.atr, sd.n, sd.hour
legs, D, _ = pd.read_pickle('swing_recall.pkl')
big = legs[legs['size'] >= 30]

types = {'trap30': det_trap(6), 'trap60': det_trap(12), 'psweep': det_pivot(3, 'sweep'), 'pretest': det_pivot(3, 'retest'), 'choch': det_choch(24, 3)}
rows = {}
for nm, sig in types.items():
    for i, s in sig:
        key = (i, s); rows.setdefault(key, set()).add(nm)
vavg = pd.Series(v).rolling(20).mean().values
atr_med = pd.Series(atr).rolling(576).median().values
hi288 = pd.Series(h).rolling(288).max().values; lo288 = pd.Series(l).rolling(288).min().values
recs = []
for (i, s), kinds in rows.items():
    if i < 700 or i + 1 >= n: continue
    ent = o[i + 1]
    m = big[(big.s == s) & (big.start <= i) & (big.end > i)]
    hit = any((ent - lg.p0) / (lg.p1 - lg.p0) <= 1 / 3 for _, lg in m.iterrows())
    a = atr[i]
    L, H = (l, h) if s > 0 else (-h, -l)
    move12 = s * (c[i] - c[i - 12]) / a; move48 = s * (c[i] - c[i - 48]) / a
    d24 = (c[i] - lo288[i - 1]) / a if s > 0 else (hi288[i - 1] - c[i]) / a     # distance from 24h extreme in trade's favourable side
    recs.append(dict(i=i, s=s, hit=int(hit), stretch=S[s][i], atrx=a / atr_med[i], volx=v[i] / vavg[i], hour=hour[i],
                     body=s * (c[i] - o[i]) / a, rng=(h[i] - l[i]) / a, move12=move12, move48=move48, d24=d24,
                     n_types=len(kinds), **{f"is_{k}": int(k in kinds) for k in types}))
df = pd.DataFrame(recs).sort_values('i').reset_index(drop=True)
X = df.drop(columns=['i', 'hit']); y = df.hit
cut = int(len(df) * 0.6)
print(f"candidates {len(df)} ({len(df)/((t[-1]-t[0])/86400*5/7):.1f}/day), base precision train {y[:cut].mean()*100:.1f}% test {y[cut:].mean()*100:.1f}%")
gb = GradientBoostingClassifier(n_estimators=200, max_depth=3, learning_rate=0.03, subsample=0.7, random_state=0).fit(X[:cut], y[:cut])
p = gb.predict_proba(X[cut:])[:, 1]
print(f"OOS AUC {roc_auc_score(y[cut:], p):.3f}")
te = df[cut:].copy(); te['p'] = p
for q in (0.5, 0.75, 0.9, 0.95):
    thr = np.quantile(gb.predict_proba(X[:cut])[:, 1], q)
    sel = te[te.p >= thr]
    print(f"  keep top {100-q*100:.0f}% (train threshold): test precision {sel.hit.mean()*100:4.1f}%  signals/day {len(sel)/((t[-1]-t[df.i[cut]])/86400*5/7):.1f}")
imp = pd.Series(gb.feature_importances_, X.columns).sort_values(ascending=False).round(3)
print("importance:", imp.head(8).to_dict())
print("\nunivariate (train | test precision by quartile):")
for f in ['stretch', 'atrx', 'volx', 'move12', 'move48', 'd24', 'rng', 'body', 'n_types']:
    try: qs = pd.qcut(df[f][:cut], 4, retbins=True, duplicates='drop')[1]
    except Exception: continue
    qs[0], qs[-1] = -1e9, 1e9
    a = df[:cut].groupby(pd.cut(df[f][:cut], qs)).hit.mean().values * 100
    b = df[cut:].groupby(pd.cut(df[f][cut:], qs)).hit.mean().values * 100
    print(f"  {f:8s} train " + " ".join(f"{x:4.1f}" for x in a) + " | test " + " ".join(f"{x:4.1f}" for x in b))
df.to_pickle('swing_candidates.pkl')
