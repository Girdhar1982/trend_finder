# Backtesting Guide — Step by Step

**Covers all three strategies: ABBM, QRC and HullTrend. Two ways to run: the Strategy Tester GUI,
and headless via a `.ini` file. Both are explained below.**

---

## 1. Prerequisites (do once per terminal)

### 1.1 Install the files

| Strategy | Files → destination |
|---|---|
| **ABBM** | from `AdvancedBBMomentumEA\`: `AdvancedBBMomentumEA.mq5`, `AdvancedBBMomentumEA_Forex.mq5`, `AdvancedBBMomentumEA_Crypto.mq5`, `AdvancedBBMomentumEA_Core.mqh` and the whole `ABBM/` folder → `MQL5\Experts\` (keep `ABBM/` as a subfolder beside the `.mq5` files) |
| **QRC** | from `QuantRegimeConfluence\`: `QuantRegimeConfluence.mq5` → `MQL5\Indicators\`; `QuantRegimeConfluenceEA.mq5`, `QuantRegimeConfluenceEA_Forex.mq5`, `QuantRegimeConfluenceEA_Crypto.mq5`, `QuantRegimeConfluenceEA_Core.mqh` → `MQL5\Experts\`; `QRC_SelfTest.mq5` → `MQL5\Scripts\` |
| **HullTrend** | from `HullTrend\`: `HullTrend_MT5.mq5` → `MQL5\Indicators\`; `HullTrendEA.mq5`, `HullTrendEA_Forex.mq5`, `HullTrendEA_Crypto.mq5`, `HullTrendEA_Core.mqh` → `MQL5\Experts\` |

Find your terminal's data folder in MT5: **File → Open Data Folder**. Compile each `.mq5` with **F7**
in MetaEditor, then **right-click Navigator → Refresh**.

> **QRC and HullTrend only:** these two load their indicator by name via `iCustom`, so the
> indicator's `.ex5` must be compiled into `MQL5\Indicators\` or the EA logs
> `FATAL: cannot create the indicator handle` and never trades.
>
> **ABBM does not use `iCustom`.** It builds every indicator internally (`iMA`, `iBands`, `iRSI`,
> `iADX`, `iATR`) in `OnInit`, so it has no indicator dependency — but it does need the whole
> `ABBM\` module folder beside the `.mq5`, because those modules are compiled in, not loaded.

### 1.2 Check the data exists

Open a chart of the symbol you will test and scroll back. Both QRC and ABBM need history **before**
the test start date:

- **ABBM**: H4 EMA200 needs ~250 H4 bars before `FromDate`. Forex prints ~30 H4 bars a week, so that
  is **≈ 8 weeks, not 6** — start the test at least **3 months after your downloaded history begins**
  to leave margin. Crypto quotes 7 days a week (~42 bars/week), where ~6 weeks is enough.
- **QRC**: needs ~117 bars of each higher timeframe (H1 and H4 on M15 charts). Opening an H4 chart of
  the symbol once forces the download.
- **HullTrend**: ~25 bars for the Hull itself, plus the higher-timeframe Hull's history.

### 1.3 Set the costs

The tester takes costs from the **symbol specification supplied by the server**, which for a
broker-provided symbol you cannot edit. Two consequences to know before reading any result:

- **Commission is usually not modelled.** If your broker books it separately rather than in the spec,
  the tester will not charge it. To impose your own, clone the instrument via
  **Symbols → right-click → Create Custom Symbol**, edit the copy's specification, and test that.
  *(This route was not verified in this session — the runs in §7 are spread-only.)*
- **`.ini` has no spread field.** Headless runs use the symbol's own spread. To force a wide-spread
  scenario you need the GUI, or an EA-side cap such as ABBM's `InpMaxSpreadPts` / `InpMaxSpreadATR` —
  but that tests *your filter*, not the cost of trading.

These strategies trade selectively — a handful of trades carries the whole result, so costs are not a
rounding error. **A spread-only run is an upper bound, not a result.**

---

## 2. Method A — Strategy Tester GUI

This is the interactive way: you see the chart, the trades, and the report.

1. **Open the tester.** In MT5 press **Ctrl+R** or **View → Strategy Tester**. A panel opens below
   the chart.
2. **Expert.** Drop-down → select the wrapper you want:
   - ABBM: `AdvancedBBMomentumEA` (forex: `_Forex`, crypto: `_Crypto`)
   - QRC: `QuantRegimeConfluenceEA` (or `_Forex` / `_Crypto`)
   - HullTrend: `HullTrendEA` (or `_Forex` / `_Crypto`)
3. **Symbol & Period.** Pick the symbol and the **execution timeframe** — must match the EA's
   `InpExecTF` (ABBM M15 default) or profile minimum:
   - ABBM: M15 or M5
   - QRC: M15+ (crypto profile: H1+)
   - HullTrend: M5 floor for FX, H1 for crypto
4. **Modelling.** Select:
   - **"1 minute OHLC"** (Model 1) — fast, acceptable
   - **"Every tick based on real ticks"** (Model 4) — most accurate
   - **NEVER "Open prices only"** (Model 2) — invalid. Entries happen at bar open, but exits are
     SL/TP hits **inside** a bar; open-prices-only cannot model that and produces nonsense.
5. **Dates.** From / To. Keep the warm-up rule from §1.2.
6. **Deposit, currency, leverage.** Match your live account so position sizing is representative.
7. **Inputs tab.** Check the values the EA will actually run with (see §4 for what matters per
   strategy). Note the **`.set` trap** in §5.2 — the tester silently reuses a previously saved input
   set.
8. **Run.** Press **Start**. Watch the **Journal** and **Experts** tabs while it runs.
9. **Read the report.** When done, the **Backtest** tab shows the report; **Chart** shows trades;
   **Graph** shows equity.

> **The single most common cause of "no trades" is insufficient warm-up.** Before concluding a
> strategy is broken, read the Journal/Experts for the EA's own explanation:
> - ABBM: `NO_DATA` lines, or rejections like `H4_NEUTRAL`, `SPREAD`, `REGIME`
> - QRC: `QRC-EA | signal ignored: …` lines
> - HullTrend: the `SUM` line's `vetoes:` histogram

---

## 3. Method B — Headless via `.ini`

Faster for repeat runs and reproducible config. `.ini` files already exist for ABBM and QRC
(`abbm_backtest.ini`, `qrc_backtest.ini`); HullTrend has no `.ini` — use the template in §3.3.

### 3.1 The run procedure

1. **Close MetaTrader 5 completely, and confirm it.** MT5 allows one instance per data folder, so
   the run needs the terminal free. Confirm rather than assume — if one is still up, your run exits
   in under a second having done nothing (§5.5):
   ```powershell
   Get-Process terminal64 -ErrorAction SilentlyContinue   # must return nothing
   ```
2. **Edit the `.ini`** if needed (see §3.2 for the fields).
3. **Run it** in PowerShell:
   ```powershell
   & "C:\Program Files\Go MetaTrader 5\terminal64.exe" /config:"c:\myfiles\training_folder\AdvancedBBMomentumEA\abbm_backtest.ini"
   ```
4. The terminal opens, runs the test, and exits on its own (`ShutdownTerminal=1`).
5. **Read the result from the log, not the report.** On build 6140, `Report=` with an **absolute**
   path produced **no file at all**, silently. Do not depend on it. The authoritative record is
   `%APPDATA%\MetaQuotes\Terminal\<id>\Tester\logs\<date>.log`, which is **UTF-16** — read it with
   `Get-Content -Encoding Unicode` or it looks empty and garbled.

   That log is **appended to for the whole day, across every run**. To read one run you must split
   it: each ABBM run opens with its config banner, so split on `ADVANCED BB MOMENTUM EA` and take
   the block you want. Reading it end to end and assuming one run is a good way to draw a conclusion
   from somebody else's test.
6. **Sanity-check the elapsed time.** A 2.5-year EURUSD M15 run at Model 1 takes **≈ 9 seconds** on
   this machine. A run that returns in **under a second did not run** — see §5.5.

### 3.2 The `[Tester]` fields you will touch

| Field | Meaning | Typical value |
|---|---|---|
| `Expert=` | EA name, **already relative to `MQL5\Experts`** | `AdvancedBBMomentumEA`. Writing `Experts\AdvancedBBMomentumEA` fails with `tester didn't start` / `Experts\Experts\….ex5 not found` |
| `Symbol=` | Instrument | `EURUSD`, `XAUUSD`, `BTCUSD`… |
| `Period=` | Execution timeframe | `M15` (see profile minimums in §2 step 3) |
| `Model=` | 0 every tick, 1 1-minute OHLC, 2 open prices only (**invalid**), 3 math, 4 every tick real | `1` fast, `4` accurate |
| `FromDate=` / `ToDate=` | Window | Respect warm-up §1.2 |
| `Deposit=` / `Currency=` / `Leverage=` | Account | Match live |
| `Report=` | Report file name/path | `ABBM_Report`, `c:\…\reports\run1` |
| `ReplaceReport=1` | Overwrite an existing report | `1` |
| `ShutdownTerminal=1` | Auto-close after the run | `1` |
| `ExpertParameters=` | Optional `.set` file overriding EA inputs (see §3.4) | `abbm_defaults.set` |

