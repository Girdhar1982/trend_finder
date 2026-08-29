# Hull Trend — EA Execution Layer

**Companion guide to `HullTrend_Documentation.md`. This file covers the EA half in full: the profiles, the shared core, every input, and every runtime behaviour.**

Version 1.40 · Last updated 2026-08-28

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
23. [Support and resistance](#23-support-and-resistance)

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
| `HullTrendSR_MT5.mq5` | `MQL5\Indicators\` | Draws the S/R levels (§23) — optional, not required to trade |
| `HullTrendSR.mqh` | `MQL5\Include\` | **Shared** S/R engine + HTF ladder. One copy, used by the EA *and* the S/R indicator |
| `HullTrendEA.mq5` | `MQL5\Experts\` | Execution — generic profile |
| `HullTrendEA_Forex.mq5` | `MQL5\Experts\` | Execution — forex profile |
| `HullTrendEA_Crypto.mq5` | `MQL5\Experts\` | Execution — crypto profile |
| `HullTrendEA_Core.mqh` | `MQL5\Experts\` | Execution — all shared logic |

`HullTrendEA_Core.mqh` and `HullTrendSR.mqh` both carry large maintainer headers — read them before modifying anything.

> `HullTrendSR.mqh` goes in `MQL5\Include\`, **not** next to the EA. It is included with angle brackets (`#include <HullTrendSR.mqh>`) by files that live in two different folders, and keeping a second copy would reintroduce exactly the drift it exists to prevent.

---

## 4. The `iCustom` contract

`HullTrend_MT5` declares **20 input parameters spread over 4 `input group` headers**. `input group` headers are real positional slots, so the call passes **24 arguments: 20 values + 4 placeholders**.

This is not folklore — it is verified against this build. In the terminal's `MQL5/Logs/` directory, an EA-created handle and a hand-attached copy of the same indicator print different `atrMul` values on the same bar: the EA's profile value reaches the indicator only because the group placeholders are there.

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
        InpConfirmWindow,      // 10
        0,                     // 11 group "Reversal arrows"
        false,                 // 12 show arrows   - the EA reads buffers
        233,                   // 13 up arrow code
        234,                   // 14 down arrow code
        10,                    // 15 arrow offset, points
        0.0,                   // 16 arrow offset, ATR - off: no ATR handle needed
        0,                     // 17 group "Alerts"
        0,                     // 18 signal bar    - closed bar
        false,                 // 19 pop-up alerts - the EA logs instead
        false,                 // 20 sound
        "",                    // 21 sound file
        false,                 // 22 push
        false,                 // 23 email
        false                  // 24 alert on attach
       );
