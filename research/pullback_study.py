"""Trend-continuation pullback detector (BUY; SELL mirror). Causal. Test: +20 before -10 within 36 bars, fill next open+spread."""
import numpy as np, pandas as pd, datetime as dt, itertools
import sweep_dataset as sd
from swing_recall import pivots_lows
PIP=0.01; o,h,l,c,sp,atr,n,t,v=sd.o,sd.h,sd.l,sd.c,sd.sp,sd.atr,sd.n,sd.t,sd.v
e288=sd.ema288; e48=sd.ema48
e20=pd.Series(c).ewm(span=20,adjust=False).mean().values
vavg=pd.Series(v).rolling(20).mean().values
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%m-%d %H:%M')
def fwd(i,s,up=20,dn=10,H=36):
    O,Hh,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); ent=O[i+1]+sp[i+1]
    for j in range(i+1,i+H+1):
        if L[j]<=ent-dn*PIP: return 0.0
        if Hh[j]>=ent+up*PIP: return 1.0
    return 0.5 if C[i+H]>ent else 0.0
def detect(zone='ema48', depth=0.0, look=6, trig='prevhigh', hl=True, gap=6, slope_min=0.0):
    out=[]
    for s in (1,-1):
        O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c); E288=s*e288; E48=s*e48; E20=s*e20
        pl=pivots_lows(L,3); k=0; lastpl=None; last=-99
        for i in range(700,n-40):
            while k<len(pl) and pl[k]+3<=i-1: lastpl=L[pl[k]]; k+=1
            if i-last<gap: continue
            a=atr[i]
            if not (C[i]>E288[i] and (E288[i]-E288[i-36])/a>slope_min): continue
            lo=L[i-look+1:i+1].min()
            if zone=='ema48': ok=lo<=E48[i]+depth*a
            elif zone=='ema20': ok=lo<=E20[i]+depth*a
            else: ok=(H[i-24:i+1].max()-lo)>=depth*a          # retrace from 2h high
            if not ok: continue
            if hl and lastpl is not None and lo<=lastpl: continue   # must be a HIGHER low
            if trig=='prevhigh' and not (C[i]>H[i-1] and C[i]>O[i]): continue
            if trig=='bull' and not (C[i]>O[i]): continue
            out.append((i,s)); last=i
    return out
cut=int(n*0.6); dtr=(t[cut]-t[700])/86400*5/7; dte=(t[-40]-t[cut])/86400*5/7
rng=np.random.default_rng(0)
# baseline: random with-trend bars
bw=[]
for i in rng.integers(800,n-40,30000):
    s=1 if rng.random()<0.5 else -1
    if s*(c[i]-e288[i])>0 and s*(e288[i]-e288[i-36])>0: bw.append((i,s,fwd(i,s)))
bw=np.array(bw); print(f"baseline random WITH-trend bars: train {bw[bw[:,0]<cut][:,2].mean()*100:.1f}%  test {bw[bw[:,0]>=cut][:,2].mean()*100:.1f}%   (break-even 33%)\n")
rows=[]
for zone,depth,trig,hl,slope in itertools.product(('ema20','ema48','retrace'),(0.0,0.5,1.0,2.0),('prevhigh','bull'),(True,False),(0.0,0.5)):
    if zone=='retrace' and depth<1: continue
    sig=detect(zone,depth if zone!='retrace' else depth*1.5,6,trig,hl,6,slope)
    r=np.array([(i,fwd(i,s)) for i,s in sig])
    if len(r)==0: continue
    a=r[r[:,0]<cut][:,1]; b=r[r[:,0]>=cut][:,1]
    rows.append(dict(zone=zone,depth=depth,trig=trig,higher_low=hl,slope=slope,per_day=round(len(b)/dte,1),train=round(a.mean()*100,1),test=round(b.mean()*100,1)))
R=pd.DataFrame(rows)
print("top 10 by TRAIN (judge on TEST):"); print(R.sort_values('train',ascending=False).head(10).to_string(index=False))
print("\ncombos above 30% in BOTH halves:", int(((R.train>=30)&(R.test>=30)).sum()), "of", len(R))
print(R[(R.train>=30)&(R.test>=30)].sort_values('test',ascending=False).head(8).to_string(index=False))
R.to_pickle('pullback_grid.pkl')
