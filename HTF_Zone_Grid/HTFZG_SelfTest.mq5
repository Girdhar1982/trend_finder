//+------------------------------------------------------------------+
//|                                               HTFZG_SelfTest.mq5 |
//|                                                                  |
//|  GEOMETRY SELF-TEST for HTF_Zone_Grid_3Level_EA                  |
//|                                                                  |
//|  WHY THIS EXISTS                                                 |
//|  The grid builder is the part that can lose real money quietly.  |
//|  A sign error in the SELL ladder, an off-by-one in the legal     |
//|  band, a lot calculation that rounds up instead of down - none   |
//|  of these crash. They place a slightly wrong ladder, and in a    |
//|  backtest they look like ordinary losing trades.                 |
//|                                                                  |
//|  So the geometry is checked against hand-computed cases with no  |
//|  market data involved, including the worked example from the     |
//|  spec (BUY zone 2500-2502, sweep 2495).                          |
//|                                                                  |
//|  HOW TO RUN                                                      |
//|    Compile, drag onto any chart. Results print to the Experts    |
//|    tab. Look for the final verdict line.                         |
//|                                                                  |
//|  WHEN TO RUN                                                     |
//|    After ANY edit to HTFZG_Grid.mqh. Non-negotiable.             |
//|                                                                  |
//|  NOTE ON LOT ASSERTIONS                                          |
//|    Lot sizing depends on the chart symbol's contract spec, so    |
//|    the lot cases assert RELATIONSHIPS (all levels equal; nothing |
//|    exceeds Level 1) rather than absolute numbers. Those are the  |
//|    properties INVARIANT 2 actually promises, and they hold on    |
//|    any symbol.                                                   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property version   "1.00"
#property script_show_inputs
#property description "Validates HTF_Zone_Grid grid geometry against hand-computed cases."

#include "HTFZG_Types.mqh"
#include "HTFZG_Grid.mqh"

input double InpTolerance = 1e-6;      // Floating-point comparison tolerance

int g_pass = 0;
int g_fail = 0;

//+------------------------------------------------------------------+
void Check(const string name, const bool ok, const string detail = "")
  {
   if(ok) { g_pass++; PrintFormat("  PASS  %s", name); }
   else   { g_fail++; PrintFormat("  FAIL  %s %s", name, detail); }
  }

//+------------------------------------------------------------------+
void CheckNear(const string name, const double got, const double want)
  {
   const bool ok = (MathAbs(got - want) <= MathMax(InpTolerance, MathAbs(want) * 1e-6));
   Check(name, ok, StringFormat("(got %.8f, want %.8f)", got, want));
  }

//+------------------------------------------------------------------+
//| Default config: the spec defaults.                               |
//+------------------------------------------------------------------+
void BaseCfg(HTFZGGridCfg &c)
  {
   c.riskPerLevel   = 0.5;
   c.maxLevels      = 3;
   c.spacingATR     = 0.4;
   c.slBufferATR    = 0.5;
   c.tp1R           = 1.0;
   c.tp2R           = 2.0;
   c.deepestATR     = 0.2;
   c.sweepBufferATR = 0.3;
   c.entryTolATR    = 0.5;
   c.minRSpread     = 0.0;   // geometry cases are symbol-independent; no spread gate
   c.expiryHours    = 4;
   c.bePoints       = 100;
   c.equalRisk      = false;
   c.magic          = 970301;
   c.slippage       = 20;
  }

