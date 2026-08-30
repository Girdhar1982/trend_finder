//+------------------------------------------------------------------+
//|                                          HullTrendFVG_SelfTest.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| DETECTION SELF-TEST for HullTrendFVG.mqh                         |
//|                                                                  |
//| WHY THIS EXISTS                                                  |
//|   The detection is the part that fails quietly. A sign error in  |
//|   the gap test, an off-by-one in the swing confirmation, a fill  |
//|   percentage measured from the wrong edge - none of these crash. |
//|   They draw a slightly wrong rectangle, and a slightly wrong     |
//|   rectangle looks exactly like a right one.                      |
//|                                                                  |
//|   So the geometry is checked against a hand-built bar series     |
//|   with no market data involved, and then the whole engine is     |
//|   run over real history and checked against invariants that      |
//|   must hold on any symbol.                                       |
//|                                                                  |
//| HOW TO RUN                                                       |
//|   Drag onto any chart, or run it in the Strategy Tester over a   |
//|   few days. Everything happens in OnInit; look for the verdict.  |
//|                                                                  |
//| WHEN TO RUN                                                      |
//|   After ANY edit to HullTrendFVG.mqh. Non-negotiable.            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property version   "1.00"
#property description "Validates the HullTrendFVG detection engine against hand-computed cases."

#include <HullTrendFVG.mqh>

input ENUM_TIMEFRAMES InpTestHTF = PERIOD_H4;   // Timeframe for the live-history section
input double          InpTol     = 1e-8;        // Floating-point comparison tolerance

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
//| The hand-built series.                                           |
//|                                                                  |
//| Written CHRONOLOGICALLY because that is how a human can check    |
//| it, then reversed into the newest-first order every engine       |
//| function expects. Bar times are one hour apart from a fixed      |
//| epoch, so the expected answers below never move.                 |
//|                                                                  |
//|  idx  open high  low close   what it is                          |
//|   0   100  101    99  100                                        |
//|   1   100  102   100  101                                        |
//|   2   101  105   101  104    swing HIGH 105                      |
//|   3   104  103   100  101                                        |
//|   4   101  102    98   99    swing LOW 98, and a DOWN candle     |
//|   5    99  101    99  100                                        |
//|   6   100  104   100  103                                        |
//|   7   103  106   103  106    closes 106 > 105  -> BOS up         |
//|   8   106  107   105  105    swing HIGH 107 (never broken)       |
//|   9   105  106   100  101                                        |
//|  10   101  102    97   97    closes  97 <  98  -> CHoCH down     |
//|  11    97   99    96   98                                        |
//|  12    98  100    97   99    the forming bar - never examined    |
//+------------------------------------------------------------------+
#define TEST_BARS 13

void BuildSeries(MqlRates &r[])
  {
   double o[TEST_BARS] = {100,100,101,104,101, 99,100,103,106,105,101, 97, 98};
   double h[TEST_BARS] = {101,102,105,103,102,101,104,106,107,106,102, 99,100};
   double l[TEST_BARS] = { 99,100,101,100, 98, 99,100,103,105,100, 97, 96, 97};
   double c[TEST_BARS] = {100,101,104,101, 99,100,103,106,105,101, 97, 98, 99};

   ArrayResize(r, TEST_BARS);
   ArraySetAsSeries(r, true);

   //--- Series ordering means index 0 is the NEWEST, so the chronological
   //--- table above is written in backwards. Doing the flip here, once, is
   //--- what lets the expectations be stated in the order a human reads.
   const datetime epoch = D'2025.01.06 00:00';
   for(int i = 0; i < TEST_BARS; i++)
     {
      const int idx = TEST_BARS - 1 - i;      // chronological index for shift i
      r[i].time   = epoch + (datetime)(idx * 3600);
      r[i].open   = o[idx];
      r[i].high   = h[idx];
      r[i].low    = l[idx];
      r[i].close  = c[idx];
      r[i].tick_volume = 1;
      r[i].spread = 0;
      r[i].real_volume = 0;
     }
  }

//--- shift of a chronological index in the reversed series
int Shift(const int chronoIdx) { return(TEST_BARS - 1 - chronoIdx); }

