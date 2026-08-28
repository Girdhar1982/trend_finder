//+------------------------------------------------------------------+
//|                                                   HullTrendSR.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Shared support / resistance engine.                               |
//|                                                                   |
//| ONE copy of the algorithm, two consumers:                         |
//|   HullTrendEA_Core.mqh  - trades off these levels                 |
//|   HullTrendSR_MT5.mq5   - draws them                              |
//|                                                                   |
//| That split is the whole point. A visualiser with its own copy of  |
//| the maths drifts from the EA sooner or later, and a picture that  |
//| no longer describes the trades is worse than no picture at all:   |
//| you would tune the veto against levels the EA never saw.          |
//|                                                                   |
//| This file also carries the higher-timeframe ladder. It is not an  |
//| S/R concept, but both consumers have to resolve the SAME higher   |
//| timeframe or they scan different data and draw different levels.  |
//|                                                                   |
//| METHOD                                                            |
//|   1. Pivot fractals - a high with `fractal` lower highs on each   |
//|      side, and the mirror for lows.                               |
//|   2. Confirmed LATE and therefore never repainting: a pivot at    |
//|      shift i is only examined once the `fractal` bars to its      |
//|      right have closed, so the scan starts at shift fractal + 1   |
//|      (shift 0 is still forming).                                  |
//|   3. Clustered by ATR-scaled proximity. Highs and lows go into    |
//|      ONE list: a broken resistance becomes support, and a price   |
//|      that is both a pivot high and a pivot low is one strong      |
//|      level, not two weak ones.                                    |
//|   4. Strength is a touch count. It is a count, not evidence -     |
//|      see the "known limitations" note in the EA documentation.    |
//+------------------------------------------------------------------+
#ifndef HULLTREND_SR_MQH
#define HULLTREND_SR_MQH

//+------------------------------------------------------------------+
//| One clustered level                                              |
//+------------------------------------------------------------------+
struct SRLevel
  {
   double            price;     // touch-weighted mean of the merged pivots
   int               touches;   // how many pivots merged into it
   datetime          first;     // oldest pivot in the cluster - where it began
   datetime          last;      // newest pivot in the cluster
  };

//+------------------------------------------------------------------+
//| How to build the level set. Both consumers fill this from their  |
//| own inputs; identical values must produce identical levels.      |
//+------------------------------------------------------------------+
struct SRConfig
  {
   int               fractal;      // bars each side of a pivot
   int               lookback;     // bars scanned on the trading TF
   bool              useHTF;       // also scan the higher timeframe
   ENUM_TIMEFRAMES   htf;          // which one (already resolved)
   double            clusterATR;   // merge pivots closer than this x ATR
   int               maxAgeBars;   // drop levels older than this many chart bars
  };

//+------------------------------------------------------------------+
//| How to draw it                                                   |
//+------------------------------------------------------------------+
struct SRStyle
  {
   color             resistance;   // levels above the current price
   color             support;      // levels below it
   int               maxEachSide;  // 0 = draw them all
   bool              labels;       // price / touches / distance text
   bool              rays;         // extend the line to the right edge
   int               labelShift;   // label offset to the right, in bars
  };

//+------------------------------------------------------------------+
//| Candidate higher timeframes.                                     |
//|                                                                  |
//| Deliberately a SUBSET of what MT5 offers. M2/M3/M6/M12, H2/H3/H6 |
//| and friends are perfectly good CHART timeframes but poor regime  |
//| filters, and excluding them is what lets the formula below       |
//| reproduce the original hand-written ladder exactly while also    |
//| covering the timeframes that ladder had no answer for.           |
//+------------------------------------------------------------------+
#define SR_HTF_CANDIDATES 8

