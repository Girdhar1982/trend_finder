//+------------------------------------------------------------------+
//|                                     HTF_Zone_Grid_3Level_EA.mq5 |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+==================================================================+
//|                                                                  |
//|                  ORIENTATION FOR FUTURE MAINTAINERS              |
//|                                                                  |
//| WHAT THIS IS                                                     |
//| A high-selectivity, hard-capped scale-in EA. It waits for a      |
//| six-factor confluence to score 80/100, then places at most three |
//| fixed-lot levels INSIDE the zone that produced the signal, all   |
//| sharing one stop loss.                                           |
//|                                                                  |
//| WHAT THIS IS NOT                                                 |
//| It is not a martingale and must never become one. No lot         |
//| multiplier, no recovery level, no averaging into a loser outside |
//| the zone, no fourth level, no grid without a score of 80. Those  |
//| are not tuning parameters - they are the reason the risk is      |
//| bounded at all. A grid EA that relaxes them is a different and   |
//| much worse strategy wearing this one's filename.                 |
//|                                                                  |
//| THE ONE-PARAGRAPH THESIS                                         |
//| Scaling in is only defensible when the scale-in prices were      |
//| decided BEFORE entry and are all inside a level you would have   |
//| bought anyway. Levels 2 and 3 are not a response to being wrong; |
//| they are a plan for getting a better average inside a zone the   |
//| model already validated. The instant price leaves that zone the  |
//| ladder stops, and one shared stop caps the whole idea.           |
//|                                                                  |
//+==================================================================+
//|                                                                  |
//| FILE MAP - fix bugs in the module that owns the concept          |
//|                                                                  |
//|   HTFZG_Types.mqh     shared structs/enums. No logic.            |
//|   HTFZG_Analysis.mqh  THE MODEL. Steps 2-8. Read-only, no        |
//|                       orders, no drawing, deterministic.         |
//|   HTFZG_Grid.mqh      EXECUTION. Steps 9-12. Geometry, sizing,   |
//|                       placement, management, teardown.           |
//|   HTFZG_Panel.mqh     Dashboard and chart objects. No decisions. |
//|   HTFZG_SelfTest.mq5  Offline checks on the grid geometry.       |
//|                                                                  |
//| This file is the orchestrator: inputs, lifecycle, safety gate,   |
//| the state machine, and the daily book. It holds no strategy      |
//| maths of its own.                                                |
//|                                                                  |
//+==================================================================+
//|                                                                  |
//| INVARIANT 1 - CLOSED BARS ONLY                                   |
//| The scan runs once per closed M5 bar. Live price is used for the |
//| spread gate, the TP1 trigger and fills - nowhere else.           |
//|                                                                  |
//| INVARIANT 2 - ONE GRID PER SYMBOL, EVER                          |
//| State is a single HTFZGGrid. Before any new grid the TERMINAL is |
//| asked whether orders with our magic still exist; g_grid is never |
//| trusted for that, because a stop-out, a TP or a manual close     |
//| leaves the struct stale with no event guaranteed to have run.    |
//|                                                                  |
//| INVARIANT 3 - PRINT THE RESOLVED CONFIG AT OnInit                |
//| MT5 silently reuses a saved tester .set over recompiled          |
//| defaults. Without this line, results get attributed to inputs    |
//| the EA never actually received. Read it before trusting a run.   |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.00"
#property description "HTF zone grid - 3 fixed-lot levels inside one confluence zone."
#property description "Score >= 80 required. One shared SL. Not a martingale."

#include "HTFZG_Types.mqh"
#include "HTFZG_Analysis.mqh"
#include "HTFZG_Grid.mqh"
#include "HTFZG_Panel.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                           |
//|                                                                  |
//| Groups A-C are the spec verbatim. Groups D-E expose the values   |
//| the spec used as literals in its prose (0.3 ATR sweep depth,     |
//| 3-bar reclaim, 4h expiry, 100pt breakeven) plus the four zone    |
//| parameters it never named at all. Every default IS the spec      |
//| value, so a default run is the specified strategy.               |
//+------------------------------------------------------------------+
input group                  "A. Risk"
input double InpRiskPerLevel      = 0.5;      // Risk per level (% of equity)
input int    InpMaxGridLevels     = 3;        // Max grid levels (hard ceiling 3)
input int    InpMinScore          = 80;       // Minimum confluence score to trade
input double InpMaxSpreadPoints   = 300;      // Max spread (points)
input double InpMaxDailyLossPct   = 3.0;      // Daily loss cap (%) - closes everything
input int    InpCooldownMin       = 90;       // Cooldown after a grid closes (minutes)
input int    InpMaxTradesPerDay   = 2;        // Max grids per day

