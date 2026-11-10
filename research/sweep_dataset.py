"""
Build a dataset of every liquidity SWEEP / RETEST of a prior extreme on USDJPY M5 (server time), long and short
(short = mirror via negated prices), with features known AT the signal bar close and forward labels.

Candidate at bar k (long version):
  lvl  = lowest low of bars [k-LB, k-3]          (prior swing low / liquidity pool)
  sweep : low[k] < lvl - 0.05*ATR  and close[k] > lvl     (wick through the level, closed back above)
  retest: |low[k]-lvl| <= 0.30*ATR (no break) and bullish close
Entry = close[k].  Stop = low[k]-0.2*ATR, risk clamped to [0.7,2.5] ATR.
Labels (path simulated with M5 bars, stop first on ties, 72 bars max):
  mfe_r  = best R reached before the stop was hit
  r36    = R at 36 bars if not stopped, else -1
usage: imported by sweep_features.py ; run directly to write sweep_dataset.pkl
"""
import numpy as np, pandas as pd, MetaTrader5 as mt5

PIP = 0.01
mt5.initialize(); mt5.symbol_select("USDJPY", True)
r = mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 50000)
t = r['time'].astype('int64')
o, h, l, c = (r[k].astype(float) for k in ('open', 'high', 'low', 'close'))
v = r['tick_volume'].astype(float); sp = r['spread'].astype(float) * 0.001
n = len(r)
hour = ((t % 86400) // 3600).astype(int); dow = ((t // 86400 + 3) % 7).astype(int)   # Mon=0

s = pd.Series
pc = np.r_[c[0], c[:-1]]
tr = np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))
atr = s(tr).rolling(14).mean().values
atr_med = s(atr).rolling(576).median().values
vavg = s(v).rolling(20).mean().values
ema288 = s(c).ewm(span=288, adjust=False).mean().values
ema48 = s(c).ewm(span=48, adjust=False).mean().values
day = t // 86400
# previous-day high/low (server day)
dd = pd.DataFrame({'day': day, 'h': h, 'l': l}).groupby('day').agg(H=('h', 'max'), L=('l', 'min'))
pdh = pd.Series(day).map(dd['H'].shift(1)).values; pdl = pd.Series(day).map(dd['L'].shift(1)).values
# server-day open (00:00) -> "Asia range so far"
day_open = pd.Series(o).groupby(day).transform('first').values

LBS = (24, 48, 96)
MAXB = 72


def build():
    rows = []
    for sign in (1, -1):
        O, H, L, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
        EMA288 = ema288 * sign; EMA48 = ema48 * sign
        PDL = (pdl if sign > 0 else -pdh); PDH = (pdh if sign > 0 else -pdl)
        last_sig = -99
        for k in range(600, n - MAXB - 1):
            a = atr[k]
            if np.isnan(a) or k - last_sig < 6: continue
            best = None
            for LB in LBS:
                lvl = L[k - LB:k - 2].min()
                depth = (lvl - L[k]) / a
                kind = None
                if depth > 0.05 and C[k] > lvl: kind = 'sweep'
                elif abs(L[k] - lvl) <= 0.30 * a and C[k] > O[k] and C[k] > lvl: kind = 'retest'
                if kind and (best is None or (kind == 'sweep' and best[1] != 'sweep')): best = (LB, kind, lvl, depth)
                if kind == 'sweep': break
            if best is None: continue
            LB, kind, lvl, depth = best
            if kind == 'retest' and C[k] <= O[k]: continue
            entry = C[k]
            risk = min(max(entry - (L[k] - 0.2 * a), 0.7 * a), 2.5 * a)
            stop = entry - risk
            mfe = 0.0; r36 = None; hit = False
            for j in range(k + 1, k + MAXB + 1):
                if L[j] <= stop: hit = True; break
                mfe = max(mfe, (H[j] - entry) / risk)
                if j == k + 36: r36 = (C[j] - entry) / risk
            if r36 is None: r36 = -1.0 if hit else (C[k + 36] - entry) / risk
            r36 = -1.0 if (hit and j <= k + 36) else r36
            top48 = H[k - 48:k].max()
            touches = int((np.abs(L[k - LB:k - 2] - lvl) <= 0.3 * a).sum())
            rng = H[k] - L[k]
            rows.append(dict(
                t=t[k], k=k, sign=sign, kind=kind, LB=LB, hour=hour[k], dow=dow[k],
                depth=max(depth, 0.0), volx=v[k] / vavg[k], closepos=(C[k] - L[k]) / rng if rng > 0 else 0.5,
                body=(C[k] - O[k]) / a, wick=(min(O[k], C[k]) - L[k]) / a,
                trend288=(C[k] - EMA288[k]) / a, trend48=(C[k] - EMA48[k]) / a,
                slope288=(EMA288[k] - EMA288[k - 36]) / a,
                drop=(top48 - lvl) / a, compress=(H[k - 24:k].max() - L[k - 24:k].min()) / a,
                touches=touches, atrx=a / atr_med[k], atr_pips=a / PIP,
                dist_pdl=(C[k] - PDL[k]) / a if not np.isnan(PDL[k]) else np.nan,
                dist_dayopen=((C[k] - day_open[k] * sign) / a),
                risk_atr=risk / a, mfe_r=mfe, r36=r36, stopped=hit,
                mfe_pips=mfe * risk / PIP))
            last_sig = k
    return pd.DataFrame(rows)


if __name__ == '__main__':
    df = build()
    df.to_pickle('sweep_dataset.pkl')
    print(len(df), df.kind.value_counts().to_dict(), df.sign.value_counts().to_dict())
    print("base rates  reach>=2R before stop:", (df.mfe_r >= 2).mean().round(3), " >=3R:", (df.mfe_r >= 3).mean().round(3),
          " mean r36:", df.r36.mean().round(3))
