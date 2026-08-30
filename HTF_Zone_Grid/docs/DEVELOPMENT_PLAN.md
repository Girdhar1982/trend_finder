# HTF_Zone_Grid_3Level_EA — Development Plan

**Status:** BUILT. All phases implemented; both files compile at 0 errors, 0 warnings.
Phases 1-5 complete. Phase 6 partially complete - geometry verified, backtest still outstanding
(the terminal was running during the build, see §4).

**Result:** main `.mq5` is 579 lines, inside the 700-line target. See
[HTF_Zone_Grid_Documentation.md](../HTF_Zone_Grid_Documentation.md) for the finished system.

---

## 1. Why the code is split this way

The spec is one document, but it describes two independent things: a **model** that decides
whether a setup exists, and an **execution layer** that turns that decision into a bounded
ladder of orders. Keeping them in one file makes the most important debugging question
unanswerable — *did the model score this wrong, or did the grid build it wrong?*

```
HTF_Zone_Grid_3Level_EA.mq5     orchestrator: inputs, lifecycle, safety gate, state machine
├── HTFZG_Types.mqh             shared structs/enums — no logic, included by everything
├── HTFZG_Analysis.mqh          THE MODEL      spec steps 2–8   read-only, deterministic
├── HTFZG_Grid.mqh              EXECUTION      spec steps 9–12  geometry, sizing, management
└── HTFZG_Panel.mqh             presentation   dashboard + chart objects — decides nothing

HTFZG_SelfTest.mq5              offline geometry checks, no market data
backtest/htfzg_backtest.ini     headless tester config + the stale-.set warning
docs/                           this plan, then the strategy doc
```

`Types` is included by all three; none of the three includes another. That keeps the include
graph acyclic by construction rather than by discipline.

The payoff is testability: `HTFZG_Analysis.mqh` never places an order and never draws, so it
returns the same answer for the same bars every time. `HTFZG_Grid.mqh` is pure geometry given
a signal, which is why `HTFZG_SelfTest.mq5` can check it on paper cases with no market data at all.

---

## 2. Three places the spec contradicts itself

These are resolved in the scaffolding with the reasoning recorded at the point of use.
**They are the decisions most worth a second opinion before implementation starts.**

### 2.1 Fixed lots vs fixed risk per level — *the one that matters*

The spec asks for both:

> `InpRiskPerLevel = 0.5; // 0.5% per level` … and … *"fixed lot per level (no multiplier)"*

These cannot both hold. Levels 2 and 3 sit **closer** to the shared stop than Level 1, so
risking a flat 0.5% on each requires **progressively larger lots** the deeper the ladder goes —
a martingale by shape, even though it is not one by intent, and the spec bans lot escalation
outright.

**Resolved:** size Level 1 at `InpRiskPerLevel` over its own distance to `sharedSL`, then use
that **same lot** on every level. Deeper levels risk strictly less than 0.5% each, worst-case
total lands **under** the 1.5% budget instead of over it, and no lot ever increases.
`InpEqualRiskPerLevel = true` exposes the literal reading for testing; the default is the safe one.

### 2.2 Four score components are not really optional

The spec scores six components to 100 and gates at 80. Read literally, a signal can reach 80
**with no sweep** (20+20+15+15+10) or **no BOS** (20+20+15+20+10 = 85). Both would pass the gate
and then build a grid from an undefined `sweepExtreme` — i.e. **a zero stop loss**, silently.

**Resolved:** Trend, Zone, Sweep and BOS are hard prerequisites checked *before* the score is
summed. That leaves 75 mandatory points, so the ≥ 80 gate still requires at least one bonus
(Vol → 85, Pivot → 90, both → 100). The gate stays meaningful rather than decorative.

### 2.3 TP1 partial vs levels that fill afterwards

TP1 closes "50% of total position". If a pending level fills *after* that partial, "50% of total"
becomes a larger number than the half already banked, and the remainder is no longer at breakeven.

**Resolved:** taking TP1 **deletes every unfilled pending**. The ladder freezes at whatever filled.
Related: `tp1`/`tp2` are fixed prices derived from Level 1 at build time (per spec step 11,
"2R based on Level1") so they never move as levels fill, while the **breakeven** stop is computed
from `avgEntry` — a stop at Level 1 would not be breakeven for a ladder that averaged down below it.

### Minor items, decided without ceremony

- *"hours 0–23"* is no filter at all; exposed as `InpStartHour`/`InpEndHour` with 0/23 defaults.
- The legal band's lower bound needs a number the spec never gives; using the sweep depth
  (0.30 ATR) as `sweepBufferATR`, exposed.
- Several prose literals (3-bar reclaim, 4h expiry, 100pt breakeven, 0.2 ATR depth cap) are now
  inputs in group D, **defaulting to the spec values** — so a default run *is* the spec.

