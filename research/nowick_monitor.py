"""
No-wick retest monitor (M15, MT5 server time).

Rule (as specified):
  1. Trend: M15 close above a RISING EMA(50) = up, below a FALLING EMA(50) = down.
  2. Signal: a closed candle with NO WICKS (both wicks <= max(0.3 pip, wick-pct % of its range)) and a real body
     (>= min-body ATR), in the trend's direction: bullish no-wick in an uptrend, bearish no-wick in a downtrend.
  3. Entry: a LIMIT order at the no-wick candle's open (entry=open; --entry mid = middle of the body), valid for the
     next 9 candles, cancelled if not touched.
  4. Stop: most recent swing low (buys) / high (sells) beyond the entry (2-bar pivot, last 30 bars), + 3 pip buffer.
  5. Target: 1:1 (distance entry->stop).
Fills use bid/ask: a buy limit fills when ask (low + spread) <= entry, a sell limit when bid (high) >= entry. On the fill
bar only the stop is considered (order inside the bar is unknown); afterwards stop is checked before target.
Exit at the close if neither is hit within --max-hold bars (default 96 = 24h).

    python research/nowick_monitor.py                         # live (alerts only - it does NOT place orders)
    python research/nowick_monitor.py --replay "2026-11-12 08:00" "2026-11-12 22:00"
    python research/nowick_monitor.py --backtest              # all M15 history MT5 has
    python research/nowick_monitor.py --test-alert
"""
import argparse
import sys
import time as _time

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

import breakout_monitor as bm      # toast / popup / winsound reuse

LOG = "research/nowick_monitor.log"
TF_MIN = 15