ENUM_TIMEFRAMES SRHTFCandidate(const int i)
  {
   switch(i)
     {
      case 0:
         return PERIOD_M5;
      case 1:
         return PERIOD_M15;
      case 2:
         return PERIOD_M30;
      case 3:
         return PERIOD_H1;
      case 4:
         return PERIOD_H4;
      case 5:
         return PERIOD_D1;
      case 6:
         return PERIOD_W1;
      default:
         return PERIOD_MN1;
     }
  }

//+------------------------------------------------------------------+
//| Higher timeframe selection.                                      |
//|                                                                  |
//| Targets `mult` x the chart timeframe and snaps to the nearest    |
//| candidate above. The predecessor was a lookup table covering     |
//| eight chart timeframes; every other one fell through to a        |
//| default that returned the chart TF itself, which silently        |
//| disabled the single most important filter in the system on one   |
//| log line at startup. H2, H6, H8 and H12 are ordinary choices.    |
//|                                                                  |
//| Resolves identically to the old table on all eight timeframes it |
//| did handle: M1->M15, M5->H1, M15->H4, M30->H4, H1->D1, H4->D1,   |
//| D1->W1. Nothing that already worked changes.                     |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SRPickHTF(const ENUM_TIMEFRAMES chartTF, const bool autoMode,
                          const ENUM_TIMEFRAMES explicitTF, const double multIn)
  {
   if(!autoMode)
      return (explicitTF == PERIOD_CURRENT ? chartTF : explicitTF);

   const double chart = (double)PeriodSeconds(chartTF);
   if(chart <= 0.0)
      return chartTF;

   const double mult   = (multIn < 2.0 ? 2.0 : multIn);
   const double target = chart * mult;

   ENUM_TIMEFRAMES best    = chartTF;
   double          bestErr = 0.0;
   bool            found   = false;

   for(int i = 0; i < SR_HTF_CANDIDATES; i++)
     {
      const ENUM_TIMEFRAMES tf = SRHTFCandidate(i);
      const double secs = (double)PeriodSeconds(tf);
      if(secs <= chart)
         continue;                  // a "higher" timeframe has to be higher

      //--- Error measured in LOG space, so being 2x under target and 2x over
      //--- it count the same. A linear metric would bias every choice upward,
      //--- because the candidates get further apart as they get larger.
      const double err = MathAbs(MathLog(secs / target));
      if(!found || err < bestErr - 1e-9)
        {
         found   = true;
         best    = tf;
         bestErr = err;
        }
     }

   //--- Candidates ascend and the comparison above is strict, so an exact tie
   //--- keeps the SMALLER timeframe - the more responsive of the two.
   return (found ? best : chartTF);
  }

//+------------------------------------------------------------------+
//| Merge one pivot into the level set                               |
//+------------------------------------------------------------------+
void SRAddLevel(SRLevel &lv[], const double price, const datetime when, const double tol)
  {
   const int n = ArraySize(lv);
   for(int i = 0; i < n; i++)
      if(MathAbs(lv[i].price - price) <= tol)
        {
         //--- touch-weighted running mean, so the level sits where price
         //--- actually turned rather than on whichever pivot arrived first
         lv[i].price = (lv[i].price * lv[i].touches + price) / (lv[i].touches + 1);
         lv[i].touches++;
         if(when > lv[i].last)
            lv[i].last = when;
         if(when < lv[i].first)
            lv[i].first = when;
         return;
        }

   ArrayResize(lv, n + 1);
   lv[n].price   = price;
   lv[n].touches = 1;
   lv[n].first   = when;
   lv[n].last    = when;
  }

