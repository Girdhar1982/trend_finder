//+------------------------------------------------------------------+
//|                                                  HullTrendFVG.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Shared higher-timeframe imbalance engine: fair value gaps, order |
//| blocks, and the market structure that gives them a direction.    |
//|                                                                  |
//| ONE copy of the detection, any number of consumers:              |
//|   HullTrendFVG_MT5.mq5 - draws the H4 zones on the M15 chart,    |
//|                          scores the entry, prints to the log.    |
//|                                                                  |
//| WHY THIS EXISTS                                                  |
//|   A fair value gap on its own is a rectangle, not a trade. What  |
//|   makes it tradable is the company it keeps: the structure break |
//|   that says which way the higher timeframe is going, the order   |
//|   block that says where that move came from, and a lower-        |
//|   timeframe break that says the retracement into it is over.     |
//|   This engine produces all four from one pass over one set of    |
//|   bars, so they cannot disagree with each other.                 |
//|                                                                  |
//| THE THREE-CANDLE GAP                                             |
//|   A bullish FVG is a hole in the delivery: candle 3 never traded |
//|   down to candle 1, so the range between them was skipped. Price |
//|   returning to it is the market finishing business it left       |
//|   undone. Bearish is the mirror image.                           |
//|                                                                  |
//|       c1      c2      c3                                         |
//|        |              |      top    = low of c3                  |
//|        |     ####     |      bottom = high of c1                 |
//|        |     ####     |      (#### = the gap - unfilled)         |
//|                                                                  |
//| STRUCTURE                                                        |
//|   A swing needs `fractal` closed bars either side, so it is only |
//|   examined once it can no longer change. A CLOSE beyond the      |
//|   newest unbroken swing is a break: BOS when it continues the    |
//|   prevailing direction, CHoCH when it reverses it. The swing is  |
//|   then consumed - the next break needs the next swing, so one    |
//|   level cannot report the same break twice.                      |
//|                                                                  |
//| ORDER BLOCKS                                                     |
//|   The last opposite-colour candle before the leg that broke      |
//|   structure. Not every down candle is an order block; the one    |
//|   standing at the origin of a structural break is.               |
//|                                                                  |
//| NOTHING HERE REPAINTS                                            |
//|   Every pattern needs CLOSED bars, so a zone can appear one bar  |
//|   late but never moves or vanishes once drawn. The one value     |
//|   that tracks the live bar is a zone fill percentage, and that   |
//|   is monotone: price can trade further into a gap, never back    |
//|   out of one.                                                    |
//|                                                                  |
//| Shares HullTrendSR.mqh for timeframe resolution and formatting   |
//| rather than reimplementing them: the HTF a chart resolves to has |
//| to be the SAME answer everywhere in this suite, and a second     |
//| copy of SRPickHTF is exactly how that stops being true.          |
//+------------------------------------------------------------------+
#ifndef HULLTREND_FVG_MQH
#define HULLTREND_FVG_MQH

#include <HullTrendSR.mqh>   // SRPickHTF / SRTFName / SRFormatDist / SRFormatAge

//--- How far back from a structure break the origin candle is hunted. Past
//--- this, "the last opposite candle before the move" is no longer before the
//--- move in any sense a trader would recognise.
#define FVG_OB_SEARCH 30

//--- Trigger-arrow clearance from the bar, in ATR. Same convention as the flip
//--- arrows in HullTrend_MT5.mq5: a flat point offset is invisible on an index
//--- CFD and enormous on a JPY cross.
#define FVG_ARROW_OFF_ATR 0.6

//+------------------------------------------------------------------+
//| What a zone is. Both kinds mean "price should not have left this |
//| behind" - they differ only in what evidence says so.             |
//+------------------------------------------------------------------+
enum ENUM_FVG_KIND
  {
   FVG_KIND_GAP = 0,   // three-candle imbalance
   FVG_KIND_OB  = 1    // order block: origin of a structure break
  };

//+------------------------------------------------------------------+
//| How far the setup has progressed. The states are ordered, so a   |
//| consumer can compare them.                                       |
//+------------------------------------------------------------------+
enum ENUM_FVG_STATE
  {
   FVG_STATE_NONE    = 0, // no HTF direction, or no zone to trade into
   FVG_STATE_WAIT    = 1, // a direction and a zone, but price is away from it
   FVG_STATE_INZONE  = 2, // price is inside the zone - waiting for the trigger
   FVG_STATE_TRIGGER = 3  // chart-TF break in the HTF direction: the entry
  };

//+------------------------------------------------------------------+
//| One zone                                                         |
//+------------------------------------------------------------------+
struct FVGZone
  {
   ENUM_FVG_KIND     kind;     // gap or order block
   int               dir;      // +1 bullish (demand - price returns DOWN into it)
                               // -1 bearish (supply - price returns UP into it)
   double            top;      // upper edge
   double            bottom;   // lower edge
   datetime          time;     // the bar that COMPLETED the pattern
   datetime          origin;   // first bar of the pattern - the box left edge
   double            fill;     // 0..1, how much of it price has traded back into
   int               age;      // HTF bars since `time`

   //--- Half the zone: half the gap filled, half of it still owed. The classic
   //--- limit inside an imbalance. Derived on demand so it can never go stale
   //--- against the edges it is derived from.
   double            mid()  const { return((top + bottom) * 0.5); }
   double            size() const { return(top - bottom); }
   bool              holds(const double p) const { return(p <= top && p >= bottom); }
  };

//+------------------------------------------------------------------+
//| One structure break                                              |
//+------------------------------------------------------------------+
struct FVGBreak
  {
   double            level;     // the swing that was broken
   datetime          swing;     // when that swing formed
   datetime          time;      // the bar whose CLOSE broke it
   int               dir;       // +1 broke a high, -1 broke a low
   bool              choch;     // it reversed the prevailing direction
  };

//+------------------------------------------------------------------+
//| Everything the structure pass concludes that is not a break.     |
//|                                                                  |
//| refHigh / refLow are the swings still standing when the scan     |
//| ends - the untaken liquidity on each side. That is where a move  |
//| in this direction is actually headed, and therefore where the    |
//| target belongs.                                                  |
//+------------------------------------------------------------------+
struct FVGBias
  {
   int               dir;       // +1 / -1 / 0 (nothing broke inside the window)
   datetime          time;      // the break that set it
   bool              choch;     // that break was a change of character
   double            level;     // the level it broke
   double            refHigh;   // nearest unbroken swing high (0 = none)
   double            refLow;    // nearest unbroken swing low  (0 = none)
   int               found;     // zones detected, before the filters
   int               dropped;   // zones dropped as mitigated

                     FVGBias()
     {
      dir = 0; time = 0; choch = false; level = 0.0;
      refHigh = 0.0; refLow = 0.0; found = 0; dropped = 0;
     }
  };

