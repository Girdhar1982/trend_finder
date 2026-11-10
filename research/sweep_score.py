import numpy as np, pandas as pd, warnings; warnings.filterwarnings('ignore')
df = pd.read_pickle('sweep_dataset.pkl').sort_values('t').reset_index(drop=True)
df['big'] = (df.mfe_r >= 3).astype(int); df['dt'] = pd.to_datetime(df.t, unit='s')
cut = int(len(df) * 0.6)
# simple, fixed-form stretch score: how far price is stretched AGAINST the trade direction (counter-trend extension)
cols = ['trend48', 'trend288', 'dist_dayopen']
mu = df.iloc[:cut][cols].mean(); sd = df.iloc[:cut][cols].std()          # fit on train only
df['score'] = -((df[cols] - mu) / sd).mean(axis=1)
tr_, te_ = df.iloc[:cut], df.iloc[cut:]
q = tr_.score.quantile([.25, .5, .75, .9]).values
def bucket(x): return np.digitize(x, q)
for nm, d in (("TRAIN", tr_), ("TEST", te_)):
    g = d.groupby(bucket(d.score)).agg(n=('big','size'), big=('big','mean'), p2=('mfe_r', lambda s: (s>=2).mean()), r36=('r36','mean'), mfe_med=('mfe_r','median')).round(3)
    print(nm, "score buckets (0=least stretched .. 4=top 10%)"); print(g)
for thr_name, thr in (("top25%", q[2]), ("top10%", q[3])):
    for nm, d in (("train", tr_), ("test", te_)):
        s = d[d.score >= thr]
        print(f"{thr_name} {nm}: n={len(s)} big={s.big.mean():.3f} r36={s.r36.mean():+.3f} per-month n={len(s)/ max(1,d.dt.dt.to_period('M').nunique()):.0f}")
# where do the two reference days rank?
for a, b, lab in (("2026-11-06 09:30", "2026-11-06 09:45", "6 Nov sweep"), ("2026-11-05 07:15", "2026-11-05 07:30", "5 Nov retest"), ("2026-11-05 09:10", "2026-11-05 09:30", "5 Nov late")):
    m = df[(df.dt >= a) & (df.dt <= b)]
    print(lab, m[['dt','sign','kind','score','depth','volx','trend48','trend288','mfe_pips','r36']].round(2).to_string(index=False) if len(m) else "no candidate")
# by month, top25%
df['m'] = df.dt.dt.to_period('M'); top = df[df.score >= q[2]]
print(top.groupby('m').agg(n=('big','size'), big=('big','mean'), r36=('r36','mean')).round(3).T.to_string())
