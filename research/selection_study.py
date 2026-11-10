"""Which candidates to take? Outcome = indicator's real exit (next-open fill, structural stop, 3 ATR trail, 144-bar cap).
Slices judged on train (first 60%) vs test (last 40%); only slices positive in BOTH with n>=60 each are interesting."""
import numpy as np, pandas as pd
import sweep_dataset as sd
PIP=0.01; TRAIL=3.0; CAP=144
o,h,l,c,sp,atr,n=sd.o,sd.h,sd.l,sd.c,sd.sp,sd.atr,sd.n
df=pd.read_pickle('sweep_dataset.pkl').sort_values('t').reset_index(drop=True)
pips=[];held=[]
for k,s,rk in zip(df.k,df.sign,df.risk_atr):
    O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c)
    a=atr[k]; risk=rk*a; stop=C[k]-risk; ent=O[k+1]+sp[k+1]; hh=C[k]; res=None
    if ent<=stop: pips.append(0.0); held.append(0); continue
    for j in range(k+1,min(n-1,k+CAP)+1):
        if L[j]<=stop: res=min(stop,O[j])-ent; break
        hh=max(hh,H[j]); stop=max(stop,hh-TRAIL*atr[j])
    if res is None: j=min(n-1,k+CAP); res=C[j]-ent
    pips.append(res/PIP); held.append(j-k)
df['pips']=pips; df['held']=held; df['risk_p']=df.risk_atr*df.atr_pips; df['R']=df.pips/df.risk_p
df['dt']=pd.to_datetime(df.t,unit='s'); cut=int(len(df)*0.6); df['half']=np.where(df.index<cut,'tr','te')
cols=['trend48','trend288','dist_dayopen']; mu=df.iloc[:cut][cols].mean(); sdv=df.iloc[:cut][cols].std()
df['score']=-((df[cols]-mu)/sdv).mean(axis=1)
df['tier']=np.where(df.score>=0.9669,1,np.where(df.score>=0.4686,2,3))
# prior same-direction attempts in the previous 36 bars (clustered failures), and with-trend flags
prior=[]
ks=df.k.values; ss=df.sign.values
for idx,(k,s) in enumerate(zip(ks,ss)):
    m=(ss==s)&(ks<k)&(ks>=k-36); prior.append(int(m.sum()))
df['prior']=prior
df['with_trend']=(df.trend288>0)&(df.slope288>0)      # price above rising EMA288 in trade direction
df['counter']=(df.trend288<0)&(df.slope288<0)
days=df.dt.dt.date.nunique()
def row(name,m):
    s=df[m]; a=s[s.half=='tr']; b=s[s.half=='te']
    f=lambda x: f"n={len(x):4d} avg={x.pips.mean():+5.1f}p win={np.mean(x.pips>0)*100:3.0f}%" if len(x) else "n=0"
    flag='  <== both+' if len(a)>=60 and len(b)>=60 and a.pips.mean()>0 and b.pips.mean()>0 else ''
    print(f"{name:28s} /day={len(s)/days:4.1f} | train {f(a)} | test {f(b)}{flag}")
row("ALL",df.t>0)
for t_ in (1,2,3): row(f"tier {'ABC'[t_-1]}",df.tier==t_)
row("tier A+B",df.tier<=2)
row("sweep",df.kind=='sweep'); row("retest",df.kind=='retest')
row("with trend (EMA288 rising)",df.with_trend); row("counter-trend",df.counter)
row("longs",df.sign==1); row("shorts",df.sign==-1)
for nm,a_,b_ in (("Asia 0-7",0,7),("pre-London 7-10",7,10),("London 10-15",10,15),("NY 15-20",15,20),("late 20-24",20,24)):
    row(f"hours {nm}",df.hour.between(a_,b_-1))
row("prior attempts 0",df.prior==0); row("prior attempts 1-2",df.prior.between(1,2)); row("prior attempts 3+",df.prior>=3)
row("volx>=1.3",df.volx>=1.3); row("depth>=0.3 sweep",(df.kind=='sweep')&(df.depth>=0.3))
row("touches>=3",df.touches>=3); row("risk<=0.9 ATR (tight stop)",df.risk_atr<=0.9)
row("A+B & with trend",(df.tier<=2)&df.with_trend); row("A+B & counter",(df.tier<=2)&df.counter)
row("A+B & prior>=1",(df.tier<=2)&(df.prior>=1)); row("A+B & London 10-15",(df.tier<=2)&df.hour.between(10,14))
print("\nR-multiple view (pips / structural stop pips), all candidates: mean R train/test:",
      df[df.half=='tr'].R.mean().round(3), df[df.half=='te'].R.mean().round(3))
print("typical stop size (pips) median:",df.risk_p.median().round(1),"  median hold bars:",df.held.median())
df.to_pickle('selection_dataset.pkl')
