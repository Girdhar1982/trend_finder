import numpy as np, pandas as pd, datetime as dt
from stretch_core import *
TH_A,TH_S=1.531,1.896; TP,SL=1.5,1.5
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%d %H:%M')
d0=int(np.searchsorted(t,dt.datetime(2026,11,5,tzinfo=dt.timezone.utc).timestamp())); d1=n-1
rows=[]
for s in (1,-1):
    O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); last=-99
    for i in np.where(valid&(S[s]>=TH_A)&(C>O))[0]:
        if i-last<6 or i>=n-MAXB-2: continue
        last=i
        if i<d0: continue
        a=atr[i]; ent=O[i+1]+sp[i+1]; stp=ent-SL*a; tgt=ent+TP*a; res=None; why='time'
        for j in range(i+1,i+MAXB+1):
            if L[j]<=stp: res=min(stp,O[j])-ent; why='stop'; xj=j; break
            if H[j]>=tgt: res=tgt-ent; why='target'; xj=j; break
        if res is None: xj=i+MAXB; res=C[xj]-ent
        rows.append((i,s,S[s][i],s*ent,xj,res/PIP,why,a/PIP))
rows.sort()
print(f"{'signal bar':>11} {'dir':>4} {'score':>5} {'str':>6} {'entry':>8} {'exit':>11} {'why':>6} {'pips':>6} {'ATRp':>5}")
for i,s,sc,ent,xj,p,why,a in rows:
    print(f"{tstr(i):>11} {'BUY' if s>0 else 'SELL':>4} {sc:5.2f} {'STRONG' if sc>=TH_S else 'sig':>6} {ent:8.3f} {tstr(xj):>11} {why:>6} {p:6.1f} {a:5.1f}")
p=np.array([r[5] for r in rows]); print(f"\n{len(rows)} signals  total {p.sum():+.1f}p  win {np.mean(p>0)*100:.0f}%")
for dd in (5,6):
    q=[r[5] for r in rows if dt.datetime.fromtimestamp(t[r[0]],dt.timezone.utc).day==dd]; print(f"  Nov {dd}: n={len(q)} total={sum(q):+.1f}p")