```

Getting the placeholder count wrong fails **silently**: every value shifts one slot left and the indicator simply runs with the wrong settings. Three things defend against that now:

1. The indicator prints its resolved configuration at `OnInit` (`Hull Trend config: …`), so a shift is visible in the log.
2. The EA declares `HULL_ICUSTOM_ARGS` (currently `24`) and cross-checks it against the live handle with `IndicatorParameters()` at `OnInit`, logging the observed count in the `ENV` block. `HULL_ICUSTOM_ARGS` and `HULL_ICUSTOM_ARGS + 1` both pass, because some builds count the indicator name as parameter 0.

   A mismatch is a loud `ERROR`, **not** a refusal to start. What `IndicatorParameters()` counts for an `iCustom` handle is not documented tightly enough to bet a refusal-to-start on, and an EA that will not run at all is worse than the bug this guards against. Treat the error as "go and read check 1 before trusting anything".
3. `HullTrend_MT5.mq5` carries the count in a comment above its input block.

Do not reorder, insert or delete an input or a group header without updating all three.

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
   - **Arm** the signal, then attempt entry through the veto ladder (§11).
2. A flip that is vetoed still prints a `VETO` line and counts in the summary — a veto is not silence.

### Armed signals

A flip used to be a single shot: one attempt, on the flip bar, and the bar was consumed either way. Two failures followed from that.

- **The reversal could be lost entirely.** `CloseAgainst` and the new order are separate server round trips. If the close had not been booked when `TryEnter` read `PositionsTotal()`, the entry was vetoed as `pos-limit` — so the EA closed the old trade and never opened the new one. With `InpMaxPositions = 1` that is the *default* outcome of any close that does not settle instantly, and it is the worst half of a stop-and-reverse to execute on its own.
- **A momentary HTF disagreement discarded the whole move.** If the higher timeframe disagreed on the flip bar and agreed two bars later with the trend still intact, no trade ever happened until the next flip — which is the exit.

A flip now arms `g_armSig` for `InpSignalArmBars` bars (default `3`; `0` = flip bar only). The guards are re-tested:

- **on every tick** while armed, quietly — this is what closes the reversal race, because the position slot frees up between ticks, not on a bar boundary;
- **once per closed bar**, loudly — that is the attempt which prints a `VETO` line and counts in the histogram.

The arm is dropped when the entry fills, when the indicator turns the other way first, or when the window runs out (`ARM` log line). Nothing extends the risk: `g_armSig.entry` stays pinned to the **flip bar's close**, so as price runs away the `drift` guard rejects the trade on its own. The arm window lets a *good* entry through late; it does not chase a bad one.

Because the guards are re-tested per bar rather than per flip, the `vetoes:` histogram counts **attempts**, not flips. Totals above the flip count are expected.

The opposite flip is therefore the primary exit (`DEAL_REASON_EXPERT`, counted as `flip`). SL and TP hits (`stop-loss`, `take-profit`) are secondary. An optional `InpTPmulR` take-profit (0 = none) lets you exit early when a target is reached; otherwise only the flip or the stop ends the trade.

---

## 8. Stop placement modes

`InpSLMode` selects how the initial stop is placed from the fill:

| Mode | Stop level | Notes |
|---|---|---|
| `SL_ATR` (default) | `fill − dir × InpSLmulATR × atr` | Simple volatility multiple |
| `SL_SWING` | nearest **S/R level** on the protective side, padded by `InpSLpadATR × atr`; falls back to the swing low/high over `InpSwingBars` | A clustered level price has turned at repeatedly is a better stop than an extreme that was touched once (§23). Set `InpSRStop = false` for the old pure-swing behaviour. The fallback also applies when the nearest level is more than 3×ATR away |
| `SL_HMA` | `hma − dir × InpSLpadATR × atr` | The Hull line itself is the thesis — if price is through it, the trade is wrong by its own definition |

`InpTPmulR > 0` places `fill + dir × InpTPmulR × risk` as the take-profit. It is derived **after** the stop has been widened to the broker's minimum distance — deriving it first left the take-profit claiming an R multiple the trade no longer had.

The stop is widened using `SYMBOL_TRADE_STOPS_LEVEL` only. The **freeze level** is a different rule — it governs how close to price an *existing* order may be touched — and folding it in here made every initial stop wider than the broker actually required. It still applies to stop *modifications* (§13). The result is normalised to `SYMBOL_DIGITS`. A stop already on the **wrong side** of the fill means price has run through the protective level — the entry is vetoed (`stop-wrong-side`).

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
| 9 | `no-room-to-level` | The nearest S/R level ahead is closer than `InpSRVetoATR × ATR` (§23) |
| 10 | `stop-wrong-side` | The computed stop is already through the fill (§8) |
| 11 | `drift` | Price has run more than `InpMaxDriftR × risk` past the signal close — the assumed R:R is gone. Also what expires a stale armed signal |
| 12 | `lots-too-small` | Risk % rounds below the broker minimum lot, or fixed lots clamp below it |
| 13 | `margin` | Order needs > 90% of free margin, or `OrderCalcMargin` failed (which now logs) |
| 14 | `order-failed` | `Buy`/`Sell` retcode non-zero |

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
- Triggered when `rNow ≥ InpBEatR`, **or** as soon as the structural partial has been taken (§23) regardless of R — once part of the trade is banked at a level, the rest should run free. Target stop = entry ± `InpBEoffsetPts × point` (the offset covers costs).
- `beDone` is set only once the stop is actually **at** break-even, never merely because we tried — a freeze-band refusal must not prevent a retry.
- Never throttled.

**Trailing** (throttled):
- Triggered when `rNow ≥ InpTrailStartR`; trail level = `price − dir × InpTrailDistR × risk`.
- Advances only after a minimum move of `InpTrailStepR × risk`, measured against the stop the **broker currently holds** — not against a stop staged on the same tick (a break-even move would otherwise satisfy the step for the trail, and the throttle would do nothing on the one tick where both fire). The step costs nothing in placement: the stop ends up in the same place, in fewer hops, without flooding the broker with per-tick `PositionModify` calls.
- Never pushes the stop into the freeze band. Modification proximity uses `max(SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL)`, unlike initial placement (§8), which uses the stops level alone.

**Adopted positions.** A position open across a restart has its R reconstructed from the current stop. Break-even is now marked done only when that stop is **already at or beyond the entry**; blanket-disabling it meant a restart at 0.9R permanently lost break-even protection on that trade.

Each successful move logs `#ticket break-even|trail -> price (+X.XXR advance) at X.XXR open`.

