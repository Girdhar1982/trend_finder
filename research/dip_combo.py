import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
exec(open('dip_feature_test.py').read().split("r=pd.DataFrame(rows)")[0].replace("res=0\n","res=0\n            exs=None\n"))
# tradable: stop = sweep low -1p, target +30p (and +20p) from next open+spread, 36 bars; pips net
def trade(j,tp):
    e=o[j+1]+sp[j+1]*P;sl=l[j]-.01
    for k in range(j+1,j+37):
        if l[k]<=sl:return (sl-e)/P
        if h[k]>=e+tp*P:return tp
    return (c[j+36]-e)/P
r=pd.DataFrame(rows)
idx={tt:i for i,tt in enumerate(t)}
for tp in(20,30):r['pl%d'%tp]=[trade(idx[x],tp) for x in r.time]
cut=int(len(r)*.6);tr,te=r.iloc[:cut],r.iloc[cut:]
def rep(name,m):
    s=[]
    for nm,df in(('tr',tr),('te',te)):
        g=df[m(df)]; s.append(f"{nm} n{len(g)} run30 {g.run30.mean()*100:.0f}% pl20 {g.pl20.mean():+.2f} pl30 {g.pl30.mean():+.2f}p")
    print(name.ljust(34),' | '.join(s))
rep('all',lambda d:d.depth>=0)
rep('closepos>=.67',lambda d:d.closepos>=.67)
rep('rsi_div',lambda d:d.rsi_div==1)
rep('depth>=3.5p',lambda d:d.depth>=3.5)
rep('closepos>=.67 & rsi_div',lambda d:(d.closepos>=.67)&(d.rsi_div==1))
rep('closepos>=.67 & depth>=3.5',lambda d:(d.closepos>=.67)&(d.depth>=3.5))
rep('all3',lambda d:(d.closepos>=.67)&(d.rsi_div==1)&(d.depth>=3.5))
rep('closepos>=.67 & vol>=1.2',lambda d:(d.closepos>=.67)&(d.vol>=1.2))
print(tr.depth.quantile(2/3), 'months of test:',te.time.min(),te.time.max())
g=r[(r.closepos>=.67)&(r.rsi_div==1)];print(g.groupby(g.time.dt.to_period('M')).agg(n=('pl30','size'),run30=('run30','mean'),pl30=('pl30','mean')).round(2).to_string())
