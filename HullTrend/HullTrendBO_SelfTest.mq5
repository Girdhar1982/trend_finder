//+------------------------------------------------------------------+
//|                                           HullTrendBO_SelfTest.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| DETECTION SELF-TEST for HullTrendBO.mqh                          |
//|                                                                  |
//| WHY THIS EXISTS                                                  |
//|   The arming rule is the part that fails quietly. Get it wrong   |
//|   in one direction and a single trending move reports forty      |
//|   breakouts; get it wrong in the other and the second real       |
//|   breakout of the week never appears at all. Neither crashes.    |
//|   Both look like a working indicator until you count.            |
//|                                                                  |
//|   So the walk is driven by a hand-built bar series that contains |
//|   one of every case - a clean breakout, a continuation bar that  |
//|   must be suppressed, a re-entry that must re-arm, a breakout    |
//|   that fails, one that is still PENDING, and one the other way - |
//|   and then the whole engine is run over real history against     |
//|   invariants that must hold on any symbol.                       |
//|                                                                  |
//|   The SCORE gets the same treatment. Three breakouts with        |
//|   hand-computed component values and hand-computed totals, so    |
//|   that a change to any weight or calibration constant shows up   |
//|   here as a number rather than as a slightly different chart     |
//|   nobody notices.                                                |
//|                                                                  |
//| HOW TO RUN                                                       |
//|   Drag onto any chart, or run it in the Strategy Tester over a   |
//|   few days. Everything happens in OnInit; look for the verdict.  |
//|                                                                  |
//| WHEN TO RUN                                                      |
//|   After ANY edit to HullTrendBO.mqh. Non-negotiable.             |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property version   "1.00"
#property description "Validates the HullTrendBO detection engine against hand-computed cases."

#include <HullTrendBO.mqh>

input ENUM_TIMEFRAMES InpTestTF = PERIOD_H1;   // Timeframe for the live-history section
input double          InpTol    = 1e-8;        // Floating-point comparison tolerance

int g_pass = 0;
int g_fail = 0;

//+------------------------------------------------------------------+
void Check(const string name, const bool ok, const string detail = "")
  {
   if(ok)
     {
      g_pass++;
      PrintFormat("  PASS  %s", name);
     }
   else
     {
      g_fail++;
      PrintFormat("  FAIL  %s %s", name, detail);
     }
  }

void CheckNear(const string name, const double got, const double want)
  {
   const bool ok = (MathAbs(got - want) <= MathMax(InpTol, MathAbs(want) * 1e-9));
   Check(name, ok, StringFormat("(got %.8f, want %.8f)", got, want));
  }

void CheckInt(const string name, const long got, const long want)
  {
   Check(name, got == want, StringFormat("(got %I64d, want %I64d)", got, want));
  }

//+------------------------------------------------------------------+
//| The hand-built series.  rangeBars = 3, confirmBars = 2.          |
//|                                                                  |
//| Written CHRONOLOGICALLY because that is how a human can check    |
//| it, then reversed into the newest-first order the engine wants.  |
//|                                                                  |
//|  idx  open  high   low  close   what it is                       |
//|   0    100   101    99  100.0   \                                |
//|   1    100   101    99  100.0    |  the first range: 99 - 101    |
//|   2    100   101    99  100.0   /                                |
//|   3    100   103    99  102.5   closes through 101  -> BREAK UP  |
//|   4    102   104   102  103.5   clears a rolling high too, but   |
//|                                 it is the SAME move: suppressed  |
//|   5    103   104   102  103.0   still inside the move            |
//|   6    103   104   100  100.5   closes back under 101 -> RE-ARM  |
//|   7    100   106   100  105.5   closes through 104  -> BREAK UP  |
//|   8    105   106   103  103.5   straight back under 104 -> FAILED|
//|   9    103   104   100  100.5                                    |
//|  10    100   101    97   97.5   closes under 100  -> BREAK DOWN  |
//|  11     97    98    95   95.5   same move down: suppressed       |
//|  12     95    96    94   94.5   the forming bar - never examined |
//|                                                                  |
//| Expected, newest first:                                          |
//|   #1  bar 10  DOWN  level 100  score 66  PENDING                 |
//|   #2  bar  7  UP    level 104  score 66  FAILED                  |
//|   #3  bar  3  UP    level 101  score 94  HELD                    |
//|                                                                  |
//| #1 is PENDING because only ONE closed bar has followed it and    |
//| the window is two. That is the case this series exists to pin    |
//| down: the honest answer to "did it hold" is "not yet known".     |
//+------------------------------------------------------------------+
#define TEST_BARS 13