//+------------------------------------------------------------------+
//| The trade the picture adds up to.                                |
//+------------------------------------------------------------------+
struct FVGSetup
  {
   ENUM_FVG_STATE    state;
   int               dir;       // direction of the setup (= the HTF bias)
   int               zone;      // index into the zone array (-1 = none)
   double            entry;     // close of the trigger bar
   double            sl;        // beyond the far edge of the zone
   double            tp;        // the liquidity the move is headed for
   double            rr;        // reward : risk, 0 when undefined
   datetime          time;      // the chart bar that triggered
   datetime          zoneTime;  // the zone it triggered from

                     FVGSetup()
     {
      state = FVG_STATE_NONE; dir = 0; zone = -1;
      entry = 0.0; sl = 0.0; tp = 0.0; rr = 0.0; time = 0; zoneTime = 0;
     }
  };

//+------------------------------------------------------------------+
//| How to build the zone set. A consumer fills this from its own    |
//| inputs; identical values must produce identical zones.           |
//+------------------------------------------------------------------+
struct FVGConfig
  {
   int               lookback;      // HTF bars scanned
   int               maxAgeBars;    // drop zones older than this many HTF bars
   double            minGapATR;     // a gap must be at least this x HTF ATR
   int               fractal;       // closed bars each side of an HTF swing
   bool              useGaps;       // detect three-candle imbalances
   bool              useOB;         // detect order blocks
   bool              obBodyOnly;    // the OB box is the body, not the full range
   double            mitigatedPct;  // retire a zone once this much of it is filled
   int               maxPerSide;    // keep at most N zones per direction
   int               entryFractal;  // closed bars each side of a CHART-TF swing
   int               armBars;       // chart bars a visit to the zone stays live

                     FVGConfig()
     {
      lookback     = 180;
      maxAgeBars   = 0;      // 0 = the whole lookback
      minGapATR    = 0.25;
      fractal      = 2;
      useGaps      = true;
      useOB        = true;
      obBodyOnly   = false;
      mitigatedPct = 100.0;
      maxPerSide   = 4;
      entryFractal = 2;
      armBars      = 12;
     }
  };

//+------------------------------------------------------------------+
//| The clamps the engine applies, exposed so a consumer can log the |
//| numbers it will ACTUALLY run with instead of the raw inputs. The |
//| engine calls these too - one definition, no drift.               |
//+------------------------------------------------------------------+
int    FVGScanBars(const int lookback) { return(lookback < 40 ? 40 : lookback); }
int    FVGFractal(const int k)         { return(k < 1 ? 1 : k); }
int    FVGArmBars(const int n)         { return(n < 1 ? 1 : n); }

double FVGMitigated(const double pct)
  {
   const double p = (pct < 1.0 ? 1.0 : (pct > 100.0 ? 100.0 : pct));
   return(p / 100.0);
  }

//--- How many bars back the scan really reaches: the lookback and the age
//--- cutoff, whichever bites first. Counted in BARS, never in seconds - a
//--- calendar window silently loses every weekend and session break inside it.
int FVGScanDepth(const FVGConfig &cfg)
  {
   const int bars = FVGScanBars(cfg.lookback);
   const int age  = (cfg.maxAgeBars > 0 ? cfg.maxAgeBars : bars);
   return((int)MathMin(bars, age));
  }

//+------------------------------------------------------------------+
//| How to draw it. Defaulted in a constructor, like SRStyle, so     |
//| that adding a field here cannot silently feed garbage to a       |
//| caller written before it existed.                                |
//+------------------------------------------------------------------+
struct FVGStyle
  {
   color             bull;         // demand zone edge
   color             bear;         // supply zone edge
   color             bullFill;     // demand zone body
   color             bearFill;     // supply zone body
   color             obBull;       // bullish order block edge
   color             obBear;       // bearish order block edge
   color             structure;    // BOS / CHoCH markers
   bool              showMid;      // dotted 50% line inside each zone
   bool              labels;       // text beside each zone
   bool              showBreaks;   // BOS / CHoCH markers at all
   int               maxBreaks;    // how many of them (0 = all)
   int               fontSize;
   int               rightPad;     // chart bars a zone extends past the last bar
   bool              showSetup;    // arrow and SL/TP lines for the live setup
   bool              panel;
   ENUM_BASE_CORNER  panelCorner;
   int               panelX;
   int               panelY;
   color             panelText;
   color             panelBg;

                     FVGStyle()
     {
      bull        = clrMediumSeaGreen;
      bear        = clrTomato;
      bullFill    = C'18,46,34';
      bearFill    = C'62,26,26';
      obBull      = clrSteelBlue;
      obBear      = clrOrchid;
      structure   = clrGoldenrod;
      showMid     = true;
      labels      = true;
      showBreaks  = true;
      maxBreaks   = 4;
      fontSize    = 8;
      rightPad    = 8;
      showSetup   = true;
      panel       = true;
      panelCorner = CORNER_LEFT_UPPER;
      panelX      = 12;
      panelY      = 22;
      panelText   = clrSilver;
      panelBg     = C'22,26,34';
     }
  };

//+==================================================================+
//| DETECTION                                                        |
//+==================================================================+

//--- A swing needs to beat its neighbours on BOTH sides, strictly, exactly the
//--- way SRCollect defines a pivot. Strict on both sides means a double top
//--- produces no swing at all, which is the honest answer: neither candle is
//--- the turn.
bool FVGSwingHigh(const MqlRates &r[], const int s, const int k)
  {
   for(int j = 1; j <= k; j++)
      if(r[s].high <= r[s - j].high || r[s].high <= r[s + j].high)
         return(false);
   return(true);
  }