### 3.3 HullTrend `.ini` template

Save this as `hull_backtest.ini` in `c:\myfiles\training_folder\`:

```ini
[Tester]
Expert=HullTrendEA
Symbol=EURUSD
Period=M15
Model=1
Optimization=0
ForwardMode=0
FromDate=2024.01.01
ToDate=2026.06.30
Deposit=10000
Currency=USD
Leverage=1:100
ExecutionMode=0
Visual=0
Report=Hull_Report
ReplaceReport=1
ShutdownTerminal=1
```

### 3.4 Overriding inputs with a `.set` file

To run with different EA inputs without touching defaults, save them in a `.set` file and point at it:

```ini
ExpertParameters=my_run.set
```

**The file must live in `<data folder>\MQL5\Profiles\Tester\`.** `ExpertParameters=` takes a bare
filename resolved against that folder — a path anywhere else is silently ignored and the run proceeds
with whatever inputs it would otherwise have used, which looks exactly like your overrides having no
effect.

Hand-written format is one `InputName=value` per line (see `tests\abbm_m5.set`):

```
InpExecTF=5
InpConfirmTF=15
InpEnableDebugLogs=true
```

Two things about that format:

- **A partial `.set` is fine.** Inputs you list are overridden; inputs you omit fall back to the EA's
  compiled defaults. You do not have to enumerate all 96 of ABBM's inputs to change one.
- **GUI-saved `.set` files look different.** They carry the optimiser columns —
  `InpMaxSpreadATR=0.15||0.15||0.015000||1.500000||N` — where the trailing fields are
  start / step / stop / optimise-flag. Both forms load; only the first value matters for a single run.

Saving a `.set` from the GUI: run once, then in the tester **Inputs** tab right-click → **Save**.

---

## 4. Settings that matter, per strategy

### ABBM (`AdvancedBBMomentumEA`)

| Setting | Value | Why |
|---|---|---|
| Modelling | 1 or 4 | Exits are SL/TP hits inside a bar; model 2 is invalid |
| Period | M15 (or M5) | Must match `InpExecTF` |
| Spread | realistic **fixed**, not "current" | Trades selectively; a handful of trades carries the result |
| Commission | your broker's actual figure | Same reason |
| From date | ≥ 3 months after history begins | H4 EMA200 warm-up |

**Interpreting the run.** Rejections are one line each in the Experts tab:
`ABBM REJECTED  reason=H4_NEUTRAL  score=58.2 need>=70 or <=30`. The first gate to fail names the
cause. Read the `guards:` and `score:` lines of the startup config dump before trusting any result.

**Optimising.** Do not optimise everything at once. Fix all weights at documented defaults; optimise
`InpMinSignalScore`, the H4 thresholds and the risk block — and never all three together.

### QRC (`QuantRegimeConfluenceEA`)

| Setting | Value | Why |
|---|---|---|
| Modelling | 1 or 4 | Same intrabar-exit reasoning |
| Period | M15+ | Profile minimums; crypto profile expects H1+ |
| Warm-up | ~117 bars of H1 and H4 before `FromDate` | Indicator requires it |
| Deposit / leverage | match live | Sizing must be representative |

**Interpreting the run.** With `InpVerboseLog` on, every refusal is logged with its reason:
`QRC-EA | signal ignored: spread 31.0 pts > 25.0`. The heartbeat line
(`QRC-EA | watching | bars N …`) proves the run is alive during quiet stretches.

**Optimising.** Never optimise the 74 indicator + 54 EA inputs together. Work in stages, freezing
everything else: regime layer → trigger layer → logistic coefficients (`InpW1…W10`, `InpBias`, use
walk-forward) → risk last. Read the `QRC ladder:` line at startup to confirm the timeframe mapping.

### HullTrend (`HullTrendEA`)

| Setting | Value | Why |
|---|---|---|
| Modelling | 1 or 4 | Intrabar SL/TP exits |
| Period | **M5 is the floor** for FX | A flip system pays the spread on every reversal; M1 retail FX cannot clear its costs |
| Spread / commission | realistic, and check the `SUM` line | If `spread avg x ATR` is not well under **0.25**, the strategy is paying its edge to the spread |
| Warm-up | ~25 bars + HTF history | Hull needs `n + √n` bars |

**Interpreting the run.** The `SUM` line is the "is it working" answer:
`SUM | running | vetoes: htf-disagrees=142  spread=8  same-dir=5`. The veto histogram names the
rejecting filter.

**Optimising.** Optimise the whipsaw inputs (`InpSlopeATRMul`, `InpConfirmBars`), the HTF multiple
and the stop mode **separately** — never together.

---

## 5. Pitfalls that waste the most time

### 5.1 "No trades" = warm-up, not a broken strategy

- ABBM: look for `NO_DATA  exec bars=… need=300` in the journal.
- QRC: the panel shows `Status: loading H4 history`; open an H4 chart of the symbol once.
- HullTrend: read the `SUM` veto histogram.

### 5.2 The stale `.set` trap (ABBM especially)

MT5 auto-saves the tester's input set per expert to
`MQL5\Profiles\Tester\<ExpertName>.set` and **silently reuses it** on later runs that don't specify
`ExpertParameters`. A recompile with new defaults does *not* take effect — the stale `.set` wins.
Delete it between runs when you have changed a default:

```
del "%APPDATA%\MetaQuotes\Terminal\<id>\MQL5\Profiles\Tester\AdvancedBBMomentumEA.set"
```

The EA's startup configuration dump exists precisely to catch this — **read it before trusting a result.**

### 5.3 Model 2 (Open prices only)

Invalid for all three EAs. Entries are at bar open, exits are SL/TP hits **inside** a bar. Model 2
produces nonsense.

### 5.4 Costs are not a rounding error here

These are selective/cost-sensitive systems. A run with no spread and no commission is optimistic —
treat it as an upper bound, not a result.

### 5.5 "It finished instantly" — the run never happened

MT5 allows one instance per data folder. If a terminal is **already open**, `/config:` hands the
request to the running instance and the process you launched **exits immediately with no test and no
error**. It looks like a successful run that produced nothing.

Tells, in order of reliability:

| Symptom | Meaning |
|---|---|
| Elapsed under 1 s (vs ~9 s) | Terminal already open; nothing ran |
| Log shows `tester didn't start` | Bad `Expert=` path — see §3.2 |
| Log shows `…ex5 not found` | EA not compiled into `MQL5\Experts`, or the name is wrong |
| Test "successfully finished" but 0 bars | Date window has no history |
| Runs, but inputs are not yours | Stale `.set` — §5.2 — or the `.set` is in the wrong folder — §3.4 |

