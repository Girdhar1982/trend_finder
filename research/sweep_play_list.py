import numpy as np, pandas as pd
from stretch_core import S
ev=pd.read_pickle('sweep_size_events.pkl'); ev=ev[ev['mode']=='same'].copy()
ev['st']=[S[s][k] for k,s in zip(ev.k,ev.s)]; ev['dt']=pd.to_datetime(ev.t,unit='s')
e=ev[(ev.level=='N288')]
e['cls']=np.where(e.depth_p>=3,'AVOID',np.where(e.depth_p<0.5,'-',np.where(e.st>=0.62,'PLAY','level')))
x=e[(e.dt>='2026-10-20')&(e.cls.isin(['PLAY','AVOID']))]
print(x[['dt','s','cls','depth_p','st','p10','pnl']].round(2).rename(columns={'dt':'bar (server)','s':'dir','depth_p':'sweep_pips','st':'stretch','p10':'hit+10','pnl':'pips'}).to_string(index=False))
