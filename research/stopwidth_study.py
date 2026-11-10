import numpy as np, pandas as pd
import sweep_dataset as sd
PIP=0.01; CAP=144
o,h,l,c,sp,atr,n=sd.o,sd.h,sd.l,sd.c,sd.sp,sd.atr,sd.n
df=pd.read_pickle('selection_dataset.pkl')
cut=int(len(df)*0.6)
def sim(k,s,stop_atr,trail_atr):
    O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c)
    a=atr[k]; ent=O[k+1]+sp[k+1]; stop=ent-stop_atr*a; hh=ent
    for j in range(k+1,min(n-1,k+CAP)+1):
        if L[j]<=stop: return (min(stop,O[j])-ent)/PIP
        hh=max(hh,H[j]); stop=max(stop,hh-trail_atr*atr[j])
    j=min(n-1,k+CAP); return (C[j]-ent)/PIP
res={}
for sa in (1.5,2.0,3.0):
    for ta in (3.0,4.0):
        res[(sa,ta)]=np.array([sim(k,s,sa,ta) for k,s in zip(df.k,df.sign)])
sel={"ALL":np.ones(len(df),bool),"tier A":(df.tier==1).values,"tier A+B":(df.tier<=2).values,"counter-trend":df.counter.values}
print("avg pips per trade [train | test]   (stop ATR, trail ATR) ; stop sizes ~", (1.5*df.atr_pips.median()).round(0),"/",(2*df.atr_pips.median()).round(0),"/",(3*df.atr_pips.median()).round(0),"pips")
for key,p in res.items():
    out=[]
    for nm,m in sel.items():
        a=p[:cut][m[:cut]]; b=p[cut:][m[cut:]]
        out.append(f"{nm}: {a.mean():+5.1f}|{b.mean():+5.1f} (win {np.mean(a>0)*100:2.0f}/{np.mean(b>0)*100:2.0f}%)")
    print(f"stop {key[0]} trail {key[1]}: "+"  ".join(out))