void BuildSeries(MqlRates &r[])
  {
   double o[TEST_BARS] = {100.0,100.0,100.0,100.0,102.0,103.0,103.0,100.0,105.0,103.0,100.0, 97.0, 95.0};
   double h[TEST_BARS] = {101.0,101.0,101.0,103.0,104.0,104.0,104.0,106.0,106.0,104.0,101.0, 98.0, 96.0};
   double l[TEST_BARS] = { 99.0, 99.0, 99.0, 99.0,102.0,102.0,100.0,100.0,103.0,100.0, 97.0, 95.0, 94.0};
   double c[TEST_BARS] = {100.0,100.0,100.0,102.5,103.5,103.0,100.5,105.5,103.5,100.5, 97.5, 95.5, 94.5};
   //--- Tick volume, chosen so each breakout gets a different volume grade:
   //--- bar 3 doubles its range average (full marks), bar 7 matches it (none),
   //--- bar 10 sits half way (half marks).
   long   v[TEST_BARS] = {  100,  100,  100,  200,  100,  100,  100,  100,  100,  100,  150,  100,  100};

   ArrayResize(r, TEST_BARS);
   ArraySetAsSeries(r, true);

   //--- Series ordering means index 0 is the NEWEST, so the chronological
   //--- table above goes in backwards. Doing the flip here, once, is what
   //--- lets the expectations be stated in the order a human reads.
   const datetime epoch = D'2025.01.06 00:00';
   for(int i = 0; i < TEST_BARS; i++)
     {
      const int idx = TEST_BARS - 1 - i;      // chronological index for shift i
      r[i].time        = epoch + (datetime)(idx * 3600);
      r[i].open        = o[idx];
      r[i].high        = h[idx];
      r[i].low         = l[idx];
      r[i].close       = c[idx];
      r[i].tick_volume = v[idx];
      r[i].spread      = 0;
      r[i].real_volume = 0;
     }
  }

//--- shift of a chronological index in the reversed series
int Shift(const int chronoIdx) { return(TEST_BARS - 1 - chronoIdx); }

//--- the config the table above was designed around
BOConfig TestConfig()
  {
   BOConfig cfg;
   cfg.lookback    = 50;      // floored anyway; the series is shorter
   cfg.rangeBars   = 3;
   cfg.minBreakATR = 0.0;     // the push filter is tested on its own below
   cfg.confirmBars = 2;
   cfg.maxAgeBars  = 0;
   cfg.maxShown    = 0;       // all of them
   return(cfg);
  }