bool FVGSwingLow(const MqlRates &r[], const int s, const int k)
  {
   for(int j = 1; j <= k; j++)
      if(r[s].low >= r[s - j].low || r[s].low >= r[s + j].low)
         return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Running extremes of everything NEWER than each shift.            |
//|                                                                  |
//| minLow[i] / maxHigh[i] cover shifts 0..i inclusive, so the       |
//| extreme of everything that happened AFTER the bar at shift i is  |
//| the entry at i - 1. Precomputing this turns the "has price come  |
//| back into this zone" test from a scan per zone into a lookup,    |
//| which is what keeps a 500-bar lookback cheap enough to run on    |
//| every closed bar.                                                |
//|                                                                  |
//| Shift 0 - the forming bar - is deliberately included. A zone     |
//| being tested RIGHT NOW is the single most decision-relevant      |
//| state it can be in, and including it repaints nothing: an        |
//| extreme only ever extends, so a fill percentage can rise within  |
//| a bar but never fall back.                                       |
//+------------------------------------------------------------------+
void FVGRunExtremes(const MqlRates &r[], const int n, double &minLow[], double &maxHigh[])
  {
   ArrayResize(minLow,  n);
   ArrayResize(maxHigh, n);
   if(n < 1)
      return;

   minLow[0]  = r[0].low;
   maxHigh[0] = r[0].high;
   for(int i = 1; i < n; i++)
     {
      minLow[i]  = MathMin(minLow[i - 1],  r[i].low);
      maxHigh[i] = MathMax(maxHigh[i - 1], r[i].high);
     }
  }

//+------------------------------------------------------------------+
//| How much of a zone price has taken back, as 0..1.                |
//|                                                                  |
//| Measured from the edge price approaches FROM: a demand zone is   |
//| eaten downwards from its top, a supply zone upwards from its     |
//| bottom. 1.0 means price traded clean through it.                 |
//+------------------------------------------------------------------+
double FVGFillOf(const double top, const double bottom, const int dir,
                 const int shift, const double &minLow[], const double &maxHigh[])
  {
   const double size = top - bottom;
   if(size <= 0.0 || shift < 1)
      return(0.0);

   const double deep = (dir > 0 ? minLow[shift - 1] : maxHigh[shift - 1]);
   const double into = (dir > 0 ? top - deep : deep - bottom);
   if(into <= 0.0)
      return(0.0);
   return(into >= size ? 1.0 : into / size);
  }

//--- Append, with the derived fields filled in one place so no caller can
//--- forget one. `shift` is the bar the zone completed on, which is also the
//--- zone age in bars, because the series is newest-first.
void FVGAddZone(FVGZone &z[], const ENUM_FVG_KIND kind, const int dir,
                const double top, const double bottom,
                const datetime when, const datetime origin, const int shift,
                const double &minLow[], const double &maxHigh[])
  {
   const int k = ArraySize(z);
   ArrayResize(z, k + 1);
   z[k].kind   = kind;
   z[k].dir    = dir;
   z[k].top    = top;
   z[k].bottom = bottom;
   z[k].time   = when;
   z[k].origin = origin;
   z[k].age    = shift;
   z[k].fill   = FVGFillOf(top, bottom, dir, shift, minLow, maxHigh);
  }

//+------------------------------------------------------------------+
//| Market structure over an already-copied, newest-first series.    |
//|                                                                  |
//| Walks CHRONOLOGICALLY (decreasing shift) because a break is a    |
//| sequence, not a snapshot: whether a close beyond a swing is a    |
//| BOS or a CHoCH depends on what the previous break was, and that  |
//| question has no answer when the bars are read backwards.         |
//|                                                                  |
//| The walk covers every bar available so the direction is already  |
//| established by the time the reporting window opens; only breaks  |
//| INSIDE `scan` are recorded. Breaks come back newest-first.       |
//|                                                                  |
//| `obOut` optionally receives the origin candle of each recorded   |
//| break as an order block. It is produced here, and not in a       |
//| second pass, because it needs the break bar SHIFT - a number     |
//| that means nothing once the array it indexes is gone.            |
//+------------------------------------------------------------------+
bool FVGStructure(FVGBreak &brk[], FVGBias &bias, FVGZone &obOut[],
                  const MqlRates &r[], const int n, const int kIn, const int scan,
                  const bool wantOB, const bool obBodyOnly,
                  const double &minLow[], const double &maxHigh[])
  {
   ArrayResize(brk, 0);
   const int k = FVGFractal(kIn);
   if(n < 4 * k + 4)
      return(false);

   //--- The active references: the newest confirmed swing on each side that
   //--- nothing has closed beyond yet. Consumed on a break, so the next break
   //--- has to wait for the next swing rather than re-reporting this one.
   bool     haveHigh = false, haveLow = false;
   double   refHigh = 0.0, refLow = 0.0;
   datetime refHighT = 0, refLowT = 0;
   int      dir = 0;

   //--- A swing at shift s is only confirmed once k bars to its RIGHT have
   //--- closed, i.e. when the walk reaches shift s - k. Starting the walk at
   //--- n - 1 - 2k is what guarantees the swing test at s = i + k can still
   //--- read k bars on the far side of s without running off the array.
   for(int i = n - 1 - 2 * k; i >= 1; i--)
     {
      const int s = i + k;
      if(FVGSwingHigh(r, s, k))
        {
         refHigh = r[s].high;  refHighT = r[s].time;  haveHigh = true;
        }
      if(FVGSwingLow(r, s, k))
        {
         refLow = r[s].low;    refLowT = r[s].time;   haveLow = true;
        }

      const bool up   = (haveHigh && r[i].close > refHigh);
      const bool down = (haveLow  && r[i].close < refLow);
      if(!up && !down)
         continue;

      //--- A bar wide enough to close beyond BOTH references is one bar, not
      //--- two breaks. Its own body says which side it belongs to.
      int take = 0;
      if(up && down)
         take = (r[i].close >= r[i].open ? +1 : -1);
      else
         take = (up ? +1 : -1);

      const bool     choch = (dir != 0 && dir != take);
      const double   lvl   = (take > 0 ? refHigh : refLow);
      const datetime swt   = (take > 0 ? refHighT : refLowT);

      if(take > 0)
         haveHigh = false;   // consumed
      else
         haveLow = false;
      dir = take;

      if(i > scan)
         continue;           // context only: outside the reporting window

      const int b = ArraySize(brk);
      ArrayResize(brk, b + 1);
      brk[b].level = lvl;
      brk[b].swing = swt;
      brk[b].time  = r[i].time;
      brk[b].dir   = take;
      brk[b].choch = choch;

      bias.dir   = take;
      bias.time  = r[i].time;
      bias.choch = choch;
      bias.level = lvl;

      if(!wantOB)
         continue;

      //--- The order block: walking back from the break bar, the last candle
      //--- that closed AGAINST the break. That is the candle the move away
      //--- from began at, and the one unfilled orders are presumed to sit in.
      for(int j = i + 1; j <= i + FVG_OB_SEARCH && j < n; j++)
        {
         const bool opposite = (take > 0 ? r[j].close < r[j].open
                                         : r[j].close > r[j].open);
         if(!opposite)
            continue;

         //--- Body-only is the tighter reading (the block is where the orders
         //--- were worked, not how far the wick reached). The full range is
         //--- the safer one. Neither is wrong; the input picks.
         const double hi = (obBodyOnly ? MathMax(r[j].open, r[j].close) : r[j].high);
         const double lo = (obBodyOnly ? MathMin(r[j].open, r[j].close) : r[j].low);
         if(hi > lo)
            FVGAddZone(obOut, FVG_KIND_OB, take, hi, lo, r[j].time, r[j].time, j,
                       minLow, maxHigh);
         break;
        }
     }

   //--- Whatever is still standing is untaken liquidity, which is where a move
   //--- in either direction is headed. The target logic reads these.
   bias.refHigh = (haveHigh ? refHigh : 0.0);
   bias.refLow  = (haveLow  ? refLow  : 0.0);

   //--- Recorded chronologically; every consumer wants newest first.
   const int nb = ArraySize(brk);
   for(int a = 0, b = nb - 1; a < b; a++, b--)
     {
      FVGBreak t = brk[a];
      brk[a] = brk[b];
      brk[b] = t;
     }
   return(true);
  }

//--- Newest first, by the bar the zone completed on. Zones arrive from two
//--- passes with different orderings, so one merged ordering has to be imposed
//--- before anything caps "the most recent N". Insertion sort: the arrays are
//--- tens of entries, and it is stable, which keeps a gap and an order block
//--- that formed on the same bar in a predictable order.
void FVGSortZones(FVGZone &z[])
  {
   const int n = ArraySize(z);
   for(int i = 1; i < n; i++)
     {
      const FVGZone key = z[i];
      int j = i - 1;
      while(j >= 0 && z[j].time < key.time)
        {
         z[j + 1] = z[j];
         j--;
        }
      z[j + 1] = key;
     }
  }

//+------------------------------------------------------------------+
//| Scan one timeframe for zones and structure.                      |
//|                                                                  |
//| `atr` sets the minimum-gap scale, and is the CURRENT ATR rather  |
//| than each zone bar's own - the same approximation SRBuild makes  |
//| for its clustering, and for the same reason: a filter that       |
//| changes definition halfway down the chart cannot be reasoned     |
//| about.                                                           |
//|                                                                  |
//| Returns false ONLY when the history could not be read, which a   |
//| caller must not confuse with "nothing found". Acting on the      |
//| empty set in that case wipes a chart that was merely still       |
//| syncing history after an attach.                                 |
//+------------------------------------------------------------------+
bool FVGCollect(FVGZone &zone[], FVGBreak &brk[], FVGBias &bias,
                const string symbol, const ENUM_TIMEFRAMES tf,
                const FVGConfig &cfg, const double atr)
  {
   ArrayResize(zone, 0);
   ArrayResize(brk,  0);
   FVGBias fresh;
   bias = fresh;

   if(atr <= 0.0)
      return(false);

   const int k    = FVGFractal(cfg.fractal);
   const int bars = FVGScanBars(cfg.lookback);
   const int scan = FVGScanDepth(cfg);

   //--- Extra bars beyond the reporting window: the structure walk needs room
   //--- to establish a direction BEFORE the window opens, or the oldest break
   //--- in view is always reported as a BOS whatever preceded it.
   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int need = bars + 4 * k + 8;
   const int n    = CopyRates(symbol, tf, 0, need, r);
   if(n < 4 * k + 8)
      return(false);

   double minLow[], maxHigh[];
   FVGRunExtremes(r, n, minLow, maxHigh);

   //--- Structure first: the order blocks it emits are zones like any other,
   //--- and land in the same array as the gaps.
   FVGZone ob[];
   FVGStructure(brk, bias, ob, r, n, k, scan, cfg.useOB, cfg.obBodyOnly,
                minLow, maxHigh);

   //--- Gaps. Shift 0 is still forming and the newest bar of the triple has to
   //--- be closed, so the scan starts at shift 1 - which is what makes the set
   //--- non-repainting.
   const double minGap = MathMax(0.0, cfg.minGapATR) * atr;
   if(cfg.useGaps)
      for(int i = 1; i + 2 < n; i++)
        {
         //--- `i` IS the bar shift, so the horizon is exact here.
         if(i > scan)
            break;                 // newest-first: everything older follows

         //--- Bullish: the newest candle of the three never traded down to the
         //--- oldest one. The untraded band between them is the gap.
         const double bullTop = r[i].low,  bullBot = r[i + 2].high;
         if(bullTop - bullBot >= minGap && bullTop > bullBot)
            FVGAddZone(zone, FVG_KIND_GAP, +1, bullTop, bullBot,
                       r[i].time, r[i + 2].time, i, minLow, maxHigh);

         const double bearTop = r[i + 2].low, bearBot = r[i].high;
         if(bearTop - bearBot >= minGap && bearTop > bearBot)
            FVGAddZone(zone, FVG_KIND_GAP, -1, bearTop, bearBot,
                       r[i].time, r[i + 2].time, i, minLow, maxHigh);
        }

   //--- Merge the order blocks in, then impose one ordering over both kinds.
   const int nz = ArraySize(zone), no = ArraySize(ob);
   ArrayResize(zone, nz + no);
   for(int i = 0; i < no; i++)
      zone[nz + i] = ob[i];
   FVGSortZones(zone);

   //--- The filters, in one place. `found` is what the patterns produced;
   //--- `dropped` is what mitigation retired - the panel reports both, because
   //--- "no zones" and "every zone already filled" are different markets.
   bias.found = ArraySize(zone);

   const double dead = FVGMitigated(cfg.mitigatedPct);
   const int    cap  = (cfg.maxPerSide > 0 ? cfg.maxPerSide : ArraySize(zone));
   int kept = 0, bull = 0, bear = 0, dropped = 0;
   for(int i = 0; i < ArraySize(zone); i++)
     {
      if(zone[i].age > scan)
         continue;
      if(zone[i].fill >= dead)
        {
         dropped++;
         continue;
        }
      //--- Newest first already, so "the first N of this direction" IS the N
      //--- most recent - no second sort needed.
      if(zone[i].dir > 0)
        {
         if(bull >= cap)
            continue;
         bull++;
        }
      else
        {
         if(bear >= cap)
            continue;
         bear++;
        }
      zone[kept++] = zone[i];
     }
   ArrayResize(zone, kept);
   bias.dropped = dropped;

   return(true);
  }

//+==================================================================+
//| THE SETUP                                                        |
//+==================================================================+

//--- Distance from price to a zone: 0 when price is inside it, and otherwise
//--- the gap to the edge price would reach first. Signed distances would say
//--- which side, but every caller here already knows that from `dir`.
double FVGDistance(const FVGZone &z, const double price)
  {
   if(z.holds(price))
      return(0.0);
   return(price > z.top ? price - z.top : z.bottom - price);
  }

//+------------------------------------------------------------------+
//| Pick the zone to trade into.                                     |
//|                                                                  |
//| Only zones facing the HTF direction qualify - a demand zone is a |
//| place to buy in an uptrend and a place to be wrong in a          |
//| downtrend. Among those, the one price is nearest to, with a zone |
//| price is INSIDE always beating one it merely approaches.         |
//|                                                                  |
//| Returns -1 when nothing qualifies.                               |
//+------------------------------------------------------------------+
int FVGPickZone(const FVGZone &zone[], const int dir, const double price)
  {
   int    best = -1;
   double bestD = 0.0;

   for(int i = 0; i < ArraySize(zone); i++)
     {
      if(zone[i].dir != dir)
         continue;

      //--- A demand zone above price has already done its work - price came
      //--- from below it. Only a zone still ahead of the retracement is a
      //--- place to enter.
      if(dir > 0 && zone[i].bottom > price)
         continue;
      if(dir < 0 && zone[i].top < price)
         continue;

      const double d = FVGDistance(zone[i], price);
      if(best < 0 || d < bestD)
        {
         best  = i;
         bestD = d;
        }
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| Where the move is headed, given it starts at `entry`.            |
//|                                                                  |
//| In order of preference: the near edge of the first opposing zone |
//| in the way (price rarely walks through supply on the first       |
//| attempt), then the untaken swing that is the actual objective,   |
//| then a plain 2R fallback so the number is never blank.           |
//+------------------------------------------------------------------+
double FVGTarget(const FVGZone &zone[], const FVGBias &bias, const int dir,
                 const double entry, const double risk)
  {
   double best = 0.0;

   for(int i = 0; i < ArraySize(zone); i++)
     {
      if(zone[i].dir == dir)
         continue;                          // same side: not an obstacle
      const double edge = (dir > 0 ? zone[i].bottom : zone[i].top);
      if(dir > 0 && edge <= entry)
         continue;
      if(dir < 0 && edge >= entry)
         continue;
      if(best == 0.0 || (dir > 0 ? edge < best : edge > best))
         best = edge;
     }

   const double liq = (dir > 0 ? bias.refHigh : bias.refLow);
   if(liq > 0.0 && (dir > 0 ? liq > entry : liq < entry))
      if(best == 0.0 || (dir > 0 ? liq < best : liq > best))
         best = liq;

   if(best == 0.0 && risk > 0.0)
      best = entry + dir * 2.0 * risk;
   return(best);
  }

//+------------------------------------------------------------------+
//| Score the live setup on the CHART timeframe.                     |
//|                                                                  |
//| The higher timeframe says WHERE and WHICH WAY; it cannot say     |
//| WHEN, because by the time an H4 candle confirms the turn the M15 |
//| move is half over. So the trigger is a chart-timeframe structure |
//| break in the HTF direction, taken while price is in - or has     |
//| just left - the HTF zone.                                        |
//|                                                                  |
//| `armBars` is what "just left" means. Without it, a break three   |
//| days after the last visit to the zone would still be reported as |
//| an entry from that zone.                                         |
//|                                                                  |
//| Returns false only when the chart history could not be read.     |
//+------------------------------------------------------------------+
bool FVGEvaluate(FVGSetup &out, FVGBreak &chartBrk[],
                 const FVGZone &zone[], const FVGBias &bias,
                 const string symbol, const ENUM_TIMEFRAMES chartTF,
                 const FVGConfig &cfg, const double price, const double htfATR)
  {
   FVGSetup fresh;
   out = fresh;
   ArrayResize(chartBrk, 0);

   if(bias.dir == 0 || ArraySize(zone) == 0)
      return(true);

   const int idx = FVGPickZone(zone, bias.dir, price);
   if(idx < 0)
      return(true);

   out.dir      = bias.dir;
   out.zone     = idx;
   out.zoneTime = zone[idx].time;
   out.state    = FVG_STATE_WAIT;

   const int k    = FVGFractal(cfg.entryFractal);
   const int arm  = FVGArmBars(cfg.armBars);
   const int need = arm + 8 * k + 40;

   MqlRates c[];
   ArraySetAsSeries(c, true);
   const int n = CopyRates(symbol, chartTF, 0, need, c);
   if(n < 4 * k + 8)
      return(false);

   //--- Has price been in the zone recently? The live bar counts: a wick into
   //--- the zone on the bar now forming is a visit, and waiting for it to
   //--- close to say so throws away the whole first candle of the reaction.
   bool visited = false;
   for(int i = 0; i <= arm && i < n; i++)
      if(c[i].low <= zone[idx].top && c[i].high >= zone[idx].bottom)
        {
         visited = true;
         break;
        }
   if(zone[idx].holds(price))
      visited = true;

   if(zone[idx].holds(price))
      out.state = FVG_STATE_INZONE;

   //--- Chart-TF structure. Run over the same engine as the HTF pass, so a
   //--- break means the same thing on both: a CLOSE beyond a confirmed swing.
   double minLow[], maxHigh[];
   FVGRunExtremes(c, n, minLow, maxHigh);
   FVGZone unused[];
   FVGBias cbias;
   FVGStructure(chartBrk, cbias, unused, c, n, k, arm + 4 * k, false, false,
                minLow, maxHigh);

   if(!visited || ArraySize(chartBrk) == 0)
      return(true);

   //--- Newest break only. An older one in the right direction has already
   //--- been acted on or already failed; either way it is not this entry.
   if(chartBrk[0].dir != bias.dir)
      return(true);

   const int since = iBarShift(symbol, chartTF, chartBrk[0].time, false);
   if(since < 0 || since > arm)
      return(true);

   out.state = FVG_STATE_TRIGGER;
   out.time  = chartBrk[0].time;
   out.entry = c[since].close;

   //--- The stop goes beyond the zone, not beyond the trigger bar: the zone is
   //--- the reason for the trade, so the zone failing is what makes it wrong.
   //--- The buffer is in HTF ATR because the zone is an HTF object; a chart-TF
   //--- buffer would be invisible against an H4 gap.
   const double buf = 0.25 * htfATR;
   out.sl = (bias.dir > 0 ? zone[idx].bottom - buf : zone[idx].top + buf);

   const double risk = MathAbs(out.entry - out.sl);
   out.tp = FVGTarget(zone, bias, bias.dir, out.entry, risk);
   if(risk > 0.0 && out.tp > 0.0)
      out.rr = MathAbs(out.tp - out.entry) / risk;

   return(true);
  }

//+==================================================================+
//| DRAWING                                                          |
//+==================================================================+
void FVGClear(const long chartId, const string prefix)
  {
   ObjectsDeleteAll(chartId, prefix, -1, -1);
  }

//--- Short tag for a zone: "FVG" or "OB", plus the side. Used in labels, the
//--- panel and the log, so all three call one thing.
string FVGZoneTag(const FVGZone &z)
  {
   const string kind = (z.kind == FVG_KIND_OB ? "OB" : "FVG");
   return(kind + (z.dir > 0 ? "+" : "-"));
  }

string FVGStateName(const ENUM_FVG_STATE s)
  {
   switch(s)
     {
      case FVG_STATE_TRIGGER:
         return("TRIGGER");
      case FVG_STATE_INZONE:
         return("IN ZONE");
      case FVG_STATE_WAIT:
         return("waiting");
      default:
         return("no setup");
     }
  }

//+------------------------------------------------------------------+
//| The zones.                                                       |
//|                                                                  |
//| Each is a box from the bar it formed on to the right edge, so    |
//| the picture shows WHERE the imbalance came from and not just     |
//| that it exists. Filled and sent to the background, because a     |
//| zone is context for the candles, not a thing to read on top of   |
//| them.                                                            |
//|                                                                  |
//| The boxes are drawn at their ORIGINAL edges even when partly     |
//| filled. Shrinking a box to its unfilled remainder is a defensible|
//| convention, but it makes a rectangle move on a chart that        |
//| promises nothing moves, and the fill percentage in the label     |
//| already carries that information without the ambiguity.          |
//+------------------------------------------------------------------+
void FVGDrawZones(const FVGZone &zone[], const long chartId, const string prefix,
                  const string symbol, const ENUM_TIMEFRAMES chartTF,
                  const ENUM_TIMEFRAMES htf, const int activeZone,
                  const FVGStyle &st)
  {
   const int      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const datetime now    = TimeCurrent();
   const datetime right  = now + (datetime)(PeriodSeconds(chartTF) *
                                            (st.rightPad < 1 ? 1 : st.rightPad));

   for(int i = 0; i < ArraySize(zone); i++)
     {
      const bool  bull = (zone[i].dir > 0);
      const bool  isOB = (zone[i].kind == FVG_KIND_OB);
      const color edge = (isOB ? (bull ? st.obBull : st.obBear)
                               : (bull ? st.bull   : st.bear));
      const color body = (bull ? st.bullFill : st.bearFill);
      const bool  live = (i == activeZone);

      const string rn = StringFormat("%sZ%d", prefix, i);
      if(ObjectCreate(chartId, rn, OBJ_RECTANGLE, 0,
                      zone[i].origin, zone[i].top, right, zone[i].bottom))
        {
         ObjectSetInteger(chartId, rn, OBJPROP_COLOR,      edge);
         ObjectSetInteger(chartId, rn, OBJPROP_BGCOLOR,    body);
         ObjectSetInteger(chartId, rn, OBJPROP_FILL,       true);
         ObjectSetInteger(chartId, rn, OBJPROP_BACK,       true);
         ObjectSetInteger(chartId, rn, OBJPROP_STYLE,      (isOB ? STYLE_DOT : STYLE_SOLID));
         ObjectSetInteger(chartId, rn, OBJPROP_WIDTH,      (live ? 2 : 1));
         ObjectSetInteger(chartId, rn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, rn, OBJPROP_HIDDEN,     true);
         ObjectSetString(chartId, rn, OBJPROP_TOOLTIP,
                         StringFormat("%s %s  %s\n%s - %s   (%s wide)\n"
                                      "%.0f%% filled   %d %s bars old%s",
                                      SRTFName(htf), FVGZoneTag(zone[i]),
                                      (isOB ? "order block" : "fair value gap"),
                                      DoubleToString(zone[i].bottom, digits),
                                      DoubleToString(zone[i].top, digits),
                                      SRFormatDist(symbol, zone[i].size()),
                                      zone[i].fill * 100.0, zone[i].age,
                                      SRTFName(htf),
                                      (live ? "\nACTIVE - the setup zone" : "")));
        }

      //--- The 50% line. Half the imbalance repaired is where a limit order
      //--- inside one of these conventionally sits, and the eye cannot find it
      //--- in a filled box without help.
      if(st.showMid && !isOB)
        {
         const string mn = StringFormat("%sM%d", prefix, i);
         if(ObjectCreate(chartId, mn, OBJ_TREND, 0,
                         zone[i].origin, zone[i].mid(), right, zone[i].mid()))
           {
            ObjectSetInteger(chartId, mn, OBJPROP_COLOR,      edge);
            ObjectSetInteger(chartId, mn, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chartId, mn, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chartId, mn, OBJPROP_RAY_RIGHT,  false);
            ObjectSetInteger(chartId, mn, OBJPROP_RAY_LEFT,   false);
            ObjectSetInteger(chartId, mn, OBJPROP_BACK,       true);
            ObjectSetInteger(chartId, mn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(chartId, mn, OBJPROP_HIDDEN,     true);
           }
        }

      if(!st.labels)
         continue;

      //--- Label at the right edge, on the outside of the zone, so it never
      //--- covers the candles that are about to test it.
      const string tn  = StringFormat("%sZT%d", prefix, i);
      const string txt = StringFormat("%s %s  %.0f%%%s", SRTFName(htf),
                                      FVGZoneTag(zone[i]), zone[i].fill * 100.0,
                                      (live ? "  <" : ""));
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0, right, (bull ? zone[i].bottom : zone[i].top)))
        {
         ObjectSetString(chartId, tn, OBJPROP_TEXT,       txt);
         ObjectSetInteger(chartId, tn, OBJPROP_COLOR,     edge);
         ObjectSetInteger(chartId, tn, OBJPROP_FONTSIZE,  st.fontSize);
         ObjectSetInteger(chartId, tn, OBJPROP_ANCHOR,
                          (bull ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER));
         ObjectSetInteger(chartId, tn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, tn, OBJPROP_HIDDEN,     true);
        }
     }
  }

//+------------------------------------------------------------------+
//| The structure breaks.                                            |
//|                                                                  |
//| A segment from the swing that was broken to the bar that broke   |
//| it, labelled BOS or CHoCH. The segment is the point: it shows    |
//| WHICH level gave way and how long it held, which a marker on the |
//| break bar alone cannot.                                          |
//+------------------------------------------------------------------+
void FVGDrawBreaks(const FVGBreak &brk[], const long chartId, const string prefix,
                   const string tag, const color col, const FVGStyle &st)
  {
   const int total = ArraySize(brk);
   const int n     = (st.maxBreaks > 0 ? (int)MathMin(st.maxBreaks, total) : total);

   for(int i = 0; i < n; i++)
     {
      const string ln = StringFormat("%s%sB%d", prefix, tag, i);
      if(ObjectCreate(chartId, ln, OBJ_TREND, 0,
                      brk[i].swing, brk[i].level, brk[i].time, brk[i].level))
        {
         ObjectSetInteger(chartId, ln, OBJPROP_COLOR,      col);
         ObjectSetInteger(chartId, ln, OBJPROP_STYLE,      STYLE_DASH);
         ObjectSetInteger(chartId, ln, OBJPROP_WIDTH,      1);
         ObjectSetInteger(chartId, ln, OBJPROP_RAY_RIGHT,  false);
         ObjectSetInteger(chartId, ln, OBJPROP_RAY_LEFT,   false);
         ObjectSetInteger(chartId, ln, OBJPROP_BACK,       false);
         ObjectSetInteger(chartId, ln, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, ln, OBJPROP_HIDDEN,     true);
        }

      const string tn = StringFormat("%s%sBT%d", prefix, tag, i);
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0, brk[i].time, brk[i].level))
        {
         ObjectSetString(chartId, tn, OBJPROP_TEXT,
                         StringFormat(" %s %s", tag, (brk[i].choch ? "CHoCH" : "BOS")));
         ObjectSetInteger(chartId, tn, OBJPROP_COLOR,     col);
         ObjectSetInteger(chartId, tn, OBJPROP_FONTSIZE,  st.fontSize);
         ObjectSetInteger(chartId, tn, OBJPROP_ANCHOR,
                          (brk[i].dir > 0 ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER));
         ObjectSetInteger(chartId, tn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, tn, OBJPROP_HIDDEN,     true);
        }
     }
  }

