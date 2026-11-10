import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from swing_recall import evaluate
legs,_,_=pd.read_pickle('swing_recall.pkl'); df=pd.read_pickle('swing_candidates.pkl'); t=sd.t
cut_i=df.i.iloc[int(len(df)*0.6)]
def rep(lab,m):
    out=[f"{lab:46s}"]
    for half in ('tr','te'):
        lg=legs[legs.start<cut_i] if half=='tr' else legs[legs.start>=cut_i]
        mm=m&((df.i<cut_i) if half=='tr' else (df.i>=cut_i))
        r,_=evaluate('x',list(zip(df.i[mm],df.s[mm])),lg)
        days=((t[cut_i]-t[700]) if half=='tr' else (t[-1]-t[cut_i]))/86400*5/7
        out.append(f"{half}: {mm.sum()/days:4.1f}/day prec {r['precision']:4.1f}% recall30 {r['recall_30']:4.1f}%")
    print("  ".join(out))
A=(df.stretch>=0)&(df.volx>=1.0)
for cols,lab in ((['is_psweep','is_pretest'],'pivot sweep+retest only'),(['is_psweep','is_pretest','is_choch'],'+ CHoCH'),
                 (['is_psweep','is_pretest','is_trap30','is_trap60'],'+ traps'),(['is_psweep','is_pretest','is_choch','is_trap30','is_trap60'],'all 5 types')):
    any_=df[cols].sum(axis=1)>0
    rep(f"A filter, {lab}",A&any_)
print()
B=(df.stretch>=0)|(df.d24<=3)
rep("B: stretch>=0 OR within 3 ATR of 24h extreme",B)
rep("A or B (what the chart shows)",A|B)
rep("stretch>=0 only",df.stretch>=0)
print("\n5-6 Nov candidates (server time):")
x=df[(df.i>=np.searchsorted(t,dt.datetime(2026,11,5,tzinfo=dt.timezone.utc).timestamp()))].copy()
x['time']=[dt.datetime.fromtimestamp(t[i],dt.timezone.utc).strftime('%m-%d %H:%M') for i in x.i]
x['tier']=np.where(A[x.index],'A',np.where(B[x.index],'B','-'))
x['types']=x[[c for c in df.columns if c.startswith('is_')]].apply(lambda r:'+'.join(c[3:] for c in r.index if r[c]),axis=1)
print(x[(x.time.between('11-05 06:00','11-05 08:00'))|(x.time.between('11-06 08:00','11-06 10:00'))][['time','s','types','stretch','volx','d24','tier','hit']].round(2).to_string(index=False))
