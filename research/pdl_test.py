import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True);d=d[d.time>='2026-03-09'].reset_index(drop=True)
d['date']=d.time.dt.date;d['m']=d.time.dt.hour*60+d.time.dt.minute
o=d.open.values;h=d.high.values;l=d.low.values;c=d.close.values;sp=d.spread.values;n=len(d)
dl=d.groupby('date').low.min();dates=[x for x in dl.index if pd.Timestamp(x).dayofweek<5]
pdl={dates[i]:dl[dates[i-1]] for i in range(1,len(dates))}
TPS=(4,8,12,20,30);SL=4;HOLD=60
def sim(i0,e,tp):
    for k in range(i0,min(i0+HOLD,n)):
        if l[k]<=e-SL*.01:return -SL
        if h[k]>=e+tp*.01:return tp
    return (c[min(i0+HOLD-1,n-1)]-e)/.01
ev=[]
for dt_,g in d.groupby('date'):
    if dt_ not in pdl or pd.Timestamp(dt_)<pd.Timestamp('2026-03-10') or len(g)<200:continue
    P=pdl[dt_];gi=g.index.values
    hit=[i for i in gi if l[i]<=P+.02]
    if not hit:ev.append(dict(date=dt_,bucket='none'));continue
    i=hit[0];m=d.m[i];bk='<09:00' if m<540 else ('09-10' if m<600 else '>=10:00')
    r=dict(date=dt_,bucket=bk,t=d.time[i],under=(P-l[i])/.01)
    # A: limit buy at PDL, fills if ask<=PDL
    fi=next((k for k in gi if k>=i and l[k]+sp[k]*.01<=P),None)
    for tp in TPS:
        r['A%d'%tp]=sim(fi,P,tp) if fi is not None and fi+HOLD<n else np.nan
    # B: first close back above PDL within 12 bars (after touch), next open
    bi=next((k for k in gi if i<=k<=i+12 and c[k]>P and k+1<n),None)
    for tp in TPS:
        r['B%d'%tp]=sim(bi+1,o[bi+1]+sp[bi+1]*.01,tp) if bi is not None and bi+1+HOLD<n else np.nan
    ev.append(r)
e=pd.DataFrame(ev);tot=len(e);print('trading days',tot);print(e.bucket.value_counts().to_string())
cut=pd.Timestamp('2026-07-10').date()
print('\nstop 4p; win% / avg pips (breakeven win = 4/(4+TP)); H1|H2 avg')
for bk in['09-10','<09:00','>=10:00']:
    s=e[e.bucket==bk]
    for kind,lab in(('A','limit buy at prev-day low'),('B','buy after close back above PDL')):
        print(f'\n[{bk}] {lab}  n={s[kind+"8"].notna().sum()}')
        for tp in TPS:
            x=s[kind+str(tp)].dropna();h1=s.loc[x.index][s.loc[x.index].date<cut][kind+str(tp)];h2=s.loc[x.index][s.loc[x.index].date>=cut][kind+str(tp)]
            print(f'  TP{tp:<2} BE {4/(4+tp)*100:3.0f}%  win {(x>0).mean()*100:3.0f}%  avg {x.mean():+.2f}p   H1 {h1.mean():+.2f} | H2 {h2.mean():+.2f}')

print('\n--- ANY touch inside window (regardless of earlier touches), days of',tot)
rows=[]
for dt_,g in d.groupby('date'):
    if dt_ not in pdl or pd.Timestamp(dt_)<pd.Timestamp('2026-03-10') or len(g)<200:continue
    P=pdl[dt_];w=g[(g.m>=540)&(g.m<600)];x=g[(g.m>=600)&(g.m<660)];y=g[(g.m>=420)&(g.m<540)]
    rows.append((dt_,(w.low.min()-P)/.01,(x.low.min()-P)/.01,(y.low.min()-P)/.01,(g.low.min()-P)/.01))
z=pd.DataFrame(rows,columns=['date','w0910','w1011','w0709','dayminusP'])
for px in(0,2,5,10):
    print(f'within {px:>2}p of/below PDL: 09-10 {int((z.w0910<=px).sum()):3d} days | 10-11 {int((z.w1011<=px).sum()):3d} | 07-09 {int((z.w0709<=px).sum()):3d}')
