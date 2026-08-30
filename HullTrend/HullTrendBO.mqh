//+------------------------------------------------------------------+
//|                                                   HullTrendBO.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Shared range-breakout engine.                                    |
//|                                                                  |
//| ONE copy of the detection, any number of consumers:              |
//|   HullTrendBO_MT5.mq5 - marks the most recent breakouts on a     |
//|                         chosen timeframe and prints them.        |
//|                                                                  |
//| WHAT A BREAKOUT IS HERE                                          |
//|   A bar that CLOSES clear of the range that contained it. The    |
//|   range is the `rangeBars` bars immediately before that bar, so  |
//|   the level being broken is defined entirely by history and the  |
//|   breaking bar can never be part of the level it breaks.         |
//|                                                                  |
//|        <---- rangeBars ---->                                     |
//|      ______________________                                      |
//|     |                      |          close                      |
//|     |      the range       |            |                        |
//|     |______________________|___________ | ___ level (range high) |
//|                                        \|/                       |
//|                                     the breakout bar             |
//|                                                                  |
//| THIS IS THE MIRROR OF HullTrendLG.mqh                            |
//|   A liquidity grab pierces a level and closes back INSIDE: the   |
//|   breakout failed. This engine records the bar that closes       |
//|   OUTSIDE and stays there. Same geometry, opposite verdict, and  |
//|   the two together read as one picture: which levels gave way    |
//|   and which ones only pretended to.                              |
//|                                                                  |
//| ONE BREAKOUT PER MOVE                                            |
//|   In a trend every bar closes above a rolling range high, so a   |
//|   naive detector reports forty breakouts for one move. A         |
//|   direction is ARMED once, spends itself on the break, and is    |
//|   only re-armed when price closes back inside the level it       |
//|   broke. So "three recent breakouts" means three separate        |
//|   moves, not three bars of the same one.                         |
//|                                                                  |
//| IS IT A VALID BREAKOUT? - TWO SEPARATE QUESTIONS                 |
//|                                                                  |
//|   1. THE SCORE, known the moment the bar closes. Four things     |
//|      that are all visible on the breakout bar itself, weighted   |
//|      into 0-100 and graded. This is "does this look like a real  |
//|      break", answerable NOW, which is when the question is       |
//|      actually asked.                                             |
//|                                                                  |
//|   2. THE STATUS, known only later. PENDING until the             |
//|      confirmation window has actually elapsed, then HELD or      |
//|      FAILED. A breakout one bar old is PENDING - reporting it    |
//|      as "held" would be claiming knowledge of bars that have     |
//|      not happened yet.                                           |
//|                                                                  |
//|   Keeping these apart is the whole point. A high score that      |
//|   later FAILS is not a contradiction; it is the market, and a    |
//|   study that hides one behind the other cannot show you that.    |
//|                                                                  |
//| NOTHING HERE REPAINTS                                            |
//|   A breakout needs a CLOSED bar, and both the score and the      |
//|   failure test read closed bars only, so a marker never moves    |
//|   once drawn. The status advances PENDING -> HELD or PENDING ->  |
//|   FAILED exactly once and never goes back. The single value      |
//|   that tracks the live bar is MFE, and that is monotone: a move  |
//|   can extend but never un-extend.                                |
//|                                                                  |
//| Shares HullTrendSR.mqh for timeframe naming and distance         |
//| formatting, the same way HullTrendFVG.mqh does - so a distance   |
//| reads the same in every study in this suite.                     |
//+------------------------------------------------------------------+
#ifndef HULLTREND_BO_MQH
#define HULLTREND_BO_MQH

#include <HullTrendSR.mqh>   // SRTFName / SRFormatDist / SRFormatAge / SRPipSize

//--- Arrow clearance from the breakout bar, in ATR. Same convention as the
//--- flip arrows in HullTrend_MT5.mq5: a flat point offset is invisible on an
//--- index CFD and enormous on a JPY cross.
#define BO_ARROW_OFF_ATR 0.5

//+------------------------------------------------------------------+
//| SCORE CALIBRATION                                                |
//|                                                                  |
//| Four components, each normalised to 0..1 and then weighted. The  |
//| weights sum to 100 and are asserted to in the self-test, so a    |
//| future edit cannot quietly produce scores out of 100 that are    |
//| not out of 100.                                                  |
//|                                                                  |
//| These are constants rather than inputs on purpose. A score is    |
//| only worth anything if it means the same thing on every chart    |
//| it is read from; a per-chart calibration is not a score, it is   |
//| a second opinion. What IS an input is `minScore` - the bar you   |
//| hold breakouts to - which is a judgement, not a definition.      |
//+------------------------------------------------------------------+
#define BO_W_PUSH       30    // how far past the level it closed
#define BO_W_CLOSE      30    // where in its own bar that close sat
#define BO_W_COMP       20    // how tight the range it left was
#define BO_W_VOL        20    // whether the effort expanded

//--- Full marks for closing this far past the level, in ATR. Beyond half an
//--- ATR the extra distance says little that the first half did not.
#define BO_PUSH_FULL     0.5

