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
//| How much a level's label should say.                             |
//|                                                                  |
//| The chart already prints the price on its own axis, so a label   |
//| whose first number is that same price spends the widest, most    |
//| readable strip of the screen restating what the trader can       |
//| already read. Every rung below spends it instead on the numbers  |
//| the axis cannot give: how far away the level is, in the units    |
//| the position is actually sized in.                               |
//+------------------------------------------------------------------+
enum ENUM_SR_LABEL
  {
   SR_LABEL_COMPACT = 0,   // Compact - rank and ATR distance only
   SR_LABEL_NORMAL  = 1,   // Normal - plus pips and strength
   SR_LABEL_FULL    = 2    // Full - plus price, touch count and age
  };

//+------------------------------------------------------------------+
//| How to draw it                                                   |
//|                                                                  |
//| Defaulted in a constructor, so that adding a field here cannot   |
//| silently feed garbage to a caller written before it existed.     |
//| The EA fills the first six and must keep working untouched.      |
//+------------------------------------------------------------------+
struct SRStyle
  {
   color             resistance;   // levels above the current price
   color             support;      // levels below it
   int               maxEachSide;  // 0 = draw them all
   bool              labels;       // per-level text
   bool              rays;         // extend the line to the right edge
   int               labelShift;   // label offset to the right, in bars
   int               detail;       // ENUM_SR_LABEL - how much that text says
   int               fontSize;     // label and panel font size
   bool              panel;        // the summary block in the chart corner
   int               panelCorner;  // ENUM_BASE_CORNER it hangs from
   int               panelX;       // its inset from that corner, in pixels
   int               panelY;       //
   color             panelText;    // its body colour
   color             panelBg;      // its backing plate (clrNONE = no plate)

                     SRStyle()
     {
      resistance  = clrTomato;
      support     = clrMediumSeaGreen;
      maxEachSide = 4;
      labels      = true;
      rays        = true;
      labelShift  = 3;
      detail      = SR_LABEL_NORMAL;
      fontSize    = 8;
      panel       = false;        // opt-in: the EA draws levels as a debug aid
      panelCorner = CORNER_LEFT_UPPER;
      panelX      = 12;
      panelY      = 22;
      panelText   = clrSilver;
      panelBg     = C'22,26,34';
     }
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
//| Human units                                                      |
//|                                                                  |
//| A level printed as "1.16412  x3" states two things the trader    |
//| cannot act on: a price the axis already shows, and a bare count  |
//| with no scale attached to it. What a decision actually needs is  |
//| how FAR the level is - in pips, because that is the unit the     |
//| stop is set in, and in ATR, because that is the unit the EA's    |
//| no-room-to-level veto is set in - how HARD it has held, and how  |
//| RECENTLY. These helpers produce exactly those.                   |
//+------------------------------------------------------------------+

//--- The timeframe without MQL5's enum prefix: "H4", not "PERIOD_H4".
string SRTFName(const ENUM_TIMEFRAMES tf)
  {
   const string s = EnumToString(tf);
   return (StringFind(s, "PERIOD_") == 0 ? StringSubstr(s, 7) : s);
  }

//--- One pip for this symbol: the 3/5-digit FX convention, and the raw point
//--- everywhere else. Deliberately NOT a table of symbol names - those go
//--- stale the day the broker renames a suffix, and then every distance on
//--- the chart is wrong by a factor of ten with nothing on screen saying so.
double SRPipSize(const string symbol)
  {
   const double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(point <= 0.0)
      return 0.0;
   return ((digits == 3 || digits == 5) ? point * 10.0 : point);
  }

//--- Distance in the largest unit that still reads as a quantity. Points stop
//--- carrying meaning somewhere around five figures: on an index or a coin
//--- "48300 pts" is not a number anyone holds in their head, so past that
//--- threshold this falls back to the price move itself.
string SRFormatDist(const string symbol, const double dist)
  {
   const int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double unit   = SRPipSize(symbol);
   const double d      = MathAbs(dist);

   if(unit <= 0.0)
      return DoubleToString(d, digits);

   const bool   fx = (digits == 3 || digits == 5);
   const double n  = d / unit;

   if(n >= 10000.0)
      return DoubleToString(d, digits);
   if(n < 20.0)
      return StringFormat("%.1f %s", n, (fx ? "pips" : "pts"));
   return StringFormat("%.0f %s", n, (fx ? "pips" : "pts"));
  }

//--- Age the way a trader says it: "40m", "5h", "3d". One unit only - the
//--- second one has never changed anybody's decision.
string SRFormatAge(const datetime when, const datetime now)
  {
   long s = (long)(now - when);
   if(s < 0)
      s = 0;
   if(s < 3600)
      return StringFormat("%dm", (int)(s / 60));
   if(s < 86400)
      return StringFormat("%dh", (int)(s / 3600));
   const int days = (int)(s / 86400);
   if(days < 28)
      return StringFormat("%dd", days);
   return StringFormat("%dw", days / 7);
  }

//--- Strength as weight rather than as a number: three pivots is not "3", it
//--- is one rung above two. Capped at five, so a heavily retested level
//--- cannot run its own label off the right of the screen.
string SRStrengthBar(const int touches)
  {
   const int n = (touches < 1 ? 1 : (touches > 5 ? 5 : touches));
   string s = "";
   for(int i = 0; i < n; i++)
      s += "*";
   return s;
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
//--- that it exists. Strength drives width and line style.
//---
//--- Labels are ranked R1/S1 outwards, because "the nearest resistance" is the
//--- thing a trader actually points at, and a rank says which one this is
//--- without the eye having to measure. Beside the rank is the distance TO it:
//--- in ATR, the unit InpSRVetoATR is set in, and in pips, the unit the stop
//--- is set in. The price itself is demoted to the FULL rung and the tooltip -
//--- the axis was already printing it.
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

      const bool   above = (lv[i].price >= price);
      const color  col   = (above ? st.resistance : st.support);
      const double dist  = MathAbs(lv[i].price - price);

      //--- R1 is the nearest resistance, S2 the second support out, and so on
      const string tag = StringFormat("%s%d", (above ? "R" : "S"), rank + 1);

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

         //--- the long form on hover, so the label itself can stay short
         ObjectSetString(chartId, ln, OBJPROP_TOOLTIP,
                         StringFormat("%s  %s  %s\n%s away  (%.2f ATR)\n"
                                      "%d touches   first %s   last %s",
                                      tag, (above ? "resistance" : "support"),
                                      DoubleToString(lv[i].price, _Digits),
                                      SRFormatDist(_Symbol, dist),
                                      (atr > 0.0 ? dist / atr : 0.0),
                                      lv[i].touches,
                                      TimeToString(lv[i].first, TIME_DATE | TIME_MINUTES),
                                      TimeToString(lv[i].last,  TIME_DATE | TIME_MINUTES)));
        }

      if(!st.labels)
         continue;

      string txt = tag;
      if(st.detail >= SR_LABEL_FULL)
         txt += "  " + DoubleToString(lv[i].price, _Digits);
      if(atr > 0.0)
         txt += StringFormat("  %.2f ATR", dist / atr);
      if(st.detail >= SR_LABEL_NORMAL)
         txt += "  " + SRFormatDist(_Symbol, dist) + "  " + SRStrengthBar(lv[i].touches);
      if(st.detail >= SR_LABEL_FULL)
         txt += StringFormat("  %d touches, last %s", lv[i].touches,
                             SRFormatAge(lv[i].last, now));

      const string tn = StringFormat("%sT%d", prefix, i);
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0, lblT, lv[i].price))
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
//| One pinned line of the summary panel                             |
//+------------------------------------------------------------------+
void SRPanelLine(const long chartId, const string name, const SRStyle &st,
                 const int row, const string text, const color col)
  {
   //--- Consolas, so the columns line up. A proportional font turns the table
   //--- into a ransom note the moment one price is a digit longer.
   const int lh = (int)(st.fontSize * 1.9) + 3;

   if(!ObjectCreate(chartId, name, OBJ_LABEL, 0, 0, 0))
      return;
   ObjectSetInteger(chartId, name, OBJPROP_CORNER,     st.panelCorner);
   ObjectSetInteger(chartId, name, OBJPROP_XDISTANCE,  st.panelX + 8);
   ObjectSetInteger(chartId, name, OBJPROP_YDISTANCE,  st.panelY + 6 + row * lh);
   ObjectSetInteger(chartId, name, OBJPROP_COLOR,      col);
   ObjectSetInteger(chartId, name, OBJPROP_FONTSIZE,   st.fontSize);
   ObjectSetString(chartId, name, OBJPROP_FONT,        "Consolas");
   ObjectSetString(chartId, name, OBJPROP_TEXT,        text);
   ObjectSetInteger(chartId, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chartId, name, OBJPROP_HIDDEN,     true);
  }