//+------------------------------------------------------------------+
//| The live setup: the trigger arrow, and the two prices that       |
//| decide whether taking it was worth it.                           |
//+------------------------------------------------------------------+
void FVGDrawSetup(const FVGSetup &su, const long chartId, const string prefix,
                  const string symbol, const ENUM_TIMEFRAMES chartTF,
                  const double atr, const FVGStyle &st)
  {
   if(!st.showSetup || su.state != FVG_STATE_TRIGGER || su.time == 0)
      return;

   const bool   bull   = (su.dir > 0);
   const color  col    = (bull ? st.bull : st.bear);
   const int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double off    = (atr > 0.0 ? atr * FVG_ARROW_OFF_ATR : 0.0);
   const double at     = (bull ? su.entry - off : su.entry + off);

   const string an = prefix + "SUA";
   if(ObjectCreate(chartId, an, OBJ_ARROW, 0, su.time, at))
     {
      ObjectSetInteger(chartId, an, OBJPROP_ARROWCODE, (bull ? 233 : 234));
      ObjectSetInteger(chartId, an, OBJPROP_COLOR,     col);
      ObjectSetInteger(chartId, an, OBJPROP_WIDTH,     3);
      ObjectSetInteger(chartId, an, OBJPROP_ANCHOR,    (bull ? ANCHOR_TOP : ANCHOR_BOTTOM));
      ObjectSetInteger(chartId, an, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(chartId, an, OBJPROP_HIDDEN,     true);
      ObjectSetString(chartId, an, OBJPROP_TOOLTIP,
                      StringFormat("%s entry  %s\nSL %s   TP %s   %.2fR",
                                   (bull ? "Long" : "Short"),
                                   DoubleToString(su.entry, digits),
                                   DoubleToString(su.sl, digits),
                                   DoubleToString(su.tp, digits), su.rr));
     }

   //--- Stop and target as rays from the trigger bar. Rays, because the levels
   //--- stay relevant for as long as the trade does.
   const int    rows = 2;
   double       px[2];
   string       tag[2];
   color        cl[2];
   px[0]  = su.sl;   tag[0] = "SL";  cl[0] = clrIndianRed;
   px[1]  = su.tp;   tag[1] = "TP";  cl[1] = clrMediumSeaGreen;

   for(int i = 0; i < rows; i++)
     {
      if(px[i] <= 0.0)
         continue;

      const string ln = StringFormat("%sSU%s", prefix, tag[i]);
      if(ObjectCreate(chartId, ln, OBJ_TREND, 0, su.time, px[i],
                      su.time + (datetime)PeriodSeconds(chartTF), px[i]))
        {
         ObjectSetInteger(chartId, ln, OBJPROP_COLOR,      cl[i]);
         ObjectSetInteger(chartId, ln, OBJPROP_STYLE,      STYLE_DOT);
         ObjectSetInteger(chartId, ln, OBJPROP_WIDTH,      1);
         ObjectSetInteger(chartId, ln, OBJPROP_RAY_RIGHT,  true);
         ObjectSetInteger(chartId, ln, OBJPROP_RAY_LEFT,   false);
         ObjectSetInteger(chartId, ln, OBJPROP_BACK,       false);
         ObjectSetInteger(chartId, ln, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, ln, OBJPROP_HIDDEN,     true);
        }

      const string tn = StringFormat("%sSU%sT", prefix, tag[i]);
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0, su.time, px[i]))
        {
         ObjectSetString(chartId, tn, OBJPROP_TEXT,
                         StringFormat(" %s %s", tag[i], DoubleToString(px[i], digits)));
         ObjectSetInteger(chartId, tn, OBJPROP_COLOR,      cl[i]);
         ObjectSetInteger(chartId, tn, OBJPROP_FONTSIZE,   st.fontSize);
         ObjectSetInteger(chartId, tn, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chartId, tn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, tn, OBJPROP_HIDDEN,     true);
        }
     }
  }

