//+------------------------------------------------------------------+
//|                                               HTFZG_Analysis.mqh |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+==================================================================+
//|                                                                  |
//| THE MODEL. Read-only market analysis: steps 2-8 of the spec.     |
//|                                                                  |
//| Not one function in this file places, modifies or closes an      |
//| order, and none of them writes to a chart. Given the same bar    |
//| history they return the same answer every time. That is what     |
//| makes the strategy testable in isolation from the execution      |
//| layer - if a trade looks wrong, the first question is always     |
//| "did the model score it wrong, or did the grid mis-build it?",   |
//| and the split is what lets that question be answered.            |
//|                                                                  |
//+==================================================================+
//|                                                                  |
//| INVARIANT 1 - CLOSED BARS ONLY                                   |
//| Every helper reads from shift 1 upward and never shift 0. The    |
//| forming bar repaints: a sweep that "happened" at 14:03 can be    |
//| gone by 14:15, and a grid built on it is a grid built on noise.  |
//| The single approved use of live price is the spread check and    |
//| the fill-price maths in HTFZG_Grid.mqh.                          |
//|                                                                  |
//| INVARIANT 2 - MANDATORY vs BONUS COMPONENTS                      |
//| The spec scores six components to 100 and gates at 80. Four of   |
//| them are NOT optional regardless of arithmetic:                  |
//|                                                                  |
//|   Trend 20  mandatory - dir == NONE returns immediately          |
//|   Zone  20  mandatory - no zone, nothing to build a grid inside  |
//|   Sweep 20  mandatory - sweepExtreme DEFINES the shared SL       |
//|   BOS   15  mandatory - bosPrice DEFINES Level 1                 |
//|   Pivot 15  bonus                                                |
//|   Vol   10  bonus                                                |
//|                                                                  |
//| Read literally, the spec lets a signal reach 80 with no sweep    |
//| (20+20+15+15+10) or no BOS (20+20+15+20+10 = 85). Both would     |
//| pass the gate and then build a grid from an UNDEFINED shared SL  |
//| or an undefined Level 1 - a zero stop loss, silently, on a live  |
//| account. So the four are hard prerequisites, checked before the  |
//| score is even summed.                                            |
//|                                                                  |
//| That leaves 75 mandatory points, so the >= 80 gate still means   |
//| something real: at least one bonus must also land (Vol -> 85,    |
//| Pivot -> 90, both -> 100). The gate is not decorative.           |
//|                                                                  |
//| INVARIANT 3 - ONE HANDLE PER INDICATOR, CREATED ONCE             |
//| Indicator handles are created in OnInit and freed in OnDeinit.   |
//| Creating them inside the scan leaks a handle per bar and the     |
//| terminal starts refusing new ones after a few thousand.          |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#include "HTFZG_Types.mqh"

//+------------------------------------------------------------------+
//| Handle bundle. Owned by the EA, passed in by reference, never    |
//| created here - see INVARIANT 3.                                  |
//+------------------------------------------------------------------+
struct HTFZGHandles
  {
   int               ema4h;         // EMA(InpEMA4H) on PERIOD_H4
   int               atr15;         // ATR(InpATRPeriod) on PERIOD_M15
   int               atr5;          // ATR(InpATRPeriod) on PERIOD_M5
   int               atr1h;         // ATR(InpATRPeriod) on PERIOD_H1 - pivot proximity scale

                     HTFZGHandles() { ema4h=INVALID_HANDLE; atr15=INVALID_HANDLE;
                                      atr5=INVALID_HANDLE;  atr1h=INVALID_HANDLE; }
   bool              Valid() const
     {
      return ema4h!=INVALID_HANDLE && atr15!=INVALID_HANDLE
          && atr5 !=INVALID_HANDLE && atr1h!=INVALID_HANDLE;
     }
  };

//+------------------------------------------------------------------+
//| Tunables the model needs. Mirrors the EA inputs so that this     |
//| module never reads a global - which is what would otherwise make |
//| it untestable from the self-test script.                         |
//+------------------------------------------------------------------+
struct HTFZGCfg
  {
   int               ema4h;         // InpEMA4H
   int               swingLB;       // InpSwingLB
   int               atrPeriod;     // InpATRPeriod
   double            sweepDepthATR; // 0.30 - how far past the zone counts as a sweep
   int               reclaimBars;   // 3    - bars allowed to close back inside
   int               bosLookback;   // short 5M swing lookback for the structure break
   double            volMult;       // 1.50 - tick volume vs MA20
   int               volMA;         // 20
   double            pivotNearATR;  // 0.50 - Daily S1/R1 within this x ATR scores the bonus
  };