//--- Range height, in ATR, for full marks and for none. A break out of a coil
//--- is worth more than the same break out of a wide chop, because in the
//--- chop the "level" was never a level anybody was watching.
#define BO_TIGHT_ATR     1.5
#define BO_LOOSE_ATR     6.0

//--- Full marks when the breakout bar carries this multiple of the range's
//--- average tick volume. Equal to the average scores zero: a break nobody
//--- turned up for is a break nobody has to respect.
#define BO_VOL_FULL      2.0

//--- Grade thresholds. Named because they appear in the panel, the labels and
//--- the log, and those three must never disagree about what "FAIR" means.
#define BO_GRADE_STRONG 75
#define BO_GRADE_FAIR   50
#define BO_GRADE_WEAK   25

//+------------------------------------------------------------------+
//| What happened AFTER the breakout. Ordered so a consumer can      |
//| compare, and deliberately three-valued: "not yet known" is an    |
//| answer, and the two-valued version of this was a bug.            |
//+------------------------------------------------------------------+
enum ENUM_BO_STATUS
  {
   BO_PENDING = 0,   // the confirmation window has not elapsed yet
   BO_HELD    = 1,   // it survived the window without closing back inside
   BO_FAILED  = 2    // it closed back inside the level it broke
  };

//+------------------------------------------------------------------+
//| One breakout                                                     |
//+------------------------------------------------------------------+
struct BOPoint
  {
   double            level;     // the range edge that gave way
   double            close;     // the close that broke it
   datetime          time;      // the breakout bar (already closed)
   datetime          from;      // first bar of the range - the box left edge
   double            rangeHigh; // the range that was broken out of
   double            rangeLow;  //
   int               dir;       // +1 broke the high, -1 broke the low
   double            push;      // how far past the level it closed, price units
   double            mfe;       // best excursion since, from the close, price units
   ENUM_BO_STATUS    status;    // what happened after
   int               age;       // bars since the breakout

   //--- the score, and the four things it is made of, all 0..1 except `score`
   int               score;     // 0..100
   double            pushQ;     // distance past the level
   double            closeQ;    // where the close sat in its own bar
   double            compQ;     // how tight the range was
   double            volQ;      // effort expansion on the breakout bar

   double            height() const { return(rangeHigh - rangeLow); }
   bool              failed() const { return(status == BO_FAILED); }
   bool              pending() const { return(status == BO_PENDING); }
  };

//+------------------------------------------------------------------+
//| How to build the set. A consumer fills this from its own inputs; |
//| identical values must produce identical points.                  |
//+------------------------------------------------------------------+
struct BOConfig
  {
   int               lookback;     // bars scanned on the chosen timeframe
   int               rangeBars;    // bars before each bar that define the range
   double            minBreakATR;  // the close must clear the level by this x ATR
   int               confirmBars;  // bars in which a close back inside = failed
   int               minScore;     // hide breakouts scoring below this (0 = show all)
   int               maxAgeBars;   // drop breakouts older than N bars (0 = lookback)
   int               maxShown;     // keep the most recent N (0 = all)

                     BOConfig()
     {
      lookback    = 300;
      rangeBars   = 20;
      minBreakATR = 0.15;
      confirmBars = 3;
      minScore    = 0;
      maxAgeBars  = 0;
      maxShown    = 3;
     }
  };

//+------------------------------------------------------------------+
//| The clamps the engine applies, exposed so a consumer can log the |
//| numbers it will ACTUALLY run with instead of the raw inputs. The |
//| engine calls these too - one definition, no drift.               |
//+------------------------------------------------------------------+
int BOScanBars(const int lookback)  { return(lookback < 50 ? 50 : lookback); }
int BORangeBars(const int bars)     { return(bars < 2 ? 2 : bars); }
int BOConfirmBars(const int bars)   { return(bars < 0 ? 0 : bars); }
int BOMinScore(const int s)         { return(s < 0 ? 0 : (s > 100 ? 100 : s)); }

//--- How many bars back the scan really reaches: the lookback and the age
//--- cutoff, whichever bites first. Counted in BARS, never in seconds - a
//--- calendar window silently loses every weekend and session break inside it.
int BOScanDepth(const BOConfig &cfg)
  {
   const int bars = BOScanBars(cfg.lookback);
   const int age  = (cfg.maxAgeBars > 0 ? cfg.maxAgeBars : bars);
   return((int)MathMin(bars, age));
  }