Always check `Get-Process terminal64` before a headless run.

### 5.6 Verifying a run is honest

- **Determinism**: rerun the exact same config and confirm identical output (same trades, same final
  balance). ABBM's verification did exactly this — see `tests\t1_eurusd_m15.ini` / `t2_…_rerun.ini`.
- **Non-repaint**: run in Visual mode, slow speed, and watch printed arrows for 50+ bars — they must
  never move or vanish. Or: run to bar N, screenshot, run to N+200, compare the same historical bars.
- **Expected-trade count**: with defaults these systems trade rarely. A handful of trades over two
  years is normal for ABBM/QRC — **a small sample supports no profitability conclusion.**

---

## 6. Results on record — ABBM, August 2026

Full method and per-item verification: `ABBM_Documentation.md` §8. Summarised here so the guide has
a reference point for what "normal" looks like.

**Conditions.** GoMarkets-Demo, build 6140, Model 1 (1-minute OHLC), 10,000 USD, 1:100, hedging,
**spread only — no commission modelled**. EURUSD/USDJPY 2024.01.01–2026.08.01; XRPUSD from
2025.06.01 (2024 history absent).

| Run | Spread cap | Bars | Signals | Filled | Errors | Dupes | Balance | Net |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| EURUSD M15 baseline | 0.30 ATR | 64,148 | 5 | 5 | 0 | 0 | 10,214.64 | **+2.15%** |
| EURUSD M15 identical rerun | 0.30 ATR | 64,148 | 5 | 5 | 0 | 0 | 10,214.64 | +2.15% |
| EURUSD **M5** | 0.30 ATR | 192,425 | 0 | 0 | 0 | 0 | 10,000.00 | 0.00% |
| USDJPY M15 | 0.30 ATR | 64,147 | 2 | 2 | 0 | 0 | 9,813.06 | **−1.87%** |
| XRPUSD M15 (crypto) | 0.35 ATR | 40,652 | 0 | 0 | 0 | 0 | 10,000.00 | 0.00% |
| Spread gate forced | 0.1 pt | 6,044 | 0 | 0 | 0 | 0 | 10,000.00 | 0.00% |
| Daily loss forced 0.4% | 0.30 ATR | 64,147 | 2 | 2 | 0 | 0 | 9,691.66 | −3.08% |