//+------------------------------------------------------------------+
//| 1. The three breakouts, and the two bars that must NOT be some   |
//+------------------------------------------------------------------+
void TestWalk()
  {
   Print("-- the walk --");
   MqlRates r[];
   BuildSeries(r);

   BOPoint bo[];
   BOConfig cfg = TestConfig();
   Check("the scan ran", BOScan(bo, r, TEST_BARS, cfg, 1.0));

   //--- THE headline assertion. Four bars in this series close beyond a
   //--- rolling range edge; only three of them start a new move.
   CheckInt("three breakouts, not five", ArraySize(bo), 3);
   if(ArraySize(bo) != 3)
      return;

   //--- #1, newest: the downside break of the 100 floor.
   CheckInt ("#1 is a downside break",      bo[0].dir, -1);
   CheckNear("#1 broke the 100 floor",      bo[0].level, 100.0);
   CheckNear("#1 closed at 97.5",           bo[0].close,  97.5);
   CheckInt ("#1 sits on bar 10",           (long)bo[0].time, (long)r[Shift(10)].time);
   CheckNear("#1 pushed 2.5 past the level", bo[0].push,  2.5);
   CheckInt ("#1 is 2 bars old",            bo[0].age, Shift(10));

   //--- THE HONESTY CASE. #1 is one closed bar old against a 2-bar
   //--- confirmation window, so whether it held is NOT YET KNOWN. The
   //--- predecessor of this engine reported it as "held", which was a claim
   //--- about a bar that has not happened.
   CheckInt ("#1 is PENDING, not held",     bo[0].status, BO_PENDING);
   Check    ("#1 does not claim to have failed", !bo[0].failed());
   Check    ("#1 reports itself as pending",     bo[0].pending());

   //--- #2: broke 104 and closed straight back under it.
   CheckInt ("#2 is an upside break",       bo[1].dir, +1);
   CheckNear("#2 broke the 104 ceiling",    bo[1].level, 104.0);
   CheckInt ("#2 sits on bar 7",            (long)bo[1].time, (long)r[Shift(7)].time);
   CheckInt ("#2 FAILED",                   bo[1].status, BO_FAILED);

   //--- #3, oldest: the original break of the 99-101 range.
   CheckInt ("#3 is an upside break",       bo[2].dir, +1);
   CheckNear("#3 broke the 101 ceiling",    bo[2].level, 101.0);
   CheckInt ("#3 sits on bar 3",            (long)bo[2].time, (long)r[Shift(3)].time);
   CheckInt ("#3 HELD",                     bo[2].status, BO_HELD);

   //--- The range each one broke out of, which is what the box draws.
   CheckNear("#3 range high", bo[2].rangeHigh, 101.0);
   CheckNear("#3 range low",  bo[2].rangeLow,   99.0);
   CheckInt ("#3 box starts at bar 0", (long)bo[2].from, (long)r[Shift(0)].time);
   CheckNear("#2 range high", bo[1].rangeHigh, 104.0);
   CheckNear("#2 range low",  bo[1].rangeLow,  100.0);
   CheckNear("#1 range high", bo[0].rangeHigh, 106.0);
   CheckNear("#1 range low",  bo[0].rangeLow,  100.0);

   //--- How far each ran afterwards, the live bar included.
   CheckNear("#1 ran 3.5 (down to 94)",  bo[0].mfe, 3.5);
   CheckNear("#2 ran 0.5 (up to 106)",   bo[1].mfe, 0.5);
   CheckNear("#3 ran 3.5 (up to 106)",   bo[2].mfe, 3.5);

   //--- Ordering, which every consumer depends on.
   bool desc = true;
   for(int i = 1; i < ArraySize(bo); i++)
      if(bo[i].time > bo[i - 1].time)
         desc = false;
   Check("breakouts come back newest first", desc);
  }

//+------------------------------------------------------------------+
//| 2. The arming rule, stated as its own case                       |
//+------------------------------------------------------------------+
void TestArming()
  {
   Print("-- arming --");
   MqlRates r[];
   BuildSeries(r);

   BOPoint bo[];
   BOConfig cfg = TestConfig();
   BOScan(bo, r, TEST_BARS, cfg, 1.0);

   //--- Bar 4 closes 103.5, clear of the 103 high of bars 1-3. Without the
   //--- arming rule it is a breakout; with it, it is the second bar of the
   //--- move that started on bar 3.
   bool bar4 = false, bar11 = false;
   for(int i = 0; i < ArraySize(bo); i++)
     {
      if(bo[i].time == r[Shift(4)].time)
         bar4 = true;
      if(bo[i].time == r[Shift(11)].time)
         bar11 = true;
     }
   Check("bar 4 is not a second upside breakout",  !bar4);
   Check("bar 11 is not a second downside breakout", !bar11);

   //--- And the rule must not be a permanent mute: bar 6 closes back under
   //--- 101, and bar 7 is allowed to break again.
   bool bar7 = false;
   for(int i = 0; i < ArraySize(bo); i++)
      if(bo[i].time == r[Shift(7)].time)
         bar7 = true;
   Check("closing back inside re-arms the direction", bar7,
         "(bar 6 closed 100.5, under the 101 that broke)");
  }

