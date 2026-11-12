import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True)
c=d.close.values;h=d.high.values;l=d.low.values;o=d.open.values;sp=d.spread.values;n=len(d)
def lwma(x,p):
    w=np.arange(1,p+1);out=np.full(len(x),np.nan)
    for i in range(p-1,len(x)):out[i]=np.dot(x[i-p+1:i+1],w)/w.sum()
    return out
P=20;diff=2*lwma(c,P//2)-lwma(c,P);hma=lwma(np.nan_to_num(diff,nan=np.nan),int(P**.5))
pc=np.r_[c[0],c[:-1]];tr=np.maximum(h-l,np.maximum(abs(h-pc),abs(l-pc)));atr=pd.Series(tr).rolling(14).mean().values
trend=np.zeros(n,int);up_arr=np.zeros(n,bool);dn_arr=np.zeros(n,bool);st=None
for i in range(40,n):
    if np.isnan(hma[i]) or np.isnan(hma[i-1]) or np.isnan(atr[i]):continue
    s=hma[i]-hma[i-1];th=atr[i]*.05
    cand=1 if s>th else (0 if -s>th else -1)
    if st is None:
        if cand!=-1:st=cand
        trend[i]=st if st is not None else 0;continue
    if cand!=-1 and cand!=st:
        st=cand;(up_arr if cand==1 else dn_arr)[i]=True
    trend[i]=st
t=d.time;m=(t.dt.hour*60+t.dt.minute).values;dow=t.dt.dayofweek.values;date=t.dt.date.values
mask=(t>='2026-03-10').values&(dow<5)
cut=pd.Timestamp('2026-07-10')
def run(entries,SL,TP,exit_red=False,hold=60):
    out=[]
    for i in entries:
        e=o[i+1]+sp[i+1]*.01;r=None
        for k in range(i+1,min(i+1+hold,n)):
            if l[k]<=e-SL*.01:r=-SL;break
            if TP and h[k]>=e+TP*.01:r=TP;break
            if exit_red and dn_arr[k]:r=(c[k]-e)/.01;break
        if r is None:r=(c[min(i+hold,n-1)]-e)/.01
        out.append(r)
    return np.array(out)
def sel(first_only,lo=565,hi=715):
    idx=[i for i in range(n-70) if up_arr[i] and mask[i] and lo<=m[i]<=hi]   # arrow bar open 09:25..11:55 -> entry >=09:30
    if first_only:
        seen=set();o2=[]
        for i in idx:
            if date[i] not in seen:seen.add(date[i]);o2.append(i)
        idx=o2
    return np.array(idx)
for first in(True,False):
    idx=sel(first);ts=t.values[idx];H1=ts<np.datetime64(cut)
    print(f"\n{'FIRST green arrow per day' if first else 'EVERY green arrow'} entry 09:30-12:00 server, SL 4p, hold 5h  n={len(idx)} (H1 {H1.sum()}, H2 {(~H1).sum()})  days={len(set(date[idx]))}")
    print('exit        BE  | win%  avg   | H1 win/avg  | H2 win/avg')
    for name,TP,er in [('TP4',4,0),('TP6',6,0),('TP8',8,0),('TP12',12,0),('TP20',20,0),('TP30',30,0),('red arrow',0,1)]:
        r=run(idx,4,TP,er);be=f'{4/(4+TP)*100:3.0f}%' if TP else ' - '
        print(f'{name:<10} {be} | {(r>0).mean()*100:3.0f}% {r.mean():+.2f} | {(r[H1]>0).mean()*100:3.0f}% {r[H1].mean():+.2f} | {(r[~H1]>0).mean()*100:3.0f}% {r[~H1].mean():+.2f}')