The baseline and its rerun are identical in every rejection bucket down to the unit — that is the
no-look-ahead evidence, and it is the check worth repeating on any change you make.

### What the rejections were doing

| Run | Dominant gates |
|---|---|
| EURUSD M15 | H4_NEUTRAL 32% · REGIME 28% · NO_SETUP 20% · SPREAD 16% |
| EURUSD M5 | **SPREAD 51%** · H4_NEUTRAL 18% · REGIME 13% |
| USDJPY M15 | REGIME 33% · H4_NEUTRAL 29% · NO_SETUP 27% · SPREAD 6% |
| XRPUSD M15 | **SPREAD 57%** · H4_NEUTRAL 15% · NO_SETUP 14% |

**M5 and XRPUSD take no trades because spread eats them**, not because the logic is broken. On this
broker, spread relative to M15 ATR is already ~15–23%; on M5 the ATR halves while spread does not.
If you want M5, you need a tighter-spread account — no parameter fixes that.

### Read this before quoting the +2.15%

Trade by trade, the EURUSD run went:

| # | Direction | Outcome |
|---|---|---|
| 1 | SELL 1.33 | break-even scratch (+5 pts) |
| 2 | SELL 0.82 | **trailed out — the only real winner** |
| 3 | SELL 0.58 | break-even scratch |
| 4 | BUY 0.67 | break-even scratch |
| 5 | SELL 0.66 | break-even scratch |

