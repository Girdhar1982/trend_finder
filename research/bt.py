"""Backtest engine for the USDJPY M5/M15 rule book.  Run with: python -I bt.py <command>

Costs: every trade pays COST_PIPS on entry (spread + slippage).  If SL and TP are both inside
one bar the SL is assumed to hit first (pessimistic).  Server time = New York + 7h, so the
server calendar day rolls at 17:00 New York, which is also the FX trading-day roll.
"""
import numpy as np, pandas as pd

PIP = 0.01
COST_PIPS = 1.2


def wma(x, n):
    w = np.arange(1, n + 1, dtype=float)
    out = np.full(len(x), np.nan)
    if len(x) >= n:
        c = np.convolve(x, w[::-1], mode="valid") / w.sum()
        out[n - 1:] = c
    return out


def hma(x, n):
    h = wma(x, n // 2) * 2 - wma(x, n)
    h2 = np.where(np.isnan(h), 0.0, h)
    out = wma(h2, int(round(np.sqrt(n))))
    out[: n + int(np.sqrt(n))] = np.nan
    return out


def rsi(c, n=14):
    d = np.diff(c, prepend=c[0])
    up = pd.Series(np.clip(d, 0, None)).ewm(alpha=1 / n, adjust=False).mean()
    dn = pd.Series(np.clip(-d, 0, None)).ewm(alpha=1 / n, adjust=False).mean()
    return (100 - 100 / (1 + up / dn.replace(0, np.nan))).to_numpy()


def atr(h, l, c, n=14):
    pc = np.roll(c, 1); pc[0] = c[0]
    tr = np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))
    return pd.Series(tr).rolling(n).mean().to_numpy()


def load(tf):
    d = pd.read_pickle(f"usdjpy_{tf}.pkl").reset_index(drop=True)
    return d


def features(tf="M15", htf="H1", htf_hours=1):
    d = load(tf)
    c = d.close.to_numpy(); h = d.high.to_numpy(); l = d.low.to_numpy()
    d["atr"] = atr(h, l, c)
    d["rsi"] = rsi(c)
    s = pd.Series(c)
    d["bbm"] = s.rolling(20).mean()
    sd = s.rolling(20).std(ddof=0)
    d["bbu"] = d.bbm + 2 * sd
    d["bbl"] = d.bbm - 2 * sd
    d["bbw"] = (d.bbu - d.bbl) / d.bbm
    hm = hma(c, 20)
    d["hma"] = hm
    slope = np.diff(hm, prepend=np.nan)
    thr = 0.05 * d.atr.to_numpy()
    d["hdir"] = np.where(slope > thr, 1, np.where(slope < -thr, -1, 0))
    # higher-timeframe Hull, only from CLOSED htf bars
    g = load(htf)
    gh = hma(g.close.to_numpy(), 20)
    gs = np.diff(gh, prepend=np.nan)
    ga = atr(g.high.to_numpy(), g.low.to_numpy(), g.close.to_numpy())
    g["hdir_htf"] = np.where(gs > 0.05 * ga, 1, np.where(gs < -0.05 * ga, -1, 0))
    g["avail"] = g.time + pd.Timedelta(hours=htf_hours)
    bar = pd.Timedelta(minutes=int(tf[1:]) * (1 if tf[0] == "M" else 60))
    d["bar_close"] = d.time + bar
    d = pd.merge_asof(d.sort_values("bar_close"), g[["avail", "hdir_htf"]].sort_values("avail"),
                      left_on="bar_close", right_on="avail", direction="backward")
    d["day"] = d.time.dt.floor("D")
    day = d.groupby("day").agg(dh=("high", "max"), dl=("low", "min"))
    day = day.shift(1)
    d = d.join(day, on="day")
    d["hour"] = d.time.dt.hour + d.time.dt.minute / 60
    d = d.reset_index(drop=True)
    d["ob_bear"], d["ob_bull"] = order_blocks(d)
    return d


def order_blocks(d, impulse=1.2, struct=10, maxback=6, maxage=96):
    """Same definition as Order_Blocks.mq5.  Returns, per bar, whether the bar's range reached an
    ACTIVE bearish / bullish OB (zone created on an earlier bar, not yet closed through)."""
    o = d.open.to_numpy(); h = d.high.to_numpy(); l = d.low.to_numpy(); c = d.close.to_numpy()
    a = d.atr.to_numpy(); n = len(d)
    bear = []; bull = []            # [top, bot, created_idx]
    t_bear = np.zeros(n, bool); t_bull = np.zeros(n, bool)
    for i in range(struct + maxback + 2, n):
        # touches use zones created BEFORE this bar
        bear = [z for z in bear if i - z[2] <= maxage]
        bull = [z for z in bull if i - z[2] <= maxage]
        for z in bear:
            if h[i] >= z[1]: t_bear[i] = True
        for z in bull:
            if l[i] <= z[0]: t_bull[i] = True
        bear = [z for z in bear if c[i] <= z[0]]      # mitigated when a close goes through
        bull = [z for z in bull if c[i] >= z[1]]
        body = c[i] - o[i]
        if np.isnan(a[i]) or abs(body) < impulse * a[i]:
            continue
        if body > 0 and c[i] > h[i - struct:i].max():
            for j in range(i - 1, i - maxback - 1, -1):
                if c[j] < o[j]:
                    bull.append([h[j], l[j], i]); break
        elif body < 0 and c[i] < l[i - struct:i].min():
            for j in range(i - 1, i - maxback - 1, -1):
                if c[j] > o[j]:
                    bear.append([h[j], l[j], i]); break
    return t_bear, t_bull