input group                  "B. Model"
input ENUM_HTFZG_TREND InpTrendMode = HTFZG_TREND_STRICT; // H4 trend strictness
input int    InpEMA4H             = 200;      // H4 EMA period (trend filter)
input int    InpSwingLB           = 50;       // H4 swing lookback (bars)
input int    InpATRPeriod         = 14;       // ATR period

input group                  "C. Grid geometry"
input double InpGridSpacingATR    = 0.4;      // Spacing between levels (x ATR 15M)
input double InpSharedSL_ATR_Buffer = 0.5;    // Shared SL beyond sweep extreme (x ATR 15M)
input double InpTP1_R             = 1.0;      // TP1 (R from Level 1) - closes 50%
input double InpTP2_R             = 2.0;      // TP2 (R from Level 1) - closes the rest

input group                  "D. Tolerances (spec literals + zone definition)"
input double InpSweepDepthATR     = 0.30;     // Sweep must exceed the zone by this x ATR
input int    InpSweepWindowBars   = 12;       // How far back a sweep may have happened (M15)
input int    InpReclaimBars       = 3;        // Bars allowed to reclaim the zone
input int    InpBOSLookbackBars   = 60;       // M5 swing scan depth for the structure break
input double InpDeepestLevelATR   = 0.20;     // Level 3 may not pass the sweep by more
input double InpEntryTolATR       = 0.50;     // How far past the zone Level 1 may sit
input double InpPivotNearATR      = 0.50;     // Daily S1/R1 this close scores the bonus
input double InpVolMult           = 1.50;     // Break-bar tick volume vs its MA
input int    InpVolMA             = 20;       // Volume MA period
input int    InpZoneLookbackH1    = 150;      // H1 bars scanned for the zone
input double InpZoneClusterATR    = 0.50;     // Merge pivots closer than this x ATR(H1)
input int    InpZoneMinTouches    = 2;        // Touches required to call a zone "strong"
input double InpZoneMinHeightATR  = 0.20;     // Pad a hairline zone to this x ATR(H1)
input double InpMinR_SpreadMult   = 3.0;      // 1R must be >= this x the current spread
input int    InpPendingExpiryHours = 4;       // Unfilled levels expire after N hours
input int    InpBreakevenPoints   = 100;      // BE offset after TP1 (points)

input group                  "E. Session and plumbing"
input int    InpStartHour         = 0;        // Trading window start (server hour)
input int    InpEndHour           = 23;       // Trading window end (inclusive)
input bool   InpEqualRiskPerLevel = false;    // See INVARIANT 2 in HTFZG_Grid.mqh.
                                              // false = fixed lots (safe, default)
                                              // true  = flat 0.5% per level (lots GROW)
input long   InpMagic             = 970301;   // Magic number
input int    InpSlippage          = 20;       // Max deviation (points)

input group                  "F. Display"
input bool   InpShowPanel         = true;     // Show the dashboard
input bool   InpShowVisuals       = true;     // Draw zone, levels and shared SL
input int    InpPanelX            = 12;       // Panel inset X (pixels)
input int    InpPanelY            = 22;       // Panel inset Y (pixels)
input int    InpFontSize          = 9;        // Panel font size
input color  InpPanelText         = clrSilver;      // Panel text colour
input color  InpPanelBg           = C'22,26,34';    // Panel backing plate
input color  InpZoneColor         = C'40,60,90';    // Zone rectangle
input color  InpLevelColor        = clrDodgerBlue;  // Grid level lines
input color  InpSLColor           = clrTomato;      // Shared stop line

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
HTFZGHandles     g_h;
HTFZGCfg         g_cfg;
HTFZGGridCfg     g_gcfg;
HTFZGGrid        g_grid;
HTFZGSignal      g_sig;              // last scan, for the panel
HTFZGDayBook     g_book;
ENUM_HTFZG_STATE g_state   = HTFZG_IDLE;
datetime         g_lastBar = 0;
const string     g_prefix  = "HTFZG_";

