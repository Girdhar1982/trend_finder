import sys; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
RULE=dict(tp_atr=1.5,sl_atr=2.0,rsi_pull=50,rsi_floor=40,pull_bars=4,min_atr_pips=6,htf=True,use_pdhl=True,h0=3,h1=19)
d=bt.features("M15","H1"); d.to_pickle("feat_M15.pkl")
print("bars touching bear OB %.1f%%, bull OB %.1f%%"%(d.ob_bear.mean()*100,d.ob_bull.mean()*100))
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
cut=d.time.iloc[int(len(d)*0.6)]
def L(tag,t):
    t=t.copy(); t['time']=pd.to_datetime(t.time)
    out=[]
    for nm,x,dy in (("all",t,nd(d.time.iloc[0],d.time.iloc[-1])),("train",t[t.time<cut],nd(d.time.iloc[0],cut)),("test",t[t.time>=cut],nd(cut,d.time.iloc[-1]))):
        s=bt.stats(x,dy); out.append(f"{nm}: n={s['n']:3d} win={s['win']:4.1f}% exp={s['exp']:+5.2f} /d={s['perday']:.2f}")
    print(f"{tag:22s}"+" | ".join(out))
for tag,kw in [("rulebook",{}),("rulebook + OB confl.",dict(ob=1)),("OB replaces BB-mid",dict(ob=2)),("OB repl, rsi 50/30",dict(ob=2,rsi_floor=30)),("OB confl, no pullback n",dict(ob=1,pull_bars=8))]:
    t,_=bt.run(d,**{**RULE,**kw}); L(tag,t)
