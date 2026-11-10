"""Stretch mean-reversion scalp on USDJPY M5. Signal at bar i close (no look-ahead): per-bar stretch score against direction s
>= theta AND a reversal bar (bullish for long / bearish for short); fill = next open + spread; fixed TP/SL in ATR, time stop 24 bars.
Parameters chosen on TRAIN (first 60% of bars) only; reported on TEST."""
import numpy as np, pandas as pd, itertools
import sweep_dataset as sd
PIP=0.01; MAXB=24
o,h,l,c,sp,atr,n,t=sd.o,sd.h,sd.l,sd.c,sd.sp,sd.atr,sd.n,sd.t
MU=(-1.5648,-1.9859,-2.6434); SDv=(1.3383,5.7488,9.3744)
def score(s):
    a=atr
    z=[(s*(c-sd.ema48)/a-MU[0])/SDv[0],(s*(c-sd.ema288)/a-MU[1])/SDv[1],(s*(c-sd.day_open)/a-MU[2])/SDv[2]]
    return -np.mean(z,axis=0)
S={1:score(1),-1:score(-1)}
cut=int(n*0.6); days_tr=(t[cut]-t[600])/86400*5/7; days_te=(t[-1]-t[cut])/86400*5/7
valid=np.arange(n)>=700
def run(theta,tp,sl):
    out=[]  # (bar index, pips)
    for s in (1,-1):
        O,H,L,C=(o,h,l,c) if s>0 else (-o,-l,-h,-c)
        idx=np.where(valid&(S[s]>=theta)&(C>O))[0]; last=-99
        for i in idx:
            if i-last<6 or i>=n-MAXB-2: continue
            last=i; a=atr[i]; ent=O[i+1]+sp[i+1]; stp=ent-sl*a; tgt=ent+tp*a; res=None
            for j in range(i+1,i+MAXB+1):
                if L[j]<=stp: res=min(stp,O[j])-ent; break      # stop first on ties
                if H[j]>=tgt: res=tgt-ent; break
            if res is None: res=C[i+MAXB]-ent
            out.append((i,res/PIP))
    return np.array(out)

qs_all=np.r_[S[1][700:cut],S[-1][700:cut]]