//+------------------------------------------------------------------+
//| Everything, in the order the objects have to be created: the     |
//| clear takes the whole prefix with it, so it happens ONCE, here,  |
//| and never inside one of the pieces.                              |
//+------------------------------------------------------------------+
void FVGDraw(const FVGZone &zone[], const FVGBreak &htfBrk[], const FVGBreak &chartBrk[],
             const FVGSetup &su, const long chartId, const string prefix,
             const string symbol, const ENUM_TIMEFRAMES chartTF,
             const ENUM_TIMEFRAMES htf, const double atr, const FVGStyle &st)
  {
   FVGClear(chartId, prefix);

   FVGDrawZones(zone, chartId, prefix, symbol, chartTF, htf, su.zone, st);

   if(st.showBreaks)
     {
      FVGDrawBreaks(htfBrk,   chartId, prefix, SRTFName(htf),     st.structure, st);
      FVGDrawBreaks(chartBrk, chartId, prefix, SRTFName(chartTF), st.structure, st);
     }

   FVGDrawSetup(su, chartId, prefix, symbol, chartTF, atr, st);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void FVGPanelLine(const long chartId, const string name, const FVGStyle &st,
                  const int row, const string text, const color col)
  {
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
//| The summary panel.                                               |
//|                                                                  |
//| The boxes answer "what is that rectangle?". They cannot answer   |
//| the question actually asked before a trade - which way, into     |
//| which zone, how far away is it and what does the trade pay -     |
//| because that answer lives in the relationship between the HTF    |
//| direction, one zone and the current price. No single label can   |
//| hold it. This block can.                                         |
//|                                                                  |
//| Call it AFTER FVGDraw: that function clears the whole prefix.    |
//+------------------------------------------------------------------+
void FVGDrawPanel(const FVGZone &zone[], const FVGBias &bias, const FVGSetup &su,
                  const long chartId, const string prefix, const string symbol,
                  const ENUM_TIMEFRAMES chartTF, const ENUM_TIMEFRAMES htf,
                  const double price, const double atr, const FVGStyle &st)
  {
   if(!st.panel)
      return;

   const int      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const datetime now    = TimeCurrent();
   const int      rows   = 6;
   string ln[6];
   color  cl[6];

   int bull = 0, bear = 0;
   for(int i = 0; i < ArraySize(zone); i++)
      if(zone[i].dir > 0)
         bull++;
      else
         bear++;

   //--- The ATR is named, not just printed: every distance below is quoted in
   //--- the HIGHER timeframe ATR, because that is the ruler the zones and the
   //--- stop buffer are built with, and an unlabelled ATR on a chart showing
   //--- two timeframes is a number nobody can act on.
   ln[0] = StringFormat("HULL FVG   %s   %s zones on %s   %s ATR %s",
                        symbol, SRTFName(htf), SRTFName(chartTF),
                        SRTFName(htf), SRFormatDist(symbol, atr));
   cl[0] = st.panelText;

   //--- The bias line names the break that set it, because "bullish" with no
   //--- date is an opinion and "bullish since the CHoCH at 12:00" is a fact
   //--- that can be checked against the chart.
   if(bias.dir != 0)
     {
      ln[1] = StringFormat("bias  %-7s  %s %s at %s  (%s ago)",
                           (bias.dir > 0 ? "BULLISH" : "BEARISH"),
                           SRTFName(htf), (bias.choch ? "CHoCH" : "BOS"),
                           DoubleToString(bias.level, digits),
                           SRFormatAge(bias.time, now));
      cl[1] = (bias.dir > 0 ? st.bull : st.bear);
     }
   else
     {
      ln[1] = StringFormat("bias  none - nothing broke %s structure inside the lookback",
                           SRTFName(htf));
      cl[1] = st.panelText;
     }

   if(su.zone >= 0 && su.zone < ArraySize(zone))
     {
      const FVGZone z = zone[su.zone];
      const double  d = FVGDistance(z, price);
      ln[2] = StringFormat("zone  %-5s %s - %s   %.0f%% filled   %s away  (%.2f ATR)",
                           FVGZoneTag(z),
                           DoubleToString(z.bottom, digits),
                           DoubleToString(z.top, digits),
                           z.fill * 100.0,
                           (d <= 0.0 ? "INSIDE" : SRFormatDist(symbol, d)),
                           (atr > 0.0 ? d / atr : 0.0));
      cl[2] = (z.dir > 0 ? st.bull : st.bear);
     }
   else
     {
      ln[2] = "zone  no unmitigated zone on the bias side of price";
      cl[2] = st.panelText;
     }

   ln[3] = StringFormat("state %s", FVGStateName(su.state));
   cl[3] = (su.state == FVG_STATE_TRIGGER ? (su.dir > 0 ? st.bull : st.bear)
            : st.panelText);

   if(su.state == FVG_STATE_TRIGGER)
     {
      ln[4] = StringFormat("trade %s  entry %s  SL %s  TP %s  %.2fR",
                           (su.dir > 0 ? "LONG " : "SHORT"),
                           DoubleToString(su.entry, digits),
                           DoubleToString(su.sl, digits),
                           DoubleToString(su.tp, digits), su.rr);
      cl[4] = (su.rr >= 2.0 ? clrMediumSeaGreen : st.panelText);
     }
   else
     {
      //--- What the setup is waiting FOR, not just that it is waiting. The
      //--- difference between "price has not arrived" and "price is here but
      //--- the entry timeframe has not turned" is the difference between
      //--- walking away and watching closely.
      ln[4] = (su.state == FVG_STATE_INZONE
               ? StringFormat("trade waiting for a %s %s in the zone",
                              SRTFName(chartTF), (su.dir > 0 ? "bullish break" : "bearish break"))
               : "trade waiting for price to reach the zone");
      cl[4] = st.panelText;
     }

   ln[5] = StringFormat("zones %d bull, %d bear drawn   (%d found, %d mitigated)",
                        bull, bear, bias.found, bias.dropped);
   cl[5] = st.panelText;

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
      FVGPanelLine(chartId, StringFormat("%sP%d", prefix, i), st, i, ln[i], cl[i]);
  }

//+==================================================================+
//| LOG                                                              |
//+==================================================================+

//+------------------------------------------------------------------+
//| Human-readable print of what the scan found.                     |
//|                                                                  |
//| One line per zone, "HullFVG | ZONE | ...", so the Experts tab    |
//| can be pasted and read back the way the EA log is. The header    |
//| carries the bias, because a zone list with no direction beside   |
//| it is half the information.                                      |
//+------------------------------------------------------------------+
void FVGPrintRecent(const FVGZone &zone[], const FVGBreak &brk[], const FVGBias &bias,
                    const FVGSetup &su, const string symbol,
                    const ENUM_TIMEFRAMES chartTF, const ENUM_TIMEFRAMES htf,
                    const double price, const double atr, const int maxLines)
  {
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const int total  = ArraySize(zone);

   PrintFormat("HullFVG | LIST | %s %s zones on %s: %d live, %d mitigated  |  "
               "bias %s%s",
               symbol, SRTFName(htf), SRTFName(chartTF), total, bias.dropped,
               (bias.dir == 0 ? "none" : (bias.dir > 0 ? "BULLISH" : "BEARISH")),
               (bias.dir == 0 ? ""
                : StringFormat(" since the %s %s at %s",
                               SRTFName(htf), (bias.choch ? "CHoCH" : "BOS"),
                               TimeToString(bias.time, TIME_DATE | TIME_MINUTES))));

   const int n = (maxLines > 0 ? (int)MathMin(maxLines, total) : total);
   for(int i = 0; i < n; i++)
     {
      const double d = FVGDistance(zone[i], price);
      PrintFormat("HullFVG | ZONE | %s | %-5s %s - %s  %s wide  %3.0f%% filled  "
                  "%s away  %d %s bars ago",
                  TimeToString(zone[i].time, TIME_DATE | TIME_MINUTES),
                  FVGZoneTag(zone[i]),
                  DoubleToString(zone[i].bottom, digits),
                  DoubleToString(zone[i].top, digits),
                  SRFormatDist(symbol, zone[i].size()),
                  zone[i].fill * 100.0,
                  (d <= 0.0 ? "INSIDE" : SRFormatDist(symbol, d)),
                  zone[i].age, SRTFName(htf));
     }
   if(total > n)
      PrintFormat("HullFVG | ZONE | ... and %d more, newest shown first", total - n);

   const int nb = ArraySize(brk);
   const int mb = (maxLines > 0 ? (int)MathMin(maxLines, nb) : nb);
   for(int i = 0; i < mb; i++)
      PrintFormat("HullFVG | %-5s | %s | %s broke %s formed %s",
                  (brk[i].choch ? "CHoCH" : "BOS"),
                  TimeToString(brk[i].time, TIME_DATE | TIME_MINUTES),
                  (brk[i].dir > 0 ? "up  " : "down"),
                  DoubleToString(brk[i].level, digits),
                  TimeToString(brk[i].swing, TIME_DATE | TIME_MINUTES));

   if(su.state == FVG_STATE_TRIGGER)
      PrintFormat("HullFVG | SETUP | %s | %s  entry %s  SL %s  TP %s  %.2fR",
                  TimeToString(su.time, TIME_DATE | TIME_MINUTES),
                  (su.dir > 0 ? "LONG" : "SHORT"),
                  DoubleToString(su.entry, digits),
                  DoubleToString(su.sl, digits),
                  DoubleToString(su.tp, digits), su.rr);
   else
      PrintFormat("HullFVG | SETUP | %s%s", FVGStateName(su.state),
                  (atr > 0.0 && su.zone >= 0 && su.zone < total
                   ? StringFormat("  -  zone %.2f ATR away",
                                  FVGDistance(zone[su.zone], price) / atr)
                   : ""));
  }

#endif // HULLTREND_FVG_MQH
//+------------------------------------------------------------------+
