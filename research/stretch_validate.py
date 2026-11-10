import numpy as np, pandas as pd, datetime as dt
from stretch_core import *
th=lambda q: float(np.quantile(qs_all,q))
print("theta (train quantiles): ",{q:round(th(q),3) for q in (0.90,0.95,0.97,0.98,0.985,0.99)})
def stats(r,lab):
    if len(r)==0: return
    p=r[:,1]; eq=np.cumsum(p); dd=(np.maximum.accumulate(eq)-eq).max()
    gp=p[p>0].sum(); gl=-p[p<0].sum()
    print(f"{lab:34s} n={len(p):4d} avg={p.mean():+5.2f}p win={np.mean(p>0)*100:3.0f}% PF={gp/gl:4.2f} total={p.sum():+6.0f}p maxDD={dd:5.0f}p worst={p.min():+5.0f}p")
for tp,sl in ((1.5,1.5),(1.5,3.0),(1.0,2.0)):
    print(f"\n=== TP {tp} ATR / SL {sl} ATR / time stop 24 bars ===")
    for q in (0.97,0.98,0.985,0.99):
        r=run(th(q),tp,sl); stats(r[r[:,0]<cut],f"q={q} TRAIN"); stats(r[r[:,0]>=cut],f"q={q} TEST")
tp,sl,q=1.5,1.5,0.98
r=run(th(q),tp,sl); te=r[r[:,0]>=cut]
print(f"\n--- chosen config q={q} TP {tp} SL {sl}: TEST by month and side ---")
mon=pd.to_datetime(t[te[:,0].astype(int)],unit='s').to_period('M')
print(pd.DataFrame({'m':mon,'p':te[:,1]}).groupby('m').p.agg(n='size',avg='mean',tot='sum',win=lambda s:(s>0).mean()*100).round(1).T.to_string())
for s_,nm in ((1,'long'),(-1,'short')):
    rs=[];
    for i,p in te:
        pass
# side split
def run_side(theta,tp,sl,side):
    O,H,L,C=(o,h,l,c) if side>0 else (-o,-l,-h,-c); out=[]; last=-99
    for i in np.where(valid&(S[side]>=theta)&(C>O))[0]:
        if i-last<6 or i>=n-MAXB-2: continue
        last=i; a=atr[i]; ent=O[i+1]+sp[i+1]; stp=ent-sl*a; tgt=ent+tp*a; res=None
        for j in range(i+1,i+MAXB+1):
            if L[j]<=stp: res=min(stp,O[j])-ent; break
            if H[j]>=tgt: res=tgt-ent; break
        if res is None: res=C[i+MAXB]-ent
        out.append((i,res/PIP))
    return np.array(out)
for side,nm in ((1,'LONG'),(-1,'SHORT')):
    r=run_side(th(q),tp,sl,side); stats(r[r[:,0]<cut],f"{nm} TRAIN"); stats(r[r[:,0]>=cut],f"{nm} TEST")
print("\n--- band test: A = score>=q98, B = q90..q98 (exclusive), TP1.5 SL1.5 ---")
rB=[]
for side in (1,-1):
    O,H,L,C=(o,h,l,c) if side>0 else (-o,-l,-h,-c); last=-99
    for i in np.where(valid&(S[side]>=th(0.90))&(S[side]<th(0.98))&(C>O))[0]:
        if i-last<6 or i>=n-MAXB-2: continue
        last=i; a=atr[i]; ent=O[i+1]+sp[i+1]; stp=ent-1.5*a; tgt=ent+1.5*a; res=None
        for j in range(i+1,i+MAXB+1):
            if L[j]<=stp: res=min(stp,O[j])-ent; break
            if H[j]>=tgt: res=tgt-ent; break
        if res is None: res=C[i+MAXB]-ent
        rB.append((i,res/PIP))
rB=np.array(rB); stats(rB[rB[:,0]<cut],"B band TRAIN"); stats(rB[rB[:,0]>=cut],"B band TEST")
