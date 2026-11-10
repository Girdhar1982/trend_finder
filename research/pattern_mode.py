import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from swing_recall import det_trap
from trend_range_sweep import fwd
t,n=sd.t,sd.n
ev=pd.read_pickle('trend_range_sweep.pkl').sort_values('i')
cut=int(n*0.6); dtr=(t[cut]-t[700])/86400*5/7; dte=(t[n-40]-t[cut])/86400*5/7
S_any=ev[(ev.depth>=0.7)&(ev.volx>=1.3)][['i','s']].assign(kind='sweep')
tr=pd.DataFrame([(i,s) for i,s in det_trap(12) if 700<=i<n-40],columns=['i','s']).assign(kind='trap60')
U=pd.concat([S_any,tr]).groupby(['i','s']).kind.apply(lambda x:'+'.join(sorted(set(x)))).reset_index()
U['w20']=[fwd(i,s) for i,s in zip(U.i,U.s)]
def rep(lab,d):
    a=d[d.i<cut]; b=d[d.i>=cut]
    print(f"{lab:40s} train {a.w20.mean()*100:4.1f}% ({len(a)/dtr:4.1f}/d)  test {b.w20.mean()*100:4.1f}% ({len(b)/dte:4.1f}/d)")
print("break-even 33%, random bars ~28-30%")
rep("deep sweep + volume, ANY trend",U[U.kind.str.contains('sweep')])
rep("1h trap (your 5/6 Nov pattern)",U[U.kind.str.contains('trap')])
rep("PATTERN MODE = either",U)
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%m-%d %H:%M')
print("\nyour examples:")
for want in ('11-05 07:20','11-06 09:40','11-06 19:40'):
    m=U[[tstr(i)==want for i in U.i]]
    print(f"  {want}: " + (f"{'BUY' if m.s.iloc[0]>0 else 'SELL'} {m.kind.iloc[0]} -> {'hit +20' if m.w20.iloc[0]==1 else 'no'}" if len(m) else "NOT included"))
x=U[(U.i>=np.searchsorted(t,dt.datetime(2026,11,5,tzinfo=dt.timezone.utc).timestamp()))]
print("\nall pattern-mode signals 5-6 Nov:"); [print(f"  {tstr(r.i)} {'BUY ' if r.s>0 else 'SELL'} {r.kind:13s} {'+20 first' if r.w20==1 else ('-10 first' if r.w20==0 else 'timeout')}") for r in x.itertuples()]
print("\nlast 10 PATTERN signals (for the log check):")
for r in U.tail(10).itertuples(): print(f"  {dt.datetime.fromtimestamp(t[r.i],dt.timezone.utc):%Y-%m-%d %H:%M} {'BUY ' if r.s>0 else 'SELL'} {r.kind}")
