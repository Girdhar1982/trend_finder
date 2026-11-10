import numpy as np, datetime as dt
from stretch_core import *
TH_A,TH_S=1.531,1.896; TP=SL=1.5
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%m-%d %H:%M')
rows=[]
for s in (1,-1):
    O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); last=-99
    for i in np.where(valid&(S[s]>=TH_A)&(C>O))[0]:
        if i-last<6 or i>=n-MAXB-2: continue
        last=i; a=atr[i]; ent=O[i+1]+sp[i+1]; stp=ent-SL*a; tgt=ent+TP*a; res=None; why='time'
        for j in range(i+1,i+MAXB+1):
            if L[j]<=stp: res=min(stp,O[j])-ent; why='stop'; break
            if H[j]>=tgt: res=tgt-ent; why='target'; break
        if res is None: res=C[i+MAXB]-ent
        rows.append((i,s,S[s][i],why,res/PIP))
rows.sort(); print("last 14 signals (server time):")
for i,s,sc,why,p in rows[-14:]: print(f"  {tstr(i)} {'BUY ' if s>0 else 'SELL'} score {sc:.2f} {'STRONG' if sc>=TH_S else 'sig   '} -> {why:6s} {p:+5.1f}p")
print("total signals:",len(rows)," in last 60 days:",sum(1 for r in rows if t[r[0]]>t[-1]-60*86400))
