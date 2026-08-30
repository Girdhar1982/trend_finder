# XRPUSD — tuning report

**Question asked:** make HTF_Zone_Grid_3Level_EA more profitable on XRPUSD.

**Short answer:** the strategy as specified cannot work on XRPUSD at this broker, and the reason
is not a parameter. **The spread is 168% of the average stop distance.** A guard that refuses
those trades turns a −$2,292 loss into roughly break-even, but nothing found so far makes the EA
meaningfully profitable on this symbol.

Broker: GoMarkets-Demo. History: XRPUSD M5 from **2018-06-19**. All runs $10,000, `Model=1`.

---

## 1. Symbol specs

```
XRPUSD  digits=4  point=0.0001  tickSize=0.0001  tickValue=1.00
        contract=10000  minLot=0.01  maxLot=160  lotStep=0.01
        stopLevel=0  spread=250 points
```

---

## 2. Baseline

| Config | Period | Grids | Net |
|---|---|---:|---:|
| Spec defaults | 2025-04 → 2026-08 | 3 | −$335.69 |

Blocked by: `H4 neutral 62.3%` · `no sweep/reclaim 34.7%` · `no BOS 1.9%`

Same profile as gold: the H4 trend filter is the binding constraint, far ahead of the score gate.

---

## 3. Loosening the trend filter buys trades, not profit

`InpTrendMode` was added (STRICT / RELAXED / EMA_ONLY) because the strict test — EMA **and** both
swing legs — was rejecting ~60% of all bars and was structural rather than tunable.

| Trend mode | Grids | Net | Per trade |
|---|---:|---:|---:|
| STRICT (spec) | 3 | −$335.69 | −$112 |
| RELAXED | 15 | −$956.67 | −$64 |
| EMA_ONLY | 21 | −$663.94 | −$32 |

More trades, more loss. **The entry filter was never what was losing the money.**

---

## 4. A logging bug that hid the losses

While diagnosing, the per-trade results printed by the EA summed to **+159.48** while the account
had actually lost **$663.94**. Nine of 21 grids logged `0.00R`.

`FinishGrid` was reading a PnL accumulator that `OnTradeTransaction` populated — but that handler
is not guaranteed to have delivered the closing deal by the time the management tick notices the
grid is gone. The trades it missed were exactly the ones that closed fastest: **the stop-outs.**

Fixed: PnL is now read from history (`RealisedSince()`), never accumulated. A log that hides
losses is worse than no log — this one would have made a losing strategy look profitable.

Corrected distribution (EMA_ONLY, 21 trades): **−13.37R total, 8 wins / 13 losses.**

```
 3.09  -2.37   1.52  -1.73  -2.70  -2.38   1.78   2.10   1.49   1.28  -2.35
-2.38  -2.46   3.10  -2.17  -2.38   3.86  -2.99  -3.03  -2.40  -2.25
```

Losses cluster at −2.4R **by design**: when all three levels fill, total risk in Level-1 R units
is 1.0 + 0.82 + 0.64 ≈ 2.46R (1.23% of equity — inside the 1.5% budget). Risk control works. The
problem is that the ladder adds size precisely when the trade is going wrong, and one shared stop
kills all of it together. Win rate 38%, avg win +2.28R, avg loss −2.44R.

---

## 5. Why no parameter fixes it

Over the **full 8 years**, all 24 combinations of trend mode × levels × TP1 × TP2 lose:

| | Best | Worst |
|---|---:|---:|
| Net | −$2,185 | −$3,005 |

The entire parameter space spans ~$800 on a ~$2,500 loss. Nothing comes near zero.

One finding held in **every single pairing** and is therefore real rather than noise:
**2 levels always beats 3**, by $400–500. The third level adds the most size deepest into an
adverse move.

By contrast, the 16-month in-sample "best" (EMA_ONLY, 2 levels, TP1 1.5R, TP2 6R) scored
**+$14.53** — and the same config over the full history loses **−$2,380**. That +14.53 was
fitted noise. Its neighbours gave TP2=4 → good, TP2=5 → bad, TP2=6 → good; non-monotonic
behaviour like that is the signature of fitting 21 trades.

---

## 6. The actual cause

```
average 1R  = 0.01486 price units   (min 0.00177, max 0.13683)
spread      = 0.02500 price units   (250 points)
spread / R  = 168%
```

