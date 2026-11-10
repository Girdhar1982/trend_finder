import numpy as np, pandas as pd
from stretch_core import S
ev=pd.read_pickle('sweep_size_events.pkl'); base=pd.read_pickle('sweep_size_base.pkl')
ev['st']=[S[s][k] for k,s in zip(ev.k,ev.s)]
def line(name,d):
    o=[f"{name:34s}"]
    for hf in ('tr','te'):
        x=d[d.half==hf]; o.append(f"{hf}: n={len(x):4d} +10/-10={x.p10.mean()*100 if len(x) else 0:3.0f}% pnl={x.pnl.mean() if len(x) else 0:+5.2f}p")
    return "  ".join(o)
print(line("baseline any reversal bar",base))
for st_lo,lab in ((-99,'any stretch'),(0.62,'stretch>=0.62 (q90)'),(1.03,'stretch>=1.03 (q95)'),(1.53,'stretch>=1.53 (q98)')):
    print(f"\n{lab}:")
    e=ev[ev.st>=st_lo]
    for a,b in ((0,1),(1,3),(3,100)):
        print(line(f"  sweep {a}-{b} pips",e[(e.depth_p>=a)&(e.depth_p<b)]))
    print(line("  all sweeps",e))
