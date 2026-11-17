"""
Sweep + reclaim monitor (MT5 server time) with Windows alerts.

A SWEEP is a bar whose wick goes beyond a level (a stop-run). A RECLAIM is a CLOSE back inside the level, either on the
same bar or within --reclaim-bars bars. Low-side level swept then reclaimed = BUY idea; high-side = SELL idea.

Levels (from bars BEFORE the bar being judged):
  24h     high / low of the last 24 hours
  swing   most recent unbroken 3-bar swing high / low
  PD      previous day high / low
  00-02   00:00-02:00 server range (pre-Tokyo; from 02:00 on)
  fig     whole figure above / below (e.g. 160.00)

Events:
  RECLAIM  (the signal)  graded PLAY / LEVEL / DEEP
           PLAY  = 24h level, swept 0.5-3 pips, reclaimed ON THE SAME BAR, counter-trend stretch >= 0.62  (M5 only)
           DEEP  = swept >= --deep pips (default 3)
           LEVEL = every other reclaim
  SWEEP    price is beyond a level but has not closed back yet (watching for the reclaim)
  EXPIRED  no reclaim within --reclaim-bars: the sweep behaved like a breakout

    python research/sweep_reclaim_monitor.py                      # live M5 USDJPY
    python research/sweep_reclaim_monitor.py --tf M15
    python research/sweep_reclaim_monitor.py --replay "2026-11-12 17:00" "2026-11-12 20:00"
    python research/sweep_reclaim_monitor.py --stats               # what happened after past RECLAIMs
    python research/sweep_reclaim_monitor.py --test-alert
It only alerts. It does not place orders.
"""
import argparse
import time as _time

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

import breakout_monitor as bm        # toast / popup / beep

LOG = "research/sweep_reclaim_monitor.log"
TFS = {"M1": (mt5.TIMEFRAME_M1, 1), "M5": (mt5.TIMEFRAME_M5, 5), "M15": (mt5.TIMEFRAME_M15, 15),
       "M30": (mt5.TIMEFRAME_M30, 30), "H1": (mt5.TIMEFRAME_H1, 60)}
# stretch score constants (M5, from research/sweep_score.py, same as Sweep_Reclaim_Alert.mq5)
MU48, SD48 = -1.5647647681, 1.3383025567
MU288, SD288 = -1.9859023515, 5.7488277428
MUDO, SDDO = -2.6433684188, 9.3743545638
RANK = {"PLAY": 3, "LEVEL": 2, "DEEP": 1}


