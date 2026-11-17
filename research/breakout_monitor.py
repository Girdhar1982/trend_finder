"""
Breakout monitor (USDJPY M5, MT5 server time).  Run it in a terminal next to MT5:

    python research/breakout_monitor.py                  # live, USDJPY
    python research/breakout_monitor.py --symbol EURUSD --buffer 0.5
    python research/breakout_monitor.py --replay "2026-11-12 17:00" "2026-11-12 20:00"   # test on history

It judges CLOSED M5 bars only and watches these levels (recomputed every bar, from bars BEFORE the one being judged):
  00-02 range   high/low of server 00:00-02:00 today (pre-Tokyo; only after 02:00)
  1h range      high/low of the last 12 bars
  PDH / PDL     previous server day's high / low
  24h high/low  last 288 bars
  figure        the whole number just above / below price (e.g. 160.00 / 159.00)

Events:
  BREAK UP/DOWN    a bar CLOSES beyond a level by >= buffer (previous close was inside)
  WICK  above/below  bar poked past the level but CLOSED back inside (sweep - these usually reverse)
  FAILED           within 3 bars of a BREAK the price closes back inside the level
  HELD             3 bars after a BREAK, still beyond the level
Alerts: console + beep + log always; Windows toast for BREAK/WICK/FAILED (--toast none to turn off);
--popup BREAK,WICK adds an always-on-top box that stays until you click OK; --test-alert checks both work.
History caveat (see memory/usdjpy-sweep-reclaim-study): downside breaks of the 00-02 range failed about half the time and
no breakout rule here has a proven edge. This tells you WHAT happened; it is not a trade signal.
"""
import argparse
import math
import sys
import time as _time
from datetime import datetime

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

try:
    import winsound
except ImportError:  # not Windows
    winsound = None

LOG = "research/breakout_monitor.log"
RECHECK = 12     # bars before the same level/direction can alert again
CONFIRM = 3      # bars used for FAILED / HELD


class Monitor:
    def __init__(self, pip, buffer_pips, min_vol, min_wick=3.0, groups=("00-02", "PD", "24h", "fig")):
        self.pip = pip
        self.buf = buffer_pips * pip
        self.min_vol = min_vol
        self.min_wick = min_wick * pip
        self.groups = groups
        self.last = {}       # (level, dir) -> bar index of last alert
        self.pending = []    # confirmed breaks awaiting FAILED / HELD

    @staticmethod
    def atr(d, i, n=14):
        s = max(0, i - n + 1)
        h, l = d.high.values, d.low.values
        pc = d.close.values[s - 1:i] if s > 0 else np.r_[d.close.values[0], d.close.values[:i]]
        tr = np.maximum(h[s:i + 1] - l[s:i + 1], np.maximum(abs(h[s:i + 1] - pc), abs(l[s:i + 1] - pc)))
        return tr.mean()

    def levels(self, d, i):
        """list of (name, price, side) side='H' (upper level) or 'L' (lower level), from bars < i."""
        t = d.time
        out = []
        day = t.iat[i].normalize()
        today = d[(t >= day) & (t < day + pd.Timedelta("2h")) & (d.index < i)]
        if t.iat[i].hour >= 2 and len(today) >= 20:
            out += [("00-02 high", today.high.max(), "H"), ("00-02 low", today.low.min(), "L")]
        w = d.iloc[max(0, i - 12):i]
        out += [("1h high", w.high.max(), "H"), ("1h low", w.low.min(), "L")]
        prev_days = t[t < day].dt.normalize()
        if len(prev_days):
            pdv = d[t.dt.normalize() == prev_days.iloc[-1]]
            out += [("PDH", pdv.high.max(), "H"), ("PDL", pdv.low.min(), "L")]
        w = d.iloc[max(0, i - 288):i]
        out += [("24h high", w.high.max(), "H"), ("24h low", w.low.min(), "L")]
        pc = d.close.iat[i - 1]
        fu = math.floor(pc) + 1.0
        fd = math.floor(pc)
        out += [(f"{fu:.2f}", fu, "H"), (f"{fd:.2f}", fd, "L")]
        return out

    def process(self, d, i):
        """judge closed bar i. returns [(kind, text)] kind in BREAK / WICK / FAILED / HELD."""
        ev = []
        o, h, l, c = d.open.iat[i], d.high.iat[i], d.low.iat[i], d.close.iat[i]
        pc = d.close.iat[i - 1]
        a = self.atr(d, i - 1)
        va = d.tick_volume.iloc[max(0, i - 20):i].mean()
        vx = d.tick_volume.iat[i] / va if va > 0 else 0.0
        ctx = f"close {c:.3f}  range {(h - l) / self.pip:.0f}p ({(h - l) / a:.1f} ATR)  vol {vx:.1f}x"
        # resolve pending breaks first
        keep = []
        for p in self.pending:
            age = i - p["i"]
            back = (c < p["px"]) if p["dir"] == "UP" else (c > p["px"])
            if back:
                ev.append(("FAILED", f"{p['dir']} break of {p['name']} {p['px']:.3f} FAILED after {age} bar(s): close {c:.3f} is back inside"))
            elif age >= CONFIRM:
                ev.append(("HELD", f"{p['dir']} break of {p['name']} {p['px']:.3f} HELD {CONFIRM} bars: close {c:.3f}"))
            else:
                keep.append(p)
        self.pending = keep
        grouped = {}      # (kind, direction) -> [level texts], one line per bar
        for name, px, side in self.levels(d, i):
            grp = ("00-02" if name.startswith("00-02") else "1h" if name.startswith("1h") else "PD" if name.startswith("PD")
                   else "24h" if name.startswith("24h") else "fig")
            if grp not in self.groups:
                continue
            for direction in ("UP", "DOWN"):
                if (direction == "UP") != (side == "H"):
                    continue
                key = (name, direction)
                if i - self.last.get(key, -10**9) < RECHECK:
                    continue
                if direction == "UP":
                    brk = c > px + self.buf and pc <= px + self.buf
                    wick = h > px + self.buf and c <= px
                else:
                    brk = c < px - self.buf and pc >= px - self.buf
                    wick = l < px - self.buf and c >= px
                if brk and vx >= self.min_vol:
                    self.last[key] = i
                    self.pending.append(dict(i=i, name=name, px=px, dir=direction))
                    grouped.setdefault(("BREAK", direction), []).append(f"{name} {px:.3f}")
                elif wick:
                    ext = (h - px) if direction == "UP" else (px - l)
                    if ext < self.min_wick:
                        continue
                    self.last[key] = i
                    grouped.setdefault(("WICK", direction), []).append(f"{name} {px:.3f} (+{ext / self.pip:.1f}p)")
        for (kind, direction), names in grouped.items():
            if kind == "BREAK":
                ev.append((kind, f"BREAK {direction}: {', '.join(names)} | {ctx}"))
            else:
                ev.append((kind, f"WICK {'above' if direction == 'UP' else 'below'}, closed back inside: {', '.join(names)} | {ctx}"))
        return ev


