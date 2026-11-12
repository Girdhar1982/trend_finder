import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True);d=d[d.time>='2026-03-10']
d['date']=d.time.dt.date;d['m']=d.time.dt.hour*60+d.time.dt.minute
TPS=(4,6,8,12,20,30);SL=4;R={tp:[] for tp in TPS};meta=[]
for dt_,g in d.groupby('date'):
    if g.time.dt.dayofweek.iloc[0]>4 or len(g)<200: continue
    w1=g[(g.m>=435)&(g.m<=495)]
    if w1.empty: continue
    pre=g[(g.m>495)&(g.m<570)]                      # 08:20-09:25, known at 09:30
    below=pre.low.min()<w1.low.min() if len(pre) else False
    e=g[g.m>=570].iloc[0];ent=e.open+e.spread*.01
    fut=g[(g.index>=e.name)&(g.m<=800)]
    meta.append((dt_,below))
    for tp in TPS:
        r=None
        for x in fut.itertuples():
            if x.low<=ent-SL*.01:r=-SL;break
            if x.high>=ent+tp*.01:r=tp;break
        if r is None:r=(fut.close.iloc[-1]-ent)/.01
        R[tp].append(r)
m=pd.DataFrame(meta,columns=['date','below']);cut=pd.Timestamp('2026-07-10').date()
print('BUY 09:30 server, stop 4p, to 13:20, days',len(m),'| price already below 07:45-dip low by 09:30:',m.below.sum())
print('TP  BE  | ALL win% avg | BELOW-first-dip win% avg | H1/H2 win% (all)')
for tp in TPS:
    s=pd.Series(R[tp]);bl=s[m.below.values];h1=s[(m.date<cut).values];h2=s[(m.date>=cut).values]
    print(f'{tp:>2} {SL/(SL+tp)*100:4.0f}% | {(s>0).mean()*100:3.0f}% {s.mean():+.2f}p | {(bl>0).mean()*100:3.0f}% {bl.mean():+.2f}p | {(h1>0).mean()*100:.0f}/{(h2>0).mean()*100:.0f}')