//+------------------------------------------------------------------+
//| Rejection tally.                                                 |
//|                                                                  |
//| A strategy this selective will spend most of a backtest doing    |
//| nothing, and "3 trades in a year" is uninterpretable without     |
//| knowing WHICH gate ate the other 70,000 bars. Counting the       |
//| reject reasons turns that into a ranked list, which is the       |
//| difference between tuning the right parameter and tuning at      |
//| random. Printed once at OnDeinit.                                |
//+------------------------------------------------------------------+
string g_rejName[];
int    g_rejCount[];

void TallyReject(const string r)
  {
   if(r == "")
      return;
   for(int i = 0; i < ArraySize(g_rejName); i++)
      if(g_rejName[i] == r)
        { g_rejCount[i]++; return; }
   const int n = ArraySize(g_rejName);
   ArrayResize(g_rejName, n + 1);
   ArrayResize(g_rejCount, n + 1);
   g_rejName[n]  = r;
   g_rejCount[n] = 1;
  }

void PrintRejectTally()
  {
   const int n = ArraySize(g_rejName);
   if(n == 0)
     { Print("HTFZG SCAN TALLY: no scan was ever blocked."); return; }

   int total = 0;
   for(int i = 0; i < n; i++)
      total += g_rejCount[i];

   int idx[];
   ArrayResize(idx, n);
   for(int i = 0; i < n; i++) idx[i] = i;
   for(int i = 0; i < n - 1; i++)              // selection sort; n is tiny
      for(int j = i + 1; j < n; j++)
         if(g_rejCount[idx[j]] > g_rejCount[idx[i]])
           { const int t = idx[i]; idx[i] = idx[j]; idx[j] = t; }

   Print("HTFZG SCAN TALLY - why each scanned M5 bar did not open a grid:");
   for(int i = 0; i < n; i++)
      PrintFormat("   %7d  (%5.1f%%)  %s", g_rejCount[idx[i]],
                  100.0 * g_rejCount[idx[i]] / total, g_rejName[idx[i]]);
   PrintFormat("   %7d           TOTAL blocked scans", total);
  }

//+------------------------------------------------------------------+
//| Roll the daily book on a server DATE change.                     |
//|                                                                  |
//| Date, not a timer: an EA started on Friday evening must not have |
//| its loss cap cleared by "24 hours elapsed" somewhere inside the  |
//| weekend gap. The lockout survives exactly until the next trading |
//| date actually begins.                                            |
//+------------------------------------------------------------------+
void RollDayBook()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   const datetime today = StructToTime(t);

   if(g_book.day == today)
      return;

   if(g_book.day != 0)
      PrintFormat("HTFZG: new trading day - previous day closed with %d grid(s), PnL %.2f.",
                  g_book.gridsToday, g_book.realisedPnL);

   g_book.day         = today;
   g_book.startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_book.realisedPnL = 0.0;
   g_book.gridsToday  = 0;
   g_book.lockedOut   = false;
   // cooldownUntil deliberately survives the rollover - a grid that closed
   // at 23:50 still owes its cooldown at 00:05.
  }

//+------------------------------------------------------------------+
//| Realised loss today, as a positive percentage of the equity the  |
//| day opened with. Floating PnL is included: a 3% cap that only    |
//| counts closed trades is not a cap, it is a delay.                |
//+------------------------------------------------------------------+
double DailyLossPct()
  {
   if(g_book.startEquity <= 0.0)
      return 0.0;
   const double now = AccountInfoDouble(ACCOUNT_EQUITY);
   const double dd  = g_book.startEquity - now;
   return (dd <= 0.0 ? 0.0 : dd / g_book.startEquity * 100.0);
  }

//+------------------------------------------------------------------+
//| True once per closed bar of the given timeframe.                 |
//+------------------------------------------------------------------+
bool NewBar(const ENUM_TIMEFRAMES tf)
  {
   const datetime t = iTime(_Symbol, tf, 0);
   if(t == 0 || t == g_lastBar)
      return false;
   g_lastBar = t;
   return true;
  }