def load(symbol, n=3000, start=0):
    """start=0 includes the forming bar, start=1 returns closed bars only."""
    r = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M5, start, n)
    if r is None or len(r) == 0:
        raise SystemExit(f"no data for {symbol}: {mt5.last_error()}")
    d = pd.DataFrame(r)
    d["time"] = pd.to_datetime(d.time, unit="s")
    return d


TOAST_PS = r"""
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$n = $x.GetElementsByTagName('text')
$n.Item(0).AppendChild($x.CreateTextNode($env:BM_TITLE)) | Out-Null
$n.Item(1).AppendChild($x.CreateTextNode($env:BM_BODY)) | Out-Null
$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show([Windows.UI.Notifications.ToastNotification]::new($x))
"""


def toast(title, body):
    """Windows toast (corner pop-up + notification centre). Non-blocking."""
    import os
    import subprocess
    env = dict(os.environ, BM_TITLE=title, BM_BODY=body[:240])
    try:
        subprocess.Popen(["powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", TOAST_PS],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except OSError as ex:
        print(f"toast failed: {ex}", flush=True)


def popup(title, body):
    """Always-on-top message box that stays until you click OK. Runs in a thread so the monitor keeps going."""
    import ctypes
    import threading
    # 0x30 = warning icon, 0x40000 = topmost, 0x10000 = foreground
    threading.Thread(target=lambda: ctypes.windll.user32.MessageBoxW(0, body, title, 0x30 | 0x40000 | 0x10000),
                     daemon=True).start()


def emit(symbol, ts, kind, text, beep=True, toast_kinds=(), popup_kinds=()):
    line = f"{ts:%Y-%m-%d %H:%M} {symbol} {text}"
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    if beep and winsound and kind in ("BREAK", "FAILED"):
        winsound.Beep(1200 if "UP" in text else 800, 300)
    head, _, rest = text.partition(":") if kind in ("BREAK", "WICK") else (text.split(" of ")[0], "", text)
    title = f"{symbol} {head.strip()}" if kind in ("BREAK", "WICK") else f"{symbol} {kind}"
    body = f"{ts:%H:%M} server  " + (rest.strip() if kind in ("BREAK", "WICK") else text)
    if kind in toast_kinds:
        toast(title, body)
    if kind in popup_kinds:
        popup(title, body)


def table(mon, d, i):
    """levels as they stand for the NEXT bar (d must contain the forming bar at index i + 1)."""
    px = d.close.iat[i]
    print(f"\nlevels now (last closed price {px:.3f}, bar {d.time.iat[i]:%Y-%m-%d %H:%M} server):")
    for name, lv, side in sorted(mon.levels(d, i + 1), key=lambda x: -x[1]):
        print(f"  {name:11} {lv:9.3f}  {(lv - px) / mon.pip:+7.1f}p")
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="USDJPY")
    ap.add_argument("--buffer", type=float, default=0.5, help="pips a close must clear a level by (default 0.5)")
    ap.add_argument("--min-vol", type=float, default=0.0, help="min tick volume vs 20-bar average for a BREAK (default 0 = off)")
    ap.add_argument("--min-wick", type=float, default=3.0, help="pips a WICK must poke past a level to be reported (default 3)")
    ap.add_argument("--levels", default="00-02,PD,24h,fig",
                    help="comma list from: 00-02, 1h, PD, 24h, fig (default excludes the noisy 1h range)")
    ap.add_argument("--poll", type=float, default=3.0, help="seconds between checks")
    ap.add_argument("--replay", nargs=2, metavar=("START", "END"), help="replay history instead of watching live")
    ap.add_argument("--no-beep", action="store_true")
    ap.add_argument("--toast", default="BREAK,WICK,FAILED",
                    help="events that raise a Windows toast (default BREAK,WICK,FAILED; 'none' to turn off)")
    ap.add_argument("--popup", default="none",
                    help="events that raise an always-on-top message box until you click OK, e.g. BREAK,WICK (default none)")
    ap.add_argument("--test-alert", action="store_true", help="fire one test toast (and popup) and exit")
    a = ap.parse_args()
    split = lambda s: () if s.strip().lower() == "none" else tuple(x.strip().upper() for x in s.split(","))
    toast_kinds, popup_kinds = split(a.toast), split(a.popup)
    if a.test_alert:
        toast("USDJPY test alert", "If you can read this, Windows alerts work.")
        if popup_kinds:
            popup("USDJPY test alert", "If you can read this, pop-ups work. Click OK.")
            _time.sleep(30)
        else:
            _time.sleep(3)
        return
    if not mt5.initialize():
        raise SystemExit(f"MT5 init failed: {mt5.last_error()}")
    mt5.symbol_select(a.symbol, True)
    info = mt5.symbol_info(a.symbol)
    pip = info.point * (10 if info.digits in (3, 5) else 1)
    mon = Monitor(pip, a.buffer, a.min_vol, a.min_wick, tuple(x.strip() for x in a.levels.split(",")))

    if a.replay:
        d = load(a.symbol, 60000)
        s, e = pd.Timestamp(a.replay[0]), pd.Timestamp(a.replay[1])
        first = d.index[d.time >= s][0]
        # warm up pending/last state on the 288 bars before the window
        for i in range(max(300, first - 300), len(d)):
            if d.time.iat[i] > e:
                break
            for kind, text in mon.process(d, i):
                if d.time.iat[i] >= s:
                    emit(a.symbol, d.time.iat[i], kind, text, beep=False)
        return

    d = load(a.symbol)
    i = len(d) - 2                                   # last CLOSED bar
    print(f"watching {a.symbol} M5 (server time), levels {a.levels}, buffer {a.buffer}p, min wick {a.min_wick}p. "
          f"Ctrl+C to stop. Log: {LOG}", flush=True)
    table(mon, d, i)
    # prime the dedupe/pending state silently with the last 40 bars
    for j in range(i - 40, i + 1):
        mon.process(d, j)
    mon.pending = []
    d = d.iloc[:-1].reset_index(drop=True)           # closed bars only from here on; the frame grows with every new bar
    try:
        while True:
            _time.sleep(a.poll)
            fresh = load(a.symbol, 40, start=1)
            new = fresh[fresh.time > d.time.iat[-1]]
            if new.empty:
                continue
            first = len(d)
            d = pd.concat([d, new], ignore_index=True)
            for k in range(first, len(d)):
                for kind, text in mon.process(d, k):
                    emit(a.symbol, d.time.iat[k], kind, text, beep=not a.no_beep,
                         toast_kinds=toast_kinds, popup_kinds=popup_kinds)
    except KeyboardInterrupt:
        print("stopped")


if __name__ == "__main__":
    main()