//+------------------------------------------------------------------+
//| Scan one timeframe for pivot fractals                            |
//+------------------------------------------------------------------+
void SRCollect(SRLevel &lv[], const string symbol, const ENUM_TIMEFRAMES tf,
               const int lookback, const int fractalIn, const double tol,
               const datetime cutoff)
  {
   const int k = (fractalIn < 1 ? 1 : fractalIn);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int n = CopyRates(symbol, tf, 0, lookback, r);
   if(n < 2 * k + 2)
      return;

   //--- Shift 0 is still forming, and a pivot needs k CLOSED bars on its right,
   //--- so the newest bar that can carry one is at shift k + 1. This is what
   //--- makes the level set non-repainting.
   for(int i = k + 1; i < n - k; i++)
     {
      if(r[i].time < cutoff)
         break;                     // series is newest-first: everything older follows

      bool hi = true, lo = true;
      for(int j = 1; j <= k; j++)
        {
         if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high)
            hi = false;
         if(r[i].low  >= r[i - j].low  || r[i].low  >= r[i + j].low)
            lo = false;
        }

      if(hi)
         SRAddLevel(lv, r[i].high, r[i].time, tol);
      if(lo)
         SRAddLevel(lv, r[i].low,  r[i].time, tol);
     }
  }

//+------------------------------------------------------------------+
//| Build the whole level set. O(lookback) with a tiny constant.      |
//| `atr` sets the clustering scale; `maxAgeBars` must already be     |
//| resolved to a positive number by the caller.                      |
//+------------------------------------------------------------------+
void SRBuild(SRLevel &lv[], const string symbol, const ENUM_TIMEFRAMES chartTF,
             const SRConfig &cfg, const double atr)
  {
   ArrayResize(lv, 0);
   if(atr <= 0.0)
      return;

   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const double tol   = MathMax(cfg.clusterATR * atr, point);

   const int age = (cfg.maxAgeBars > 0 ? cfg.maxAgeBars : 400);

   //--- one wall-clock horizon for both timeframes, expressed in chart bars
   const long     span   = (long)age * PeriodSeconds(chartTF);
   const datetime cutoff = (datetime)MathMax(0.0, (double)TimeCurrent() - (double)span);

   SRCollect(lv, symbol, chartTF, (cfg.lookback < 50 ? 50 : cfg.lookback),
             cfg.fractal, tol, cutoff);

   if(cfg.useHTF && cfg.htf != chartTF)
      SRCollect(lv, symbol, cfg.htf, MathMax(60, cfg.lookback / 4),
                cfg.fractal, tol, cutoff);
  }

//+------------------------------------------------------------------+
//| Nearest level strictly on the `dir` side of `from`               |
//| (+1 = above, -1 = below). Levels below `minTouches` are ignored. |
//+------------------------------------------------------------------+
bool SRNearest(const SRLevel &lv[], const int minTouches, const double from, const int dir,
               double &lvl, int &touches)
  {
   bool   found = false;
   double bestD = 0.0;
   const int minT = (minTouches < 1 ? 1 : minTouches);

   lvl     = 0.0;
   touches = 0;

   for(int i = 0; i < ArraySize(lv); i++)
     {
      if(lv[i].touches < minT)
         continue;
      const double d = (lv[i].price - from) * dir;
      if(d <= 0.0)
         continue;                  // wrong side, or exactly on it
      if(!found || d < bestD)
        {
         found   = true;
         bestD   = d;
         lvl     = lv[i].price;
         touches = lv[i].touches;
        }
     }
   return found;
  }

//--- how many qualifying levels sit between `price` and lv[idx] on the same
//--- side. 0 means lv[idx] is the nearest one in that direction.
int SRRank(const SRLevel &lv[], const int idx, const int minTouches, const double price)
  {
   const int    minT = (minTouches < 1 ? 1 : minTouches);
   const double d    = MathAbs(lv[idx].price - price);
   const int    side = (lv[idx].price >= price ? 1 : -1);
   int rank = 0;

   for(int i = 0; i < ArraySize(lv); i++)
     {
      if(i == idx || lv[i].touches < minT)
         continue;
      if((lv[i].price >= price ? 1 : -1) != side)
         continue;
      if(MathAbs(lv[i].price - price) < d)
         rank++;
     }
   return rank;
  }

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
void SRClear(const long chartId, const string prefix)
  {
   ObjectsDeleteAll(chartId, prefix, -1, -1);
  }