//+------------------------------------------------------------------+
//| STEP 2 - Higher-timeframe direction on H4.                       |
//|                                                                  |
//| BUY  needs close > EMA200 AND a higher-high / higher-low pair.   |
//| SELL needs close < EMA200 AND a lower-high / lower-low pair.     |
//| Anything else is NONE, and NONE ends the scan.                   |
//|                                                                  |
//| Requiring BOTH the average and the structure is the point. The   |
//| EMA alone flips late and often in a range; the swing pattern     |
//| alone has no notion of where value is. Together they disagree    |
//| exactly during the chop this strategy must not trade.            |
//+------------------------------------------------------------------+
ENUM_HTFZG_DIR HTFZG_Direction(const string sym, const HTFZGHandles &h, const HTFZGCfg &cfg);

//+------------------------------------------------------------------+
//| STEP 3 - Locate the confluence zone on H1.                       |
//|                                                                  |
//| Bullish bias -> the nearest strong SUPPORT below price.          |
//| Bearish bias -> the nearest strong RESISTANCE above price.       |
//|                                                                  |
//| "Strong" means a pivot cluster with >= 2 touches within the      |
//| lookback. The zone is the cluster envelope, not a single line:   |
//| the grid has to be placed INSIDE something with width, and a     |
//| one-price level gives the ladder nowhere to stand.               |
//|                                                                  |
//| Returns false when no qualifying zone exists - a normal outcome, |
//| not an error.                                                    |
//+------------------------------------------------------------------+
bool HTFZG_FindZone(const string sym, ENUM_HTFZG_DIR dir,
                    const HTFZGHandles &h, const HTFZGCfg &cfg, HTFZGZone &out);

//+------------------------------------------------------------------+
//| STEP 4 - Daily pivot confluence. BONUS ONLY, never a gate.       |
//|                                                                  |
//| Classic floor pivots from yesterday's H/L/C. Scores if S1 (buy)  |
//| or R1 (sell) sits within cfg.pivotNearATR x ATR(H1) of the zone. |
//+------------------------------------------------------------------+
bool HTFZG_PivotConfluence(const string sym, ENUM_HTFZG_DIR dir,
                           const HTFZGZone &z, const HTFZGHandles &h, const HTFZGCfg &cfg);

//+------------------------------------------------------------------+
//| STEP 5 - Sweep and reclaim on M15. MANDATORY.                    |
//|                                                                  |
//| BUY:  some bar low  < zLow  - 0.30 x ATR(15M), and price closes  |
//|       back above zLow within cfg.reclaimBars bars.               |
//| SELL: mirrored above zHigh.                                      |
//|                                                                  |
//| Writes sweepExtreme - the wick extreme of the sweeping bar. That |
//| single number is the anchor for the whole risk model downstream, |
//| which is why this step cannot be optional. If several bars swept |
//| inside the window, the FURTHEST extreme wins: the stop must sit  |
//| beyond all of the liquidity that was taken, not just the last.   |
//+------------------------------------------------------------------+
bool HTFZG_SweepReclaim(const string sym, ENUM_HTFZG_DIR dir, const HTFZGZone &z,
                        double atr15, const HTFZGCfg &cfg, double &sweepExtreme);

//+------------------------------------------------------------------+
//| STEP 6 - Structure break on M5, after the reclaim. MANDATORY.    |
//|                                                                  |
//| BUY:  close above the most recent short-term swing HIGH formed   |
//|       since the reclaim. SELL: below the most recent swing LOW.  |
//|                                                                  |
//| Writes bosPrice - the break close, which becomes Level 1. The    |
//| "since the reclaim" clause matters: breaking a high that formed  |
//| BEFORE the sweep is just the market retracing, not confirming.   |
//+------------------------------------------------------------------+
bool HTFZG_StructureBreak(const string sym, ENUM_HTFZG_DIR dir, datetime sinceBar,
                          const HTFZGCfg &cfg, double &bosPrice);

//+------------------------------------------------------------------+
//| STEP 7 - Volume confirmation on M5. BONUS ONLY.                  |
//|                                                                  |
//| Tick volume on the break bar > MA(volMA) x volMult. Tick volume, |
//| not real volume: real volume is empty or broker-specific on most |
//| retail feeds, so a real-volume test would silently never fire.   |
//+------------------------------------------------------------------+
bool HTFZG_VolumeConfirm(const string sym, const HTFZGCfg &cfg);

//+------------------------------------------------------------------+
//| STEP 8 - Run steps 2-7 and score. The only entry point the EA    |
//| calls; everything above is exposed for the self-test.            |
//|                                                                  |
//| Fills `out` and returns true only when every MANDATORY component |
//| passed. The caller still has to apply the >= InpMinScore gate -  |
//| a true return means "well-formed signal", not "tradeable".       |
//| Sets out.reject on the first failure either way.                 |
//+------------------------------------------------------------------+
bool HTFZG_Scan(const string sym, const HTFZGHandles &h, const HTFZGCfg &cfg, HTFZGSignal &out);

//+------------------------------------------------------------------+
//  IMPLEMENTATION - see docs/DEVELOPMENT_PLAN.md, phase 2.
//+------------------------------------------------------------------+