---

## 14. Daily guards

- **`RollDay()`** — runs every tick; on a new server-trading day snapshots the **balance**, resets the trade counter, un-blocks the day. Equity at midnight carries whatever is floating on an open position, so a day that opened inside a drawdown started from an artificially low baseline and the halt fired late.
- **`DailyLossHit()`** — live equity down ≥ `InpMaxDailyLossPct` from the day's **opening balance** (floating losses count) blocks new entries for the rest of the day (0 = off).
- **`TimeAllowed()`** — optional hours window (server time; wraps midnight) plus `InpNoFridayLate` cut-off after `InpFridayStopHour`.
- **`InpMaxTradesPerDay`** — cap on new entries per day (0 = unlimited).

### Halts now close, not just block

Blocking new entries while leaving the open trade to ride the very weekend gap the Friday cut-off exists to avoid was never the intent of that input. `HaltCheck()` runs **every tick** — a cut-off that waits for the next closed bar is not a cut-off — and flattens everything the EA owns when:

- `InpFlattenOnFriday` (default **true**) and the Friday cut-off has passed, or
- `InpFlattenOnLoss` (default **true**) and the daily loss limit has been hit.

> **This changes results against every backtest run before v1.40.** Set both to `false` to reproduce the old behaviour. The `ENV` block prints which mode is active at startup (`halts: Friday cut-off 19:00 (flatten YES) | daily loss 3.00% (flatten YES)`).

Flattening also disarms any pending signal.

---

## 15. Logging

Every line is `HullEA | TAG | message` — one record per line, so the whole Experts tab can be pasted and read back. Tags:

