import numpy as np, pandas as pd, warnings; warnings.filterwarnings('ignore')
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
df = pd.read_pickle('sweep_dataset.pkl').sort_values('t').reset_index(drop=True)
df['big'] = (df.mfe_r >= 3).astype(int)
df['dt'] = pd.to_datetime(df.t, unit='s')
cut = int(len(df) * 0.6); tr_, te_ = df.iloc[:cut], df.iloc[cut:]
print(f"n={len(df)}  train {tr_.dt.min().date()}..{tr_.dt.max().date()} ({len(tr_)})  test {te_.dt.min().date()}..{te_.dt.max().date()} ({len(te_)})")
print(f"base: big(>=3R) train {tr_.big.mean():.3f} test {te_.big.mean():.3f}; meanR36 train {tr_.r36.mean():+.3f} test {te_.r36.mean():+.3f}\n")
num = ['depth','volx','closepos','body','wick','trend288','trend48','slope288','drop','compress','touches','atrx','atr_pips','dist_pdl','dist_dayopen','risk_atr','hour','LB']
print("UNIVARIATE: quartile bins, train vs test  (big = reached 3R before stop; r36 = R after 36 bars)")
for f in num:
    try: q = pd.qcut(tr_[f], 4, duplicates='drop', retbins=True)[1]
    except Exception: continue
    q[0], q[-1] = -1e9, 1e9
    b1 = pd.cut(tr_[f], q); b2 = pd.cut(te_[f], q)
    g1 = tr_.groupby(b1).agg(n=('big','size'), big=('big','mean'), r=('r36','mean'))
    g2 = te_.groupby(b2).agg(n=('big','size'), big=('big','mean'), r=('r36','mean'))
    flag = ''
    d1 = g1.big.values; d2 = g2.big.values
    if len(d1) >= 3 and np.sign(d1[-1]-d1[0]) == np.sign(d2[-1]-d2[0]) and abs(d2[-1]-d2[0]) > 0.04: flag = '  <-- consistent'
    print(f"{f:13s} train big " + " ".join(f"{x:.2f}" for x in d1) + "  | test big " + " ".join(f"{x:.2f}" for x in d2) + flag)
print()
for f in ['kind','sign','dow']:
    print(f, "train:", tr_.groupby(f).big.mean().round(3).to_dict(), " test:", te_.groupby(f).big.mean().round(3).to_dict())
print("\nhour of day (server) big-rate  [n]:")
hh = df.groupby('hour').agg(n=('big','size'), big=('big','mean'), r=('r36','mean')).round(3); print(hh.T.to_string())

# multivariate, strict out-of-sample
X = df[num + ['sign']].copy(); X['kind'] = (df.kind == 'sweep').astype(int); X = X.fillna(0)
y = df.big
gb = GradientBoostingClassifier(n_estimators=150, max_depth=2, learning_rate=0.05, subsample=0.7, random_state=1).fit(X.iloc[:cut], y.iloc[:cut])
p = gb.predict_proba(X.iloc[cut:])[:, 1]
print(f"\nGradientBoosting OOS AUC for 'big': {roc_auc_score(y.iloc[cut:], p):.3f}   (0.5 = no skill)")
imp = pd.Series(gb.feature_importances_, X.columns).sort_values(ascending=False).head(8).round(3); print(imp.to_dict())
te = te_.copy(); te['p'] = p
te['bucket'] = pd.qcut(te.p, 4, labels=False, duplicates='drop')
print(te.groupby('bucket').agg(n=('big','size'), big=('big','mean'), meanR36=('r36','mean'), mfe_med=('mfe_r','median')).round(3))
# walk-forward by month
df['m'] = df.dt.dt.to_period('M')
print("\nby month: n, big-rate, meanR36"); print(df.groupby('m').agg(n=('big','size'), big=('big','mean'), r36=('r36','mean')).round(3).T.to_string())
