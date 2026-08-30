# HTF_Zone_Grid_3Level_EA — Documentation

**Version 1.02** · MetaTrader 5 · signal timeframe M5 · compiled clean, 0 errors 0 warnings
· backtested on XAUUSD (§8) and XRPUSD ([docs/XRPUSD_FINDINGS.md](docs/XRPUSD_FINDINGS.md))

A high-selectivity, hard-capped scale-in EA. It waits for a six-factor confluence to score
80/100, then places at most **three fixed-lot levels inside the zone that produced the signal**,
all sharing **one** stop loss.

---

## 1. What this is not

It is not a martingale and must never become one.

| Banned | Why it is banned |
|---|---|
| Lot multipliers (1.5×, 2×) | Turns a bounded loss into an unbounded one |
| A level outside the confluence zone | Scale-in is only justified where the model said "value" |
| A fourth level | Three fixed lots is the entire risk budget |
| Any grid below score 80 | The gate is what makes scaling in defensible at all |
| A recovery trade after a loss | Cooldown exists precisely to prevent this |

These are not tuning parameters. They are the reason total risk is knowable in advance.
An EA that relaxes them is a different and much worse strategy wearing this one's filename.

**The thesis in one paragraph.** Scaling in is defensible only when the scale-in prices were
decided *before* entry and all sit inside a level you would have bought anyway. Levels 2 and 3
are not a response to being wrong — they are a plan for a better average inside a zone the model
already validated. The instant price leaves that zone the ladder stops, and one shared stop caps
the whole idea.

---

## 2. Architecture

```
HTF_Zone_Grid_3Level_EA.mq5   579 lines   orchestrator: inputs, lifecycle, gate, state machine
├── HTFZG_Types.mqh           202 lines   shared structs/enums — no logic
├── HTFZG_Analysis.mqh        518 lines   THE MODEL      steps 2–8    read-only
├── HTFZG_Grid.mqh            609 lines   EXECUTION      steps 9–12   geometry, sizing, mgmt
└── HTFZG_Panel.mqh           243 lines   presentation — decides nothing

HTFZG_SelfTest.mq5            318 lines   offline geometry checks, no market data
backtest/htfzg_backtest.ini                headless tester config
docs/DEVELOPMENT_PLAN.md                   build phases and design decisions
```

`Types` is included by all three modules; **none of the three includes another**, so the include
graph is acyclic by construction rather than by discipline.

The split exists to make one question answerable: *did the model score this wrong, or did the grid
build it wrong?* `HTFZG_Analysis.mqh` places no orders and draws nothing, so it returns the same
answer for the same bars every time. `HTFZG_Grid.mqh` is pure geometry given a signal, which is why
`HTFZG_SelfTest.mq5` can check it on paper cases with no market data at all.

---

## 3. How a trade happens

### Step 1 — Safety gate
Spread ≤ `InpMaxSpreadPoints`, inside the session window, not locked out by the daily loss cap,
cooldown elapsed, grids-today under the cap, trading permitted, **and no grid already live**.

That last check asks the *terminal* (`HTFZG_GridExists`), never the internal struct — a stop-out,
a take-profit or a manual close leaves the struct stale with no event guaranteed to have run.

### Step 2 — HTF direction (H4) · mandatory · 20 pts
- **BUY**: close > EMA(200) **and** higher-high + higher-low
- **SELL**: close < EMA(200) **and** lower-high + lower-low
- Anything else is neutral and ends the scan.

Both conditions are required deliberately. The EMA alone flips late and often in a range; the swing
pattern alone has no notion of where value is. They disagree exactly during the chop this strategy
must not trade.

### Step 3 — Confluence zone (H1) · mandatory · 20 pts
The nearest cluster of ≥ `InpZoneMinTouches` swing points within `InpZoneClusterATR` × ATR(H1) of
each other, on the correct side of price. The zone is the cluster **envelope**, not a line — the
ladder needs width to stand in. A hairline cluster is padded to `InpZoneMinHeightATR` × ATR.

### Step 4 — Daily pivot confluence · **bonus** · 15 pts
Classic floor pivots from yesterday's H/L/C. Scores if S1 (buy) or R1 (sell) sits within
`InpPivotNearATR` × ATR(H1) of the zone, measured to the nearest edge.

