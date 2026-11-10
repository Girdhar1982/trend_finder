import numpy as np, pandas as pd
import sweep_dataset as sd
PIP=0.01; t,o,h,l,c,n=sd.t,sd.o,sd.h,sd.l,sd.c,sd.n
T=pd.read_pickle('my_trades_enriched.pkl')
def mae_path(r,incl_entry_bar):
    a=r.i if incl_entry_bar else r.i+1
    if r.xi<a: return 0.0
    seg=slice(a,r.xi+1)
    return (r.ep-l[seg].min())/PIP if r.dir>0 else (h[seg].max()-r.ep)/PIP
print(f"actual: total {T.pips.sum():+.0f}p  win {np.mean(T.pips>0)*100:.0f}%  worst {T.pips.min():.0f}p  avg {T.pips.mean():+.2f}p")
print("Counterfactual: hard stop at X pips from YOUR entry (same exits otherwise). lower/upper bound = how the entry bar's range is treated")
for X in (8,10,12,15,20,25,30):
    res=[]
    for inc in (False,True):
        p=[]
        for r in T.itertuples():
            m=mae_path(r,inc)
            p.append(-X-0.3 if m>=X else r.pips)   # 0.3p slippage when stopped
        p=np.array(p); res.append((p.sum(),np.mean(p>0)*100,p.min()))
    print(f" stop {X:2d}p: total {res[0][0]:+5.0f}..{res[1][0]:+5.0f}p  win {res[1][1]:.0f}-{res[0][1]:.0f}%  worst {res[0][2]:.0f}p")
# the combination: no more than N concurrent positions
print("\nCap on stacking: skip a trade if >=K positions already open")
for K in (1,2,3,4):
    keep=T[(T.conc-1)<K]; print(f" max {K} open: keeps {len(keep)} trades, total {keep.pips.sum():+.0f}p, worst {keep.pips.min():.0f}p")