//+------------------------------------------------------------------+
//| 1. Running extremes                                              |
//+------------------------------------------------------------------+
void TestExtremes()
  {
   Print("-- running extremes --");
   MqlRates r[];
   BuildSeries(r);

   double minLow[], maxHigh[];
   FVGRunExtremes(r, TEST_BARS, minLow, maxHigh);

   //--- Shift 0 is chronological bar 12: low 97, high 100.
   CheckNear("minLow[0] is the newest bar low",   minLow[0],  97.0);
   CheckNear("maxHigh[0] is the newest bar high", maxHigh[0], 100.0);

   //--- Shifts 0..2 are chronological 12,11,10: lows 97,96,97 -> 96.
   CheckNear("minLow[2] spans the three newest bars", minLow[2], 96.0);

   //--- Everything: the lowest low in the table is 96, the highest high 107.
   CheckNear("minLow over the whole series",  minLow[TEST_BARS - 1],  96.0);
   CheckNear("maxHigh over the whole series", maxHigh[TEST_BARS - 1], 107.0);

   //--- Monotone by construction, and the whole fill model depends on it.
   bool mono = true;
   for(int i = 1; i < TEST_BARS; i++)
      if(minLow[i] > minLow[i - 1] || maxHigh[i] < maxHigh[i - 1])
         mono = false;
   Check("running extremes are monotone in shift", mono);
  }

//+------------------------------------------------------------------+
//| 2. Fill measurement                                              |
//+------------------------------------------------------------------+
void TestFill()
  {
   Print("-- fill measurement --");

   //--- A zone 10.0 - 9.0 at shift 3, with the deepest low after it at 9.5:
   //--- price took back half of a demand zone.
   double minLow[4], maxHigh[4];
   minLow[0] = 9.5;  minLow[1] = 9.5;  minLow[2] = 9.5;  minLow[3] = 9.5;
   maxHigh[0] = 9.5; maxHigh[1] = 9.5; maxHigh[2] = 9.5; maxHigh[3] = 9.5;

   CheckNear("demand half filled", FVGFillOf(10.0, 9.0, +1, 3, minLow, maxHigh), 0.5);
   CheckNear("supply half filled", FVGFillOf(10.0, 9.0, -1, 3, minLow, maxHigh), 0.5);

   //--- Traded clean through: clamped at 1, never past it.
   minLow[2] = 8.0;
   CheckNear("demand traded through clamps at 1",
             FVGFillOf(10.0, 9.0, +1, 3, minLow, maxHigh), 1.0);

   //--- Never approached: 0, not a negative fraction.
   minLow[2] = 11.0;
   CheckNear("demand never approached is 0",
             FVGFillOf(10.0, 9.0, +1, 3, minLow, maxHigh), 0.0);

   //--- A zone completed on the newest closed bar has nothing after it yet.
   CheckNear("no bars after the zone means no fill",
             FVGFillOf(10.0, 9.0, +1, 0, minLow, maxHigh), 0.0);

   //--- Degenerate zone: no width, no fraction, no division by zero.
   CheckNear("zero-width zone is 0",
             FVGFillOf(10.0, 10.0, +1, 3, minLow, maxHigh), 0.0);
  }

