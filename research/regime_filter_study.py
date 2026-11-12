import io, contextlib, numpy as np, pandas as pd
with contextlib.redirect_stdout(io.StringIO()):
    import pattern_fix_test as P
sd=P.sd; t,o,h,l,c,atr,n=sd.t,sd.o,sd.h,sd.l,sd.c,sd.atr,sd.n
U=P.U.copy(); cut=P.cut
day=t//86400
# day range so far (server day) at each bar
df=pd.DataFrame({'d':day,'h':h,'l':l})
hi=df.groupby('d').h.cummax().values; lo=df.groupby('d').l.cummin().values
rng_sofar=(hi-lo)*100
# full-day ranges, previous 20 days median (known before today)
dr=df.groupby('d').agg(H=('h','max'),L=('l','min')); dr['r']=(dr.H-dr.L)*100
med20=dr.r.shift(1).rolling(20).median()
med_today=pd.Series(day).map(med20).values
hour=(t%86400)//3600
# expected fraction of day range done by this hour (from history) -> normalise range so far
U['rng']=rng_sofar[U.i]; U['rng_rel']=U.rng/med_today[U.i]
U['atr_p']=atr[U.i]*100
U['atr_rel']=atr[U.i]/pd.Series(atr).rolling(288*10).median().values[U.i]   # vs 10-day median
def eff(i,N): return abs(c[i]-c[i-N])/np.sum(np.abs(np.diff(c[i-N:i+1])))
U['eff24']=[eff(i,24) for i in U.i]; U['eff72']=[eff(i,72) for i in U.i]
U['box_p']=[(h[i-12:i].max()-l[i-12:i].min())*100 for i in U.i]
U['hour']=hour[U.i]
# range so far relative to what is normal BY THIS HOUR
tmp=pd.DataFrame({'d':day,'hr':hour,'r':rng_sofar})
byhr=tmp.groupby(['d','hr']).r.last().reset_index()
byhr['norm']=byhr.groupby('hr').r.transform(lambda s:s.shift(1).rolling(20).median())
key=dict(zip(zip(byhr.d,byhr.hr),byhr.norm))
U['rng_hr']=[rng_sofar[i]/key.get((day[i],hour[i]),np.nan) for i in U.i]
def show(col,qs=(0,.25,.5,.75,1.0)):
    v=U[col]; edges=v.quantile(list(qs)).values
    print(f"\n{col}:")
    for a,b in zip(edges[:-1],edges[1:]):
        m=(v>=a)&(v<=b)
        tr=U[m&(U.i<cut)]; te=U[m&(U.i>=cut)]
        print(f"  {a:7.2f} .. {b:7.2f}   train {tr.w20.mean()*100:5.1f}% (n={len(tr):3d})   test {te.w20.mean()*100:5.1f}% (n={len(te):3d})")
print("baseline train %.1f%%  test %.1f%%   (break-even 33%%)"%(U[U.i<cut].w20.mean()*100,U[U.i>=cut].w20.mean()*100))
for col in ('rng_hr','rng','atr_p','atr_rel','box_p','eff24','eff72'): show(col)

