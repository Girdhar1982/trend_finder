//+------------------------------------------------------------------+
//|                                                   HTFZG_Grid.mqh |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+==================================================================+
//|                                                                  |
//| THE EXECUTION LAYER. Steps 9-12 of the spec: build the ladder,   |
//| size it, place it, manage it, tear it down.                      |
//|                                                                  |
//| It contains no signal logic. It is handed a scored HTFZGSignal   |
//| and its only judgement is geometric: do three levels FIT inside  |
//| this zone with a sane stop, and if not, what is the largest      |
//| ladder that does?                                                |
//|                                                                  |
//+==================================================================+
//|                                                                  |
//| INVARIANT 1 - ONE SHARED STOP, ALWAYS                            |
//| Every level carries grid.sharedSL. Not a per-level stop, not a   |
//| trailing stop, not "SL added after the fill". Verified on every  |
//| management tick against the broker, and repaired if it drifts.   |
//| This is what makes total risk knowable in advance.               |
//|                                                                  |
//| INVARIANT 2 - FIXED LOTS ACROSS LEVELS (spec conflict, resolved) |
//| The spec asks for two things that cannot both hold:              |
//|   "InpRiskPerLevel = 0.5%  per level"                            |
//|   "fixed lot per level (no multiplier)"                          |
//| Levels 2 and 3 sit CLOSER to the shared stop than Level 1, so    |
//| risking a flat 0.5% on each would require BIGGER lots the deeper |
//| the ladder goes. That is a martingale by shape even though it is |
//| not one by intent, and the spec bans lot escalation outright.    |
//|                                                                  |
//| RESOLUTION: size Level 1 at InpRiskPerLevel over its own         |
//| distance to sharedSL, and use that SAME lot for every level.     |
//| Deeper levels then risk strictly LESS than 0.5% each, so worst   |
//| case total risk is UNDER the 1.5% budget rather than over it,    |
//| and no lot ever increases. InpEqualRiskPerLevel = false exposes  |
//| the literal reading for anyone who wants to test it; the default |
//| is the safe one.                                                 |
//|                                                                  |
//| INVARIANT 3 - TP1 CLOSES THE LADDER TO NEW FILLS                 |
//| The spec says TP1 closes 50% of the total position. If a pending |
//| level filled AFTER that partial, "50% of total" would be a       |
//| different, larger number than the half already banked, and the   |
//| remainder would no longer be at breakeven. So the moment TP1 is  |
//| taken, every unfilled pending is DELETED. The ladder is frozen   |
//| at whatever filled.                                              |
//|                                                                  |
//| INVARIANT 4 - R IS MEASURED FROM LEVEL 1, PARTIALS FROM AVERAGE  |
//| tp1/tp2 are fixed price levels derived from Level 1 at build     |
//| time (spec step 11: "2R based on Level1"), so they never move as |
//| levels fill. avgEntry is tracked separately and is what the      |
//| breakeven stop is computed from, because a stop at Level 1 would |
//| not be breakeven for a ladder that averaged down below it.       |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#include "HTFZG_Types.mqh"

//+------------------------------------------------------------------+
//| Execution tunables. Mirrors the EA inputs for the same reason    |
//| HTFZGCfg does - no globals, so the self-test can drive this.     |
//+------------------------------------------------------------------+
struct HTFZGGridCfg
  {
   double            riskPerLevel;    // InpRiskPerLevel, percent of equity
   int               maxLevels;       // InpMaxGridLevels, clamped to HTFZG_MAX_LEVELS
   double            spacingATR;      // InpGridSpacingATR
   double            slBufferATR;     // InpSharedSL_ATR_Buffer
   double            tp1R;            // InpTP1_R
   double            tp2R;            // InpTP2_R
   double            deepestATR;      // 0.20 - Level 3 may not pass sweepExtreme by more
   double            sweepBufferATR;  // 0.30 - lower bound of the legal band, = sweep depth
   int               expiryHours;     // InpPendingExpiryHours (4)
   int               bePoints;        // 100  - breakeven offset after TP1
   long              magic;
   int               slippage;
  };

//+------------------------------------------------------------------+
//| STEP 9a - Shared stop from the sweep extreme.                    |
//|                                                                  |
//|   BUY:  sweepExtreme - ATR(15M) x slBufferATR                    |
//|   SELL: sweepExtreme + ATR(15M) x slBufferATR                    |
//|                                                                  |
//| Beyond the wick, not at it: the stop has to sit past the         |
//| liquidity that was just taken, or the next probe of the same     |
//| low takes the whole ladder out at once.                          |
//+------------------------------------------------------------------+
double HTFZG_SharedSL(ENUM_HTFZG_DIR dir, double sweepExtreme, double atr15,
                      const HTFZGGridCfg &cfg);

