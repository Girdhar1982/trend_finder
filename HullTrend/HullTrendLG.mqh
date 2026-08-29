//+------------------------------------------------------------------+
//|                                                   HullTrendLG.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Shared liquidity-grab engine.                                    |
//|                                                                  |
//| ONE copy of the detection, any number of consumers:              |
//|   HullTrendLG_MT5.mq5 - prints the recent grabs to the Experts   |
//|                         log and marks them on the chart          |
//|                                                                  |
//| A liquidity grab (stop hunt, sweep) is a bar that pierces a      |
//| resting order cluster and closes back inside it: the liquidity   |
//| was real, the breakout was not.                                  |
//|                                                                  |
//|   BULL grab - price closes below a recent swing LOW (taking out  |
//|   the sell stops resting under it) and closes back above it.     |
//|   The sell-side is exhausted; longs step in where those stops    |
//|   were.                                                          |
//|                                                                  |
//|   BEAR grab - price pierces a recent swing HIGH (taking out the  |
//|   buy stops above it) and closes back below it. The breakout     |
//|   failed; shorts step in where those stops were.                 |
//|                                                                  |
//| METHOD                                                           |
//|   1. The reference for bar i is the highest high / lowest low of |
//|      the `refBars` bars BEFORE it - the level whose resting      |
//|      orders the bar is suspected of clearing.                    |
//|   2. Only CLOSED bars are examined (shift 1 onward), and the     |
//|      close must be back on the original side of the level, so    |
//|      nothing here repaints.                                      |
//|   3. The pierce must exceed `minSweepATR` x ATR to count: a      |
//|      one-tick overshoot of a level is noise, not a grab.         |
//|   4. Bull and bear grabs go into ONE list, tagged by dir, newest |
//|      first, so one consumer can show both sides.                 |
//+------------------------------------------------------------------+
#ifndef HULLTREND_LG_MQH
#define HULLTREND_LG_MQH

//--- Arrow clearance from the swept extreme, in ATR. Same convention as the
//--- flip arrows in HullTrend_MT5.mq5: a flat point offset is invisible on an
//--- index CFD and enormous on a JPY cross.
#define LG_ARROW_OFF_ATR 0.25

//+------------------------------------------------------------------+
//| One grab point                                                   |
//+------------------------------------------------------------------+
struct LGPoint
  {
   double            price;    // the extreme the bar reached (the sweep tip)
   double            level;    // the swing high/low that was swept
   datetime          time;     // the bar that did it (already closed)
   int               dir;      // +1 bull grab (sell-side swept), -1 bear grab (buy-side swept)
   double            sweep;    // how far past the level, in price units
  };

//+------------------------------------------------------------------+
//| How to build the grab set. Both consumers fill this from their   |
//| own inputs; identical values must produce identical points.      |
//+------------------------------------------------------------------+
struct LGConfig
  {
   int               lookback;     // bars scanned on the trading TF
   int               refBars;      // lookback for the reference swing before each bar
   double            minSweepATR;  // pierce must be at least this x ATR
   int               maxAgeBars;   // drop grabs older than this many chart bars
  };

//+------------------------------------------------------------------+
//| The clamps the engine applies to a config, exposed so a consumer  |
//| can log the numbers it will ACTUALLY run with instead of the raw  |
//| inputs. LGCollect calls these too - one definition, no drift.     |
//+------------------------------------------------------------------+
int LGRefBars(const int refBars)   { return(refBars  < 2  ? 2  : refBars);  }
int LGScanBars(const int lookback) { return(lookback < 50 ? 50 : lookback); }

//--- How many bars back the scan really reaches: the lookback and the age
//--- cutoff, whichever bites first. Counted in BARS, never in seconds.
int LGScanDepth(const LGConfig &cfg)
  {
   const int age = (cfg.maxAgeBars > 0 ? cfg.maxAgeBars : 400);
   return((int)MathMin(LGScanBars(cfg.lookback), age));
  }

