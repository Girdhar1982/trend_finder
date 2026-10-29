import sys; sys.path.insert(0, r"C:\myfiles\training_folder\research")
import MetaTrader5 as mt5, pandas as pd, numpy as np, bt
mt5.initialize(); mt5.symbol_select("USDJPY",True)
TF={"M15":mt5.TIMEFRAME_M15,"H1":mt5.TIMEFRAME_H1,"H4":mt5.TIMEFRAME_H4}
def live(tf):
    d=pd.DataFrame(mt5.copy_rates_from_pos("USDJPY",TF[tf],0,20000 if tf!="H4" else 6000)); d['time']=pd.to_datetime(d.time,unit='s'); return d
cache={k:live(k) for k in TF}
bt.load=lambda tf:cache[tf].copy()
t=mt5.symbol_info_tick("USDJPY"); print("tick",t.bid,t.ask,"spread pips",round((t.ask-t.bid)/0.01,1),"server time",pd.to_datetime(t.time,unit='s'))
def check(name,d,p):
    # d's last row is the forming bar; evaluate the last CLOSED bar (-2)
    sig=bt.signals(d,{**bt.BASE,**p}); i=len(d)-2; r=d.iloc[i]
    print(f"\n{name}: last closed bar {r.time} close {r.close} | ATR {r.atr/0.01:.1f}p RSI {r.rsi:.1f} bbm {r.bbm:.3f} hull {int(r.hdir)} htf {int(r.hdir_htf)} hour {r.hour:.2f}")
    print("  OB bear touch last 4:",d.ob_bear.iloc[i-5:i+1].any()," bull:",d.ob_bull.iloc[i-5:i+1].any(), "| signal on last closed bar:",int(sig[i]),"| any in last 3 bars:",sig[i-2:i+1].tolist())
    return r
d15=bt.features("M15","H1"); d1=bt.features("H1","H4",4)
B=dict(pull_bars=4,rsi_pull=50,rsi_floor=40,min_atr_pips=6,htf=True,use_pdhl=True,h0=3,h1=19)
check("Profile B (M15 core)",d15,B)
check("Profile A (M15 +OB)",d15,{**B,"ob":1})
check("Profile C (H1 +OB)",d1,dict(pull_bars=6,rsi_pull=50,rsi_floor=30,htf=True,use_pdhl=False,ob=1,h0=3,h1=19,min_atr_pips=15))
r=d15.iloc[-2]; print("\nPDL",r.dl,"PDH",r.dh,"| M15 ATR",r.atr/0.01)
print("H1 hull",int(d1.hdir.iloc[-2]),"H4 hull",int(d1.hdir_htf.iloc[-2]),"H1 RSI",round(d1.rsi.iloc[-2],1))
print("orders",mt5.orders_total(),"positions",mt5.positions_total())
mt5.shutdown()