//+------------------------------------------------------------------+
//| How to draw it. Defaulted in a constructor, like SRStyle, so     |
//| that adding a field here cannot silently feed garbage to a       |
//| caller written before it existed.                                |
//|                                                                  |
//| THE PALETTE IS DELIBERATELY NOT GREEN / RED.                     |
//|   Every other study in this suite - the trend line, S/R,         |
//|   liquidity grabs, fair value gaps - already ships green for up  |
//|   and red for down. Put two of them on one chart and the arrows  |
//|   become unreadable: the colour no longer says which STUDY drew  |
//|   it, which is the thing you need to know first.                 |
//|                                                                  |
//|   So this one is cyan and yellow, and its arrows are chunky      |
//|   block glyphs rather than the thin 233/234 every other study    |
//|   uses. Direction is carried by the arrow shape, the level line  |
//|   and the label; colour is free to identify the study instead.   |
//|   All of it is an input, so anyone who disagrees can say so in   |
//|   one click.                                                     |
//+------------------------------------------------------------------+
struct BOStyle
  {
   color             up;          // broke the range high
   color             down;        // broke the range low
   color             failed;      // and then closed back inside
   color             range;       // the box body, when filled
   bool              fillRange;   // fill it, or draw the outline only
   bool              showRange;   // draw the range that was broken
   bool              showLevel;   // draw the level that gave way
   bool              extendLevel; // and carry it to the right edge
   bool              labels;      // text beside each marker
   int               arrowUp;     // Wingdings code, upside break
   int               arrowDown;   // Wingdings code, downside break
   int               fontSize;
   bool              panel;
   ENUM_BASE_CORNER  panelCorner;
   int               panelX;
   int               panelY;
   color             panelText;
   color             panelBg;

                     BOStyle()
     {
      up          = clrAqua;
      down        = clrYellow;
      failed      = clrDimGray;
      range       = C'26,30,38';
      fillRange   = false;      // outline only: an FVG zone on the same chart is filled
      showRange   = true;
      showLevel   = true;
      extendLevel = true;
      labels      = true;
      arrowUp     = 241;        // chunky block arrows, not the 233/234 the
      arrowDown   = 242;        // trend and liquidity studies already use
      fontSize    = 8;
      panel       = true;
      panelCorner = CORNER_LEFT_UPPER;
      panelX      = 12;
      panelY      = 22;
      panelText   = clrSilver;
      panelBg     = C'22,26,34';
     }
  };

//+==================================================================+
//| SCORING                                                          |
//+==================================================================+

double BOClamp01(const double v)
  {
   return(v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v));
  }

//+------------------------------------------------------------------+
//| The four components, each answerable from the breakout bar and   |
//| the range behind it - nothing from the future.                   |
//|                                                                  |
//| Split out of the walk so the self-test can drive them directly   |
//| with hand-picked numbers, and so the panel can show the          |
//| breakdown rather than a number nobody can argue with.            |
//+------------------------------------------------------------------+

//--- How decisively it closed past the level.
double BOPushQ(const double push, const double atr)
  {
   if(atr <= 0.0)
      return(0.0);
   return(BOClamp01(push / (BO_PUSH_FULL * atr)));
  }

//--- Where that close sat inside the breakout bar's own range. Closing on the
//--- high of an up-break is conviction; closing mid-bar after a long upper
//--- wick is a bar that broke out and then thought better of it.
double BOCloseQ(const MqlRates &bar, const int dir)
  {
   const double span = bar.high - bar.low;
   if(span <= 0.0)
      return(0.5);            // a bar with no range says nothing either way
   return(BOClamp01(dir > 0 ? (bar.close - bar.low) / span
                            : (bar.high - bar.close) / span));
  }

//--- How tight the range was. A break out of a coil is worth more than the
//--- same break out of a wide chop, where the "level" was never a level.
double BOCompQ(const double height, const double atr)
  {
   if(atr <= 0.0)
      return(0.0);
   const double bars = height / atr;
   return(BOClamp01((BO_LOOSE_ATR - bars) / (BO_LOOSE_ATR - BO_TIGHT_ATR)));
  }

//--- Whether the effort expanded. Tick volume, because it is the one volume
//--- every symbol and every broker actually has.
double BOVolQ(const double barVol, const double avgVol)
  {
   if(avgVol <= 0.0)
      return(0.5);            // no volume data: neither credit nor penalty
   return(BOClamp01((barVol / avgVol - 1.0) / (BO_VOL_FULL - 1.0)));
  }

//--- The weighted total, 0..100.
int BOScoreOf(const double pushQ, const double closeQ,
              const double compQ, const double volQ)
  {
   const double s = BO_W_PUSH  * pushQ + BO_W_CLOSE * closeQ +
                    BO_W_COMP  * compQ + BO_W_VOL   * volQ;
   return((int)MathRound(s));
  }

//--- The grade, in the one place all three consumers read it from.
string BOGrade(const int score)
  {
   if(score >= BO_GRADE_STRONG)
      return("STRONG");
   if(score >= BO_GRADE_FAIR)
      return("FAIR");
   if(score >= BO_GRADE_WEAK)
      return("WEAK");
   return("POOR");
  }

string BOStatusName(const ENUM_BO_STATUS s)
  {
   switch(s)
     {
      case BO_HELD:
         return("held");
      case BO_FAILED:
         return("FAILED");
      default:
         return("PENDING");
     }
  }

//+==================================================================+
//| DETECTION                                                        |
//+==================================================================+

