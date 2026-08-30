# Hull Trend System

**A Hull Moving Average trend-flip system: a whipsaw-filtered trend indicator and a stop-and-reverse Expert Advisor.**

Version 2.30 (indicator) · 1.20 (S/R indicator) · 1.00 (liquidity-grab indicator) · 1.00 (FVG indicator) · 1.10 (breakout indicator) · 1.40 (EA) · Last updated 2026-08-29

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [System architecture](#2-system-architecture)
3. [Installation](#3-installation)
4. [The indicator maths](#4-the-indicator-maths)
5. [Trend state machine](#5-trend-state-machine)
6. [Non-repainting behaviour](#6-non-repainting-behaviour)
7. [Reading the chart](#7-reading-the-chart)
8. [Input reference — indicator](#8-input-reference--indicator)
9. [Buffer contract](#9-buffer-contract)
10. [Alerts](#10-alerts)
11. [Testing protocol](#11-testing-protocol)
12. [Backtesting](#12-backtesting)
13. [Troubleshooting](#13-troubleshooting)
14. [Known limitations](#14-known-limitations)
15. [Maintenance checklist](#15-maintenance-checklist)
16. [Liquidity grabs](#16-liquidity-grabs)
17. [Range breakouts](#17-range-breakouts)
18. [Version history](#18-version-history)

---

## 1. What this is

A Hull Moving Average trend engine and its execution layer, plus two chart studies of the
market structure around them:

- **`HullTrend_MT5.mq5`** — an indicator that draws the Hull line colour-coded by slope, marks trend **reversals** with arrows, and fires alerts. Its distinguishing feature is **whipsaw control**: a minimum slope (optionally scaled by ATR) that must be exceeded before a bar is allowed to argue for a trend change, plus an N-bar confirmation before a flip is actually declared.
- **`HullTrendEA*.mq5`** — a **stop-and-reverse** trend follower that trades the flips the indicator publishes. The natural exit is the opposite flip; the stop is a disaster brake, not a target.
- **`HullTrendSR_MT5.mq5`** — draws the support/resistance levels the EA vetoes against, from the very engine the EA runs. Documented in `HullTrend_EA_Documentation.md` §23.
- **`HullTrendLG_MT5.mq5`** — marks **liquidity grabs**: bars that pierce a recent swing and close back inside it. Standalone; no EA reads it. See §16.
- **`HullTrendFVG_MT5.mq5`** — draws **higher-timeframe fair value gaps, order blocks and BOS/CHoCH** on the trading chart (H4 zones on an M15 chart by default) and scores the entry. Standalone; no EA reads it. Documented separately in `HullTrendFVG_Documentation.md`.
- **`HullTrendBO_MT5.mq5`** — marks the **N most recent range breakouts** on a timeframe you choose, with the range that broke, how hard it pushed, how far it ran, and which ones failed. Standalone; no EA reads it. See §17.

> **Cost warning (read this first).** A flip system pays the spread on *every* reversal. Round-trip cost as a fraction of ATR(14) is roughly **0.5–0.9× on M1 FX, 0.25–0.4× on M5 and 0.12–0.2× on M15**. M1 on retail FX does not clear its own costs. **M5 is the practical floor for majors**; M1 only makes sense where the spread is tiny relative to the range (index CFDs, futures).

> **This is a trend-following framework, not a proven profitable strategy.** Nothing here has been validated as profitable on live markets.

---

## 2. System architecture

```
┌──────────────────────────────────────────────────────────┐
│  HullTrend_MT5.mq5               (MQL5\Indicators\)      │
│  ─────────────────────────────────────────────────────   │
│  THE MODEL. HMA line, colour, flip arrows, alerts.       │
│                                                          │
│   HMA = LWMA(2*LWMA(price,n/2) - LWMA(price,n), √n)      │
│   slope = HMA[i] - HMA[i-1]  vs  ATR-scaled threshold    │
│   streak + confirm bars  ->  trend flips                 │
│                                                          │
│  Outputs: 7 buffers, colour-coded line, arrows           │
└────────────────────────┬─────────────────────────────────┘
                         │ iCustom (24 args) + CopyBuffer
                         ▼
┌──────────────────────────────────────────────────────────┐
│  HullTrendEA*.mq5                (MQL5\Experts\)         │
│  ─────────────────────────────────────────────────────   │
│  EXECUTION ONLY. Stop-and-reverse the flips.             │
│                                                          │
│   Three thin wrappers around HullTrendEA_Core.mqh:       │
│     HullTrendEA.mq5        generic profile               │
│     HullTrendEA_Forex.mq5  M5+, 1.5xATR stop, Fri cutoff │
│     HullTrendEA_Crypto.mq5 H1+, 2.25xATR stop, 24/7      │
└──────────────────────────────────────────────────────────┘
```

Two chart studies sit alongside, each sharing its engine rather than duplicating it:

```
┌──────────────────────────────────────────────────────────┐
│  HullTrendSR_MT5.mq5             (MQL5\Indicators\)      │
│  ─────────────────────────────────────────────────────   │
│  Draws the S/R levels the EA vetoes against.             │
│  Engine: HullTrendSR.mqh   <- SHARED WITH THE EA         │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  HullTrendLG_MT5.mq5             (MQL5\Indicators\)      │
│  ─────────────────────────────────────────────────────   │
│  Marks liquidity grabs; lists them in the Experts tab.   │
│  Engine: HullTrendLG.mqh   <- no EA consumer             │
└──────────────────────────────────────────────────────────┘
```

**Why the split matters.** The indicator is independently testable without risking a cent. When a trade looks wrong: an arrow the EA ignored → **execution bug**, look in the EA; an arrow that should not exist → **model bug**, look in the indicator.

---

## 3. Installation

Files belong in your terminal's data folder (**File → Open Data Folder** in MT5):

| File | Destination |
|---|---|
| `HullTrend_MT5.mq5` | `MQL5\Indicators\` |
| `HullTrendSR_MT5.mq5` | `MQL5\Indicators\` |
| `HullTrendSR.mqh` | `MQL5\Include\` — **shared by the EA and the S/R indicator**, one copy only |
| `HullTrendLG_MT5.mq5` | `MQL5\Indicators\` |
| `HullTrendFVG_MT5.mq5` | `MQL5\Indicators\` |
| `HullTrendFVG.mqh` | `MQL5\Include\` |
| `HullTrendBO_MT5.mq5` | `MQL5\Indicators\` |
| `HullTrendBO.mqh` | `MQL5\Include\` |
| `HullTrendLG.mqh` | `MQL5\Include\` — the liquidity-grab engine |
| `HullTrendEA.mq5` | `MQL5\Experts\` |
| `HullTrendEA_Forex.mq5` | `MQL5\Experts\` |
| `HullTrendEA_Crypto.mq5` | `MQL5\Experts\` |
| `HullTrendEA_Core.mqh` | `MQL5\Experts\` |

Compile each (F7 in MetaEditor), then **right-click Navigator → Refresh**.

**Command-line compile:**

```powershell
& "C:\Program Files\Go MetaTrader 5\MetaEditor64.exe" `
    /compile:"<full path>\HullTrend_MT5.mq5" `
    /log:"<full path>\hull.log"
```

Two gotchas:

- The log is **UTF-16**. Read it with `Get-Content -Encoding Unicode` or it looks empty.
- MetaEditor returns **exit code 1 on success**. Parse the `Result: N errors, M warnings` line, never the exit code.

**Requirements:** the EA requires `HullTrend_MT5.ex5` in `MQL5\Indicators\`, loaded by name via `iCustom`. The indicator needs ~25 bars of history before the line appears (the Hull of period `n` needs `n + √n` bars); nothing is drawn before that.

---

## 4. The indicator maths

### 4.1 The Hull moving average

```
  HMA = LWMA( 2 · LWMA(price, n/2) − LWMA(price, n) , √n )
```

where `LWMA(x, k)` is a linearly-weighted moving average of `x` over `k` bars. The two inner LWMAs are **rolled forward incrementally (O(1) per bar)** rather than recomputed per window — the original recomputed every window from scratch, which is O(period) per bar.

The applied price is selectable (`PRICE_CLOSE` default; open/high/low/median/typical/weighted available).

### 4.2 Slope and colour

The trend direction of bar `i` is decided by the **slope** `HMA[i] − HMA[i−1]`, compared against a minimum threshold:

| Slope filter mode | Threshold | Meaning |
|---|---|---|
| `SLOPE_FILTER_NONE` | 0 | Any slope change flips the trend — maximum sensitivity, maximum whipsaw |
| `SLOPE_FILTER_POINTS` | `InpSlopePoints × point` | Fixed minimum slope, instrument-specific |
| `SLOPE_FILTER_ATR` (default) | `InpSlopeATRMul × ATR` | **Adaptive** — the minimum slope scales with volatility, so the filter means the same thing in quiet and volatile markets |

- `slope > threshold` → bar argues **up** (colour `0`, green)
- `−slope > threshold` → bar argues **down** (colour `1`, red)
- otherwise the bar is **too flat to say** — it argues for nothing.

A zero threshold in either mode silently disables the filter, so `OnInit` prints a warning when that happens (a disabled filter must not look identical to a working one). If the ATR handle cannot be created, the indicator **degrades to an unfiltered line** rather than showing nothing.

### 4.3 Whipsaw filter — confirmation

One counter-trend bar is not a trend change. The indicator keeps a **streak** of counter-trend bars plus the streak's **age**, and only flips when the streak reaches `InpConfirmBars`:

- Bar agrees with the current trend → streak and age reset to 0.
- Bar is too flat → streak is **held** (not reset), and the age keeps running. On low timeframes most bars sit inside the threshold band; resetting here made `InpConfirmBars > 1` impossible to ever satisfy.
- Bar argues against the trend → streak increments; when `streak ≥ InpConfirmBars` the trend flips and both reset.
- **The streak expires.** If `age ≥ InpConfirmWindow` while the streak is still partial, it is abandoned.

The window is what makes the hold safe. Holding through flat bars with no time bound meant two counter-trend bars *a day apart* still flipped the trend, which is not what "N bars of confirmation" means to anyone reading the input. `InpConfirmWindow = 0` resolves to `3 × InpConfirmBars`.

With `InpConfirmBars = 1` (default) any qualifying counter-trend bar flips immediately and the window never comes into play; higher values demand a run of opposing bars inside the window before the trend changes.

---

## 5. Trend state machine

Per bar, in order:

1. Compute `PriceBuffer` (applied price), the raw Hull difference `2·LWMA(n/2) − LWMA(n)`, and the Hull line `LWMA(·, √n)`.
2. Compute the slope and the threshold (points or ATR).
3. Classify the bar as up / down / flat.
4. Apply the streak rules (§4.3) to derive this bar's colour and streak.
5. If the colour changed, write a reversal arrow (up arrow below the bar's low, or down arrow above the bar's high) and, on a fresh signal, fire the configured alerts.

**Seeding.** The first bar carrying a Hull value (`g_hmaFirst`) has no earlier value to take a slope against. The seed used to be a hard-coded "up", which is a direction the data never argued for: if the next bar sloped down, the state machine emitted a *down reversal against a prior that did not exist* — a fabricated flip, drawn as a real arrow and handed to an EA as a real signal.

The seed now comes from the first **real** slope, `HMA[g_hmaFirst + 1] − HMA[g_hmaFirst]`, and the state machine only begins deciding at `g_hmaFirst + 2` (`PLOT_DRAW_BEGIN` for both arrow plots). The warm-up region is cleared to `EMPTY_VALUE` (arrows) so an EA reading via `CopyBuffer` never receives a phantom signal at price zero — another real past defect.

---

## 6. Non-repainting behaviour

The indicator's **closed-bar output is stable**. A bar's colour and arrows depend only on its own slope, the earlier bars, and the streak state — all fixed once the bar closes. Recomputing from `prev_calculated − 1` re-derives the same values; nothing historical changes.

The **forming bar** (last index) is live and recomputes on every tick — that is the point of a trend line, but it means:

- The default alert signal bar is the **closed bar** (`SIGNAL_CLOSED_BAR`). Selecting `SIGNAL_CURRENT_BAR` fires alerts on the forming bar, which **can repaint** — use it only when you want early (unconfirmed) signals.
- The EA reads **shift 1 (last closed bar)** only. Reading shift 0 would repaint and make backtests fiction.

Alerts fire **once per bar**, keyed to a strictly-increasing `g_lastSignalTime`. Historical signals are never replayed on attach or on a history reload — the marker initialises to the current bar on first run rather than walking backwards and re-alerting.

The cost of that rule is that a reversal landing on the exact bar you attach to is swallowed. Set `InpAlertOnAttach = true` to evaluate that one bar as well; everything older is still never replayed.

---

## 7. Reading the chart

- A **green line** = the Hull is rising above the threshold; a **red line** = it is falling. Green/red is decided by slope against the whipsaw threshold, so a flat-but-bullish price structure can still show red.
- **Up arrow** = bullish reversal (colour flipped to up); **down arrow** = bearish reversal. Arrows only appear on a flip, not on every bar.
- The DataWindow shows the Hull value, colour index (0/1), arrow values, and the internal streak count and streak age per bar.
- Arrow distance from the bar is `max(InpArrowOffset × point, InpArrowOffATR × ATR)`, so it stays legible across instruments instead of vanishing on one and dwarfing the candle on another.

---

## 8. Input reference — indicator

### 1. Hull Moving Average

| Input | Default | Notes |
|---|---|---|
| `InpHMAPeriod` | `20` | Hull period. Clamped to ≥ 2 |
| `InpHMAPrice` | `PRICE_CLOSE` | Applied price (open/high/low/close/median/typical/weighted) |

### 2. Whipsaw filter

| Input | Default | Notes |
|---|---|---|
| `InpSlopeFilter` | `SLOPE_FILTER_ATR` | `0` off, `1` points, `2` ATR |
| `InpSlopeATRMul` | `0.05` | ATR mode: slope must exceed ATR × this |
| `InpATRPeriod` | `14` | ATR mode: ATR period |
| `InpSlopePoints` | `0.0` | Points mode: minimum slope (points) |
| `InpConfirmBars` | `1` | Counter-trend bars needed to flip (1 = none) |
| `InpConfirmWindow` | `0` | Bars a **partial** confirmation stays alive. `0` = `3 × InpConfirmBars`. Irrelevant when `InpConfirmBars = 1` |

### 3. Reversal arrows

| Input | Default | Notes |
|---|---|---|
| `InpShowArrows` | `true` | Draw flip arrows |
| `InpArrowUp` | `233` | Up arrow code (Wingdings) |
| `InpArrowDown` | `234` | Down arrow code (Wingdings) |
| `InpArrowOffset` | `10` | Arrow distance from the bar (points). Acts as a **floor** when the ATR offset is on |
| `InpArrowOffATR` | `0.25` | Arrow distance from the bar (× ATR). `0` = points only. A flat point offset is invisible on an index CFD and enormous on a JPY cross |

### 4. Alerts

| Input | Default | Notes |
|---|---|---|
| `InpSignalBar` | `SIGNAL_CLOSED_BAR` | Closed bar (confirmed) or current bar (can repaint) |
| `InpEnableAlert` | `true` | Pop-up alert |
| `InpEnableSound` | `false` | Sound alert |
| `InpSoundFile` | `alert.wav` | Sound file |
| `InpEnablePush` | `false` | Mobile push |
| `InpEnableEmail` | `false` | Email |
| `InpAlertOnAttach` | `false` | Also evaluate the bar you attach on. Off by default: a reversal sitting on the attach bar is not replayed |

---

## 9. Buffer contract

| # | Name | Kind | Contents |
|---|---|---|---|
| 0 | HMA line | plot 0 (`DRAW_COLOR_LINE`) | The Hull value, or `EMPTY_VALUE` before warm-up |
| 1 | Colour | plot 0 colour index | `0` = up, `1` = down — **the trend signal an EA reads** |
| 2 | Up arrow | plot 1 (`DRAW_ARROW`) | Low − offset on a bullish flip, else `EMPTY_VALUE` |
| 3 | Down arrow | plot 2 (`DRAW_ARROW`) | High + offset on a bearish flip, else `EMPTY_VALUE` |
| 4 | Price | calculations | Selected applied price |
| 5 | Diff | calculations | `2·LWMA(n/2) − LWMA(n)` |
| 6 | Streak | calculations | Counter-trend bars banked toward the next flip |
| 7 | Age | calculations | Bars since that streak opened — the confirmation window counts against this |

Buffers 2–6 are `INDICATOR_CALCULATIONS`, readable by an EA. The EA reads **buffer 1** for the trend, never the arrows — the arrows are derived from the same state machine, so they carry no extra information, and the colour makes the current trend available on every bar (which the higher-timeframe filter needs).

---

## 10. Alerts

Alerts fire on a **fresh reversal** only — a colour change on the chosen signal bar, once per bar, never replayed for historical signals:

```
Hull Trend (20) BULLISH reversal on EURUSD M15 at 2026.08.26 12:15
```

The subject and message include the symbol and a readable timeframe name (`PERIOD_H1` → `H1`).

---

## 11. Testing protocol

**T1 — Compile.** Expect `Result: 0 errors, 0 warnings`. UTF-16 log; exit code 1 means success.

**T2 — Whipsaw filter sanity.** On a ranging chart, `SLOPE_FILTER_NONE` flips far more often than `SLOPE_FILTER_ATR`. Raise `InpSlopeATRMul` and confirm the flip count drops. If the line never changes colour, check the Experts log for the `Hull Trend config:` line (resolved settings) and any `slope filter is OFF` warning.

**T3 — Confirmation.** Set `InpConfirmBars = 3`; a flip now requires three consecutive counter-trend bars (flat bars don't reset the count). Compare against `1`.

**T4 — Non-repaint proof.** Strategy Tester → Visual mode, slow speed. Watch a printed arrow for 50+ bars — it must never move or vanish. Run to bar N, screenshot, run to N+200, compare the same historical bars.

**T5 — EA round-trip costs.** Run the EA on M1, M5 and M15 of the same symbol and read the `SUM` line's `spread avg x ATR`. It should sit well under 0.25; on M1 retail FX it will not clear its own costs.

---

## 12. Backtesting

- **Modelling mode:** "Every tick based on real ticks" is best (exits are SL/TP hits inside a bar). "Open prices only" is invalid. "1 minute OHLC" is an acceptable fast approximation.
- **Costs:** set a realistic fixed spread and your broker's commission. A flip system is exceptionally cost-sensitive — the spread is the entire edge against it.
- **Timeframe:** M5 is the practical floor for major FX pairs (see §1).
- **Warm-up:** allow ~25 bars before the start date; the EA additionally needs the higher-timeframe Hull to have data.

---

## 13. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No line drawn | Fewer than ~`n + √n` bars of history. Scroll back or pick a longer-history symbol. |
| Line is one colour forever | Whipsaw threshold too large, or a zero-threshold mode warning in the log means the filter is actually OFF. |
| Arrows everywhere | `InpSlopeFilter = NONE` or `InpConfirmBars = 1` with a small threshold. Tighten the filter. |
| `InpConfirmBars > 1` never seems to fire | The streak now expires after `InpConfirmWindow` bars (default `3 × InpConfirmBars`). Raise the window, or lower the slope threshold so more bars qualify as directional. |
| `ATR covered only N of M bars` in the log | Those oldest bars ran with **no** slope threshold, i.e. as `SLOPE_FILTER_NONE`. Load more history before trusting a backtest that spans them. |
| EA logs `FATAL: cannot create the indicator handle` | `HullTrend_MT5.ex5` missing from `MQL5\Indicators\`. |
| EA never trades | Read the `SUM` line: the `vetoes:` histogram names the rejecting filter (e.g. `htf-disagrees=142 spread=8`). |
| EA trades differ from chart arrows | The EA reads the colour buffer, not arrows, at shift 1 — check `InpHTFShift` and that you are not reading the forming bar. |
| `sizing preflight: … rounds to ZERO lots` | Risk % is below the minimum-lot floor on this symbol. The log says the exact % needed. |
| No liquidity-grab markers at all | `InpMinSweepATR` is too high for the symbol, or `InpMaxAgeBars` is shorter than the visible chart. Both effective values are on the `Hull Liquidity Grab config:` line printed at attach. |
| Fewer grab markers than the log lists | `InpMaxPoints` caps what is **drawn** (default 8), never what is found. The `HullLG \| LIST` line reports the true totals. |
| Grab markers all sit on one side | Expected in a one-way trend. The log does not: `InpPrintPerSide` caps each direction independently, so both sides always appear in the list. |

---

## 14. Known limitations

1. **A flip system pays spread on every reversal.** The strategy is cost-bound; on retail M1 FX it cannot clear its own costs.
2. **The trend line repaints on the forming bar.** Closed-bar output is stable; shift-0 reads and `SIGNAL_CURRENT_BAR` alerts are not.
3. **The slope threshold is a heuristic, not a calibrated statistic.** Unlike the QRC engine, no statistic here has a known null distribution — thresholds are tuned by hand.
4. **Tick-volume, not real volume** — the indicator doesn't use volume at all; the EA's spread guard uses live bid/ask.
5. **Not validated as profitable.** No live or out-of-sample edge has been demonstrated.

---

## 15. Maintenance checklist

| Change | Also update |
|---|---|
| A whipsaw default | The profile table in `HullTrend_EA_Documentation.md` §18 (the EA forwards `InpSlopeATRMul`) |
| Indicator input order | The **24**-argument `iCustom` call in `HullTrendEA_Core.mqh`'s `CreateHullHandle()` — group placeholders included — **and** `HULL_ICUSTOM_ARGS`, which the EA asserts against the live handle at `OnInit` |
| Buffer order | The buffer contract in §9 **and** the EA's `ReadSignal()` buffer indices |
| Anything in the state machine | The streak/flip explanation in §4–§5 and the EA's flip-detection (`col[1] != col[0]`) |
| A new per-bar log line | The log format table in `HullTrend_EA_Documentation.md` §15 |
| An `LGConfig` field | `LGViewerConfig()` in `HullTrendLG_MT5.mq5` — the one place inputs become a config, so the logged line and the scan cannot diverge |
| How either engine ages its history out | §16.3 here **and** `HullTrend_EA_Documentation.md` §23 step 4 — both state that the horizon is counted in bars |

---

## 16. Liquidity grabs

`HullTrendLG_MT5.mq5` marks **liquidity grabs** (stop hunts, sweeps): a bar that pierces a
resting order cluster and closes back inside it. The liquidity was real; the breakout was not.

- **Bull grab** — price takes out the sell stops resting under a recent swing **low**, then
  closes back above it. The sell side is exhausted.
- **Bear grab** — price takes out the buy stops above a recent swing **high**, then closes
  back below it. The breakout failed.

No EA reads this indicator. It is a chart study and a log, nothing more.

### 16.1 How a grab is detected

`LGCollect()` in `HullTrendLG.mqh`, run once per closed bar:

1. **The reference is the swing *before* the bar.** For a bar at shift `i` the level is the
   highest high / lowest low over shifts `i+1 … i+InpRefBars`. A bar can never sweep a level
   that includes its own extreme.
2. **Closed bars only.** The scan starts at shift 1, and the close must be back on the
   original side of the level. Nothing repaints: a marker can appear one bar late, but once
   drawn it never moves or vanishes.
3. **The pierce must be worth something.** It must exceed `InpMinSweepATR × ATR`. A one-tick
   overshoot of a level is noise, not a grab.
4. **Both directions in one list**, tagged by direction, newest first.

### 16.2 Input reference — liquidity grabs

**Detection**

| Input | Default | Meaning |
|---|---|---|
| `InpLookback` | `200` | Bars scanned for grabs. Floored at 50 by the engine. |
| `InpRefBars` | `20` | Bars before each bar that define the swept level. Floored at 2. |
| `InpMinSweepATR` | `0.25` | Minimum pierce beyond the level, in ATR |
| `InpMaxAgeBars` | `0` | Drop grabs older than N **bars** (`0` = use `InpLookback`) |
| `InpATRPeriod` | `14` | ATR period for the sweep scale |

**Experts log**

| Input | Default | Meaning |
|---|---|---|
| `InpPrint` | `true` | Print grabs to the Experts tab |
| `InpPrintPerSide` | `3` | Recent grabs printed **per direction** (`0` = all) |

**Appearance**

| Input | Default | Meaning |
|---|---|---|
| `InpColorBull` | `clrMediumSeaGreen` | Bull grab — a low was swept |
| `InpColorBear` | `clrTomato` | Bear grab — a high was swept |
| `InpLabels` | `true` | Text label beside each marker |
| `InpFontSize` | `8` | Label font size (floored at 6) |
| `InpMaxPoints` | `8` | Markers **drawn** (`0` = all). Does not affect what is found. |
| `InpShowLevel` | `true` | Dotted segment at the swept level |

The `Hull Liquidity Grab config:` line printed at attach reports the values the scan will
**actually** use, with the engine's floors already applied — a `refBars` of 1 is logged as the
2 it becomes. The line is a record of the run, not of the dialog.

### 16.3 The age horizon is counted in bars

`InpMaxAgeBars` means what it says: N **chart bars**, not N × the bar duration in seconds.
The distinction is not pedantic. The market is shut all weekend, so N bars always span more
than N hours of wall clock on an H1 chart. Measured on EURUSD H1 at a Monday open, a cutoff
set 200 hours back reached only **120 bars** — the requested 200-bar window came up 40%
short, with nothing in any log to say so.

The S/R engine had exactly that defect and was corrected with it — see the S/R indicator 1.20
entry in §17.

### 16.4 Reading the log

Printed at attach, and again only when a new grab confirms — never on every bar:

```
HullLG | LIST | 20 grab(s) in lookback: 12 bull, 8 bear - showing most recent 3 of each, newest first
HullLG | GRAB | 2026.08.28 14:00 | BULL  price 1.16021  swept level 1.16044  sweep 0.31 ATR  6 bars ago
```

The two direction counts are what was **found**, so they add up to the total beside them;
`showing most recent N of each` says how much of it follows. Because `InpPrintPerSide` caps
each direction independently, a one-way trend cannot crowd the other side out of the list.

### 16.5 Reading the chart

The arrow sits **0.25 × ATR clear of the swept extreme** — below a swept low, above a swept
high — so it points at the wick instead of covering it. That clearance is in ATR for the same
reason the trend indicator's flip arrows are: a flat point offset is invisible on an index CFD
and enormous on a JPY cross. A dotted segment marks the level that was swept, and the label
reads `LG-B  0.31A` — `B` for a bull grab, `S` for a bear one, then the sweep in ATR. The
tooltip carries the full detail.

---

## 17. Range breakouts

`HullTrendBO_MT5.mq5` marks the **N most recent range breakouts** (default 3) on a timeframe you
choose, and prints them to the Experts log.

**This is the mirror of §16.** A liquidity grab pierces a level and closes back *inside* it — the
breakout failed. This indicator records the bar that closes *outside* and stays there. Same
geometry, opposite verdict; run both and the chart says which levels gave way and which ones only
pretended to.

No EA reads this indicator. It is a chart study and a log, nothing more.

### 17.1 Which timeframe it works on

**Any.** `InpTF` selects the timeframe the *scan* runs on, independently of the chart:

- `PERIOD_CURRENT` (default) — scan whatever the chart is showing. M5 chart, M5 breakouts.
- Any explicit timeframe — the scan runs there and the markers still land on **this** chart. An M15
  chart showing H4 breakouts is one picture, not two windows.

The panel header names the scanned timeframe, and adds the chart timeframe after it when the two
differ, so a screenshot can never be ambiguous about which bars produced the levels.

Everything is quoted in the **ATR of the scanned timeframe** — the ruler the levels were built with.

### 17.2 How a breakout is detected

`BOScan()` in `HullTrendBO.mqh`, run over a newest-first bar series:

1. **The range is the bars *before* the bar.** For a bar at shift `i` the range is the highest high
   and lowest low over shifts `i+1 … i+InpRangeBars`. A bar can never break a level that includes
   its own extreme.
2. **A close, not a wick.** The bar must *close* beyond the edge, by at least
   `InpMinBreakATR × ATR`. A one-tick poke through a level is noise.
3. **One breakout per move — the arming rule.** In a trend every bar closes above a rolling range
   high, so a naive detector reports forty breakouts for one move. A direction is **armed** once,
   **spends** itself on the break, and is only **re-armed** when price closes back inside the level
   it broke. "Three recent breakouts" therefore means three separate moves, not three bars of the
   same one.
4. **Closed bars only.** The walk ends at shift 1 and every verdict reads closed bars only. Nothing
   repaints: a marker can appear one bar late, but it never moves once drawn. The one value that
   tracks the live bar is MFE, and a move can extend but never un-extend.

> The walk covers bars **older** than the reporting window on purpose. Arming is a running state, so
> the scan has to see what came before the window to know whether a break inside it is a new move or
> the tail of an old one.

### 17.3 How you know whether it is valid

Two questions, and they are answerable at **different times**. The indicator keeps them apart, and
that separation is the substance of this section.

#### The score — known the moment the bar closes

Four things, all visible on the breakout bar and the range behind it. Nothing from the future.

| Component | Weight | What earns full marks | Why it matters |
|---|---|---|---|
| **Push** | 30 | Closing `0.5 × ATR` or more past the level | A close that barely clears the edge has not committed to anything |
| **Close** | 30 | Closing at the extreme of its own bar | Closing mid-bar after a long wick is a bar that broke out and then thought better of it |
| **Compression** | 20 | A range `1.5 × ATR` tall or tighter (nothing at `6 × ATR`) | A break out of a coil is worth more than the same break out of a wide chop, where the "level" was never a level anybody watched |
| **Volume** | 20 | Twice the average tick volume of the range bars | A break nobody turned up for is a break nobody has to respect. Equal to the average scores **zero** |

Weighted into **0–100** and graded: **STRONG** ≥ 75, **FAIR** ≥ 50, **WEAK** ≥ 25, **POOR** below.

The score is never just asserted at you. The panel shows the newest breakout broken into its four
parts, the tooltip shows all four for any breakout, and the log prints a `SCORE` line beside every
`BREAK` line. It is an argument you can disagree with on specific grounds, not a verdict.

The calibration constants are **not** inputs. A score is only worth something if it means the same
thing on every chart it is read from; a per-chart calibration is not a score, it is a second
opinion. What *is* an input is `InpMinScore` — the bar you hold breakouts to — because that is a
judgement rather than a definition.

#### The status — known only later

| Status | Meaning |
|---|---|
| `PENDING` | The `InpConfirmBars` window has **not elapsed yet**. Whether it held is not yet known |
| `held` | It survived the window without closing back inside the level |
| `FAILED` | It closed back inside the level it broke |

**A breakout inside its confirmation window is `PENDING`, not "held".** Reporting a one-bar-old
breakout as held would be a claim about bars that have not happened. The newest breakout on a live
chart is normally `PENDING` — that is the honest answer, and it is the one the panel gives.

A high score that later FAILS is not a contradiction; it is the market. Keeping the two apart is
what lets you see that pattern instead of hiding it.

#### Using them

- `InpMinScore` hides breakouts below a score — set it to 50 to see only FAIR and better.
- `InpAlertMinScore` is **separate on purpose**: plenty of people want every break drawn for context
  but only want to be woken for the good ones.

### 17.4 Reading the chart

```
      _______________________
     |                       |            <- the range that broke (dotted outline)
     |    the 20-bar range   |
     |_______________________|___ _ _ _ _ _ _ _ _ _  the level, carried right
                              \
                               \|/  chunky arrow on the bar that closed through
                                v
                    BO1 UP  82 STRONG  PENDING  ->2.4A
                             |    |        |        |
                         score  grade   status   how far it has run
```

- The **newest** breakout gets a thicker arrow and a thicker level line.
- A **grey** marker is one that **FAILED**. It is still information — this level does not hold — but
  it is not a direction, and colouring it like one would say it was. A `PENDING` breakout keeps its
  full colour, because it is the live one and the most likely to matter.
- The level is carried right because a broken level is the first thing price tests on the way back.
- Hover any arrow for the full score breakdown.

The panel:

```
HULL BREAKOUT   EURUSD   H1 on M15   range 20 bars   H1 ATR 18.4 pips
#1  DOWN 1.16040    82 STRONG  push 0.42A  ran  1.85A  PENDING  6h ago
#2  UP   1.16610    41 WEAK    push 0.31A  ran  0.22A  FAILED   2d ago
#3  UP   1.16180    67 FAIR    push 0.55A  ran  2.90A  held     4d ago
  #1 score 82 = push 30 + close 26 + compression 14 + volume 12   (of 30/30/20/20)
of the last 3: 1 held, 1 failed, 1 still inside the 3-bar window
```

### 17.5 Colours — why this one is cyan and yellow

Every other study in this suite ships **green for up, red for down**: the trend line, S/R, liquidity
grabs, and the FVG zones all use that pair. Put two of them on one chart and the colour stops saying
*which study drew this marker*, which is the thing you need to know first.

So this one is different by default, on two axes at once:

| | This study | The others |
|---|---|---|
| Up / down | **cyan / yellow** | green / red |
| Arrow glyph | **241 / 242** (chunky blocks) | 233 / 234 (thin arrows) |
| Range box | **outline only** | FVG zones are filled |

Direction is carried by the arrow shape, the level line and the label, which frees colour to
identify the study. All of it is an input — `InpColorUp`, `InpColorDown`, `InpArrowUp`,
`InpArrowDown`, `InpFillRange` — so anyone who disagrees can say so in one click.

> **If things still collide**, the fastest fixes are: turn off `InpShowRange` on whichever study you
> care about less, move one panel with `InpPanelCorner`, or set `InpExtendLevel = false` so the
> broken levels stop competing with S/R lines.

### 17.6 Input reference — breakouts

**Which timeframe to scan**

| Input | Default | Meaning |
|---|---|---|
| `InpTF` | `PERIOD_CURRENT` | Timeframe the scan runs on (`CURRENT` = the chart) |

**Detection**

| Input | Default | Meaning |
|---|---|---|
| `InpCount` | `3` | How many recent breakouts to show (`0` = all found) |
| `InpRangeBars` | `20` | Bars before each bar that define the range. Floored at 2 |
| `InpMinBreakATR` | `0.15` | The close must clear the level by this × ATR |
| `InpConfirmBars` | `3` | Bars in which a close back inside marks it **FAILED** (`0` = never) |
| `InpMinScore` | `0` | Hide breakouts scoring below this, 0–100 (`0` = show all) |
| `InpLookback` | `300` | Bars scanned. Floored at 50 |
| `InpMaxAgeBars` | `0` | Ignore breakouts older than N **bars** (`0` = use `InpLookback`) |
| `InpATRPeriod` | `14` | ATR period for the push / run scale |

**Appearance**

| Input | Default | Meaning |
|---|---|---|
| `InpColorUp` / `InpColorDown` | `clrAqua` / `clrYellow` | Broke the range high / low. **Not** green/red — see §17.5 |
| `InpColorFailed` | `clrDimGray` | …and closed back inside |
| `InpFillRange` | `false` | Fill the range box, or draw the outline only |
| `InpArrowUp` / `InpArrowDown` | `241` / `242` | Wingdings codes. Distinct from the 233/234 the other studies use |
| `InpShowRange` | `true` | Draw the range that was broken |
| `InpShowLevel` | `true` | Draw the level that gave way |
| `InpExtendLevel` | `true` | Carry that level to the right edge |
| `InpLabels` | `true` | Text beside each marker |
| `InpRedrawSecs` | `5` | Intrabar refresh (`0` = new bar only) |

**Alerts**

| Input | Default | Meaning |
|---|---|---|
| `InpEnableAlert` | `true` | Pop-up when a **new** breakout confirms |
| `InpAlertMinScore` | `0` | …only if it scores at least this (`0` = any) |

Plus sound / push / email, and the usual panel block. **Alerts never fire on the attach pass** — the
newest breakout in the lookback may be days old, and waking someone for it teaches them to ignore
the alert that matters.

### 17.7 Tuning

| Symptom | Knob |
|---|---|
| Too many marginal breaks | Raise `InpMinBreakATR` to 0.3–0.5, or set `InpMinScore` to 50 |
| Only want the good ones | `InpMinScore = 75` — STRONG only |
| Want them all drawn but only alerted on the good ones | Leave `InpMinScore = 0`, set `InpAlertMinScore = 75` |
| Breakouts of trivial ranges | Raise `InpRangeBars` to 40–50 — this also lifts the compression score |
| Everything says FAILED | The symbol is mean-reverting at this range size — raise `InpRangeBars`, or trade the fade |
| Everything says PENDING | `InpConfirmBars` is longer than the breakouts are old. Lower it, or wait |
| Scores are always low on volume | Some CFD feeds have flat tick volume; that component will sit near 0. Judge on the other three |
| Clashing with another Hull study | See §17.5 |

### 17.8 Testing

**`HullTrendBO_SelfTest.mq5` — run it after any edit to `HullTrendBO.mqh`. Non-negotiable.**

It drives the walk with a hand-built 13-bar series containing one of every case — a clean breakout,
a continuation bar that must be suppressed, a re-entry that must re-arm, a breakout that fails, one
still `PENDING`, and one the other way — with **hand-computed scores and component values** for all
three, so a change to any weight or calibration constant shows up here as a number rather than as a
slightly different chart nobody notices. Then it runs the whole engine over real history and
re-derives every breakout from its own range bars.

Drag it onto any chart and read the Experts tab, or run it headlessly with `bo_selftest.ini` (see
§12) **while the terminal is closed** — one instance per data folder, so a `/config:` launch is
silently refused when MT5 is already open.

Baseline at v1.10, EURUSD M15 / H1, 2026-08-20 → 2026-08-28: **109 passed, 0 failed**; 3 breakouts
found in the last 300 H1 bars, all three re-derived from their own range bars.

## 18. Version history

### Breakout indicator 1.10

- **Fixed, and it mattered:** a breakout inside its confirmation window reported as **"held"**. It
  had no way to know that — the bars had not happened. Status is now three-valued, `PENDING` until
  the window has actually elapsed, then `held` or `FAILED`. On a live chart the newest breakout is
  normally `PENDING`, which is the honest answer and the one a breakout trader needs.
- **Added a score.** 0–100 from four things visible on the breakout bar itself — push past the level
  (30), where the close sat in its own bar (30), how tight the range was (20), and volume expansion
  against the range average (20) — graded STRONG / FAIR / WEAK / POOR. The panel, the tooltip and
  the log all show the four parts, so it is an argument rather than a verdict. `InpMinScore` hides
  the weak ones; `InpAlertMinScore` gates alerts separately, because wanting every break drawn for
  context and wanting to be woken only for good ones are different wishes.
- The calibration constants are deliberately **not** inputs — a score is only worth something if it
  means the same thing on every chart it is read from. The one judgement, `minScore`, is an input.
- The score filter runs **after** the walk, never inside it: a hidden breakout still happened and
  still spent the arming, so filtering must not promote the next bar of the same move into a fresh
  breakout. Asserted in the self-test.
- **Recoloured to stop colliding with the rest of the suite.** Cyan / yellow instead of green / red,
  chunky 241/242 arrows instead of the 233/234 every other study uses, and the range box is an
  outline rather than a fill so it does not read like an FVG zone. Every one of those is an input
  (§17.5).
- Self-test grown from 59 to **109 assertions**, 0 failures — including hand-computed scores for all
  three breakouts in the built series and every status transition.

### Breakout indicator 1.00 (new)
- `HullTrendBO_MT5.mq5` marks the N most recent range breakouts on a **selectable** timeframe and
  lists them in the Experts tab (§17). The scan timeframe is independent of the chart, so an M15
  chart can show H4 breakouts.
- The detection lives in `HullTrendBO.mqh` (`MQL5\Include\`), split into a pure `BOScan()` over a
  bar array and a `BOCollect()` that fetches one — the same split as `HullTrendFVG.mqh`, and for the
  same reason: a detector that can only be driven by live bars can only be checked against whatever
  the market happened to do.
- **The arming rule** is the substance of it: a direction is armed once, spent on the break, and
  re-armed only when price closes back inside the level it broke. Without it a single trending move
  reports one breakout per bar.
- Every breakout carries its own outcome — how far it ran, and whether it failed back inside the
  level within `InpConfirmBars`. Failed ones are drawn grey rather than hidden.
- Non-repainting by construction: a breakout needs a closed bar, and the failure verdict reads
  closed bars only.
- Self-test: `HullTrendBO_SelfTest.mq5`, 59 assertions, 0 failures on EURUSD M15/H1.

### FVG indicator 1.00 (new)
- `HullTrendFVG_MT5.mq5` draws higher-timeframe fair value gaps, order blocks and BOS/CHoCH on the
  trading chart, and scores the entry against a chart-timeframe structure break. Documented
  separately in `HullTrendFVG_Documentation.md`.
- The detection lives in `HullTrendFVG.mqh` (`MQL5\Include\`), which reuses `HullTrendSR.mqh` for
  timeframe resolution so that the HTF a chart resolves to is the same answer everywhere in this
  suite.
- Self-test: `HullTrendFVG_SelfTest.mq5`, 74 assertions, 0 failures on EURUSD M15/H4.

### Liquidity-grab indicator 1.00 (new)
- `HullTrendLG_MT5.mq5` marks liquidity grabs on the chart and lists the recent ones in the
  Experts tab (§16).
- The detection lives in `HullTrendLG.mqh` (`MQL5\Include\`), apart from the indicator that
  draws it, on the same principle as `HullTrendSR.mqh`: one copy of the rule, any number of
  consumers. No EA reads it yet — the split exists so that adding one never means
  reimplementing the detection.
- Non-repainting by construction: a grab needs a closed bar and a close back inside the level.

### S/R indicator 1.20
- **Fixed:** `InpMaxAgeBars` is counted in **bars**, as its label always claimed. It was being
  converted to `N × PeriodSeconds` and compared against bar times, so every weekend and
  session break inside the window shortened it. Measured on EURUSD H1, a 200-bar horizon was
  reaching 120 bars.
- **Fixed:** that horizon is now re-quoted per timeframe instead of shared as one wall-clock
  instant. `SRBarsOnTF()` converts the chart-bar horizon into the HTF's own bar count — a
  150-bar H1 horizon becomes 38 H4 bars — rounding up so re-quoting can never shorten it.
  Both scans still cover the same stretch of history; that invariant was the point of the old
  shared cutoff and it is preserved.
- **Fixed:** the indicator no longer blanks the chart for a whole bar when the history read
  fails. `SRBuild()` and `SRCollect()` return `false` **only** when history is unreadable —
  never to mean "found nothing" — and the viewer marks a bar done only after a successful
  build. A short `CopyRates` while the terminal was still syncing used to clear every level
  and leave the chart bare until the next bar closed; on H4 that is four hours.
- **Affects the EA too.** The engine is shared, so the EA's levels move with it. They now
  reach as far back as `InpSRMaxAgeBars` really specifies, which generally means *more*
  levels than before. Re-read the `SUM | … | S/R levels` count before trusting an
  `InpSRVetoATR` that was tuned against the old behaviour.

### S/R indicator 1.10
- **Changed:** the on-chart numbers now answer the question being asked. A label used to read
  `1.16412  x3` — a price the chart's own axis was already printing, and a bare count with no
  scale attached. It now reads `R1  0.42 ATR  38 pips  ***`: the level's rank counting outwards
  from price, its distance in the unit `InpSRVetoATR` is set in *and* the unit the stop is set
  in, and strength as weight rather than as a digit. The price moved to the tooltip and to the
  new **Full** detail rung, where it belongs.
- **Added:** `InpLabelDetail` (Compact / Normal / Full) and `InpFontSize`.
- **Added:** a summary panel (`InpPanel`, on by default) reporting R1 and S1 with their distance,
  strength and age, where price sits inside that band as a percentage, and how many levels are
  drawn versus found. The band position is the one quantity no per-level label can carry.
- **Added:** `SRFormatDist()` picks the unit per symbol — pips on 3/5-digit FX, points elsewhere,
  and the raw price move once the point count passes five figures. No table of symbol names, so
  a broker renaming a suffix cannot silently make every distance wrong by a factor of ten.
- `SRStyle` gained a constructor. New drawing fields therefore default sanely for callers written
  before they existed, which is what lets the EA's `InpSRDraw` path compile and improve untouched.

### S/R indicator 1.00 (new)
- `HullTrendSR_MT5.mq5` draws the support/resistance levels the EA trades against.
- The engine moved to `HullTrendSR.mqh` (`MQL5\Include\`) and is **shared** with the EA, so the picture cannot drift from the trades. The higher-timeframe ladder moved with it, because both consumers must resolve the same HTF or they scan different data.
- Deliberately a separate indicator: folding it into `HullTrend_MT5` would extend that indicator's positional `iCustom` list — the most fragile contract in the system — to publish data the EA does not want, since the EA computes its own levels in-process.

### Indicator 2.30
- **Fixed:** the state machine no longer fabricates a flip at the warm-up boundary. The seed is taken from the first real slope instead of a hard-coded "up", and colouring starts one bar later (§5).
- **Added:** `InpConfirmWindow` — a partial confirmation streak now expires instead of living forever. Without it, `InpConfirmBars > 1` did not mean what it says (§4.3).
- **Added:** `InpArrowOffATR` — volatility-scaled arrow offset, with the point setting as a floor.
- **Added:** `InpAlertOnAttach` — optionally evaluate the attach bar, which was previously always swallowed.
- A short ATR copy now prints a warning. Those bars run with **no** slope threshold, i.e. as a different indicator; it used to be silent.
- New calculations buffer 7 (streak age). Buffer count 7 → 8; `iCustom` argument count 21 → **24**.

### Indicator 2.20
- **Fixed:** the warm-up region now clears arrow buffers to `EMPTY_VALUE` — they previously held `0.0`, invisible on the chart but handed to an EA by `CopyBuffer` as a signal at price zero.
- LWMAs rolled forward to O(1) per bar (was O(period)).
- Flat bars now **hold** the confirmation streak instead of resetting it, making `InpConfirmBars > 1` achievable on low timeframes.
- Alerts keyed to a strictly-increasing signal time — no replays on attach or history reload.
- `OnInit` prints the resolved configuration (`Hull Trend config: …`) so a shifted `iCustom` caller is visible in the log.
- ATR handle failure degrades to an unfiltered line with a printed warning.

### EA 1.40
- **Fixed (high):** a stop-and-reverse could leave the account flat. The flip closed the old position and `TryEnter` then read a position list the broker had not updated yet, vetoing the reversal as `pos-limit` — and the bar was already consumed, so it never retried. Flips now **arm** a signal that re-tests its guards every tick for `InpSignalArmBars` bars (§ EA doc).
- **Fixed (high):** `NormalizeDouble(lots, 2)` destroyed sizing on any symbol with a volume step finer than 0.01. Volume digits are now derived from `SYMBOL_VOLUME_STEP`.
- **Fixed:** fixed lots bypassed every broker constraint; the lot cap was applied after step rounding; the take profit was derived from the pre-widened stop; `OrderCalcMargin` failure was the one silent reject path; the daily-loss baseline included floating P&L; adopted positions could never reach break-even; the freeze level was conflated with the stops level on initial placement.
- **Added:** support and resistance — clustered pivot fractals used to veto entries with no room, to take a structural partial, and to place the swing stop. Never to generate an entry.
- **Added:** Friday cut-off and daily-loss halt can now **close** open positions, not just block new ones.
- **Added:** watchdogs for a signal or HTF handle that never fills, and a startup assertion on the `iCustom` argument count.

### EA 1.30
- Three profiles around one shared core (`HullTrendEA_Core.mqh`): generic, forex (M5+, Friday cut-off), crypto (H1+, 2.25×ATR stop, 24/7).
- Veto counting + `SUM` histograms; sizing pre-flight; cost telemetry (`spread avg/max x ATR`).
- Higher-timeframe selection now snaps to the nearest candidate in log space — the old lookup table silently returned the chart TF itself on untabulated timeframes, disabling the biggest filter on one log line.

---

Both source files carry extensive maintainer documentation in their headers. **Read those headers before modifying anything.**
