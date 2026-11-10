"""Causal bar-by-bar replay of the Sweep_Reclaim_Alert rules. At bar i only data <= i is used for decisions.
Fill = open of bar i+1 (+ spread). Stop = structural (from the signal bar). Exit = 3 ATR chandelier trail, 144-bar cap."""
import sys, datetime as dt, numpy as np
import sweep_dataset as sd
o,h,l,c,v,sp,atr,t,n = sd.o,sd.h,sd.l,sd.c,sd.v,sd.sp,sd.atr,sd.t,sd.n
e48,e288,dop = sd.ema48,sd.ema288,sd.day_open
PIP=0.01; LBS=(24,48,96); TRAIL=3.0; CAP=144
MU=(-1.5647647681,-1.9859023515,-2.6433684188); SDv=(1.3383025567,5.7488277428,9.3743545638); TA,TB=0.9669,0.4686
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%d %H:%M')
def day_idx(d,hh,mm): return int(np.searchsorted(t, dt.datetime(2026,11,d,hh,mm,tzinfo=dt.timezone.utc).timestamp()))

def signal(i,s):
    O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c)
    a=atr[i]; kind=0; lb=0
    for LB in LBS:
        lv=L[i-LB:i-2].min(); kd=0
        if (lv-L[i])/a>0.05 and C[i]>lv: kd=2
        elif abs(L[i]-lv)<=0.30*a and C[i]>O[i] and C[i]>lv: kd=1
        if kd and (kind==0 or (kd==2 and kind!=2)): kind,lb=kd,LB
        if kd==2: break
    if not kind: return None
    z=[(s*(c[i]-e48[i])/a-MU[0])/SDv[0],(s*(c[i]-e288[i])/a-MU[1])/SDv[1],(s*(c[i]-dop[i])/a-MU[2])/SDv[2]]
    score=-np.mean(z); risk=min(max(C[i]-(L[i]-0.2*a),0.7*a),2.5*a)
    return kind,lb,score,risk

def trade(i,s,risk,a_sig):
    """entry next open; returns (entry_price, exit_idx, exit_price, reason) in real prices"""
    O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c)
    stop=C[i]-risk; entry=O[i+1]+sp[i+1]
    if entry<=stop: return None
    hh=C[i]
    for j in range(i+1,min(n-1,i+CAP)+1):
        if L[j]<=stop: return s*entry, j, s*min(stop,O[j]), 'stop' if stop<=C[i]-risk+1e-12 else 'trail'
        hh=max(hh,H[j]); stop=max(stop,hh-TRAIL*atr[j])
    j=min(n-1,i+CAP); return s*entry,j,s*C[j],'end/cap'

start,end=day_idx(5,0,0),min(day_idx(7,0,0),n-1)
last=[-1000,-1000]; rows=[]
for i in range(600,end):
    for d,s in enumerate((1,-1)):
        if i-last[d]<6: continue
        sg=signal(i,s)
        if not sg: continue
        kind,lb,score,risk=sg; last[d]=i
        if i<start: continue
        tier=1 if score>=TA else 2 if score>=TB else 3
        tr=trade(i,s,risk,atr[i])
        if tr is None: continue
        ent,xj,xp,why=tr
        rows.append((i,s,kind,lb,score,tier,ent,xj,xp,why,s*(xp-ent)/PIP-sp[i+1]/PIP*0))
print(f"Signals 5-6 Nov (server time), all tiers: {len(rows)}\n")
print(f"{'signal bar':>11} {'dir':>4} {'kind':>6} {'LB':>3} {'score':>6} tier {'entry':>8} {'exit':>11} {'xprice':>8} {'why':>7} {'pips':>6}")
for (i,s,kind,lb,score,tier,ent,xj,xp,why,pips) in rows:
    if tier<=2 or '-all' in sys.argv:
        print(f"{tstr(i):>11} {'BUY' if s>0 else 'SELL':>4} {'sweep' if kind==2 else 'retest':>6} {lb:3d} {score:6.2f}  {'ABC'[tier-1]}   {ent:8.3f} {tstr(xj):>11} {xp:8.3f} {why:>7} {pips:6.1f}")
print()
for lab,sel in (("Tier A only",lambda r:r[5]==1),("Tier A+B",lambda r:r[5]<=2),("All tiers",lambda r:True)):
    rr=[r for r in rows if sel(r)]
    if rr:
        p=np.array([r[10] for r in rr]); print(f"{lab:12s} n={len(rr):3d} win={np.mean(p>0)*100:3.0f}% total={p.sum():+7.1f}p avg={p.mean():+5.1f}p best={p.max():+.0f} worst={p.min():+.0f}")
print("\nper day, all tiers:")
for dd in (5,6):
    rr=[r for r in rows if dt.datetime.fromtimestamp(t[r[0]],dt.timezone.utc).day==dd]
    if rr: p=np.array([r[10] for r in rr]); print(f"  Nov {dd}: n={len(rr)} total={p.sum():+.1f}p  tierA n={sum(r[5]==1 for r in rr)}  tierB n={sum(r[5]==2 for r in rr)}")