//--- Append, with every derived field filled in one place so that no caller
//--- can forget one.
void BOAdd(BOPoint &bo[], const int dir, const double level, const MqlRates &bar,
           const datetime from, const double rangeHigh, const double rangeLow,
           const int shift, const double avgVol, const double atr)
  {
   const int k = ArraySize(bo);
   ArrayResize(bo, k + 1);
   bo[k].dir       = dir;
   bo[k].level     = level;
   bo[k].close     = bar.close;
   bo[k].time      = bar.time;
   bo[k].from      = from;
   bo[k].rangeHigh = rangeHigh;
   bo[k].rangeLow  = rangeLow;
   bo[k].push      = (dir > 0 ? bar.close - level : level - bar.close);
   bo[k].mfe       = 0.0;
   bo[k].status    = BO_PENDING;
   bo[k].age       = shift;

   bo[k].pushQ  = BOPushQ(bo[k].push, atr);
   bo[k].closeQ = BOCloseQ(bar, dir);
   bo[k].compQ  = BOCompQ(rangeHigh - rangeLow, atr);
   bo[k].volQ   = BOVolQ((double)bar.tick_volume, avgVol);
   bo[k].score  = BOScoreOf(bo[k].pushQ, bo[k].closeQ, bo[k].compQ, bo[k].volQ);
  }

//+------------------------------------------------------------------+
//| Scan a bar series for breakouts, newest first.                   |
//|                                                                  |
//| The walk is CHRONOLOGICAL (decreasing shift) because a breakout  |
//| is a sequence, not a snapshot: whether a close beyond the range  |
//| is a new move or the fortieth bar of an old one depends on what  |
//| already happened, and that question has no answer when the bars  |
//| are read backwards.                                              |
//|                                                                  |
//| `atr` sets the score and filter scales, and is the CURRENT ATR   |
//| rather than each bar's own - the same approximation SRBuild      |
//| makes for its clustering, and for the same reason: a measure     |
//| that changes definition halfway down the chart cannot be         |
//| reasoned about.                                                  |
//|                                                                  |
//| Returns false ONLY when the series was too short to hold a       |
//| range, which a caller must not confuse with "no breakouts        |
//| found". Acting on the empty set in that case wipes a chart that  |
//| was merely still syncing history after an attach.                |
//+------------------------------------------------------------------+
bool BOScan(BOPoint &bo[], const MqlRates &r[], const int n,
            const BOConfig &cfg, const double atr)
  {
   ArrayResize(bo, 0);
   if(atr <= 0.0)
      return(false);

   const int    range    = BORangeBars(cfg.rangeBars);
   const int    confirm  = BOConfirmBars(cfg.confirmBars);
   const int    scan     = BOScanDepth(cfg);
   const double minBreak = MathMax(0.0, cfg.minBreakATR) * atr;

   if(n < range + 3)
      return(false);

   //--- ARMED means "a breakout this way would be a new move". Spent on the
   //--- break, and only restored when price closes back inside the level that
   //--- broke. Both start armed: the first break seen in the window is a real
   //--- one whatever happened before the window opened.
   bool   armedUp = true, armedDown = true;
   double lastUp = 0.0, lastDown = 0.0;

   //--- Shift 0 is still forming and a breakout needs a CLOSED bar, so the
   //--- walk ends at shift 1 - which is what makes the set non-repainting.
   //--- It starts at n - range - 1, the oldest bar that still has a full range
   //--- behind it to break out of.
   for(int i = n - range - 1; i >= 1; i--)
     {
      //--- The range is the bars BEFORE this one, so a bar can never break a
      //--- level that includes its own extreme. The average effort over those
      //--- same bars is collected in the same pass - it is the baseline the
      //--- breakout bar's own volume is judged against.
      double refHigh = r[i + 1].high;
      double refLow  = r[i + 1].low;
      double volSum  = (double)r[i + 1].tick_volume;
      for(int j = i + 2; j <= i + range; j++)
        {
         if(r[j].high > refHigh)
            refHigh = r[j].high;
         if(r[j].low < refLow)
            refLow = r[j].low;
         volSum += (double)r[j].tick_volume;
        }
      const double avgVol = volSum / (double)range;

      //--- Re-arm first: a bar that closes back inside a broken level is
      //--- giving the level back, and cannot also be breaking out that way.
      if(!armedUp && r[i].close < lastUp)
         armedUp = true;
      if(!armedDown && r[i].close > lastDown)
         armedDown = true;

      const bool up   = (r[i].close > refHigh + minBreak);
      const bool down = (r[i].close < refLow  - minBreak);
      if(!up && !down)
         continue;

      //--- A bar that closes clear of BOTH edges is one bar, not two
      //--- breakouts. Its own body says which side it belongs to.
      int take = 0;
      if(up && down)
         take = (r[i].close >= r[i].open ? +1 : -1);
      else
         take = (up ? +1 : -1);

      if(take > 0 && !armedUp)
         continue;                    // still inside the same up move
      if(take < 0 && !armedDown)
         continue;

      const double level = (take > 0 ? refHigh : refLow);
      if(take > 0)
        {
         armedUp = false;
         lastUp  = level;
        }
      else
        {
         armedDown = false;
         lastDown  = level;
        }

      //--- Arming is a running state, so the walk has to cover bars OLDER than
      //--- the reporting window to know whether a break inside it is new. Only
      //--- the ones inside the window are recorded.
      if(i > scan)
         continue;

      BOAdd(bo, take, level, r[i], r[i + range].time, refHigh, refLow, i,
            avgVol, atr);
      const int k = ArraySize(bo) - 1;

      //--- What happened next. The bars are already in the array - they are
      //--- simply at lower shifts than the walk has reached - so the outcome
      //--- is settled here, where the breakout is known, rather than in a
      //--- second pass that would have to re-find it.
      //---
      //--- CLOSED bars only, down to shift 1. Letting the forming bar decide
      //--- would flip a verdict back and forth inside a single bar, which is
      //--- precisely what "non-repainting" rules out.
      const int elapsed = i - 1;                      // closed bars since
      const int stop    = (int)MathMax(1, i - confirm);
      bool      failed  = false;
      for(int j = i - 1; j >= stop; j--)
         if(take > 0 ? r[j].close < level : r[j].close > level)
           {
            failed = true;
            break;
           }

      //--- PENDING is not a placeholder, it is the answer. Calling a breakout
      //--- that is one bar old "held" claims knowledge of bars that have not
      //--- happened yet, and that claim is exactly what a breakout trader
      //--- must not be handed.
      if(failed)
         bo[k].status = BO_FAILED;
      else
         bo[k].status = (elapsed >= confirm ? BO_HELD : BO_PENDING);

      //--- MFE includes the forming bar. A move can extend but never
      //--- un-extend, so this rises within a bar and never falls back.
      double best = r[i].close;
      for(int j = i - 1; j >= 0; j--)
         best = (take > 0 ? MathMax(best, r[j].high) : MathMin(best, r[j].low));
      bo[k].mfe = (take > 0 ? best - r[i].close : r[i].close - best);
     }

   //--- Recorded chronologically; every consumer wants newest first.
   int total = ArraySize(bo);
   for(int a = 0, b = total - 1; a < b; a++, b--)
     {
      BOPoint t = bo[a];
      bo[a] = bo[b];
      bo[b] = t;
     }

   //--- The score filter runs AFTER the walk, never inside it. A weak
   //--- breakout still happened and still spent the arming; hiding it must
   //--- not promote the next bar of the same move into a fresh one.
   const int floor = BOMinScore(cfg.minScore);
   if(floor > 0)
     {
      int kept = 0;
      for(int i = 0; i < total; i++)
         if(bo[i].score >= floor)
            bo[kept++] = bo[i];
      ArrayResize(bo, kept);
      total = kept;
     }

   //--- Newest first already, so "the first N" IS the N most recent.
   if(cfg.maxShown > 0 && total > cfg.maxShown)
      ArrayResize(bo, cfg.maxShown);

   return(true);
  }