---

## 3. Build phases

Each phase ends compilable and verifiable. Nothing goes live until phase 6.

| # | Phase | Deliverable | Done when |
|---|-------|-------------|-----------|
| 1 | **Skeleton** | Inputs, config structs, handle creation, daybook rollover, `OnInit` resolved-config print | **DONE** — compiles clean, prints its resolved config |
| 2 | **Model** | `HTFZG_Analysis.mqh` steps 2–8 | **DONE** — 518 lines, read-only, no orders, no drawing |
| 3 | **Geometry** | `HTFZG_Grid.mqh` build + sizing, `HTFZG_SelfTest.mq5` | **DONE** — all 10 cases pass via an independent port of the builder |
| 4 | **Execution** | Placement, `OnTradeTransaction`, management, teardown, visuals | **DONE** — not yet exercised against a broker |
| 5 | **Risk & state** | Safety gate, daily loss cap, cooldown, trades/day, direction-change teardown, adopt-on-restart | **DONE** — each protection implemented and logged |
| 6 | **Validation** | Backtests, then documentation | **PARTIAL** — docs done, geometry verified, backtest outstanding |

**Sequencing rationale:** the model is built before execution so it can be watched scoring on a
live chart while placing nothing — the cheapest possible way to find out whether "score ≥ 80"
fires twice a week or twice a year. If it turns out to be twice a year, the thresholds get
revisited *before* execution code is written against them.

---

## 4. Verification

Compile and backtest per the existing toolchain (`MetaEditor64.exe /compile:` under
`C:\Program Files\Go MetaTrader 5`; logs are UTF-16; **exit code 1 means success** — parse the
`Result: N errors` line instead).

1. **Self-test** — phase 3, all cases green.
2. **Zero-trade sanity** — run with `InpMinScore = 101`. Must produce exactly zero trades. If it
   trades, the gate is not wired to the gate.
3. **Baseline backtest** — XAUUSD M5, 2024–2026, `Model=1`. Expect a low trade count; that is the
   design, not a fault. Confirm the `resolved config` log line before reading any result.
4. **Fill realism** — re-run anything promising at `Model=0`. L2/L3 are limit orders inside a
   few-ATR band, so control-point fills will flatter the fill rate.
5. **Risk audit** — from the tester log, the worst single grid must lose **no more than
   `maxLevels × InpRiskPerLevel`**, and with fixed lots (§2.1) materially less. Any grid exceeding
   that means the shared-SL invariant broke somewhere.

**The stale-`.set` trap:** MT5 auto-saves tester inputs to
`<data>\MQL5\Profiles\Tester\<EA>.set` and silently reuses them on later runs. Recompiling with
new defaults does **not** take effect. Delete that file whenever a default changes — this is why
`OnInit` prints its resolved config, and why nothing gets attributed to inputs the EA may never
have received.

---

## 5. Protections, and how each is proven

Every protection needs a test that makes it actually fire; an untested guard is decoration.

| Protection | How it is proven |
|---|---|
| Max 3 levels, no multiplier | Self-test case 7: all level lots equal |
| One grid per symbol | Terminal is queried by magic before every new grid — `g_grid` is never trusted (a stop-out leaves it stale) |
| Shared SL on every leg | Re-asserted on every management tick, not just at placement — some brokers drop the stop on a partial-close |
| Daily loss cap 3% | Forced run on a losing period; confirm close-all + lockout in the log |
| Cooldown, trades/day | Log timestamps between consecutive grids |
| Direction change | Deletes **pendings only** — a filled leg already has bounded risk, and closing it on an H4 flicker throws away a good entry |
| Pending expiry 4h | Backtest log shows deletions, not indefinite resting orders |
| Restart mid-trade | Recompile with a live ladder: it must be adopted, not orphaned |

---

## 6. Line budget

| File | Est. lines |
|---|---|
| `HTF_Zone_Grid_3Level_EA.mq5` | ~600 |
| `HTFZG_Analysis.mqh` | ~420 |
| `HTFZG_Grid.mqh` | ~480 |
| `HTFZG_Panel.mqh` | ~220 |
| `HTFZG_Types.mqh` | ~190 (written) |
| `HTFZG_SelfTest.mq5` | ~260 |

Main EA lands comfortably inside the 700-line limit; the modules carry the weight, which is the
point of the split.

---

## 7. Open question for the strategy owner

**§2.1 (fixed lots vs fixed risk) changes the risk profile of every trade this EA will ever take.**
The scaffolding defaults to fixed lots because the spec's "no lot increase" rule is unambiguous and
the failure mode of guessing wrong in the other direction is unbounded. Worth confirming before
phase 3 — it is a one-line default change now and a re-test of every result later.