class Engine:
    def __init__(self, pip, tfm, groups, min_depth=0.5, deep=3.0, reclaim_bars=2, cooldown=12, stretch=0.62):
        self.pip, self.tfm, self.groups = pip, tfm, groups
        self.md, self.deep, self.R, self.cd, self.thr = min_depth * pip, deep, reclaim_bars, cooldown, stretch
        self.pending, self.cool, self.A = [], {}, {}

    # ---------- indicators for every bar (computed once per data load) ----------
    def prep(self, d):
        n24 = 1440 // self.tfm
        d["h24"] = d.high.rolling(n24).max().shift(1)
        d["l24"] = d.low.rolling(n24).min().shift(1)
        day = d.time.dt.normalize()
        d["pdh"] = day.map(d.groupby(day).high.max().shift(1))
        d["pdl"] = day.map(d.groupby(day).low.min().shift(1))
        early = d.time.dt.hour < 2
        e = d[early]
        g = e.groupby(day[early])
        ok = g.size() >= (120 // self.tfm) - 1
        d["r02h"] = day.map(g.high.max()[ok]).where(~early)
        d["r02l"] = day.map(g.low.min()[ok]).where(~early)
        step = 100 * self.pip
        pc = d.close.shift(1)
        d["figd"] = np.floor(pc / step) * step
        d["figu"] = d.figd + step
        hi, lo, n, W = d.high.values, d.low.values, len(d), 3
        swh, swl = np.full(n, np.nan), np.full(n, np.nan)
        ch = cl = np.nan
        for i in range(n):
            if i >= 1:
                if not np.isnan(ch) and hi[i - 1] > ch:
                    ch = np.nan
                if not np.isnan(cl) and lo[i - 1] < cl:
                    cl = np.nan
            j = i - 1 - W
            if j - W >= 0:
                if hi[j] == hi[j - W:j + W + 1].max():
                    ch = hi[j]
                if lo[j] == lo[j - W:j + W + 1].min():
                    cl = lo[j]
            swh[i], swl[i] = ch, cl
        d["swh"], d["swl"] = swh, swl
        prev = d.close.shift(1)
        tr = np.maximum(d.high - d.low, np.maximum((d.high - prev).abs(), (d.low - prev).abs()))
        d["atr"] = tr.rolling(14).mean()
        e48, e288 = d.close.ewm(span=48, adjust=False).mean(), d.close.ewm(span=288, adjust=False).mean()
        dopen = d.open.where(day != day.shift(1)).ffill()
        for s, col in ((1, "sc_buy"), (-1, "sc_sell")):
            t48, t288, dd = s * (d.close - e48) / d.atr, s * (d.close - e288) / d.atr, s * (d.close - dopen) / d.atr
            d[col] = -(((t48 - MU48) / SD48 + (t288 - MU288) / SD288 + (dd - MUDO) / SDDO) / 3.0)
        d["vx"] = d.tick_volume / d.tick_volume.rolling(20).mean().shift(1)
        self.A = {c: d[c].values for c in ("open", "high", "low", "close", "h24", "l24", "pdh", "pdl", "r02h", "r02l",
                                             "swh", "swl", "figu", "figd", "sc_buy", "sc_sell", "vx")}
        return d

    def levels(self, i):
        A, out = self.A, []

        def add(name, col, side, grp):
            v = A[col][i]
            if not np.isnan(v) and grp in self.groups:
                out.append((name, v, side, grp))
        add("24h high", "h24", "H", "24h"); add("24h low", "l24", "L", "24h")
        add("swing high", "swh", "H", "swing"); add("swing low", "swl", "L", "swing")
        add("PDH", "pdh", "H", "PD"); add("PDL", "pdl", "L", "PD")
        add("00-02 high", "r02h", "H", "00-02"); add("00-02 low", "r02l", "L", "00-02")
        if not np.isnan(A["figu"][i]):
            add(f"{A['figu'][i]:.2f}", "figu", "H", "fig"); add(f"{A['figd'][i]:.2f}", "figd", "L", "fig")
        return out

    def classify(self, p, depth, same, stretch):
        if depth >= self.deep:
            return "DEEP"
        if p["grp"] == "24h" and same and depth >= self.md / self.pip and self.tfm == 5 and stretch >= self.thr:
            return "PLAY"
        return "LEVEL"

    # ---------- one closed bar ----------
    def step(self, d, i):
        A = self.A
        hi, lo, cl = A["high"][i], A["low"][i], A["close"][i]
        t = d.time.iat[i]
        rec, sw, exp = {"BUY": [], "SELL": []}, {"BUY": [], "SELL": []}, {"BUY": [], "SELL": []}
        for p in list(self.pending):
            s = p["side"]
            if s == "BUY":
                p["ext"] = min(p["ext"], lo)
                back = cl > p["level"]
            else:
                p["ext"] = max(p["ext"], hi)
                back = cl < p["level"]
            if back:
                rec[s].append(p); self.pending.remove(p); self.cool[p["name"]] = i
            elif i - p["k"] >= self.R:
                exp[s].append(p); self.pending.remove(p); self.cool[p["name"]] = i
        have = {p["name"] for p in self.pending}
        for name, lv, side, grp in self.levels(i):
            if name in have or i - self.cool.get(name, -10**9) < self.cd:
                continue
            if side == "L" and lo < lv - self.md:
                p = dict(name=name, level=lv, side="BUY", k=i, ext=lo, grp=grp)
                if cl > lv:
                    rec["BUY"].append(p); self.cool[name] = i
                else:
                    self.pending.append(p); sw["BUY"].append(p)
            elif side == "H" and hi > lv + self.md:
                p = dict(name=name, level=lv, side="SELL", k=i, ext=hi, grp=grp)
                if cl < lv:
                    rec["SELL"].append(p); self.cool[name] = i
                else:
                    self.pending.append(p); sw["SELL"].append(p)
        ev = []
        pp = self.pip
        for s in ("BUY", "SELL"):
            depth = lambda p: (p["level"] - p["ext"] if s == "BUY" else p["ext"] - p["level"]) / pp
            if rec[s]:
                lst = rec[s]
                ext = min(p["ext"] for p in lst) if s == "BUY" else max(p["ext"] for p in lst)
                stop = ext - pp if s == "BUY" else ext + pp
                risk = abs(cl - stop) / pp
                st = A["sc_buy"][i] if s == "BUY" else A["sc_sell"][i]
                items, cls = [], "DEEP"
                for p in lst:
                    same = p["k"] == i
                    c = self.classify(p, depth(p), same, st)
                    cls = c if RANK[c] > RANK[cls] else cls
                    items.append(f"{p['name']} {p['level']:.3f} (swept {depth(p):.1f}p, "
                                 f"{'same bar' if same else f'reclaimed after {i - p['k']} bar(s)'})")
                sttxt = f" | stretch {st:.2f}" if self.tfm == 5 and not np.isnan(st) else ""
                text = (f"RECLAIM {s} [{cls}]: {'; '.join(items)} | close {cl:.3f}, stop ref {stop:.3f} (risk {risk:.1f}p)"
                        f"{sttxt} | vol {A['vx'][i]:.1f}x")
                info = dict(i=i, t=t, side=s, cls=cls, names=[p["name"] for p in lst], grps={p["grp"] for p in lst},
                            depth=max(depth(p) for p in lst), same=any(p["k"] == i for p in lst), stretch=st,
                            vol=A["vx"][i], ext=ext, stop=stop)
                ev.append(("RECLAIM", text, info))
            if sw[s]:
                where = "below" if s == "BUY" else "above"
                ev.append(("SWEEP", f"SWEEP {s} watch: price went {where} " +
                           ", ".join(f"{p['name']} {p['level']:.3f} (+{depth(p):.1f}p)" for p in sw[s]) +
                           f" but closed {where} it ({cl:.3f}) - waiting for a close back "
                           f"{'above' if s == 'BUY' else 'below'} within {self.R} bar(s)", None))
            if exp[s]:
                ev.append(("EXPIRED", f"NO RECLAIM {s}: " + ", ".join(f"{p['name']} {p['level']:.3f}" for p in exp[s]) +
                           f" still beaten after {self.R} bar(s) - behaving like a breakout, {s} idea invalid", None))
        return ev


def load(symbol, tf, n, start=0):
    """start=0 includes the forming bar, start=1 returns closed bars only."""
    r = mt5.copy_rates_from_pos(symbol, TFS[tf][0], start, n)
    if r is None or len(r) == 0:
        raise SystemExit(f"no data for {symbol} {tf}: {mt5.last_error()}")
    d = pd.DataFrame(r)
    d["time"] = pd.to_datetime(d.time, unit="s")
    return d


def emit(a, ts, kind, text, beep=True, cls=None):
    line = f"{ts:%Y-%m-%d %H:%M} {a.symbol} {a.tf} {text}"
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    graded_out = kind == "RECLAIM" and cls not in a.alert_grades      # console only for grades you did not ask to be alerted on
    if beep and bm.winsound and kind == "RECLAIM" and not graded_out:
        bm.winsound.Beep(1200 if " BUY" in text[:14] else 800, 300)
    if graded_out:
        return
    head = text.split(":")[0]
    if kind in a.toast_kinds:
        bm.toast(f"{a.symbol} {a.tf} {head}", text.split(":", 1)[1].strip() if ":" in text else text)
    if kind in a.popup_kinds:
        bm.popup(f"{a.symbol} {a.tf} {head}", text)


def bracket(d, e, side, pip, tp_p=10.0, sl_p=10.0, hold=36, stop=None):
    """next-open entry at index e. fixed pips bracket, or stop price + 1R target. returns (pips, R-or-None)."""
    o, h, l, c = d.open.values, d.high.values, d.low.values, d.close.values
    sp = d.spread.values * pip / 10.0
    if e >= len(o):
        return None
    entry = o[e] + (sp[e] if side > 0 else 0.0)
    if stop is None:
        tp, sl = entry + side * tp_p * pip, entry - side * sl_p * pip
    else:
        risk = (entry - stop) * side
        if risk < 2 * pip:
            return None
        sl, tp = stop, entry + side * risk
    for k in range(e, min(e + hold, len(o))):
        if side > 0:
            if l[k] <= sl:
                return (sl - entry) / pip, -1.0
            if h[k] >= tp:
                return (tp - entry) / pip, 1.0
        else:
            if h[k] + sp[k] >= sl:
                return (entry - sl) / pip, -1.0
            if l[k] + sp[k] <= tp:
                return (entry - tp) / pip, 1.0
    k = min(e + hold, len(o)) - 1
    px = c[k] if side > 0 else c[k] + sp[k]
    return side * (px - entry) / pip, side * (px - entry) / abs(entry - sl)


def stats(a, pip, tfm):
    d = load(a.symbol, a.tf, 99000)
    eng = Engine(pip, tfm, a.groups, a.min_depth, a.deep, a.reclaim_bars, a.cooldown, a.stretch)
    eng.prep(d)
    n, cut = len(d), int(len(d) * 0.6)
    days = d.time.dt.normalize().nunique()
    rows = []
    for i in range(300, n - 1):
        for kind, text, info in eng.step(d, i):
            if kind != "RECLAIM":
                continue
            s = 1 if info["side"] == "BUY" else -1
            b = bracket(d, i + 1, s, pip)
            r = bracket(d, i + 1, s, pip, stop=info["stop"])
            if b is None:
                continue
            rows.append(dict(i=i, side=s, cls=info["cls"], grp="+".join(sorted(info["grps"])), depth=info["depth"],
                             p10=b[0], pR=(r[1] if r else np.nan)))
    R = pd.DataFrame(rows)
    rng = np.random.default_rng(5)
    base = [bracket(d, int(k) + 1, sd, pip) for k in rng.integers(300, n - 60, 6000) for sd in (1, -1)]
    base = np.array([x[0] for x in base if x])
    print(f"{a.symbol} {a.tf} {d.time.iloc[0]:%Y-%m-%d}..{d.time.iloc[-1]:%Y-%m-%d} ({days} days, test = last 40%)")
    print(f"RECLAIM events: {len(R)}  ({len(R)/days:.1f}/day).  Random-entry baseline for the same +/-10p bracket: {base.mean():+.2f}p")
    print("outcome = enter NEXT bar open (spread paid), +10p target / -10p stop within 36 bars;  'stopR' = stop at sweep extreme "
          "-/+ 1p, target 1R\n")

    def line(name, g):
        tr, te = g[g.i < cut], g[g.i >= cut]
        sr = g.pR.dropna()
        print(f"  {name:26} n={len(g):4d} ({len(g)/days:4.2f}/d) win {100*(g.p10>0).mean():4.1f}%  avg {g.p10.mean():+6.2f}p  "
              f"train {tr.p10.mean():+6.2f}/{len(tr):3d}  test {te.p10.mean():+6.2f}/{len(te):3d}  | stopR avg {sr.mean():+.3f} (n={len(sr)})")
    line("ALL", R)
    print("\nby grade:")
    for c in ("PLAY", "LEVEL", "DEEP"):
        if (R.cls == c).any():
            line(c, R[R.cls == c])
    print("\nby side:")
    line("BUY", R[R.side > 0]); line("SELL", R[R.side < 0])
    print("\nby level group (any level in the bar's group):")
    for g in ("24h", "swing", "PD", "00-02", "fig"):
        m = R.grp.str.contains(g)
        if m.sum() >= 30:
            line(g, R[m])
    P = R[R.cls == "PLAY"]
    if len(P):
        print("\nPLAY by side:")
        line("PLAY BUY", P[P.side > 0])
        line("PLAY SELL", P[P.side < 0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="USDJPY")
    ap.add_argument("--tf", default="M5", choices=list(TFS), help="timeframe (default M5; PLAY grade needs M5)")
    ap.add_argument("--levels", default="24h,PD,00-02,fig",
                    help="comma list from: 24h, swing, PD, 00-02, fig (default leaves out 'swing': ~10 noisy events a day)")
    ap.add_argument("--min-depth", type=float, default=0.5, help="pips a wick must go beyond a level (default 0.5)")
    ap.add_argument("--deep", type=float, default=3.0, help="sweeps this deep or more are graded DEEP (default 3)")
    ap.add_argument("--reclaim-bars", type=int, default=2, help="bars allowed to close back inside (default 2)")
    ap.add_argument("--cooldown", type=int, default=12, help="bars before the same level can alert again (default 12)")
    ap.add_argument("--stretch", type=float, default=0.62, help="stretch needed for PLAY (default 0.62)")
    ap.add_argument("--alert-grades", default="PLAY",
                    help="RECLAIM grades that beep / toast / pop up (default PLAY, the only grade with a positive backtest). "
                         "Everything is always printed and logged. e.g. PLAY,LEVEL,DEEP for all")
    ap.add_argument("--poll", type=float, default=3.0)
    ap.add_argument("--replay", nargs=2, metavar=("START", "END"))
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--no-beep", action="store_true")
    ap.add_argument("--toast", default="RECLAIM", help="events that raise a Windows toast, e.g. RECLAIM,SWEEP,EXPIRED ('none' = off)")
    ap.add_argument("--popup", default="none", help="events that raise an always-on-top box until you click OK")
    ap.add_argument("--test-alert", action="store_true")
    a = ap.parse_args()
    split = lambda s: () if s.strip().lower() == "none" else tuple(x.strip().upper() for x in s.split(","))
    a.toast_kinds, a.popup_kinds = split(a.toast), split(a.popup)
    a.groups = tuple(x.strip() for x in a.levels.split(","))
    a.alert_grades = split(a.alert_grades) if a.alert_grades.lower() != "all" else ("PLAY", "LEVEL", "DEEP")
    if a.test_alert:
        bm.toast(f"{a.symbol} sweep/reclaim test", "If you can read this, Windows alerts work.")
        if a.popup_kinds:
            bm.popup(f"{a.symbol} sweep/reclaim test", "If you can read this, pop-ups work. Click OK.")
            _time.sleep(30)
        else:
            _time.sleep(3)
        return
    if not mt5.initialize():
        raise SystemExit(f"MT5 init failed: {mt5.last_error()}")
    mt5.symbol_select(a.symbol, True)
    info = mt5.symbol_info(a.symbol)
    pip = info.point * (10 if info.digits in (3, 5) else 1)
    tfm = TFS[a.tf][1]
    mk = lambda: Engine(pip, tfm, a.groups, a.min_depth, a.deep, a.reclaim_bars, a.cooldown, a.stretch)
    if a.stats:
        stats(a, pip, tfm)
        return
    if a.replay:
        d = load(a.symbol, a.tf, 99000)
        s, e = pd.Timestamp(a.replay[0]), pd.Timestamp(a.replay[1])
        eng = mk()
        eng.prep(d)
        first = d.index[d.time >= s][0]
        for i in range(max(300, first - 300), len(d) - 1):
            if d.time.iat[i] > e:
                break
            for kind, text, inf in eng.step(d, i):
                if d.time.iat[i] >= s:
                    emit(a, d.time.iat[i] + pd.Timedelta(minutes=tfm), kind, text, beep=False, cls=inf and inf["cls"])
        return

    d = load(a.symbol, a.tf, 6000)
    eng = mk()
    eng.prep(d)
    i = len(d) - 2
    for j in range(max(300, i - 60), i + 1):         # silent warm-up so live sweeps are known
        eng.step(d, j)
    print(f"watching {a.symbol} {a.tf} (server time): sweep + reclaim of {a.levels}; min depth {a.min_depth}p, "
          f"reclaim within {a.reclaim_bars} bar(s), DEEP >= {a.deep}p. Alerts only - no orders. Ctrl+C to stop.", flush=True)
    if eng.pending:
        for p in eng.pending:
            print(f"  already watching: {p['side']} sweep of {p['name']} {p['level']:.3f}")
    d = d.iloc[:-1].reset_index(drop=True)           # closed bars only from here on; the frame grows with every new bar
    try:
        while True:
            _time.sleep(a.poll)
            fresh = load(a.symbol, a.tf, 40, start=1)
            new = fresh[fresh.time > d.time.iat[-1]]
            if new.empty:
                continue
            first = len(d)
            d = pd.concat([d, new], ignore_index=True)
            eng.prep(d)
            for k in range(first, len(d)):
                for kind, text, inf in eng.step(d, k):
                    emit(a, d.time.iat[k] + pd.Timedelta(minutes=tfm), kind, text, beep=not a.no_beep, cls=inf and inf["cls"])
    except KeyboardInterrupt:
        print("stopped")


if __name__ == "__main__":
    main()