//+------------------------------------------------------------------+
//| How to draw it. Defaulted in a constructor, like SRStyle, so     |
//| that adding a field here cannot silently feed garbage to a       |
//| caller written before it existed.                                |
//+------------------------------------------------------------------+
struct LGStyle
  {
   color             bull;         // bull grab marker
   color             bear;         // bear grab marker
   bool              labels;       // text beside each marker
   int               fontSize;     // label font size
   int               maxPoints;    // draw only the most recent N (0 = all)
   bool              showLevel;    // dashed segment at the swept reference level

                     LGStyle()
     {
      bull      = clrMediumSeaGreen;
      bear      = clrTomato;
      labels    = true;
      fontSize  = 8;
      maxPoints = 8;
      showLevel = true;
     }
  };

//+------------------------------------------------------------------+
//| Scan one timeframe for liquidity grabs, newest first.            |
//|                                                                  |
//| `atr` sets the sweep scale. The pierce is measured against the   |
//| CURRENT ATR, not the grab bar's own - the same approximation     |
//| SRBuild makes for its clustering.                                |
//|                                                                  |
//| Returns false ONLY when the history could not be read, which a   |
//| caller must not confuse with "no grabs found": acting on the     |
//| empty set in that case wipes a chart that was merely still       |
//| syncing its history.                                             |
//+------------------------------------------------------------------+
bool LGCollect(LGPoint &lg[], const string symbol, const ENUM_TIMEFRAMES tf,
               const LGConfig &cfg, const double atr)
  {
   ArrayResize(lg, 0);
   if(atr <= 0.0)
      return(false);

   const int    ref      = LGRefBars(cfg.refBars);
   const double minSweep = MathMax(0.0, cfg.minSweepATR) * atr;
   const int    bars     = LGScanBars(cfg.lookback);
   const int    scan     = LGScanDepth(cfg);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int need = bars + ref + 2;
   const int n    = CopyRates(symbol, tf, 0, need, r);
   if(n < ref + 3)
      return(false);

   //--- Shift 0 is still forming and a grab needs a CLOSED bar, so the scan
   //--- starts at shift 1 - which is also what makes the set non-repainting.
   //--- STRICT `<`: the reference scan below reads r[i + ref], so the last
   //--- safe start is n - ref - 1. `<=` walked one past the end of the array,
   //--- which MQL5 treats as a critical error and removes the indicator.
   for(int i = 1; i < n - ref; i++)
     {
      //--- `i` IS the bar shift, so the age cutoff is exact here. Expressing it
      //--- in calendar seconds cut the window short by every weekend and
      //--- session break that fell inside it.
      if(i > scan)
         break;                     // series is newest-first: everything older follows

      //--- the reference is the swing BEFORE this bar, so a bar can never
      //--- sweep a level that includes its own extreme
      double refHigh = r[i + 1].high;
      double refLow  = r[i + 1].low;
      for(int j = i + 2; j <= i + ref; j++)
        {
         if(r[j].high > refHigh)
            refHigh = r[j].high;
         if(r[j].low  < refLow)
            refLow  = r[j].low;
        }

      //--- bear grab: pierced the high, closed back inside it
      const double sweepHigh = r[i].high - refHigh;
      if(sweepHigh > 0.0 && r[i].close < refHigh &&
         (minSweep <= 0.0 || sweepHigh >= minSweep))
        {
         ArrayResize(lg, ArraySize(lg) + 1);
         const int k = ArraySize(lg) - 1;
         lg[k].price = r[i].high;
         lg[k].level = refHigh;
         lg[k].time  = r[i].time;
         lg[k].dir   = -1;
         lg[k].sweep = sweepHigh;
        }

      //--- bull grab: pierced the low, closed back inside it
      const double sweepLow = refLow - r[i].low;
      if(sweepLow > 0.0 && r[i].close > refLow &&
         (minSweep <= 0.0 || sweepLow >= minSweep))
        {
         ArrayResize(lg, ArraySize(lg) + 1);
         const int k = ArraySize(lg) - 1;
         lg[k].price = r[i].low;
         lg[k].level = refLow;
         lg[k].time  = r[i].time;
         lg[k].dir   = +1;
         lg[k].sweep = sweepLow;
        }
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
void LGClear(const long chartId, const string prefix)
  {
   ObjectsDeleteAll(chartId, prefix, -1, -1);
  }

//--- Marker at the sweep tip: an arrow in the direction the sweep
//--- failed, so the eye reads the setup rather than the wick. A
//--- dashed segment shows the reference level that was swept.
void LGDraw(const LGPoint &lg[], const long chartId, const string prefix,
            const string symbol, const ENUM_TIMEFRAMES chartTF,
            const LGStyle &st, const double atr)
  {
   LGClear(chartId, prefix);

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const int total  = ArraySize(lg);
   const int n      = (st.maxPoints > 0 ? (int)MathMin(st.maxPoints, total) : total);

   for(int i = 0; i < n; i++)
     {
      const bool   bull     = (lg[i].dir > 0);
      const color  col      = (bull ? st.bull : st.bear);
      const double sweepATR = (atr > 0.0 ? lg[i].sweep / atr : 0.0);

      //--- Marker price: clear of the wick rather than on top of it, the way
      //--- the trend indicator offsets its own flip arrows.
      const double off = (atr > 0.0 ? atr * LG_ARROW_OFF_ATR : 0.0);
      const double at  = (bull ? lg[i].price - off : lg[i].price + off);

      //--- the marker. Arrow codes 233/234 are the up/down arrows the
      //--- trend indicator already uses for its flips. The anchor puts the
      //--- glyph on the far side of that point, pointing back at the bar -
      //--- inverted, it drew the arrow straight over the wick it marks.
      const string an = StringFormat("%sA%d", prefix, i);
      if(ObjectCreate(chartId, an, OBJ_ARROW, 0, lg[i].time, at))
        {
         ObjectSetInteger(chartId, an, OBJPROP_ARROWCODE, (bull ? 233 : 234));
         ObjectSetInteger(chartId, an, OBJPROP_COLOR,      col);
         ObjectSetInteger(chartId, an, OBJPROP_WIDTH,      2);
         ObjectSetInteger(chartId, an, OBJPROP_ANCHOR,
                          (bull ? ANCHOR_TOP : ANCHOR_BOTTOM));
         ObjectSetInteger(chartId, an, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, an, OBJPROP_HIDDEN,     true);
         ObjectSetString(chartId, an, OBJPROP_TOOLTIP,
                         StringFormat("%s liquidity grab\nprice %s  swept level %s\n"
                                      "%.2f ATR  %s",
                                      (bull ? "Bullish" : "Bearish"),
                                      DoubleToString(lg[i].price, digits),
                                      DoubleToString(lg[i].level, digits),
                                      sweepATR,
                                      TimeToString(lg[i].time, TIME_DATE | TIME_MINUTES)));
        }

      //--- the level that was swept: a short dashed segment across the grab
      //--- bar, so the setup is visible without hovering
      if(st.showLevel)
        {
         const long   secs = PeriodSeconds(chartTF);
         const string ln   = StringFormat("%sL%d", prefix, i);
         if(ObjectCreate(chartId, ln, OBJ_TREND, 0,
                         lg[i].time - (datetime)secs, lg[i].level,
                         lg[i].time + (datetime)secs, lg[i].level))
           {
            ObjectSetInteger(chartId, ln, OBJPROP_COLOR,      col);
            ObjectSetInteger(chartId, ln, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chartId, ln, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chartId, ln, OBJPROP_RAY_RIGHT,  false);
            ObjectSetInteger(chartId, ln, OBJPROP_RAY_LEFT,   false);
            ObjectSetInteger(chartId, ln, OBJPROP_BACK,       true);
            ObjectSetInteger(chartId, ln, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(chartId, ln, OBJPROP_HIDDEN,     true);
           }
        }

      if(!st.labels)
         continue;

      const string tn  = StringFormat("%sT%d", prefix, i);
      const string txt = StringFormat("LG-%s  %.2fA", (bull ? "B" : "S"), sweepATR);
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0,
                      lg[i].time + (datetime)(2 * PeriodSeconds(chartTF)),
                      at))
        {
         ObjectSetString(chartId, tn, OBJPROP_TEXT, txt);
         ObjectSetInteger(chartId, tn, OBJPROP_COLOR,      col);
         ObjectSetInteger(chartId, tn, OBJPROP_FONTSIZE,   st.fontSize);
         ObjectSetInteger(chartId, tn, OBJPROP_ANCHOR,     ANCHOR_LEFT);
         ObjectSetInteger(chartId, tn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, tn, OBJPROP_HIDDEN,     true);
        }
     }
  }

//+------------------------------------------------------------------+
//| Human-readable print of the recent grabs.                        |
//|                                                                  |
//| Prints the `perSide` most recent grabs of EACH direction, merged |
//| newest-first, so a trend that sweeps one way cannot hide the     |
//| other side entirely. One line per grab, "HullLG | GRAB | ...",   |
//| so the Experts tab can be pasted and read back like the EA's.    |
//+------------------------------------------------------------------+
void LGPrintRecent(const LGPoint &lg[], const int perSide, const string symbol,
                   const ENUM_TIMEFRAMES tf, const double atr)
  {
   const int total = ArraySize(lg);
   if(total == 0)
      return;

   //--- `perSide` caps each direction INDEPENDENTLY, so both sides of the
   //--- market are always represented even in a one-way trend
   int bull[], bear[];
   int nBull = 0, nBear = 0;      // what was FOUND, before `perSide` caps it
   for(int i = 0; i < total; i++)
     {
      if(lg[i].dir > 0)
        {
         nBull++;
         if(perSide > 0 && ArraySize(bull) >= perSide)
            continue;
         ArrayResize(bull, ArraySize(bull) + 1);
         bull[ArraySize(bull) - 1] = i;
        }
      else
        {
         nBear++;
         if(perSide > 0 && ArraySize(bear) >= perSide)
            continue;
         ArrayResize(bear, ArraySize(bear) + 1);
         bear[ArraySize(bear) - 1] = i;
        }
     }

   //--- The two counts are what was found, so they add up to the total beside
   //--- them; `each` says how much of it follows. Printing the CAPPED sizes
   //--- here made the line contradict itself - "20 grabs: 3 bull, 3 bear".
   const string each = (perSide > 0 ? StringFormat("showing most recent %d of each", perSide)
                        : "showing all");
   Print(StringFormat("HullLG | LIST | %d grab(s) in lookback: %d bull, %d bear - "
                      "%s, newest first",
                      total, nBull, nBear, each));

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   int b = 0, s = 0;
   while(b < ArraySize(bull) || s < ArraySize(bear))
     {
      const bool   takeBull = (s >= ArraySize(bear) ||
                               (b < ArraySize(bull) &&
                                lg[bull[b]].time >= lg[bear[s]].time));
      const int    idx  = (takeBull ? bull[b++] : bear[s++]);
      const string kind = (lg[idx].dir > 0 ? "BULL" : "BEAR");
      const int    age  = iBarShift(symbol, tf, lg[idx].time, false);

      Print(StringFormat("HullLG | GRAB | %s | %-4s  price %s  swept level %s  "
                         "sweep %.2f ATR  %d bar%s ago",
                         TimeToString(lg[idx].time, TIME_DATE | TIME_MINUTES),
                         kind,
                         DoubleToString(lg[idx].price, digits),
                         DoubleToString(lg[idx].level, digits),
                         (atr > 0.0 ? lg[idx].sweep / atr : 0.0),
                         (age >= 0 ? age : 0),
                         (age == 1 ? "" : "s")));
     }
  }

#endif // HULLTREND_LG_MQH
//+------------------------------------------------------------------+
