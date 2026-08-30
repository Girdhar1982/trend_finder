# Hull FVG — H4 imbalances, traded on M15

**A higher-timeframe fair value gap / order block / market structure study, drawn on the chart you actually trade.**

Version 1.00 · Last updated 2026-08-29

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [Files and installation](#2-files-and-installation)
3. [The method](#3-the-method)
4. [Reading the chart](#4-reading-the-chart)
5. [The setup state machine](#5-the-setup-state-machine)
6. [Non-repainting behaviour](#6-non-repainting-behaviour)
7. [Input reference](#7-input-reference)
8. [The Experts log](#8-the-experts-log)
9. [Alerts](#9-alerts)
10. [Testing protocol](#10-testing-protocol)
11. [Tuning](#11-tuning)
12. [Known limitations](#12-known-limitations)
13. [Version history](#13-version-history)

---

## 1. What this is

Attach **`HullTrendFVG_MT5`** to an **M15** chart and leave the defaults alone. It scans **H4** for
recent unfilled imbalances and draws them, together with everything needed to decide whether one is
tradable:

| On the chart | What it is |
|---|---|
| Filled green / red boxes | **H4 fair value gaps** — demand (green) and supply (red) |
| Dotted 50% line inside a box | **Consequent encroachment** — half the gap repaired |
| Dotted blue / orchid boxes | **H4 order blocks** — the candle the breaking move came from |
| Dashed gold segments labelled `H4 BOS` / `H4 CHoCH` | **H4 market structure** — the level that gave way, and how long it held |
| The same labelled `M15 BOS` / `M15 CHoCH` | **Chart-timeframe structure** — the entry trigger |
| Arrow + dotted `SL` / `TP` rays | The live setup, when one is armed |
| Panel, top left | Bias, active zone, distance, state, entry / stop / target / R |

> **This is a chart study, not a proven profitable strategy.** No EA reads it, and nothing here has
> been validated as profitable on live markets. It puts the evidence on one screen; the decision is
> still yours.

### Why it is a separate indicator

Folding this into `HullTrend_MT5` would extend that indicator's **positional `iCustom` argument
list** — the single most fragile contract in this system, mirrored by hand in
`HullTrendEA_Core.mqh` — to publish data the EA never asks for. It is a standalone study, the same
way `HullTrendSR_MT5` and `HullTrendLG_MT5` are.

---

## 2. Files and installation

```
HullTrendFVG.mqh            ->  MQL5\Include\        the detection engine
HullTrendFVG_MT5.mq5        ->  MQL5\Indicators\     the chart study
HullTrendFVG_SelfTest.mq5   ->  MQL5\Experts\        the detection self-test
```

`HullTrendFVG.mqh` includes `HullTrendSR.mqh` for `SRPickHTF` / `SRTFName` / `SRFormatDist` /
`SRFormatAge`. That is deliberate reuse, not an accident: **the higher timeframe a chart resolves
to has to be the same answer everywhere in this suite**, and a second copy of `SRPickHTF` is exactly
how that stops being true. `HullTrendSR.mqh` must be present in `MQL5\Include\`.

Compile with MetaEditor (`/compile:` accepts the repo path; the `<...>` includes resolve from the
terminal's `Include` folder, so **copy `HullTrendFVG.mqh` there first**). Note that MetaEditor
returns **exit code 1 on a successful compile** — read the `Result: N errors, M warnings` line
instead.

---

## 3. The method

### 3.1 The three-candle gap

A bullish FVG is a hole in the delivery: candle 3 never traded down to candle 1, so the range
between them was skipped.

```
     c1      c2      c3
      |              |        top    = low of c3
      |     ####     |        bottom = high of c1
      |     ####     |        (#### = the gap - unfilled)
```

Formally, on the H4 series (shift `i` is the newest of the three):

- **Bullish**: `low[i] > high[i+2]` → zone `[high[i+2], low[i]]`
- **Bearish**: `high[i] < low[i+2]` → zone `[high[i], low[i+2]]`

The gap must be at least `InpMinGapATR × ATR(H4)` wide. Without that filter every second candle on
a fast market produces a one-tick "imbalance" and the chart becomes unreadable.

### 3.2 Market structure — BOS and CHoCH

A swing needs `InpFractal` **closed** bars either side, so it is only examined once it can no longer
change. A **close** beyond the newest unbroken swing is a break:

- **BOS** (break of structure) — it continues the prevailing direction.
- **CHoCH** (change of character) — it reverses it. This is the one that turns the bias.

The swing is then **consumed**: the next break needs the next confirmed swing, so one level cannot
report the same break twice.

The engine walks **every** available bar to establish direction, but only *reports* breaks inside
the scan window. Without that, the oldest break in view would always be labelled a BOS whatever
preceded it.

### 3.3 Order blocks

The last candle closing **against** the break, searched back up to `FVG_OB_SEARCH` (30) bars from
the break bar. That is the candle the move away began at. `InpOBBodyOnly` picks between the body
(tighter — where the orders were worked) and the full range (safer).

### 3.4 Mitigation

A zone carries a **fill** from 0 to 1: how much of it price has taken back, measured **from the edge
price approaches from** — a demand zone is eaten downwards from its top, a supply zone upwards from
its bottom. Once the fill reaches `InpMitigatedPct`, the zone is retired and disappears from the
chart. The panel still reports how many were retired, because *"no zones"* and *"every zone already
filled"* are different markets.

Fill is computed from precomputed running extremes rather than a scan per zone, which is what keeps
a 500-bar lookback cheap enough to run on every refresh.

### 3.5 The trigger

The higher timeframe says **where** and **which way**. It cannot say **when** — by the time an H4
candle confirms the turn, the M15 move is half over. So the trigger is a **chart-timeframe structure
break in the HTF direction**, taken while price is inside, or has just left, the HTF zone.
`InpArmBars` is what *"just left"* means; without it, a break three days after the last visit would
still be reported as an entry from that zone.

**Stop** goes beyond the far edge of the **zone** (plus a 0.25 × H4 ATR buffer), not beyond the
trigger bar: the zone is the reason for the trade, so the zone failing is what makes it wrong. The
buffer is in H4 ATR because the zone is an H4 object — a chart-TF buffer would be invisible against
an H4 gap.

**Target**, in order of preference: the near edge of the first opposing zone in the way → the
untaken swing that is the actual objective → a plain 2R fallback, so the number is never blank.

---

## 4. Reading the chart

```
 price
   |                                                    .......... TP  (untaken H4 high)
   |          ____________________________
   |         |############################|  <- H4 supply, 0% filled
   |         |____________________________|
   |   \  /\                          /\
   |    \/  \    M15 CHoCH ------>  _/  \        the trigger
   |         \   ______________    /
   |          \ |##############|  /   <- H4 demand FVG, 40% filled, price inside
   |           \|##############| /       arrow prints here
   |            |______________|
   |         ............................................ SL (below the zone + buffer)
```

- A **thicker box border** marks the **active** zone — the one the panel and the setup refer to.
- The label at a box's right edge reads `H4 FVG+  40%`, and gains a `<` when it is the active one.
- Hover any box for the exact bounds, width, fill and age.

The panel:

```
HULL FVG   EURUSD   H4 zones on M15   H4 ATR 62.0 pips
bias  BULLISH  H4 CHoCH at 1.16240  (14h ago)
zone  FVG+  1.15980 - 1.16110   40% filled   INSIDE  (0.00 ATR)
state IN ZONE
trade waiting for a M15 bullish break in the zone
zones 3 bull, 1 bear drawn   (39 found, 30 mitigated)
```

Every distance is quoted in **H4 ATR** — the ruler the zones and the stop buffer are built with.

---

## 5. The setup state machine

| State | Meaning | What to do |
|---|---|---|
| `no setup` | No H4 direction, or no zone on the bias side of price | Nothing here |
| `waiting` | Direction and a zone, but price is away from it | Set an alert, walk away |
| `IN ZONE` | Price is inside the zone | Watch the M15 for the turn |
| `TRIGGER` | M15 broke structure in the H4 direction, inside `armBars` of a zone visit | The entry, with SL / TP / R printed |

A zone **above** price in a bullish bias is never selected: price came from below it, so it has
already done its work and is not a place to buy a retracement. The mirror rule applies to shorts.

---

## 6. Non-repainting behaviour

Every pattern needs **closed** bars:

- A gap needs its third candle closed (scan starts at shift 1).
- A swing needs `fractal` closed bars on its right before it is examined.
- A break needs a **close** beyond the level, not a wick.
- The trigger comes from a closed chart bar, so an alert cannot fire twice for the same break.

A zone can therefore appear **one bar late**, but it never moves or vanishes once drawn.

The one value that tracks the live bar is a zone's **fill percentage**, and that is **monotone**:
price can trade further into a gap but never back out of one, so a fill can rise within a bar and
never fall back. Including the forming bar there is what lets the chart show a zone being tested
*right now* rather than fifteen minutes late.

---

## 7. Input reference

### Higher timeframe (where the zones come from)

| Input | Default | Notes |
|---|---|---|
| `InpHTFAuto` | `false` | Derive the HTF from the chart TF instead of naming it |
| `InpHTF` | `PERIOD_H4` | The HTF when Auto is off. **This is the H4 in "H4 on M15"** |
| `InpHTFMult` | `16.0` | Auto mode: target HTF as a multiple of the chart TF |

Explicit `H4` is the default on purpose: attach to M15, H1 or M5 and you get H4 zones either way.
If the resolved HTF is not *above* the chart timeframe, the indicator says so in the log and falls
back to single-timeframe zones rather than silently drawing a filter that filters nothing.

### Zones

| Input | Default | Notes |
|---|---|---|
| `InpLookback` | `180` | H4 bars scanned (≈ 30 trading days). Floored at 40 |
| `InpMaxAgeBars` | `0` | Drop zones older than N H4 bars (0 = the whole lookback) |
| `InpMinGapATR` | `0.25` | A gap must be this wide in H4 ATR. **The main noise knob** |
| `InpUseGaps` | `true` | Detect three-candle imbalances |
| `InpUseOB` | `true` | Detect order blocks |
| `InpOBBodyOnly` | `false` | OB box = body instead of the full range |
| `InpMitigatedPct` | `100.0` | Retire a zone once this much of it is filled |
| `InpMaxPerSide` | `4` | Keep at most N zones per direction, newest first |
| `InpATRPeriod` | `14` | ATR period, used on both timeframes |

### Structure

| Input | Default | Notes |
|---|---|---|
| `InpFractal` | `2` | Closed bars each side of an H4 swing. Higher = fewer, bigger swings |
| `InpShowBreaks` | `true` | Draw the BOS / CHoCH markers |
| `InpMaxBreaks` | `4` | How many, **per timeframe** (0 = all) |

### Entry on this chart

| Input | Default | Notes |
|---|---|---|
| `InpEntryFractal` | `2` | Closed bars each side of a chart-TF swing |
| `InpArmBars` | `12` | Chart bars a visit to the zone stays live (12 × M15 = 3 hours) |
| `InpShowSetup` | `true` | Draw the arrow, stop and target |

### Appearance, panel, log, alerts

Colours for each zone kind and side, the 50% line, labels, font size, right-edge padding, the
intrabar refresh throttle (`InpRedrawSecs`, default 5 s), panel corner and colours, how many log
lines per section, and the five alert channels (`Alert` / sound / push / email, all off except the
pop-up).

---

## 8. The Experts log

`OnInit` prints the **resolved** configuration — effective values with the engine's clamps already
applied, so the line describes the scan that ran and not the dialog you filled in:

```
Hull FVG config: htf=H4 chart=M15 lookback=180 scanDepth=180 minGap=0.25xATR fractal=2
                 gaps=on ob=on mitigated=100% maxPerSide=4 entryFractal=2 armBars=12 atrPeriod=14
```

Then, on attach and whenever a new zone forms:

```
HullFVG | LIST  | EURUSD H4 zones on M15: 4 live, 30 mitigated  |  bias BULLISH since the H4 CHoCH at 2026.08.18 12:00
HullFVG | ZONE  | 2026.08.19 08:00 | FVG+  1.15980 - 1.16110  13.0 pips wide   40% filled  INSIDE  3 H4 bars ago
HullFVG | BOS   | 2026.08.19 04:00 | up   broke 1.16240 formed 2026.08.15 16:00
HullFVG | SETUP | IN ZONE  -  zone 0.00 ATR away
```

Lines are prefixed `HullFVG |` so the Experts tab can be pasted and read back the way the EA log is.

---

## 9. Alerts

One alert per trigger bar, through every channel switched on, plus an unconditional `Print` — an
alert that fired at 3am and was dismissed otherwise leaves no trace anywhere:

```
EURUSD M15: LONG setup from the H4 FVG+ zone - entry 1.16050  SL 1.15825  TP 1.16480  1.91R
```

Because the trigger comes from a closed chart bar, the 5-second refresh cannot fire it twice.

---

## 10. Testing protocol

**`HullTrendFVG_SelfTest.mq5` — run it after any edit to `HullTrendFVG.mqh`. Non-negotiable.**

It checks the geometry against a hand-built 13-bar series with no market data involved (running
extremes, fill measurement from either edge, BOS vs CHoCH, swing consumption, untaken liquidity,
both order blocks, body-only boxes, the reporting window, zone selection, targets, ordering and
every clamp), and then runs the whole engine over **real history** and asserts the invariants that
must hold on any symbol — including re-deriving every detected gap from its own three bars.

Drag it onto a chart, or run it headlessly:

```powershell
& "C:\Program Files\Go MetaTrader 5\terminal64.exe" /config:"...\HullTrend\fvg_selftest.ini"
```

Results land in the agent log named at the end of `<data>\Tester\logs\<yyyymmdd>.log` (both
UTF-16). Look for the verdict:

```
VERDICT: 74 passed, 0 failed  -  ALL GOOD
```

Baseline at v1.00, EURUSD M15 / H4, 2026-08-20 → 2026-08-28: **74 passed, 0 failed**; 39 zones
found, 30 retired as mitigated, 4 drawn, 18 structure breaks, bias bullish.

---

## 11. Tuning

| Symptom | Knob |
|---|---|
| Too many small boxes | Raise `InpMinGapATR` to 0.4–0.6 |
| Chart too busy | Lower `InpMaxPerSide` to 2, or `InpMaxBreaks` to 2 |
| Only want untouched zones | Set `InpMitigatedPct` to `1.0` — anything price has touched at all retires |
| Zones vanish too readily | `InpMitigatedPct` is already at its cap of 100, so a zone only goes when price has been clean through it. Raise `InpMinGapATR` instead, so the survivors are gaps worth respecting |
| Structure too noisy on H4 | Raise `InpFractal` to 3 |
| Trigger fires too easily on M15 | Raise `InpEntryFractal` to 3, or lower `InpArmBars` |
| Nothing ever triggers | Raise `InpArmBars`; on a slow pair 12 M15 bars can expire before the turn |
| Want D1 zones instead | Set `InpHTF = PERIOD_D1` and raise `InpLookback` to ~250 |

On a **fast symbol** (indices, crypto) start at `InpMinGapATR = 0.4`; on quiet majors 0.2 is
readable.

---

## 12. Known limitations

- **A zone is not a signal.** Price fills gaps against the trend all day. The bias, the structure
  break and the trigger are what make one tradable, and even then this is a study, not a system.
- **Order blocks near the edge of the lookback can be missed.** The origin candle is searched up to
  30 bars back from a break; if that reaches past the window, no OB is emitted for that break.
- **Double tops and bottoms produce no swing.** The fractal test is strict on both sides, which is
  the honest answer — neither candle is the turn — but it does mean a clean double top is not a
  level the structure pass will ever report a break of.
- **`InpMitigatedPct` uses wicks, not closes.** A wick clean through a zone retires it even if no
  candle closed beyond. That is the stricter reading; ICT convention for order blocks is often
  looser.
- **The R:R is arithmetic, not a forecast.** It assumes the target is reached before the stop, which
  is exactly the thing in question.
- **One zone at a time.** The setup tracks the nearest qualifying zone only; a stack of three
  overlapping H4 gaps is drawn in full but scored as one.

---

## 13. Version history

### 1.00 — 2026-08-29

Initial release. H4 fair value gaps, order blocks and BOS / CHoCH drawn on the trading chart, with a
chart-timeframe break as the entry trigger, ATR-scaled stop and structure-aware target, summary
panel, Experts-log reporting and five alert channels. Engine shared via `HullTrendFVG.mqh`;
timeframe resolution and formatting reused from `HullTrendSR.mqh`. Self-test: 74 assertions,
0 failures.