//+------------------------------------------------------------------+
//| STEP 1 - the safety gate. Every reason to refuse, in one place.  |
//|                                                                  |
//| Writes the reason into g_sig.reject so an idle EA can always     |
//| say why it is idle - see the panel note in HTFZG_Panel.mqh.      |
//+------------------------------------------------------------------+
bool SafetyGate()
  {
   if(g_book.lockedOut)
     { g_sig.reject = "daily loss lockout"; return false; }

   if(TimeCurrent() < g_book.cooldownUntil)
     {
      g_sig.reject = StringFormat("cooldown %d min",
                                  (int)((g_book.cooldownUntil - TimeCurrent()) / 60));
      return false;
     }

   if(g_book.gridsToday >= InpMaxTradesPerDay)
     { g_sig.reject = "max grids today"; return false; }

   const double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
     { g_sig.reject = StringFormat("spread %.0f > %.0f", spread, InpMaxSpreadPoints);
       return false; }

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   const bool inWindow = (InpStartHour <= InpEndHour
                          ? (t.hour >= InpStartHour && t.hour <= InpEndHour)
                          : (t.hour >= InpStartHour || t.hour <= InpEndHour));
   if(!inWindow)
     { g_sig.reject = "outside session"; return false; }

   //--- INVARIANT 2: ask the terminal, never the struct
   if(HTFZG_GridExists(_Symbol, InpMagic))
     { g_sig.reject = "grid already live"; return false; }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { g_sig.reject = "trading not allowed"; return false; }

   return true;
  }

