import numpy as np, pandas as pd
import sweep_dataset as sd
df = pd.read_pickle('sweep_dataset.pkl').sort_values('t').reset_index(drop=True)
df['big']=(df.mfe_r>=3).astype(int); df['dt']=pd.to_datetime(df.t,unit='s')
cut=int(len(df)*0.6); df['half']=np.where(df.index<cut,'tr','te'); days=df.dt.dt.date.nunique()
h,l,atr=sd.h,sd.l,sd.atr
trap=[]
for k,s in zip(df.k,df.sign):
    H,L=(h,l) if s>0 else (-l,-h)
    a=atr[k]; bh=H[k-36:k-12].max(); bl=L[k-36:k-12].min()
    trap.append(bool(H[k-12:k].max()>bh+0.3*a and L[k]<=bl+0.3*a))
df['trap']=trap
def show(name,m):
    s=df[m]; o_=[f"{name:22s} n={len(s):4d} /day={len(s)/days:4.2f}"]
    for hh in ('tr','te'):
        x=s[s.half==hh]; o_.append(f"{hh}: big={x.big.mean():.3f} r36={x.r36.mean():+.2f} n={len(x)}")
    print("  ".join(o_))
show("all",df.t>0); show("trap",df.trap); show("no trap",~df.trap)
cols=['trend48','trend288','dist_dayopen']; mu=df.iloc[:cut][cols].mean(); sdv=df.iloc[:cut][cols].std()
df['score']=-((df[cols]-mu)/sdv).mean(axis=1)
show("trap & scoreB+",df.trap&(df.score>=0.4686)); show("trap & scoreA",df.trap&(df.score>=0.9669))
show("scoreA",df.score>=0.9669); show("scoreB+",df.score>=0.4686)
m=df[(df.dt>='2026-11-05')]; print(m[m.trap][['dt','sign','kind','LB','score','mfe_pips']].round(2).to_string(index=False))
