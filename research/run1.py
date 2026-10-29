import sys; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
d=bt.features("M15","H1")
print(len(d), d.time.iloc[0], d.time.iloc[-1], d.hdir.value_counts().to_dict(), d.hdir_htf.value_counts(dropna=False).to_dict())
cut=d.time.iloc[int(len(d)*0.6)]
print("split",cut)
tr,p=bt.run(d)
tr['time']=pd.to_datetime(tr.time)
def rep(tag,t,days):
    s=bt.stats(t,days); print(f"{tag:10s} n={s['n']:4d} win={s['win']:.1f}% exp={s['exp']:+.2f}p pf={s['pf']:.2f} net={s['net']:+.0f}p perday={s['perday']:.2f} maxdd={s['maxdd']:.0f}")
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
rep("ALL",tr,nd(d.time.iloc[0],d.time.iloc[-1]))
rep("TRAIN",tr[tr.time<cut],nd(d.time.iloc[0],cut))
rep("TEST",tr[tr.time>=cut],nd(cut,d.time.iloc[-1]))
print(tr.why.value_counts().to_dict())
