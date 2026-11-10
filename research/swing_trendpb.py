import numpy as np, pandas as pd
import sweep_dataset as sd
from swing_recall import evaluate
legs,_,_=pd.read_pickle('swing_recall.pkl'); df=pd.read_pickle('swing_candidates.pkl'); t=sd.t; e288=sd.ema288; e48=sd.ema48; c=sd.c; atr=sd.atr
cut_i=df.i.iloc[int(len(df)*0.6)]
df['above288']=[s*(c[i]-e288[i])/atr[i] for i,s in zip(df.i,df.s)]
df['slope288']=[s*(e288[i]-e288[i-36])/atr[i] for i,s in zip(df.i,df.s)]
df['slope48']=[s*(e48[i]-e48[i-12])/atr[i] for i,s in zip(df.i,df.s)]
def rep(lab,m):
    out=[f"{lab:52s}"]
    for half in ('tr','te'):
        lg=legs[legs.start<cut_i] if half=='tr' else legs[legs.start>=cut_i]
        mm=m&((df.i<cut_i) if half=='tr' else (df.i>=cut_i))
        r,_=evaluate('x',list(zip(df.i[mm],df.s[mm])),lg)
        days=((t[cut_i]-t[700]) if half=='tr' else (t[-1]-t[cut_i]))/86400*5/7
        out.append(f"{half}: {mm.sum()/days:4.1f}/d prec {r['precision']:4.1f}% rec30 {r['recall_30']:4.1f}%")
    print("  ".join(out))
rep("all candidates",df.i>0)
rep("with trend: above EMA288 & EMA288 rising",(df.above288>0)&(df.slope288>0))
rep("with trend, strong slope (>0.5 ATR / 3h)",(df.above288>0)&(df.slope288>0.5))
rep("with trend & pullback (below EMA48)",(df.above288>0)&(df.slope288>0)&(df.trend48<0) if 'trend48' in df else (df.above288>0)&(df.slope288>0))
rep("counter trend (below EMA288 & falling)",(df.above288<0)&(df.slope288<0))
rep("with trend & volx>=1.0",(df.above288>0)&(df.slope288>0)&(df.volx>=1.0))
rep("A (stretch>=0 & volx>=1)",(df.stretch>=0)&(df.volx>=1.0))