**Four of five trades reached 1R, were moved to break-even, retraced, and scratched. Not one reached
its 2R target.** The entire +2.15% is one trade. `InpBreakEvenAtR = 1.0` against a 2R target is
converting most winners into zeros — that is the first parameter to examine, and
`tests\t9_be_off.ini` / `tests\t10_be_15.ini` are ready to measure it.

Seven trades across two symbols is **not a sample**. These runs establish that the machinery does
what the specification says. They establish nothing about edge, and the absence of commission makes
even the sign optimistic.

### Parameter search — 15 configurations, EURUSD M15, 2015–2026

The 2024–2026 window above gave 5 trades and +2.15%. Extending to the **full 11 years of available
history** (287,685 bars) reverses that conclusion, and a 15-configuration search found **no
profitable setting**.

**Break-even sweep** (defaults otherwise):

| Config | Trades | Win | Loss | Net | PF |
|---|---:|---:|---:|---:|---:|
| BE 1.0R (default) | 10 | 5 | 5 | −2.83% | 0.42 |
| BE off | 10 | 1 | 9 | −6.79% | 0.22 |
| BE 1.5R | 10 | 1 | 9 | −6.79% | 0.22 |
| BE 2.0R | 10 | 1 | 9 | −6.79% | 0.22 |
| BE 1.0R + ranging | 11 | 5 | 6 | −3.80% | 0.35 |

