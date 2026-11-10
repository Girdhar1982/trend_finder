import sys, numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from stretch_core import S
from swing_recall import det_trap, det_pivot, det_choch
t,o,h,l,c,v,atr,n=sd.t,sd.o,sd.h,sd.l,sd.c,sd.v,sd.atr,sd.n
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%m-%d %H:%M')
types={'trap30':det_trap(6),'trap60':det_trap(12),'sweep':det_pivot(3,'sweep'),'retest':det_pivot(3,'retest'),'choch':det_choch(24,3)}
U={}
for nm,sig in types.items():
    for i,s in sig: U.setdefault((i,s),[]).append(nm)
vavg=pd.Series(v).rolling(20).mean().values
a0,a1=sys.argv[1],sys.argv[2]
for (i,s),k in sorted(U.items()):
    ts=tstr(i)
    if not (a0<=ts<=a1): continue
    st=S[s][i]; vx=v[i]/vavg[i]; d24=(c[i]-l[i-288:i].min())/atr[i] if s>0 else (h[i-288:i].max()-c[i])/atr[i]
    tier='A' if st>=0 and vx>=1 else ('B' if st>=0 or d24<=3 else 'C')
    up=(c[i]-sd.ema288[i])/atr[i]; sl=(sd.ema288[i]-sd.ema288[i-36])/atr[i]
    print(f"{ts} {'BUY ' if s>0 else 'SELL'} {tier} {'+'.join(k):18s} stretch {st:5.2f} vol {vx:4.2f}  price vs EMA288 {up:+5.1f} ATR, EMA288 slope {sl:+4.2f}")
