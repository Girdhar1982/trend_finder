"""
Which sweep SIZE (in pips, what you see on the chart) is followed by a tradeable play?  USDJPY M5, server time.

Event (long; short is the mirror): bar k's low goes BELOW a level and the bar CLOSES back above it
  ('same' = swept and reclaimed on one bar)  or  bar k-1 swept and closed below, bar k closes back above ('next').
Levels: N-bar low for N in 24/48/96/288 (formed >= 3 bars before k), previous-day low, day-low-so-far.
The event is tagged with the MOST significant level it swept (288 > 96 > 48 > 24; PDL and day-low flags separately).
Depth = (level - sweep low) in pips.
Entry = next bar open + spread (no look-ahead). Outcomes, 36-bar horizon (3h):
  p10    : +10 pips before -10 pips (fixed bracket)
  p10s   : +10 pips before price trades 1 pip beyond the sweep extreme (structural stop)
  pnl10  : pips from the fixed +/-10 bracket (timeout = close at 36 bars)
  mfe    : best pips reached before the structural stop (capped at 36 bars)
Baseline: every reversal bar (close in trade direction) with the same exits.
Split: first 60% of time = train, rest = test.
"""
import numpy as np, pandas as pd
import sweep_dataset as sd

PIP = 0.01; H = 36
t, o, h, l, c, sp, atr, n = sd.t, sd.o, sd.h, sd.l, sd.c, sd.sp, sd.atr, sd.n
day = t // 86400
cut_t = t[600] + (t[-1] - t[600]) * 0.6


def levels(s):
    """level arrays for direction s (long: lows; short: negated highs) -> dict name -> array (in transformed space)"""
    L = l if s > 0 else -h
    out = {}
    for N in (24, 48, 96, 288):
        out[f"N{N}"] = pd.Series(L).rolling(N - 2).min().shift(3).values
    out["PDL"] = sd.pdl if s > 0 else -sd.pdh
    ds = pd.Series(L).groupby(day).cummin().groupby(day).shift(3).values   # day extreme so far, formed >= 3 bars ago
    out["DAY"] = ds
    return out


def simulate(k, s):
    O, Hh, Ll, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
    ent = O[k + 1] + sp[k + 1]
    ext = min(Ll[k], Ll[k - 1])                      # sweep extreme (covers the 'next' case)
    sstop = ext - 1 * PIP
    up, dn = ent + 10 * PIP, ent - 10 * PIP
    p10 = p10s = None; pnl = None; mfe = 0.0; s_alive = True
    for j in range(k + 1, min(n - 1, k + H) + 1):
        # fixed bracket (stop first on ties)
        if p10 is None:
            if Ll[j] <= dn: p10 = 0; pnl = -10 - (ent - O[j] if O[j] < dn else 0) / PIP * 0
            elif Hh[j] >= up: p10 = 1; pnl = 10
        # structural
        if s_alive:
            if Ll[j] <= sstop: s_alive = False; p10s = 0 if p10s is None else p10s
            else:
                mfe = max(mfe, (Hh[j] - ent) / PIP)
                if p10s is None and Hh[j] >= up: p10s = 1
        if p10 is not None and (not s_alive or p10s is not None): break
    jend = min(n - 1, k + H)
    if p10 is None: p10 = 0.5; pnl = (C[jend] - ent) / PIP
    if p10s is None: p10s = 0
    return p10, p10s, pnl, mfe, (ent - sstop) / PIP


