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
//| The swing scanner enforces this structurally - it starts at      |
//| frac+1 so bar 0 can never enter a comparison.                    |
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
   int               atr1h;         // ATR(InpATRPeriod) on PERIOD_H1 - the zone/pivot scale

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
//| it untestable from anything but a live chart.                    |
//+------------------------------------------------------------------+
struct HTFZGCfg
  {
   ENUM_HTFZG_TREND  trendMode;     // InpTrendMode
   int               swingLB;       // InpSwingLB - H4 swing scan depth
   int               zoneLB;        // InpZoneLookbackH1
   double            zoneClusterATR;// InpZoneClusterATR
   int               zoneMinTouch;  // InpZoneMinTouches
   double            zoneMinHtATR;  // InpZoneMinHeightATR
   double            sweepDepthATR; // InpSweepDepthATR
   int               sweepWindow;   // InpSweepWindowBars (M15)
   int               reclaimBars;   // InpReclaimBars
   int               bosLookback;   // InpBOSLookbackBars (M5)
   double            volMult;       // InpVolMult
   int               volMA;         // InpVolMA
   double            pivotNearATR;  // InpPivotNearATR
  };

//+------------------------------------------------------------------+
//| A confirmed swing point.                                         |
//+------------------------------------------------------------------+
struct HTFZGSwing
  {
   double            price;
   int               bar;           // series index on its timeframe
   datetime          time;
  };

//+------------------------------------------------------------------+
//| Read one value from an indicator buffer. Returns false rather    |
//| than a plausible-looking zero when history is not ready - a      |
//| zero ATR silently produces a zero-width grid and a stop loss on  |
//| top of the entry.                                                |
//+------------------------------------------------------------------+
bool HTFZG_Ind(const int handle, const int shift, double &value)
  {
   double buf[];
   if(handle == INVALID_HANDLE)                 return false;
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return false;
   if(buf[0] <= 0.0 || !MathIsValidNumber(buf[0])) return false;
   value = buf[0];
   return true;
  }

//+------------------------------------------------------------------+
//| Collect confirmed swing points, most recent first.               |
//|                                                                  |
//| A swing high at bar i needs `frac` higher-indexed (older) bars    |
//| AND `frac` lower-indexed (newer) bars below it. Scanning starts  |
//| at i = frac+1, which is what keeps bar 0 out of every comparison |
//| (INVARIANT 1) - a swing is only ever confirmed once the bars to  |
//| its right have closed, so it can appear late but never move.     |
//+------------------------------------------------------------------+
int HTFZG_Swings(const string sym, const ENUM_TIMEFRAMES tf, const int lookback,
                 const int frac, const bool wantHighs, HTFZGSwing &out[])
  {
   ArrayResize(out, 0);
   const int need = lookback + frac + 2;

   double px[];
   ArraySetAsSeries(px, true);
   const int got = (wantHighs ? CopyHigh(sym, tf, 0, need, px)
                              : CopyLow (sym, tf, 0, need, px));
   if(got < frac * 2 + 2)
      return 0;

   const int last = MathMin(lookback, got - frac - 1);
   for(int i = frac + 1; i <= last; i++)
     {
      bool ok = true;
      for(int k = 1; k <= frac && ok; k++)
        {
         if(wantHighs) { if(px[i] <= px[i-k] || px[i] <= px[i+k]) ok = false; }
         else          { if(px[i] >= px[i-k] || px[i] >= px[i+k]) ok = false; }
        }
      if(!ok)
         continue;

      HTFZGSwing s;
      s.price = px[i];
      s.bar   = i;
      s.time  = iTime(sym, tf, i);
      const int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = s;
     }
   return ArraySize(out);
  }

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
ENUM_HTFZG_DIR HTFZG_Direction(const string sym, const HTFZGHandles &h, const HTFZGCfg &cfg)
  {
   double ema = 0.0;
   if(!HTFZG_Ind(h.ema4h, 1, ema))
      return HTFZG_DIR_NONE;

   const double close = iClose(sym, PERIOD_H4, 1);
   if(close <= 0.0)
      return HTFZG_DIR_NONE;

   HTFZGSwing hi[], lo[];
   const int nh = HTFZG_Swings(sym, PERIOD_H4, cfg.swingLB, 2, true,  hi);
   const int nl = HTFZG_Swings(sym, PERIOD_H4, cfg.swingLB, 2, false, lo);
   if(cfg.trendMode != HTFZG_TREND_EMA_ONLY && (nh < 2 || nl < 2))
      return HTFZG_DIR_NONE;      // not enough structure to have an opinion

   const bool haveSwings = (nh >= 2 && nl >= 2);
   const bool hh = (haveSwings && hi[0].price > hi[1].price);
   const bool hl = (haveSwings && lo[0].price > lo[1].price);
   const bool lh = (haveSwings && hi[0].price < hi[1].price);
   const bool ll = (haveSwings && lo[0].price < lo[1].price);

   bool up = false, down = false;
   switch(cfg.trendMode)
     {
      case HTFZG_TREND_EMA_ONLY: up = true;            down = true;            break;
      case HTFZG_TREND_RELAXED:  up = (hh || hl);      down = (lh || ll);      break;
      default:                   up = (hh && hl);      down = (lh && ll);      break;
     }

   if(close > ema && up)   return HTFZG_DIR_BUY;
   if(close < ema && down) return HTFZG_DIR_SELL;
   return HTFZG_DIR_NONE;
  }