### Step 5 — Sweep + reclaim (M15) · mandatory · 20 pts
- **BUY**: a low pierces `zLow − 0.30 × ATR`, then price closes back above `zLow` within 3 bars
- **SELL**: mirrored above `zHigh`

Writes **`sweepExtreme`** — the furthest wick across the whole episode, from the sweeping bar
through the reclaiming bar. The furthest extreme wins because the stop must sit beyond *all* the
liquidity that was taken, not just the last bar of it. This number anchors the entire risk model.

### Step 6 — Structure break (M5) · mandatory · 15 pts
The last closed bar closes beyond the most recent M5 swing that formed **at or after the reclaim**.
Writes **`bosPrice`**, which becomes Level 1.

Two clauses do real work. *After the reclaim* — breaking a high that formed before the sweep is the
market retracing, not confirming. And the break must be **fresh**: bar 2 has to still be on the
wrong side, so one break fires exactly one signal instead of re-firing every bar it stays broken.

### Step 7 — Volume confirmation (M5) · **bonus** · 10 pts
Break-bar tick volume > MA(20) × 1.5, where the MA is taken over bars *before* the break so the
spike cannot inflate its own baseline. Tick volume, not real volume — real volume is empty or
broker-specific on most retail feeds and the test would silently never fire.

### Step 8 — Score
`Trend 20 + Zone 20 + Pivot 15 + Sweep 20 + BOS 15 + Vol 10 = 100`. Below `InpMinScore`, stop.

### Step 9 — Grid geometry
```
sharedSL = sweepExtreme ∓ InpSharedSL_ATR_Buffer × ATR(15M)
1R       = |Level1 − sharedSL|
Level1   = bosPrice
Level2   = Level1 ∓ InpGridSpacingATR × ATR(15M)
Level3   = Level2 ∓ InpGridSpacingATR × ATR(15M)
TP1      = Level1 ± 1R × InpTP1_R      TP2 = Level1 ± 1R × InpTP2_R
```

Validation — every scale-in level must sit inside the legal band and above the depth cap:

| Check | BUY | Refusal behaviour |
|---|---|---|
| Legal band | `[zLow − 0.3 ATR, zHigh]` | Level fails → **drop to 2 levels** |
| Depth cap | `≥ sweepExtreme − 0.2 ATR` | Level fails → **drop to 2 levels** |
| Entry chase | L1 ≤ `zHigh + 0.5 ATR` | **Refuse the trade** |
| Stop side | `sharedSL < Level1` | **Refuse the trade** |
| Broker stop level | `1R ≥ SYMBOL_TRADE_STOPS_LEVEL` | **Refuse the trade** |
| Spread worth it | `1R ≥ InpMinR_SpreadMult × spread` | **Refuse the trade** |
| Risk affordable | Level 1 lot ≥ broker minimum | **Refuse the trade** |

A level is **never nudged back inside the band**. A level moved to fit is a level the confluence
never justified. Fewer than 2 surviving levels is a refusal, not a one-level trade — a lone market
entry is a different strategy than the one specified.

Level 1 is judged by a looser rule than 2 and 3 on purpose: it is the market entry, and a
break-of-structure close routinely prints just beyond the zone it broke out of. It gets
`InpEntryTolATR` of tolerance past the far edge and is rejected beyond that as a chase. Levels 2
and 3 must be strictly inside the band — that is what *"scale-in inside the confluence zone only"*
actually constrains.

### Step 10 — Placement
Level 1 at market; Levels 2–3 as BUY LIMIT / SELL LIMIT with a 4-hour `ORDER_TIME_SPECIFIED`
expiry. Every ticket carries `sharedSL` and `TP2`. **If Level 1 fails to fill, nothing else is
placed** — pendings without their anchor are an unmanaged position waiting to happen.

### Step 11 — Management
Every tick, in order:
1. Reconcile fills, recompute the volume-weighted average entry, **re-assert the shared stop on
   every leg**.
2. Delete pendings past expiry.
3. On the first touch of TP1: close 50% of live volume proportionally, **delete every remaining
   pending**, move the stop to `avgEntry ± InpBreakevenPoints`, state → PARTIAL.
4. Nothing else. No trailing. TP2 and the shared stop finish the trade.

