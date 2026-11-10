"""
Does a detector catch the IMPORTANT swings early enough to be useful?
Swings (hindsight labels): zigzag with a 25-pip reversal threshold; legs >= 30 pips are 'important'.
A swing is CAUGHT by a signal in its direction whose signal bar is at/after the swing's start (the pivot) and whose
entry (next open) is within the first third of the leg (>= 2/3 of the move still ahead).
Precision = share of signals that catch some important swing. All detectors are causal (decide at bar close).
"""
import numpy as np, pandas as pd, datetime as dt
import sweep_dataset as sd
from stretch_core import S
PIP = 0.01
t, o, h, l, c, sp, atr, n = sd.t, sd.o, sd.h, sd.l, sd.c, sd.sp, sd.atr, sd.n
tstr = lambda i: dt.datetime.fromtimestamp(t[i], dt.timezone.utc).strftime('%m-%d %H:%M')


def zigzag(R):
    piv = []; d = 0; ext_i = 0; ext_p = c[0]
    for i in range(1, n):
        if d >= 0:
            if h[i] > ext_p or d == 0 and h[i] - l[ext_i] > 0: pass
        if d == 0:
            if h[i] - l[:i + 1].min() >= R * PIP: d = 1; ext_i = i; ext_p = h[i]; piv.append((int(np.argmin(l[:i + 1])), l[:i + 1].min(), -1))
            elif h[:i + 1].max() - l[i] >= R * PIP: d = -1; ext_i = i; ext_p = l[i]; piv.append((int(np.argmax(h[:i + 1])), h[:i + 1].max(), 1))
            continue
        if d == 1:
            if h[i] >= ext_p: ext_i, ext_p = i, h[i]
            elif ext_p - l[i] >= R * PIP: piv.append((ext_i, ext_p, 1)); d = -1; ext_i, ext_p = i, l[i]
        else:
            if l[i] <= ext_p: ext_i, ext_p = i, l[i]
            elif h[i] - ext_p >= R * PIP: piv.append((ext_i, ext_p, -1)); d = 1; ext_i, ext_p = i, h[i]
    legs = []
    for (i0, p0, k0), (i1, p1, k1) in zip(piv[:-1], piv[1:]):
        legs.append(dict(start=i0, end=i1, p0=p0, p1=p1, s=1 if p1 > p0 else -1, size=abs(p1 - p0) / PIP))
    return pd.DataFrame(legs)


# ---------------- detectors (all causal, return list of (bar, sign)) ----------------
def det_trap(BOX=12, W_MAX=5.0, BAIT=0.3, MAXW=24, TOL=0.3, RECL=3):
    out = []
    for s in (1, -1):
        O, H, L, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c); pend = []
        for i in range(BOX + 20, n - 2):
            fired = False
            for p in list(pend):
                if p[4] < 0:
                    if i <= p[0] + MAXW - 1 and L[i] <= p[2] + TOL * p[3]: p[4] = i
                    elif i > p[0] + MAXW - 1: pend.remove(p); continue
                if p[4] >= 0:
                    if i <= p[4] + RECL:
                        if C[i] > p[2] and C[i] > O[i]: out.append((i, s)); fired = True; break
                    else: pend.remove(p)
            if fired: pend = []; continue
            a = atr[i - 1]; top = H[i - BOX:i].max(); bot = L[i - BOX:i].min()
            if top - bot <= W_MAX * a and C[i] > top + BAIT * a and C[i - 1] <= top: pend.append([i, top, bot, a, -1])
    return out


def pivots_lows(L, w):
    """confirmed pivot lows: index j with L[j] the min of [j-w, j+w]; known at bar j+w"""
    m = pd.Series(L).rolling(2 * w + 1, center=True).min().values
    return np.where(L == m)[0]


def det_pivot(w=3, mode='sweep', TOL=0.3, gap=6, recl=2):
    """mode sweep: low breaks the latest confirmed pivot low and a bar closes back above it within recl bars.
       mode retest: low comes within TOL*ATR of the pivot low without breaking it, bullish close above it."""
    out = []
    for s in (1, -1):
        O, H, L, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
        pl = pivots_lows(L, w); conf = pl + w; k = 0; last_p = None; last = -99; broke = -1
        for i in range(30, n - 2):
            while k < len(pl) and conf[k] <= i - 1: last_p = (pl[k], L[pl[k]]); k += 1; broke = -1
            if last_p is None or i - last < gap: continue
            lv = last_p[1]; a = atr[i]
            if mode == 'sweep':
                if L[i] < lv and broke < 0: broke = i
                if broke >= 0 and i - broke <= recl and C[i] > lv and C[i] > O[i]:
                    out.append((i, s)); last = i; broke = -1; last_p = (i, L[i])   # the sweep low becomes the new level
                elif broke >= 0 and i - broke > recl: last_p = None; broke = -1   # level lost: wait for a new pivot
            else:
                if lv <= L[i] <= lv + TOL * a and C[i] > O[i] and C[i] > lv: out.append((i, s)); last = i
    return out


