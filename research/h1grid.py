import sys, itertools; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
d=bt.features("H1","H4",4); d.to_pickle("feat_H1.pkl")
print(len(d),d.time.iloc[0],d.time.iloc[-1],"ATR pips median",(d.atr/0.01).median())
cut=d.time.iloc[int(len(d)*0.6)]
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
dtr=nd(d.time.iloc[0],cut); dte=nd(cut,d.time.iloc[-1])
rows=[]
for ob,pb,rp,rf,htf,pdhl,(h0,h1),mA in itertools.product([0,1],[3,6],[50,58],[30,40],[True],[True,False],[(0,24),(3,19),(8,17)],[10,15]):
    sg=dict(pull_bars=pb,rsi_pull=rp,rsi_floor=rf,htf=htf,use_pdhl=pdhl,h0=h0,h1=h1,min_atr_pips=mA,ob=ob,room_atr=0.5)
    p0={**bt.BASE,**sg}; sig=bt.signals(d,p0)
    if (sig!=0).sum()<30: continue
    for tp,sl,mh in itertools.product([0.5,0.75,1.0,1.5,2.0],[1.0,1.5,2.0,3.0],[8,16,24]):
        p={**p0,"tp_atr":tp,"sl_atr":sl,"max_hold":mh,"max_day":5}
        tr=bt.simulate(d,sig,p)
        if len(tr)<50: continue
        tr['time']=pd.to_datetime(tr.time)
        a=bt.stats(tr[tr.time<cut],dtr); b=bt.stats(tr[tr.time>=cut],dte); c=bt.stats(tr,dtr+dte)
        rows.append(dict(ob=ob,pb=pb,rp=rp,rf=rf,pdhl=pdhl,h0=h0,h1=h1,mA=mA,tp=tp,sl=sl,mh=mh,n=c['n'],win=c['win'],exp=c['exp'],pf=c['pf'],net=c['net'],pd=c['perday'],n_tr=a['n'],win_tr=a['win'],exp_tr=a['exp'],n_te=b['n'],win_te=b['win'],exp_te=b['exp']))
r=pd.DataFrame(rows); r.to_pickle("h1grid.pkl"); print(len(r),"configs")
pd.set_option('display.width',260); pd.set_option('display.max_columns',30)
q=r[(r.exp_tr>0)&(r.exp_te>0)&(r.n_tr>=40)&(r.n_te>=20)]
print("profitable in BOTH halves:",len(q),"of",len(r))
print(q[q.win>=70].sort_values('exp',ascending=False).head(10).round(2).to_string())
print("\nwin>=60 both halves profitable, top by exp:")
print(q[(q.win_tr>=60)&(q.win_te>=60)].sort_values('exp',ascending=False).head(10).round(2).to_string())
