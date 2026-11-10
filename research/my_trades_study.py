import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
PIP=0.01
d=pd.read_pickle('my_deals.pkl'); d=d[d.symbol=='USDJPY']
ins=d[d.entry==0].set_index('position_id'); outs=d[d.entry==1].groupby('position_id').agg(
    xt=('time','last'),xp=('price','last'),xprofit=('profit','sum'),xcomm=('commission','sum'),xswap=('swap','sum'),xfee=('fee','sum'),xcomment=('comment','last'),xn=('time','size'))
T=ins.join(outs,how='inner'); T=T.rename(columns={'time':'et','price':'ep'}).sort_values('et').reset_index()
T['dir']=np.where(T.type==0,1,-1)
T['pips']=T.dir*(T.xp-T.ep)/PIP
T['net']=T.profit+T.commission+T.fee+T.swap+T.xprofit+T.xcomm+T.xswap+T.xfee
T['hold_min']=(T.xt-T.et).dt.total_seconds()/60
t,o,h,l,c,atr,n=sd.t,sd.o,sd.h,sd.l,sd.c,sd.atr,sd.n
ets=T.et.astype('int64')//10**9; xts=T.xt.astype('int64')//10**9
T['i']=np.searchsorted(t,ets,'right')-1; T['xi']=np.searchsorted(t,xts,'right')-1
T=T[(T.i>650)&(T.xi<n)].reset_index(drop=True)
print("paired positions:",len(T),"| exits per position max:",int(T.xn.max()),"| volumes:",T.volume.value_counts().to_dict())
print("check vs screenshot:"); print(T[(T.et>='2026-11-05')][['et','dir','volume','ep','xt','xp','pips','net']].head(9).to_string(index=False))
T.to_pickle('my_trades.pkl')
