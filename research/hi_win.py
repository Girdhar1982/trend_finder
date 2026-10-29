import sys, itertools; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
d=pd.read_pickle("feat_M15.pkl")
cut=d.time.iloc[int(len(d)*0.6)]
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
dtr=nd(d.time.iloc[0],cut); dte=nd(cut,d.time.iloc[-1])
RULE=dict(rsi_pull=50,rsi_floor=40,pull_bars=4,min_atr_pips=6,htf=True,use_pdhl=True,h0=3,h1=19)
rows=[]
for ob,mb,mp in itertools.product([0,1],[4,8],[6,9]):
    sg=dict(RULE,ob=ob,pull_bars=mb,min_atr_pips=mp)
    p0={**bt.BASE,**sg}; sig=bt.signals(d,p0)
    for tp,sl,mh in itertools.product([0.3,0.4,0.5,0.6,0.8,1.0],[1.5,2.0,3.0,4.0],[16,32,64]):
        p={**p0,"tp_atr":tp,"sl_atr":sl,"max_hold":mh}
        tr=bt.simulate(d,sig,p)
        if len(tr)<40: continue
        tr['time']=pd.to_datetime(tr.time)
        a=bt.stats(tr[tr.time<cut],dtr); b=bt.stats(tr[tr.time>=cut],dte); c=bt.stats(tr,dtr+dte)
        rows.append(dict(ob=ob,pb=mb,minatr=mp,tp=tp,sl=sl,hold=mh,n=c['n'],win=c['win'],exp=c['exp'],pf=c['pf'],net=c['net'],pd=c['perday'],n_tr=a['n'],win_tr=a['win'],exp_tr=a['exp'],n_te=b['n'],win_te=b['win'],exp_te=b['exp']))
r=pd.DataFrame(rows); r.to_pickle("hi_win.pkl"); pd.set_option('display.width',250); pd.set_option('display.max_columns',30)
print(len(r))
for w in (80,75,70):
    q=r[(r.win_tr>=w)&(r.win_te>=w)]
    print(f"\n-- train&test win>={w}%: {len(q)} configs; with exp>0 both halves: {((q.exp_tr>0)&(q.exp_te>0)).sum()}")
    print(q.sort_values('exp',ascending=False).head(6).round(2).to_string())
print("\nBest overall by exp (all data), win>=65 and both halves exp>0:")
print(r[(r.win>=65)&(r.exp_tr>0)&(r.exp_te>0)].sort_values('exp',ascending=False).head(8).round(2).to_string())
