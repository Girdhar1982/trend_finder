import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True);d=d[d.time>='2026-03-10']
d['date']=d.time.dt.date;d['m']=d.time.dt.hour*60+d.time.dt.minute
rows=[]
for dt_,g in d.groupby('date'):
    if g.time.dt.dayofweek.iloc[0]>4 or len(g)<200: continue
    w1=g[(g.m>=7*60+15)&(g.m<=8*60+15)];w2=g[(g.m>=9*60+15)&(g.m<=10*60+15)]
    if w1.empty or w2.empty: continue
    l1=w1.low.min();i2=w2.low.idxmin();l2=w2.low.min()
    post=g[(g.index>i2)&(g.m<=i2*0+g.loc[i2,'m']+180)]
    if len(post)<10: continue
    brk=post[post.close<l2]; end=brk.index[0] if len(brk) else post.index[-1]
    rally=(post.loc[:end].high.max()-l2)/.01
    # causal entry: 10:20 server open, stop l2-1p, TP 30 / 20, 3h
    e=g[g.m>=10*60+20].iloc[0];ent=e.open+e.spread*.01;sl=l2-.01
    fut=g[(g.index>=e.name)&(g.m<=13*60+20)];res=None
    for _,x in fut.iterrows():
        if x.low<=sl:res=(sl-ent)/.01;break
        if x.high>=ent+.30:res=30;break
    if res is None:res=(fut.close.iloc[-1]-ent)/.01
    rows.append(dict(date=dt_,dow=pd.Timestamp(dt_).day_name()[:3],lower=l2<l1,undercut=(l1-l2)/.01,rally=rally,run30=rally>=30,pl=res,low2_time=g.loc[i2,'time'].strftime('%H:%M')))
r=pd.DataFrame(rows);print('days',len(r))
for k,gg in r.groupby('lower'):print('second low lower than first =',k,'days',len(gg),'run>=30p %.0f%%'%(gg.run30.mean()*100),'median rally %.0fp'%gg.rally.median(),'pl30 %.2f'%gg.pl.mean())
g=r[r.lower];print(g.groupby('dow').agg(n=('run30','size'),run=('run30','sum')).T.to_string())
g['half']=np.where(g.date<pd.Timestamp('2026-07-10').date(),'H1','H2');print(g.groupby('half').agg(n=('pl','size'),run30=('run30','mean'),pl=('pl','mean'),win=('pl',lambda s:(s>0).mean())).round(2))
print(g[g.date>=pd.Timestamp('2026-08-10').date()][['date','dow','undercut','rally','pl']].round(1).to_string())