//+------------------------------------------------------------------+
//| 3. Structure: BOS, CHoCH, and the order blocks they emit         |
//+------------------------------------------------------------------+
void TestStructure()
  {
   Print("-- structure --");
   MqlRates r[];
   BuildSeries(r);

   double minLow[], maxHigh[];
   FVGRunExtremes(r, TEST_BARS, minLow, maxHigh);

   FVGBreak brk[];
   FVGZone  ob[];
   FVGBias  bias;
   const bool ok = FVGStructure(brk, bias, ob, r, TEST_BARS, 1, TEST_BARS,
                                true, false, minLow, maxHigh);
   Check("structure pass ran", ok);

   CheckInt("two breaks found", ArraySize(brk), 2);
   if(ArraySize(brk) != 2)
      return;

   //--- Newest first. brk[0] is the later of the two.
   CheckInt   ("newest break is bearish",       brk[0].dir, -1);
   Check      ("newest break is a CHoCH",       brk[0].choch,
               "(it reversed the up move before it)");
   CheckNear  ("newest break took the swing low", brk[0].level, 98.0);
   CheckInt   ("newest break is on bar 10",     (long)brk[0].time,
               (long)r[Shift(10)].time);
   CheckInt   ("the swing it broke formed on bar 4", (long)brk[0].swing,
               (long)r[Shift(4)].time);

   CheckInt   ("older break is bullish",        brk[1].dir, +1);
   Check      ("older break is a BOS",          !brk[1].choch,
               "(nothing preceded it to reverse)");
   CheckNear  ("older break took the swing high", brk[1].level, 105.0);
   CheckInt   ("older break is on bar 7",       (long)brk[1].time,
               (long)r[Shift(7)].time);

   //--- The bias is whatever the LAST break said.
   CheckInt ("bias follows the newest break", bias.dir, -1);
   Check    ("bias records the change of character", bias.choch);
   CheckNear("bias level is the broken low", bias.level, 98.0);

   //--- Untaken liquidity: the 107 high was never closed above, so it is still
   //--- standing and is where an up move would be headed. The low was consumed
   //--- by the CHoCH and no newer one confirmed, so there is none.
   CheckNear("untaken high still standing", bias.refHigh, 107.0);
   CheckNear("the low was consumed by the break", bias.refLow, 0.0);

   //--- Order blocks: the last opposite-colour candle before each break.
   CheckInt("one order block per break", ArraySize(ob), 2);
   if(ArraySize(ob) != 2)
      return;

   //--- Emitted in walk order, so the bullish one (bar 4) comes first.
   CheckInt ("bullish OB is bullish",    ob[0].dir, +1);
   CheckInt ("bullish OB is an OB",      ob[0].kind, FVG_KIND_OB);
   CheckNear("bullish OB top is bar 4 high",    ob[0].top,    102.0);
   CheckNear("bullish OB bottom is bar 4 low",  ob[0].bottom,  98.0);
   CheckInt ("bullish OB sits on bar 4", (long)ob[0].time, (long)r[Shift(4)].time);

   CheckInt ("bearish OB is bearish",    ob[1].dir, -1);
   CheckNear("bearish OB top is bar 7 high",   ob[1].top,    106.0);
   CheckNear("bearish OB bottom is bar 7 low", ob[1].bottom, 103.0);

   //--- The bullish OB at 98-102 was traded clean through afterwards: bar 11
   //--- reached 96. That is what retires a zone.
   CheckNear("bullish OB has been fully mitigated", ob[0].fill, 1.0);

   //--- Body-only narrows the box to where the orders were worked. Bar 4 is
   //--- open 101 close 99, so the body is 99-101 inside a 98-102 range.
   FVGBreak b2[];
   FVGZone  ob2[];
   FVGBias  bias2;
   FVGStructure(b2, bias2, ob2, r, TEST_BARS, 1, TEST_BARS, true, true,
                minLow, maxHigh);
   if(ArraySize(ob2) > 0)
     {
      CheckNear("body-only OB top is the open",    ob2[0].top,    101.0);
      CheckNear("body-only OB bottom is the close", ob2[0].bottom, 99.0);
     }
   else
      Check("body-only order block produced", false);

   //--- The reporting window is in BARS. Narrow it and the older break falls
   //--- out of the report while still counting as context for the newer one.
   FVGBreak b3[];
   FVGZone  ob3[];
   FVGBias  bias3;
   FVGStructure(b3, bias3, ob3, r, TEST_BARS, 1, 3, false, false, minLow, maxHigh);
   CheckInt("a 3-bar window reports only the newest break", ArraySize(b3), 1);
   if(ArraySize(b3) == 1)
      Check("and it is still labelled a CHoCH", b3[0].choch,
            "(the context walk ran outside the window)");
  }

//+------------------------------------------------------------------+
//| 4. Zone selection, distance and targets                          |
//+------------------------------------------------------------------+
void MakeZone(FVGZone &z[], const int dir, const double top, const double bottom)
  {
   const int k = ArraySize(z);
   ArrayResize(z, k + 1);
   z[k].kind   = FVG_KIND_GAP;
   z[k].dir    = dir;
   z[k].top    = top;
   z[k].bottom = bottom;
   z[k].time   = D'2025.01.06 00:00' + (datetime)(k * 3600);
   z[k].origin = z[k].time;
   z[k].fill   = 0.0;
   z[k].age    = k + 1;
  }

