import numpy as np, pandas as pd
df=pd.read_pickle('selection_dataset.pkl'); df['depth_p']=df.depth*df.atr_pips
s=df[df.kind=='sweep'].copy(); cut=int(len(df)*0.6)
s['half']=np.where(s.index<cut,'tr','te')
print("sweeps only, indicator exit (pips/trade), by sweep depth beyond the level, in ATR:")
for lo,hi in ((0.05,0.15),(0.15,0.3),(0.3,0.6),(0.6,1.0),(1.0,99)):
    x=s[(s.depth>=lo)&(s.depth<hi)]
    f=lambda y: f"n={len(y):4d} avg={y.pips.mean():+5.1f}p win={np.mean(y.pips>0)*100:3.0f}% big3R={y.big.mean()*100 if 'big' in y else (y.mfe_r>=3).mean()*100:3.0f}%"
    print(f"  depth {lo:.2f}-{hi:4.2f} ATR (~{lo*df.atr_pips.median():.1f}-{min(hi,9)*df.atr_pips.median():.0f}p)  train {f(x[x.half=='tr'])} | test {f(x[x.half=='te'])}  /day={len(x)/165:.1f}")
