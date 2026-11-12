import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True);d=d[d.time>='2026-03-09'].reset_index(drop=True)
d['date']=d.time.dt.date;h=d.high.values;l=d.low.values;n=len(d)
dl=d.groupby('date').low.min();dates=[x for x in dl.index if pd.Timestamp(x).dayofweek<5]
pdl={dates[i]:dl[dates[i-1]] for i in range(1,len(dates))}
rows=[];last=-99
for i in range(n-40):
    dt_=d.date[i]
    if dt_ not in pdl or d.time[i]<pd.Timestamp('2026-03-10'):continue
    P=pdl[dt_]
    if l[i]>P+.0 or i-last<24 or l[i-12:i].min()<=P+.03:last=i if l[i]<=P else last;continue
    last=i;rally=0;broke=False
    for k in range(i,i+37):
        if l[k]<=P-.10:broke=True;break
        rally=max(rally,(h[k]-P)/.01)
    # rally measured before a 10p break; also record first-bar-of-day flag
    rows.append(dict(time=d.time[i],hr=d.time[i].hour,first=int(i==d.index[d.date==dt_][0] or not any(rows) or rows[-1]['date']!=dt_) if rows else 1,date=dt_,rally=rally,broke=broke,under=(P-l[i])/.01))
r=pd.DataFrame(rows)
def rep(x,label):
    print(f'{label}: touches {len(x)} on {x.date.nunique()} days | '+' | '.join(f'+{k}p before 10p break: {int(((x.rally>=k)&(~x.broke)|((x.rally>=k))).sum())}' for k in (10,20,30))+f' | broke 10p below first: {int(((x.rally<10)&x.broke).sum())} | median rally {x.rally.median():.0f}p')
rep(r,'ALL touches (episodes >=2h apart), Mar-Nov')
rep(r[r.time>='2026-08-10'],'LAST 3 MONTHS')
f=r.drop_duplicates('date');rep(f[f.time>='2026-08-10'],'First touch of the day, last 3 months')

x=r[r.time>='2026-08-10']
print(x[['time','under','rally','broke']].round(0).to_string())
print('bounce>=20p share last3m: %.0f%%  all: %.0f%%'%((x.rally>=20).mean()*100,(r.rally>=20).mean()*100))