//+------------------------------------------------------------------+
//| 3. The minimum-push filter                                       |
//+------------------------------------------------------------------+
void TestPushFilter()
  {
   Print("-- minimum push --");
   MqlRates r[];
   BuildSeries(r);

   BOConfig cfg = TestConfig();
   BOPoint bo[];

   //--- With ATR 1.0 and a 2.0 ATR floor, only the downside break clears it:
   //--- it closed 2.5 past its level, the two upside ones only 1.5.
   cfg.minBreakATR = 2.0;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("a 2 ATR floor leaves only the strongest break", ArraySize(bo), 1);
   if(ArraySize(bo) == 1)
      CheckInt("and it is the downside one", bo[0].dir, -1);

   //--- The filter must scale with ATR, not with price. Same floor, half the
   //--- ATR, and the weaker breaks come back.
   BOScan(bo, r, TEST_BARS, cfg, 0.5);
   CheckInt("halving the ATR lets all three back in", ArraySize(bo), 3);

   //--- A poke that fails the filter is not a breakout, so it must not spend
   //--- the arming either - bar 3 stays available to be found.
   cfg.minBreakATR = 1.4;      // 1.5 pushes pass, nothing else changes
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("a 1.4 ATR floor still finds all three", ArraySize(bo), 3);
  }

//+------------------------------------------------------------------+
//| 4. Windows, caps and clamps                                      |
//+------------------------------------------------------------------+
void TestWindowsAndClamps()
  {
   Print("-- windows and clamps --");
   MqlRates r[];
   BuildSeries(r);

   BOConfig cfg = TestConfig();
   BOPoint bo[];

   //--- "The 2 most recent" must be the two NEWEST, not the first two found.
   cfg.maxShown = 2;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("maxShown caps the list", ArraySize(bo), 2);
   if(ArraySize(bo) == 2)
     {
      CheckInt("and keeps the newest",       (long)bo[0].time, (long)r[Shift(10)].time);
      CheckInt("and the one before it",      (long)bo[1].time, (long)r[Shift(7)].time);
     }

   //--- The age window is in BARS. Bar 3 is 9 bars back, so a 6-bar window
   //--- drops it - while the walk still runs over it, which is what keeps
   //--- bar 4 suppressed rather than promoting it to a breakout.
   cfg.maxShown   = 0;
   cfg.maxAgeBars = 6;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("a 6-bar window drops the oldest break", ArraySize(bo), 2);
   if(ArraySize(bo) == 2)
      CheckInt("and the survivors are the newest two",
               (long)bo[1].time, (long)r[Shift(7)].time);

   //--- confirmBars 0 means nothing is ever called failed.
   cfg.maxAgeBars  = 0;
   cfg.confirmBars = 0;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   bool anyFailed = false, anyPending = false;
   for(int i = 0; i < ArraySize(bo); i++)
     {
      if(bo[i].status == BO_FAILED)
         anyFailed = true;
      if(bo[i].status == BO_PENDING)
         anyPending = true;
     }
   Check("confirmBars 0 disables the failure verdict", !anyFailed);
   Check("and leaves nothing pending - a zero window has already elapsed",
         !anyPending);

   //--- A longer confirmation window catches a later re-entry: with 4 bars,
   //--- bar 3's break is failed by bar 6 closing back under 101.
   cfg.confirmBars = 4;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   if(ArraySize(bo) == 3)
     {
      CheckInt("a 4-bar window fails the oldest break too", bo[2].status, BO_FAILED);
      //--- and widening the window pushes the NEWEST one further from a
      //--- verdict, never closer to one
      CheckInt("and the newest is still pending", bo[0].status, BO_PENDING);
     }
   else
      Check("a 4-bar window still finds three breaks", false);

   CheckInt("lookback below the floor is raised", BOScanBars(5),   50);
   CheckInt("lookback above the floor is kept",   BOScanBars(300), 300);
   CheckInt("range below 2 is raised",            BORangeBars(1),  2);
   CheckInt("negative confirm bars are floored",  BOConfirmBars(-3), 0);

   BOConfig c2;
   c2.lookback   = 100;
   c2.maxAgeBars = 500;
   CheckInt("age cannot outreach the lookback", BOScanDepth(c2), 100);
   c2.maxAgeBars = 0;
   CheckInt("age 0 means the whole lookback",   BOScanDepth(c2), 100);
   c2.maxAgeBars = 30;
   CheckInt("a shorter age wins",               BOScanDepth(c2), 30);

   //--- Too few bars to hold a range is not a crash and not an empty answer -
   //--- it is "could not read", which a caller must not treat as "none found".
   BOPoint tiny[];
   BOConfig c3 = TestConfig();
   Check("a series shorter than the range is refused, not emptied",
         !BOScan(tiny, r, 4, c3, 1.0));
  }