//--- Draws each level as a segment running from the pivot that started it to
//--- the right edge, so the picture shows WHERE a level came from and not just
//--- that it exists. Strength drives width and line style; the nearest level
//--- on each side is labelled with its distance in ATR, which is the number
//--- InpSRVetoATR has to be set against.
void SRDraw(const SRLevel &lv[], const long chartId, const string prefix,
            const int minTouches, const double price, const double atr,
            const ENUM_TIMEFRAMES chartTF, const SRStyle &st)
  {
   SRClear(chartId, prefix);

   const int      minT = (minTouches < 1 ? 1 : minTouches);
   const datetime now  = TimeCurrent();
   const datetime lblT = now + (datetime)((long)MathMax(0, st.labelShift) *
                                          PeriodSeconds(chartTF));

   for(int i = 0; i < ArraySize(lv); i++)
     {
      if(lv[i].touches < minT)
         continue;

      const int rank = SRRank(lv, i, minT, price);
      if(st.maxEachSide > 0 && rank >= st.maxEachSide)
         continue;

      const bool  above = (lv[i].price >= price);
      const color col   = (above ? st.resistance : st.support);

      //--- strength reads as weight, so a glance ranks the levels
      int width = 1;
      if(lv[i].touches >= 3)
         width = 2;
      if(lv[i].touches >= 6)
         width = 3;
      const ENUM_LINE_STYLE style = (lv[i].touches >= 3 ? STYLE_SOLID : STYLE_DOT);

      const string ln = StringFormat("%sL%d", prefix, i);
      if(ObjectCreate(chartId, ln, OBJ_TREND, 0, lv[i].first, lv[i].price, now, lv[i].price))
        {
         ObjectSetInteger(chartId, ln, OBJPROP_COLOR,      col);
         ObjectSetInteger(chartId, ln, OBJPROP_STYLE,      style);
         ObjectSetInteger(chartId, ln, OBJPROP_WIDTH,      width);
         ObjectSetInteger(chartId, ln, OBJPROP_RAY_RIGHT,  st.rays);
         ObjectSetInteger(chartId, ln, OBJPROP_RAY_LEFT,   false);
         ObjectSetInteger(chartId, ln, OBJPROP_BACK,       true);
         ObjectSetInteger(chartId, ln, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, ln, OBJPROP_HIDDEN,     true);
         ObjectSetString(chartId, ln, OBJPROP_TOOLTIP,
                         StringFormat("%s  %s  touches %d  since %s",
                                      (above ? "resistance" : "support"),
                                      DoubleToString(lv[i].price, _Digits),
                                      lv[i].touches,
                                      TimeToString(lv[i].first, TIME_DATE | TIME_MINUTES)));
        }

      if(!st.labels)
         continue;

      //--- Only the nearest level each side carries the ATR distance. That is
      //--- the one the EA's no-room-to-level veto actually measures against,
      //--- and labelling every level with it just makes noise.
      string txt = StringFormat("%s  x%d", DoubleToString(lv[i].price, _Digits), lv[i].touches);
      if(rank == 0 && atr > 0.0)
         txt += StringFormat("  (%.2fxATR)", MathAbs(lv[i].price - price) / atr);

      const string tn = StringFormat("%sT%d", prefix, i);
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0, lblT, lv[i].price))
        {
         ObjectSetString(chartId, tn, OBJPROP_TEXT, txt);
         ObjectSetInteger(chartId, tn, OBJPROP_COLOR,      col);
         ObjectSetInteger(chartId, tn, OBJPROP_FONTSIZE,   8);
         ObjectSetInteger(chartId, tn, OBJPROP_ANCHOR,     ANCHOR_LEFT);
         ObjectSetInteger(chartId, tn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, tn, OBJPROP_HIDDEN,     true);
        }
     }
  }

#endif // HULLTREND_SR_MQH
//+------------------------------------------------------------------+
