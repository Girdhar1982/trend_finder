"""
"Resistance breaks -> early buyers trapped -> their stops swept -> continue in the break direction."
Compares the indicator's current Trap() with stricter versions of the same idea (buy side; sells = mirror).

  CUR    current Trap(): close > range high + 0.3 ATR, back to range low (<= low + 0.3 ATR) within 24 bars,
         bullish close above range low within 3 bars
  SWEEP  same, but the range low must actually be TAKEN (low < range low) = stops really swept
  CUR>R  CUR touch, then wait for a close back above the broken resistance (range high) within 24 bars
  SWP>R  SWEEP touch, then close back above the broken resistance within 24 bars
  SHAKE  after the break, price dips back under the broken resistance by >= 0.1 ATR (breakout buyers' stops),
         then a bullish close back above it within 3 bars
  SHAKEB same, but the dip must take the BREAKOUT BAR's low (where the early entries put their stops)
Fill = next bar open + spread. Metrics over 36 bars:
  hit20  = +20 pips reached before -10 (break-even 33.3%)
  br10   = +/-10 pip bracket, average pips
  st20   = structural stop (lowest low since the touch/dip - 1 pip), TP 20 pips, average pips
Random = every bar of that side (same metrics). Train = first 60% of bars, test = last 40%.
usage: python research/trap_variants.py
"""
import datetime as dt
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PIP, GAP, MAXW, RECL, HOLD = 0.01, 6, 24, 3, 36

mt5.initialize()
d = pd.DataFrame(mt5.copy_rates_from_pos("USDJPY", mt5.TIMEFRAME_M5, 0, 99000))
t = d.time.values.astype("int64")
o, h, l, c = (d[k].values.astype(float) for k in ("open", "high", "low", "close"))
sp = d.spread.values * 0.001
n = len(c)
pc = np.r_[c[0], c[:-1]]
atr = pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean().values
SPLIT = int(n * 0.6)
ts = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime("%Y-%m-%d %H:%M")


def outcome(i, s, stopT):
    """returns (hit20, br10 pips, st20 pips or nan). s=+1 buy, -1 sell. stopT = transformed structural low."""
    e = i + 1
    if e + HOLD >= n:
        return None
    entry = o[e] + sp[e] if s > 0 else o[e]
    # transformed path: buy uses bid lows/highs, sell uses ask (high+sp)
    lo = np.where(s > 0, l[e:e + HOLD], -(h[e:e + HOLD] + sp[e:e + HOLD]))
    hi = np.where(s > 0, h[e:e + HOLD], -(l[e:e + HOLD] + sp[e:e + HOLD]))
    E = s * entry
    endpx = s * (c[e + HOLD - 1] if s > 0 else c[e + HOLD - 1] + sp[e + HOLD - 1])

    def bracket(stop, tp):
        for k in range(HOLD):
            if lo[k] <= stop: return (stop - E) / PIP, 0
            if hi[k] >= tp: return (tp - E) / PIP, 1
        return (endpx - E) / PIP, 0

    _, hit = bracket(E - 10 * PIP, E + 20 * PIP)
    br, _ = bracket(E - 10 * PIP, E + 10 * PIP)
    st = np.nan
    stp = stopT - PIP
    if E - stp > 0.5 * PIP:
        st, _ = bracket(stp, E + 20 * PIP)
    return hit, br, st


def detect(box, var):
    out = []
    for s in (1, -1):
        H, L, C, O = (h, l, c, o) if s > 0 else (-l, -h, -c, -o)
        pend, last = [], -10**9
        for i in range(box + 20, n - HOLD - 2):
            fired = None
            for p in list(pend):
                if p["touch"] < 0:
                    if i > p["push"] + MAXW - 1:
                        pend.remove(p); continue
                    if var in ("CUR", "CUR>R"): hit = L[i] <= p["bot"] + 0.3 * p["a"]
                    elif var in ("SWEEP", "SWP>R"): hit = L[i] < p["bot"]
                    elif var == "SHAKE": hit = L[i] < p["top"] - 0.1 * p["a"]
                    else: hit = L[i] < p["plo"]          # SHAKEB: breakout bar low taken
                    if hit: p["touch"] = i
                if p["touch"] >= 0:
                    lim = MAXW if var in ("CUR>R", "SWP>R") else RECL
                    if i <= p["touch"] + lim:
                        lvl = p["top"] if var in ("CUR>R", "SWP>R", "SHAKE", "SHAKEB") else p["bot"]
                        ok = C[i] > lvl and C[i] > O[i]
                        if var in ("CUR>R", "SWP>R"): ok = C[i] > lvl and C[i - 1] <= lvl
                        if ok and i - last >= GAP:
                            fired = (i, L[p["touch"]:i + 1].min()); break
                    else:
                        pend.remove(p)
            if fired:
                out.append((fired[0], s, fired[1])); last = fired[0]; pend = []; continue
            a = atr[i - 1]
            if not a > 0: continue
            top, bot = H[i - box:i].max(), L[i - box:i].min()
            if top - bot <= 5 * a and C[i] > top + 0.3 * a and C[i - 1] <= top:
                pend.append(dict(push=i, top=top, bot=bot, a=a, plo=L[i], touch=-1))
    return sorted(out)


def summarise(rows):
    if not rows: return "n=0"
    r = np.array(rows, dtype=float)
    return f"n={len(r):5d} hit20 {100*r[:,0].mean():4.1f}%  br10 {r[:,1].mean():+5.2f}p  st20 {np.nanmean(r[:,2]):+5.2f}p"


def report(name, sigs):
    res = {}
    for i, s, stT in sigs:
        oc = outcome(i, s, stT)
        if oc is None: continue
        res.setdefault(("train" if i < SPLIT else "test", s), []).append(oc)
    per_day = len(sigs) / ((t[-1] - t[0]) / 86400 * 5 / 7)
    print(f"{name:12s} {per_day:4.1f}/day")
    for half in ("train", "test"):
        for s in (1, -1):
            print(f"   {half:5s} {'BUY ' if s > 0 else 'SELL'} {summarise(res.get((half, s), []))}")


print(f"USDJPY M5 {ts(0)} -> {ts(n-1)}  ({n} bars, split {ts(SPLIT)})")
rnd = [(i, s, (l[i] if s > 0 else -h[i])) for s in (1, -1) for i in range(300, n - HOLD - 2, 7)]
report("RANDOM", rnd)
for box in (12, 6):
    print(f"\n=== range = {box} bars ({box*5} min) ===")
    for var in ("CUR", "SWEEP", "CUR>R", "SWP>R", "SHAKE", "SHAKEB"):
        sig = detect(box, var)
        report(var, sig)
        if box == 12 and var in ("SWP>R", "SHAKEB"):
            print("     last 5:", ", ".join(f"{ts(i)} {'B' if s > 0 else 'S'}" for i, s, _ in sig[-5:]))