//+------------------------------------------------------------------+
//| 5. The score components, on their own                            |
//+------------------------------------------------------------------+
void TestScoreParts()
  {
   Print("-- score components --");

   //--- push: full marks at BO_PUSH_FULL ATR past the level, clamped there.
   CheckNear("push at half the full distance", BOPushQ(0.25, 1.0), 0.5);
   CheckNear("push at the full distance",      BOPushQ(0.50, 1.0), 1.0);
   CheckNear("push beyond it is clamped",      BOPushQ(5.00, 1.0), 1.0);
   CheckNear("push scales with ATR",           BOPushQ(0.50, 2.0), 0.5);

   //--- close: where the close sat inside the breakout bar itself.
   MqlRates b;
   b.open = 10.0; b.high = 12.0; b.low = 10.0; b.close = 12.0;
   CheckNear("closing on the high is a perfect up-break", BOCloseQ(b, +1), 1.0);
   CheckNear("and the worst possible down-break",         BOCloseQ(b, -1), 0.0);
   b.close = 11.0;
   CheckNear("closing mid-bar is half either way",        BOCloseQ(b, +1), 0.5);
   b.high = 10.0; b.low = 10.0; b.close = 10.0;
   CheckNear("a bar with no range says nothing either way", BOCloseQ(b, +1), 0.5);

   //--- compression: a coil scores, a wide chop does not.
   CheckNear("a range at the tight threshold is full marks",  BOCompQ(1.5, 1.0), 1.0);
   CheckNear("tighter still is clamped",                      BOCompQ(0.2, 1.0), 1.0);
   CheckNear("a range at the loose threshold scores nothing", BOCompQ(6.0, 1.0), 0.0);
   CheckNear("wider than that is clamped, not negative",      BOCompQ(20.0, 1.0), 0.0);

   //--- volume: expansion against the range average.
   CheckNear("double the average volume is full marks", BOVolQ(200.0, 100.0), 1.0);
   CheckNear("equal to the average scores nothing",     BOVolQ(100.0, 100.0), 0.0);
   CheckNear("half way there is half marks",            BOVolQ(150.0, 100.0), 0.5);
   CheckNear("below average is floored, not negative",  BOVolQ( 50.0, 100.0), 0.0);
   CheckNear("no volume data is neutral, not zero",     BOVolQ(100.0,   0.0), 0.5);

   //--- The weights have to sum to 100, or the score is not out of 100 and
   //--- every grade threshold beside it is quietly wrong.
   CheckInt("the weights sum to 100",
            BO_W_PUSH + BO_W_CLOSE + BO_W_COMP + BO_W_VOL, 100);
   CheckInt("a perfect breakout scores 100", BOScoreOf(1.0, 1.0, 1.0, 1.0), 100);
   CheckInt("a worthless one scores 0",      BOScoreOf(0.0, 0.0, 0.0, 0.0), 0);

   Check("100 is STRONG", BOGrade(100) == "STRONG");
   Check("75 is STRONG",  BOGrade(BO_GRADE_STRONG) == "STRONG");
   Check("74 is FAIR",    BOGrade(BO_GRADE_STRONG - 1) == "FAIR");
   Check("49 is WEAK",    BOGrade(BO_GRADE_FAIR - 1) == "WEAK");
   Check("24 is POOR",    BOGrade(BO_GRADE_WEAK - 1) == "POOR");
  }

