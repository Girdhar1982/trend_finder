import sys; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
d=pd.read_pickle("feat_H1.pkl")
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date())); DAYS=nd(d.time.iloc[0],d.time.iloc[-1])
def wilson(k,n,z=1.96):
    p=k/n; den=1+z*z/n; c=p+z*z/(2*n); m=z*np.sqrt(p*(1-p)/n+z*z/(4*n*n)); return (c-m)/den*100,(c+m)/den*100
base=dict(pull_bars=6,rsi_pull=50,rsi_floor=30,htf=True,use_pdhl=False,ob=1,max_day=5)
cands={"H1-A tp0.75 sl3 hold24 3-19 ATR>=15":dict(tp_atr=0.75,sl_atr=3.0,max_hold=24,h0=3,h1=19,min_atr_pips=15),
       "H1-B tp1.0 sl3 hold24 3-19 ATR>=15":dict(tp_atr=1.0,sl_atr=3.0,max_hold=24,h0=3,h1=19,min_atr_pips=15),
       "H1-C tp1.5 sl3 hold24 all-hrs ATR>=15":dict(tp_atr=1.5,sl_atr=3.0,max_hold=24,h0=0,h1=24,min_atr_pips=15)}
rng=np.random.default_rng(1)
for tag,ex in cands.items():
    print("=====",tag)
    for cp in (1.2,2.0,3.0):
        bt.COST_PIPS=cp; tr,_=bt.run(d,**{**base,**ex}); s=bt.stats(tr,DAYS)
        print(f" cost {cp}: n={s['n']} win={s['win']:.1f}% exp={s['exp']:+.2f} pf={s['pf']:.2f} net={s['net']:+.0f} maxDD={s['maxdd']:.0f} /day={s['perday']:.2f}")
    bt.COST_PIPS=1.2; tr,_=bt.run(d,**{**base,**ex}); tr['time']=pd.to_datetime(tr.time)
    lo,hi=wilson((tr.pnl>0).sum(),len(tr)); b=[rng.choice(tr.pnl.to_numpy(),len(tr)).mean() for _ in range(5000)]
    print(f" win CI {lo:.0f}-{hi:.0f}% avgW {tr.pnl[tr.pnl>0].mean():.1f} avgL {tr.pnl[tr.pnl<0].mean():.1f} worst {tr.pnl.min():.0f}; exp 95% CI [{np.percentile(b,2.5):+.1f},{np.percentile(b,97.5):+.1f}] pips; exits {tr.why.value_counts().to_dict()}")
    mx=cur=0
    for x in tr.pnl: cur=cur+1 if x<0 else 0; mx=max(mx,cur)
    print(" max losing streak",mx, "BUY",len(tr[tr.side==1]),round((tr[tr.side==1].pnl>0).mean()*100),"% SELL",len(tr[tr.side==-1]),round((tr[tr.side==-1].pnl>0).mean()*100),"%")
    for k,g in tr.groupby(tr.time.dt.year.astype(str)+"H"+((tr.time.dt.month>6)+1).astype(str)): print("  ",k,f"n={len(g):2d} win={(g.pnl>0).mean()*100:5.1f}% net={g.pnl.sum():+6.1f}")
