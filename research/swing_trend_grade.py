import numpy as np, pandas as pd, itertools
import sweep_dataset as sd
from swing_recall import evaluate
legs,_,_=pd.read_pickle('swing_recall.pkl'); df=pd.read_pickle('swing_candidates.pkl'); t=sd.t; c=sd.c; atr=sd.atr
e288=sd.ema288; e48=sd.ema48
cut_i=df.i.iloc[int(len(df)*0.6)]
df['up288']=[s*(c[i]-e288[i])/atr[i] for i,s in zip(df.i,df.s)]
df['sl288']=[s*(e288[i]-e288[i-36])/atr[i] for i,s in zip(df.i,df.s)]
df['pb48']=[-s*(c[i]-e48[i])/atr[i] for i,s in zip(df.i,df.s)]      # >0 = price pulled back below EMA48 (for a buy)
df['with']=(df.up288>0)&(df.sl288>0)
df['against']=(df.up288<0)&(df.sl288<0)
def rep(lab,m):
    out=[f"{lab:58s}"]
    for half in ('tr','te'):
        lg=legs[legs.start<cut_i] if half=='tr' else legs[legs.start>=cut_i]
        mm=m&((df.i<cut_i) if half=='tr' else (df.i>=cut_i))
        r,_=evaluate('x',list(zip(df.i[mm],df.s[mm])),lg)
        days=((t[cut_i]-t[700]) if half=='tr' else (t[-1]-t[cut_i]))/86400*5/7
        out.append(f"{half}: {mm.sum()/days:4.1f}/d prec {r['precision']:4.1f}% rec30 {r['recall_30']:4.1f}%")
    print("  ".join(out))
rep("random-like baseline: all candidates",df.i>0)
rep("current A (stretch>=0 & vol>=1)",(df.stretch>=0)&(df.volx>=1))
rep("current A, but only WITH the 24h trend",(df.stretch>=0)&(df.volx>=1)&df['with'])
rep("current A, NOT against... (with or flat)",(df.stretch>=0)&(df.volx>=1)&~df['against'] & ~((df.up288>0)&(df.sl288<0)))
print("\nwith-trend candidates graded by pullback depth (pb48 = ATR below EMA48):")
w=df['with']
for lo,hi in ((-99,-1),(-1,0),(0,1),(1,2),(2,99)):
    rep(f"  with trend, pb48 in [{lo},{hi})",w&(df.pb48>=lo)&(df.pb48<hi))
for vx in (1.0,1.3):
    rep(f"  with trend, pb48>=0 & vol>={vx}",w&(df.pb48>=0)&(df.volx>=vx))
    rep(f"  with trend, pb48>=1 & vol>={vx}",w&(df.pb48>=1)&(df.volx>=vx))
print("\nby trend context, all candidates:")
rep("  with trend",w); rep("  against trend",df['against']); rep("  mixed",~w&~df['against'])