//+------------------------------------------------------------------+
//| 6. The scores the hand-built series must produce                 |
//+------------------------------------------------------------------+
void TestScores()
  {
   Print("-- scores on the built series --");
   MqlRates r[];
   BuildSeries(r);

   BOPoint bo[];
   BOConfig cfg = TestConfig();
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   if(ArraySize(bo) != 3)
     {
      Check("three breakouts to score", false);
      return;
     }

   //--- #3, bar 3: closed 1.5 past a 2.0-tall range on double volume, near the
   //--- high of its own bar. This is what a good one looks like.
   CheckNear("#3 push is full marks",      bo[2].pushQ,  1.0);
   CheckNear("#3 closed 87.5% up its bar", bo[2].closeQ, 0.875);
   CheckNear("#3 range was tight",         bo[2].compQ,  4.0 / 4.5);
   CheckNear("#3 volume doubled",          bo[2].volQ,   1.0);
   CheckInt ("#3 scores 94",               bo[2].score,  94);
   Check    ("#3 grades STRONG",           BOGrade(bo[2].score) == "STRONG");

   //--- #2, bar 7: the same push, but out of a range twice as wide and on
   //--- average volume. Same break, materially worse setup.
   CheckNear("#2 range was looser",        bo[1].compQ,  2.0 / 4.5);
   CheckNear("#2 volume did not expand",   bo[1].volQ,   0.0);
   CheckInt ("#2 scores 66",               bo[1].score,  66);
   Check    ("#2 grades FAIR",             BOGrade(bo[1].score) == "FAIR");

   //--- #1, bar 10: out of a 6-ATR range, which is exactly the loose
   //--- threshold, so the compression component earns nothing at all.
   CheckNear("#1 gets no compression credit", bo[0].compQ, 0.0);
   CheckNear("#1 volume was half way",        bo[0].volQ,  0.5);
   CheckInt ("#1 scores 66",                  bo[0].score, 66);

   //--- Every score has to be inside the range its grades assume.
   bool inRange = true;
   for(int i = 0; i < ArraySize(bo); i++)
      if(bo[i].score < 0 || bo[i].score > 100)
         inRange = false;
   Check("every score is inside 0..100", inRange);
  }

//+------------------------------------------------------------------+
//| 7. The score floor                                               |
//+------------------------------------------------------------------+
void TestMinScore()
  {
   Print("-- the score floor --");
   MqlRates r[];
   BuildSeries(r);

   BOPoint bo[];
   BOConfig cfg = TestConfig();

   cfg.minScore = 70;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("a floor of 70 leaves only the STRONG one", ArraySize(bo), 1);
   if(ArraySize(bo) == 1)
      CheckInt("and it is the one on bar 3", (long)bo[0].time, (long)r[Shift(3)].time);

   cfg.minScore = 66;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("a floor of 66 lets all three through", ArraySize(bo), 3);

   cfg.minScore = 95;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   CheckInt("a floor of 95 leaves nothing", ArraySize(bo), 0);

   //--- The floor must not disturb the WALK. A hidden breakout still happened
   //--- and still spent the arming, so filtering must not promote bar 4 - the
   //--- continuation bar - into a breakout of its own.
   cfg.minScore = 70;
   BOScan(bo, r, TEST_BARS, cfg, 1.0);
   bool bar4 = false;
   for(int i = 0; i < ArraySize(bo); i++)
      if(bo[i].time == r[Shift(4)].time)
         bar4 = true;
   Check("filtering does not promote a continuation bar", !bar4);

   CheckInt("a negative floor is raised to 0", BOMinScore(-5),  0);
   CheckInt("a floor over 100 is capped",      BOMinScore(500), 100);
  }

