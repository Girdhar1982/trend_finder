"""
Does higher-timeframe direction help?  (asked 13 Nov 2026)
HTF direction measures, each +1 up / -1 down / 0 mixed, from CLOSED HTF bars only (no look-ahead):
  H1_ema   : last closed H1 close vs H1 EMA50, and EMA50 rising/falling over 5 H1 bars
  H4_ema   : same on H4 with EMA20 over 3 bars
  D1_ema   : same on D1 with EMA20 over 3 bars
  H4_struct: last two H4 swing highs AND lows both higher (+1) / both lower (-1)  (2-bar pivots)
  D1_prev  : last closed D1 bar close above / below its open
  ALL3     : H1_ema, H4_ema, D1_ema agree
Applied to (1) CONFIRM signals (TP20 / structure stop / 36 bars, as confirm_backtest.py) and
(2) the user's real USDJPY positions.
Usage: python research/htf_direction.py
"""
import numpy as np
import pandas as pd
import confirm_backtest as cb


def htf_dir(d, rule, span, slope_n):
    x = d.set_index("time")[["open", "high", "low", "close"]].resample(rule, label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    e = x.close.ewm(span=span, adjust=False).mean()
    up = (x.close > e) & (e > e.shift(slope_n))
    dn = (x.close < e) & (e < e.shift(slope_n))
    v = pd.Series(np.where(up, 1, np.where(dn, -1, 0)), index=x.index)
    # value of an HTF bar is known only after it closes -> shift the timestamp to the bar's close
    v.index = v.index + pd.Timedelta(rule)
    return v, x


def struct_dir(x, rule):
    h, l = x.high.values, x.low.values
    n = len(x)
    out = np.zeros(n, dtype=int)
    ph, pl = [], []
    for i in range(4, n):
        j = i - 2
        if h[j] == h[j - 2:j + 3].max():
            ph.append(h[j])
        if l[j] == l[j - 2:j + 3].min():
            pl.append(l[j])
        if len(ph) >= 2 and len(pl) >= 2:
            if ph[-1] > ph[-2] and pl[-1] > pl[-2]:
                out[i] = 1
            elif ph[-1] < ph[-2] and pl[-1] < pl[-2]:
                out[i] = -1
    v = pd.Series(out, index=x.index + pd.Timedelta(rule))
    return v


def at_bars(series, times):
    """last known HTF value at each M5 bar CLOSE time (bar open + 5 min)."""
    s = series.sort_index()
    idx = s.index.searchsorted(times + pd.Timedelta("5min"), side="right") - 1
    vals = np.where(idx >= 0, s.values[np.clip(idx, 0, None)], 0)
    return vals


def main():
    d = cb.load()
    a = cb.atr(d)
    T = d.time
    h1, _ = htf_dir(d, "1h", 50, 5)
    h4, x4 = htf_dir(d, "4h", 20, 3)
    d1, xd = htf_dir(d, "1D", 20, 3)
    s4 = struct_dir(x4, "4h")
    dp = pd.Series(np.sign(xd.close - xd.open).astype(int).values, index=xd.index + pd.Timedelta("1D"))
    F = pd.DataFrame({"H1_ema": at_bars(h1, T), "H4_ema": at_bars(h4, T), "D1_ema": at_bars(d1, T),
                      "H4_struct": at_bars(s4, T), "D1_prev": at_bars(dp, T)})
    F["ALL3"] = np.where((F.H1_ema == F.H4_ema) & (F.H4_ema == F.D1_ema), F.H1_ema, 0)
    days = T.dt.normalize()
    ud = days.unique()
    cut = ud[int(len(ud) * 0.6)]
    print("share of M5 bars: up / down / mixed")
    for k in F:
        print(f"  {k:9} {100*(F[k] == 1).mean():4.0f}% {100*(F[k] == -1).mean():4.0f}% {100*(F[k] == 0).mean():4.0f}%")

    # ---- part 1: CONFIRM signals
    h, l, c = d.high.values, d.low.values, d.close.values
    rows = []
    for s, arr in ((1, (h, l, c)), (-1, (-l, -h, -c))):
        sig, _, _ = cb.confirm_state(*arr)
        for i, st in sig:
            r = cb.run_exit(d, a, i, st * s, s, "tp20")
            if r:
                rows.append(dict(i=i, s=s, p=r[0], te=days[i] >= cut, **{k: F[k].iat[i] * s for k in F}))
    R = pd.DataFrame(rows)
    print("\nPART 1  CONFIRM, TP20 exit. avg pips per trade (n). 'with' = HTF direction = trade direction")
    print(f"{'side':4} {'filter':9} | {'no filter tr/te':>18} | {'WITH HTF tr/te':>22} | {'AGAINST HTF tr/te':>22}")
    for s in (1, -1):
        g = R[R.s == s]
        base = f"{g[~g.te].p.mean():5.2f}/{g[g.te].p.mean():5.2f}"
        for k in F:
            w, ag = g[g[k] == 1], g[g[k] == -1]
            f = lambda q: f"{q[~q.te].p.mean():5.2f}/{q[q.te].p.mean():5.2f} ({len(q):4d})"
            print(f"{'BUY' if s > 0 else 'SELL':4} {k:9} | {base:>18} | {f(w):>22} | {f(ag):>22}")

    # ---- part 2: user's real positions
    import MetaTrader5 as mt5, datetime as dt
    deals = mt5.history_deals_get(dt.datetime(2024, 1, 1), dt.datetime.now() + dt.timedelta(days=2))
    D = pd.DataFrame(list(deals), columns=deals[0]._asdict().keys())
    D = D[D.symbol == "USDJPY"].copy()
    D["time"] = pd.to_datetime(D.time, unit="s")
    D["net"] = D.profit + D.commission + D.swap + D.fee
    P = []
    for pid, g in D.groupby("position_id"):
        ein, eout = g[g.entry == 0], g[g.entry == 1]
        if len(ein) != 1 or eout.empty:
            continue
        e = ein.iloc[0]
        s = 1 if e.type == 0 else -1
        xp = (eout.price * eout.volume).sum() / eout.volume.sum()
        bar = T.searchsorted(e.time, side="right") - 2      # last closed M5 bar at entry
        P.append(dict(t=e.time, s=s, pips=(xp - e.price) * s / cb.PIP, money=g.net.sum(),
                      **{k: F[k].iat[bar] * s for k in F}))
    P = pd.DataFrame(P)
    print(f"\nPART 2  your {len(P)} positions ({P.t.min().date()} .. {P.t.max().date()}): sum pips / money / win% / n")
    print(f"{'filter':9} | {'with HTF':>30} | {'against HTF':>30} | {'mixed':>30}")
    f2 = lambda q: f"{q.pips.sum():6.0f}p {q.money.sum():7.2f} {100*(q.pips > 0).mean():3.0f}% {len(q):3d}"
    for k in F:
        print(f"{k:9} | {f2(P[P[k] == 1]):>30} | {f2(P[P[k] == -1]):>30} | {f2(P[P[k] == 0]):>30}")
    print("\nby side (H4_ema):")
    for s in (1, -1):
        q = P[P.s == s]
        print(f"  {'BUY' if s > 0 else 'SELL':4} with {f2(q[q.H4_ema == 1])} | against {f2(q[q.H4_ema == -1])} | mixed {f2(q[q.H4_ema == 0])}")
    t12 = P[(P.t >= "2026-11-12") & (P.t < "2026-11-13")]
    print("\n12 Nov entries (+1 = with, -1 = against):")
    print(t12[["t", "s", "pips", "H1_ema", "H4_ema", "D1_ema", "H4_struct", "D1_prev"]].to_string(index=False))
    R.to_pickle("research/htf_confirm.pkl")


if __name__ == "__main__":
    main()
