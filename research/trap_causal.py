"""Bar-by-bar state machine = exactly what the MQL5 indicator does. Compare with trap_pattern.detect()."""
import datetime as dt, numpy as np
import sweep_dataset as sd
from trap_pattern import detect, BOX, W_MAX, BAIT_MIN, MAXW, TOL, RECL
t,o,h,l,c,atr,n=sd.t,sd.o,sd.h,sd.l,sd.c,sd.atr,sd.n
tstr=lambda i: dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%Y-%m-%d %H:%M')
def causal():
    out=[]
    for s in (1,-1):
        O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c)
        pend=[]   # dicts push, top, bot, a, touch
        for i in range(BOX+20, n-40):
            fired=False
            for p in list(pend):
                if p['touch']<0:
                    if i<=p['push']+MAXW-1 and L[i]<=p['bot']+TOL*p['a']: p['touch']=i
                    elif i>p['push']+MAXW-1: pend.remove(p); continue
                if p['touch']>=0:
                    if i<=p['touch']+RECL:
                        if C[i]>p['bot'] and C[i]>O[i]:
                            out.append((i,s,p['push'],p['touch'])); fired=True; break
                    else: pend.remove(p)
            if fired: pend=[]; continue
            a=atr[i-1]; top=H[i-BOX:i].max(); bot=L[i-BOX:i].min()
            if (top-bot)<=W_MAX*a and C[i]>top+BAIT_MIN*a and C[i-1]<=top:
                pend.append(dict(push=i,top=top,bot=bot,a=a,touch=-1))
    return sorted(out)
cz=causal(); ref=detect()
A={(e[0],e[1]) for e in cz}; B={(e['sig'],e['s']) for e in ref}
print(f"causal events {len(A)} | look-ahead reference {len(B)} | identical {len(A&B)} | only causal {len(A-B)} | only reference {len(B-A)}")
for i,s,p,tch in cz:
    if tstr(i)[:10] in ('2026-11-05','2026-11-06'): print(f"  {'BUY ' if s>0 else 'SELL'} push {tstr(p)} back {tstr(tch)} SIGNAL {tstr(i)}")
print("last 8 causal signals:"); [print(f"  {tstr(i)} {'BUY ' if s>0 else 'SELL'}") for i,s,_,_ in cz[-8:]]
