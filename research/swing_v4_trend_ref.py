import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from stretch_core import S
from swing_recall import det_trap, det_pivot, det_choch
t,o,h,l,c,v,atr,n=sd.t,sd.o,sd.h,sd.l,sd.c,sd.v,sd.atr,sd.n; e288=sd.ema288
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%Y-%m-%d %H:%M')
types={'trap30':det_trap(6),'trap60':det_trap(12),'sweep':det_pivot(3,'sweep'),'retest':det_pivot(3,'retest'),'choch':det_choch(24,3)}
U={}
for nm,sig in types.items():
    for i,s in sig: U.setdefault((i,s),[]).append(nm)
vavg=pd.Series(v).rolling(20).mean().values
rows=[]
for (i,s),k in sorted(U.items()):
    if i<700: continue
    a=atr[i]; st=S[s][i]; vx=v[i]/vavg[i]
    d24=(c[i]-l[i-288:i].min())/a if s>0 else (h[i-288:i].max()-c[i])/a
    up=s*(c[i]-e288[i])/a; sl=s*(e288[i]-e288[i-36])/a
    ctx=1 if (up>0 and sl>0) else (-1 if (up<0 and sl<0) else 0)
    tier='A' if (st>=0 and vx>=1) else ('B' if (st>=0 or d24<=3) else 'C')
    rows.append((i,s,tier,'+'.join(k),ctx))
df=pd.DataFrame(rows,columns=['i','s','tier','types','ctx'])
days=(t[-1]-t[700])/86400*5/7
for lab,m in (("with trend only",df.ctx==1),("not against",df.ctx>=0),("off",df.ctx>-9)):
    x=df[m]; print(f"{lab:16s} A {(x.tier=='A').sum()/days:4.2f}/day  B {(x.tier=='B').sum()/days:4.2f}/day  C {(x.tier=='C').sum()/days:5.2f}/day")
w=df[(df.ctx==1)&(df.tier.isin(['A','B']))]
print("\nwith-trend filter: last 15 A/B signals (for the log check):")
for r in w.tail(15).itertuples(): print(f"  {tstr(r.i)} {'BUY ' if r.s>0 else 'SELL'} {r.tier} {r.types}")
print("\n5-6 Nov, with-trend, all tiers:")
for r in df[(df.ctx==1)&(df.i>=np.searchsorted(t,dt.datetime(2026,11,5,tzinfo=dt.timezone.utc).timestamp()))].itertuples():
    print(f"  {tstr(r.i)} {'BUY ' if r.s>0 else 'SELL'} {r.tier} {r.types}")
