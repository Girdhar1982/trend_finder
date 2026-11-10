import numpy as np, pandas as pd, datetime as dt, warnings; warnings.filterwarnings('ignore')
import sweep_dataset as sd
PIP=0.01
t,o,h,l,c,v,sp,atr,n,hour=sd.t,sd.o,sd.h,sd.l,sd.c,sd.v,sd.sp,sd.atr,sd.n,sd.hour
T=pd.read_pickle('my_trades.pkl'); cand=pd.read_pickle('sweep_dataset.pkl')
print(f"{len(T)} trades {T.et.min().date()}..{T.et.max().date()}  longs={int((T.dir==1).sum())} shorts={int((T.dir==-1).sum())}")
w=T[T.pips>0]; ls=T[T.pips<=0]
print(f"win rate {len(w)/len(T)*100:.0f}%  total {T.pips.sum():+.0f} pips / ${T.net.sum():+.2f}  avg win {w.pips.mean():+.1f}p  avg loss {ls.pips.mean():+.1f}p  expectancy {T.pips.mean():+.2f}p  profit factor {w.pips.sum()/-ls.pips.sum():.2f}")
print(f"median hold {T.hold_min.median():.0f} min | wins {w.hold_min.median():.0f} min | losses {ls.hold_min.median():.0f} min")
print(f"worst 5 trades pips: {sorted(T.pips)[:5]}  best 5: {sorted(T.pips)[-5:]}")
T['day']=T.et.dt.date
dd=T.groupby('day').agg(n=('pips','size'),pips=('pips','sum'),net=('net','sum'),worst=('pips','min'),maxopen=('pips','size'))
print("\nper day (pips):"); print(dd[['n','pips','net','worst']].round(1).T.to_string())
# concurrent positions at entry (stacking)
conc=[int(((T.et<=r.et)&(T.xt>r.et)).sum())-1+1 for r in T.itertuples()]  # incl. itself
T['conc']=conc
print("\nstacking: positions already open at entry ->", T.groupby(pd.cut(T.conc-1,[-1,0,1,3,100],labels=['0','1','2-3','4+'])).agg(n=('pips','size'),avg=('pips','mean'),tot=('pips','sum')).round(1).to_string())
# path stats from M5 bars
mae=[];mfe=[];fwd12=[];fwd36=[];after=[];stretch=[];tr288=[];volx=[];hr=[];dist_open=[]
vavg=pd.Series(v).rolling(20).mean().values
for r in T.itertuples():
    i,xi,s=r.i,r.xi,r.dir
    seg=slice(i,xi+1)
    mae.append(max(0,(r.ep-l[seg].min())/PIP) if s>0 else max(0,(h[seg].max()-r.ep)/PIP))
    mfe.append(max(0,(h[seg].max()-r.ep)/PIP) if s>0 else max(0,(r.ep-l[seg].min())/PIP))
    fwd12.append(s*(c[min(n-1,i+12)]-r.ep)/PIP); fwd36.append(s*(c[min(n-1,i+36)]-r.ep)/PIP)
    k=min(n-1,xi+36); after.append((h[xi:k+1].max()-r.xp)/PIP if s>0 else (r.xp-l[xi:k+1].min())/PIP)   # extra move after exit (3h)
    j=i-1; a=atr[j]
    st=[(s*(c[j]-sd.ema48[j])/a),(s*(c[j]-sd.ema288[j])/a),(s*(c[j]-sd.day_open[j])/a)]
    stretch.append(-np.mean([(st[0]+1.5648)/1.3383,(st[1]+1.9859)/5.7488,(st[2]+2.6434)/9.3744])); volx.append(v[j]/vavg[j]); hr.append(hour[i]); tr288.append(st[1])