### Step 12 — Teardown
- **Daily loss cap hit** → close everything, lock out for the day, start cooldown.
- **HTF direction flips** → delete **unfilled pendings only**; filled legs are left to the shared
  stop, because a filled leg already has bounded risk and closing it on an H4 flicker is how a
  good entry gets thrown away.

---

## 4. Three places the spec contradicted itself

Resolved in code, with the reasoning recorded at the point of use.

### 4.1 Fixed lots vs fixed risk per level — the one that matters

The spec asked for both `InpRiskPerLevel = 0.5% per level` and *"fixed lot per level (no
multiplier)"*. These cannot both hold: Levels 2 and 3 sit **closer** to the shared stop, so a flat
0.5% each requires **progressively larger lots** the deeper the ladder goes — a martingale by
shape, which the spec bans outright.

**Resolution:** Level 1 is sized at `InpRiskPerLevel` over its own distance to `sharedSL`, and that
**same lot** is used on every level. Deeper levels then risk strictly less than 0.5% each, so
worst-case total lands **under** the 1.5% budget rather than over it, and no lot ever increases.

`InpEqualRiskPerLevel = true` exposes the literal reading for testing. It prints a warning at
`OnInit` and is **not** the default.

### 4.2 Four score components are not really optional

Read literally, a signal reaches 80 with **no sweep** (20+20+15+15+10) or **no BOS** (85). Both
would pass the gate and then build a grid from an undefined `sweepExtreme` — a **zero stop loss**,
silently, on a live account.

**Resolution:** Trend, Zone, Sweep and BOS are hard prerequisites checked before the score is
summed. That leaves 75 mandatory points, so the ≥ 80 gate still requires at least one bonus
(Vol → 85, Pivot → 90, both → 100). The gate stays meaningful rather than decorative.

### 4.3 TP1 partial vs levels that fill afterwards

If a pending fills *after* the 50% close, "50% of total" becomes a larger number than the half
already banked and the remainder is no longer at breakeven.