//+------------------------------------------------------------------+
//| Adopt a grid that already exists at startup.                     |
//|                                                                  |
//| A recompile, a terminal restart or a reconnect all re-run        |
//| OnInit with live orders on the books. Without this the EA would  |
//| consider itself IDLE, decline to manage those legs, and happily  |
//| open a second grid on top of them.                               |
//|                                                                  |
//| Only what the broker can tell us is recovered - the legs, the    |
//| stop, the target. The score and the zone that produced it are    |
//| gone, and the panel says so rather than inventing them.          |
//+------------------------------------------------------------------+
void AdoptExistingGrid()
  {
   if(!HTFZG_GridExists(_Symbol, InpMagic))
      return;

   g_grid.Reset();
   g_grid.count = 0;

   for(int i = PositionsTotal() - 1; i >= 0 && g_grid.count < HTFZG_MAX_LEVELS; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;

      const int k = g_grid.count++;
      g_grid.lv[k].ticket = t;
      g_grid.lv[k].price  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_grid.lv[k].lots   = PositionGetDouble(POSITION_VOLUME);
      g_grid.lv[k].placed = true;
      g_grid.lv[k].filled = true;

      g_grid.dir      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY
                         ? HTFZG_DIR_BUY : HTFZG_DIR_SELL);
      g_grid.sharedSL = PositionGetDouble(POSITION_SL);
      g_grid.tp2      = PositionGetDouble(POSITION_TP);
     }

   double vol = 0.0, avg = 0.0;
   HTFZG_LiveBook(_Symbol, InpMagic, vol, avg);
   g_grid.avgEntry = avg;
   g_grid.opened   = TimeCurrent();
   g_grid.expiry   = (datetime)(TimeCurrent() + (long)InpPendingExpiryHours * 3600);

   //--- TP1 is unknowable after the fact, so assume it was already taken.
   //--- Erring the other way would re-fire a 50% close on a grid that had
   //--- one, which is a real loss; assuming it is done only forfeits a
   //--- partial the EA cannot prove it still owes.
   g_grid.tp1Done = true;
   g_grid.tp1     = 0.0;
   g_state        = HTFZG_PARTIAL;

   PrintFormat("HTFZG: adopted an existing grid - %d leg(s), %s, avg %.5f, SL %.5f, TP %.5f. "
               "Score/zone unknown (pre-restart). TP1 assumed already taken.",
               g_grid.count, (g_grid.dir == HTFZG_DIR_BUY ? "BUY" : "SELL"),
               g_grid.avgEntry, g_grid.sharedSL, g_grid.tp2);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. clamp and copy inputs. Nothing below this file reads an input.
   g_cfg.trendMode      = InpTrendMode;
   g_cfg.swingLB        = MathMax(10,  InpSwingLB);
   g_cfg.zoneLB         = MathMax(30,  InpZoneLookbackH1);
   g_cfg.zoneClusterATR = MathMax(0.05, InpZoneClusterATR);
   g_cfg.zoneMinTouch   = MathMax(1,   InpZoneMinTouches);
   g_cfg.zoneMinHtATR   = MathMax(0.01, InpZoneMinHeightATR);
   g_cfg.sweepDepthATR  = MathMax(0.01, InpSweepDepthATR);
   g_cfg.sweepWindow    = MathMax(1,   InpSweepWindowBars);
   g_cfg.reclaimBars    = MathMax(1,   InpReclaimBars);
   g_cfg.bosLookback    = MathMax(10,  InpBOSLookbackBars);
   g_cfg.volMult        = MathMax(1.0, InpVolMult);
   g_cfg.volMA          = MathMax(2,   InpVolMA);
   g_cfg.pivotNearATR   = MathMax(0.0, InpPivotNearATR);

   g_gcfg.riskPerLevel   = MathMax(0.01, InpRiskPerLevel);
   g_gcfg.maxLevels      = MathMax(2, MathMin(HTFZG_MAX_LEVELS, InpMaxGridLevels));
   g_gcfg.spacingATR     = MathMax(0.05, InpGridSpacingATR);
   g_gcfg.slBufferATR    = MathMax(0.05, InpSharedSL_ATR_Buffer);
   g_gcfg.tp1R           = MathMax(0.1, InpTP1_R);
   g_gcfg.tp2R           = MathMax(g_gcfg.tp1R + 0.1, InpTP2_R);
   g_gcfg.deepestATR     = MathMax(0.0, InpDeepestLevelATR);
   g_gcfg.sweepBufferATR = g_cfg.sweepDepthATR;   // the band bound IS the sweep depth
   g_gcfg.entryTolATR    = MathMax(0.0, InpEntryTolATR);
   g_gcfg.minRSpread     = MathMax(0.0, InpMinR_SpreadMult);
   g_gcfg.expiryHours    = MathMax(1,  InpPendingExpiryHours);
   g_gcfg.bePoints       = MathMax(0,  InpBreakevenPoints);
   g_gcfg.equalRisk      = InpEqualRiskPerLevel;
   g_gcfg.magic          = InpMagic;
   g_gcfg.slippage       = MathMax(1,  InpSlippage);

   HTFZG_TradeInit(g_gcfg);

   //--- 2. handles, once (INVARIANT 3 in HTFZG_Analysis.mqh)
   const int atrP = MathMax(1, InpATRPeriod);
   g_h.ema4h = iMA (_Symbol, PERIOD_H4,  MathMax(2, InpEMA4H), 0, MODE_EMA, PRICE_CLOSE);
   g_h.atr15 = iATR(_Symbol, PERIOD_M15, atrP);
   g_h.atr5  = iATR(_Symbol, PERIOD_M5,  atrP);
   g_h.atr1h = iATR(_Symbol, PERIOD_H1,  atrP);
   if(!g_h.Valid())
     {
      Print("HTFZG: could not create the indicator handles - refusing to start.");
      return INIT_FAILED;
     }

   //--- 3/4. daily book, then adopt anything already live
   g_book.day = 0;
   RollDayBook();
   g_state = HTFZG_IDLE;
   g_grid.Reset();
   g_sig.Reset();
   AdoptExistingGrid();

   //--- 5. the resolved configuration (INVARIANT 3). Read this line before
   //---    trusting any tester result: a stale Profiles\Tester\*.set will
   //---    silently override recompiled defaults with nothing else to show it.
   PrintFormat("HTFZG resolved config: risk/level=%.2f%% levels=%d minScore=%d "
               "maxSpread=%.0f dailyLoss=%.2f%% cooldown=%dm maxGrids/day=%d | "
               "ema4h=%d swingLB=%d atr=%d | spacing=%.2fATR slBuf=%.2fATR "
               "tp1=%.2fR tp2=%.2fR | sweep=%.2fATR/%db reclaim=%db deepest=%.2fATR "
               "entryTol=%.2fATR | zone lb=%d cluster=%.2fATR touches=%d minHt=%.2fATR | "
               "expiry=%dh be=%dpts equalRisk=%s hours=%d-%d magic=%d trendMode=%s",
               g_gcfg.riskPerLevel, g_gcfg.maxLevels, InpMinScore,
               InpMaxSpreadPoints, InpMaxDailyLossPct, InpCooldownMin, InpMaxTradesPerDay,
               InpEMA4H, g_cfg.swingLB, atrP,
               g_gcfg.spacingATR, g_gcfg.slBufferATR, g_gcfg.tp1R, g_gcfg.tp2R,
               g_cfg.sweepDepthATR, g_cfg.sweepWindow, g_cfg.reclaimBars,
               g_gcfg.deepestATR, g_gcfg.entryTolATR,
               g_cfg.zoneLB, g_cfg.zoneClusterATR, g_cfg.zoneMinTouch, g_cfg.zoneMinHtATR,
               g_gcfg.expiryHours, g_gcfg.bePoints,
               (g_gcfg.equalRisk ? "TRUE (lots grow!)" : "false (fixed lots)"),
               InpStartHour, InpEndHour, (int)InpMagic,
               EnumToString(g_cfg.trendMode));

   //--- Symbol contract specs. Risk sizing is entirely a function of these,
   //--- and they are the first thing that differs when the EA is pointed at
   //--- a new symbol - a min lot that cannot express the risk budget refuses
   //--- every trade with a reason that looks nothing like "wrong symbol".
   PrintFormat("HTFZG symbol specs: %s digits=%d point=%.8f tickSize=%.8f tickValue=%.5f "
               "contract=%.2f minLot=%.4f maxLot=%.2f lotStep=%.4f stopLevel=%d spread=%d",
               _Symbol, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_POINT),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));

   if(g_gcfg.equalRisk)
      Print("HTFZG: WARNING - InpEqualRiskPerLevel is TRUE. Deeper levels will use "
            "LARGER lots than Level 1. See INVARIANT 2 in HTFZG_Grid.mqh.");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Release handles and clear our objects by prefix.                 |