T['mae']=mae;T['mfe']=mfe;T['fwd12']=fwd12;T['fwd36']=fwd36;T['after']=after;T['stretch']=stretch;T['volx']=volx;T['hr']=hr;T['tr288']=tr288
T['capture']=np.where(T.mfe>1,T.pips/T.mfe,np.nan)
print(f"\nENTRY: median drawdown after entry (MAE) {T.mae.median():.1f}p, wins {T[T.pips>0].mae.median():.1f}p, losses {T[T.pips<=0].mae.median():.1f}p")
print(f"EXIT : median best-available (MFE) {T.mfe.median():.1f}p vs realised {T.pips.median():.1f}p; avg capture of MFE {T.capture.mean()*100:.0f}%")
print(f"       winners: extra pips available in the 3h after you closed: median {T[T.pips>0].after.median():.1f}p, mean {T[T.pips>0].after.mean():.1f}p")
print(f"       losers : MFE before they turned (median {T[T.pips<=0].mfe.median():.1f}p) - {int((T[T.pips<=0].mfe>=10).sum())} of {len(T[T.pips<=0])} losers were 10+p in profit at some point")
print(f"TIMING: your entries' average forward move (signed) after 12 bars {T.fwd12.mean():+.2f}p, 36 bars {T.fwd36.mean():+.2f}p")
# baseline: random bars same direction mix and hours
rng=np.random.default_rng(1); b12=[];b36=[]
for _ in range(20):
    idx=rng.choice(np.arange(650,n-40),len(T)); sg=T.dir.values
    b12.append(np.mean(sg*(c[idx+12]-c[idx])/PIP)); b36.append(np.mean(sg*(c[idx+36]-c[idx])/PIP))
print(f"        random bars, same long/short mix: 12 bars {np.mean(b12):+.2f}p, 36 bars {np.mean(b36):+.2f}p (sd of mean {np.std(b36):.2f}) -> is your timing better than random?")
# exit counterfactuals on YOUR entries (entry price = your fill)
def cf(stop_atr,trail_atr,cap=144):
    out=[]
    for r in T.itertuples():
        s=r.dir; O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); a=atr[r.i-1]; ent=s*r.ep; stop=ent-stop_atr*a; hh=ent; res=None
        for j in range(r.i+1,min(n-1,r.i+cap)+1):
            if L[j]<=stop: res=min(stop,O[j])-ent; break
            hh=max(hh,H[j]); stop=max(stop,hh-trail_atr*atr[j])
        if res is None: res=C[min(n-1,r.i+cap)]-ent
        out.append(res/PIP)
    return np.array(out)
print("\nCOUNTERFACTUAL exits on your own entries (pips total / win pct / worst):  yours = %+.0f / %.0f%% / %.0f"%(T.pips.sum(),(T.pips>0).mean()*100,T.pips.min()))
for sa,ta in ((1.5,3),(2,3),(3,3),(3,4),(4,4)):
    p=cf(sa,ta); print(f"  stop {sa} ATR, trail {ta} ATR: {p.sum():+7.0f} / {np.mean(p>0)*100:3.0f}% / {p.min():+.0f}")
# selection: are your entries near sweep/retest candidates, and do those do better?
ck=cand.groupby('sign').k.apply(lambda x:np.array(sorted(x))).to_dict()
near=[]
for r in T.itertuples():
    ks=ck.get(r.dir,np.array([])); near.append(bool(((ks>=r.i-6)&(ks<=r.i+1)).any()))
T['near']=near
print(f"\nSELECTION: {T.near.mean()*100:.0f}% of your entries came within 6 bars after a same-direction sweep/retest candidate"
      f" (candidates fire ~22/day so random chance is ~{ (1-(1-6/288)**11)*100:.0f}%)")
for nm,m in (("near candidate",T.near),("not near",~T.near)):
    x=T[m]; print(f"  {nm:15s} n={len(x):3d} win={np.mean(x.pips>0)*100:3.0f}% total={x.pips.sum():+6.0f}p avg={x.pips.mean():+5.2f}p")
print("\nWINNERS vs LOSERS at entry (medians):")
g=T.assign(res=np.where(T.pips>0,'win','loss')).groupby('res').agg(n=('pips','size'),stretch=('stretch','median'),tr288=('tr288','median'),volx=('volx','median'),fwd12=('fwd12','median'),mae=('mae','median'),hold=('hold_min','median'))
print(g.round(2).to_string())
print("\nby hour block (server): n, win%, total pips")
T['blk']=pd.cut(T.hr,[-1,6,9,12,15,19,23],labels=['0-6','7-9','10-12','13-15','16-19','20-23'])
print(T.groupby('blk').agg(n=('pips','size'),win=('pips',lambda s:(s>0).mean()*100),tot=('pips','sum')).round(0).T.to_string())
print("\nby stretch tercile:"); T['st3']=pd.qcut(T.stretch,3,labels=['low','mid','high'])
print(T.groupby('st3').agg(n=('pips','size'),win=('pips',lambda s:(s>0).mean()*100),avg=('pips','mean'),tot=('pips','sum')).round(1).T.to_string())
print("\nby direction:"); print(T.groupby('dir').agg(n=('pips','size'),win=('pips',lambda s:(s>0).mean()*100),avg=('pips','mean'),tot=('pips','sum')).round(1).to_string())
T.to_pickle('my_trades_enriched.pkl')