//+------------------------------------------------------------------+
//| STEP 3 - Locate the confluence zone on H1.                       |
//|                                                                  |
//| Bullish bias -> the nearest strong SUPPORT below price.          |
//| Bearish bias -> the nearest strong RESISTANCE above price.       |
//|                                                                  |
//| "Strong" means a cluster of >= zoneMinTouch swing points sitting |
//| within zoneClusterATR x ATR(H1) of each other. The zone is the   |
//| cluster envelope, not a single line: the grid has to be placed   |
//| INSIDE something with width, and a one-price level gives the     |
//| ladder nowhere to stand. A cluster thinner than zoneMinHtATR is  |
//| padded symmetrically to that minimum for the same reason.        |
//|                                                                  |
//| The spec named none of these four parameters. They are inputs    |
//| rather than literals because "strong support" is precisely the   |
//| definition most worth re-testing.                                |
//|                                                                  |
//| Returns false when no qualifying zone exists - a normal outcome, |
//| not an error.                                                    |
//+------------------------------------------------------------------+
bool HTFZG_FindZone(const string sym, const ENUM_HTFZG_DIR dir,
                    const HTFZGHandles &h, const HTFZGCfg &cfg, HTFZGZone &out)
  {
   out.Reset();

   double atr1h = 0.0;
   if(!HTFZG_Ind(h.atr1h, 1, atr1h))
      return false;

   const bool wantLows = (dir == HTFZG_DIR_BUY);
   HTFZGSwing sw[];
   const int n = HTFZG_Swings(sym, PERIOD_H1, cfg.zoneLB, 3, !wantLows, sw);
   if(n < cfg.zoneMinTouch)
      return false;

   const double px = iClose(sym, PERIOD_H1, 1);
   if(px <= 0.0)
      return false;

   const double tol = cfg.zoneClusterATR * atr1h;

   //--- Walk the swings newest-first and grow a cluster around each seed
   //--- that lies on the correct side of price. The first seed that
   //--- gathers enough touches wins: swings are ordered by recency, so
   //--- that is also the most recently confirmed qualifying level.
   for(int i = 0; i < n; i++)
     {
      const double seed = sw[i].price;
      if(wantLows  && seed >= px) continue;   // support must be below price
      if(!wantLows && seed <= px) continue;   // resistance must be above

      double lo = seed, hi = seed;
      int    touches = 0;
      for(int j = 0; j < n; j++)
         if(MathAbs(sw[j].price - seed) <= tol)
           {
            touches++;
            lo = MathMin(lo, sw[j].price);
            hi = MathMax(hi, sw[j].price);
           }

      if(touches < cfg.zoneMinTouch)
         continue;

      //--- pad a hairline cluster out to a workable width
      const double minHt = cfg.zoneMinHtATR * atr1h;
      if(hi - lo < minHt)
        {
         const double mid = (hi + lo) * 0.5;
         lo = mid - minHt * 0.5;
         hi = mid + minHt * 0.5;
        }

      out.low     = lo;
      out.high    = hi;
      out.touches = touches;
      out.formed  = sw[i].time;
      out.valid   = true;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| STEP 4 - Daily pivot confluence. BONUS ONLY, never a gate.       |
//|                                                                  |
//| Classic floor pivots from yesterday's H/L/C. Scores if S1 (buy)  |
//| or R1 (sell) sits within pivotNearATR x ATR(H1) of the zone,     |
//| measured to the nearest edge - a pivot INSIDE the zone is        |
//| distance zero and obviously counts.                              |
//+------------------------------------------------------------------+
bool HTFZG_PivotConfluence(const string sym, const ENUM_HTFZG_DIR dir,
                           const HTFZGZone &z, const HTFZGHandles &h, const HTFZGCfg &cfg)
  {
   double atr1h = 0.0;
   if(!HTFZG_Ind(h.atr1h, 1, atr1h))
      return false;

   const double dh = iHigh (sym, PERIOD_D1, 1);
   const double dl = iLow  (sym, PERIOD_D1, 1);
   const double dc = iClose(sym, PERIOD_D1, 1);
   if(dh <= 0.0 || dl <= 0.0 || dc <= 0.0)
      return false;

   const double p     = (dh + dl + dc) / 3.0;
   const double pivot = (dir == HTFZG_DIR_BUY ? 2.0 * p - dh    // S1
                                              : 2.0 * p - dl);  // R1

   double dist = 0.0;
   if(pivot < z.low)       dist = z.low - pivot;
   else if(pivot > z.high) dist = pivot - z.high;

   return (dist <= cfg.pivotNearATR * atr1h);
  }

//+------------------------------------------------------------------+
//| STEP 5 - Sweep and reclaim on M15. MANDATORY.                    |
//|                                                                  |
//| BUY:  some bar low  < zLow  - sweepDepthATR x ATR(15M), and      |
//|       price closes back above zLow within reclaimBars bars.      |
//| SELL: mirrored above zHigh.                                      |
//|                                                                  |
//| Writes sweepExtreme - the wick extreme across the whole sweep    |
//| episode, from the sweeping bar through the reclaiming bar. That  |
//| single number anchors the entire risk model downstream, which is |
//| why this step cannot be optional and why the FURTHEST extreme    |
//| wins: the stop must sit beyond all of the liquidity that was     |
//| taken, not just beyond the last bar of it.                       |
//|                                                                  |
//| Also returns the reclaim bar time, because step 6 may only count |
//| structure that formed AFTER it.                                  |
//+------------------------------------------------------------------+
bool HTFZG_SweepReclaim(const string sym, const ENUM_HTFZG_DIR dir, const HTFZGZone &z,
                        const double atr15, const HTFZGCfg &cfg,
                        double &sweepExtreme, datetime &reclaimTime)
  {
   sweepExtreme = 0.0;
   reclaimTime  = 0;
   if(atr15 <= 0.0)
      return false;

   const bool   buy   = (dir == HTFZG_DIR_BUY);
   const double edge  = (buy ? z.low : z.high);
   const double trig  = (buy ? edge - cfg.sweepDepthATR * atr15
                             : edge + cfg.sweepDepthATR * atr15);

   const int need = cfg.sweepWindow + cfg.reclaimBars + 2;
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true); ArraySetAsSeries(cl, true);
   if(CopyHigh (sym, PERIOD_M15, 0, need, hi) < need) return false;
   if(CopyLow  (sym, PERIOD_M15, 0, need, lo) < need) return false;
   if(CopyClose(sym, PERIOD_M15, 0, need, cl) < need) return false;

   //--- newest first: the first valid episode found is the most recent one
   for(int s = 1; s <= cfg.sweepWindow; s++)
     {
      const bool swept = (buy ? lo[s] < trig : hi[s] > trig);
      if(!swept)
         continue;

      //--- reclaim may happen on the sweep bar itself (the classic case)
      //--- or on any of the next reclaimBars bars, which are LOWER indices
      const int rEnd = MathMax(1, s - cfg.reclaimBars);
      for(int r = s; r >= rEnd; r--)
        {
         const bool back = (buy ? cl[r] > edge : cl[r] < edge);
         if(!back)
            continue;

         double ext = (buy ? lo[r] : hi[r]);
         for(int k = r; k <= s; k++)
            ext = (buy ? MathMin(ext, lo[k]) : MathMax(ext, hi[k]));

         sweepExtreme = ext;
         reclaimTime  = iTime(sym, PERIOD_M15, r);
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| STEP 6 - Structure break on M5, after the reclaim. MANDATORY.    |
//|                                                                  |
//| BUY:  the last closed bar closes above the most recent M5 swing  |
//|       HIGH that formed at or after the reclaim. SELL mirrors.    |
//|                                                                  |
//| Writes bosPrice - the break close, which becomes Level 1.        |
//|                                                                  |
//| Two clauses do real work here. "After the reclaim" - breaking a  |
//| high that formed BEFORE the sweep is just the market retracing,  |
//| not confirming. And the break must be FRESH: bar 2 has to still  |
//| be on the wrong side of the level, so one break fires exactly    |
//| one signal instead of re-firing every bar it stays broken.       |
//+------------------------------------------------------------------+
bool HTFZG_StructureBreak(const string sym, const ENUM_HTFZG_DIR dir,
                          const datetime sinceBar, const HTFZGCfg &cfg, double &bosPrice)
  {
   bosPrice = 0.0;
   const bool buy = (dir == HTFZG_DIR_BUY);

   HTFZGSwing sw[];
   const int n = HTFZG_Swings(sym, PERIOD_M5, cfg.bosLookback, 2, buy, sw);
   if(n < 1)
      return false;

   double level = 0.0;
   bool   found = false;
   for(int i = 0; i < n; i++)
      if(sw[i].time >= sinceBar)          // newest first -> first hit is the latest
        { level = sw[i].price; found = true; break; }
   if(!found)
      return false;

   const double c1 = iClose(sym, PERIOD_M5, 1);
   const double c2 = iClose(sym, PERIOD_M5, 2);
   if(c1 <= 0.0 || c2 <= 0.0)
      return false;

   const bool broke = (buy ? (c1 > level && c2 <= level)
                           : (c1 < level && c2 >= level));
   if(!broke)
      return false;

   bosPrice = c1;
   return true;
  }

//+------------------------------------------------------------------+
//| STEP 7 - Volume confirmation on M5. BONUS ONLY.                  |
//|                                                                  |
//| Tick volume on the break bar > MA(volMA) x volMult, where the MA |
//| is taken over the bars BEFORE the break so the spike cannot      |
//| inflate its own baseline.                                        |
//|                                                                  |
//| Tick volume, not real volume: real volume is empty or            |
//| broker-specific on most retail feeds, so a real-volume test      |
//| would silently never fire.                                       |
//+------------------------------------------------------------------+
bool HTFZG_VolumeConfirm(const string sym, const HTFZGCfg &cfg)
  {
   const int need = cfg.volMA + 2;
   long v[];
   ArraySetAsSeries(v, true);
   if(CopyTickVolume(sym, PERIOD_M5, 0, need, v) < need)
      return false;

   double sum = 0.0;
   for(int i = 2; i <= cfg.volMA + 1; i++)
      sum += (double)v[i];

   const double ma = sum / (double)cfg.volMA;
   if(ma <= 0.0)
      return false;

   return ((double)v[1] > ma * cfg.volMult);
  }

//+------------------------------------------------------------------+
//| STEP 8 - Run steps 2-7 and score.                                |
//|                                                                  |
//| Fills `out` and returns true only when every MANDATORY component |
//| passed (INVARIANT 2). The caller still applies the >= InpMinScore|
//| gate - a true return means "well-formed signal", not             |
//| "tradeable". out.reject carries the first failure either way,    |
//| which is what makes a deliberately idle EA distinguishable from  |
//| a broken one.                                                    |
//+------------------------------------------------------------------+
bool HTFZG_Scan(const string sym, const HTFZGHandles &h, const HTFZGCfg &cfg, HTFZGSignal &out)
  {
   out.Reset();

   //--- ATR first: everything downstream is denominated in it
   if(!HTFZG_Ind(h.atr15, 1, out.atr15) || !HTFZG_Ind(h.atr5, 1, out.atr5))
     { out.reject = "ATR not ready"; return false; }

   //--- 2. trend (mandatory, 20)
   out.dir = HTFZG_Direction(sym, h, cfg);
   if(out.dir == HTFZG_DIR_NONE)
     { out.reject = "H4 neutral"; return false; }
   out.sTrend = 20;

   //--- 3. zone (mandatory, 20)
   if(!HTFZG_FindZone(sym, out.dir, h, cfg, out.zone))
     { out.reject = "no zone"; out.Sum(); return false; }
   out.sZone = 20;

   //--- 5. sweep + reclaim (mandatory, 20) - defines the shared SL
   datetime reclaim = 0;
   if(!HTFZG_SweepReclaim(sym, out.dir, out.zone, out.atr15, cfg, out.sweepExtreme, reclaim))
     { out.reject = "no sweep/reclaim"; out.Sum(); return false; }
   out.sSweep = 20;

   //--- 6. structure break (mandatory, 15) - defines Level 1
   if(!HTFZG_StructureBreak(sym, out.dir, reclaim, cfg, out.bosPrice))
     { out.reject = "no BOS"; out.Sum(); return false; }
   out.sBOS = 15;

   //--- 4. pivot confluence (bonus, 15)
   if(HTFZG_PivotConfluence(sym, out.dir, out.zone, h, cfg))
      out.sPivot = 15;

   //--- 7. volume (bonus, 10)
   if(HTFZG_VolumeConfirm(sym, cfg))
      out.sVol = 10;

   out.Sum();
   return true;
  }
//+------------------------------------------------------------------+