rows = []
for s in (1, -1):
    O, Hh, Ll, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
    LV = levels(s)
    last = -99
    for k in range(700, n - H - 2):
        if k - last < 6: continue
        best = None
        for mode in ("same", "next"):
            if mode == "same":
                swept_low = Ll[k]; ok_close = True
            else:
                swept_low = Ll[k - 1]
            for name in ("N288", "N96", "N48", "N24"):
                lv = LV[name][k if mode == "same" else k - 1]
                if np.isnan(lv): continue
                if mode == "same":
                    hit = swept_low < lv and C[k] > lv
                else:
                    hit = swept_low < lv and C[k - 1] <= lv and C[k] > lv and Ll[k] > swept_low - 1e-9
                if hit:
                    best = (mode, name, lv, swept_low); break
            if best: break
        if not best: continue
        mode, name, lv, swl = best
        kk = k if mode == "same" else k - 1
        pdl = LV["PDL"][kk]; dl = LV["DAY"][kk]
        flag_pdl = (not np.isnan(pdl)) and swl < pdl and C[k] > pdl
        flag_day = (not np.isnan(dl)) and swl < dl and C[k] > dl
        p10, p10s, pnl, mfe, risk = simulate(k, s)
        rows.append(dict(t=t[k], k=k, s=s, mode=mode, level=name, depth_p=(lv - swl) / PIP, depth_atr=(lv - swl) / atr[k],
                         atr_p=atr[k] / PIP, pdl=flag_pdl, daylvl=flag_day, hour=sd.hour[k],
                         p10=p10, p10s=p10s, pnl=pnl, mfe=mfe, risk_p=risk))
        last = k
ev = pd.DataFrame(rows); ev["half"] = np.where(ev.t < cut_t, "tr", "te")

# baseline: every reversal bar, same exits (subsample every 3rd bar for speed)
base = []
for s in (1, -1):
    O, Hh, Ll, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
    for k in range(700, n - H - 2, 3):
        if C[k] > O[k]:
            p10, p10s, pnl, mfe, risk = simulate(k, s)
            base.append(dict(t=t[k], p10=p10, p10s=p10s, pnl=pnl, mfe=mfe, risk_p=risk))
base = pd.DataFrame(base); base["half"] = np.where(base.t < cut_t, "tr", "te")
ev.to_pickle("sweep_size_events.pkl"); base.to_pickle("sweep_size_base.pkl")


def line(name, d):
    out = [f"{name:30s}"]
    for hf in ("tr", "te"):
        x = d[d.half == hf]
        if len(x) == 0: out.append(f"{hf}: n=0".ljust(52)); continue
        out.append(f"{hf}: n={len(x):4d} +10/-10={x.p10.mean()*100:3.0f}% pnl={x.pnl.mean():+5.2f}p +10-before-ext={x.p10s.mean()*100:3.0f}%")
    return "  ".join(out)


days = (t[-1] - t[700]) / 86400 * 5 / 7
print(line("BASELINE any reversal bar", base))
print(line("ALL sweeps", ev), f" /day={len(ev)/days:.1f}")
print("\nBY DEPTH (pips beyond the level):")
bins = [0, 0.5, 1, 2, 3, 5, 8, 100]
for a, b in zip(bins[:-1], bins[1:]):
    d = ev[(ev.depth_p >= a) & (ev.depth_p < b)]
    print(line(f"  {a:>4}-{b:<4} pips", d), f" /day={len(d)/days:.1f}")
print("\nBY LEVEL SWEPT (most significant):")
for nm in ("N24", "N48", "N96", "N288"):
    d = ev[ev.level == nm]; print(line(f"  {nm} bars", d), f" /day={len(d)/days:.2f}")
print(line("  previous-day low/high", ev[ev.pdl]), f" /day={ev.pdl.sum()/days:.2f}")
print(line("  day low/high so far", ev[ev.daylvl]), f" /day={ev.daylvl.sum()/days:.2f}")
print("\nRECLAIM SPEED:")
for m in ("same", "next"): print(line(f"  {m} bar", ev[ev["mode"] == m]))
print("\nDEPTH x SIGNIFICANT LEVEL (N96/N288/day/PDL):")
sig = ev[(ev.level.isin(["N96", "N288"])) | ev.pdl | ev.daylvl]
for a, b in ((0, 1), (1, 3), (3, 6), (6, 100)):
    d = sig[(sig.depth_p >= a) & (sig.depth_p < b)]; print(line(f"  {a}-{b} pips, big level", d), f" /day={len(d)/days:.2f}")
print("\nDEPTH in ATR (scale-free):")
for a, b in ((0, 0.15), (0.15, 0.3), (0.3, 0.6), (0.6, 1.0), (1.0, 2.0), (2.0, 99)):
    d = ev[(ev.depth_atr >= a) & (ev.depth_atr < b)]; print(line(f"  {a}-{b} ATR", d))
