"""
Confirm vs early entry (12 Nov 2026 lesson).

EARLY   : buy the close of a bar that makes a new 2h (24-bar) low   (= buying while it still falls)
CHOCH   : after a new 2h low, first close above the last confirmed pivot high (within 24 bars)
HL      : two pivot lows, the 2nd >= the 1st - 0.2 ATR, then a close above the high between them
          (within 24 bars of the 2nd pivot, 2nd low not broken)
Sell = mirror. Fill next open (+spread for buys), stop = structure low - 1 pip,
exit: TP +20 pips / stop / 36 bars (3h) at close. Spacing >= 6 bars per detector/side.
Train = first 60% of days, test = last 40%.
Usage: python research/confirm_vs_early.py
"""
import datetime as dt
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PIP = 0.01
PW = 3            # pivot half-width (as indicator)
N2H = 24
WITHIN = 24
TP = 20.0
HOLD = 36
GAP = 6


def load():
    mt5.initialize()
    r = mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 99000)
    d = pd.DataFrame(r)
    d["time"] = pd.to_datetime(d.time, unit="s")
    return d.reset_index(drop=True)


def atr(d, n=14):
    pc = d.close.shift(1).fillna(d.close)
    tr = np.maximum(d.high - d.low, np.maximum((d.high - pc).abs(), (d.low - pc).abs()))
    return tr.rolling(n).mean().values


def signals(o, h, l, c, a, s):
    """s=+1 buy on raw arrays; for sells pass transformed arrays (o,h,l,c) -> (-o,-l,-h,-c)."""
    n = len(c)
    out = {"EARLY": [], "CHOCH": [], "HL": []}
    last = {k: -1000 for k in out}
    piv_lo = []          # (bar, low)
    last_ph = None       # last confirmed pivot high value
    low2h_bar, low2h = -1000, None
    ch_used = -1
    hl_used = -1
    for i in range(30, n - 1):
        j = i - PW
        if l[j] == l[j - PW:j + PW + 1].min():
            piv_lo.append((j, l[j]))
        if h[j] == h[j - PW:j + PW + 1].max():
            last_ph = h[j]
        if l[i] <= l[i - N2H + 1:i + 1].min():
            if i - low2h_bar > 1 and i - last["EARLY"] >= GAP:
                out["EARLY"].append((i, l[i - 2:i + 1].min()))   # stop under the last 3 bars
                last["EARLY"] = i
            low2h_bar, low2h = i, l[i]
        # CHOCH
        if (last_ph is not None and i - low2h_bar <= WITHIN and c[i] > last_ph and c[i - 1] <= last_ph
                and i - last["CHOCH"] >= GAP and ch_used != low2h_bar):
            out["CHOCH"].append((i, l[low2h_bar:i + 1].min()))
            last["CHOCH"] = i
            ch_used = low2h_bar
        # HL
        if len(piv_lo) >= 2:
            (b1, p1), (b2, p2) = piv_lo[-2], piv_lo[-1]
            if (p2 >= p1 - 0.2 * a[b2] and b2 > b1 + 1 and i - b2 <= WITHIN and hl_used != b2
                    and l[b2:i + 1].min() >= p2 and i - last["HL"] >= GAP):
                H = h[b1:b2 + 1].max()
                if c[i] > H and c[i - 1] <= H:
                    out["HL"].append((i, min(p1, p2)))
                    last["HL"] = i
                    hl_used = b2
    return out


def trade(i, stop, s, d):
    """returns pips for direction s (+1 buy / -1 sell), stop given in raw price."""
    o, h, l, c, sp = d.open.values, d.high.values, d.low.values, d.close.values, d.spread.values * 0.001
    e = i + 1
    if e >= len(o):
        return None
    entry = o[e] + (sp[e] if s > 0 else 0.0)
    stop = stop - PIP if s > 0 else stop + PIP
    risk = (entry - stop) * s / PIP
    if risk <= 0.5:
        return None
    tp = entry + s * TP * PIP
    for k in range(e, min(e + HOLD, len(o))):
        bid_lo, bid_hi = l[k], h[k]
        if s > 0:
            if bid_lo <= stop:
                return -risk, risk
            if bid_hi >= tp:
                return TP, risk
        else:
            ask_hi, ask_lo = bid_hi + sp[k], bid_lo + sp[k]
            if ask_hi >= stop:
                return -risk, risk
            if ask_lo <= tp:
                return TP, risk
    k = min(e + HOLD, len(o)) - 1
    px = c[k] if s > 0 else c[k] + sp[k]
    return (px - entry) * s / PIP, risk


def main():
    d = load()
    a = atr(d)
    o, h, l, c = d.open.values, d.high.values, d.low.values, d.close.values
    days = d.time.dt.normalize()
    ud = days.unique()
    cut = ud[int(len(ud) * 0.6)]
    print(f"data {d.time.iloc[0]} .. {d.time.iloc[-1]}  ({len(ud)} days, test from {cut.date()})")
    rows = []
    for s, arrs in ((1, (o, h, l, c)), (-1, (-o, -l, -h, -c))):
        sig = signals(*arrs, a, s)
        for name, lst in sig.items():
            for i, st in lst:
                r = trade(i, st * s, s, d)   # transform the stop back to raw price
                if r is None:
                    continue
                rows.append(dict(t=d.time[i], kind=name, side="BUY" if s > 0 else "SELL",
                                 pips=r[0], risk=r[1], win=r[0] >= TP, test=days[i] >= cut))
    R = pd.DataFrame(rows)
    nd_tr, nd_te = (ud < cut).sum(), (ud >= cut).sum()
    print(f"\nexit: TP +{TP:.0f} / structure stop / {HOLD} bars.  per side & period:")
    print(f"{'kind':6} {'side':5} {'part':5} {'n':>5} {'/day':>5} {'win%':>5} {'avg':>6} {'risk':>5} {'sum':>7}")
    for (k, sd, te), g in R.groupby(["kind", "side", "test"]):
        nd = nd_te if te else nd_tr
        print(f"{k:6} {sd:5} {'test' if te else 'train':5} {len(g):5d} {len(g)/nd:5.1f} {100*g.win.mean():5.0f} "
              f"{g.pips.mean():6.2f} {g.risk.median():5.1f} {g.pips.sum():7.0f}")
    print("\nboth sides:")
    for (k, te), g in R.groupby(["kind", "test"]):
        print(f"{k:6} {'test' if te else 'train':5} n={len(g):5d} win {100*g.win.mean():3.0f}%  avg {g.pips.mean():6.2f}p  "
              f"median stop {g.risk.median():4.1f}p")
    print("\nrisk-capped (only stops <= 12 pips):")
    for (k, te), g in R[R.risk <= 12].groupby(["kind", "test"]):
        print(f"{k:6} {'test' if te else 'train':5} n={len(g):5d} win {100*g.win.mean():3.0f}%  avg {g.pips.mean():6.2f}p")
    day = R[(R.t >= "2026-11-12") & (R.t < "2026-11-13") & (R.side == "BUY")]
    print("\n12 Nov BUY signals:")
    print(day[["t", "kind", "pips", "risk"]].to_string(index=False))
    R.to_pickle("research/confirm_vs_early.pkl")


if __name__ == "__main__":
    main()