**Resolution:** taking TP1 deletes all unfilled pendings; the ladder freezes at whatever filled.
`TP1`/`TP2` stay fixed prices derived from Level 1 (per the spec's *"2R based on Level1"*), while
the breakeven stop is computed from `avgEntry` — a stop at Level 1 would not be breakeven for a
ladder that averaged down below it.

### Smaller gaps filled

- *"hours 0–23"* is no filter at all; exposed as `InpStartHour`/`InpEndHour`, defaulting to 0/23.
- The legal band's lower bound had no number; it uses the sweep depth (0.30 ATR).
- The spec never defined "strong support" — four zone parameters were added (`InpZoneLookbackH1`,
  `InpZoneClusterATR`, `InpZoneMinTouches`, `InpZoneMinHeightATR`).
- Prose literals (3-bar reclaim, 4h expiry, 100pt breakeven, 0.2 ATR depth cap) became inputs,
  **defaulting to the spec values** — so a default run *is* the specified strategy.

---

## 5. Inputs

### A. Risk
| Input | Default | Meaning |
|---|---|---|
| `InpRiskPerLevel` | 0.5 | % of equity risked, sized from Level 1 |
| `InpMaxGridLevels` | 3 | Hard ceiling of 3; minimum of 2 |
| `InpMinScore` | 80 | Confluence gate |
| `InpMaxSpreadPoints` | 300 | Spread ceiling |
| `InpMaxDailyLossPct` | 3.0 | Closes everything and locks out for the day |
| `InpCooldownMin` | 90 | Minutes after a grid closes |
| `InpMaxTradesPerDay` | 2 | Grids per day |

### B. Model
| Input | Default | Meaning |
|---|---|---|
| `InpTrendMode` | STRICT | H4 strictness: STRICT (EMA+HH+HL) / RELAXED (EMA + HH or HL) / EMA_ONLY. The single biggest control on trade count — it rejects ~60% of all bars on both gold and XRP |
| `InpEMA4H` | 200 | H4 trend filter period |
| `InpSwingLB` | 50 | H4 swing lookback |
| `InpATRPeriod` | 14 | ATR period (all timeframes) |

### C. Grid geometry
| Input | Default | Meaning |
|---|---|---|
| `InpGridSpacingATR` | 0.4 | Level spacing, × ATR(15M) |
| `InpSharedSL_ATR_Buffer` | 0.5 | Stop beyond the sweep extreme, × ATR(15M) |
| `InpTP1_R` | 1.0 | TP1 in R from Level 1 — closes 50% |
| `InpTP2_R` | 2.0 | TP2 in R from Level 1 |

### D. Tolerances and zone definition
| Input | Default | Meaning |
|---|---|---|
| `InpSweepDepthATR` | 0.30 | Sweep must exceed the zone by this × ATR |
| `InpSweepWindowBars` | 12 | How far back (M15) a sweep may have happened |
| `InpReclaimBars` | 3 | Bars allowed to reclaim |
| `InpBOSLookbackBars` | 60 | M5 swing scan depth |
| `InpDeepestLevelATR` | 0.20 | Level 3 depth cap past the sweep |
| `InpEntryTolATR` | 0.50 | How far past the zone Level 1 may sit |
| `InpPivotNearATR` | 0.50 | Pivot proximity for the bonus |
| `InpVolMult` / `InpVolMA` | 1.50 / 20 | Volume bonus test |
| `InpZoneLookbackH1` | 150 | H1 bars scanned for the zone |
| `InpZoneClusterATR` | 0.50 | Pivot merge tolerance, × ATR(H1) |
| `InpZoneMinTouches` | 2 | Touches required to call a zone strong |
| `InpZoneMinHeightATR` | 0.20 | Minimum zone width |
| `InpMinR_SpreadMult` | 3.0 | **1R must be ≥ this × the live spread, or the setup is refused.** Inert on XAUUSD (1R ≈ 100× spread); decisive on XRPUSD, where 1R averaged 0.6× the spread and every configuration lost money as a result |
| `InpPendingExpiryHours` | 4 | Unfilled levels expire |
| `InpBreakevenPoints` | 100 | BE offset after TP1 |

### E. Session and plumbing
`InpStartHour` 0 · `InpEndHour` 23 · `InpEqualRiskPerLevel` **false** (see §4.1) ·
`InpMagic` 970301 · `InpSlippage` 20

### F. Display
`InpShowPanel` · `InpShowVisuals` · panel position, font and colours.

---

## 6. Dashboard

```
HTF ZONE GRID  3-LEVEL
HTF dir (H4)  : BUY
Zone (H1)     : 2500.00 - 2502.40  (3 touch)
Score         : 85 / 80
  T20  Z20  P0   S20  B15  V10
Blocked by    : -
Grid          : ACTIVE
Levels filled : 2 / 3
Avg entry     : 2500.20
Shared SL     : 2493.00
Daily PnL     : 142.60  (1/2 grids)
Cooldown      : ready
```

Two rows are not in the spec and earn their place: the **score breakdown** and **Blocked by**.
A deliberately selective EA is idle almost all of the time — the panel has to explain the idleness
or it gets mistaken for a fault and "fixed". `Blocked by` names the first gate that failed, so
"no trades in three months" is distinguishable from "broken since the last edit".

**Chart visuals:** zone rectangle, one line per level (solid = filled, dotted = pending), the
shared stop in red, TP1 dashed and TP2 solid. Cleared the moment the grid closes — leaving a
finished ladder on the chart makes the next signal unreadable, and across a long backtest it
accumulates thousands of objects and stalls the terminal.

---

## 7. Installing and running

### Compile
```powershell
& "C:\Program Files\Go MetaTrader 5\MetaEditor64.exe" `
  /compile:"c:\myfiles\training_folder\HTF_Zone_Grid\HTF_Zone_Grid_3Level_EA.mq5" `
  /log:"c:\myfiles\training_folder\HTF_Zone_Grid\ea.log"
Get-Content ea.log -Encoding Unicode      # UTF-16
```
MetaEditor returns **exit code 1 on success** — read the `Result: N errors` line instead.
Current status: **0 errors, 0 warnings** for both the EA and the self-test.

### Live / demo
Attach to an **M5** chart. The EA reads H4, H1, M15, M5 and D1 itself; the chart timeframe only
sets the scan clock. Allow algo trading. One chart per symbol — the EA enforces one grid per
symbol via its magic number.

### Backtest
```powershell
& "C:\Program Files\Go MetaTrader 5\terminal64.exe" /config:"...\backtest\htfzg_backtest.ini"
```
- The terminal **must not already be running** (one instance per data folder).
- Copy the `.ex5` **and the four `.mqh` files** into `<data>\MQL5\Experts\HTF_Zone_Grid\` — this
  setup is copy-based, not symlinked.
- Read results from `<data>\Tester\logs\<yyyymmdd>.log` (UTF-16). `Report=` produced no file on
  build 6140.

> **The stale-`.set` trap.** MT5 auto-saves tester inputs to
> `<data>\MQL5\Profiles\Tester\HTF_Zone_Grid_3Level_EA.set` and **silently reuses them** on later
> runs. Recompiling with new defaults does *not* take effect. Delete that file whenever a default
> changes. This is why the EA prints its **resolved config** at `OnInit` — find that line and check
> the values it actually received before trusting any result.

---

## 8. Backtest results

**XAUUSD M5 · 2025.08.29 → 2026.08.29 · $10,000 · Model=1 (control points) · defaults**

| | |
|---|---|
| Grids opened | **1** |
| Final balance | 10,001.00 (+$1.00) |
| Bars scanned | 70,900 |
| Max drawdown | none — the one grid never went negative past BE |

The single trade, in full:

```
2026.02.25 03:05  GRID OPEN   BUY  score=85  zone 5141.33–5155.42  sweep 5137.56
                  L1 5159.18 (filled)  L2 5154.14  L3 5149.15  0.01 lots each
                  sharedSL 5131.32   R=27.81   TP1 5186.94   TP2 5214.75
2026.02.25 03:28  TP1 touched → L2 and L3 cancelled, stop to BE 5160.18
                  partial close skipped: 0.01 lots cannot be halved at min lot
2026.02.25 13:16  stopped at BE+100pts → +$1.00,  levels filled 1/3
```

Mechanically the whole chain works: gate → score 85 → geometry → market entry + two limits
sharing one stop → TP1 freeze → breakeven → exit. **Statistically one trade proves nothing.**

### Why it only traded once — the scan tally

The EA now counts why every scanned M5 bar was rejected and prints the ranked list at `OnDeinit`:

| Blocked by | Bars | Share |
|---|---:|---:|
| **H4 neutral** | 40,566 | **57.3%** |
| **no sweep / reclaim** | 28,268 | **39.9%** |
| no BOS | 1,727 | 2.4% |
| no zone | 108 | 0.2% |
| score 75 < 80 | 69 | 0.1% |
| L1 chased past the zone | 18 | 0.0% |
| zone too tight for L2 | 3 | 0.0% |

**The score gate is not what starves this EA — it fired only 69 times.** Two upstream filters
consume 97% of all bars:

1. **H4 direction (57%).** Requiring close vs EMA(200) *and* a HH/HL pair means gold spent most
   of the year in a state this EA calls neutral. Loosening this is the single highest-leverage
   change — e.g. accepting the EMA alone, or requiring only HH *or* HL.
2. **Sweep + reclaim (40%).** Of the bars that survive the trend filter, almost all fail here.
   `InpSweepWindowBars = 12` (three hours of M15) and `InpSweepDepthATR = 0.30` are the knobs.

Everything downstream — BOS, zone, score, geometry — is essentially never the binding constraint
at current settings. **Tune the trend filter first; tuning the score threshold would do almost
nothing.**

### Two bugs the backtest exposed

Both were fill-accounting defects. Neither affected risk, orders or the shared stop — but both
made the log and the dashboard misreport what traded, which is exactly what a post-mortem needs.

1. **Cancelled pendings counted as filled.** A pending that leaves the active order book has
   either filled *or* been deleted; the reconcile loop assumed "filled". The first run reported
   `levels=3/3` on a grid whose L2 and L3 were cancelled at TP1. Fixed by consulting
   `HistoryOrderGetInteger(..., ORDER_STATE)` to tell the two outcomes apart.

2. **Deals matched to levels by price proximity.** `OnTradeTransaction` matched a fill to a level
   with a tolerance of `oneR` (27.81) — far wider than the 5.04 gap between levels — so Level 1's
   own entry deal was attributed to Level 2. The second run still reported `2/3`. Fixed by
   matching on `DEAL_ORDER` against the level's own order ticket, and by storing the market
   order's ticket as an **order** ticket rather than a deal ticket.

After both fixes the same grid reports `levels=1/3`, which agrees with `avgEntry` staying exactly
at L1 and with the two `order canceled` lines in the broker log.

### Still outstanding

- **`HTFZG_SelfTest` has not been run in the terminal.** Its 10 cases were verified through an
  independent port of the builder (all pass, including the spec's worked example), but the `.ex5`
  itself has not been executed. Run it on an XAUUSD chart.
- **Zero-trade sanity check** (`InpMinScore = 101` → expect exactly 0 trades).
- **`Model=0` re-run.** With only one grid, and its two limits cancelled rather than filled, the
  backtest has said nothing yet about whether L2/L3 realistically fill.
- **A parameter sweep on the H4 filter**, per the tally above.
- **A meaningful sample.** One trade per year is not testable. Either loosen the trend filter or
  run the EA across several symbols.

---

## 9. Protections, and how each is proven

| Protection | Mechanism | How to prove it fired |
|---|---|---|
| Max 3 levels, no multiplier | `HTFZG_MAX_LEVELS`, single lot reused | Self-test case 8 |
| One grid per symbol | Terminal queried by magic before every grid | `Blocked by: grid already live` |
| Shared SL on every leg | Re-asserted **every** management tick | Log line on any repair |
| Daily loss cap | Equity drawdown incl. floating PnL | `DAILY LOSS CAP HIT` in the log |
| Cooldown / trades per day | Daily book, rolled on server **date** | Timestamps between grid-open lines |
| Direction change | Deletes pendings only | `HTF direction changed` log line |
| Pending expiry | Broker expiry **and** an EA-side sweep | `unfilled level(s) expired` |
| Restart mid-trade | `AdoptExistingGrid` at `OnInit` | `adopted an existing grid` |

Two details worth knowing:

**The daily loss cap counts floating PnL.** A 3% cap that only counts closed trades is not a cap,
it is a delay.

**The daily book rolls on the server *date*, not a timer.** An EA started on Friday evening must not
have its lockout cleared by "24 hours elapsed" somewhere inside the weekend gap.

---

## 10. Accounting note — PnL is read, never accumulated

Realised PnL (the per-grid `RESULT=` field and the dashboard's Daily PnL) is computed by
`RealisedSince()`, which reads deal history. It is deliberately **not** accumulated in
`OnTradeTransaction`.

That handler is not guaranteed to have delivered the closing deal by the time the management tick
notices the grid is gone, and the trades it misses are the ones that close fastest — the
stop-outs. An earlier build accumulated, and on XRPUSD it printed per-trade results summing to
**+159** while the account had actually lost **664**: nine of 21 grids logged `0.00R`. A log that
silently omits losses is worse than no log at all.

If you add any new PnL readout, read it from history the same way.

---

## 11. Known limitations

- **Adoption after a restart assumes TP1 was already taken.** The score, the zone and the TP1 state
  cannot be recovered from the broker. Erring the other way would re-fire a 50% close on a grid
  that already had one — a real loss — so the EA forfeits a partial it cannot prove it still owes,
  and the panel shows the zone as unknown rather than inventing one.
- **A minimum-lot leg cannot be halved.** If closing half would leave less than the broker minimum
  on either side, that leg is left whole and the shortfall is logged. The stop still moves to
  breakeven. On a small account this means TP1 may bank nothing.
- **Selectivity is severe by design.** Four mandatory components plus a bonus requirement plus the
  geometry validation plus two grids a day. If it never trades, read `Blocked by` before loosening
  anything — the answer is usually one specific gate, not the score.
- **Not yet walked forward.** No optimisation or out-of-sample work has been done. The defaults are
  the spec's numbers, not fitted values.

---

## 12. If you change something

- **Any edit to `HTFZG_Grid.mqh`** → re-run `HTFZG_SelfTest` before trading the build.
  Non-negotiable. Sign errors and band off-by-ones do not crash; they place a slightly wrong ladder
  that looks like an ordinary losing trade.
- **Any edit to a default** → delete the tester `.set` file, then check the resolved-config line.
- **Adding a component to the score** → decide whether it is mandatory or bonus, and update the
  75-point mandatory floor in §4.2. If mandatory points reach 80, the gate stops meaning anything.
- **Anything in §1** → do not.