void TestSelection()
  {
   Print("-- zone selection and targets --");

   FVGZone z[];
   MakeZone(z, +1, 99.0,  98.0);   // 0: demand, well below price
   MakeZone(z, +1, 100.5, 99.8);   // 1: demand, just under price
   MakeZone(z, -1, 103.0, 102.0);  // 2: supply, above price

   const double price = 100.0;

   CheckNear("distance to a zone below price", FVGDistance(z[0], price), 1.0);
   CheckNear("distance is 0 inside a zone",    FVGDistance(z[1], price), 0.0);
   CheckNear("distance to a zone above price", FVGDistance(z[2], price), 2.0);

   //--- Bullish bias takes the nearest demand zone price has not passed.
   CheckInt("bullish bias picks the nearest demand zone",
            FVGPickZone(z, +1, price), 1);
   CheckInt("bearish bias picks the supply zone",
            FVGPickZone(z, -1, price), 2);

   //--- A demand zone entirely ABOVE price has already done its work: price
   //--- came from below it, so it is not a place to buy a retracement.
   FVGZone above[];
   MakeZone(above, +1, 105.0, 104.0);
   CheckInt("a demand zone above price is not an entry",
            FVGPickZone(above, +1, price), -1);

   //--- Nothing on the bias side at all.
   CheckInt("no zone on the bias side returns -1", FVGPickZone(z, +1, 97.0), -1);

   //--- The target is the first thing in the way: the near edge of the supply
   //--- zone at 102, not the untaken high beyond it.
   FVGBias bias;
   bias.dir     = +1;
   bias.refHigh = 110.0;
   bias.refLow  = 90.0;
   CheckNear("long target stops at the supply zone in the way",
             FVGTarget(z, bias, +1, 100.0, 1.0), 102.0);

   //--- With nothing in the way, the target is the untaken liquidity.
   FVGZone bullOnly[];
   MakeZone(bullOnly, +1, 99.0, 98.0);
   CheckNear("long target is the untaken high when the path is clear",
             FVGTarget(bullOnly, bias, +1, 100.0, 1.0), 110.0);

   //--- With neither, a 2R fallback rather than a blank number.
   FVGZone none[];
   FVGBias empty;
   CheckNear("target falls back to 2R", FVGTarget(none, empty, +1, 100.0, 1.0), 102.0);
   CheckNear("and mirrors for a short", FVGTarget(none, empty, -1, 100.0, 1.0), 98.0);
  }

//+------------------------------------------------------------------+
//| 5. Sorting and the clamps                                        |
//+------------------------------------------------------------------+
void TestSortAndClamps()
  {
   Print("-- ordering and clamps --");

   FVGZone z[];
   MakeZone(z, +1, 99.0, 98.0);    // oldest
   MakeZone(z, -1, 103.0, 102.0);
   MakeZone(z, +1, 101.0, 100.0);  // newest
   FVGSortZones(z);

   bool desc = true;
   for(int i = 1; i < ArraySize(z); i++)
      if(z[i].time > z[i - 1].time)
         desc = false;
   Check("zones come back newest first", desc);
   CheckNear("and the newest really is first", z[0].top, 101.0);

   CheckInt("lookback below the floor is raised",  FVGScanBars(5),   40);
   CheckInt("lookback above the floor is kept",    FVGScanBars(180), 180);
   CheckInt("fractal below 1 is raised",           FVGFractal(0),    1);
   CheckInt("arm bars below 1 are raised",         FVGArmBars(0),    1);
   CheckNear("mitigation over 100% is capped",     FVGMitigated(500.0), 1.0);
   CheckNear("mitigation under 1% is floored",     FVGMitigated(0.0),   0.01);

   //--- The age cutoff must never be able to reach FURTHER than the lookback.
   FVGConfig cfg;
   cfg.lookback   = 100;
   cfg.maxAgeBars = 500;
   CheckInt("age cannot outreach the lookback", FVGScanDepth(cfg), 100);
   cfg.maxAgeBars = 0;
   CheckInt("age 0 means the whole lookback",   FVGScanDepth(cfg), 100);
   cfg.maxAgeBars = 30;
   CheckInt("a shorter age wins",               FVGScanDepth(cfg), 30);
  }

