"""
Backtest of Sweep_Reclaim_Alert v4.60 additions.
Part 1: CONFIRM signals (same logic as the indicator / confirm_vs_early.py) - by month, several exits.
Part 2: the DON'T ADD guard and the WAIT state replayed on the user's real USDJPY deals.
Usage: python research/confirm_backtest.py
"""
import datetime as dt
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PIP, PW, N2H, WITHIN, GAP = 0.01, 3, 24, 24, 6


def load():
    mt5.initialize()
    d = pd.DataFrame(mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 99000))
    d["time"] = pd.to_datetime(d.time, unit="s")
    return d


def atr(d, n=14):
    pc = d.close.shift(1).fillna(d.close)
    tr = np.maximum(d.high - d.low, np.maximum((d.high - pc).abs(), (d.low - pc).abs()))
    return tr.rolling(n).mean().values


def confirm_state(h, l, c):
    """transformed arrays (buy side). returns signals [(i, stopT)] and per-bar state (kc_low, used, last, ph)."""
    n = len(c)
    kc_low, used, last, ph = -10**9, -1, -10**9, None
    sig, st = [], np.zeros((n, 3), dtype=np.int64)
    phs = np.full(n, np.nan)
    for i in range(30, n):
        j = i - PW
        if h[j] == h[j - PW:j + PW + 1].max():
            ph = h[j]
        if l[i] <= l[i - N2H + 1:i + 1].min():
            kc_low = i
        if (ph is not None and i - kc_low <= WITHIN and c[i] > ph and c[i - 1] <= ph and i - last >= GAP
                and used != kc_low):
            sig.append((i, l[kc_low:i + 1].min()))
            used, last = kc_low, i
        st[i] = (kc_low, used, last)
        phs[i] = np.nan if ph is None else ph
    return sig, st, phs


def run_exit(d, a, i, stop, s, mode):
    o, h, l, c = d.open.values, d.high.values, d.low.values, d.close.values
    sp = d.spread.values * 0.001
    e = i + 1
    if e >= len(o):
        return None
    entry = o[e] + (sp[e] if s > 0 else 0.0)
    stop = stop - PIP if s > 0 else stop + PIP
    risk = (entry - stop) * s / PIP
    if risk <= 0.5:
        return None
    hold = 36 if mode in ("tp20", "tp2r", "tp20_cap12") else 72
    if mode == "tp20_cap12" and risk > 12:
        return None
    tp = entry + s * (20 if mode != "tp2r" else 2 * risk) * PIP
    best = entry
    trail = stop
    for k in range(e, min(e + hold, len(o))):
        lo = l[k] if s > 0 else -(h[k] + sp[k])
        hi = h[k] if s > 0 else -(l[k] + sp[k])
        st_t = trail if s > 0 else -trail
        if lo <= st_t:
            return (trail - entry) * s / PIP, risk
        if mode != "trail3" and hi >= (tp if s > 0 else -tp):
            return (tp - entry) * s / PIP, risk
        if mode == "trail3":
            best = max(best, h[k]) if s > 0 else min(best, l[k] + sp[k])
            nt = best - s * 3 * a[k]
            trail = max(trail, nt) if s > 0 else min(trail, nt)
    k = min(e + hold, len(o)) - 1
    px = c[k] if s > 0 else c[k] + sp[k]
    return (px - entry) * s / PIP, risk


def part1(d, a):
    o, h, l, c = d.open.values, d.high.values, d.low.values, d.close.values
    days = d.time.dt.normalize()
    ud = days.unique()
    cut = ud[int(len(ud) * 0.6)]
    rng = np.random.default_rng(7)
    print(f"PART 1  CONFIRM signals  {d.time.iloc[0].date()} .. {d.time.iloc[-1].date()}  test from {cut.date()}")
    out = {}
    for s, arr in ((1, (h, l, c)), (-1, (-l, -h, -c))):
        sig, _, _ = confirm_state(*arr)
        out[s] = sig
    modes = ["tp20", "tp20_cap12", "tp2r", "trail3"]
    print(f"\n{'side':5} {'exit':11} {'n':>5} {'win%':>5} {'train':>7} {'test':>7} {'random tr/te':>14} {'stop':>5} {'maxDD':>6} {'mon+':>6}")
    allrows = {}
    for s in (1, -1):
        for mode in modes:
            rows = []
            for i, st in out[s]:
                r = run_exit(d, a, i, st * s, s, mode)
                if r:
                    rows.append((d.time[i], r[0], r[1], days[i] >= cut))
            R = pd.DataFrame(rows, columns=["t", "p", "risk", "te"])
            # random baseline: same entries' risk distribution, random bars
            rr = []
            for _ in range(len(R)):
                i = int(rng.integers(300, len(d) - 80))
                risk = float(R.risk.sample(1, random_state=int(rng.integers(1e9))).iloc[0])
                stp = (o[i + 1] - s * (risk - 1) * PIP)
                x = run_exit(d, a, i, stp, s, mode)
                if x:
                    rr.append((x[0], days[i] >= cut))
            RR = pd.DataFrame(rr, columns=["p", "te"])
            eq = R.p.cumsum()
            mdd = (eq - eq.cummax()).min()
            mon = R.groupby(R.t.dt.to_period("M")).p.sum()
            print(f"{'BUY' if s > 0 else 'SELL':5} {mode:11} {len(R):5d} {100*(R.p > 0).mean():5.0f} {R[~R.te].p.mean():7.2f} "
                  f"{R[R.te].p.mean():7.2f} {RR[~RR.te].p.mean():6.2f}/{RR[RR.te].p.mean():6.2f} {R.risk.median():5.1f} "
                  f"{mdd:6.0f} {(mon > 0).sum():2d}/{len(mon):2d}")
            allrows[(s, mode)] = R
    R = allrows[(1, "tp20")]
    print("\nCONFIRM BUY, TP20 exit - by month (pips):")
    m = R.groupby(R.t.dt.to_period("M")).agg(n=("p", "size"), pips=("p", "sum"), avg=("p", "mean"))
    print(m.round(1).to_string())
    return out