//+------------------------------------------------------------------+
//| The same scan, over a timeframe rather than an array.            |
//|                                                                  |
//| Split from BOScan so the walk above can be driven by a           |
//| hand-built bar series with no market data involved - which is    |
//| the only way to assert that a specific bar produces a specific   |
//| breakout with a specific score. A detector that can only be      |
//| checked against live bars can only be checked against whatever   |
//| the market happened to do.                                       |
//|                                                                  |
//| Extra bars beyond the reporting window are fetched on purpose:   |
//| the arming state is a running one, so the walk has to see bars   |
//| OLDER than the window to know whether a break inside it is a new |
//| move or the tail of an old one.                                  |
//+------------------------------------------------------------------+
bool BOCollect(BOPoint &bo[], const string symbol, const ENUM_TIMEFRAMES tf,
               const BOConfig &cfg, const double atr)
  {
   ArrayResize(bo, 0);
   if(atr <= 0.0)
      return(false);

   const int range = BORangeBars(cfg.rangeBars);
   const int bars  = BOScanBars(cfg.lookback);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int n = CopyRates(symbol, tf, 0, bars + range + 2, r);
   if(n < range + 3)
      return(false);

   return(BOScan(bo, r, n, cfg, atr));
  }

//+==================================================================+
//| DRAWING                                                          |
//+==================================================================+
void BOClear(const long chartId, const string prefix)
  {
   ObjectsDeleteAll(chartId, prefix, -1, -1);
  }

//--- The colour a breakout earned. A failed one goes grey: it is still
//--- information - this level does not hold - but it is not a direction, and
//--- colouring it like one would say it was. A PENDING one keeps its full
//--- direction colour, because it is the live one and the most likely to
//--- matter; the word PENDING beside it does the rest.
color BOColorOf(const BOPoint &p, const BOStyle &st)
  {
   if(p.status == BO_FAILED)
      return(st.failed);
   return(p.dir > 0 ? st.up : st.down);
  }

//--- The one label all three consumers build from. The score and grade sit
//--- next to the direction because that pairing IS the question - "an upside
//--- break, and is it any good" - and the status only earns space when it has
//--- something to say beyond the default.
string BOLabel(const int rank, const BOPoint &p, const double atr)
  {
   const string tail = (p.status == BO_HELD ? "" : "  " + BOStatusName(p.status));
   return(StringFormat("BO%d %s  %d %s%s  ->%.1fA",
                       rank + 1, (p.dir > 0 ? "UP" : "DN"),
                       p.score, BOGrade(p.score), tail,
                       (atr > 0.0 ? p.mfe / atr : 0.0)));
  }

