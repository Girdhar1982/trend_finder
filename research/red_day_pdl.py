import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True);d=d[d.time>='2026-03-05'].reset_index(drop=True)
d['date']=d.time.dt.date
D=d.groupby('date').agg(o=('open','first'),h=('high','max'),l=('low','min'),c=('close','last'),n=('open','size'));D=D[(D.n>200)&(pd.Series(D.index).apply(lambda x:pd.Timestamp(x).dayofweek).values<5)]
days=list(D.index);rows=[]
for i in range(1,len(days)):
    dt_=days[i];p=D.loc[days[i-1]]
    if pd.Timestamp(dt_)<pd.Timestamp('2026-03-10'):continue
    g=d[d.date==dt_];l=g.low.values;h=g.high.values;c=g.close.values;P=p.l
    ep=0;last=-99;
    for k in range(len(g)):
        if l[k]<=P+.03 and k-last>=12 and (k==0 or l[max(0,k-12):k].min()>P+.03 or k<12):
            ep+=1
        if l[k]<=P+.03:last=k
    broke=(l.min()<=P-.10)
    rows.append(dict(date=dt_,prev='RED' if p.c<p.o else 'GREEN',tested=ep>=1,tests=ep,multi=ep>=2,broke10=broke,
        close_above=c[-1]>P,gap_ok=g.open.iloc[0]>P,rng=(p.h-p.l)/.01))
r=pd.DataFrame(rows);r=r[r.gap_ok]   # only days that opened above PDL (can test from above)
print('days opening above prev-day low:',len(r))
f=lambda x:pd.Series(dict(days=len(x),tested=int(x.tested.sum()),tested_pct=round(x.tested.mean()*100),multi_tests=int(x.multi.sum()),broke_10p=int(x.broke10.sum()),closed_above_PDL=int(x.close_above.sum())))
print(r.groupby('prev').apply(f).to_string())
t=r[r.tested];print('\nOf days that tested PDL:');print(t.groupby('prev').apply(lambda x:pd.Series(dict(n=len(x),held_close_above_pct=round(x.close_above.mean()*100),broke10_pct=round(x.broke10.mean()*100),avg_tests=round(x.tests.mean(),1)))).to_string())
for lab,s in(('last 3 months',r[r.date>=pd.Timestamp('2026-08-10').date()]),):
    print('\n',lab);print(s.groupby('prev').apply(f).to_string())
print('\nafter RED day, last 3 months that tested:');print(r[(r.prev=='RED')&r.tested&(r.date>=pd.Timestamp('2026-08-10').date())][['date','tests','broke10','close_above']].to_string())