//+------------------------------------------------------------------+
//| 8. The whole engine over real history.                           |
//|                                                                  |
//| The hand-built case proves the arithmetic. Only real bars prove  |
//| the thing survives contact with gaps in the history, weekends,   |
//| and a few hundred bars of index arithmetic - which is where an   |
//| MQL5 array overrun would take the indicator off the chart.       |
//+------------------------------------------------------------------+
void TestLive()
  {
   PrintFormat("-- live history: %s %s --", _Symbol, SRTFName(InpTestTF));

   const int h = iATR(_Symbol, InpTestTF, 14);
   if(h == INVALID_HANDLE)
     {
      Check("ATR handle for the live section", false);
      return;
     }

   double a[];
   ArraySetAsSeries(a, true);
   //--- The tester and a fresh attach both start with an unsynced history. A
   //--- short read here is not a failure of the engine, and reporting it as
   //--- one would make this test lie on a slow morning.
   if(CopyBuffer(h, 0, 1, 1, a) < 1 || a[0] <= 0.0)
     {
      Print("  SKIP  live history not available yet (ATR unreadable)");
      IndicatorRelease(h);
      return;
     }

   BOConfig cfg;                 // the shipped defaults
   BOPoint  bo[];
   if(!BOCollect(bo, _Symbol, InpTestTF, cfg, a[0]))
     {
      Print("  SKIP  live history not available yet (CopyRates short)");
      IndicatorRelease(h);
      return;
     }
   Check("the engine ran over real history", true);
   PrintFormat("        %d breakout(s) shown of the last %d bars",
               ArraySize(bo), BOScanDepth(cfg));

   const int      scan = BOScanDepth(cfg);
   const datetime now  = TimeCurrent();

   bool geometry = true, ages = true, ordered = true, future = false;
   bool pushOk = true, mfeOk = true, levelOk = true;
   for(int i = 0; i < ArraySize(bo); i++)
     {
      if(bo[i].rangeHigh <= bo[i].rangeLow)
         geometry = false;
      if(bo[i].age < 1 || bo[i].age > scan)
         ages = false;
      if(bo[i].time > now || bo[i].from > bo[i].time)
         future = true;
      if(i > 0 && bo[i].time > bo[i - 1].time)
         ordered = false;
      if(bo[i].push <= 0.0)
         pushOk = false;                       // it closed THROUGH the level
      if(bo[i].mfe < 0.0)
         mfeOk = false;                        // an excursion cannot be negative
      //--- the level has to be the edge of the range it came from
      const double edge = (bo[i].dir > 0 ? bo[i].rangeHigh : bo[i].rangeLow);
      if(MathAbs(bo[i].level - edge) > InpTol)
         levelOk = false;
      //--- and the close has to be on the far side of it
      if(bo[i].dir > 0 ? bo[i].close <= bo[i].level : bo[i].close >= bo[i].level)
         pushOk = false;
     }
   Check("every range has a high above its low", geometry);
   Check("every age is inside the scan window",  ages);
   Check("breakouts are ordered newest first",   ordered);
   Check("no breakout is dated in the future, and every box opens before it closes", !future);
   Check("every close is genuinely through its level", pushOk);
   Check("no negative excursions", mfeOk);
   Check("every level is the edge of its own range", levelOk);

   //--- The claim each breakout MAKES, re-checked against the bars themselves:
   //--- the level really was the extreme of the bars before it, and the bar
   //--- really did close through it.
   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int range = BORangeBars(cfg.rangeBars);
   int checked = 0;
   bool rederive = true;
   for(int i = 0; i < ArraySize(bo); i++)
     {
      const int s = iBarShift(_Symbol, InpTestTF, bo[i].time, true);
      if(s < 0 || CopyRates(_Symbol, InpTestTF, s, range + 1, r) < range + 1)
         continue;
      checked++;
      //--- r[0] is the breakout bar; r[1..range] are the range behind it.
      double hi = r[1].high, lo = r[1].low;
      for(int j = 2; j <= range; j++)
        {
         hi = MathMax(hi, r[j].high);
         lo = MathMin(lo, r[j].low);
        }
      const double edge = (bo[i].dir > 0 ? hi : lo);
      if(MathAbs(bo[i].level - edge) > InpTol)
         rederive = false;
      if(MathAbs(bo[i].close - r[0].close) > InpTol)
         rederive = false;
     }
   if(checked > 0)
      Check(StringFormat("all %d breakouts re-derive from their own range bars", checked),
            rederive);
   else
      Print("  SKIP  no breakouts in this window to re-derive");

   IndicatorRelease(h);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   Print("=====================================================");
   Print("HullTrendBO detection self-test");
   Print("=====================================================");

   TestWalk();
   TestArming();
   TestPushFilter();
   TestWindowsAndClamps();
   TestScoreParts();
   TestScores();
   TestMinScore();
   TestLive();

   Print("=====================================================");
   PrintFormat("VERDICT: %d passed, %d failed  -  %s",
               g_pass, g_fail, (g_fail == 0 ? "ALL GOOD" : "BROKEN"));
   Print("=====================================================");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Everything happens in OnInit. In the tester this keeps the run as
   //--- short as the date range, and on a live chart it never fires twice.
  }
//+------------------------------------------------------------------+
