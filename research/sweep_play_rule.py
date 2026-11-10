import numpy as np, pandas as pd, datetime as dt
from stretch_core import S
ev=pd.read_pickle('sweep_size_events.pkl'); base=pd.read_pickle('sweep_size_base.pkl')
ev['st']=[S[s][k] for k,s in zip(ev.k,ev.s)]
days=(ev.t.max()-ev.t.min())/86400*5/7
def show(lab,d):
    o=[f"{lab:44s} /day={len(d)/days:4.2f}"]
    for hf in ('tr','te'):
        x=d[d.half==hf]; o.append(f"{hf}: n={len(x):3d} win={x.p10.mean()*100:3.0f}% avg={x.pnl.mean():+5.2f}p tot={x.pnl.sum():+5.0f}p")
    print("  ".join(o))
same=ev[ev['mode']=='same']
show("baseline any reversal bar",base)
for lo,hi in ((1,3),(0.5,3),(1,4),(1.5,3)):
    for st in (0.47,0.62,0.97):
        show(f"same-bar sweep {lo}-{hi}p & stretch>={st}",same[(same.depth_p>=lo)&(same.depth_p<hi)&(same.st>=st)])
print("\nDEEP sweeps (>=3p) when stretched>=0.62 (the 'avoid' group):")
show("deep >=3p & stretch>=0.62",same[(same.depth_p>=3)&(same.st>=0.62)])
r=same[(same.depth_p>=1)&(same.depth_p<3)&(same.st>=0.62)]
r=r.assign(dt=pd.to_datetime(r.t,unit='s'))
print("\nby month (rule: 1-3p, stretch>=0.62):"); print(r.groupby(r.dt.dt.to_period('M')).pnl.agg(n='size',avg='mean',tot='sum').round(1).T.to_string())
print("\nby side:"); print(r.groupby('s').agg(n=('pnl','size'),win=('p10','mean'),avg=('pnl','mean')).round(2).to_string())
print("\n5-6 Nov events (all sweeps, with stretch & depth):")
x=same.assign(dt=pd.to_datetime(same.t,unit='s')); x=x[x.dt>='2026-11-05']
print(x[['dt','s','level','depth_p','st','p10','pnl']].round(2).to_string(index=False))

print("\n=== chosen rule: same-bar sweep 0.5-3p & stretch>=0.62 ===")
r=same[(same.depth_p>=0.5)&(same.depth_p<3)&(same.st>=0.62)].assign(dt=lambda d:pd.to_datetime(d.t,unit='s'))
print(r.groupby(r.dt.dt.to_period('M')).agg(n=('pnl','size'),win=('p10','mean'),avg=('pnl','mean'),tot=('pnl','sum')).round(2).T.to_string())
print(r.groupby('s').agg(n=('pnl','size'),win=('p10','mean'),avg=('pnl','mean'),tot=('pnl','sum')).round(2).to_string())
print(r.groupby('level').agg(n=('pnl','size'),win=('p10','mean'),avg=('pnl','mean')).round(2).to_string())

print("\n=== split checks (train | test) ===")
base_r=same[(same.depth_p>=0.5)&(same.depth_p<3)&(same.st>=0.62)]
show("rule, 24h level (N288) only",base_r[base_r.level=='N288'])
show("rule, N24/N48/N96 levels",base_r[base_r.level!='N288'])
show("rule, shorts",base_r[base_r.s==-1]); show("rule, longs",base_r[base_r.s==1])
show("rule, 24h level, shorts",base_r[(base_r.level=='N288')&(base_r.s==-1)])
show("rule, 24h level, longs",base_r[(base_r.level=='N288')&(base_r.s==1)])
d288=same[same.level=='N288']
show("24h-level sweep 0.5-3p, ANY stretch",d288[(d288.depth_p>=0.5)&(d288.depth_p<3)])
show("24h-level sweep >=3p, ANY stretch",d288[d288.depth_p>=3])
