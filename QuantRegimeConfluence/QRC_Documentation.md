# Quant Regime Confluence Engine

**A non-repainting MetaTrader 5 signal system built on statistics with known null distributions.**

Version 1.11 (indicator) · 1.10 (EA) · Last updated 2026-08-27

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [System architecture](#2-system-architecture)
3. [Installation](#3-installation)
4. [The mathematics](#4-the-mathematics)
5. [Regime classification](#5-regime-classification)
6. [Signal Strength Score](#6-signal-strength-score)
7. [Non-repainting guarantees](#7-non-repainting-guarantees)
8. [The signal pipeline](#8-the-signal-pipeline)
9. [Risk model](#9-risk-model)
10. [Reading the dashboard](#10-reading-the-dashboard)
11. [Buffer contract](#11-buffer-contract)
12. [Input reference — indicator](#12-input-reference--indicator)
13. [Input reference — EA](#13-input-reference--ea)
14. [Testing protocol](#14-testing-protocol)
15. [Backtesting](#15-backtesting)
16. [Optimisation strategy](#16-optimisation-strategy)
17. [Troubleshooting](#17-troubleshooting)
18. [Known limitations](#18-known-limitations)
19. [Maintenance checklist](#19-maintenance-checklist)
20. [Version history](#20-version-history)

---

## 1. What this is

A two-part MT5 system: an **indicator** that models the market and an **Expert Advisor** that trades what the indicator says.

The design premise is that classical indicators answer the wrong question. RSI, moving averages and their relatives tell you *where price sits relative to its own history*. They cannot tell you whether that reading is **distinguishable from noise**. A moving average crossover on a pure random walk looks exactly like a moving average crossover on a genuine trend.

Every feature in this system is instead a **statistic with a known value under a random walk**. That means each reading answers "how surprising is this versus chance?" rather than "is this line above that line?" — and it makes every threshold interpretable and honestly calibratable.

Four estimators do the work:

| Statistic | Measures | Null value |
|---|---|---|
| Variance F-ratio | volatility expansion / compression | 1.00 |
| Normalised efficiency ratio `ERn` | directionality | 1.00 |
| Lo–MacKinlay `z_VR` | trend persistence (autocorrelation) | 0.00 |
| Normalised trend statistic `Tn` | trend strength | 1.00 |

These feed a regime classifier, a multi-timeframe confluence filter, a logistic probability score, and an ATR-based dynamic risk model.

> **This is a signal and execution framework, not a proven profitable strategy.** The defaults are calibrated against synthetic noise, not against your instrument. Nothing here has been validated as profitable on live markets. Treat it as an instrument you must still tune and verify.

---

## 2. System architecture

```
┌──────────────────────────────────────────────────────────┐
│  QuantRegimeConfluence.mq5          (MQL5\Indicators\)   │
│  ─────────────────────────────────────────────────────   │
│  THE MODEL. All signal logic lives here.                 │
│                                                          │
│   BuildTFCtx()      per-TF series + features             │
│   MapClosedIndex()  chart bar -> last CLOSED higher bar  │
│   ClassifyRegime()  4 stats -> softmax -> regime         │
│   SignalScore()     10 features -> logistic -> 0..100    │
│                                                          │
│  Outputs: arrows, SL/TP lines, dashboard, 7 buffers      │
└────────────────────────┬─────────────────────────────────┘
                         │ iCustom + CopyBuffer (shift 1)
                         ▼
┌──────────────────────────────────────────────────────────┐
│  QuantRegimeConfluenceEA*.mq5         (MQL5\Experts\)    │
│  ─────────────────────────────────────────────────────   │
│  EXECUTION ONLY. No signal logic whatsoever.             │
│                                                          │
│   Three thin wrappers around ONE shared core             │
│   (QuantRegimeConfluenceEA_Core.mqh):                    │
│     QuantRegimeConfluenceEA.mq5        generic profile   │
│     QuantRegimeConfluenceEA_Forex.mq5  M15+, Fri cutoff  │
│     QuantRegimeConfluenceEA_Crypto.mq5 H1+, 24/7         │
│                                                          │
│   Position sizing · margin check · broker compliance     │
│   Break-even + trailing in R · session/loss guards       │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  QRC_SelfTest.mq5                   (MQL5\Scripts\)      │
│  Validates the estimators against known nulls.           │
└──────────────────────────────────────────────────────────┘
```

**Why the split matters.** When a trade looks wrong you can localise the fault immediately:

- Chart shows an arrow the EA didn't take → **execution bug**, look in the EA.
- The arrow itself is wrong → **model bug**, look in the indicator.

The indicator is independently testable without risking a cent.

---

## 3. Installation

Files belong in your terminal's data folder (**File → Open Data Folder** in MT5):

| File | Destination |
|---|---|
| `QuantRegimeConfluence.mq5` | `MQL5\Indicators\` |
| `QuantRegimeConfluenceEA.mq5` | `MQL5\Experts\` |
| `QuantRegimeConfluenceEA_Forex.mq5` | `MQL5\Experts\` |
| `QuantRegimeConfluenceEA_Crypto.mq5` | `MQL5\Experts\` |
| `QuantRegimeConfluenceEA_Core.mqh` | `MQL5\Experts\` |
| `QRC_SelfTest.mq5` | `MQL5\Scripts\` |

The three EA files are thin wrappers over one shared core; **compile the wrapper you intend to trade** (each is its own `.ex5`). The generic one keeps the original defaults; `_Forex` adds a late-Friday cut-off; `_Crypto` uses a wider spread guard, a higher minimum timeframe and a looser daily-loss cap. See [§13](#13-input-reference--ea) for the full profile table.

Compile each (F7 in MetaEditor), then **right-click Navigator → Refresh**.

### Command-line compile

```powershell
& "C:\Program Files\Go MetaTrader 5\MetaEditor64.exe" `
    /compile:"<full path>\QuantRegimeConfluence.mq5" `
    /log:"<full path>\qrc.log"
```

Two gotchas that waste time if you don't know them:

- The log is **UTF-16**. Read it with `Get-Content -Encoding Unicode` or it looks empty.
- MetaEditor returns **exit code 1 on success**. Parse the `Result: N errors, M warnings` line, never the exit code.

### Requirements

- The indicator needs roughly **117 bars of each higher timeframe** before it produces anything. On a fresh chart it will sit at `Status: loading H4 history` until MT5 downloads them. This is self-healing — opening an H4 chart of the same symbol once forces the download.
- The EA requires `QuantRegimeConfluence.ex5` present in `MQL5\Indicators\`, since it loads it by name via `iCustom`.

---

## 4. The mathematics

### 4.1 Feature A — Variance F-ratio (volatility state)

With log returns `r_k = ln(C_k / C_{k-1})`:

```
        σ²_fast   (variance over n_fast bars)
  F  =  ───────
        σ²_slow   (variance over n_slow bars)
```

Under homoskedasticity `F ~ F(n_fast−1, n_slow−1)`. This is a genuine test statistic, not an ad-hoc ratio.

- `F > 1.40` → variance expansion
- `F < 0.65` → variance compression (a coil / squeeze)
- `F ≈ 1.00` → stable

This replaces Bollinger-squeeze heuristics with the same idea done properly.

### 4.2 Feature B — Normalised efficiency ratio

Kaufman's efficiency ratio over `n` bars:

```
        | C_i − C_{i−n} |
  ER = ───────────────────
        Σ | C_k − C_{k−1} |
```

The part most implementations miss: **ER has a known random-walk expectation.** For a driftless random walk, `E[|C_i − C_{i−n}|] ≈ σ√(2n/π)` while `E[Σ|ΔC|] = nσ√(2/π)`, giving

```
  E[ER_randomwalk] ≈ 1/√n
```

So we normalise:

```
  ERn = ER · √n
```

Now **`ERn = 1.00` means exactly as directional as a coin flip**, and `ERn = 2.00` means twice as efficient as random. Critically, this is invariant to both timeframe and lookback, which is what makes it valid to compare M15 against H4 and to optimise a single threshold.

### 4.3 Feature C — Lo–MacKinlay variance ratio (persistence)

The core "is there real structure here" test. With `N` one-period log returns and aggregation `q`:

```
  μ̂  = (p_N − p_0) / N

  σ̂²_a = 1/(N−1) · Σ (p_k − p_{k−1} − μ̂)²

  σ̂²_c = 1/m · Σ (p_k − p_{k−q} − q·μ̂)²
         where m = q(N−q+1)(1 − q/N)

  VR(q) = σ̂²_c / σ̂²_a
```

Under a random walk `VR = 1`. The asymptotic test statistic is

```
                VR(q) − 1
  z_VR = ───────────────────────────  ~  N(0,1)
         √[ 2(2q−1)(q−1) / (3qN) ]
```

- `z_VR > +2` → significant positive autocorrelation → continuation is statistically favoured
- `z_VR < −2` → mean reversion → fade rather than follow breakouts
- `|z_VR| < 2` → indistinguishable from random → stand down

Free by-product: since `VR(q) = q^(2H−1)` for fractional Brownian motion,

```
  H = ½ · (1 + ln(VR) / ln(q))
```

displayed on the dashboard as the implied Hurst exponent.

### 4.4 Feature D — Normalised trend statistic `Tn`

Regress close on bar index over `n` bars; the raw OLS statistic is `t = b / SE(b)`.

> ### ⚠ Trap 1 — the raw t-statistic is not a significance test
>
> Regressing a random walk on time is the textbook **spurious regression** case (Granger–Newbold). Residuals are serially correlated, `SE(b)` is badly understated, and `|t|` is large on pure noise. Measured over 3000 synthetic random walks at `n = 30`:
>
> ```
>   mean |t| = 5.80        p90 |t| = 12.4
>   a threshold of |t| ≥ 2.0 fires on 75.7% of PURE NOISE
> ```
>
> A "textbook" threshold of 2.0 is **not a filter at all**. This was a real defect in v1.00 of this system, found by testing.

The null grows as `√n`, and `|t|/√n` is stable to within 3.7% across `n = 15…120`. So we divide by the measured null:

```
  Tn = t / (1.049 · √n)
```

`Tn` now has null mean **1.00** and null p90 **2.13**, exactly matching `ERn`. This makes `InpSlopeT` **lookback-invariant** — you can optimise `InpSlopePeriod` without silently changing what the threshold means. The sign is preserved and carries trend direction.

### 4.5 Calibration table

All four statistics were validated against 3000 synthetic random walks. These are **measured**, not assumed:

| Statistic | Null | p90 | p95 | p99 | Shipped threshold |
|---|---|---|---|---|---|
| `ERn` | 1.00 | 2.07 | 2.42 | 3.09 | 2.05 |
| `Tn` | 1.00 | 2.13 | 2.35 | 2.55 | 2.10 |
| `z_VR` | 0.00 | 1.36 | 1.80 | 2.63 | 1.30 |
| `F` | 1.00 | 1.40 | 1.51 | 1.73 | 1.40 / 0.65 |

Every shipped threshold sits at the **~p90 tail of the null**. A reading at threshold means "chance alone would produce this about 10% of the time on pure noise."

Two independent confirmations that the implementations are correct:

- `ERn` measured null **1.017** against theoretical **1.000** — validates the `1/√n` derivation.
- `z_VR` measured p90 **1.36** against asymptotic N(0,1) p90 **1.282** — slightly fat-tailed as expected for finite samples with overlapping windows, but closely calibrated.

### 4.6 Trap 2 — the variance ratio is deliberately blind to drift

`CalcVarRatio()` subtracts `q·μ̂` from the q-period returns, so a constant drift is removed entirely. Measured:

| Series | `ERn` | `VR(4)` | `z_VR` | Hurst |
|---|---|---|---|---|
| Random walk, no drift | 1.017 | 1.003 | 0.014 | 0.494 |
| **Drift only** (0.4σ/bar) | **2.069** | **1.003** | **0.014** | **0.494** |
| AR(1) φ = +0.35 | 1.408 | 1.657 | 3.512 | 0.677 |
| AR(1) φ = −0.35 | 0.735 | 0.585 | −2.218 | 0.299 |

This is **correct**. Drifting geometric Brownian motion is still a random walk, and the VR test is a test for **autocorrelation**, not for direction. Note how drift moves `ERn` from 1.02 to 2.07 while leaving `VR` at 1.00.

`ERn` and `VR` are therefore **complementary, not redundant** — `ERn` sees direction, `VR` sees persistence.

> If a future change makes `VR` respond to drift, that change is a **bug**, not an improvement.

---

## 5. Regime classification

Rather than nested if-statements, the four statistics feed three linear discriminant scores:

```
  s_TREND    = w_T1·(ERn − θ_ER) + w_T2·(|Tn| − θ_t) + w_T3·(z_VR − θ_VR)
  s_EXPAND   = w_E1·(F − θ_F+)   + w_E2·(θ_ER − ERn)
  s_COMPRESS = w_C1·(θ_F− − F)   + w_C2·(θ_t − |Tn|)
```

These go through a softmax with temperature `τ`:

```
  P(regime_j) = exp(s_j/τ) / Σ exp(s_k/τ)

  regime     = argmax_j P_j
  confidence = max_j P_j
```

This yields a **calibrated confidence**, not a binary flag — so "TREND at 0.58" and "TREND at 0.94" are handled differently downstream. Signals are gated on both the regime *and* `confidence ≥ InpMinRegimeConf`.

The three regimes:

| Regime | Meaning | Trades? |
|---|---|---|
| `STRUCTURED TREND` | efficient, persistent, significant slope | **yes** (default) |
| `VOL EXPANSION` | high variance, low efficiency — chaotic | only if `InpAllowExpansion` |
| `VOL COMPRESSION` | coiled, low variance, no structure | **no** — breakout watch |

Because all four statistics now share a common null of 1.00 (or 0.00 for `z_VR`), the discriminant weights are directly comparable to one another — a property v1.00 did not have.

---

## 6. Signal Strength Score

Ten direction-aligned features (`d = +1` long, `−1` short), each squashed to roughly `[−1, +1]`:

| # | Feature | Definition | Input |
|---|---|---|---|
| 1 | HTF structure | `tanh((d·Tn_HTF − 1)/1.5)` | `InpW1_HTFStruct` |
| 2 | MTF momentum | `tanh(d·z_drift_MTF / 2)` | `InpW2_MTFMom` |
| 3 | LTF momentum | `tanh(d·z_drift_LTF / 2)` | `InpW3_LTFMom` |
| 4 | Efficiency edge | `tanh(ERn − 1)` | `InpW4_Efficiency` |
| 5 | Persistence | `tanh(z_VR / 2)` | `InpW5_Persistence` |
| 6 | Regime favourability | `confidence · {+1, +0.3, −1}` | `InpW6_Regime` |
| 7 | Entry location | `1 − min(1, |C−EMA|/(2·ATR))` | `InpW7_Location` |
| 8 | Displacement | `tanh(d·(C−O)/ATR / 0.8)` | `InpW8_Displacement` |
| 9 | Volume confirmation | `tanh(z_vol / 2)` | `InpW9_Volume` |
| 10 | TF alignment | `2·(agreeing/3) − 1` | `InpW10_Alignment` |

Combined through a logistic link:

```
  z     = b₀ + Σ wₖ·fₖ
  Score = 100 / (1 + e^(−z))
```

Features 1 and 4 are **centred on the null**: a reading of exactly "as trendy as noise" scores 0, not a positive contribution.

This is a hand-initialised **logistic regression**. Every weight and the intercept are inputs, so the Strategy Tester's genetic optimiser is literally performing coefficient fitting on your data. A threshold of 85 requires `z ≥ 1.735`.

---

## 7. Non-repainting guarantees

Three invariants, enforced structurally rather than by convention. **Breaking any one causes repainting.**

### Invariant 1 — never read the forming bar

```mql5
for(int i = start; i <= rates_total - 2; i++)
```

Index `rates_total-1` is the forming bar. It is cleared to `EMPTY_VALUE` every tick and never scored.

### Invariant 2 — higher timeframes must be closed

```mql5
// MapClosedIndex(): largest j satisfying
T_j + PeriodSeconds(tf)  <=  T_i + PeriodSeconds(_Period)
```

The higher-timeframe bar must have **already closed** when the chart bar closed.

> This is *the* reason this indicator does not repaint. Naïve `iBarShift()`, or `CopyBuffer(handle, 0, 0, …)` on a higher timeframe, returns a bar that is **still forming** — the single most common repaint bug in multi-timeframe indicators.

### Invariant 3 — each bar is scored exactly once, ever

```mql5
if(time[i] <= g_lastBarTime) continue;
```

MT5 re-runs `OnCalculate` on every tick. Without this guard, win/loss statistics would double-count and objects would be redrawn repeatedly. **Any new per-bar side effect must go after this guard.**

### On the EA side

The EA reads **shift 1** only — the last closed bar — exactly once per new bar. Shift 0 is the forming bar (always empty by design); shift 2+ would act on stale bars.

**Net effect:** a signal printed at bar close is final. Historical arrows are exactly what you would have seen live.

---

## 8. The signal pipeline

Every stage must pass. In order:

1. **Regime gate** — must be `TREND` (or `EXPANSION` if enabled) with `confidence ≥ InpMinRegimeConf`.
2. **Direction** — set by the high timeframe: `Tn_HTF ≥ InpSlopeT` **and** close above its EMA (mirrored for shorts). If neither, direction is flat and no signal is possible.
3. **Mid-timeframe veto** — the MTF must not oppose: drift and EMA position must agree with the HTF direction.
4. **Trigger** on the chart timeframe, all required:
   - a pullback to value occurred within `InpPullbackBars` (price came within `InpPullTolATR × ATR` of the EMA)
   - the bar closes beyond the previous bar's extreme
   - the close is on the correct side of the EMA, and the EMA is not moving against the trade
   - body/range ≥ `InpMinBodyRatio`
   - body/ATR ≥ `InpMinDisplATR`
   - short-term momentum confirms over `InpMomBars`
5. **Confluence** — at least 2 of 3 timeframes agreeing.
6. **Score** — `Score ≥ InpScoreThreshold`.
7. **Spacing** — `InpMinBarsBetween` since the last signal; optionally no open signal.

Only then does an arrow print.

**Expect few signals.** Seven filters in series, four of them at the ~10% noise tail. This is by construction.

---

## 9. Risk model

```
  volAdj = clamp(√F, InpVolAdjMin, InpVolAdjMax)
  risk   = InpATRmultSL × ATR × volAdj
```

Stops widen automatically in volatility expansion and tighten in compression — the regime feeds directly into position risk.

With `InpSLMode = SL_STRUCTURE` (default) the stop is the **wider** of that ATR distance and the swing extreme over `InpSwingLookback` bars plus a 0.25 ATR buffer. Structure beats arithmetic when they disagree.

```
  SL = entry ∓ risk
  TP = entry ± risk × InpRR
```

### The entry-price subtlety

The indicator computes SL/TP from the **close of the signal bar**. The EA fills at market on the **next bar**. SL/TP are absolute price levels so they remain valid, but the realised risk:reward shifts.

The EA handles this two ways:

- `StaleSignalDrift()` rejects the trade if price already ran more than `InpMaxDriftR` (0.35R) past the model entry — the move happened without you, and taking it there ruins the assumed R:R.
- Lot size is always computed from the **real fill distance**, never the theoretical one.

---

## 10. Reading the dashboard

Top-left panel, top to bottom:

| Row | Meaning |
|---|---|
| **Status** | `running`, or why not (e.g. `loading H4 history`). Nothing below is meaningful until this reads `running`. |
| **Regime** | Classification + confidence % |
| **Variance F** | 1.00 = random walk; gold when expanding, blue when compressing |
| **Efficiency ERn** | 1.00 = random walk. 2.4 means "2.4× more directional than a coin flip" |
| **VarRatio VR(q)** | With its z-statistic. Green when `z ≥ 2` |
| **Implied Hurst** | 0.50 = random. >0.55 persistent, <0.45 mean-reverting |
| **Trend strength Tn** | HTF / MTF / LTF, each 1.00 = random walk. Three greens = stacked bullish structure |
| **Signal Strength Score** | Live 0–100 every bar, plus directional bias |
| **Signals / Open** | Count tracked |
| **Wins / Losses / Win%** | Self-tracked outcomes |
| **Expectancy R / PF** | Average R per signal and profit factor |
| **Last** | Most recent signal |

On the chart: blue up-arrow / red down-arrow at the signal bar, plus three projected lines — dotted entry, red SL, green TP.

The score will sit in the 20s–60s most of the time. That is normal.

> **The win/loss panel is a closed-bar path simulation, not a backtest.** No spread, no slippage, no commission, and a bar touching both SL and TP is booked as a **loss** (conservative, since intrabar order is unknown). Treat it as signal quality only.

---

## 11. Buffer contract

Stable. An EA may depend on these. **Do not renumber.**

| # | Name | Contents |
|---|---|---|
| 0 | Buy arrow | price, or `EMPTY_VALUE` |
| 1 | Sell arrow | price, or `EMPTY_VALUE` |
| 2 | Score | 0–100, **every bar** |
| 3 | Regime | 0 = compression, 1 = expansion, 2 = trend |
| 4 | Direction | +1 long candidate, −1 short, 0 none |
| 5 | Stop loss | price on signal bars, else `EMPTY_VALUE` |
| 6 | Take profit | price on signal bars, else `EMPTY_VALUE` |

Buffers 2–6 are `DRAW_NONE` but declared `INDICATOR_DATA`, so `CopyBuffer` can read them.

---

## 12. Input reference — indicator

### 1. Timeframes and scope

| Input | Default | Notes |
|---|---|---|
| `InpAutoLadder` | `true` | Derive mid/high TF from the chart TF |
| `InpTF_Mid` | `H1` | Used only when AutoLadder is off |
| `InpTF_High` | `H4` | Used only when AutoLadder is off |
| `InpMaxBars` | `1500` | History bars to calculate |

**The auto ladder.** The chart timeframe is always the signal timeframe; the other two are derived at a 1 : ~4 : ~16 ratio:

| Chart | Mid | High | | Chart | Mid | High |
|---|---|---|---|---|---|---|
| M1 | M5 | M30 | | M30 | H2 | H8 |
| M5 | M30 | H2 | | H1 | H4 | D1 |
| M15 | H1 | H4 | | H4 | D1 | W1 |
| M20 | H2 | H6 | | D1 | W1 | MN1 |

Mapping only ever goes **upward**, which is the direction that can be made non-repainting. On W1/MN1 nothing higher exists, so the ladder collapses to two effective timeframes — expected, and warned about in the log.

### 2. Statistical regime model

| Input | Default | Notes |
|---|---|---|
| `InpRegimeSrc` | `REG_MID` | Which timeframe the regime is measured on |
| `InpRetLookback` | `100` | `N` for the variance-ratio test — must be ≥ 3q |
| `InpVRq` | `4` | `q`, the aggregation period |
| `InpVolFast` | `20` | `n_fast` variance window |
| `InpVolSlow` | `100` | `n_slow` variance window |
| `InpERPeriod` | `20` | Efficiency-ratio window |
| `InpSlopePeriod` | `30` | OLS regression window (Tn is invariant to this) |

### 3. Regime decision thresholds

All at the ~p90 null tail. See [§4.5](#45-calibration-table).

| Input | Default | Null | Meaning |
|---|---|---|---|
| `InpTrendERn` | `2.05` | 1.00 | Normalised efficiency for trend |
| `InpSlopeT` | `2.10` | 1.00 | Normalised trend strength |
| `InpVRz` | `1.30` | 0.00 | Persistence z |
| `InpExpandF` | `1.40` | 1.00 | Expansion threshold |
| `InpCompressF` | `0.65` | 1.00 | Compression threshold |
| `InpSoftmaxTemp` | `1.00` | — | Lower = sharper classification |
| `InpMinRegimeConf` | `0.55` | — | Minimum confidence to arm signals |
| `InpAllowExpansion` | `false` | — | Also trade the expansion regime |

### 4. Regime discriminant weights

`InpW_T1` 1.00 · `InpW_T2` 0.50 · `InpW_T3` 0.45 · `InpW_E1` 1.20 · `InpW_E2` 0.60 · `InpW_C1` 1.40 · `InpW_C2` 0.35

### 5. Logistic score

| Input | Default | | Input | Default |
|---|---|---|---|---|
| `InpScoreThreshold` | `85.0` | | `InpW5_Persistence` | `0.60` |
| `InpBias` | `−2.60` | | `InpW6_Regime` | `0.90` |
| `InpW1_HTFStruct` | `1.20` | | `InpW7_Location` | `0.60` |
| `InpW2_MTFMom` | `1.00` | | `InpW8_Displacement` | `0.70` |
| `InpW3_LTFMom` | `0.80` | | `InpW9_Volume` | `0.40` |
| `InpW4_Efficiency` | `0.70` | | `InpW10_Alignment` | `1.00` |

### 6. Trigger

| Input | Default | Notes |
|---|---|---|
| `InpEMAPeriod` | `34` | Value line, all timeframes |
| `InpATRPeriod` | `14` | All timeframes |
| `InpPullbackBars` | `8` | Pullback-to-value lookback |
| `InpPullTolATR` | `0.35` | Tolerance around the EMA |
| `InpMinBodyRatio` | `0.50` | Trigger bar body / range |
| `InpMinDisplATR` | `0.35` | Trigger bar body / ATR |
| `InpMomBars` | `3` | Momentum confirmation lookback |
| `InpMinBarsBetween` | `5` | Minimum bars between signals |
| `InpOneAtATime` | `true` | Block a new signal while one is open |
| `InpVolZPeriod` | `30` | Tick-volume z-score window |

### 7. Risk

| Input | Default | Notes |
|---|---|---|
| `InpSLMode` | `SL_STRUCTURE` | Wider of ATR and swing structure |
| `InpATRmultSL` | `1.60` | Base ATR multiple |
| `InpRR` | `2.00` | Reward : risk |
| `InpSwingLookback` | `12` | Swing lookback for structural stop |
| `InpVolAdjMin` / `Max` | `0.70` / `1.60` | Regime volatility adjuster clamp |
| `InpMaxHoldBars` | `60` | Timeout for panel statistics |
| `InpProjectBars` | `22` | SL/TP line projection length |
| `InpMaxSignalDraw` | `40` | Max signals kept drawn |

### 8–9. Dashboard and visuals

Cosmetic. `InpShowPanel`, `InpPanelCorner`, `InpPanelX/Y`, `InpPanelWidth`, `InpPanelRowH`, `InpPanelFont`, `InpPanelFontName`, `InpPanelBG`, `InpPanelText`, `InpBuyColor`, `InpSellColor`, `InpSLColor`, `InpTPColor`, `InpArrowATROffset`, `InpAlertPopup`, `InpAlertPush`.

Alerts fire on the **close of the signal bar**, once per bar.

---

## 13. Input reference — EA

The EA ships as **three thin wrapper files around one shared core** (`QuantRegimeConfluenceEA_Core.mqh`). Every wrapper runs identical logic; only the *defaults* differ. Pick the front door that matches your instrument:

| File | Profile | Min TF | Spread guard | Friday cut | Daily loss | Magic / comment |
|---|---|---|---|---|---|---|
| `QuantRegimeConfluenceEA.mq5` | generic | M15 | 25 pts | off | 3% | `20260825` / `QRC` |
| `QuantRegimeConfluenceEA_Forex.mq5` | forex | M15 | 25 pts | **on, 19:00** | 3% | `20260829` / `QRC-FX` |
| `QuantRegimeConfluenceEA_Crypto.mq5` | crypto | H1 | 60 pts | off | 4% | `20260830` / `QRC-C` |

Nothing is locked — every value is still an overridable input. Group A (27 inputs) mirrors indicator inputs 1–27 and is forwarded via `iCustom`. Beware the positional trap: `input group` headers consume slots, so the call passes **32 arguments (27 values + 5 group placeholders)** to reach `InpScoreThreshold`. The logistic weights `InpBias`, `InpW1…InpW10` (indicator inputs 28+) are left at the indicator's own defaults. Groups B–E are execution only. A full execution-layer guide, including sizing math and R tracking, is in `QRC_EA_Documentation.md`.

### B. Risk and sizing

| Input | Default | Notes |
|---|---|---|
| `InpRiskPercent` | `0.50` | % of balance risked per trade |
| `InpFixedLots` | `0.0` | >0 overrides risk % |
| `InpMaxLots` | `5.0` | Hard cap |
| `InpMaxSpreadPts` | `25.0` (crypto `60.0`) | Max spread to enter (0 = off) |
| `InpMaxDriftR` | `0.35` | Reject if price drifted past the model entry by more than this × risk |
| `InpSlippagePts` | `20` | Max deviation |

Sizing uses `SYMBOL_TRADE_TICK_VALUE` / `SYMBOL_TRADE_TICK_SIZE`, so it is correct for FX, metals, indices and crypto alike — it never assumes 1 point equals 1 unit. Lots are always sized from the **real fill-to-stop distance**, never the indicator's theoretical one, and the broker's volume step / min / max are respected (a trade below the minimum lot is skipped and logged). The order is also pre-checked against margin (`OrderCalcMargin`, rejected if it would need more than 90% of free margin).

### C. Trade management

| Input | Default | Notes |
|---|---|---|
| `InpMaxPositions` | `1` | Simultaneous positions |
| `InpOnePerDirection` | `true` | Block a second position the same way |
| `InpCloseOnOpposite` | `false` | Close on an opposing signal |
| `InpUseBreakEven` | `true` | Move stop to break-even |
| `InpBEatR` | `1.00` | Break-even trigger, in R |
| `InpBEoffsetPts` | `5.0` | Offset to cover costs |
| `InpUseTrailing` | `true` | Trail the stop |
| `InpTrailStartR` | `1.50` | Start trailing, in R |
| `InpTrailDistR` | `1.00` | Trail distance, in R |
| `InpTrailStepR` | `0.10` | Min stop advance before modifying (R, 0 = every tick) |

Break-even is a **one-shot** move (triggered once, never throttled). Trailing only advances the stop after the staged move exceeds `InpTrailStepR × risk`, so a trending position does not flood the broker with per-tick `PositionModify` calls. Neither move ever pushes the stop inside the broker's freeze band.

### D. Guards

| Input | Default | Notes |
|---|---|---|
| `InpUseTimeFilter` | `false` | Restrict hours (server time) |
| `InpStartHour` / `InpEndHour` | `7` / `20` | Wraps midnight correctly |
| `InpNoFridayLate` | `false` (forex `true`) | Cut off late Friday |
| `InpFridayStopHour` | `19` | Friday cut-off |
| `InpMaxDailyLossPct` | `3.0` (crypto `4.0`) | Halt for the day (0 = off) |
| `InpMaxTradesPerDay` | `0` | 0 = unlimited |

### E. Bookkeeping

| Input | Default | Notes |
|---|---|---|
| `InpMagic` | `20260825` (forex `20260829`, crypto `20260830`) | Magic number |
| `InpComment` | `"QRC"` (forex `"QRC-FX"`, crypto `"QRC-C"`) | Order comment |
| `InpVerboseLog` | `true` | Log every decision to the Experts tab |
| `InpSummaryBars` | `12` | Heartbeat: proof-of-life every N closed bars (0 = off) |

With verbose logging on, **every decision including refusals** goes to the Experts tab:

```
QRC-EA | signal ignored: spread 31.0 pts > 25.0
QRC-EA | signal ignored: price already moved 0.52R past the model entry (limit 0.35R)
QRC-EA | BUY  0.34 lots @ 1.08421  SL 1.08102  TP 1.09059 | score 88.3 regime 2
```

The heartbeat line (`QRC-EA | watching | bars N  signals N  entries N  open N | last score …`) prints every `InpSummaryBars` closed bars, so a quiet run is provably alive and you can see how close the score got to the threshold. That log is the primary debugging tool.

---

## 14. Testing protocol

In increasing order of strength.

### T1 — Compile

Expect `Result: 0 errors, 0 warnings`. Remember: UTF-16 log, exit code 1 means success.

### T2 — Pipeline alive

Defaults are strict and may legitimately produce **zero** arrows. Set `InpScoreThreshold = 60` and `InpMinRegimeConf = 0.40`. If arrows now appear, the pipeline works and the defaults were merely selective. If still nothing, check the Experts log for the `QRC ladder:` line and any history warning.

### T3 — Non-repaint proof

**Strategy Tester → Visual mode**, slow speed. The tester feeds bars sequentially, so a repainting indicator visibly adds, moves or removes arrows on already-closed bars. Watch one printed arrow for 50+ bars — it must never move or vanish.

Objective version: run to bar N, screenshot, run to N+200, compare the **same historical bars**. Any difference is a repaint.

### T4 — Statistical self-test

Run `QRC_SelfTest` (drag onto any chart; it reads no market data). It pushes random-walk, drift-only and AR(1)± series through deliberate **copies** of the estimators — so it tests the formulas rather than trivially agreeing with the indicator — and asserts 15 calibration bands.

Expected output:

```
  A random walk (null)     ERn≈1.00  VR≈1.00  z≈ 0.00  F≈1.00  |Tn|≈1.00  H≈0.50
  B drift only             ERn≈2.07  VR≈1.00  z≈ 0.00  F≈1.00
  C AR(1) phi=+0.35        ERn≈1.41  VR≈1.66  z≈ 3.51  F≈1.00  H≈0.68
  D AR(1) phi=-0.35        ERn≈0.74  VR≈0.59  z≈-2.22  F≈1.00  H≈0.30

  VERDICT: PASS - all estimators match their null distributions.
```

**Run this after any change to the math section.** A `FAIL` is a genuine signal, not flakiness — the bands are roughly 10σ wide at 600 trials.

### T5 — Forward realism

Strategy Tester with a real cost model. See below.

---

## 15. Backtesting

### Modelling mode

| Mode | Verdict |
|---|---|
| Every tick based on real ticks | **Best** — use if your broker provides them |
| 1 minute OHLC | Acceptable, much faster |
| Every tick | Acceptable |
| **Open prices only** | **INVALID — will produce nonsense** |

The EA enters on bar open, but exits are SL/TP hits **inside** a bar. Open-prices-only cannot model that.

### Settings that matter

- **Costs:** set a realistic fixed spread (not "current"), and enter your broker's commission. The indicator's on-chart panel models neither, so the tester result will always look worse. **That gap is the cost of trading, not a bug.**
- **Warm-up:** the indicator needs ~117 bars of each higher timeframe *before* the start date. Don't start at the very beginning of your history.
- **Deposit / leverage:** match your live account, or position sizing won't be representative.

### Automated run

`qrc_backtest.ini` is included. MT5 allows one instance per data folder, so **close MetaTrader first**:

```powershell
& "C:\Program Files\Go MetaTrader 5\terminal64.exe" `
    /config:"c:\myfiles\training_folder\QuantRegimeConfluence\qrc_backtest.ini"
```

The terminal runs the test, writes `QRC_Report.html`, and exits (`ShutdownTerminal=1`). Edit `Symbol`, `Period`, `FromDate`, `ToDate` and `Model` in the file.

---

## 16. Optimisation strategy

There are 74 indicator inputs and 54 EA inputs (27 forwarded to the indicator + 27 execution-only). **Never optimise them together.** Work in stages, freezing everything else:

1. **Regime layer** — `InpTrendERn`, `InpSlopeT`, `InpVRz`, `InpExpandF`, `InpCompressF`, `InpRegimeSrc`. Hold the score threshold low so you are measuring regime quality, not gating.
2. **Trigger layer** — `InpEMAPeriod`, `InpPullbackBars`, `InpMinBodyRatio`, `InpMinDisplATR`.
3. **Logistic coefficients** — `InpW1…InpW10` and `InpBias`. This is genuine coefficient fitting. Use walk-forward: 11 free parameters on a single in-sample block will overfit badly.
4. **Risk last** — `InpATRmultSL`, `InpRR`, `InpVolAdjMin/Max`, then the EA's `InpRiskPercent`.

Two cautions:

- The shipped thresholds are calibrated against **synthetic noise**, not your instrument. Real markets have fat tails and volatility clustering. They are a defensible starting point, not a tuned answer.
- Optimising away from the null quantiles means giving up the "this is how surprising versus noise" interpretation. Know when you are doing that.

For serious coefficient fitting, exporting features to CSV and fitting a logistic regression offline is far sounder than a genetic search inside MT5.

---

## 17. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Chart shows only the indicator name, nothing else | Higher-timeframe history not downloaded. The panel now shows `Status: loading H4 history`. Open an H4 chart of the same symbol once. Self-healing. |
| Panel says `chart history too short` | Fewer than ~137 bars on the chart. Scroll back or pick a longer-history symbol. |
| No arrows ever | By design at defaults. Run T2. |
| Panel shows `PERIOD_M15` instead of `M15` | Stale v1.10 or earlier. Recompile v1.11+. |
| EA logs `FATAL: cannot create the indicator handle` | `QuantRegimeConfluence.ex5` missing from `MQL5\Indicators\`. |
| EA never trades but arrows appear | Check the Experts log — every refusal is logged with its reason. |
| `risk X% implies N lots, below broker minimum` | Raise `InpRiskPercent`, or the symbol's minimum lot is too large for your balance. |
| EA trades differ from chart arrows | Indicator/EA input mismatch. The EA forwards its own group-A values, which override chart settings. |
| EA logs `WARNING: the X profile expects M15/H1 or higher` | Chart timeframe is below the profile's minimum. Signals may still be valid if the spread is small against the indicator's stops, but check it — see §13. |
| EA logs nothing at all, ever | Check `InpVerboseLog` and `InpSummaryBars`. With the heartbeat on, a live EA prints `watching | …` every N bars; total silence means it is not attached, not that it is idle. |
| Self-test `VERDICT: FAIL` | An estimator has drifted from its null. Real regression — do not ignore. |

---

## 18. Known limitations

**Honest accounting of what this does not do.**

1. **Not validated as profitable.** Calibrated against synthetic noise. No live or out-of-sample edge has been demonstrated.
2. **The on-chart panel is not a backtest.** No spread, slippage or commission; ambiguous bars count as losses.
3. **Synthetic calibration.** Random walks lack fat tails, volatility clustering and session structure. Real-market nulls differ.
4. **The slope statistic is a ranking device, not a hypothesis test.** `Tn` is normalised against the measured spurious-regression null, which makes it comparable and lookback-invariant — but it still is not a p-value.
5. **R tracking does not survive EA restarts.** Positions open across a restart have their R reconstructed from the current stop; if it had already moved to break-even the reconstruction is wrong, so those positions are only trailed, never re-break-evened.
6. **`iCustom` parameters are positional.** The EA forwards 27 values plus 5 `input group` placeholders (32 arguments) to reach `InpScoreThreshold`. Reordering, inserting or deleting an input — or an `input group` header — in the indicator above `InpScoreThreshold` silently feeds the wrong values into the wrong parameters. It still compiles and still runs. No compiler check exists. The indicator prints its resolved config at `OnInit` for exactly this reason.
7. **Two files must be kept in sync.** The EA mirrors 27 indicator inputs by hand.
8. **Tick-volume, not real volume.** Feature 9 uses `tick_volume`, a proxy. On FX that is all MT5 provides.
9. **Single-symbol.** No correlation awareness, no portfolio-level risk.

---

## 19. Maintenance checklist

If you change **X**, you must also update **Y**:

| Change | Also update |
|---|---|
| A threshold default | Re-derive from the null quantile table — do not pick a round number |
| `CalcSlopeT` normalisation | `InpSlopeT` default **and** the f1 centring term in `SignalScore()` |
| Any lookback input | `MaxLookback()` — it drives warm-up and the HTF history requirement |
| Buffer order | The buffer contract in §11 **and** the EA |
| A new per-bar side effect | Place it **after** the `g_lastBarTime` guard (Invariant 3) |
| Feature count in `SignalScore` | `InpBias` — otherwise the score distribution shifts and `InpScoreThreshold` silently changes meaning |
| Indicator input order (positions 1–27, including the 5 `input group` headers inside that range) | The `iCustom` call in `QuantRegimeConfluenceEA_Core.mqh`'s `OnInit` — 32 arguments, group placeholders included |
| Anything in the math section | Re-run `QRC_SelfTest` |

---

## 20. Version history

### Indicator 1.11
- Clean timeframe names (`M15`, not `PERIOD_M15`) throughout the UI.
- **Fixed:** all five early-exit paths in `OnCalculate` bypassed `UpdatePanel()`, so the indicator rendered *nothing at all* while waiting for higher-timeframe history — indistinguishable from a broken indicator. The panel now always draws with a status line.
- Panel drawn from `OnInit` so it is never blank on attach.

### Indicator 1.10
- **Fixed a real defect:** `InpSlopeT = 2.00` fired on **75.7% of pure random walks** — it was not a filter. `CalcSlopeT` now returns `Tn`, normalised against the measured null, and is lookback-invariant.
- All four thresholds re-derived from measured p90 null quantiles.
- Added the auto timeframe ladder — the system now genuinely works on any chart timeframe.
- ~190 lines of maintainer documentation added to the source header.
- Added `QRC_SelfTest.mq5`.

### Indicator 1.00
- Initial release.

### EA 1.10
- **Profiles.** One strategy, three front doors around a single shared core (`QuantRegimeConfluenceEA_Core.mqh`): `QuantRegimeConfluenceEA.mq5` (generic, original defaults), `_Forex` (M15+, Friday cut-off at 19:00, magic `20260829`, comment `QRC-FX`), `_Crypto` (H1+, 60-pt spread guard, no Friday cut, 4% daily-loss cap, magic `20260830`, comment `QRC-C`). Fix a bug in the core once and all three builds get it.
- **New:** heartbeat watchdog (`InpSummaryBars`) — a quiet run now provably logs `watching | …` every N bars instead of being indistinguishable from a dead EA.
- **New:** trailing throttle (`InpTrailStepR`) — stops advance only after a minimum move, ending the per-tick `PositionModify` flood on trending positions.
- **New:** margin pre-check (`OrderCalcMargin`, 90% free-margin cap) and broker minimum-stop-distance widening.
- **New:** netting-account warning and a per-profile minimum-timeframe warning at startup.
- Positions open across an EA restart are adopted and their R reconstructed (logged); reconstructed positions are trailed but never re-break-even'd.

### EA 1.00
- Initial release.
- **Fixed before shipping:** `ReadSignal` conflated "no signal on this bar" with "indicator not ready", and both consumed the bar — a signal on the first bar after attach was lost permanently. Now tri-state.

---

## Appendix — file map

| File | Location | Purpose |
|---|---|---|
| `QuantRegimeConfluence.mq5` | `MQL5\Indicators\` | The model |
| `QuantRegimeConfluenceEA.mq5` | `MQL5\Experts\` | Execution — generic profile |
| `QuantRegimeConfluenceEA_Forex.mq5` | `MQL5\Experts\` | Execution — forex profile |
| `QuantRegimeConfluenceEA_Crypto.mq5` | `MQL5\Experts\` | Execution — crypto profile |
| `QuantRegimeConfluenceEA_Core.mqh` | `MQL5\Experts\` | Execution — shared logic (included by all three wrappers) |
| `QRC_SelfTest.mq5` | `MQL5\Scripts\` | Estimator validation |
| `qrc_backtest.ini` | anywhere | Headless tester config |
| `QRC_Documentation.md` | anywhere | This document |
| `QRC_EA_Documentation.md` | anywhere | EA execution-layer guide |

Both source files carry extensive header documentation aimed at future maintainers, including the invariants, the calibration table and the traps. **Read those headers before modifying either file.**