//+------------------------------------------------------------------+
//| The breakouts.                                                   |
//|                                                                  |
//| Each one gets the range it broke out of, the level that gave     |
//| way, and a marker on the bar that did it. The box is the point:  |
//| a marker alone says a breakout happened, and the box says WHAT   |
//| broke - which is the only way to judge whether it was worth      |
//| anything.                                                        |
//|                                                                  |
//| The box is an OUTLINE by default. A filled box competes with the |
//| filled zones HullTrendFVG draws, and on a chart carrying both,   |
//| "which study drew this" has to be answerable at a glance.        |
//+------------------------------------------------------------------+
void BODraw(const BOPoint &bo[], const long chartId, const string prefix,
            const string symbol, const ENUM_TIMEFRAMES tf,
            const double atr, const BOStyle &st)
  {
   BOClear(chartId, prefix);

   const int      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const long     secs   = PeriodSeconds(tf);
   const datetime right  = TimeCurrent() + (datetime)(secs * 2);
   const int      n      = ArraySize(bo);

   for(int i = 0; i < n; i++)
     {
      const bool   up      = (bo[i].dir > 0);
      const color  col     = BOColorOf(bo[i], st);
      const double pushATR = (atr > 0.0 ? bo[i].push / atr : 0.0);
      const double mfeATR  = (atr > 0.0 ? bo[i].mfe  / atr : 0.0);

      //--- The range that broke.
      if(st.showRange)
        {
         const string rn = StringFormat("%sR%d", prefix, i);
         if(ObjectCreate(chartId, rn, OBJ_RECTANGLE, 0,
                         bo[i].from, bo[i].rangeHigh, bo[i].time, bo[i].rangeLow))
           {
            ObjectSetInteger(chartId, rn, OBJPROP_COLOR,      col);
            ObjectSetInteger(chartId, rn, OBJPROP_BGCOLOR,    st.range);
            ObjectSetInteger(chartId, rn, OBJPROP_FILL,       st.fillRange);
            ObjectSetInteger(chartId, rn, OBJPROP_BACK,       true);
            ObjectSetInteger(chartId, rn, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chartId, rn, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chartId, rn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(chartId, rn, OBJPROP_HIDDEN,     true);
           }
        }

      //--- The level that gave way, carried right because a broken level is
      //--- the first thing price tests on the way back.
      if(st.showLevel)
        {
         const string ln = StringFormat("%sL%d", prefix, i);
         if(ObjectCreate(chartId, ln, OBJ_TREND, 0,
                         bo[i].from, bo[i].level,
                         (st.extendLevel ? right : bo[i].time), bo[i].level))
           {
            ObjectSetInteger(chartId, ln, OBJPROP_COLOR,      col);
            ObjectSetInteger(chartId, ln, OBJPROP_STYLE,      STYLE_DASH);
            ObjectSetInteger(chartId, ln, OBJPROP_WIDTH,      (i == 0 ? 2 : 1));
            ObjectSetInteger(chartId, ln, OBJPROP_RAY_RIGHT,  false);
            ObjectSetInteger(chartId, ln, OBJPROP_RAY_LEFT,   false);
            ObjectSetInteger(chartId, ln, OBJPROP_BACK,       true);
            ObjectSetInteger(chartId, ln, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(chartId, ln, OBJPROP_HIDDEN,     true);
           }
        }

      //--- The bar that did it. The anchor puts the glyph on the far side of
      //--- the point, pointing back at the bar - inverted, it drew the arrow
      //--- straight over the candle it marks.
      const double off = (atr > 0.0 ? atr * BO_ARROW_OFF_ATR : 0.0);
      const double at  = (up ? bo[i].close - off : bo[i].close + off);

      const string an = StringFormat("%sA%d", prefix, i);
      if(ObjectCreate(chartId, an, OBJ_ARROW, 0, bo[i].time, at))
        {
         ObjectSetInteger(chartId, an, OBJPROP_ARROWCODE,
                          (up ? st.arrowUp : st.arrowDown));
         ObjectSetInteger(chartId, an, OBJPROP_COLOR,     col);
         ObjectSetInteger(chartId, an, OBJPROP_WIDTH,     (i == 0 ? 3 : 2));
         ObjectSetInteger(chartId, an, OBJPROP_ANCHOR,    (up ? ANCHOR_TOP : ANCHOR_BOTTOM));
         ObjectSetInteger(chartId, an, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, an, OBJPROP_HIDDEN,     true);

         //--- The tooltip is where the score stops being a number and starts
         //--- being an argument: every component, with its own weight, so a
         //--- reader can disagree with the total on specific grounds.
         ObjectSetString(chartId, an, OBJPROP_TOOLTIP,
                         StringFormat("%s breakout #%d on %s   %s\n"
                                      "SCORE %d / 100  (%s)\n"
                                      "  push        %3.0f / %d   closed %.2f ATR past the level\n"
                                      "  close       %3.0f / %d   sat %.0f%% up its own bar\n"
                                      "  compression %3.0f / %d   range was %.1f ATR tall\n"
                                      "  volume      %3.0f / %d   effort vs the range average\n"
                                      "closed %s through %s\n"
                                      "range %s - %s  (%s tall)\n"
                                      "ran %.2f ATR since   |   %s",
                                      (up ? "Upside" : "Downside"), i + 1,
                                      SRTFName(tf), BOStatusName(bo[i].status),
                                      bo[i].score, BOGrade(bo[i].score),
                                      bo[i].pushQ  * BO_W_PUSH,  BO_W_PUSH,  pushATR,
                                      bo[i].closeQ * BO_W_CLOSE, BO_W_CLOSE,
                                      bo[i].closeQ * 100.0,
                                      bo[i].compQ  * BO_W_COMP,  BO_W_COMP,
                                      (atr > 0.0 ? bo[i].height() / atr : 0.0),
                                      bo[i].volQ   * BO_W_VOL,   BO_W_VOL,
                                      DoubleToString(bo[i].close, digits),
                                      DoubleToString(bo[i].level, digits),
                                      DoubleToString(bo[i].rangeLow, digits),
                                      DoubleToString(bo[i].rangeHigh, digits),
                                      SRFormatDist(symbol, bo[i].height()),
                                      mfeATR,
                                      TimeToString(bo[i].time, TIME_DATE | TIME_MINUTES)));
        }

      if(!st.labels)
         continue;

      const string tn = StringFormat("%sT%d", prefix, i);
      if(ObjectCreate(chartId, tn, OBJ_TEXT, 0,
                      bo[i].time + (datetime)(2 * secs), at))
        {
         ObjectSetString(chartId, tn, OBJPROP_TEXT,       BOLabel(i, bo[i], atr));
         ObjectSetInteger(chartId, tn, OBJPROP_COLOR,     col);
         ObjectSetInteger(chartId, tn, OBJPROP_FONTSIZE,  st.fontSize);
         ObjectSetInteger(chartId, tn, OBJPROP_ANCHOR,    ANCHOR_LEFT);
         ObjectSetInteger(chartId, tn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, tn, OBJPROP_HIDDEN,     true);
        }
     }
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void BOPanelLine(const long chartId, const string name, const BOStyle &st,
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
//| The summary panel: one row per breakout, newest at the top,      |
//| then the newest one's score broken into the four things that     |
//| made it.                                                         |
//|                                                                  |
//| The markers answer "what is that arrow?". They cannot answer     |
//| the question actually asked - is this one worth taking - because |
//| that answer lives in a score, its parts, and the record of how   |
//| the last few went. Reading three rows where two say FAILED is    |
//| the whole point.                                                 |
//|                                                                  |
//| Call it AFTER BODraw: that function clears the whole prefix.     |
//+------------------------------------------------------------------+
void BODrawPanel(const BOPoint &bo[], const long chartId, const string prefix,
                 const string symbol, const ENUM_TIMEFRAMES tf,
                 const ENUM_TIMEFRAMES chartTF, const double atr,
                 const BOConfig &cfg, const BOStyle &st)
  {
   if(!st.panel)
      return;

   const int      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const datetime now    = TimeCurrent();
   const int      n      = ArraySize(bo);
   const int      rows   = (n > 0 ? n + 3 : 3);

   string ln[];
   color  cl[];
   ArrayResize(ln, rows);
   ArrayResize(cl, rows);

   //--- The header names the timeframe the SCAN ran on, which is not
   //--- necessarily the chart. On an M15 chart showing H1 breakouts, a header
   //--- that said "M15" would be describing the wrong thing entirely.
   ln[0] = StringFormat("HULL BREAKOUT   %s   %s%s   range %d bars   %s ATR %s",
                        symbol, SRTFName(tf),
                        (tf == chartTF ? "" : StringFormat(" on %s", SRTFName(chartTF))),
                        BORangeBars(cfg.rangeBars), SRTFName(tf),
                        SRFormatDist(symbol, atr));
   cl[0] = st.panelText;

   for(int i = 0; i < n; i++)
     {
      ln[i + 1] = StringFormat("%-3s %-4s %-10s  %3d %-6s  push %4.2fA  ran %5.2fA  %-7s %s ago",
                               StringFormat("#%d", i + 1),
                               (bo[i].dir > 0 ? "UP" : "DOWN"),
                               DoubleToString(bo[i].level, digits),
                               bo[i].score, BOGrade(bo[i].score),
                               (atr > 0.0 ? bo[i].push / atr : 0.0),
                               (atr > 0.0 ? bo[i].mfe  / atr : 0.0),
                               BOStatusName(bo[i].status),
                               SRFormatAge(bo[i].time, now));
      cl[i + 1] = BOColorOf(bo[i], st);
     }

   if(n == 0)
     {
      ln[1] = StringFormat("nothing broke a %d-bar range in the last %d %s bars",
                           BORangeBars(cfg.rangeBars), BOScanDepth(cfg), SRTFName(tf));
      cl[1] = st.panelText;
      ln[2] = (BOMinScore(cfg.minScore) > 0
               ? StringFormat("min score %d - lower it to see weaker breaks",
                              BOMinScore(cfg.minScore))
               : StringFormat("min push %.2f ATR - lower it to see smaller breaks",
                              cfg.minBreakATR));
      cl[2] = st.panelText;
     }
   else
     {
      //--- The newest one's score, broken into its parts. This is the answer
      //--- to "how do I know it is valid": not a verdict handed down, but the
      //--- four things it was built from, each with the weight it carried, so
      //--- a reader can disagree on specific grounds.
      ln[rows - 2] = StringFormat("  #1 score %d = push %.0f + close %.0f + "
                                  "compression %.0f + volume %.0f   (of %d/%d/%d/%d)",
                                  bo[0].score,
                                  bo[0].pushQ  * BO_W_PUSH,
                                  bo[0].closeQ * BO_W_CLOSE,
                                  bo[0].compQ  * BO_W_COMP,
                                  bo[0].volQ   * BO_W_VOL,
                                  BO_W_PUSH, BO_W_CLOSE, BO_W_COMP, BO_W_VOL);
      cl[rows - 2] = st.panelText;

      //--- The footer is the honest summary: how many of the ones shown are
      //--- actually settled, and how they went. Three arrows look like a
      //--- working edge until this line says two of them failed.
      int held = 0, failed = 0, pending = 0;
      for(int i = 0; i < n; i++)
         if(bo[i].status == BO_HELD)
            held++;
         else
            if(bo[i].status == BO_FAILED)
               failed++;
            else
               pending++;

      ln[rows - 1] = StringFormat("of the last %d: %d held, %d failed, %d still "
                                  "inside the %d-bar window",
                                  n, held, failed, pending,
                                  BOConfirmBars(cfg.confirmBars));
      cl[rows - 1] = st.panelText;
     }

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
      BOPanelLine(chartId, StringFormat("%sP%d", prefix, i), st, i, ln[i], cl[i]);
  }

//+==================================================================+
//| LOG                                                              |
//+==================================================================+

//+------------------------------------------------------------------+
//| Human-readable print of the recent breakouts.                    |
//|                                                                  |
//| One line per breakout, "HullBO | BREAK | ...", so the Experts    |
//| tab can be pasted and read back the way the EA log is. Newest    |
//| first, which is the order the chart is read in.                  |
//+------------------------------------------------------------------+
void BOPrintRecent(const BOPoint &bo[], const string symbol,
                   const ENUM_TIMEFRAMES tf, const double atr,
                   const BOConfig &cfg)
  {
   const int n = ArraySize(bo);
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(n == 0)
     {
      PrintFormat("HullBO | LIST | %s %s: nothing cleared a %d-bar range by %.2f ATR "
                  "with a score of %d+ in the last %d bars",
                  symbol, SRTFName(tf), BORangeBars(cfg.rangeBars),
                  cfg.minBreakATR, BOMinScore(cfg.minScore), BOScanDepth(cfg));
      return;
     }

   int held = 0, failed = 0, pending = 0;
   for(int i = 0; i < n; i++)
      if(bo[i].status == BO_HELD)
         held++;
      else
         if(bo[i].status == BO_FAILED)
            failed++;
         else
            pending++;

   PrintFormat("HullBO | LIST | %s %s: %d recent breakout%s - %d held, %d failed, "
               "%d pending - newest first",
               symbol, SRTFName(tf), n, (n == 1 ? "" : "s"), held, failed, pending);

   for(int i = 0; i < n; i++)
     {
      PrintFormat("HullBO | BREAK | %s | #%d %-4s  score %d %-6s  %-7s  "
                  "closed %s through %s  push %.2f ATR  ran %.2f ATR  "
                  "range %s tall  %d bar%s ago",
                  TimeToString(bo[i].time, TIME_DATE | TIME_MINUTES),
                  i + 1, (bo[i].dir > 0 ? "UP" : "DOWN"),
                  bo[i].score, BOGrade(bo[i].score), BOStatusName(bo[i].status),
                  DoubleToString(bo[i].close, digits),
                  DoubleToString(bo[i].level, digits),
                  (atr > 0.0 ? bo[i].push / atr : 0.0),
                  (atr > 0.0 ? bo[i].mfe  / atr : 0.0),
                  SRFormatDist(symbol, bo[i].height()),
                  bo[i].age, (bo[i].age == 1 ? "" : "s"));

      //--- The breakdown on its own line, so the score is never just asserted.
      PrintFormat("HullBO | SCORE | %s | #%d  push %.0f/%d  close %.0f/%d  "
                  "compression %.0f/%d  volume %.0f/%d",
                  TimeToString(bo[i].time, TIME_DATE | TIME_MINUTES), i + 1,
                  bo[i].pushQ  * BO_W_PUSH,  BO_W_PUSH,
                  bo[i].closeQ * BO_W_CLOSE, BO_W_CLOSE,
                  bo[i].compQ  * BO_W_COMP,  BO_W_COMP,
                  bo[i].volQ   * BO_W_VOL,   BO_W_VOL);
     }
  }

#endif // HULLTREND_BO_MQH
//+------------------------------------------------------------------+