//|                                                                  |
//| Positions are deliberately NOT closed here. A recompile, a       |
//| timeframe change or a parameter edit is not a reason to exit a   |
//| live trade, and OnDeinit runs for all of them.                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_h.ema4h != INVALID_HANDLE) IndicatorRelease(g_h.ema4h);
   if(g_h.atr15 != INVALID_HANDLE) IndicatorRelease(g_h.atr15);
   if(g_h.atr5  != INVALID_HANDLE) IndicatorRelease(g_h.atr5);
   if(g_h.atr1h != INVALID_HANDLE) IndicatorRelease(g_h.atr1h);
   HTFZG_ClearAll(g_prefix);
   PrintRejectTally();
  }

//+------------------------------------------------------------------+
//| Realised PnL of OUR deals since `from`, read from history.       |
//|                                                                  |
//| NOT accumulated in OnTradeTransaction. That handler is not        |
//| guaranteed to have delivered the closing deal by the time the    |
//| management tick notices the grid is gone, so an accumulator      |
//| silently reports 0.00 for exactly the trades that closed fastest |
//| - which are the stop-outs. Observed on XRPUSD: nine of 21 grids  |
//| logged 0.00R, the logged results summed to +159 while the        |
//| account had actually lost 664. A log that hides losses is worse  |
//| than no log.                                                     |
//+------------------------------------------------------------------+
double RealisedSince(const datetime from)
  {
   if(!HistorySelect(from, TimeCurrent() + 1))
      return 0.0;
   double sum = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0)                                                continue;
      if(HistoryDealGetString (d, DEAL_SYMBOL) != _Symbol)      continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC)  != InpMagic)     continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY)  == DEAL_ENTRY_IN) continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT)
           + HistoryDealGetDouble(d, DEAL_COMMISSION)
           + HistoryDealGetDouble(d, DEAL_SWAP);
     }
   return sum;
  }