| Tag | Level | Meaning |
|---|---|---|
| `ENV` | events | Once at startup: symbol/broker facts, account mode, profile, HTF choice, sizing pre-flight |
| `BAR` | bars (3) | One line per closed bar — noisy on M1, short diagnostic runs only |
| `FLIP` | events | The indicator changed trend |
| `ARM` | decisions | A flip is waiting for its guards, or has been disarmed (§7) |
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
SUM | running | vetoes: htf-disagrees=142  spread=8  no-room-to-level=11  same-dir=5
SUM | running | armed 3  filled late 1  expired 1  | S/R levels 14  avg room ahead 1.31xATR  veto at 0.75  partials 1
SUM | running | closed 1  win 1 / loss 0 (100%)  total +2.40R  avg +2.40R | exits: stop 0  tp 0  ea 1  other 0
SUM | running | spread avg 0.11 x ATR  max 0.22 x ATR  (a flip system needs this well under 0.25 to be viable)
```

The veto histogram names the rejecting filter; the spread figure tells you whether the timeframe can pay its costs.

Three numbers on the arm/S-R line are worth reading every run:

- **`filled late`** — entries that only happened because of the arm window. If this is a large share of entries, `InpSignalArmBars` is doing real work; if it is zero, the guards were never the bottleneck.
- **`avg room ahead`** — the mean distance, in ATR, from the signal-bar close to the nearest level in the trend direction. **Set `InpSRVetoATR` below this**, or the veto rejects almost everything.
- If `no-room-to-level` rejections outnumber entries, the `SUM` block prints an explicit warning naming the observed average — that veto is the one guard capable of silently stopping the strategy dead, so it is instrumented to say so.

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
| `InpConfirmWindow` | `0` | Bars a partial confirmation stays alive (`0` = `3 × InpConfirmBars`) |
| `InpSignalArmBars` | `3` | Bars a vetoed flip keeps retrying its guards (`0` = flip bar only). See §7 |

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
| `InpFlattenOnFriday` | `true` | **Also close** open trades at the cut-off. `false` reproduces pre-1.40 behaviour |
| `InpMaxDailyLossPct` | profile | Halt for the day after this % loss of the day's opening **balance** (0 = off) |
| `InpFlattenOnLoss` | `true` | **Also close** open trades when the limit hits. `false` reproduces pre-1.40 behaviour |
| `InpMaxTradesPerDay` | `0` | Max new trades per day (0 = unlimited) |

### F. Support and resistance

See §23 for what these do and how to tune them.

| Input | Default | Notes |
|---|---|---|
| `InpUseSR` | `true` | Build S/R levels from pivot fractals |
| `InpSRFractal` | `3` | Bars each side of a pivot. Also the confirmation lag: a level appears 3 closed bars after the bar that made it |
| `InpSRLookback` | `400` | Bars scanned on the trading TF (HTF scans `/4`) |
| `InpSRUseHTF` | `true` | Also scan the resolved higher timeframe |
| `InpSRClusterATR` | `0.50` | Merge pivots closer than this × ATR into one level |
| `InpSRMinTouches` | `2` | Ignore levels with fewer touches. `1` admits every single bar extreme and will flood the list |
| `InpSRMaxAgeBars` | `0` | Drop levels older than N bars (`0` = `20 × InpHMAPeriod`) |
| `InpSRVetoATR` | profile | Veto if the level ahead is nearer than this × ATR (`0` = off). **Check it against `avg room ahead` in the `SUM` line** |
| `InpSRTargetPart` | `0.50` | Fraction of the position closed at the level ahead (`0` = off) |
| `InpSRStop` | `true` | `SL_SWING` places the stop at an S/R level instead of the raw extreme |
| `InpSRDraw` | `false` | Draw the levels as dotted horizontal lines (orange at 3+ touches). Use it once to sanity-check, then turn it off |

### G. Logging

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
| `InpSRVetoATR` | 0.75 | 0.75 | 0.60 |
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
| `adopted position #…, R reconstructed` | An open position survived an EA restart. R is reconstructed from its current stop; the same line says whether break-even is `already set` or `still pending`. Expected. |
| Log shows `insufficient margin` / `margin:` veto | Order refused by the 90% free-margin pre-check. |
| `stop modify failed` | Freeze band or broker refusal; logged with the retcode. Counted in `SUM` (`stopMods X (N failed)`). |
| EA stopped trading after upgrading to 1.40 | Check the `SUM` line for `no-room-to-level`. If it outnumbers entries, `InpSRVetoATR` is above the typical level spacing — the same line prints `avg room ahead`; set the veto below it, or `0` to disable (§23). |
| Results changed after upgrading to 1.40 | Expected. Halts now flatten open positions by default. Set `InpFlattenOnFriday` and `InpFlattenOnLoss` to `false` to reproduce the old behaviour (§14). |
| `the trading-TF handle reports N iCustom parameters, expected 24` | The indicator's input list and `CreateHullHandle()` may have drifted apart. Confirm against the indicator's `Hull Trend config:` line, then re-sync both and `HULL_ICUSTOM_ARGS` (§4). The EA still runs — do not trust its results until you have checked. |
| `no usable data for 100 consecutive ticks` | The indicator is not compiled, or the symbol/timeframe history is not loaded. Nothing trades until it is. |
| Vetoes total more than flips | Expected since 1.40: guards are re-tested per bar while a signal is armed, so the histogram counts attempts (§7). |

---

## 21. Known limitations