class Engine:
    def __init__(self, pip, ema_n=50, trend=True, wick_pct=5.0, wick_min_pips=0.3, min_body=0.7, entry="open",
                 wait=9, buffer_pips=3.0, max_risk=0.0, stack=False, max_hold=96, kind="nowick", struct=30,
                 tp_mult=1.0, sl_atr=0.0, breakout=False, brk_n=20):
        self.pip, self.trend, self.wick_pct, self.wick_min = pip, trend, wick_pct, wick_min_pips * pip
        self.min_body, self.entry_mode, self.wait = min_body, entry, wait
        self.buf, self.max_risk, self.stack, self.max_hold = buffer_pips * pip, max_risk * pip, stack, max_hold
        self.kind, self.struct, self.ema_n = kind, struct, ema_n
        self.breakout, self.brk_n = breakout, brk_n      # breakout=True: only candles that close beyond the last brk_n bars' high/low
        self.tp_mult, self.sl_atr = tp_mult, sl_atr      # tp_mult: target in R; sl_atr > 0: stop = sl_atr x ATR instead of the swing
        self.orders = []      # active orders (pending or open)
        self.trades = []      # finished (incl. expired)

    # ---------- data ----------
    def prep(self, d):
        pc = d.close.shift(1)
        tr = np.maximum(d.high - d.low, np.maximum((d.high - pc).abs(), (d.low - pc).abs()))
        d["atr"] = tr.rolling(14).mean()
        d["ema"] = d.close.ewm(span=self.ema_n, adjust=False).mean()
        return d

    # ---------- signal ----------
    def find_signal(self, d, i):
        o, h, l, c = d.open.iat[i], d.high.iat[i], d.low.iat[i], d.close.iat[i]
        rng = h - l
        atr = d.atr.iat[i]
        if i < max(60, self.ema_n + 6) or rng <= 0 or np.isnan(atr) or abs(c - o) < self.min_body * atr:
            return None
        side = 1 if c > o else -1
        up_w = (h - max(o, c))
        lo_w = (min(o, c) - l)
        tol = max(self.wick_min, self.wick_pct / 100.0 * rng)
        if self.kind == "nowick":
            if up_w > tol or lo_w > tol:
                return None
        else:  # 'wicky' baseline: same everything but with clear wicks
            if (up_w + lo_w) < 0.3 * rng:
                return None
        e, e5 = d.ema.iat[i], d.ema.iat[i - 5]
        tr_up = c > e and e > e5
        tr_dn = c < e and e < e5
        if self.trend and not ((side > 0 and tr_up) or (side < 0 and tr_dn)):
            return None
        w = slice(i - self.brk_n, i)
        brk = bool(c > d.high.values[w].max()) if side > 0 else bool(c < d.low.values[w].min())
        if self.breakout and not brk:
            return None
        entry = o if self.entry_mode == "open" else (o + c) / 2.0
        sl = (entry - side * self.sl_atr * atr) if self.sl_atr > 0 else self.structure_sl(d, i, side, entry)
        risk = abs(entry - sl)
        if self.max_risk and risk > self.max_risk:
            return None
        return dict(side=side, sig_i=i, entry=entry, sl=sl, tp=entry + side * risk * self.tp_mult, rr=self.tp_mult, risk=risk,
                    body=abs(c - o), atr=atr, brk=brk, trend="up" if tr_up else ("down" if tr_dn else "flat"))

    def structure_sl(self, d, i, side, entry):
        lo, hi = d.low.values, d.high.values
        for j in range(i - 2, max(i - self.struct, 2) - 1, -1):
            if side > 0 and lo[j] == lo[j - 2:j + 3].min() and lo[j] < entry:
                return lo[j] - self.buf
            if side < 0 and hi[j] == hi[j - 2:j + 3].max() and hi[j] > entry:
                return hi[j] + self.buf
        if side > 0:
            return min(lo[max(0, i - 9):i + 1].min(), entry) - self.buf
        return max(hi[max(0, i - 9):i + 1].max(), entry) + self.buf

    # ---------- order simulation on closed bars ----------
    def step(self, d, i):
        """advance every order with closed bar i, then look for a new signal. returns [(kind, text, order)]."""
        ev = []
        h, l, c = d.high.iat[i], d.low.iat[i], d.close.iat[i]
        spr = d.spread.iat[i] * self.pip / 10.0 if "spread" in d else 0.0     # points -> price
        for o in list(self.orders):
            s = o["side"]
            if o["fill_i"] is None:
                if i <= o["sig_i"]:
                    continue
                trig = (l + spr <= o["entry"]) if s > 0 else (h >= o["entry"])
                if trig:
                    o["fill_i"] = i
                    ev.append(("FILLED", f"{self.tag(s)} limit FILLED at {o['entry']:.3f} (bar {d.time.iat[i]:%H:%M})", o))
                    if (s > 0 and l <= o["sl"]) or (s < 0 and h + spr >= o["sl"]):
                        ev += self.close_order(o, "SL", -1.0, d, i)
                elif i >= o["sig_i"] + self.wait:
                    self.orders.remove(o)
                    self.trades.append(dict(o, outcome="EXPIRED", r=0.0, fill_i=None, exit_i=i))
                    ev.append(("EXPIRED", f"{self.tag(s)} limit {o['entry']:.3f} EXPIRED unfilled after {self.wait} candles", o))
            elif i > o["fill_i"]:
                sl_hit = (l <= o["sl"]) if s > 0 else (h + spr >= o["sl"])
                tp_hit = (h >= o["tp"]) if s > 0 else (l + spr <= o["tp"])
                if sl_hit:
                    ev += self.close_order(o, "SL", -1.0, d, i)
                elif tp_hit:
                    ev += self.close_order(o, "TP", o["rr"], d, i)
                elif i - o["fill_i"] >= self.max_hold:
                    px = c if s > 0 else c + spr
                    ev += self.close_order(o, "TIMEOUT", s * (px - o["entry"]) / o["risk"], d, i)
        sig = self.find_signal(d, i)
        if sig and (self.stack or not any(x["side"] == sig["side"] for x in self.orders)):
            sig.update(fill_i=None, sig_t=d.time.iat[i])
            self.orders.append(sig)
            ev.append(("SIGNAL", self.signal_text(sig, d, i), sig))
        return ev

    def close_order(self, o, why, r, d, i):
        if o in self.orders:
            self.orders.remove(o)
        self.trades.append(dict(o, outcome=why, r=r, exit_i=i))
        return [(why, f"{self.tag(o['side'])} {why} at bar {d.time.iat[i]:%H:%M}: {r:+.2f}R "
                      f"({r * o['risk'] / self.pip:+.1f} pips)", o)]

    @staticmethod
    def tag(s):
        return "BUY" if s > 0 else "SELL"

    def signal_text(self, o, d, i):
        until = d.time.iat[i] + pd.Timedelta(minutes=TF_MIN * (self.wait + 1))
        return (f"NO-WICK {self.tag(o['side'])} candle {d.time.iat[i]:%H:%M} (body {o['body'] / self.pip:.0f}p = "
                f"{o['body'] / o['atr']:.1f} ATR, trend {o['trend']}, {'BREAKOUT of ' + str(self.brk_n) + '-bar range' if o.get('brk') else 'inside range'}) -> {self.tag(o['side'])} LIMIT {o['entry']:.3f} | "
                f"SL {o['sl']:.3f} (risk {o['risk'] / self.pip:.1f}p) | TP {o['tp']:.3f} | cancel after {until:%H:%M}")


