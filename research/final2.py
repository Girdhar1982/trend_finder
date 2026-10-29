import sys; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
d=pd.read_pickle("feat_M15.pkl")
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
DAYS=nd(d.time.iloc[0],d.time.iloc[-1])
def wilson(k,n,z=1.96):
    p=k/n; den=1+z*z/n; c=p+z*z/(2*n); m=z*np.sqrt(p*(1-p)/n+z*z/(4*n*n)); return (c-m)/den*100,(c+m)/den*100
R=dict(rsi_pull=50,rsi_floor=40,pull_bars=4,min_atr_pips=6,htf=True,use_pdhl=True,h0=3,h1=19,ob=1)
for tag,ex in [("A tp1.0 sl3.0 hold32",dict(tp_atr=1.0,sl_atr=3.0,max_hold=32)),("B tp0.5 sl2.0 hold16 minATR9",dict(tp_atr=0.5,sl_atr=2.0,max_hold=16,min_atr_pips=9))]:
    print("=====",tag)
    for cp in (0.8,1.2,2.0,3.0):
        bt.COST_PIPS=cp; tr,_=bt.run(d,**{**R,**ex}); s=bt.stats(tr,DAYS)
        print(f" cost {cp}: n={s['n']} win={s['win']:.1f}% exp={s['exp']:+.2f} pf={s['pf']:.2f} net={s['net']:+.0f} maxDD={s['maxdd']:.0f} /day={s['perday']:.2f}")
    bt.COST_PIPS=1.2; tr,_=bt.run(d,**{**R,**ex}); tr['time']=pd.to_datetime(tr.time)
    lo,hi=wilson((tr.pnl>0).sum(),len(tr)); print(f" win CI {lo:.0f}-{hi:.0f}% avg win {tr.pnl[tr.pnl>0].mean():.1f} avg loss {tr.pnl[tr.pnl<0].mean():.1f} worst {tr.pnl.min():.1f}; exits {tr.why.value_counts().to_dict()}")
    print(" BUY",(tr[tr.side==1].pnl>0).mean().round(3),len(tr[tr.side==1]),"SELL",(tr[tr.side==-1].pnl>0).mean().round(3),len(tr[tr.side==-1]))
    mx=cur=0
    for x in tr.pnl: cur=cur+1 if x<0 else 0; mx=max(mx,cur)
    print(" max losing streak",mx)
    print(" by half-year:")
    for k,g in tr.groupby(tr.time.dt.year.astype(str)+"H"+((tr.time.dt.month>6)+1).astype(str)): print("  ",k,f"n={len(g):2d} win={(g.pnl>0).mean()*100:5.1f}% net={g.pnl.sum():+6.1f}")
    tr.to_csv("trades_hi_"+tag[0]+".csv",index=False)
