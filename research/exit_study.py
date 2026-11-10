"""
Exit study, USDJPY M5 (server time).  Same entries, different exits.
 (A) the 7 real trades from the 5-6 Nov screenshot
 (B) E2 'reclaim' events from sweep_reclaim_study.py (hours 6-13 and all hours)
Every policy starts with an initial stop of 1.5*ATR (=1R) so risk is identical; only the exit differs.
Policies: ATR trail k (chandelier: highest high - k*ATR, ratchets up only, updated after each completed bar),
          swing trail N (lowest low of last N completed bars), fixed time stop, fixed target.
Costs: bar spread charged once. Stop fills at min(stop, bar open). usage: python -I exit_study.py
"""
import datetime as dt
import numpy as np
import MetaTrader5 as mt5

PIP, HMAX, R_ATR = 0.01, 144, 1.5
mt5.initialize(); mt5.symbol_select("USDJPY", True)
r = mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 50000)
t = r['time'].astype('int64')
o, h, l, c = (r[k].astype(float) for k in ('open', 'high', 'low', 'close'))
v = r['tick_volume'].astype(float); sp = r['spread'].astype(float) * 0.001
n = len(r); hour = ((t % 86400) // 3600).astype(int)
pc = np.r_[c[0], c[:-1]]
tr = np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))
atr = np.convolve(tr, np.ones(14) / 14, 'full')[:n]; atr[:14] = np.nan
tstr = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime('%m-%d %H:%M')

POLICIES = [("ATR trail 1.0", 'atr', 1.0), ("ATR trail 1.5", 'atr', 1.5), ("ATR trail 2.0", 'atr', 2.0),
            ("ATR trail 3.0", 'atr', 3.0), ("Swing trail 6 bars", 'swing', 6), ("Swing trail 12 bars", 'swing', 12),
            ("Swing trail 24 bars", 'swing', 24), ("Time stop 12 bars (1h)", 'time', 12),
            ("Time stop 36 bars (3h)", 'time', 36), ("Time stop 72 bars (6h)", 'time', 72),
            ("Target 1R", 'tp', 1.0), ("Target 2R", 'tp', 2.0), ("Target 3R", 'tp', 3.0)]


def run(O, H, L, C, i, entry, a, kind, p, cost):
    """long trade, entered at `entry` during bar i. returns (pips, bars_held). arrays may be sign-flipped."""
    risk = R_ATR * a; stop = entry - risk; hh = entry; end = min(n - 1, i + HMAX)
    tp = entry + p * risk if kind == 'tp' else None
    for j in range(i + 1, end + 1):
        if L[j] <= stop: return (min(stop, O[j]) - entry - cost) / PIP, j - i
        if tp is not None and H[j] >= tp: return (tp - entry - cost) / PIP, j - i
        if kind == 'time' and j - i >= p: return (C[j] - entry - cost) / PIP, j - i
        hh = max(hh, H[j])
        if kind == 'atr': stop = max(stop, hh - p * a)
        elif kind == 'swing' and j - i >= p: stop = max(stop, L[j - p + 1:j + 1].min())
    return (C[end] - entry - cost) / PIP, end - i


# ---------- (A) the real trades ----------
utc = dt.timezone.utc
real = [((2026, 11, 5, 7, 7, 7), 157.871, (2026, 11, 5, 9, 45, 38), 158.144),
        ((2026, 11, 5, 7, 59, 30), 157.898, (2026, 11, 5, 9, 45, 38), 158.144),
        ((2026, 11, 6, 9, 17, 50), 158.071, (2026, 11, 6, 10, 55, 54), 158.118),
        ((2026, 11, 6, 9, 23, 7), 157.959, (2026, 11, 6, 10, 51, 24), 158.053),
        ((2026, 11, 6, 9, 25, 42), 157.921, (2026, 11, 6, 10, 51, 24), 158.053),
        ((2026, 11, 6, 9, 30, 51), 157.862, (2026, 11, 6, 10, 51, 24), 158.053),
        ((2026, 11, 6, 9, 37, 28), 157.774, (2026, 11, 6, 10, 51, 24), 158.053)]
