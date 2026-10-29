import sys; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
RULE=dict(tp_atr=1.5,sl_atr=2.0,rsi_pull=50,rsi_floor=40,pull_bars=4,min_atr_pips=6,htf=True,use_pdhl=True,h0=3,h1=19)
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
def line(tag,t,days):
    s=bt.stats(t,days); return f"{tag:14s} n={s['n']:4d} win={s['win']:5.1f}% exp={s['exp']:+5.2f}p pf={s['pf']:.2f} net={s['net']:+6.0f}p /day={s['perday']:.2f} maxDD={s['maxdd']:.0f}p"
def wilson(k,n,z=1.96):
    p=k/n; den=1+z*z/n; c=p+z*z/(2*n); m=z*np.sqrt(p*(1-p)/n+z*z/(4*n*n)); return (c-m)/den*100,(c+m)/den*100
for tf in ("M15","M5"):
    d=bt.features(tf,"H1"); print("=====",tf,d.time.iloc[0].date(),"->",d.time.iloc[-1].date())
    tr,p=bt.run(d,**RULE); tr['time']=pd.to_datetime(tr.time)
    print(line("ALL",tr,nd(d.time.iloc[0],d.time.iloc[-1])))
    lo,hi=wilson((tr.pnl>0).sum(),len(tr)); print(f"win-rate 95% CI {lo:.0f}-{hi:.0f}%  avg win {tr.pnl[tr.pnl>0].mean():.1f}p avg loss {tr.pnl[tr.pnl<0].mean():.1f}p  exits {tr.why.value_counts().to_dict()}")
    print(line("BUY",tr[tr.side==1],nd(d.time.iloc[0],d.time.iloc[-1]))); print(line("SELL",tr[tr.side==-1],nd(d.time.iloc[0],d.time.iloc[-1])))
    q=tr.groupby(tr.time.dt.to_period("Q"))
    print("by quarter:"); 
    for k,g in q: print("  ",k,f"n={len(g):3d} win={(g.pnl>0).mean()*100:5.1f}% net={g.pnl.sum():+6.0f}p")
    mx=0;cur=0
    for x in tr.pnl:
        cur=cur+1 if x<0 else 0; mx=max(mx,cur)
    print("max losing streak",mx,"| worst day",tr.groupby('day').pnl.sum().min().round(1),"p | max trades in a day",tr.groupby('day').size().max())
    for cp in (0.8,1.2,2.0,3.0):
        bt.COST_PIPS=cp; t2,_=bt.run(d,**RULE); print(f"  cost {cp}p ->",line("",t2,nd(d.time.iloc[0],d.time.iloc[-1])))
    bt.COST_PIPS=1.2
    print("ablation (remove one rule, test+train all data):")
    for name,ch in [("no H1 Hull",dict(htf=False)),("no PDH/PDL room",dict(use_pdhl=False)),("all hours",dict(h0=0,h1=24)),("rsi floor 30",dict(rsi_floor=30)),("sl1.5 tp1.0",dict(sl_atr=1.5,tp_atr=1.0))]:
        t2,_=bt.run(d,**{**RULE,**ch}); print("  ",line(name,t2,nd(d.time.iloc[0],d.time.iloc[-1])))
    if tf=="M15":
        tr.to_csv("trades_M15.csv",index=False)
