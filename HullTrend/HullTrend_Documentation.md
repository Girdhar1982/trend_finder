# Hull Trend System

**A Hull Moving Average trend-flip system: a whipsaw-filtered trend indicator and a stop-and-reverse Expert Advisor.**

Version 2.20 (indicator) · 1.30 (EA) · Last updated 2026-08-27

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
16. [Version history](#16-version-history)

---

## 1. What this is

A two-part system built around the Hull Moving Average:

- **`HullTrend_MT5.mq5`** — an indicator that draws the Hull line colour-coded by slope, marks trend **reversals** with arrows, and fires alerts. Its distinguishing feature is **whipsaw control**: a minimum slope (optionally scaled by ATR) that must be exceeded before a bar is allowed to argue for a trend change, plus an N-bar confirmation before a flip is actually declared.
- **`HullTrendEA*.mq5`** — a **stop-and-reverse** trend follower that trades the flips the indicator publishes. The natural exit is the opposite flip; the stop is a disaster brake, not a target.

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
                         │ iCustom (21 args) + CopyBuffer
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

**Why the split matters.** The indicator is independently testable without risking a cent. When a trade looks wrong: an arrow the EA ignored → **execution bug**, look in the EA; an arrow that should not exist → **model bug**, look in the indicator.

---

## 3. Installation

Files belong in your terminal's data folder (**File → Open Data Folder** in MT5):

| File | Destination |
|---|---|
| `HullTrend_MT5.mq5` | `MQL5\Indicators\` |
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
| A whipsaw default | The profile table in `HullTrend_EA_Documentation.md` §16 (the EA forwards `InpSlopeATRMul`) |
| Indicator input order | The **24**-argument `iCustom` call in `HullTrendEA_Core.mqh`'s `CreateHullHandle()` — group placeholders included — **and** `HULL_ICUSTOM_ARGS`, which the EA asserts against the live handle at `OnInit` |
| Buffer order | The buffer contract in §9 **and** the EA's `ReadSignal()` buffer indices |
| Anything in the state machine | The streak/flip explanation in §4–§5 and the EA's flip-detection (`col[1] != col[0]`) |
| A new per-bar log line | The log format table in `HullTrend_EA_Documentation.md` §15 |

---

## 16. Version history

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