print("(A) YOUR 7 TRADES  (pips; stops are 1.5*ATR(14,M5) below entry, so the Nov 6 stack gets stopped out)")
tot = {nm: 0.0 for nm, _, _ in POLICIES}; tot['actual'] = 0.0; tot['peak'] = 0.0
hdr = f"{'entry':>12} {'price':>8} {'actual':>7} {'peak*':>6}" + "".join(f"{k:>7}" for k in ('A1.0', 'A1.5', 'A2.0', 'A3.0', 'S6', 'S12', 'S24', 'T1h', 'T3h', 'T6h', 'TP1', 'TP2', 'TP3'))
print(hdr)
for (e, ep, x, xp) in real:
    ts = dt.datetime(*e, tzinfo=utc).timestamp()
    i = int(np.searchsorted(t, ts, 'right') - 1)
    day_end = i + int(np.searchsorted(hour[i:i + 400] * 0 + hour[i:i + 400], 15)) if False else min(n - 1, i + 144)
    # peak = best price reachable until 15:00 server same day
    k = i
    while k < n - 1 and t[k + 1] // 86400 == t[i] // 86400 and hour[k + 1] < 15: k += 1
    peak = (h[i + 1:k + 1].max() - ep) / PIP
    act = (xp - ep) / PIP
    out = []
    for nm, kind, p in POLICIES:
        pips, _ = run(o, h, l, c, i, ep, atr[i], kind, p, sp[i]); out.append(pips); tot[nm] += pips
    tot['actual'] += act; tot['peak'] += peak
    print(f"{tstr(i):>12} {ep:8.3f} {act:7.1f} {peak:6.1f}" + "".join(f"{x:7.1f}" for x in out))
print(f"{'TOTAL':>12} {'':>8} {tot['actual']:7.1f} {tot['peak']:6.1f}" + "".join(f"{tot[nm]:7.1f}" for nm, _, _ in POLICIES))
print("  *peak = best price reachable after entry until 15:00 server that day (hindsight ceiling)\n")


# ---------- (B) generalise on reclaim events ----------
def events(H0, H1, L=24, W_MAX=5.0, BAIT_MIN=0.3, MAXW=24, TOL=0.3, RECL=3):
    out = []
    for sign in (1, -1):
        O, Hh, Ll, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
        i = L + 20
        while i < n - HMAX - 6:
            if not (H0 <= hour[i] < H1): i += 1; continue
            a = atr[i - 1]; top, bot = Hh[i - L:i].max(), Ll[i - L:i].min()
            if (top - bot) <= W_MAX * a and C[i] > top + BAIT_MIN * a and C[i - 1] <= top:
                touch = next((j for j in range(i + 1, i + MAXW) if Ll[j] <= bot + TOL * a), None)
                rec = None if touch is None else next((k for k in range(touch, touch + RECL + 1) if C[k] > bot and C[k] > O[k]), None)
                if rec is not None:
                    out.append((sign, rec, atr[rec])); i = rec + 1; continue
            i += 1
    return out


def stats(label, res):
    a = np.array(res)
    if not len(a): return
    gp, gl = a[a[:, 0] > 0, 0].sum(), -a[a[:, 0] < 0, 0].sum()
    print(f"  {label:26s} avg={a[:,0].mean():+6.1f}p  win={np.mean(a[:,0]>0)*100:3.0f}%  PF={gp/gl if gl else 9.99:4.2f}  "
          f"sum={a[:,0].sum():+7.0f}p  avgHold={a[:,1].mean():4.0f} bars")


for (H0, H1, lab) in ((6, 13, "hours 6-13"), (0, 24, "all hours")):
    ev = events(H0, H1)
    print(f"(B) RECLAIM EVENTS, {lab}: n={len(ev)}  (pips per trade, same entry, different exit)")
    mid = t[0] + (t[-1] - t[0]) // 2
    for nm, kind, p in POLICIES:
        res = []
        for sign, rec, a in ev:
            O, Hh, Ll, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
            res.append(run(O, Hh, Ll, C, rec, C[rec], a, kind, p, sp[rec]))
        stats(nm, res)
    print()
# stability for the best-looking candidates, all hours
ev = events(0, 24); mid = t[0] + (t[-1] - t[0]) // 2
print("stability (all hours): first half vs second half of the sample")
for nm, kind, p in POLICIES:
    if nm not in ("ATR trail 2.0", "ATR trail 3.0", "Swing trail 12 bars", "Swing trail 24 bars", "Time stop 36 bars (3h)", "Target 2R"): continue
    for lab, f in (("1st", lambda x: t[x[1]] < mid), ("2nd", lambda x: t[x[1]] >= mid)):
        res = []
        for sign, rec, a in [x for x in ev if f(x)]:
            O, Hh, Ll, C = (o, h, l, c) if sign > 0 else (-o, -l, -h, -c)
            res.append(run(O, Hh, Ll, C, rec, C[rec], a, kind, p, sp[rec]))
        stats(f"{nm} [{lab}]", res)
