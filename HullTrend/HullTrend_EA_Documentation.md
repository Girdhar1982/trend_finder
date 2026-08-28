# Hull Trend — EA Execution Layer

**Companion guide to `HullTrend_Documentation.md`. This file covers the EA half in full: the profiles, the shared core, every input, and every runtime behaviour.**

Version 1.30 · Last updated 2026-08-27

---

## Table of contents

1. [What the EA is](#1-what-the-ea-is)
2. [The three front doors](#2-the-three-front-doors)
3. [File layout](#3-file-layout)
4. [The `iCustom` contract](#4-the-icustom-contract)
5. [Reading the indicator](#5-reading-the-indicator)
6. [The higher-timeframe filter](#6-the-higher-timeframe-filter)
7. [Stop-and-reverse logic](#7-stop-and-reverse-logic)
8. [Stop placement modes](#8-stop-placement-modes)
9. [Position sizing](#9-position-sizing)
10. [Margin and broker compliance](#10-margin-and-broker-compliance)
11. [Entry guards — the veto system](#11-entry-guards--the-veto-system)
12. [R tracking](#12-r-tracking)
13. [Break-even and trailing](#13-break-even-and-trailing)
14. [Daily guards](#14-daily-guards)
15. [Logging](#15-logging)
16. [Netting vs hedging](#16-netting-vs-hedging)
17. [Input reference](#17-input-reference)
18. [Profile defaults table](#18-profile-defaults-table)
19. [Backtesting notes](#19-backtesting-notes)
20. [Troubleshooting](#20-troubleshooting)
21. [Known limitations](#21-known-limitations)
22. [Version history](#22-version-history)

---

## 1. What the EA is

The EA is a **stop-and-reverse trend follower**. It contains no signal logic of its own: it attaches to `HullTrend_MT5` via `iCustom`, reads that indicator's **colour buffer**, and trades the flips.

Three design facts matter:

- **The natural exit is the opposite flip.** The stop is a disaster brake, not a target. `InpCloseOnFlip` (default on) closes a position unconditionally when the model declares it wrong — no entry guard is a reason to keep holding.
- **Signals are read from the colour buffer, never the arrows.** The arrows are derived from the same state machine, so they carry no extra information; the colour makes the trend available on *every* bar, which the higher-timeframe filter needs.
- **Entries act on the last closed bar only (shift 1).** The indicator recomputes the forming bar on every tick, so a shift-0 read would repaint and make backtests fiction.

> **Cost warning.** This is a flip system: it pays the spread on every reversal. Round-trip cost as a fraction of ATR(14) is roughly 0.5–0.9× on M1 FX, 0.25–0.4× on M5, 0.12–0.2× on M15. M1 on retail FX does not clear its own costs. **M5 is the practical floor for majors.**

---

## 2. The three front doors

One strategy, three thin wrappers around the single shared core `HullTrendEA_Core.mqh`. Only **defaults** differ; the logic is identical, so a fix in the core reaches all three.

| File | Profile | Min TF | Slope mult | Stop | Spread guard | Friday cut | Magic / comment |
|---|---|---|---|---|---|---|---|
| `HullTrendEA.mq5` | generic | M5 | 0.20 | 1.50×ATR | 0.25×ATR | on | `20260826` / `HullTrend` |
| `HullTrendEA_Forex.mq5` | forex | M5 | 0.20 | 1.50×ATR | 0.25×ATR | on | `20260827` / `HullFX` |
| `HullTrendEA_Crypto.mq5` | crypto | H1 | 0.25 | 2.25×ATR | 0.30×ATR | off | `20260828` / `HullCrypto` |

Rationale baked into the crypto profile: crypto ranges are wider (flip less — slope mult 0.25), fat tails make 1.5×ATR too thin a stop (2.25×ATR), and the H1 minimum avoids the spread eating the edge. The magic numbers differ deliberately so two profiles on the same symbol cannot manage each other's positions.

**Compile the wrapper you intend to trade** — each is its own `.ex5`. Everything below is still a normal, overridable input.

---

## 3. File layout

| File | Destination | Purpose |
|---|---|---|
| `HullTrend_MT5.mq5` | `MQL5\Indicators\` | The model (signal logic) |
| `HullTrendEA.mq5` | `MQL5\Experts\` | Execution — generic profile |
| `HullTrendEA_Forex.mq5` | `MQL5\Experts\` | Execution — forex profile |
| `HullTrendEA_Crypto.mq5` | `MQL5\Experts\` | Execution — crypto profile |
| `HullTrendEA_Core.mqh` | `MQL5\Experts\` | Execution — all shared logic |

`HullTrendEA_Core.mqh` carries a large maintainer header — read it before modifying anything.

---

## 4. The `iCustom` contract

`HullTrend_MT5` declares **17 input parameters spread over 4 `input group` headers**. `input group` headers are real positional slots, so the call passes **21 arguments: 17 values + 4 placeholders**:

```
iCustom(_Symbol, tf, "HullTrend_MT5",
        0,                     //  1 group "Hull Moving Average"
        InpHMAPeriod,          //  2
        (int)InpHMAPrice,      //  3
        0,                     //  4 group "Whipsaw filter"
        (int)InpSlopeFilter,   //  5
        InpSlopeATRMul,        //  6
        InpATRPeriod,          //  7
        InpSlopePoints,        //  8
        InpConfirmBars,        //  9
        0,                     // 10 group "Reversal arrows"
        false,                 // 11 show arrows   - the EA reads buffers
        233,                   // 12 up arrow code
        234,                   // 13 down arrow code
        10,                    // 14 arrow offset
        0,                     // 15 group "Alerts"
        0,                     // 16 signal bar    - closed bar
        false,                 // 17 pop-up alerts - the EA logs instead
        false,                 // 18 sound
        "",                    // 19 sound file
        false,                 // 20 push
        false                  // 21 email
       );
```

Getting the placeholder count wrong fails **silently**: every value shifts one slot left and the indicator simply runs with the wrong settings. The indicator prints its resolved configuration at `OnInit` (`Hull Trend config: …`) precisely so a shift is visible in the log. Do not reorder, insert or delete an input or a group header.

The EA deliberately passes `show arrows = false` and all alerts off — it reads buffers and logs itself.

---

## 5. Reading the indicator

`ReadSignal()` copies:

- **Colour buffer** at shifts 1 **and 2** (the two most recent closed bars),
- **HMA value** at shift 1,
- **ATR** at shift 1.

The trend is `col[1]` (colour `0` = up, `1` = down). A **flip** is `col[1] != col[0]` — the trend changed between the two last closed bars.

The read is **tri-state**:

| Return | Meaning | Action |
|---|---|---|
| `-1` | Data not ready (warm-up, history gap, invalid values) | Retry next tick; **bar not consumed** |
| `0` | Read fine | Proceed (flip or not) |

A flip on the forming bar is never acted on: only shifts 1–2 are ever read.

---

## 6. The higher-timeframe filter

The single biggest whipsaw filter on low timeframes: a per-bar slope threshold cannot see *regime*, but the higher-timeframe trend can.

**Selection** (`PickHTF`): with `InpHTFAuto = true`, the target is `InpHTFMult × chart TF` (default 12×), snapped to the nearest candidate in **log space** from `{M5, M15, M30, H1, H4, D1, W1, MN1}` — only candidates strictly above the chart TF qualify. Log-space snapping means being 2× under target and 2× over it count the same, and a tie keeps the smaller (more responsive) timeframe. This resolves identically to the old hand-written table on all eight timeframes it covered (M1→M15, M5→H1, M15→H4, M30→H4, H1→D1, H4→D1, D1→W1) and now also covers everything else — the old fall-through silently returned the chart TF itself, disabling the filter on one log line.

**Reading**: the HTF colour is read at `InpHTFShift` (default **1 = closed**, the only non-repainting choice).

**The rule**: a flip is vetoed (`htf-disagrees`) when `InpUseHTF` is on and the HTF trend opposes the signal. When the resolved HTF equals the chart TF, the filter logs that it is disabled.

---

## 7. Stop-and-reverse logic

On every new closed bar:

1. Read the signal. If a **flip** occurred:
   - **Exit first, unconditionally** — close all positions against the new direction (`CloseAgainst`). No entry guard can veto this: the model has declared the position wrong.
   - Then attempt a new entry in the flip direction through the veto ladder (§11).
2. A flip that is vetoed still prints a `VETO` line and counts in the summary — a veto is not silence.

The opposite flip is therefore the primary exit (`DEAL_REASON_EXPERT`, counted as `flip`). SL and TP hits (`stop-loss`, `take-profit`) are secondary. An optional `InpTPmulR` take-profit (0 = none) lets you exit early when a target is reached; otherwise only the flip or the stop ends the trade.

---

## 8. Stop placement modes

`InpSLMode` selects how the initial stop is placed from the fill:

| Mode | Stop level | Notes |
|---|---|---|
| `SL_ATR` (default) | `fill − dir × InpSLmulATR × atr` | Simple volatility multiple |
| `SL_SWING` | swing low/high over `InpSwingBars`, **padded** by `InpSLpadATR × atr` | Recent structure beyond the fill; `iLowest`/`iHighest` measured from shift 1 |
| `SL_HMA` | `hma − dir × InpSLpadATR × atr` | The Hull line itself is the thesis — if price is through it, the trade is wrong by its own definition |

`InpTPmulR > 0` places `fill + dir × InpTPmulR × risk` as the take-profit.

The stop is then widened to the broker's minimum distance if needed and normalised to `SYMBOL_DIGITS`. A stop already on the **wrong side** of the fill means price has run through the protective level — the entry is vetoed (`stop-wrong-side`).

---

## 9. Position sizing

`CalcLots(realStopDistance)` — always sized from the **real fill-to-stop distance**, never the theoretical one:

1. `InpFixedLots > 0` wins immediately.
2. Risk-based: `riskMoney = balance × InpRiskPercent / 100`; `lossPerLot = (stopDistance / tickSize) × tickValue` (correct for FX, metals, indices and crypto — never assumes 1 point = 1 unit); `lots = riskMoney / lossPerLot`.
3. Floored to `SYMBOL_VOLUME_STEP`, capped at `min(SYMBOL_VOLUME_MAX, InpMaxLots)`.
4. Below `SYMBOL_VOLUME_MIN` → vetoed `lots-too-small`.

**Sizing pre-flight** (`SizingPreflight`) runs once as soon as ATR is available and logs the whole picture up front: the ATR-mode stop distance, the lots it implies, the minimum-lot floor as a % of balance, and — if your risk % rounds to **zero** lots on this symbol — an `ERROR` line stating the exact % you would need to raise risk to. Without this, every signal would be vetoed as `lots-too-small` and the run would look exactly like the strategy never signalling.

---

## 10. Margin and broker compliance

- **Margin pre-check** — `MarginOK()` uses `OrderCalcMargin()` and rejects (veto `margin`) if the requirement exceeds **90% of free margin**.
- **Minimum stop distance** — `MinStopDist()` = `max(SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL) × point`. SL and TP are widened to it when the broker demands.
- **Freeze band** — trade management never pushes a stop inside `MinStopDist()` of the current price.

---

## 11. Entry guards — the veto system

Every reject path returns a named `ENUM_VETO` instead of just logging, so the summary can count them. In order:

| # | Veto | Trigger |
|---|---|---|
| 1 | `pos-limit` | `nPos ≥ InpMaxPositions` |
| 2 | `same-dir` | Already long (for a buy) or short (for a sell); counts are **per-direction** |
| 3 | `htf-disagrees` | Higher TF trend opposes the signal (§6) |
| 4 | `out-of-hours` | `TimeAllowed()` — server-time window, wraps midnight; Friday cut-off |
| 5 | `daily-loss` | Equity down `InpMaxDailyLossPct` from day start |
| 6 | `trade-cap` | `g_tradesToday ≥ InpMaxTradesPerDay` |
| 7 | `bar-gap` | `InpMinBarsGap` since the last entry |
| 8 | `spread` | Live spread above `InpMaxSpreadATR × ATR` **or** above `InpMaxSpreadPts` (0 = off). The ATR-scaled guard keeps its meaning across instruments and volatility regimes |
| 9 | `stop-wrong-side` | The computed stop is already through the fill (§8) |
| 10 | `drift` | Price has run more than `InpMaxDriftR × risk` past the signal close — the assumed R:R is gone |
| 11 | `lots-too-small` | Risk % rounds below the broker minimum lot |
| 12 | `margin` | Order needs > 90% of free margin |
| 13 | `order-failed` | `PositionModify`/`Buy`/`Sell` retcode non-zero |

The entry log line records everything needed to reconstruct the decision offline: size, levels, the volatility they were scaled to, spread paid, drift, risk % and balance.

---

## 12. R tracking

Break-even and trailing are expressed in **R** — multiples of the original stop distance — so the EA must remember each position's original stop. That state lives in memory (`g_track[]`), keyed by ticket:

- `TrackAdd()` **overwrites** a record with the same ticket rather than appending (a duplicate would let a stale entry/risk silently win every R calculation).
- `TrackPrune()` drops records whose position no longer exists, and reports each departure via `LogClosedPosition()` — which reads the **deal history** to reconstruct entry/exit prices, the R multiple, the real PnL (profit + swap + commission), and the exit reason (SL / TP / flip / other). The original risk is captured *before* the record is removed, because the broker no longer knows it once break-even and trailing have moved the stop.
- **Restart reconstruction.** A position open across an EA restart is adopted with R reconstructed from the current stop distance and logged; adopted positions are trailed but **never re-break-even'd** (the stop may already have moved, so the reconstruction could be wrong).

---

## 13. Break-even and trailing

Both run from `ManagePositions()`, which executes **every tick** — stops must react intrabar.

**Break-even** (one-shot):
- Triggered when `rNow ≥ InpBEatR`; target stop = entry ± `InpBEoffsetPts × point` (the offset covers costs).
- `beDone` is set only once the stop is actually **at** break-even, never merely because we tried — a freeze-band refusal must not prevent a retry.
- Never throttled.

**Trailing** (throttled):
- Triggered when `rNow ≥ InpTrailStartR`; trail level = `price − dir × InpTrailDistR × risk`.
- Advances only after a minimum move of `InpTrailStepR × risk`, measured against the stop the **broker currently holds** — not against a stop staged on the same tick (a break-even move would otherwise satisfy the step for the trail, and the throttle would do nothing on the one tick where both fire). The step costs nothing in placement: the stop ends up in the same place, in fewer hops, without flooding the broker with per-tick `PositionModify` calls.
- Never pushes the stop into the freeze band.

Each successful move logs `#ticket break-even|trail -> price (+X.XXR advance) at X.XXR open`.

---

## 14. Daily guards

- **`RollDay()`** — runs every tick; on a new server-trading day snapshots equity, resets the trade counter, un-blocks the day.
- **`DailyLossHit()`** — equity down ≥ `InpMaxDailyLossPct` from day-start (floating losses count) blocks new entries for the rest of the day (0 = off). Open positions are still managed.
- **`TimeAllowed()`** — optional hours window (server time; wraps midnight) plus `InpNoFridayLate` cut-off after `InpFridayStopHour`.
- **`InpMaxTradesPerDay`** — cap on new entries per day (0 = unlimited).

---

## 15. Logging

Every line is `HullEA | TAG | message` — one record per line, so the whole Experts tab can be pasted and read back. Tags:

| Tag | Level | Meaning |
|---|---|---|
| `ENV` | events | Once at startup: symbol/broker facts, account mode, profile, HTF choice, sizing pre-flight |
| `BAR` | bars (3) | One line per closed bar — noisy on M1, short diagnostic runs only |
| `FLIP` | events | The indicator changed trend |
| `ENTRY` | events | An order was placed (with all decision inputs) |
| `VETO` | decisions | A flip was not traded, and why |
| `STOP` | events | A stop was moved (break-even or trailing) |
| `CLOSE` | events | A position ended, with its R multiple, PnL and reason |
| `SUM` | events | Running totals every `InpSummaryBars` bars and at exit |
| `ERROR` | always | Something failed — bypasses the log level, never tuned out |

Log levels (`InpLogLevel`): `0` off, `1` events, `2` decisions (default), `3` bars.

**The `SUM` line** is the "is it working" answer:

```
SUM | running | bars 240  flips 3  entries 2  open 1  stopMods 4 (0 failed)
SUM | running | vetoes: htf-disagrees=142  spread=8  same-dir=5
SUM | running | closed 1  win 1 / loss 0 (100%)  total +2.40R  avg +2.40R | exits: stop 0  tp 0  flip 1  other 0
SUM | running | spread avg 0.11 x ATR  max 0.22 x ATR  (a flip system needs this well under 0.25 to be viable)
```

The veto histogram names the rejecting filter; the spread figure tells you whether the timeframe can pay its costs.

---

## 16. Netting vs hedging

`OnInit` inspects `ACCOUNT_MARGIN_MODE`. On **hedging** accounts the position ticket is resolved explicitly via `PositionSelectByTicket()`. On **netting** accounts (one position per symbol) a warning is logged: a second EA on the same symbol shares that one position — its orders can reduce or close what this EA opened, and the magic filter cannot separate them. Give each EA its own symbol, or use a hedging account.

---

## 17. Input reference

### A. Signal (forwarded to the indicator)

| Input | Default | Notes |
|---|---|---|
| `InpHMAPeriod` | `20` | Hull period |
| `InpHMAPrice` | `PRICE_CLOSE` | Applied price |
| `InpSlopeFilter` | `EA_SLOPE_ATR` | Slope threshold mode |
| `InpSlopeATRMul` | profile | ATR mode: slope must exceed ATR × this |
| `InpATRPeriod` | `14` | ATR period |
| `InpSlopePoints` | `0.0` | Points mode: minimum slope |
| `InpConfirmBars` | `1` | Counter-trend bars needed to flip |

### B. Higher-timeframe filter

| Input | Default | Notes |
|---|---|---|
| `InpUseHTF` | `true` | Only trade with the higher TF trend |
| `InpHTFAuto` | `true` | Auto-derive the HTF from the chart TF |
| `InpHTF` | `PERIOD_H1` | HTF when Auto is off |
| `InpHTFMult` | `12.0` | Auto: target HTF as a multiple of chart TF |
| `InpHTFShift` | `1` | HTF bar to read (1 = closed, 0 = repaints) |

### C. Risk and sizing

| Input | Default | Notes |
|---|---|---|
| `InpRiskPercent` | `0.50` | Risk per trade (% of balance) |
| `InpFixedLots` | `0.0` | >0 overrides risk % |
| `InpMaxLots` | `5.0` | Hard lot cap |
| `InpSLMode` | `SL_ATR` | Stop placement |
| `InpSLmulATR` | profile | SL distance (×ATR) — ATR mode |
| `InpSwingBars` | `12` | Swing lookback — Swing mode |
| `InpSLpadATR` | `0.30` | SL padding (×ATR) — Swing / HMA modes |
| `InpTPmulR` | `0.0` | Take profit (R). 0 = none, exit on flip |
| `InpSlippagePts` | `20` | Max deviation (points) |

### D. Trade management

| Input | Default | Notes |
|---|---|---|
| `InpCloseOnFlip` | `true` | Close on the opposite flip (stop and reverse) |
| `InpMaxPositions` | `1` | Max simultaneous positions |
| `InpUseBreakEven` | `true` | Move stop to break-even |
| `InpBEatR` | `1.00` | Break-even trigger (R) |
| `InpBEoffsetPts` | `5.0` | Break-even offset (points, covers costs) |
| `InpUseTrailing` | `true` | Trail the stop |
| `InpTrailStartR` | `1.50` | Start trailing at (R) |
| `InpTrailDistR` | `1.00` | Trail distance (R) |
| `InpTrailStepR` | `0.10` | Min stop advance before modifying (R, 0 = every tick) |

### E. Guards

| Input | Default | Notes |
|---|---|---|
| `InpMaxSpreadATR` | profile | Reject if spread > this × ATR (0 = off) |
| `InpMaxSpreadPts` | `0.0` | Reject if spread > this many points (0 = off) |
| `InpMaxDriftR` | `0.35` | Reject if price drifted > this × risk |
| `InpMinBarsGap` | `0` | Min bars between entries (0 = off) |
| `InpUseTimeFilter` | `false` | Restrict trading hours (server time) |
| `InpStartHour` / `InpEndHour` | `7` / `20` | Wraps midnight correctly |
| `InpNoFridayLate` | profile | No new trades late Friday |
| `InpFridayStopHour` | `19` | Friday cut-off hour |
| `InpMaxDailyLossPct` | profile | Halt for the day after this % loss (0 = off) |
| `InpMaxTradesPerDay` | `0` | Max new trades per day (0 = unlimited) |

### F. Logging

| Input | Default | Notes |
|---|---|---|
| `InpLogLevel` | `LOGL_DECISIONS` | 0 off, 1 events, 2 decisions, 3 bars |
| `InpSummaryBars` | `240` | `SUM` line every N closed bars |
| `InpMagic` | profile | Magic number |
| `InpComment` | profile | Order comment |

---

## 18. Profile defaults table

| Default | Generic | Forex | Crypto |
|---|---|---|---|
| Minimum timeframe | M5 | M5 | H1 |
| `InpSlopeATRMul` | 0.20 | 0.20 | 0.25 |
| `InpSLmulATR` | 1.50 | 1.50 | 2.25 |
| `InpMaxSpreadATR` | 0.25 | 0.25 | 0.30 |
| `InpRiskPercent` | 0.50 | 0.50 | 0.50 |
| `InpNoFridayLate` | true | true | false |
| `InpMaxDailyLossPct` | 3.0 | 3.0 | 4.0 |
| `InpMagic` | 20260826 | 20260827 | 20260828 |
| `InpComment` | HullTrend | HullFX | HullCrypto |

---

## 19. Backtesting notes

- **Modelling mode:** "Every tick based on real ticks" is best — exits are SL/TP hits inside a bar. "Open prices only" is invalid. "1 minute OHLC" is an acceptable fast approximation.
- **Costs:** set a realistic fixed spread and commission. A flip system is cost-bound; if the `SUM` line's `spread avg x ATR` is not well under 0.25, the strategy is paying its edge to the spread on that timeframe.
- **Timeframe:** M5 is the practical floor for major FX pairs.
- **Warm-up:** allow the Hull warm-up (~25 bars) plus HTF history before the start date.
- **Optimising:** optimise the whipsaw inputs (`InpSlopeATRMul`, `InpConfirmBars`), the HTF multiple and the stop mode **separately** — never together.

---

## 20. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| EA logs `FATAL: cannot create the indicator handle` | `HullTrend_MT5.ex5` missing from `MQL5\Indicators\`. |
| EA never trades | Read the `SUM` line's `vetoes:` — it names the rejecting filter (`htf-disagrees` is the most common). |
| `sizing preflight: … rounds to ZERO lots` | Risk % below the minimum-lot floor; the `ERROR` line gives the exact % needed. |
| EA trades differ from chart arrows | The EA reads the **colour buffer** at shift 1, not arrows. Check `InpHTFShift` and that no other indicator copies are at play. |
| `WARNING: the X profile expects M5/H1 or higher` | Chart below the profile minimum. Watch the `SUM` spread line — on M1 retail FX it won't clear costs. |
| `adopted position #…, R reconstructed` | An open position survived an EA restart; it is trailed but never re-break-even'd. Expected. |
| Log shows `insufficient margin` / `margin:` veto | Order refused by the 90% free-margin pre-check. |
| `stop modify failed` | Freeze band or broker refusal; logged with the retcode. Counted in `SUM` (`stopMods X (N failed)`). |

---

## 21. Known limitations

1. **Cost-bound by construction.** A flip system pays the spread on every reversal; on retail M1 FX it cannot clear its own costs.
2. **R tracking does not survive restarts faithfully.** Positions open across a restart have R reconstructed from the current stop; adopted positions are trailed but never re-break-even'd.
3. **`iCustom` parameters are positional.** Reordering, inserting or deleting an indicator input or group header silently mis-feeds parameters. Read the indicator's `Hull Trend config:` line at `OnInit`.
4. **The HTF filter reads the indicator's colour**, so it inherits the indicator's whipsaw/confirmation settings on the HTF as well.
5. **Single-symbol.** No correlation awareness, no portfolio-level risk.
6. **Not validated as profitable.** Nothing here has been validated as profitable on live markets.

---

## 22. Version history

### 1.30
- **Profiles.** One shared core (`HullTrendEA_Core.mqh`), three front doors: generic, forex (M5+, Friday cut-off, magic `20260827`, comment `HullFX`), crypto (H1+, 2.25×ATR stop, 0.25 slope mult, 0.30 spread guard, 24/7, magic `20260828`, comment `HullCrypto`).
- **HTF selection rewritten** to snap to the nearest candidate in log space; the old lookup table silently returned the chart TF on untabulated timeframes, disabling the single biggest filter on one log line.
- Veto counting and the `SUM` veto histogram; sizing pre-flight; cost telemetry (`spread avg/max x ATR`).

### 1.20
- Initial shared-core release (base for the profile split in 1.30).

---

The wrapper files and the core carry extensive maintainer documentation in their headers. **Read those headers before modifying anything.**