BE 1.5R and 2.0R are byte-identical to BE-off — **no trade ever reached 1.5R**, so those triggers
never fire.

**Selectivity sweep** (loosening filters to build a real sample):

| Config | Trades | Net | PF |
|---|---:|---:|---:|
| score ≥ 70 (default) | 10 | −2.83% | 0.42 |
| score ≥ 60 | 39 | −14.18% | 0.34 |
| score ≥ 50 | 97 | −20.86% | 0.56 |
| score ≥ 50, bias 62/38 | 105 | −19.72% | 0.60 |
| + ranging enabled | 143 | −27.98% | 0.61 |
| score ≥ 40, bias 58/42, no caps | 249 | −40.22% | 0.65 |

**Exit-logic isolation** (score ≥ 50, bias 62/38, ranging on):

| Config | Trades | Win% | Avg win | Avg loss | Net | PF | Expectancy |
|---|---:|---:|---:|---:|---:|---:|---:|
| Pure SL/TP, no BE, no trail | 142 | 26.1% | $166.70 | $84.70 | −27.27% | 0.69 | −$19.20 |
| Both setups FIXED_RR 2R | 151 | 26.5% | $163.90 | $83.80 | −27.58% | 0.70 | −$18.20 |
| 3R target | 150 | 18.7% | $223.30 | $78.00 | −32.88% | 0.66 | −$21.75 |
| Trail only from 1R | 142 | 28.2% | $131.60 | $78.10 | −26.97% | 0.66 | −$19.03 |

### What the search establishes

**1 — The exits work. The entries have no edge.** Pure SL/TP realises avg win ÷ avg loss = **1.97**,
almost exactly the 2R target. The mechanics do what they claim. But at 2R the break-even win rate is
**33.3%**, and the observed rate is **26.1%** over 142 trades. That gap is roughly two standard
errors — strong evidence of negative expectancy, though one symbol alone is not proof.

**2 — Profit factor *rises* as filters loosen: 0.42 → 0.65.** This is the important number. A real
edge shows the opposite — the most selective settings should have the *highest* PF. Here the signals
the model rates highest perform *worst*, which means the 100-point rubric is **anti-predictive**:
it is ranking noise, and tightening it only shrinks the sample without improving quality.

**3 — PF sits in a narrow 0.62–0.70 band across every configuration and sample size from 13 to 249
trades.** That stability is the signature of a system with no edge paying its transaction costs, not
of a system that needs tuning.

**4 — The +2.15% on 2024–2026 was an artefact of the window.** Over 11 years the same settings return
−2.83%. Never size a conclusion to a window you chose after seeing the result.

### The honest conclusion

**There is no optimal configuration in this parameter space.** The least-bad setting is the shipped
default — and only because it trades 10 times in 11 years. Losing least by trading least is not an
edge, it is abstention.

Do not run this live. What it would take to change the verdict:

- **Fix the entry, not the parameters.** No exit rule rescues a 26% win rate at 2R.
- **Validate the rubric component by component.** Score each of the six inputs against forward
  returns individually; at least one is likely inverted, given PF improves when you ignore them.
- **Test other instruments and timeframes** before discarding the architecture — this is one symbol
  on one broker. The machinery is sound and instrument-agnostic; the signal model is what failed.

One observation, offered with caution: inverting a 26%-win/2R system implies 74% wins at 1R, which is
nominally positive. **Do not act on that.** It ignores intrabar path (both levels can be touched in
one bar), it doubles spread exposure per unit of reward, and inverting a losing system is a
well-known way to discover that costs were the edge all along. If tested, it must be tested as a
hypothesis with its own out-of-sample window, not adopted.

---

## 7. Quick reference — files in this folder

| File | Purpose |
|---|---|
| `abbm_backtest.ini` | Headless tester config for ABBM |
| `qrc_backtest.ini` | Headless tester config for QRC |
| `hull_backtest.ini` | (template in §3.3 — create it when needed) |
| `tests\*.ini`, `tests\*.set` | Verification runs behind §6; `t9`/`t10` measure break-even sensitivity |
| `reports\` | Where `Report=` files land |
| `*_Documentation.md` | Full per-strategy docs, each with a "Backtesting" section |