1. **Cost-bound by construction.** A flip system pays the spread on every reversal; on retail M1 FX it cannot clear its own costs.
2. **R tracking does not survive restarts faithfully.** Positions open across a restart have R reconstructed from the current stop, which is only the original risk if nothing has moved it yet. Adopted positions also get no structural target.
3. **`iCustom` parameters are positional.** Reordering, inserting or deleting an indicator input or group header silently mis-feeds parameters. Read the indicator's `Hull Trend config:` line at `OnInit`.
4. **The HTF filter reads the indicator's colour**, so it inherits the indicator's whipsaw/confirmation settings on the HTF as well.
5. **Single-symbol.** No correlation awareness, no portfolio-level risk.
6. **S/R levels are geometry, not statistics.** A pivot cluster has no null distribution and no significance test; `touches` is a count, not evidence. The levels are used to veto and to take profit — never to enter — precisely because that is all the weight they can carry.
7. **The structural partial makes the reported R approximate.** A scaled-out position has two exit deals; the `CLOSE` line measures R against the **last** one and marks it `[scaled out]`. Treat it as the runner's result, not the blended one.
8. **Not validated as profitable.** Nothing here has been validated as profitable on live markets. The v1.40 changes fix defects and add instrumentation; none of them is evidence of an edge.

---

## 22. Version history

### 1.40

**Fixed — high severity**

- **A stop-and-reverse could leave the account flat.** The flip closed the old position, then `TryEnter` read a position list the broker had not updated yet and vetoed the reversal as `pos-limit` — with the bar already consumed, so it never retried. Flips now arm a signal that re-tests its guards every tick (§7). `CloseAgainst()` returns whether the close actually settled.
- **`NormalizeDouble(lots, 2)` destroyed sizing below a 0.01 volume step.** On a 0.001-step symbol a correct 0.003 lots became `0.00` (rejected) and 0.005 became 0.01 — double the intended risk. Volume digits are derived from `SYMBOL_VOLUME_STEP`.

**Fixed — medium and low**

- Fixed lots bypassed every broker constraint (no min/step/max clamp) — they now go through the same `ClampLots()` as risk-based sizing.
- The lot cap was applied *after* step rounding, so a cap that was not a step multiple produced an off-step volume.
- The take-profit was derived from the pre-widened stop, so it no longer represented `InpTPmulR` R once the broker minimum kicked in.
- A single-shot flip discarded the whole move when the HTF disagreed on the flip bar only (§7).
- A signal or HTF handle that never filled stalled the EA silently and forever. Both now trip a watchdog after 100 consecutive not-ready ticks.
- `OrderCalcMargin` failure was the one reject path with no log line at all; `VETO_MARGIN` appeared in the summary unexplained.
- The daily-loss baseline was equity at midnight, which included floating P&L (§14).
- Adopted positions were flagged break-even-done unconditionally, so a restart at 0.9R permanently lost break-even protection (§13).
- Initial stop placement conflated `SYMBOL_TRADE_FREEZE_LEVEL` with `SYMBOL_TRADE_STOPS_LEVEL` (§8).
- No `SYMBOL_TRADE_MODE` check at startup: a disabled, close-only or one-side-only symbol produced order failures instead of a startup error.

**Added**

- **Support and resistance** (§23): clustered pivot fractals used to veto entries with no room, take a structural partial, and place the swing stop. Never to generate an entry.
- **Armed signals** (§7), `InpSignalArmBars`.
- **Added:** `HullTrendSR_MT5` — a companion indicator that draws the levels. The engine moved to the shared `HullTrendSR.mqh` (with the HTF ladder) so the EA and the drawing cannot diverge.
- Friday cut-off and daily-loss halt can now **close** open positions (`InpFlattenOnFriday`, `InpFlattenOnLoss`, both default `true`).
- `HULL_ICUSTOM_ARGS` is cross-checked against the live handle via `IndicatorParameters()` at `OnInit`, and the observed count is printed in `ENV`. A mismatch is a loud error, not a refusal to start (§4).
- `SUM` reports arm statistics, S/R level count, average room ahead, and warns when the S/R veto is rejecting more than it admits.

**Behaviour changes to be aware of**

- Halts flatten by default — results differ from every earlier backtest. Set both flatten inputs to `false` to reproduce the old behaviour.
- The veto histogram counts **attempts**, not flips (§7).
- `iCustom` argument count 21 → **24** (indicator 2.30 adds three inputs).
- `CLOSE` reason `flip` is now labelled `ea-exit`: the EA closes on halts as well as on flips, and calling both "flip" was wrong.

