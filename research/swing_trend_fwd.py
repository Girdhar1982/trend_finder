import numpy as np, pandas as pd
import sweep_dataset as sd
PIP=0.01; o,h,l,c,sp,atr,n,t=sd.o,sd.h,sd.l,sd.c,sd.sp,sd.atr,sd.n,sd.t
df=pd.read_pickle('swing_candidates.pkl'); e288=sd.ema288; e48=sd.ema48
cut_i=df.i.iloc[int(len(df)*0.6)]
def fwd(i,s,up=20,dn=10,H=36):
    if i+H+1>=n: return np.nan
    O,Hh,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); ent=O[i+1]+sp[i+1]
    for j in range(i+1,i+H+1):
        if L[j]<=ent-dn*PIP: return 0.0
        if Hh[j]>=ent+up*PIP: return 1.0
    return 0.5 if C[i+H]>ent else 0.0
df['w20']=[fwd(i,s) for i,s in zip(df.i,df.s)]
df['up288']=[s*(c[i]-e288[i])/atr[i] for i,s in zip(df.i,df.s)]
df['sl288']=[s*(e288[i]-e288[i-36])/atr[i] for i,s in zip(df.i,df.s)]
df['pb48']=[-s*(c[i]-e48[i])/atr[i] for i,s in zip(df.i,df.s)]
W=(df.up288>0)&(df.sl288>0); AG=(df.up288<0)&(df.sl288<0)
rng=np.random.default_rng(0); idx=rng.integers(800,n-40,20000); ss=rng.choice([1,-1],20000)
base=np.array([fwd(i,s) for i,s in zip(idx,ss)]); bh=idx<cut_i
bW=np.array([(s*(c[i]-e288[i])>0) and (s*(e288[i]-e288[i-36])>0) for i,s in zip(idx,ss)])
print(f"baseline random bars       +20 before -10: train {np.nanmean(base[bh])*100:4.1f}%  test {np.nanmean(base[~bh])*100:4.1f}%   (break-even = 33%)")
print(f"baseline random WITH trend                 train {np.nanmean(base[bh&bW])*100:4.1f}%  test {np.nanmean(base[~bh&bW])*100:4.1f}%")
def rep(lab,m):
    a=df[m&(df.i<cut_i)]; b=df[m&(df.i>=cut_i)]
    dtr=(t[cut_i]-t[700])/86400*5/7; dte=(t[-1]-t[cut_i])/86400*5/7
    print(f"{lab:46s} train {a.w20.mean()*100:4.1f}% ({len(a)/dtr:4.1f}/d)  test {b.w20.mean()*100:4.1f}% ({len(b)/dte:4.1f}/d)")
rep("all candidates",df.i>0)
rep("current A (counter-trend stretch)",(df.stretch>=0)&(df.volx>=1))
rep("with-trend candidates",W)
rep("against-trend candidates",AG)
for lo,hi in ((-99,0),(0,1),(1,99)):
    rep(f"with trend, pullback pb48 [{lo},{hi})",W&(df.pb48>=lo)&(df.pb48<hi))
rep("with trend, pb48>=0 & vol>=1",W&(df.pb48>=0)&(df.volx>=1))
rep("with trend, pb48>=1 & vol>=1",W&(df.pb48>=1)&(df.volx>=1))
rep("with trend, pb48>=0.5 & vol>=1",W&(df.pb48>=0.5)&(df.volx>=1))
for k in ('sweep','retest','choch','trap30','trap60'):
    rep(f"with trend & {k}",W&(df[f'is_{k}']==1))
df.to_pickle('swing_candidates_fwd.pkl')
