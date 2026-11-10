import numpy as np, pandas as pd
import sweep_dataset as sd
T=pd.read_pickle('my_trades_enriched.pkl')
bins=[-99,0,0.62,1.03,1.53,99]; lab=['<0 (not stretched)','0-0.62 (<q90)','0.62-1.03 (q90-95)','1.03-1.53 (q95-98)','>=1.53 (q98+)']
T['b']=pd.cut(T.stretch,bins,labels=lab)
g=T.groupby('b').agg(n=('pips','size'),win=('pips',lambda s:(s>0).mean()*100),avg=('pips','mean'),tot=('pips','sum'),worst=('pips','min'),medhold=('hold_min','median')).round(1)
print(g.to_string())
print("\nstretch percentiles of your entries:",T.stretch.quantile([.1,.25,.5,.75,.9,.99]).round(2).to_dict())
for a,b,lab_ in (("2026-11-05 07:00","2026-11-05 08:00","5 Nov"),("2026-11-06 09:10","2026-11-06 09:40","6 Nov")):
    x=T[(T.et>=a)&(T.et<=b)]; print(lab_, x[['et','dir','ep','pips','stretch']].round(2).to_string(index=False))
print("\ntop 10 trades by loss:"); print(T.nsmallest(8,'pips')[['et','dir','volume','pips','hold_min','mae','stretch','conc']].round(1).to_string(index=False))
print("\nlosses >=15 pips: n=",int((T.pips<=-15).sum())," total",round(T[T.pips<=-15].pips.sum()),"pips  vs all other trades total",round(T[T.pips>-15].pips.sum()))
