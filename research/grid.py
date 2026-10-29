import sys, itertools; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import bt, pandas as pd, numpy as np
tf=sys.argv[1]; htf=sys.argv[2]
d=bt.features(tf,htf)
cut=d.time.iloc[int(len(d)*0.6)]
nd=lambda a,b:max(1,np.busday_count(a.date(),b.date()))
dtr=nd(d.time.iloc[0],cut); dte=nd(cut,d.time.iloc[-1])
rows=[]
grid=dict(tp_atr=[0.6,1.0,1.5,2.0], sl_atr=[1.0,1.5,2.0], rsi_pull=[50,58], rsi_floor=[30,40], pull_bars=[4,8],
          min_atr_pips=[6,9], sess=[(3,19),(8,17),(15,19)], htf=[True,False], use_pdhl=[True,False])
keys=list(grid)
for vals in itertools.product(*grid.values()):
    k=dict(zip(keys,vals)); h0,h1=k.pop("sess")
    tr,p=bt.run(d,h0=h0,h1=h1,**k)
    if len(tr)==0: continue
    tr['time']=pd.to_datetime(tr.time)
    a=bt.stats(tr[tr.time<cut],dtr); b=bt.stats(tr[tr.time>=cut],dte)
    rows.append(dict(**k,h0=h0,h1=h1,n_tr=a['n'],win_tr=a['win'],exp_tr=a['exp'],pf_tr=a['pf'],n_te=b['n'],win_te=b['win'],exp_te=b['exp'],pf_te=b['pf'],net_te=b['net'],pd_te=b['perday']))
r=pd.DataFrame(rows); r.to_pickle(f"grid_{tf}.pkl")
print(len(r))
pd.set_option('display.width',250); pd.set_option('display.max_columns',30)
good=r[(r.n_tr>=120)&(r.win_tr>=60)&(r.exp_tr>0)]
print("train-qualified:",len(good))
print(good.sort_values("exp_tr",ascending=False).head(15).round(2).to_string())
print("\nof those, test exp>0 & win>=58:",((good.exp_te>0)&(good.win_te>=58)).sum(),"/",len(good))
print("\nBest on TEST regardless (n_te>=80, win>=60):")
print(r[(r.n_te>=80)&(r.win_te>=60)].sort_values("exp_te",ascending=False).head(10).round(2).to_string())