**Every trade paid more to open than it risked in total.** The tightest setups risked one
fourteenth of the spread. ATR-derived stops know nothing about what entry costs, and on a
wide-spread symbol the two invert completely. No downstream parameter can recover that.

### The fix — `InpMinR_SpreadMult` (default 3.0)

`HTFZG_BuildGrid` now refuses any setup whose 1R is less than N × the current spread.

| Guard | Grids | Net (8 years) |
|---|---:|---:|
| off (0×) | 65 | −$2,292.24 |
| **3× spread** | **44** | **+$274.83** |
| 6× spread | 19 | −$70.39 |
| 10× spread | 10 | −$240.84 |

This is a structural correction, not a tuned parameter — it removes trades that were
mathematically unable to profit. The default of 3.0 is inert on XAUUSD, where 1R is ~100× the
spread, so it costs nothing on symbols that were never affected.

---

## 7. Sweep with the guard on — and a correction

24 configurations re-run over the full 8 years **with** the spread guard. Top 12:

| Config | Grids | Net |
|---|---:|---:|
| minR3 · EMA_ONLY · 2 levels · TP1 1.5R | 44 | **+$274.83** |
| minR3 · EMA_ONLY · 3 levels · TP1 1.5R | 44 | +$241.16 |
| minR4 · EMA_ONLY · 2 levels · TP1 1.5R | 31 | +$186.61 |
| minR4 · EMA_ONLY · 3 levels · TP1 1.5R | 31 | +$103.08 |
| minR3 · RELAXED · 2 levels · TP1 1.5R | 33 | +$82.11 |
| minR3 · RELAXED · 3 levels · TP1 1.5R | 33 | +$75.29 |
| minR4 · EMA_ONLY · 2 levels · TP1 1.0R | 31 | +$70.17 |
| minR4 · EMA_ONLY · 3 levels · TP1 1.0R | 31 | +$35.33 |
| minR3 · EMA_ONLY · 2 levels · TP1 1.0R | 44 | +$5.06 |
| minR3 · EMA_ONLY · 3 levels · TP1 1.0R | 44 | −$18.89 |
| minR3 · RELAXED · 2 levels · TP1 1.0R | 33 | −$145.98 |
| minR3 · RELAXED · 3 levels · TP1 1.0R | 33 | −$204.76 |

All `minR=2` configurations fell below the cutoff, i.e. worse than +$5.

Two directions hold in **every** pairing and are the only findings here worth carrying forward:

- **TP1 at 1.5R beats 1.0R** (6/6 pairings). The 50% partial at 1R was cutting winners short.
- **EMA_ONLY beats RELAXED** (6/6 pairings) — but see §3: that is about trade count, not edge.

### Correction to the pre-guard reading of "2 levels beats 3"

Section 5 reported that dropping to 2 levels was worth **$400–500** in all 12 pre-guard pairings.
With the spread guard on, the direction still holds in all 6 pairings — but the gap collapses to
**$7–$84**.

So "2 beats 3" is directionally robust (18/18 pairings overall) while its *magnitude* was almost
entirely an artefact of the spread problem: the third level's extra size was mostly extra spread
cost, not extra market risk. Once trades that could not pay for themselves are refused, the third
level is close to neutral. Do not carry the "$400–500" figure forward — it measured the cost bug,
not the ladder.

---

## 8. Verdict

**+$274.83 over eight years on $10,000 is +2.7% total — break-even, not profitable.**

The spread guard is worth keeping on every symbol. But it converts XRPUSD from "structurally
broken" to "no demonstrable edge", which is an honest description of where this strategy stands
on this instrument, not a win.

### What would actually be needed

- **A cheaper instrument or broker.** At 250 points, XRPUSD spread demands stops far wider than
  0.4–0.5 ATR on M15. The strategy is not the problem; the cost base is.
- **A higher signal timeframe.** M15 or H1 signals would produce a larger 1R, changing the
  spread ratio directly rather than filtering around it.
- **Drop the third level** on any symbol — it lost money in all 12 pairings tested.

### Do not

- Read the +$274.83 as a result to trade on. 44 trades over eight years is far too thin, and it
  came from a search over the same data.
- Treat any of the tuned values here as validated. Nothing in this report has been tested
  out-of-sample.