//+------------------------------------------------------------------+
//| The finished grid's result expressed in R.                       |
//|                                                                  |
//| Currency PnL is not comparable across symbols or account sizes;  |
//| R is. The denominator is what Level 1 actually risked - lots x   |
//| the Level1 -> sharedSL distance - so "-1.00R" means the trade    |
//| lost exactly the planned per-level risk.                         |
//+------------------------------------------------------------------+
double RiskedR()
  {
   if(g_grid.oneR <= 0.0 || g_grid.lv[0].lots <= 0.0)
      return 0.0;
   const double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSz <= 0.0 || tickVal <= 0.0)
      return 0.0;
   const double riskMoney = (g_grid.oneR / tickSz) * tickVal * g_grid.lv[0].lots;
   return (riskMoney > 0.0 ? g_grid.realised / riskMoney : 0.0);
  }

//+------------------------------------------------------------------+
//| Close out a finished grid: log the result, clear the drawing,    |
//| start the cooldown.                                              |
//+------------------------------------------------------------------+
void FinishGrid(const string why)
  {
   g_grid.realised    = RealisedSince(g_grid.opened);
   g_book.realisedPnL = RealisedSince(g_book.day);

   PrintFormat("HTFZG GRID CLOSED [%s] | %s dir=%s score=%d zone=%.5f-%.5f sweep=%.5f "
               "levels=%d/%d avgEntry=%.5f sharedSL=%.5f tp1=%.5f tp2=%.5f "
               "tp1Taken=%s RESULT=%.2f (%.2fR) dayPnL=%.2f",
               why, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
               (g_grid.dir == HTFZG_DIR_BUY ? "BUY" : "SELL"), g_grid.score,
               g_grid.zLow, g_grid.zHigh, g_grid.sweepExtreme,
               g_grid.FilledCount(), g_grid.count, g_grid.avgEntry, g_grid.sharedSL,
               g_grid.tp1, g_grid.tp2, (g_grid.tp1Done ? "yes" : "no"),
               g_grid.realised, RiskedR(), g_book.realisedPnL);

   HTFZG_ClearGrid(g_prefix);
   g_grid.Reset();
   g_book.cooldownUntil = (datetime)(TimeCurrent() + (long)InpCooldownMin * 60);
   g_state = HTFZG_COOLDOWN;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   RollDayBook();

   //--- 1. manage anything live, every tick
   if(g_state == HTFZG_ACTIVE || g_state == HTFZG_PARTIAL)
     {
      if(!HTFZG_Manage(_Symbol, g_gcfg, g_grid, g_state))
        {
         FinishGrid("stop/target/closed");
        }
      else if(InpShowVisuals)
         HTFZG_DrawGrid(g_prefix, g_grid, InpLevelColor, InpSLColor);
     }

   //--- 2. the daily loss cap outranks everything, including a live grid
   if(!g_book.lockedOut && DailyLossPct() >= InpMaxDailyLossPct)
     {
      g_book.lockedOut = true;
      PrintFormat("HTFZG: DAILY LOSS CAP HIT (%.2f%% >= %.2f%%) - closing everything, "
                  "no more grids today.", DailyLossPct(), InpMaxDailyLossPct);
      if(HTFZG_GridExists(_Symbol, InpMagic))
        {
         HTFZG_CloseAll(_Symbol, g_gcfg, g_grid, false);
         FinishGrid("daily loss cap");
        }
      g_book.cooldownUntil = (datetime)(TimeCurrent() + (long)InpCooldownMin * 60);
     }

   //--- 3. everything below is closed-bar work (INVARIANT 1)
   if(!NewBar(PERIOD_M5))
      return;

   //--- cooldown expiry is only a state label; SafetyGate owns the decision
   if(g_state == HTFZG_COOLDOWN && TimeCurrent() >= g_book.cooldownUntil)
      g_state = HTFZG_IDLE;

   //--- 4. a live grid re-checks the HTF bias and nothing else
   if(g_state == HTFZG_ACTIVE || g_state == HTFZG_PARTIAL)
     {
      const ENUM_HTFZG_DIR now = HTFZG_Direction(_Symbol, g_h, g_cfg);
      if(now != g_grid.dir)
         HTFZG_CloseAll(_Symbol, g_gcfg, g_grid, true);   // pendings only
      if(InpShowPanel)
         HTFZG_PanelDraw(g_prefix, g_sig, g_grid, g_book, g_state, InpMinScore,
                         InpMaxTradesPerDay, CORNER_LEFT_UPPER, InpPanelX, InpPanelY,
                         InpFontSize, InpPanelText, InpPanelBg);
      return;
     }

   g_book.realisedPnL = RealisedSince(g_book.day);

   //--- 5. hunt
   g_sig.Reset();
   const bool gated = SafetyGate();

   if(gated)
     {
      HTFZG_Scan(_Symbol, g_h, g_cfg, g_sig);

      if(g_sig.reject == "" && g_sig.total < InpMinScore)
         g_sig.reject = StringFormat("score %d < %d", g_sig.total, InpMinScore);

      if(g_sig.reject == "")
        {
         string why = "";
         if(!HTFZG_BuildGrid(_Symbol, g_sig, g_gcfg, g_grid, why))
            g_sig.reject = why;
         else if(!HTFZG_PlaceGrid(_Symbol, g_gcfg, g_grid))
            g_sig.reject = "placement failed";
         else
           {
            g_state = HTFZG_ACTIVE;
            g_book.gridsToday++;
            PrintFormat("HTFZG GRID OPEN | %s dir=%s score=%d zone=%.5f-%.5f sweep=%.5f "
                        "levels=%d L1=%.5f L2=%.5f L3=%.5f lots=%.2f sharedSL=%.5f "
                        "R=%.5f tp1=%.5f tp2=%.5f",
                        TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
                        (g_grid.dir == HTFZG_DIR_BUY ? "BUY" : "SELL"), g_grid.score,
                        g_grid.zLow, g_grid.zHigh, g_grid.sweepExtreme, g_grid.count,
                        g_grid.lv[0].price,
                        (g_grid.count > 1 ? g_grid.lv[1].price : 0.0),
                        (g_grid.count > 2 ? g_grid.lv[2].price : 0.0),
                        g_grid.lv[0].lots, g_grid.sharedSL, g_grid.oneR,
                        g_grid.tp1, g_grid.tp2);

            if(InpShowVisuals)
              {
               HTFZG_DrawZone(g_prefix, g_sig.zone, g_sig.zone.formed, InpZoneColor);
               HTFZG_DrawGrid(g_prefix, g_grid, InpLevelColor, InpSLColor);
              }
           }
        }
     }

   TallyReject(g_sig.reject);

   if(InpShowPanel)
      HTFZG_PanelDraw(g_prefix, g_sig, g_grid, g_book, g_state, InpMinScore,
                      InpMaxTradesPerDay, CORNER_LEFT_UPPER, InpPanelX, InpPanelY,
                      InpFontSize, InpPanelText, InpPanelBg);
  }