//+------------------------------------------------------------------+
//| 6. The whole engine over real history.                           |
//|                                                                  |
//| The hand-built cases prove the arithmetic. Only real bars prove  |
//| the thing survives contact with gaps in the history, weekends,   |
//| and a few hundred bars of index arithmetic - which is where an   |
//| MQL5 array overrun would take the indicator off the chart.       |
//+------------------------------------------------------------------+
void TestLive()
  {
   PrintFormat("-- live history: %s %s --", _Symbol, SRTFName(InpTestHTF));

   const int h = iATR(_Symbol, InpTestHTF, 14);
   if(h == INVALID_HANDLE)
     {
      Check("ATR handle for the live section", false);
      return;
     }

   double a[];
   ArraySetAsSeries(a, true);
   //--- The tester and a fresh attach both start with an unsynced history.
   //--- A short read here is not a failure of the engine, and reporting it as
   //--- one would make this test lie on a slow morning.
   if(CopyBuffer(h, 0, 1, 1, a) < 1 || a[0] <= 0.0)
     {
      Print("  SKIP  live history not available yet (ATR unreadable)");
      IndicatorRelease(h);
      return;
     }

   FVGConfig cfg;
   FVGZone   zone[];
   FVGBreak  brk[];
   FVGBias   bias;
   const bool ok = FVGCollect(zone, brk, bias, _Symbol, InpTestHTF, cfg, a[0]);
   if(!ok)
     {
      Print("  SKIP  live history not available yet (CopyRates short)");
      IndicatorRelease(h);
      return;
     }
   Check("the engine ran over real history", true);
   PrintFormat("        %d zones, %d breaks, bias %d, %d found, %d mitigated",
               ArraySize(zone), ArraySize(brk), bias.dir, bias.found, bias.dropped);

   const int scan = FVGScanDepth(cfg);
   const datetime now = TimeCurrent();

   bool geometry = true, fills = true, ages = true, ordered = true, future = false;
   for(int i = 0; i < ArraySize(zone); i++)
     {
      if(zone[i].top <= zone[i].bottom)
         geometry = false;
      if(zone[i].fill < 0.0 || zone[i].fill >= 1.0)
         fills = false;              // a fully filled zone must have been dropped
      if(zone[i].age < 1 || zone[i].age > scan)
         ages = false;
      if(zone[i].time > now)
         future = true;
      if(i > 0 && zone[i].time > zone[i - 1].time)
         ordered = false;
     }
   Check("every zone has a top above its bottom", geometry);
   Check("every fill is inside [0,1) after filtering", fills);
   Check("every age is inside the scan window", ages);
   Check("zones are ordered newest first", ordered);
   Check("no zone is dated in the future", !future);

   //--- The claim a gap zone MAKES, re-checked against the bars themselves:
   //--- the third candle never traded back to the first. If this holds on a
   //--- few hundred real bars, the detection means what the docs say.
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int checked = 0;
   bool gapsHold = true;
   for(int i = 0; i < ArraySize(zone); i++)
     {
      if(zone[i].kind != FVG_KIND_GAP)
         continue;
      const int s = iBarShift(_Symbol, InpTestHTF, zone[i].time, true);
      if(s < 0 || CopyRates(_Symbol, InpTestHTF, s, 3, r) < 3)
         continue;
      checked++;
      //--- r[0] is the newest of the three = the bar the zone completed on.
      if(zone[i].dir > 0)
        {
         if(MathAbs(r[0].low - zone[i].top) > InpTol ||
            MathAbs(r[2].high - zone[i].bottom) > InpTol ||
            r[0].low <= r[2].high)
            gapsHold = false;
        }
      else
        {
         if(MathAbs(r[0].high - zone[i].bottom) > InpTol ||
            MathAbs(r[2].low - zone[i].top) > InpTol ||
            r[0].high >= r[2].low)
            gapsHold = false;
        }
     }
   if(checked > 0)
      Check(StringFormat("all %d gap zones re-derive from their own three bars", checked),
            gapsHold);
   else
      Print("  SKIP  no gap zones in this window to re-derive");

   bool breaksOk = true;
   for(int i = 0; i < ArraySize(brk); i++)
     {
      if(brk[i].dir != 1 && brk[i].dir != -1)
         breaksOk = false;
      if(brk[i].time <= brk[i].swing)
         breaksOk = false;          // a break cannot precede the swing it broke
      if(i > 0 && brk[i].time > brk[i - 1].time)
         breaksOk = false;
     }
   Check("breaks are well formed and newest first", breaksOk);

   //--- And the setup on top of it.
   FVGSetup su;
   FVGBreak cbrk[];
   const double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(FVGEvaluate(su, cbrk, zone, bias, _Symbol, (ENUM_TIMEFRAMES)_Period,
                  cfg, price, a[0]))
     {
      Check("the setup evaluated", true);
      PrintFormat("        state %s, dir %d, zone %d, %d chart breaks",
                  FVGStateName(su.state), su.dir, su.zone, ArraySize(cbrk));

      if(su.state == FVG_STATE_TRIGGER)
        {
         //--- A stop on the wrong side of the entry is the one error here that
         //--- costs money rather than clarity.
         Check("the stop is on the losing side of the entry",
               (su.dir > 0 ? su.sl < su.entry : su.sl > su.entry),
               StringFormat("(entry %.5f sl %.5f)", su.entry, su.sl));
         Check("the target is on the winning side of the entry",
               (su.dir > 0 ? su.tp > su.entry : su.tp < su.entry),
               StringFormat("(entry %.5f tp %.5f)", su.entry, su.tp));
         Check("the reward:risk is a positive number", su.rr > 0.0);
        }
      else
         Check("a setup below TRIGGER carries no entry price", su.time == 0);
     }
   else
      Print("  SKIP  chart history not available yet for the setup");

   IndicatorRelease(h);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   Print("=====================================================");
   Print("HullTrendFVG detection self-test");
   Print("=====================================================");

   TestExtremes();
   TestFill();
   TestStructure();
   TestSelection();
   TestSortAndClamps();
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
