"""List sudden big M5 candles: range >= K x ATR(14, bars before), recent days. Classify by where it closed."""
import sys, datetime as dt, numpy as np, pandas as pd, MetaTrader5 as mt5
K = float(sys.argv[1]) if len(sys.argv) > 1 else 2.5
DAYS = int(sys.argv[2]) if len(sys.argv) > 2 else 14
mt5.initialize()
d = pd.DataFrame(mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 99000))
t = d.time.values.astype("int64"); o, h, l, c = (d[k].values for k in ("open", "high", "low", "close")); n = len(c)
pc = np.r_[c[0], c[:-1]]
tr = np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))
atr = pd.Series(tr).rolling(14).mean().shift(1).values          # ATR of the bars BEFORE
rng12 = pd.Series(h).rolling(12).max().shift(1).values - pd.Series(l).rolling(12).min().shift(1).values
ts = lambda i: dt.datetime.fromtimestamp(int(t[i]), dt.timezone.utc).strftime("%Y-%m-%d %a %H:%M")
x = tr / atr
ev = np.nonzero(x >= K)[0]
print(f"bars >= {K} x ATR: {len(ev)} in {n} bars = {len(ev)/((t[-1]-t[0])/86400*5/7):.1f}/day")
for i in ev[ev > 0]:
    if t[i] < t[-1] - DAYS * 86400 or i + 6 >= n: continue
    rngp = (h[i] - l[i]) * 100
    dn = c[i] < o[i]
    pos = (c[i] - l[i]) / (h[i] - l[i])                     # 0 = closed at low, 1 = at high
    kind = ("DOWN" if dn else "UP  ") + (" REJECT (long wick, closed back)" if (dn and pos > 0.4) or (not dn and pos < 0.6) else " IMPULSE (closed near extreme)")
    after = (c[i + 6] - c[i]) * 100
    print(f" {ts(i)}  range {rngp:5.1f}p = {x[i]:4.1f}xATR  prior 1h range {rng12[i]*100:5.1f}p  close at {pos:4.0%} of bar  {kind}  next 30min {after:+5.1f}p")