//+------------------------------------------------------------------+
//| STEP 9b - Build the ladder and validate it.                      |
//|                                                                  |
//|   Level 1 = signal.bosPrice (reclaim + break)                    |
//|   Level 2 = Level 1 -/+ spacingATR x ATR(15M)                    |
//|   Level 3 = Level 2 -/+ spacingATR x ATR(15M)                    |
//|                                                                  |
//| Then every level must sit inside the legal band:                 |
//|   BUY:  [zLow - sweepBufferATR x ATR , zHigh]                    |
//|   SELL: [zLow , zHigh + sweepBufferATR x ATR]                    |
//| and Level 3 may not be deeper than sweepExtreme -/+ deepestATR.  |
//|                                                                  |
//| A level that fails DROPS THE LADDER TO 2 (or refuses the trade   |
//| at fewer than 2). It is never nudged back inside: a level moved  |
//| to fit is a level the confluence never justified, and the whole  |
//| premise here is that scale-in happens only inside the zone.      |
//|                                                                  |
//| Also rejects when the resulting stop distance is below the       |
//| broker minimum or so wide the 0.5% risk cannot buy a lot at all. |
//|                                                                  |
//| Returns false with a reason in `why` - the caller logs it.       |
//+------------------------------------------------------------------+
bool HTFZG_BuildGrid(const string sym, const HTFZGSignal &sig,
                     const HTFZGGridCfg &cfg, HTFZGGrid &g, string &why);

//+------------------------------------------------------------------+
//| STEP 10a - Lot for the ladder. See INVARIANT 2.                  |
//|                                                                  |
//| Sized off Level 1 -> sharedSL, normalised to the symbol step and |
//| clamped to min/max. Returns 0 when the broker minimum lot would  |
//| already exceed the per-level risk budget: the correct answer is  |
//| then "do not trade", never "trade smaller than allowed".         |
//+------------------------------------------------------------------+
double HTFZG_LotForLevel(const string sym, double entry, double sl,
                         double riskPct, double equity);

//+------------------------------------------------------------------+
//| STEP 10b - Place the ladder.                                     |
//|                                                                  |
//| Level 1 at market. Levels 2-3 as BUY LIMIT / SELL LIMIT with     |
//| ORDER_TIME_SPECIFIED expiry at now + expiryHours.                |
//| Every ticket carries sharedSL and tp2.                           |
//|                                                                  |
//| If Level 1 fails to fill, NOTHING else is placed and the grid is |
//| abandoned. Pendings without their anchor are an unmanaged        |
//| position waiting to happen.                                      |
//+------------------------------------------------------------------+
bool HTFZG_PlaceGrid(const string sym, const HTFZGGridCfg &cfg, HTFZGGrid &g);

//+------------------------------------------------------------------+
//| STEP 11 - Per-tick management. Called while state is ACTIVE or   |
//| PARTIAL. Does, in this order:                                    |
//|                                                                  |
//|   1. Reconcile: which pendings became positions? Recompute       |
//|      avgEntry. Re-assert sharedSL on every leg (INVARIANT 1).    |
//|   2. Expire: delete pendings past g.expiry.                      |
//|   3. TP1: once price touches g.tp1, close 50% of the total live  |
//|      volume proportionally across legs, delete all remaining     |
//|      pendings (INVARIANT 3), move the stop to avgEntry +/-       |
//|      bePoints, set tp1Done, state -> PARTIAL.                    |
//|   4. Nothing else. No trailing. TP2 and sharedSL do the rest.    |
//|                                                                  |
//| Returns true while the grid still exists.                        |
//+------------------------------------------------------------------+
bool HTFZG_Manage(const string sym, const HTFZGGridCfg &cfg, HTFZGGrid &g,
                  ENUM_HTFZG_STATE &state);

//+------------------------------------------------------------------+
//| STEP 12 - Emergency teardown: daily loss cap tripped, or the H4  |
//| direction went neutral/opposite.                                 |
//|                                                                  |
//| `pendingOnly` is the direction-change case: the spec deletes     |
//| unfilled levels but leaves filled ones to their shared stop,     |
//| because a filled leg already has bounded risk and closing it on  |
//| an H4 flicker is how a good entry gets thrown away. The daily    |
//| loss cap passes false and closes everything.                     |
//+------------------------------------------------------------------+
void HTFZG_CloseAll(const string sym, const HTFZGGridCfg &cfg, HTFZGGrid &g, bool pendingOnly);

//+------------------------------------------------------------------+
//| Are any of OUR orders/positions still on this symbol? The truth  |
//| comes from the terminal, not from g - a manual close or a        |
//| stop-out leaves the struct stale until this says otherwise.      |
//+------------------------------------------------------------------+
bool HTFZG_GridExists(const string sym, long magic);

//+------------------------------------------------------------------+
//  IMPLEMENTATION - see docs/DEVELOPMENT_PLAN.md, phase 3.
//+------------------------------------------------------------------+
