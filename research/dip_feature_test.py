import warnings;warnings.filterwarnings("ignore")
import pandas as pd, numpy as np
a=pd.read_pickle('usdjpy_M5.pkl');b=pd.read_pickle('usdjpy_M5_fresh.pkl')
d=pd.concat([a,b]).drop_duplicates('time').sort_values('time').reset_index(drop=True)
d=d[d.time>='2026-03-10'].reset_index(drop=True)
o=d.open.values;h=d.high.values;l=d.low.values;c=d.close.values;v=d.tick_volume.values.astype(float);sp=d.spread.values;t=d.time;n=len(d);P=.01
pc=np.r_[c[0],c[:-1]];tr=np.maximum(h-l,np.maximum(abs(h-pc),abs(l-pc)));atr=pd.Series(tr).rolling(14).mean().values
ema288=pd.Series(c).ewm(span=288,adjust=False).mean().values
dl=pd.Series(c).diff();up=dl.clip(lower=0).ewm(alpha=1/14,adjust=False).mean();dn=(-dl.clip(upper=0)).ewm(alpha=1/14,adjust=False).mean();rsi=(100-100/(1+up/dn)).values
vma=pd.Series(v).rolling(20).mean().values
K=3;piv=[i for i in range(K,n-K) if l[i]==l[i-K:i+K+1].min() and l[i]<l[i-K:i].min()+1e-9]
rows=[];last=-99
for j in range(300,n-40):
    if j-last<12: continue
    for p in reversed([q for q in piv if 6<=j-q<=60 and q+K<j]):
        if l[j]<l[p]<=l[j]+.15 and l[p+1:j].min()>=l[p]-1e-9 and h[p:j].max()-l[p]>=.05 and l[j]==l[j-3:j+1].min():
            last=j;lo=l[j];e=o[j+1]+sp[j+1]*P
            brk=next((k for k in range(j+1,j+25) if c[k]<lo),10**9)
            r30=(h[j+1:min(brk,j+25)].max()-lo)/P>=30 if brk>j+1 else False
            # tradable: +20 before -10 within 36 bars from next open
            res=0
            for k in range(j+1,j+37):
                if l[k]<=e-.10: res=0;break
                if h[k]>=e+.20: res=1;break
            hr=t[j].hour+t[j].minute/60
            rows.append(dict(time=t[j],run30=int(r30),win=res,depth=(l[p]-lo)/P,depth_atr=(l[p]-lo)/atr[j],
              closepos=(c[j]-l[j])/max(h[j]-l[j],1e-9),vol=v[j]/vma[j],bounce_atr=(h[p:j].max()-l[p])/atr[j],bars=j-p,
              rsi_div=int(rsi[j]>rsi[p]),rsi=rsi[j],trend=(c[j]-ema288[j])/atr[j],hour=hr,range_atr=(h[j]-l[j])/atr[j]))
            break
r=pd.DataFrame(rows);cut=int(len(r)*.6);tr,te=r.iloc[:cut],r.iloc[cut:]
print('events',len(r),'train',len(tr),'test',len(te));
for k in('run30','win'):print(k,'base train %.1f%% test %.1f%%'%(tr[k].mean()*100,te[k].mean()*100))
print('\nfeature: tercile cutoffs from train -> hit(win +20/-10; BE 33%) / run30 , train | test')
for f in ['depth','depth_atr','closepos','vol','bounce_atr','bars','rsi','trend','hour','range_atr']:
    q=np.unique(tr[f].quantile([1/3,2/3]).values);bins=[-1e9,*q,1e9]
    for name,df in(('tr',tr),('te',te)):df[f+'_b']=pd.cut(df[f],bins,labels=False)
    out=[]
    for bkt in sorted(tr[f+'_b'].dropna().unique()):
        a_=tr[tr[f+'_b']==bkt];b_=te[te[f+'_b']==bkt]
        out.append(f'b{int(bkt)}[{a_.win.mean()*100:.0f}/{a_.run30.mean()*100:.0f} n{len(a_)} | {b_.win.mean()*100:.0f}/{b_.run30.mean()*100:.0f} n{len(b_)}]')
    print(f.ljust(10),' '.join(out))
a_=tr[tr.rsi_div==1];b_=te[te.rsi_div==1];a0=tr[tr.rsi_div==0];b0=te[te.rsi_div==0]
print('rsi_div=1',f'{a_.win.mean()*100:.0f}/{a_.run30.mean()*100:.0f} n{len(a_)} | {b_.win.mean()*100:.0f}/{b_.run30.mean()*100:.0f} n{len(b_)}','  =0',f'{a0.win.mean()*100:.0f}/{a0.run30.mean()*100:.0f} | {b0.win.mean()*100:.0f}/{b0.run30.mean()*100:.0f}')
r.to_pickle('dip_events.pkl')
