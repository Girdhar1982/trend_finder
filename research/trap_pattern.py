"""
The user's 5/6 Nov pattern, coded literally (long version; short = mirror):
  1. RANGE : last BOX bars (default 12 = 1 hour) form a range no wider than W_MAX*ATR.
  2. PUSH  : first bar that CLOSES above the range high by >= BAIT_MIN*ATR (the early move that trapped the user).
  3. BACK  : within MAXW bars price returns to the range low: low <= range_low + TOL*ATR
             ('sweep' if it trades below the range low, 'retest' if it holds above it).
  4. TURN  : within RECL bars of that touch, a bullish bar closes back above the range low -> SIGNAL (BUY) at its close.
Causal: every decision at bar k uses bars <= k only. Fill = next open + spread.
Outcomes: +10/-10 bracket (36 bars), 3-ATR chandelier trail (structural stop = touch low - 1 pip, 144 bars), MFE before stop.
usage: python trap_pattern.py [BOX]
"""
import sys, datetime as dt, numpy as np, pandas as pd
import sweep_dataset as sd
PIP = 0.01
t, o, h, l, c, sp, atr, n = sd.t, sd.o, sd.h, sd.l, sd.c, sd.sp, sd.atr, sd.n
BOX = int(sys.argv[1]) if len(sys.argv) > 1 else 12
W_MAX, BAIT_MIN, MAXW, TOL, RECL = 5.0, 0.3, 24, 0.3, 3
tstr = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime('%Y-%m-%d %H:%M')


def detect():
    ev = []
    for s in (1, -1):
        O, H, L, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
        i = BOX + 20
        while i < n - 40:
            a = atr[i - 1]
            top, bot = H[i - BOX:i].max(), L[i - BOX:i].min()
            if (top - bot) <= W_MAX * a and C[i] > top + BAIT_MIN * a and C[i - 1] <= top:
                touch = next((j for j in range(i + 1, min(i + MAXW, n - 40)) if L[j] <= bot + TOL * a), None)
                rec = None if touch is None else next((k for k in range(touch, min(touch + RECL + 1, n - 40)) if C[k] > bot and C[k] > O[k]), None)
                if rec is not None:
                    ext = L[touch:rec + 1].min()
                    ev.append(dict(s=s, push=i, touch=touch, sig=rec, top=s * top, bot=s * bot, ext=s * ext,
                                   kind='sweep' if ext < bot else 'retest', a=a))
                    i = rec + 1; continue
            i += 1
    return sorted(ev, key=lambda e: e['sig'])


def outcomes(e):
    s = e['s']; k = e['sig']
    O, H, L, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
    ent = O[k + 1] + sp[k + 1]
    # fixed +/-10
    p10 = None
    for j in range(k + 1, min(n - 1, k + 36) + 1):
        if L[j] <= ent - 10 * PIP: p10 = -10.0; break
        if H[j] >= ent + 10 * PIP: p10 = 10.0; break
    if p10 is None: p10 = (C[min(n - 1, k + 36)] - ent) / PIP
    # structural stop + 3 ATR trail
    stop = s * e['ext'] - 1 * PIP; hh = ent; mfe = 0.0; tr = None
    for j in range(k + 1, min(n - 1, k + 144) + 1):
        if L[j] <= stop: tr = (min(stop, O[j]) - ent) / PIP; break
        hh = max(hh, H[j]); mfe = max(mfe, (H[j] - ent) / PIP); stop = max(stop, hh - 3 * atr[j])
    if tr is None: tr = (C[min(n - 1, k + 144)] - ent) / PIP
    return ent * s, p10, tr, mfe, (ent - (s * e['ext'] - PIP)) / PIP


if __name__ == '__main__':
    ev = detect()
    rows = []
    for e in ev:
        ent, p10, tr, mfe, risk = outcomes(e)
        rows.append(dict(sig_t=tstr(e['sig']), push_t=tstr(e['push']), touch_t=tstr(e['touch']), dir='BUY' if e['s'] > 0 else 'SELL',
                         kind=e['kind'], range_lo=min(e['top'], e['bot']), range_hi=max(e['top'], e['bot']), entry=ent,
                         stop_pips=risk, p10=p10, trail=tr, mfe=mfe, t=t[e['sig']]))
    df = pd.DataFrame(rows)
    print(f"BOX={BOX} bars ({BOX*5} min). Events: {len(df)}  ({len(df)/((t[-1]-t[0])/86400*5/7):.1f}/trading day)\n")
    print("== your two days ==")
    m = df[df.sig_t.str.startswith(('2026-11-05', '2026-11-06'))]
    print(m[['dir', 'kind', 'push_t', 'touch_t', 'sig_t', 'range_lo', 'range_hi', 'entry', 'stop_pips', 'p10', 'trail', 'mfe']].round(3).to_string(index=False))
    cut = df.t.quantile(0.6)
    print("\n== all history (fill next open + spread) ==")
    for lab, d in (("train", df[df.t < cut]), ("test", df[df.t >= cut])):
        print(f"  {lab}: n={len(d):3d}  +10/-10: win {np.mean(d.p10 > 0)*100:3.0f}% avg {d.p10.mean():+5.2f}p | trail exit avg {d.trail.mean():+5.2f}p win {np.mean(d.trail > 0)*100:3.0f}% | "
              f"MFE>=30p {np.mean(d.mfe >= 30)*100:3.0f}%  median stop {d.stop_pips.median():.1f}p")
    for k_ in ('sweep', 'retest'):
        d = df[df.kind == k_]; print(f"  {k_:6s}: n={len(d):3d}  +10/-10 avg {d.p10.mean():+5.2f}p win {np.mean(d.p10>0)*100:3.0f}% | trail avg {d.trail.mean():+5.2f}p")
    for k_ in ('BUY', 'SELL'):
        d = df[df.dir == k_]; print(f"  {k_:6s}: n={len(d):3d}  +10/-10 avg {d.p10.mean():+5.2f}p win {np.mean(d.p10>0)*100:3.0f}% | trail avg {d.trail.mean():+5.2f}p")
    print("\n== last 12 events (to check on the chart) ==")
    print(df[['sig_t', 'dir', 'kind', 'range_lo', 'range_hi', 'p10', 'trail']].tail(12).round(3).to_string(index=False))
    df.to_pickle(f'trap_events_{BOX}.pkl')