def signals(d, p):
    """Returns array: +1 buy, -1 sell, 0 none, evaluated on bar close."""
    n = len(d)
    c = d.close.to_numpy(); h = d.high.to_numpy(); l = d.low.to_numpy()
    r = d.rsi.to_numpy(); bbm = d.bbm.to_numpy(); a = d.atr.to_numpy()
    hd = d.hdir.to_numpy(); hh = d.hdir_htf.to_numpy()
    N = p["pull_bars"]
    sig = np.zeros(n, dtype=int)
    hi_touch = pd.Series(h >= bbm).rolling(N).max().to_numpy() > 0       # bar(s) reached/above middle band
    lo_touch = pd.Series(l <= bbm).rolling(N).max().to_numpy() > 0
    rmax = pd.Series(r).rolling(N).max().to_numpy()
    rmin = pd.Series(r).rolling(N).min().to_numpy()
    ok = ~np.isnan(a) & ~np.isnan(r) & ~np.isnan(bbm) & ~np.isnan(hd) & ~np.isnan(hh)
    ok &= a / PIP >= p["min_atr_pips"]
    hr = d.hour.to_numpy()
    ok &= (hr >= p["h0"]) & (hr < p["h1"])
    sell = ok & (hd == -1) & (c < bbm) & hi_touch & (rmax >= p["rsi_pull"]) & (r < p["rsi_trig"]) & (r > p["rsi_floor"])
    buy = ok & (hd == 1) & (c > bbm) & lo_touch & (rmin <= 100 - p["rsi_pull"]) & (r > 100 - p["rsi_trig"]) & (r < 100 - p["rsi_floor"])
    if p.get("htf", True):
        sell &= hh == -1
        buy &= hh == 1
    if p.get("ob", 0):
        tb = pd.Series(d.ob_bear.to_numpy()).rolling(N).max().to_numpy() > 0
        tl = pd.Series(d.ob_bull.to_numpy()).rolling(N).max().to_numpy() > 0
        if p["ob"] == 1:      # confluence: pullback must also have touched an order block
            sell &= tb; buy &= tl
        else:                 # OB replaces the band-middle pullback as the location rule
            base = ok & (c < bbm) if False else ok
            sell = base & (hd == -1) & tb & (c < bbm) & (r < p["rsi_trig"]) & (r > p["rsi_floor"])
            buy = base & (hd == 1) & tl & (c > bbm) & (r > 100 - p["rsi_trig"]) & (r < 100 - p["rsi_floor"])
            if p.get("htf", True):
                sell &= hh == -1; buy &= hh == 1
    if p.get("use_pdhl", True):  # no entry that runs straight into yesterday's high/low
        room = p["room_atr"] * a
        dl = d.dl.to_numpy(); dh = d.dh.to_numpy()
        sell &= ~(c - dl < room) | np.isnan(dl)
        buy &= ~(dh - c < room) | np.isnan(dh)
    if not p.get("use_hull", True):
        pass
    sig[buy] = 1
    sig[sell] = -1
    return sig


def simulate(d, sig, p):
    o = d.open.to_numpy(); h = d.high.to_numpy(); l = d.low.to_numpy(); c = d.close.to_numpy()
    a = d.atr.to_numpy(); day = d.day.to_numpy(); t = d.time.to_numpy()
    n = len(d); cost = COST_PIPS * PIP
    trades = []
    free = 0
    per_day = {}
    losses_day = {}
    for i in np.flatnonzero(sig != 0):
        if i + 1 >= n or i + 1 < free:
            continue
        dd = day[i + 1]
        if per_day.get(dd, 0) >= p["max_day"] or losses_day.get(dd, 0) >= p["max_loss_day"]:
            continue
        side = sig[i]
        entry = o[i + 1] + cost * side            # worse fill: buy higher / sell lower
        risk = p["sl_atr"] * a[i]
        sl = o[i + 1] - side * risk
        tp = o[i + 1] + side * p["tp_atr"] * a[i]
        res = None
        for j in range(i + 1, min(n, i + 1 + p["max_hold"])):
            hit_sl = l[j] <= sl if side == 1 else h[j] >= sl
            hit_tp = h[j] >= tp if side == 1 else l[j] <= tp
            if hit_sl:
                res = (sl, j, "SL"); break
            if hit_tp:
                res = (tp, j, "TP"); break
        if res is None:
            j = min(n - 1, i + p["max_hold"]); res = (c[j], j, "TIME")
        px, j, why = res
        pnl = (px - entry) * side / PIP
        trades.append(dict(time=t[i + 1], side=side, pnl=pnl, why=why, bars=j - i, day=dd))
        per_day[dd] = per_day.get(dd, 0) + 1
        if pnl < 0:
            losses_day[dd] = losses_day.get(dd, 0) + 1
        free = j + 1
    return pd.DataFrame(trades)


def stats(tr, ndays):
    if len(tr) == 0:
        return dict(n=0, win=np.nan, exp=np.nan, pf=np.nan, net=0, perday=0, maxdd=0)
    w = tr.pnl[tr.pnl > 0].sum(); lo = -tr.pnl[tr.pnl < 0].sum()
    cum = tr.pnl.cumsum()
    return dict(n=len(tr), win=(tr.pnl > 0).mean() * 100, exp=tr.pnl.mean(),
                pf=w / lo if lo > 0 else np.inf, net=tr.pnl.sum(), perday=len(tr) / ndays,
                maxdd=(cum.cummax() - cum).max())


BASE = dict(pull_bars=6, rsi_pull=50, rsi_trig=50, rsi_floor=30, min_atr_pips=6, h0=3, h1=19,
            sl_atr=1.5, tp_atr=1.0, max_hold=16, max_day=5, max_loss_day=3, htf=True,
            use_pdhl=True, room_atr=0.5)


def run(d, **kw):
    p = {**BASE, **kw}
    return simulate(d, signals(d, p), p), p
