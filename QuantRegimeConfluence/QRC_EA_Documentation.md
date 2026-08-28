# Quant Regime Confluence — EA Execution Layer

**Companion guide to `QRC_Documentation.md`. This file covers the execution half of the system in full: the profiles, the shared core, every input, and every runtime behaviour.**

Version 1.10 · Last updated 2026-08-27

---

## Table of contents

1. [What the EA is (and is not)](#1-what-the-ea-is-and-is-not)
2. [The three front doors](#2-the-three-front-doors)
3. [File layout](#3-file-layout)
4. [The `iCustom` contract](#4-the-icustom-contract)
5. [Reading the indicator](#5-reading-the-indicator)
6. [Position sizing](#6-position-sizing)
7. [Margin and broker compliance](#7-margin-and-broker-compliance)
8. [Entry guards](#8-entry-guards)
9. [R tracking](#9-r-tracking)
10. [Break-even and trailing](#10-break-even-and-trailing)
11. [Daily guards](#11-daily-guards)
12. [Heartbeat and logging](#12-heartbeat-and-logging)
13. [Netting vs hedging](#13-netting-vs-hedging)
14. [Input reference — group A (forwarded)](#14-input-reference--group-a-forwarded)
15. [Input reference — groups B–E (execution)](#15-input-reference--groups-b-e-execution)
16. [Profile defaults table](#16-profile-defaults-table)
17. [Backtesting notes](#17-backtesting-notes)
18. [Troubleshooting](#18-troubleshooting)
19. [Known limitations](#19-known-limitations)
20. [Version history](#20-version-history)

---

## 1. What the EA is (and is not)

The EA is the **execution half** of the two-part system. It contains **no signal logic of its own**. It attaches to `QuantRegimeConfluence.ex5` via `iCustom`, reads that indicator's buffers on the last **closed** bar, and turns signals into orders with position sizing, margin checks, broker-compliance handling, and R-based trade management.

The split is deliberate and is the primary debugging tool:

- Chart shows an arrow the EA ignored → **execution bug**, look in the EA.
- The arrow itself is wrong → **model bug**, look in the indicator.

The EA never computes a statistic, never fires a signal, and never re-derives SL/TP from prices. It takes what the indicator publishes.

---

## 2. The three front doors

The strategy exists **once** in `QuantRegimeConfluenceEA_Core.mqh`. The three `.mq5` files are thin wrappers that only select a default profile before including the core:

| File | Profile | When to use |
|---|---|---|
| `QuantRegimeConfluenceEA.mq5` | **generic** | Original defaults, unchanged. Use when a profile adds nothing you want. |
| `QuantRegimeConfluenceEA_Forex.mq5` | **forex** | FX sessions where the weekend gap is a real risk: M15+ chart, Friday cut-off at 19:00 server time, 25-pt spread guard. |
| `QuantRegimeConfluenceEA_Crypto.mq5` | **crypto** | 24/7 markets with fat spreads: H1+ chart, 60-pt spread guard, no Friday cut, looser 4% daily-loss cap. |

Only **defaults** differ. The logic is byte-identical, so a fix made in the core reaches all three builds. Nothing is locked: every default is still a normal input the user can override in the tester or by editing the wrapper.

**Compile the wrapper you intend to trade** — each is its own `.ex5`.

---

## 3. File layout

| File | Destination | Purpose |
|---|---|---|
| `QuantRegimeConfluence.mq5` | `MQL5\Indicators\` | The model (signal logic) |
| `QuantRegimeConfluenceEA.mq5` | `MQL5\Experts\` | Execution — generic profile |
| `QuantRegimeConfluenceEA_Forex.mq5` | `MQL5\Experts\` | Execution — forex profile |
| `QuantRegimeConfluenceEA_Crypto.mq5` | `MQL5\Experts\` | Execution — crypto profile |
| `QuantRegimeConfluenceEA_Core.mqh` | `MQL5\Experts\` | Execution — all shared logic |

`QuantRegimeConfluenceEA_Core.mqh` carries a large maintainer header (the invariants, the position-tracking design and the backtesting notes). **Read it before modifying anything.**

---

## 4. The `iCustom` contract

The indicator declares **74 input parameters**, 9 of which are `input group` headers. Group headers are real positional slots in the parameter list, which makes `iCustom` arguments positional in a way that is easy to get wrong.

The EA's group A holds 27 values, but the `iCustom` call in `OnInit` passes **32 arguments**: the 27 values plus a `0` placeholder for each of the 5 `input group` headers that fall inside the forwarded range (groups A–E up to `InpScoreThreshold`).

```
g_hQRC = iCustom(_Symbol, _Period, "QuantRegimeConfluence",
                 0,                    //  1 group "A. Timeframes"
                 InpAutoLadder,        //  2
                 InpTF_Mid,            //  3
                 InpTF_High,           //  4
                 InpMaxBars,           //  5
                 0,                    //  6 group "B. Regime model"
                 (int)InpRegimeSrc,    //  7
                 ...                   // ...
                 InpScoreThreshold     // 32
                );
```

An earlier version of this file passed only 27 arguments. Every value landed one slot left at each group — `InpMaxBars` received `1`, `InpERPeriod` received `2`, and `InpScoreThreshold` never arrived at all. It compiled, ran, and produced trades. Nothing failed loudly.

**Rules:**
- Do not reorder, insert or delete an indicator input *or an `input group` header* above `InpScoreThreshold`.
- The indicator prints its resolved config at `OnInit` (`QRC config: autoLadder=… tfMid=… scoreThreshold=…`). Read that line before trusting any result.
- The logistic weights `InpBias`, `InpW1…InpW10` (indicator inputs 28+) are **not** forwarded; they stay at the indicator's own defaults. Extend the call if you want to optimise them.

---

## 5. Reading the indicator

The indicator writes signals to the last **closed** bar and clears the forming bar to `EMPTY_VALUE` on every tick. In series indexing:

- shift `0` = forming bar (always empty by design)
- shift `1` = last closed bar = **the signal**
- shift `2+` = stale bars

`ReadSignal()` copies buffers 0, 1, 2, 3, 5, 6 (buy, sell, score, regime, SL, TP) at shift 1, exactly one value each, and returns a **tri-state**:

| Return | Meaning | Action |
|---|---|---|
| `-1` | Indicator data not available yet (warm-up, history gap) | Retry next tick; **bar not consumed** |
| `0` | Bar read fine, no signal on it | Bar consumed, nothing to do |
| `+1` | Signal present (`dir`, `score`, `regime`, `sl`, `tp`) | Proceed to entry |

The tri-state matters: conflating "not ready" with "no signal" lost the first signal after attach — a real bug fixed before shipping.

An arrow without SL/TP is logged and treated as no signal (indicator/EA version mismatch).

---

## 6. Position sizing

`CalcLots(stopDistance)` is always called with the **real fill-to-stop distance**, never the indicator's theoretical one (the next-bar open shifts the realised R:R).

1. If `InpFixedLots > 0`, that wins immediately.
2. Otherwise risk-based:
   - `riskMoney = balance × InpRiskPercent / 100`
   - `lossPerLot = (stopDistance / tickSize) × tickValue` — uses `SYMBOL_TRADE_TICK_VALUE` / `SYMBOL_TRADE_TICK_SIZE`, so it is correct for FX, metals, indices and crypto alike; it never assumes 1 point = 1 unit.
   - `lots = riskMoney / lossPerLot`
3. Rounded **down** to the broker's `SYMBOL_VOLUME_STEP`, then capped at `min(SYMBOL_VOLUME_MAX, InpMaxLots)`.
4. If the result is below `SYMBOL_VOLUME_MIN`, the trade is skipped with a logged reason (this is the `risk X% implies N lots, below broker minimum` message).

---

## 7. Margin and broker compliance

Two layers run before an order is placed:

- **Margin pre-check** — `MarginOK()` calls `OrderCalcMargin()` for the intended order and rejects it if the margin requirement exceeds **90% of free margin**. The broker never gets to reject it for us.
- **Minimum stop distance** — `MinStopDist()` returns `max(SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL) × point`. If the indicator's SL or TP sits inside that distance from the fill, both are **widened** to the minimum. SL/TP are then normalised to `SYMBOL_DIGITS`.

The same freeze-band rule protects trade management: a stop is never pushed to within `MinStopDist()` of the current price, and a modification that would land inside the band is skipped.

---

## 8. Entry guards

Signals are filtered in `TryEnter()` before any order. Every refusal is logged. In order:

1. **Position cap** — `nPos >= InpMaxPositions` → ignored.
2. **Direction cap** — `InpOnePerDirection` and already long (for a buy) or short (for a sell) → ignored. Counts are per-direction, because a single flag cannot represent two positions.
3. **Time window** — `TimeAllowed()` (server time; wraps midnight correctly) and the Friday cut-off (`InpNoFridayLate`, `InpFridayStopHour`).
4. **Daily loss** — `DailyLossHit()` blocks new entries for the rest of the day once equity is down `InpMaxDailyLossPct` from the day's start.
5. **Daily trade cap** — `InpMaxTradesPerDay` (0 = unlimited).
6. **Spread** — `InpMaxSpreadPts > 0` and live spread above it → ignored.
7. **Stale signal** — `StaleSignalDrift()`: if price has already run more than `InpMaxDriftR × risk` past the model entry, the move happened without us and the assumed R:R is gone → ignored.
8. **Gap through the stop** — if the fill is already beyond the indicator's SL, the trade is refused (the stop is meaningless).

Only then are SL/TP adjusted for broker minimums and lots computed from the real distance.

---

## 9. R tracking

Break-even and trailing are expressed in **R** — multiples of the original stop distance — so the EA must remember each position's original stop. That state lives in memory (`g_track[]`):

- Each record holds `ticket, entry, risk, dir, beDone, reconstructed`.
- `TrackAdd()` **overwrites** a record with the same ticket rather than appending, so a duplicate can never shadow the real one.
- `TrackPrune()` drops records whose position no longer exists.
- The position a new order created is resolved by **ticket**, not by scanning for a symbol+magic match — a scan can bind the trade to an older ticket the moment two positions are open.

**Restart reconstruction.** If the EA restarts with positions open, `ManagePositions()` re-creates each record from the current stop distance and flags it `reconstructed`. If the stop had already moved to break-even, the reconstruction is wrong, so reconstructed positions are **trailed but never re-break-even'd** (their `beDone` is set immediately). This is a documented, accepted trade-off — the alternative is encoding state in the order comment, which brokers are free to rewrite. Positions opened after the restart manage normally.

---

## 10. Break-even and trailing

Both run from `ManagePositions()`, which executes **every tick** — stops must react intrabar.

**Break-even** (one-shot):
- Triggered when `rNow ≥ InpBEatR`.
- Target stop = entry ± `InpBEoffsetPts × point` (the offset covers costs).
- `beDone` is only set once the stop is actually **at** break-even, never merely because we tried — a broker freeze-band rejection would otherwise prevent a retry.
- Break-even is never throttled: it is a one-shot move that must happen when earned.

**Trailing** (throttled):
- Triggered when `rNow ≥ InpTrailStartR`. Trail level = `price − dir × InpTrailDistR × risk`.
- The stop advances only if the staged move is at least `InpTrailStepR × risk`. Without this throttle, every favourable tick issues a `PositionModify` server call — a flood a broker can refuse outright under rate limiting.
- The advance is measured against the stop the **broker currently holds**, not against a stop staged on the same tick. Measuring against the staged stop would let a break-even move satisfy the step and the throttle would do nothing on the one tick where both fire.

The log reports each successful move: `#ticket stop -> price (X.XXR open)`.

---

## 11. Daily guards

- **`RollDay()`** — runs every tick; detects a new server-trading day, snapshots equity, resets the trade counter and un-blocks the day.
- **`DailyLossHit()`** — equity is down ≥ `InpMaxDailyLossPct` from the day-start snapshot → block new entries for the rest of the day (0 = off).
- **`TimeAllowed()`** — optional hours window on server time; `InpStartHour > InpEndHour` wraps midnight. `InpNoFridayLate` cuts off new entries after `InpFridayStopHour` on Friday.
- **`InpMaxTradesPerDay`** — cap on new entries per day (0 = unlimited).

Note the daily-loss guard compares **equity**, so floating losses count. Blocking applies to new entries only; open positions are still managed (BE/trailing/SL).

---

## 12. Heartbeat and logging

Verbose logging (`InpVerboseLog = true`) prints **every decision, including refusals**, with the `QRC-EA |` prefix:

```
QRC-EA | signal ignored: spread 31.0 pts > 25.0
QRC-EA | signal ignored: price already moved 0.52R past the model entry (limit 0.35R)
QRC-EA | BUY  0.34 lots @ 1.08421  SL 1.08102  TP 1.09059 | score 88.3 regime 2
```

A refusal-only logger still produces no output on a quiet market — indistinguishable from a broken handle, a stopped terminal, or an EA that was never attached. The **heartbeat** fixes that: every `InpSummaryBars` closed bars (and always on the first closed bar of a run) it prints:

```
QRC-EA | watching | bars 214  signals 3  entries 2  open 1 | last score 58.4 (need >= 85.0)  regime 2  spread 11.2 pts (max 25.0)
```

That line is proof of life and simultaneously tells you *how close* the model got to the threshold — a different problem from the EA not running.

---

## 13. Netting vs hedging

`OnInit` inspects `ACCOUNT_MARGIN_MODE`:

- **Hedging accounts** — the position ticket is the opening order's ticket, resolved explicitly via `PositionSelectByTicket()`. Multiple positions per symbol work.
- **Netting accounts** — one position per symbol, so the order may merge into an existing position (`TrackAdd()` handles this by overwriting). A warning is printed: a **second EA on the same symbol** shares that one position; its orders can reduce or close what this EA opened, and the magic filter cannot separate them. Give each EA its own symbol, or use a hedging account.

---

## 14. Input reference — group A (forwarded)

27 inputs, forwarded verbatim to the indicator through the 32-argument `iCustom` call (§4). Their defaults mirror the indicator's — changing them here overrides the chart's indicator settings. See `QRC_Documentation.md` §12 for the meaning of each.

`InpAutoLadder`, `InpTF_Mid`, `InpTF_High`, `InpMaxBars`, `InpRegimeSrc`, `InpRetLookback`, `InpVRq`, `InpVolFast`, `InpVolSlow`, `InpERPeriod`, `InpSlopePeriod`, `InpTrendERn`, `InpSlopeT`, `InpVRz`, `InpExpandF`, `InpCompressF`, `InpSoftmaxTemp`, `InpMinRegimeConf`, `InpAllowExpansion`, `InpW_T1`–`InpW_C2`, `InpScoreThreshold`.

---

## 15. Input reference — groups B–E (execution)

### B. Risk and sizing

| Input | Default | Notes |
|---|---|---|
| `InpRiskPercent` | `0.50` | % of balance risked per trade |
| `InpFixedLots` | `0.0` | >0 overrides risk % |
| `InpMaxLots` | `5.0` | Hard lot cap |
| `InpMaxSpreadPts` | profile (§16) | Max spread to enter (points, 0 = off) |
| `InpMaxDriftR` | `0.35` | Reject if price moved > this × risk past the model entry |
| `InpSlippagePts` | `20` | Max deviation (points) |

### C. Trade management

| Input | Default | Notes |
|---|---|---|
| `InpMaxPositions` | `1` | Max simultaneous positions |
| `InpOnePerDirection` | `true` | Block a 2nd position in the same direction |
| `InpCloseOnOpposite` | `false` | Close positions when an opposite signal prints |
| `InpUseBreakEven` | `true` | Move stop to break-even |
| `InpBEatR` | `1.00` | Break-even trigger (R) |
| `InpBEoffsetPts` | `5.0` | Break-even offset (points, covers costs) |
| `InpUseTrailing` | `true` | Trail the stop |
| `InpTrailStartR` | `1.50` | Start trailing at (R) |
| `InpTrailDistR` | `1.00` | Trail distance (R) |
| `InpTrailStepR` | `0.10` | Min stop advance before modifying (R, 0 = every tick) |

### D. Guards

| Input | Default | Notes |
|---|---|---|
| `InpUseTimeFilter` | `false` | Restrict trading hours (server time) |
| `InpStartHour` / `InpEndHour` | `7` / `20` | Wraps midnight correctly |
| `InpNoFridayLate` | profile (§16) | No new trades late Friday |
| `InpFridayStopHour` | `19` | Friday cut-off hour |
| `InpMaxDailyLossPct` | profile (§16) | Halt for the day after this % loss (0 = off) |
| `InpMaxTradesPerDay` | `0` | Max new trades per day (0 = unlimited) |

### E. Bookkeeping

| Input | Default | Notes |
|---|---|---|
| `InpMagic` | profile (§16) | Magic number |
| `InpComment` | profile (§16) | Order comment |
| `InpVerboseLog` | `true` | Log decisions to the Experts tab |
| `InpSummaryBars` | `12` | Heartbeat every N closed bars (0 = off) |

---

## 16. Profile defaults table

| Default | Generic | Forex | Crypto |
|---|---|---|---|
| Minimum timeframe | M15 | M15 | H1 |
| `InpRiskPercent` | 0.50 | 0.50 | 0.50 |
| `InpMaxSpreadPts` | 25.0 | 25.0 | 60.0 |
| `InpNoFridayLate` | false | true | false |
| `InpFridayStopHour` | 19 | 19 | 19 |
| `InpMaxDailyLossPct` | 3.0 | 3.0 | 4.0 |
| `InpMagic` | 20260825 | 20260829 | 20260830 |
| `InpComment` | QRC | QRC-FX | QRC-C |

The spread guard is in absolute **points**, not a fraction of range, so it is instrument-specific by nature. The crypto default is loose because a crypto CFD spread of 30 points would be blocked outright by the forex value — which looks exactly like the model never signalling. Tune it per symbol.

The minimum-timeframe value is a warning threshold only: on a lower timeframe the EA logs `WARNING: the X profile expects Y or higher`, and it is on you to confirm the spread is small against the stop distances the indicator produces.

---

## 17. Backtesting notes

- **Modelling mode:** "Every tick based on real ticks" is best. The EA enters on bar open, but exits are SL/TP hits **inside** a bar, so the intrabar path matters. "Open prices only" is invalid and will produce nonsense. "1 minute OHLC" is an acceptable faster approximation.
- **Costs:** set a realistic fixed spread (not "current") and your broker's commission. The indicator's on-chart panel models neither, so the tester result is always worse than the panel. That gap is the cost of trading, not a bug.
- **Warm-up:** the indicator needs ~117 bars of each higher timeframe **before** the test start date. Start at least a few months after your data begins.
- **Optimising:** optimise the indicator thresholds and the risk block **separately**, never together — they interact and the joint space is far too large to trust.
- Headless runs via `qrc_backtest.ini` are described in `QRC_Documentation.md` §15.

---

## 18. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| EA logs `FATAL: cannot create the indicator handle` | `QuantRegimeConfluence.ex5` missing from `MQL5\Indicators\`. |
| EA never trades but arrows appear | Check the Experts log — every refusal is logged with its reason. |
| EA logs nothing at all | Check `InpVerboseLog` and `InpSummaryBars`. A live EA prints `watching | …`; total silence means it is not attached. |
| `risk X% implies N lots, below broker minimum` | Raise `InpRiskPercent`, or the symbol's minimum lot is too large for your balance. |
| EA trades differ from chart arrows | Indicator/EA input mismatch. The EA's group-A values override chart indicator settings. |
| `WARNING: the X profile expects M15/H1 or higher` | Chart timeframe below the profile's minimum. Fine if spread is small vs stop distances; otherwise switch profile or timeframe. |
| Log shows `insufficient margin` | Position refused by the 90% free-margin pre-check. |
| Position after a restart never break-evens | Expected: R was reconstructed from a possibly-moved stop, so it is trailed but not re-break-even'd (§9). |
| Second EA on the same symbol behaves oddly | Netting account: one position per symbol is shared. Use separate symbols or a hedging account (§13). |

---

## 19. Known limitations

1. **R tracking does not survive restarts faithfully.** Positions open across a restart have R reconstructed from the current stop; if it had already moved to break-even the reconstruction is wrong, so those positions are only trailed, never re-break-even'd.
2. **`iCustom` parameters are positional.** Reordering, inserting or deleting an indicator input *or an `input group` header* above `InpScoreThreshold` silently mis-feeds parameters. No compiler check exists — read the indicator's `QRC config:` line at `OnInit`.
3. **The indicator's logistic weights are not forwarded.** `InpBias`, `InpW1…InpW10` stay at the indicator's defaults; optimising them requires extending the `iCustom` call and adding matching EA inputs.
4. **The heartbeat is log-only.** It is proof of life, not a guard.
5. **Single-symbol.** No correlation awareness, no portfolio-level risk.
6. **Not validated as profitable.** The execution layer assumes the indicator's signals; nothing here has been validated as profitable on live markets.

---

## 20. Version history

### 1.10
- **Profiles.** One shared core (`QuantRegimeConfluenceEA_Core.mqh`), three front doors: generic (original defaults), forex (M15+, Friday cut-off, magic `20260829`, comment `QRC-FX`), crypto (H1+, 60-pt spread guard, no Friday cut, 4% daily loss, magic `20260830`, comment `QRC-C`).
- **New:** heartbeat watchdog (`InpSummaryBars`).
- **New:** trailing throttle (`InpTrailStepR`).
- **New:** margin pre-check (`OrderCalcMargin`, 90% free-margin cap) and broker minimum-stop-distance widening.
- **New:** netting-account warning and per-profile minimum-timeframe warning.
- Restart adoption of open positions is now logged; reconstructed positions are trailed but never re-break-even'd.

### 1.00
- Initial release.
- **Fixed before shipping:** `ReadSignal` conflated "no signal" with "indicator not ready" and consumed the bar either way — a signal on the first bar after attach was lost permanently. Now tri-state (`-1`/`0`/`+1`).

---

Both wrapper files and the core carry extensive maintainer documentation in their headers. **Read those headers before modifying anything.**