def det_choch(N=24, w=3, gap=6, within=24):
    """structure break: price made a new N-bar low within the last `within` bars, then closes above the latest
       confirmed pivot HIGH (the last lower high) -> trend change up."""
    out = []
    for s in (1, -1):
        O, H, L, C = (o, h, l, c) if s > 0 else (-o, -l, -h, -c)
        ph = pivots_lows(-H, w); conf = ph + w; k = 0; last_ph = None; last = -99
        newlow = pd.Series(L).rolling(N).min().values
        recent_low = -10**9
        for i in range(N + 5, n - 2):
            while k < len(ph) and conf[k] <= i - 1: last_ph = H[ph[k]]; k += 1
            if L[i] <= newlow[i] + 1e-12: recent_low = i
            if last_ph is None or i - last < gap: continue
            if i - recent_low <= within and C[i] > last_ph and C[i - 1] <= last_ph:
                out.append((i, s)); last = i
    return out


def evaluate(name, sig, legs, R30=30):
    big = legs[legs['size'] >= R30].reset_index(drop=True)
    sig = sorted(set(sig))
    caught = np.zeros(len(big), bool); good = 0
    # index legs by direction for speed
    for i, s in sig:
        if i + 1 >= n: continue
        ent = o[i + 1]
        m = big[(big.s == s) & (big.start <= i) & (big.end > i)]
        hit = False
        for idx, lg in m.iterrows():
            frac = (ent - lg.p0) / (lg.p1 - lg.p0)
            if frac <= 1 / 3: caught[idx] = True; hit = True
        good += hit
    days = (t[-1] - t[0]) / 86400 * 5 / 7
    return dict(detector=name, signals_per_day=round(len(sig) / days, 1), precision=round(good / max(1, len(sig)) * 100, 1),
                recall_30=round(caught.mean() * 100, 1),
                recall_50=round(caught[(big['size'] >= 50).values].mean() * 100, 1) if (big['size'] >= 50).any() else np.nan), caught


if __name__ == '__main__':
    legs = zigzag(25)
    big = legs[legs['size'] >= 30]
    days = (t[-1] - t[0]) / 86400 * 5 / 7
    print(f"important swings (>=30p, 25p zigzag): {len(big)} = {len(big)/days:.1f}/day; >=50p: {(big['size']>=50).sum()}; median {big['size'].median():.0f}p\n")
    D = {
        'trap 1h box (current)': det_trap(12),
        'trap 30m box': det_trap(6),
        'trap 2h box': det_trap(24),
        'pivot sweep w3': det_pivot(3, 'sweep'),
        'pivot sweep w6': det_pivot(6, 'sweep'),
        'pivot retest w3': det_pivot(3, 'retest'),
        'pivot retest w6': det_pivot(6, 'retest'),
        'structure break (CHoCH) w3': det_choch(24, 3),
        'structure break (CHoCH) w6': det_choch(48, 6),
    }
    D['ALL traps (30m/1h/2h)'] = D['trap 1h box (current)'] + D['trap 30m box'] + D['trap 2h box']
    D['trap1h + pivot sweep/retest w6'] = D['trap 1h box (current)'] + D['pivot sweep w6'] + D['pivot retest w6']
    D['trap1h + pivots w6 + CHoCH w6'] = D['trap1h + pivot sweep/retest w6'] + D['structure break (CHoCH) w6']
    # random baseline with same rate as the current detector: reversal bars at random
    rng = np.random.default_rng(0)
    rr = [(int(i), int(s)) for i, s in zip(rng.integers(100, n - 2, len(D['trap 1h box (current)'])), rng.choice([1, -1], len(D['trap 1h box (current)'])))]
    D['RANDOM (same count as current)'] = rr
    res = []; CAUGHT = {}
    for k, v in D.items():
        r, cg = evaluate(k, v, legs); res.append(r); CAUGHT[k] = cg
    print(pd.DataFrame(res).to_string(index=False))
    pd.to_pickle((legs, D, CAUGHT), 'swing_recall.pkl')