def load(symbol, n=99000, start=0):
    """start=0 includes the forming bar, start=1 returns closed bars only."""
    r = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M15, start, n)
    if r is None or len(r) == 0:
        raise SystemExit(f"no data for {symbol}: {mt5.last_error()}")
    d = pd.DataFrame(r)
    d["time"] = pd.to_datetime(d.time, unit="s")
    return d


def emit(symbol, ts, kind, text, a, beep=True):
    line = f"{ts:%Y-%m-%d %H:%M} {symbol} M15 {text}"
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    if beep and bm.winsound and kind in ("SIGNAL", "FILLED", "TP", "SL"):
        bm.winsound.Beep(1200 if "BUY" in text else 800, 300)
    title = f"{symbol} M15 {kind}"
    if kind in a.toast_kinds:
        bm.toast(title, text)
    if kind in a.popup_kinds:
        bm.popup(title, text)


def backtest(a, pip):
    d = load(a.symbol)
    n = len(d)
    cut = int(n * 0.6)
    print(f"{a.symbol} M15 {d.time.iloc[0]:%Y-%m-%d} .. {d.time.iloc[-1]:%Y-%m-%d}  ({n} bars, train first 60% / test last 40%)")
    variants = [
        ("RULE as specified (nowick, trend, entry=open)", {}),
        ("  BREAKOUT candles only (--breakout)", dict(breakout=True)),
        ("  entry at middle of body", dict(entry="mid")),
        ("  no trend filter", dict(trend=False)),
        ("  wick-tolerance 10%", dict(wick_pct=10.0)),
        ("  only risk <= 25 pips", dict(max_risk=25.0)),
        ("  wait 3 candles instead of 9", dict(wait=3)),
        ("  3 pip buffer -> 1 pip", dict(buffer_pips=1.0)),
        ("BASELINE: same rules, candles WITH wicks", dict(kind="wicky")),
    ]
    print(f"\n{'variant':46} {'sig':>5} {'fill%':>6} {'win%':>5} {'avgR':>7} {'trainR':>7} {'testR':>7} {'totR':>7} {'risk':>5} {'mon+':>6}")
    rows = {}
    for name, kw in variants:
        e = Engine(pip, ema_n=a.ema, trend=a.trend, wick_pct=a.wick_pct, min_body=a.min_body, entry=a.entry, wait=a.wait,
                   buffer_pips=a.buffer, max_risk=a.max_risk, stack=a.stack, max_hold=a.max_hold, breakout=a.breakout)
        for k, v in kw.items():
            setattr(e, {"buffer_pips": "buf", "max_risk": "max_risk", "entry": "entry_mode", "trend": "trend",
                        "wick_pct": "wick_pct", "wait": "wait", "kind": "kind", "breakout": "breakout"}[k],
                    v * pip if k in ("buffer_pips", "max_risk") else v)
        e.prep(d)
        for i in range(60, n - 1):
            e.step(d, i)
        T = pd.DataFrame(e.trades)
        if T.empty:
            print(f"{name:46} no trades")
            continue
        F = T[T.outcome != "EXPIRED"].copy()
        F["t"] = d.time.values[F.sig_i.values]
        tr, te = F[F.sig_i < cut], F[F.sig_i >= cut]
        mon = F.groupby(F.t.dt.to_period("M")).r.sum()
        print(f"{name:46} {len(T):5d} {100*len(F)/len(T):6.0f} {100*(F.r > 0).mean():5.1f} {F.r.mean():7.3f} "
              f"{tr.r.mean():7.3f} {te.r.mean():7.3f} {F.r.sum():7.0f} {F.risk.median()/pip:5.1f} {(mon > 0).sum():2d}/{len(mon):2d}")
        rows[name] = F
    F = rows.get("RULE as specified (nowick, trend, entry=open)")
    if F is not None and len(F):
        print("\nRULE by side:")
        for s, g in F.groupby("side"):
            print(f"  {'BUY' if s > 0 else 'SELL':4} n={len(g):4d} win {100*(g.r > 0).mean():4.1f}%  avgR {g.r.mean():+.3f}  totR {g.r.sum():+.0f}")
        print("RULE by year:")
        for y, g in F.groupby(F.t.dt.year):
            print(f"  {y} n={len(g):4d} win {100*(g.r > 0).mean():4.1f}%  avgR {g.r.mean():+.3f}  totR {g.r.sum():+.0f}")
        print(f"outcomes: {F.outcome.value_counts().to_dict()}")
        print("\nBreak-even for a 1:1 trade is 50% wins; spread on sells and the trigger (ask <= limit) are included.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="USDJPY")
    ap.add_argument("--ema", type=int, default=50, help="trend EMA length on M15 (default 50)")
    ap.add_argument("--no-trend", dest="trend", action="store_false", help="ignore the trend filter")
    ap.add_argument("--wick-pct", type=float, default=5.0, help="max wick as %% of the candle range (default 5)")
    ap.add_argument("--min-body", type=float, default=0.7, help="min body in ATR(14) (default 0.7)")
    ap.add_argument("--entry", choices=["open", "mid"], default="open", help="limit price: candle open (default) or body middle")
    ap.add_argument("--wait", type=int, default=9, help="candles the limit stays valid (default 9)")
    ap.add_argument("--buffer", type=float, default=3.0, help="pips beyond the swing for the stop (default 3)")
    ap.add_argument("--max-risk", type=float, default=0.0, help="skip setups whose stop is wider than this many pips (0 = off)")
    ap.add_argument("--breakout", action="store_true",
                    help="only no-wick candles that close beyond the high/low of the previous 20 bars (backtest +0.10R vs +0.01R)")
    ap.add_argument("--stack", action="store_true", help="allow several active orders on the same side (default: one)")
    ap.add_argument("--max-hold", type=int, default=96, help="bars after fill before closing at market (default 96)")
    ap.add_argument("--poll", type=float, default=3.0)
    ap.add_argument("--replay", nargs=2, metavar=("START", "END"))
    ap.add_argument("--backtest", action="store_true")
    ap.add_argument("--no-beep", action="store_true")
    ap.add_argument("--toast", default="SIGNAL,TOUCH,FILLED,TP,SL,EXPIRED", help="events that raise a Windows toast ('none' = off)")
    ap.add_argument("--popup", default="none", help="events that raise an always-on-top box, e.g. SIGNAL,FILLED")
    ap.add_argument("--test-alert", action="store_true")
    a = ap.parse_args()
    split = lambda s: () if s.strip().lower() == "none" else tuple(x.strip().upper() for x in s.split(","))
    a.toast_kinds, a.popup_kinds = split(a.toast), split(a.popup)
    if a.test_alert:
        bm.toast("USDJPY M15 test alert", "If you can read this, Windows alerts work.")
        if a.popup_kinds:
            bm.popup("USDJPY M15 test alert", "If you can read this, pop-ups work. Click OK.")
            _time.sleep(30)
        else:
            _time.sleep(3)
        return
    if not mt5.initialize():
        raise SystemExit(f"MT5 init failed: {mt5.last_error()}")
    mt5.symbol_select(a.symbol, True)
    info = mt5.symbol_info(a.symbol)
    pip = info.point * (10 if info.digits in (3, 5) else 1)
    if a.backtest:
        backtest(a, pip)
        return
    mk = lambda: Engine(pip, a.ema, a.trend, a.wick_pct, 0.3, a.min_body, a.entry, a.wait, a.buffer, a.max_risk, a.stack, a.max_hold, breakout=a.breakout)

    if a.replay:
        d = load(a.symbol)
        s, e = pd.Timestamp(a.replay[0]), pd.Timestamp(a.replay[1])
        eng = mk()
        eng.prep(d)
        for i in range(60, len(d) - 1):
            if d.time.iat[i] > e:
                break
            for kind, text, o in eng.step(d, i):
                if d.time.iat[i] >= s:
                    emit(a.symbol, d.time.iat[i], kind, text, a, beep=False)
        return

    d = load(a.symbol, 5000)
    eng = mk()
    eng.prep(d)
    i = len(d) - 2
    for j in range(max(60, i - 150), i + 1):          # silent warm-up: finds setups that are still alive
        eng.step(d, j)
    print(f"watching {a.symbol} M15 (server time): no-wick candle with trend EMA{a.ema}, {a.entry} limit valid {a.wait} candles, "
          f"stop = swing +{a.buffer}p, TP 1:1{", BREAKOUT candles only" if a.breakout else ", breakout flag shown on each alert"}. Alerts only - no orders are placed. Ctrl+C to stop.", flush=True)
    live = [o for o in eng.orders]
    if live:
        print("setups still alive from earlier candles:")
        for o in live:
            st = "OPEN (filled)" if o["fill_i"] is not None else "pending"
            print(f"  [{st}] " + eng.signal_text(o, d, o["sig_i"]))
    else:
        print("no live setups right now.")
    d = d.iloc[:-1].reset_index(drop=True)           # closed bars only from here on; the frame grows with every new bar
    touched = set()
    try:
        while True:
            _time.sleep(a.poll)
            fresh = load(a.symbol, 40, start=1)
            new = fresh[fresh.time > d.time.iat[-1]]
            if not new.empty:
                first = len(d)
                d = pd.concat([d, new], ignore_index=True)
                eng.prep(d)
                for k in range(first, len(d)):
                    for kind, text, o in eng.step(d, k):
                        emit(a.symbol, d.time.iat[k] + pd.Timedelta(minutes=TF_MIN), kind, text, a, beep=not a.no_beep)
            tick = mt5.symbol_info_tick(a.symbol)
            for o in eng.orders:       # live touch of a pending limit, before the bar closes
                if o["fill_i"] is None and id(o) not in touched:
                    hit = tick.ask <= o["entry"] if o["side"] > 0 else tick.bid >= o["entry"]
                    if hit:
                        touched.add(id(o))
                        emit(a.symbol, pd.to_datetime(tick.time, unit="s"), "TOUCH",
                             f"{eng.tag(o['side'])} entry {o['entry']:.3f} TOUCHED live (bid {tick.bid:.3f} / ask {tick.ask:.3f}) - "
                             f"your limit fills if placed; SL {o['sl']:.3f}, TP {o['tp']:.3f}", a, beep=not a.no_beep)
    except KeyboardInterrupt:
        print("stopped")


if __name__ == "__main__":
    main()
