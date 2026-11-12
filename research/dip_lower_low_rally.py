import pandas as pd, numpy as np
d=pd.read_pickle('usdjpy_M5_fresh.pkl'); d=d[d.time>='2026-08-10'].reset_index(drop=True)
h=d.high.values;l=d.low.values;c=d.close.values;t=d.time;n=len(d);P=0.01
K=3;ev=[];last=-99
piv=[i for i in range(K,n-K) if l[i]==l[i-K:i+K+1].min() and l[i]<l[i-K:i].min()+1e-9]
for j in range(K+1,n-40):
    # sweep bar j: low undercuts a pivot low p (confirmed, 6..60 bars earlier), first undercut, bounce >=5 pips between
    if j-last<12: continue
    for p in reversed([q for q in piv if 6<=j-q<=60 and q+K<j]):
        if l[j]<l[p] and l[j]>=l[p]-0.15 and l[p+1:j].min()>=l[p]-1e-9 and h[p:j].max()-l[p]>=0.05 and l[j]==l[j-3:j+1].min():
            ev.append((j,p));last=j;break
rows=[]
for j,p in ev:
    lo=l[j];end=j+24
    brk=next((k for k in range(j+1,end+1) if c[k]<lo),end+1)   # close below sweep low
    up=(h[j+1:min(brk,end+1)].max()-lo)/P if brk>j+1 else 0
    rows.append((t[j],(l[p]-lo)/P,up,brk<=end))
r=pd.DataFrame(rows,columns=['time','undercut_p','rally_p','stopped']);r['hr']=r.time.dt.hour+r.time.dt.minute/60
print('sweep events',len(r),'in',round((t.iloc[-1]-t.iloc[0]).days/7,1),'weeks')
for th in (15,20,30,40):
    g=r[(r.rally_p>=th)&(~r.stopped)];w=g[(g.hr>=9)&(g.hr<12)]
    print(f'rally>={th}p within 2h, no close below sweep low: {len(g)} all-day, {len(w)} in 09-12 server | base all-day {len(r)}, window {((r.hr>=9)&(r.hr<12)).sum()}')
g=r[(r.rally_p>=30)&(~r.stopped)];print(g.sort_values('time').tail(40).round(1).to_string())