//+------------------------------------------------------------------+
//| The summary panel.                                                |
//|                                                                   |
//| Per-level labels answer "what is that line?". They cannot answer  |
//| the question actually asked before a trade - how much room is     |
//| there, and on which side - because that answer lives in the       |
//| relationship between two levels and the current price, and no     |
//| single label can hold it. This block can.                         |
//|                                                                   |
//| Call it AFTER SRDraw: that function clears the whole prefix.      |
//+------------------------------------------------------------------+
void SRDrawPanel(const SRLevel &lv[], const long chartId, const string prefix,
                 const int minTouches, const double price, const double atr,
                 const string symbol, const ENUM_TIMEFRAMES chartTF,
                 const string htfName, const SRStyle &st)
  {
   if(!st.panel || atr <= 0.0)
      return;

   const int      minT   = (minTouches < 1 ? 1 : minTouches);
   const int      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const datetime now    = TimeCurrent();
   const int      total  = ArraySize(lv);

   //--- one pass for everything the panel reports: the nearest level on each
   //--- side, how many levels cleared the touch filter, and how many of those
   //--- actually made it onto the chart
   int iRes = -1, iSup = -1, qualified = 0, shown = 0;
   for(int i = 0; i < total; i++)
     {
      if(lv[i].touches < minT)
         continue;
      qualified++;

      const int rank = SRRank(lv, i, minT, price);
      if(st.maxEachSide <= 0 || rank < st.maxEachSide)
         shown++;
      if(rank != 0)
         continue;

      if(lv[i].price >= price)
         iRes = i;
      else
         iSup = i;
     }

   const int rows = 5;
   string ln[5];
   color  cl[5];

   ln[0] = StringFormat("HULL S/R   %s %s   HTF %s   ATR %s",
                        symbol, SRTFName(chartTF), htfName, SRFormatDist(symbol, atr));
   cl[0] = st.panelText;

   if(iRes >= 0)
     {
      const double d = lv[iRes].price - price;
      ln[1] = StringFormat("R1  %-10s  +%-11s %-9s %-5s last %s",
                           DoubleToString(lv[iRes].price, digits),
                           SRFormatDist(symbol, d),
                           StringFormat("%.2f ATR", d / atr),
                           SRStrengthBar(lv[iRes].touches),
                           SRFormatAge(lv[iRes].last, now));
     }
   else
      ln[1] = "R1  nothing above price in this lookback";
   cl[1] = st.resistance;

   if(iSup >= 0)
     {
      const double d = price - lv[iSup].price;
      ln[2] = StringFormat("S1  %-10s  -%-11s %-9s %-5s last %s",
                           DoubleToString(lv[iSup].price, digits),
                           SRFormatDist(symbol, d),
                           StringFormat("%.2f ATR", d / atr),
                           SRStrengthBar(lv[iSup].touches),
                           SRFormatAge(lv[iSup].last, now));
     }
   else
      ln[2] = "S1  nothing below price in this lookback";
   cl[2] = st.support;

   //--- Where price sits INSIDE the band is the number no single label can
   //--- carry, and it is the one that says whether a long is buying support
   //--- or chasing into resistance.
   if(iRes >= 0 && iSup >= 0)
     {
      const double band = lv[iRes].price - lv[iSup].price;
      const double pos  = (band > 0.0 ? (price - lv[iSup].price) / band * 100.0 : 0.0);
      ln[3] = StringFormat("price %s sits %.0f%% up a %s band  (%.2f ATR wide)",
                           DoubleToString(price, digits), pos,
                           SRFormatDist(symbol, band), band / atr);
     }
   else
      ln[3] = StringFormat("price %s - only one side is bounded",
                           DoubleToString(price, digits));
   cl[3] = st.panelText;

   ln[4] = StringFormat("drawn %d of %d levels with %d+ touches   (%d clustered)",
                        shown, qualified, minT, total);
   cl[4] = st.panelText;

   //--- Backing plate first, so the text lands on top of it. Consolas advances
   //--- roughly 0.8 px per point of font size, which is close enough to size a
   //--- plate that never clips the longest line.
   if(st.panelBg != clrNONE)
     {
      int longest = 0;
      for(int i = 0; i < rows; i++)
         longest = (int)MathMax(longest, StringLen(ln[i]));

      const int    lh = (int)(st.fontSize * 1.9) + 3;
      const string bg = prefix + "PBG";
      if(ObjectCreate(chartId, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0))
        {
         ObjectSetInteger(chartId, bg, OBJPROP_CORNER,      st.panelCorner);
         ObjectSetInteger(chartId, bg, OBJPROP_XDISTANCE,   st.panelX);
         ObjectSetInteger(chartId, bg, OBJPROP_YDISTANCE,   st.panelY);
         ObjectSetInteger(chartId, bg, OBJPROP_XSIZE,       (int)(longest * st.fontSize * 0.80) + 22);
         ObjectSetInteger(chartId, bg, OBJPROP_YSIZE,       rows * lh + 12);
         ObjectSetInteger(chartId, bg, OBJPROP_BGCOLOR,     st.panelBg);
         ObjectSetInteger(chartId, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(chartId, bg, OBJPROP_COLOR,       st.panelText);
         ObjectSetInteger(chartId, bg, OBJPROP_BACK,        false);
         ObjectSetInteger(chartId, bg, OBJPROP_SELECTABLE,  false);
         ObjectSetInteger(chartId, bg, OBJPROP_HIDDEN,      true);
        }
     }

   for(int i = 0; i < rows; i++)
      SRPanelLine(chartId, StringFormat("%sP%d", prefix, i), st, i, ln[i], cl[i]);
  }

#endif // HULLTREND_SR_MQH
//+------------------------------------------------------------------+
