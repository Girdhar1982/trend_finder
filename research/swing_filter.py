import numpy as np, pandas as pd, itertools
import sweep_dataset as sd
from swing_recall import evaluate
legs,_,_=pd.read_pickle('swing_recall.pkl'); df=pd.read_pickle('swing_candidates.pkl')
t=sd.t; cut_i=df.i.iloc[int(len(df)*0.6)]
big=legs[legs['size']>=30]
def ev_half(sig, half):
    lg = legs[(legs.start<cut_i)] if half=='tr' else legs[(legs.start>=cut_i)]
    s=[(i,s) for i,s in sig if (i<cut_i)==(half=='tr')]
    r,_=evaluate('x',s,lg); days=((cut_i-700) if half=='tr' else (sd.n-cut_i))/288*7/5/ (7/5)  # bars->days approx
    return r['precision'], r['recall_30'], r['recall_50'], len(s)/(((t[cut_i]-t[700]) if half=='tr' else (t[-1]-t[cut_i]))/86400*5/7)
rows=[]
for st,d,vx in itertools.product((-99,0.0,0.3,0.62),(99,3,2,1),(0,1.0,1.3)):
    m=(df.stretch>=st)&(df.d24<=d)&(df.volx>=vx)
    sig=list(zip(df.i[m],df.s[m]))
    a=ev_half(sig,'tr'); b=ev_half(sig,'te')
    rows.append(dict(stretch=st,d24=d,volx=vx,day_te=round(b[3],1),prec_tr=a[0],prec_te=b[0],rec30_tr=a[1],rec30_te=b[1],rec50_te=b[2]))
R=pd.DataFrame(rows)
print("all candidates:"); print(R[(R.stretch==-99)&(R.d24==99)&(R.volx==0)].to_string(index=False))
print("\nbest balance (test signals/day between 3 and 10), sorted by test recall:")
print(R[(R.day_te>=3)&(R.day_te<=10)].sort_values('rec30_te',ascending=False).head(12).to_string(index=False))
print("\nhighest precision with >=2/day:"); print(R[R.day_te>=2].sort_values('prec_te',ascending=False).head(6).to_string(index=False))