def part2(d):
    print("\nPART 2  your real USDJPY deals replayed against WAIT / DON'T ADD")
    deals = mt5.history_deals_get(dt.datetime(2024, 1, 1), dt.datetime.now() + dt.timedelta(days=2))
    D = pd.DataFrame(list(deals), columns=deals[0]._asdict().keys())
    D = D[D.symbol == "USDJPY"].copy()
    D["time"] = pd.to_datetime(D.time, unit="s")
    D["net"] = D.profit + D.commission + D.swap + D.fee
    pos = []
    for pid, g in D.groupby("position_id"):
        ein, eout = g[g.entry == 0], g[g.entry == 1]
        if len(ein) != 1 or eout.empty:
            continue
        e = ein.iloc[0]
        s = 1 if e.type == 0 else -1
        xp = (eout.price * eout.volume).sum() / eout.volume.sum()
        pos.append(dict(pid=pid, s=s, t_in=e.time, t_out=eout.time.max(), px=e.price, vol=e.volume,
                        pips=(xp - e.price) * s / PIP, money=g.net.sum()))
    P = pd.DataFrame(pos).sort_values("t_in").reset_index(drop=True)
    print(f"{len(P)} closed positions {P.t_in.min()} .. {P.t_in.max()}")
    h, l, c = d.high.values, d.low.values, d.close.values
    states = {}
    for s, arr in ((1, (h, l, c)), (-1, (-l, -h, -c))):
        _, st, phs = confirm_state(*arr)
        states[s] = st
    T = d.time
    rows = []
    for _, p in P.iterrows():
        bar = T.searchsorted(p.t_in, side="right") - 1
        L = bar - 1
        if L < 300 or bar >= len(d):
            continue
        kl, used, last = states[p.s][L]
        falling = (L - kl <= WITHIN) and used != kl
        opn = P[(P.s == p.s) & (P.t_in < p.t_in) & (P.t_out > p.t_in)]
        if opn.empty:
            kind = "fresh"
            flag = falling
        else:
            kind = "add"
            avg = (opn.px * opn.vol).sum() / opn.vol.sum()
            under = (p.px < avg) if p.s > 0 else (p.px > avg)
            ib = T.searchsorted(opn.t_in.max(), side="right") - 1
            flag = falling or (under and not (last >= ib))
        rows.append(dict(t=p.t_in, side="BUY" if p.s > 0 else "SELL", kind=kind, flag=flag, pips=p.pips, money=p.money))
    R = pd.DataFrame(rows)
    lab = {("fresh", True): "fresh entry during WAIT (falling)", ("fresh", False): "fresh entry, not falling",
           ("add", True): "add flagged DON'T ADD", ("add", False): "add allowed"}
    print(f"\n{'group':36} {'n':>4} {'win%':>5} {'avg pips':>9} {'sum pips':>9} {'money':>8}")
    for (k, f), g in R.groupby(["kind", "flag"]):
        print(f"{lab[(k, f)]:36} {len(g):4d} {100*(g.pips > 0).mean():5.0f} {g.pips.mean():9.1f} {g.pips.sum():9.1f} {g.money.sum():8.2f}")
    print("\nby side:")
    for (sd, k, f), g in R.groupby(["side", "kind", "flag"]):
        print(f"  {sd:4} {lab[(k, f)]:36} {len(g):4d} {100*(g.pips > 0).mean():5.0f} {g.pips.mean():8.1f} {g.money.sum():8.2f}")
    tot = R.money.sum()
    skip = R[R.flag].money.sum()
    print(f"\nall positions: {tot:.2f}   flagged ones: {skip:.2f}   -> skipping flagged would give {tot - skip:.2f}")
    print("\n12 Nov:")
    print(R[(R.t >= "2026-11-12") & (R.t < "2026-11-13")].to_string(index=False))
    R.to_pickle("research/confirm_backtest_trades.pkl")


if __name__ == "__main__":
    d = load()
    a = atr(d)
    part1(d, a)
    part2(d)