### 1.30
- **Profiles.** One shared core (`HullTrendEA_Core.mqh`), three front doors: generic, forex (M5+, Friday cut-off, magic `20260827`, comment `HullFX`), crypto (H1+, 2.25×ATR stop, 0.25 slope mult, 0.30 spread guard, 24/7, magic `20260828`, comment `HullCrypto`).
- **HTF selection rewritten** to snap to the nearest candidate in log space; the old lookup table silently returned the chart TF on untabulated timeframes, disabling the single biggest filter on one log line.
- Veto counting and the `SUM` veto histogram; sizing pre-flight; cost telemetry (`spread avg/max x ATR`).

### 1.20
- Initial shared-core release (base for the profile split in 1.30).

---

## 23. Support and resistance

### What it is for

The EA's structural weakness is stated in its own design notes: it is a stop-and-reverse
trend follower whose only exit is the opposite flip. A flip arrives *after* the move has
already turned over, so every winning leg gives back the distance from its peak to the
reversal. S/R is aimed at that, and at entries taken into a wall.

Three uses, in descending order of expected value:

1. **Entry veto.** At entry, measure the distance to the nearest level in the trade's
   direction. If it is less than `InpSRVetoATR × ATR`, veto (`no-room-to-level`). A long
   entered a fraction of an ATR under a level that has already turned price away twice is
   taking a full-size stop for a truncated move.
2. **Structural partial.** When price reaches the level that was ahead at entry, close
   `InpSRTargetPart` of the position and put the runner at break-even. A fixed R target on a
   trend follower is wrong — which is why `InpTPmulR` is off by default — but a
   *structural* target is not.
3. **Stop placement.** `SL_SWING` uses the nearest level on the protective side rather than
   the raw extreme of the last `InpSwingBars` bars. An extreme touched once is not the same
   as one touched three times.

**S/R is never used to generate an entry.** Bounce trading is a different strategy with a
different edge, a different stop and a different cost profile; mixing it in would make both
untestable.

### Seeing them on the chart

Attach **`HullTrendSR_MT5`** to the same chart. It shares the EA's engine (`HullTrendSR.mqh` in `MQL5\Include\`) rather than reimplementing it, so with matching inputs it draws exactly the levels the EA is trading against.

| Reading it | |
|---|---|
| Line start | The pivot that created the level — you can see where it came from, not just that it exists |
| Colour | Red above the current price (resistance), green below (support). Levels switch side as price crosses them |
| Width / style | Dotted and thin = 2 touches; solid = 3+; thickest = 6+ |
| Label | `R1  0.42 ATR  38 pips  ***` — the level's **rank** (R1/S1 = nearest, counting outwards), then how far away it is in ATR (the exact quantity `InpSRVetoATR` is compared against) and in pips (what the stop is sized in), then strength as one `*` per touch, capped at five |
| Label detail | `InpLabelDetail`: **Compact** = rank + ATR only; **Normal** (default) = + pips + strength; **Full** = + the price, the touch count and how long since the level was last touched |
| Tooltip | Hover any line for the long form: price, distance in both units, touch count, and the first/last pivot timestamps |
| Panel | A summary block in the chart corner (`InpPanel`) — see below |

The panel is the part a label cannot do, because the useful quantity lives *between* two levels:

```
HULL S/R   EURUSD M15   HTF H4   ATR 4.2 pips
R1  1.16412   +38.0 pips   0.42 ATR   ***   last 5h
S1  1.16050   -18.4 pips   0.20 ATR   **    last 2d
price 1.16234 sits 33% up a 56.4 pips band  (0.62 ATR wide)
drawn 6 of 9 levels with 2+ touches   (14 clustered)
```

- **Line 2 / 3** — the two levels the EA's veto actually measures against, with the distance
  in both units and how recently each was last defended.
- **Line 4** — where price sits inside the band. This is what says whether a long is buying
  support or chasing into resistance; no single level label can carry it.
- **Line 5** — how much of the level set you are actually looking at. `drawn` is capped by
  `InpMaxEachSide`; the gap between `with 2+ touches` and `clustered` is what `InpMinTouches`
  is filtering out.