//+------------------------------------------------------------------+
//| The authoritative fill/close feed.                               |
//|                                                                  |
//| Polling positions in OnTick misses a level that fills and closes |
//| inside a single tick, and misses the realised PnL of anything    |
//| the broker closed for us. This does not.                         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.symbol != _Symbol)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;

   //--- PnL is NOT accumulated here - see RealisedSince(). This handler
   //--- exists only to attribute fills to levels.

   //--- A level filling: match it by the ORDER that produced the deal.
   //--- Never by price proximity - the levels are one grid step apart
   //--- (0.4 ATR) while any sane tolerance is a fraction of R, so a
   //--- proximity match attributes Level 1's own entry deal to Level 2
   //--- and reports a ladder that never traded. Observed in the first
   //--- backtest: 2/3 filled on a grid whose L2 and L3 were cancelled.
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
     {
      const ulong ord = (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER);
      for(int i = 0; i < g_grid.count; i++)
         if(g_grid.lv[i].placed && !g_grid.lv[i].filled && g_grid.lv[i].ticket == ord)
           { g_grid.lv[i].filled = true; break; }

      double vol = 0.0, avg = 0.0;
      HTFZG_LiveBook(_Symbol, InpMagic, vol, avg);
      if(vol > 0.0)
         g_grid.avgEntry = avg;
     }
  }
//+------------------------------------------------------------------+
