"""With-trend range sweep & reclaim (user's core pattern without the 'push' step). BUY; SELL mirror. Causal.
RANGE: last BOX bars before the sweep bar, width <= WMAX ATR.  SWEEP: bar low goes below range low by >= DEPTH ATR.
RECLAIM: that bar or one of the next RECL bars closes back above the range low (bullish).  TREND: price above rising EMA288.
Test: +20 before -10 pips within 36 bars from next open + spread."""
import numpy as np, pandas as pd, datetime as dt, itertools, sys
import sweep_dataset as sd
PIP=0.01; o,h,l,c,sp,atr,n,t,v=sd.o,sd.h,sd.l,sd.c,sd.sp,sd.atr,sd.n,sd.t,sd.v; e288=sd.ema288
vavg=pd.Series(v).rolling(20).mean().values
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%m-%d %H:%M')
def fwd(i,s,up=20,dn=10,H=36):
    O,Hh,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); ent=O[i+1]+sp[i+1]
    for j in range(i+1,i+H+1):
        if L[j]<=ent-dn*PIP: return 0.0
        if Hh[j]>=ent+up*PIP: return 1.0
    return 0.5 if C[i+H]>ent else 0.0
def detect(BOX=12,WMAX=5.0,RECL=2,trend='with',gap=6):
    out=[]
    for s in (1,-1):
        O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); E=s*e288; last=-99; pend=None
        for i in range(700,n-40):
            a=atr[i]
            # 1) pending sweep waiting for reclaim
            if pend is not None:
                k0,bot,dep,box_w=pend
                if i-k0>RECL: pend=None
                elif C[i]>bot and C[i]>O[i] and i-last>=gap:
                    up=(C[i]-E[i])/a; sl=(E[i]-E[i-36])/a
                    ctx=1 if (up>0 and sl>0) else (-1 if (up<0 and sl<0) else 0)
                    out.append(dict(i=i,s=s,depth=dep,ctx=ctx,volx=max(v[k0],v[i])/vavg[i],box_w=box_w,same=(i==k0)))
                    last=i; pend=None; continue
            # 2) new sweep on this bar?
            top=H[i-BOX:i].max(); bot=L[i-BOX:i].min(); w=(top-bot)/atr[i-1]
            if w<=WMAX and L[i]<bot:
                pend=(i,bot,(bot-L[i])/a,w)
                if C[i]>bot and C[i]>O[i] and i-last>=gap:     # reclaimed on the same bar
                    up=(C[i]-E[i])/a; sl=(E[i]-E[i-36])/a
                    ctx=1 if (up>0 and sl>0) else (-1 if (up<0 and sl<0) else 0)
                    out.append(dict(i=i,s=s,depth=(bot-L[i])/a,ctx=ctx,volx=v[i]/vavg[i],box_w=w,same=True)); last=i; pend=None
    return pd.DataFrame(out)
cut=int(n*0.6)
ev=detect()
ev['w20']=[fwd(i,s) for i,s in zip(ev.i,ev.s)]
ev['half']=np.where(ev.i<cut,'tr','te')
dtr=(t[cut]-t[700])/86400*5/7; dte=(t[n-40]-t[cut])/86400*5/7
def rep(lab,m):
    a=ev[m&(ev.half=='tr')]; b=ev[m&(ev.half=='te')]
    print(f"{lab:44s} train {a.w20.mean()*100:4.1f}% (n={len(a):4d})  test {b.w20.mean()*100:4.1f}% (n={len(b):4d}, {len(b)/dte:4.1f}/d)")
print("random with-trend bars: ~26.7%   break-even 33%\n")
rep("all range sweeps",ev.i>0)
for nm,cx in (("WITH trend",1),("mixed",0),("AGAINST trend",-1)): rep(f"  {nm}",ev.ctx==cx)
W=ev.ctx==1
print("\nWITH trend, by sweep depth (ATR beyond the range edge):")
for lo,hi in ((0,0.3),(0.3,0.7),(0.7,1.5),(1.5,3),(3,99)): rep(f"  depth {lo}-{hi} ATR",W&(ev.depth>=lo)&(ev.depth<hi))
print("\nWITH trend, by volume on the sweep/reclaim:")
for lo,hi in ((0,1),(1,1.3),(1.3,99)): rep(f"  vol {lo}-{hi}x",W&(ev.volx>=lo)&(ev.volx<hi))
rep("WITH trend, depth>=0.7 & vol>=1.3",W&(ev.depth>=0.7)&(ev.volx>=1.3))
rep("WITH trend, reclaimed same bar",W&ev.same); rep("WITH trend, reclaimed next bars",W&~ev.same)
x=ev[(ev.i>=np.searchsorted(t,dt.datetime(2026,11,6,18,tzinfo=dt.timezone.utc).timestamp()))&(ev.i<np.searchsorted(t,dt.datetime(2026,11,6,21,tzinfo=dt.timezone.utc).timestamp()))]
print("\n6 Nov 18:00-21:00:"); [print(f"  {tstr(r.i)} {'BUY ' if r.s>0 else 'SELL'} depth {r.depth:.2f} ATR ctx {r.ctx} vol {r.volx:.2f} -> {r.w20}") for r in x.itertuples()]
ev.to_pickle('trend_range_sweep.pkl')
