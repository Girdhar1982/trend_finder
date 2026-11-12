import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True);d=d[d.time>='2026-03-10']
d['date']=d.time.dt.date;d['m']=d.time.dt.hour*60+d.time.dt.minute
TPS=(4,6,8,12,20,30);SL=4;res={tp:[] for tp in TPS};meta=[]
for dt_,g in d.groupby('date'):
    if g.time.dt.dayofweek.iloc[0]>4 or len(g)<200: continue
    w1=g[(g.m>=435)&(g.m<=495)];w2=g[(g.m>=555)&(g.m<=615)]
    if w1.empty or w2.empty: continue
    lower=w2.low.min()<w1.low.min()
    e=g[g.m>=620].iloc[0];ent=e.open+e.spread*.01
    fut=g[(g.index>=e.name)&(g.m<=800)]
    meta.append((dt_,lower))
    for tp in TPS:
        r=None
        for x in fut.itertuples():
            hs=x.low<=ent-SL*.01;ht=x.high>=ent+tp*.01
            if hs: r=-SL;break          # stop first if same bar (conservative)
            if ht: r=tp;break
        if r is None:r=(fut.close.iloc[-1]-ent)/.01
        res[tp].append(r)
m=pd.DataFrame(meta,columns=['date','lower']);cut=pd.Timestamp('2026-07-10').date()
print(f'stop {SL}p from entry (10:20 server buy), held to 13:20; stop wins ties; spread included')
print('TP  breakeven | ALL win%% avg | LOWER-ONLY n=%d win%% avg | train/test(lower) win%%'%m.lower.sum())
for tp in TPS:
    s=pd.Series(res[tp]);lo=s[m.lower.values];h1=lo[(m.date<cut)[m.lower].values];h2=lo[(m.date>=cut)[m.lower].values]
    print(f'{tp:>2}  {SL/(SL+tp)*100:4.0f}%  | {(s>0).mean()*100:3.0f}% {s.mean():+.2f}p | {(lo>0).mean()*100:3.0f}% {lo.mean():+.2f}p | {(h1>0).mean()*100:.0f}% / {(h2>0).mean()*100:.0f}%')
