"""
Improvement study for the M15 no-wick retest rule (research/nowick_monitor.py).
A) exit / stop variants (re-simulated)   B) feature slices of the base rule's filled trades.
Train = first 60% of bars, test = last 40%.  A slice is only 'consistent' if avgR > +0.05 in BOTH halves with n >= 60 each.
Usage: python research/nowick_improve.py   (run from repo root)
"""
import numpy as np
import pandas as pd
import MetaTrader5 as mt5
import nowick_monitor as nm
import htf_direction as hd


def run(d, pip, **kw):
    e = nm.Engine(pip, **kw)
    e.prep(d)
    for i in range(60, len(d) - 1):
        e.step(d, i)
    T = pd.DataFrame(e.trades)
    F = T[T.outcome != "EXPIRED"].copy()
    return T, F


def htf_at(series, d, minutes):
    s = series.sort_index()
    idx = s.index.searchsorted(d.time + pd.Timedelta(minutes=minutes), side="right") - 1
    return np.where(idx >= 0, s.values[np.clip(idx, 0, None)], 0)


def line(name, F, cut, T=None):
    tr, te = F[F.sig_i < cut], F[F.sig_i >= cut]
    fill = f"{100*len(F)/len(T):4.0f}%" if T is not None else "     "
    return (f"{name:34} n={len(F):4d} fill {fill}  win {100*(F.r>0).mean():4.1f}%  avgR {F.r.mean():+.3f}  "
            f"train {tr.r.mean():+.3f} (n={len(tr)})  test {te.r.mean():+.3f} (n={len(te)})  totR {F.r.sum():+.0f}")


def main():
    mt5.initialize()
    info = mt5.symbol_info("USDJPY")
    pip = info.point * 10
    d = nm.load("USDJPY")
    n = len(d)
    cut = int(n * 0.6)
    print(f"USDJPY M15 {d.time.iloc[0]:%Y-%m-%d}..{d.time.iloc[-1]:%Y-%m-%d} {n} bars, split at {d.time.iloc[cut]:%Y-%m-%d}")

    print("\nA) EXIT / STOP VARIANTS (base rule otherwise)")
    base_T, base_F = run(d, pip)
    print(line("base: swing stop, TP 1R", base_F, cut, base_T))
    for m in (0.5, 0.75, 1.5, 2.0, 3.0):
        T, F = run(d, pip, tp_mult=m)
        print(line(f"swing stop, TP {m}R", F, cut, T))
    for a in (0.8, 1.2, 1.6, 2.4):
        for m in (1.0, 1.5):
            T, F = run(d, pip, sl_atr=a, tp_mult=m)
            print(line(f"stop {a} ATR, TP {m}R", F, cut, T))
    T, F = run(d, pip, wait=5)
    print(line("wait 5 candles", F, cut, T))
    T, F = run(d, pip, min_body=1.0)
    print(line("body >= 1.0 ATR", F, cut, T))
    T, F = run(d, pip, min_body=1.5)
    print(line("body >= 1.5 ATR", F, cut, T))
    T, F = run(d, pip, ema_n=100)
    print(line("trend EMA100", F, cut, T))
    T, F = run(d, pip, ema_n=20)
    print(line("trend EMA20", F, cut, T))

    # ---- features for the base trades
    F = base_F.copy()
    i = F.sig_i.values
    o, h, l, c = d.open.values, d.high.values, d.low.values, d.close.values
    atr = d.atr.values
    F["hour"] = d.time.dt.hour.values[i]
    F["body_atr"] = F.body / F.atr
    F["risk_atr"] = F.risk / F.atr
    F["ema_dist"] = F.side * (c[i] - d.ema.values[i]) / atr[i]
    va = d.tick_volume.rolling(20).mean().shift(1).values
    F["vol"] = d.tick_volume.values[i] / va[i]
    hi20 = pd.Series(h).rolling(20).max().shift(1).values
    lo20 = pd.Series(l).rolling(20).min().shift(1).values
    F["break20"] = np.where(F.side > 0, c[i] > hi20[i], c[i] < lo20[i])
    f = np.floor(c[i])
    F["fig_p"] = np.minimum(c[i] - f, f + 1 - c[i]) * 100
    h4, _ = hd.htf_dir(d, "4h", 20, 3)
    d1, _ = hd.htf_dir(d, "1D", 20, 3)
    F["h4"] = F.side * htf_at(h4, d, 15)[i]
    F["d1"] = F.side * htf_at(d1, d, 15)[i]
    F["dow"] = d.time.dt.dayofweek.values[i]

    print("\nB) SLICES of the base rule's filled trades (avgR train / test)")

    def sl(title, groups):
        print(f"\n  {title}")
        for name, m in groups:
            g = F[m]
            tr, te = g[g.sig_i < cut], g[g.sig_i >= cut]
            if len(g) < 25:
                continue
            ok = len(tr) >= 60 and len(te) >= 60 and tr.r.mean() > .05 and te.r.mean() > .05
            print(f"    {name:26} n={len(g):4d} win {100*(g.r>0).mean():4.1f}% avgR {g.r.mean():+.3f}  "
                  f"train {tr.r.mean():+.3f}/{len(tr):3d}  test {te.r.mean():+.3f}/{len(te):3d} {'<-- both halves +' if ok else ''}")
    sl("server hour", [("00-06 Asia", F.hour < 7), ("07-11 London", (F.hour >= 7) & (F.hour < 12)),
                       ("12-16 London/NY", (F.hour >= 12) & (F.hour < 17)), ("17-23 NY/late", F.hour >= 17)])
    sl("body size (ATR)", [("0.7-1.0", F.body_atr < 1.0), ("1.0-1.5", (F.body_atr >= 1.0) & (F.body_atr < 1.5)), (">=1.5", F.body_atr >= 1.5)])
    sl("stop size in ATR", [("< 1.5 ATR", F.risk_atr < 1.5), ("1.5-3", (F.risk_atr >= 1.5) & (F.risk_atr < 3)), (">= 3 ATR", F.risk_atr >= 3)])
    q = F.ema_dist.quantile([.33, .66]).values
    sl("distance from EMA50 (ATR)", [(f"near < {q[0]:.1f}", F.ema_dist < q[0]), (f"mid {q[0]:.1f}-{q[1]:.1f}", (F.ema_dist >= q[0]) & (F.ema_dist < q[1])),
                                     (f"stretched >= {q[1]:.1f}", F.ema_dist >= q[1])])
    sl("signal volume vs 20-bar avg", [("< 0.8x", F.vol < .8), ("0.8-1.3x", (F.vol >= .8) & (F.vol < 1.3)), (">= 1.3x", F.vol >= 1.3)])
    sl("candle breaks 20-bar high/low", [("breakout candle", F.break20), ("inside range", ~F.break20)])
    sl("H4 trend vs trade (+1 with)", [("H4 with trade", F.h4 == 1), ("H4 against", F.h4 == -1), ("H4 mixed", F.h4 == 0)])
    sl("D1 trend vs trade", [("D1 with trade", F.d1 == 1), ("D1 against", F.d1 == -1), ("D1 mixed", F.d1 == 0)])
    sl("near whole figure", [("within 10p of .00", F.fig_p <= 10), ("farther", F.fig_p > 10)])
    sl("side", [("BUY", F.side > 0), ("SELL", F.side < 0)])
    sl("weekday", [(nm_, F.dow == k) for k, nm_ in enumerate(["Mon", "Tue", "Wed", "Thu", "Fri"])])
    F.to_pickle("research/nowick_improve_trades.pkl")


if __name__ == "__main__":
    main()