Distances are shown in pips on 3- and 5-digit FX symbols and in points elsewhere; on
instruments where the point count runs past five figures (indices, coins) the raw price move
is printed instead, because "48300 pts" is not a number anyone holds in their head.

**Match these inputs to the EA or the picture is fiction:** `InpFractal`, `InpLookback`, `InpClusterATR`, `InpMinTouches`, `InpMaxAgeBars`, `InpATRPeriod`, and the whole higher-timeframe group. Both programs print their resolved configuration at `OnInit` (`Hull Trend S/R config: …` and the EA's `ENV | S/R …` line) — read them side by side once.

The EA's own `InpSRDraw` draws the same levels from inside the EA, under a different object prefix, which is useful in a visual-mode backtest. On a live chart prefer the indicator: it works without the EA running, and it refreshes its colours and distance labels every `InpRedrawSecs` seconds rather than once per bar.

### How the levels are built

Rebuilt once per closed bar, in `SRBuild()` (`HullTrendSR.mqh`), which both the EA and the indicator call:

1. **Pivot fractals.** A pivot high is a bar whose high exceeds the `InpSRFractal` highs on
   each side; a pivot low is the mirror. Scanned on the trading timeframe and, when
   `InpSRUseHTF`, on the resolved HTF over the same wall-clock window.
2. **Never repaints.** A pivot at shift `i` is only examined once the `k` bars to its right
   have closed, so the scan starts at shift `k + 1` (shift 0 is still forming). A level
   cannot appear, move or vanish after the fact — which is the whole reason to prefer
   fractals over anything fitted.
3. **Clustered.** Pivots within `InpSRClusterATR × ATR` of each other merge into one
   level whose price is the touch-weighted running mean and whose strength is the touch
   count. Highs and lows go into **one** list: a broken resistance becomes support, and a
   price that is both a pivot high and a pivot low is one strong level, not two weak ones.
4. **Aged out.** Anything older than `InpSRMaxAgeBars` (default `20 × InpHMAPeriod`) is
   dropped.
5. **Filtered at query time.** `SRNearest()` ignores levels below `InpSRMinTouches`.

### Tuning it — read the numbers, do not guess

`InpSRVetoATR` is the one guard in this EA capable of silently stopping the strategy dead.
Set it above the typical spacing between levels and *nothing* ever has enough room; the only
symptom is an EA that no longer trades. So it is instrumented:

```
SUM | running | armed 3  filled late 1  expired 1  | S/R levels 14  avg room ahead 1.31xATR  veto at 0.75  partials 1
```

- **`S/R levels`** — how many survive clustering and the touch filter. Dozens means
  `InpSRMinTouches` is too low or `InpSRClusterATR` too tight; two or three means the
  opposite.
- **`avg room ahead`** — the mean distance from the signal-bar close to the nearest level
  in the trend direction. **`InpSRVetoATR` must sit below this**, usually well below.
- If `no-room-to-level` rejections outnumber entries, the `SUM` block prints an explicit
  warning with the number needed to fix it.

Recommended procedure, one change at a time against the same backtest:

1. Run once with `InpSRVetoATR = 0` (veto off, everything else on). Note `avg room ahead`
   and the baseline result.
2. Set `InpSRVetoATR` to roughly half the observed average. Re-run and compare entries, win
   rate **and** total R — not total R alone.
3. Only then touch `InpSRTargetPart`, and only then `InpSRStop`.
4. Attach `HullTrendSR_MT5` and confirm the levels land where you would have drawn them
   by hand. The `R1` and `S1` rows of its panel carry the ATR distance to the nearest level
   each side: that is the number `InpSRVetoATR` has to sit below.

### The cheaper experiment to run first

Before spending time on S/R, sweep `InpTrailStartR` / `InpTrailDistR`, or try a plain
chandelier exit. If a volatility trail already captures most of the give-back, S/R is a lot
of surface area for a small marginal gain. Structure earns its place only if it beats that
baseline.

---

The wrapper files and the core carry extensive maintainer documentation in their headers. **Read those headers before modifying anything.**