//+------------------------------------------------------------------+
//| Build a signal by hand. No market data is read.                  |
//+------------------------------------------------------------------+
void MakeSignal(HTFZGSignal &s, const ENUM_HTFZG_DIR dir, const double zLow,
                const double zHigh, const double sweep, const double bos, const double atr)
  {
   s.Reset();
   s.dir          = dir;
   s.zone.low     = zLow;
   s.zone.high    = zHigh;
   s.zone.valid   = true;
   s.zone.touches = 2;
   s.sweepExtreme = sweep;
   s.bosPrice     = bos;
   s.atr15        = atr;
   s.atr5         = atr;
   s.sTrend = 20; s.sZone = 20; s.sSweep = 20; s.sBOS = 15; s.sVol = 10;
   s.Sum();
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=========================================================");
   Print("HTF_Zone_Grid geometry self-test");
   PrintFormat("Symbol %s  digits=%d  minLot=%.2f  step=%.2f  stopLevel=%d",
               _Symbol, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
   Print("=========================================================");

   HTFZGGridCfg cfg;  BaseCfg(cfg);
   HTFZGSignal  sig;
   HTFZGGrid    g;
   string       why = "";

   //--- The cases below use the spec's gold-scale prices (~2500) because
   //--- that is what its worked example uses. HTFZG_BuildGrid sizes a lot
   //--- before it returns, so on a symbol whose contract cannot express a
   //--- 24-unit stop at this risk budget EVERY case would fail for a
   //--- reason that has nothing to do with geometry. Say so plainly
   //--- rather than printing ten misleading failures.
   const double probe = HTFZG_LotForLevel(_Symbol, 2500.0, 2476.0,
                                          cfg.riskPerLevel,
                                          AccountInfoDouble(ACCOUNT_EQUITY));
   if(probe <= 0.0)
     {
      PrintFormat("ABORTED: %s cannot size a 24.0-price-unit stop at %.2f%% of "
                  "%.2f equity - these cases are written at gold scale.",
                  _Symbol, cfg.riskPerLevel, AccountInfoDouble(ACCOUNT_EQUITY));
      Print("Run this script on XAUUSD (or any symbol priced near 2500). "
            "This is a scale mismatch, NOT a geometry failure.");
      return;
     }

   //================================================================
   // CASE 1 - BUY, the spec's worked example.
   //   Zone 2500-2502, sweep 2495, BOS 2501, ATR 4.0
   //   sharedSL = 2495 - 0.5*4 = 2493
   //   R        = 2501 - 2493  = 8
   //   L1 2501, L2 2501-1.6 = 2499.4, L3 2499.4-1.6 = 2497.8
   //   band     [2500-1.2, 2502] = [2498.8, 2502]
   //   L3 2497.8 is BELOW 2498.8 -> ladder must drop to 2 levels
   //   tp1 = 2501+8 = 2509, tp2 = 2501+16 = 2517
   //================================================================
   Print("CASE 1 - BUY, spec worked example (2500-2502, sweep 2495)");
   MakeSignal(sig, HTFZG_DIR_BUY, 2500.0, 2502.0, 2495.0, 2501.0, 4.0);
   bool ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("built", ok, why);
   if(ok)
     {
      CheckNear("sharedSL", g.sharedSL, 2493.0);
      CheckNear("1R",       g.oneR,     8.0);
      CheckNear("TP1",      g.tp1,      2509.0);
      CheckNear("TP2",      g.tp2,      2517.0);
      CheckNear("L1",       g.lv[0].price, 2501.0);
      CheckNear("L2",       g.lv[1].price, 2499.4);
      Check("L3 outside the band dropped the ladder to 2",
            g.count == 2, StringFormat("(count=%d)", g.count));
     }

   //================================================================
   // CASE 2 - SELL, mirrored. Same distances, opposite sign.
   //   Zone 2500-2502, sweep 2507, BOS 2501, ATR 4.0
   //   sharedSL = 2507 + 2 = 2509 ; R = 8 ; tp2 = 2501-16 = 2485
   //================================================================
   Print("CASE 2 - SELL, mirrored");
   MakeSignal(sig, HTFZG_DIR_SELL, 2500.0, 2502.0, 2507.0, 2501.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("built", ok, why);
   if(ok)
     {
      CheckNear("sharedSL", g.sharedSL, 2509.0);
      CheckNear("1R",       g.oneR,     8.0);
      CheckNear("TP1",      g.tp1,      2493.0);
      CheckNear("TP2",      g.tp2,      2485.0);
      CheckNear("L2 steps UP for a sell", g.lv[1].price, 2502.6);
     }

   //================================================================
   // CASE 3 - a wide zone that comfortably holds all three levels.
   //   Zone 2480-2502, sweep 2478, BOS 2500, ATR 4.0
   //   band [2478.8, 2502] ; deepest 2478-0.8 = 2477.2
   //   L1 2500, L2 2498.4, L3 2496.8 - all legal
   //================================================================
   Print("CASE 3 - wide zone keeps all three levels");
   MakeSignal(sig, HTFZG_DIR_BUY, 2480.0, 2502.0, 2478.0, 2500.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("built", ok, why);
   if(ok)
     {
      Check("three levels", g.count == 3, StringFormat("(count=%d)", g.count));
      CheckNear("L3", g.lv[2].price, 2496.8);
      Check("levels descend for a buy",
            g.lv[0].price > g.lv[1].price && g.lv[1].price > g.lv[2].price);
      Check("every level is above the shared SL",
            g.lv[2].price > g.sharedSL);
     }

   //================================================================
   // CASE 4 - L3 would sit deeper than the sweep extreme.
   //   Zone 2470-2502, sweep 2498, BOS 2500, ATR 4.0
   //   deepest = 2498 - 0.8 = 2497.2 ; L3 = 2496.8 < 2497.2 -> drop to 2
   //   (the band alone would have allowed it - this is the depth cap)
   //================================================================
   Print("CASE 4 - depth cap drops the ladder to 2");
   MakeSignal(sig, HTFZG_DIR_BUY, 2470.0, 2502.0, 2498.0, 2500.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("built", ok, why);
   if(ok)
      Check("dropped to 2 by the depth cap", g.count == 2,
            StringFormat("(count=%d)", g.count));

   //================================================================
   // CASE 5 - no room for a second level at all -> REFUSE.
   //   Zone 2500-2502, sweep 2499.6, BOS 2501, ATR 4.0
   //   deepest = 2499.6-0.8 = 2498.8 ; L2 = 2499.4 is inside the band
   //   but the ladder is still capped... so squeeze harder: ATR 20
   //   L2 = 2501 - 8 = 2493, band low = 2500 - 6 = 2494 -> L2 illegal
   //================================================================
   Print("CASE 5 - no room for L2 refuses the trade");
   MakeSignal(sig, HTFZG_DIR_BUY, 2500.0, 2502.0, 2496.0, 2501.0, 20.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("refused", !ok, StringFormat("(why=%s)", why));

   //================================================================
   // CASE 6 - Level 1 chased far above the zone -> REFUSE.
   //   Zone 2480-2490, BOS 2500. entryTol = 0.5*4 = 2, so anything
   //   above 2492 is a chase.
   //================================================================
   Print("CASE 6 - chased entry refuses the trade");
   MakeSignal(sig, HTFZG_DIR_BUY, 2480.0, 2490.0, 2478.0, 2500.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("refused", !ok, StringFormat("(why=%s)", why));

   //================================================================
   // CASE 7 - a stop on the wrong side of the entry -> REFUSE.
   //   BUY with the sweep extreme ABOVE the BOS price is incoherent
   //   and must never reach the broker.
   //================================================================
   Print("CASE 7 - inverted stop refuses the trade");
   MakeSignal(sig, HTFZG_DIR_BUY, 2480.0, 2502.0, 2510.0, 2500.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   Check("refused", !ok, StringFormat("(why=%s)", why));

   //================================================================
   // CASE 8 - INVARIANT 2: fixed lots. Every level identical.
   //================================================================
   Print("CASE 8 - fixed lots across levels (INVARIANT 2)");
   BaseCfg(cfg);
   MakeSignal(sig, HTFZG_DIR_BUY, 2480.0, 2502.0, 2478.0, 2500.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   if(!ok)
      Check("built", false, why);
   else
     {
      bool same = true;
      for(int i = 1; i < g.count; i++)
         if(MathAbs(g.lv[i].lots - g.lv[0].lots) > 1e-8)
            same = false;
      Check("all level lots identical", same,
            StringFormat("(L1=%.2f L2=%.2f L3=%.2f)",
                         g.lv[0].lots, (g.count>1?g.lv[1].lots:0),
                         (g.count>2?g.lv[2].lots:0)));
      Check("no lot exceeds Level 1 (no martingale shape)",
            (g.count < 2 || g.lv[1].lots <= g.lv[0].lots + 1e-8)
         && (g.count < 3 || g.lv[2].lots <= g.lv[0].lots + 1e-8));
     }

   //================================================================
   // CASE 9 - equalRisk = true: the literal spec reading. Lots MAY
   // differ, and deeper levels legitimately size larger. This case
   // documents that behaviour rather than endorsing it - it is why
   // the default is false.
   //================================================================
   Print("CASE 9 - equalRisk mode sizes deeper levels LARGER (documented, not default)");
   BaseCfg(cfg);
   cfg.equalRisk = true;
   MakeSignal(sig, HTFZG_DIR_BUY, 2480.0, 2502.0, 2478.0, 2500.0, 4.0);
   ok = HTFZG_BuildGrid(_Symbol, sig, cfg, g, why);
   if(ok && g.count >= 2)
      Check("deeper level is >= Level 1 in equalRisk mode",
            g.lv[1].lots >= g.lv[0].lots - 1e-8,
            StringFormat("(L1=%.2f L2=%.2f)", g.lv[0].lots, g.lv[1].lots));
   else
      Check("equalRisk build", ok, why);

   //================================================================
   // CASE 10 - R, TP1 and TP2 are measured from Level 1 (INVARIANT 4)
   // and are unaffected by how many levels survived validation.
   //================================================================
   Print("CASE 10 - targets anchor to Level 1, not to the ladder");
   BaseCfg(cfg);
   MakeSignal(sig, HTFZG_DIR_BUY, 2480.0, 2502.0, 2478.0, 2500.0, 4.0);
   HTFZGGrid g3;
   const bool ok3 = HTFZG_BuildGrid(_Symbol, sig, cfg, g3, why);
   cfg.maxLevels = 2;
   HTFZGGrid g2;
   const bool ok2 = HTFZG_BuildGrid(_Symbol, sig, cfg, g2, why);
   if(ok3 && ok2)
     {
      Check("level counts differ as configured", g3.count == 3 && g2.count == 2,
            StringFormat("(%d vs %d)", g3.count, g2.count));
      CheckNear("TP2 identical regardless of level count", g2.tp2, g3.tp2);
      CheckNear("sharedSL identical regardless of level count", g2.sharedSL, g3.sharedSL);
     }
   else
      Check("both ladders built", false, why);

   //================================================================
   Print("=========================================================");
   PrintFormat("VERDICT: %d passed, %d FAILED", g_pass, g_fail);
   if(g_fail == 0)
      Print("VERDICT: grid geometry is intact.");
   else
      Print("VERDICT: *** GEOMETRY IS BROKEN - DO NOT TRADE THIS BUILD ***");
   Print("=========================================================");
  }
//+------------------------------------------------------------------+
