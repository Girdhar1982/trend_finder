//+------------------------------------------------------------------+
//|                                              HullTrendLG_MT5.mq5 |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Recent liquidity grabs: prints them to the Experts log and marks |
//| them on the chart.                                               |
//|                                                                  |
//| It shares the detection engine (HullTrendLG.mqh) rather than     |
//| reimplementing it, the same way the S/R viewer shares            |
//| HullTrendSR.mqh. A bullish grab (sell-side liquidity swept) and  |
//| a bearish grab (buy-side liquidity swept) are both detected and  |
//| both printed, newest first.                                      |
//|                                                                  |
//| Nothing here repaints: a grab needs a CLOSED bar, so a point can |
//| appear one bar late but never moves or vanishes once drawn.      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.00"
#property description "Recent liquidity grabs: prints them to the Experts log and marks them on the chart."
#property description "Bullish (sell-side swept) and bearish (buy-side swept) grabs are both detected."

#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <HullTrendLG.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group                  "Detection"
input int             InpLookback    = 200;   // Bars scanned for grabs
input int             InpRefBars     = 20;    // Lookback for the reference swing high/low
input double          InpMinSweepATR = 0.25;  // Minimum sweep beyond the level (x ATR)
input int             InpMaxAgeBars  = 0;     // Drop grabs older than N bars (0 = lookback)
input int             InpATRPeriod   = 14;    // ATR period for the sweep scale

input group                  "Experts log"
input bool            InpPrint        = true; // Print grabs to the Experts tab
input int             InpPrintPerSide = 3;    // Recent grabs printed per direction (0 = all)

input group                  "Appearance"
input color           InpColorBull   = clrMediumSeaGreen; // Bull grab (swept a low)
input color           InpColorBear   = clrTomato;         // Bear grab (swept a high)
input bool            InpLabels      = true;  // Text label beside each marker
input int             InpFontSize    = 8;     // Label font size
input int             InpMaxPoints   = 8;     // Markers drawn on the chart (0 = all)
input bool            InpShowLevel   = true;  // Dashed line at the swept reference level

//--- state
LGPoint  g_lg[];
int      g_hATR      = INVALID_HANDLE;
datetime g_lastBar   = 0;
datetime g_lastPrinted = 0;   // newest grab time already reported to the log
string   g_prefix    = "HullLGv_";   // "v" for viewer - must NOT collide with
                                     // anything else on the same chart

//+------------------------------------------------------------------+
//| The inputs as ONE config. Built here rather than inline in        |
//| OnCalculate so that the line OnInit logs and the scan that runs   |
//| can never drift apart.                                            |
//+------------------------------------------------------------------+
LGConfig LGViewerConfig()
  {
   LGConfig cfg;
   cfg.lookback    = InpLookback;
   cfg.refBars     = InpRefBars;
   cfg.minSweepATR = InpMinSweepATR;
   cfg.maxAgeBars  = (InpMaxAgeBars > 0 ? InpMaxAgeBars : InpLookback);
   return(cfg);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   const int atrP = (InpATRPeriod < 1 ? 1 : InpATRPeriod);
   g_hATR = iATR(_Symbol, _Period, atrP);
   if(g_hATR == INVALID_HANDLE)
     {
      Print("Hull Liquidity Grab: cannot create the ATR handle - the sweep scale has no ruler.");
      return INIT_FAILED;
     }

   LGConfig cfg = LGViewerConfig();

   //--- the short name carries the effective refBars for the same reason the
   //--- config line below does: the header on the chart has to describe the
   //--- scan that actually ran
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("Hull LG (ref %d, min %.2f ATR)",
                                   LGRefBars(cfg.refBars), cfg.minSweepATR));

   //--- the resolved configuration, printed for the same reason the S/R viewer
   //--- prints its own: the numbers that produced these points must be on
   //--- record. EFFECTIVE values, with the engine's own clamps already applied
   //--- - a refBars of 1 is logged as the 2 the scan will really use, so the
   //--- line is a record of the run rather than of the dialog.
   PrintFormat("Hull Liquidity Grab config: lookback=%d refBars=%d minSweep=%.2fxATR "
               "maxAge=%d atrPeriod=%d",
               LGScanBars(cfg.lookback), LGRefBars(cfg.refBars), cfg.minSweepATR,
               LGScanDepth(cfg), atrP);

   g_lastBar   = 0;
   g_lastPrinted = 0;
   ArrayResize(g_lg, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   LGClear(0, g_prefix);
   if(g_hATR != INVALID_HANDLE)
     {
      IndicatorRelease(g_hATR);
      g_hATR = INVALID_HANDLE;
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2)
      return(0);

   ArraySetAsSeries(time, false);

   //--- ATR on the last CLOSED bar, like the S/R viewer: a forming bar's ATR
   //--- would make the sweep filter twitch every tick.
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1)
      return(prev_calculated);
   if(atr[0] <= 0.0 || !MathIsValidNumber(atr[0]))
      return(prev_calculated);

   //--- Grab points cannot change intrabar by construction - a grab needs a
   //--- closed bar - so one pass per closed bar is all this needs. The
   //--- markers are anchored to historical bar times and never move.
   const datetime bar    = time[rates_total - 1];
   const bool     newBar = (bar != g_lastBar);
   if(!newBar)
      return(rates_total);

   LGConfig cfg = LGViewerConfig();

   //--- Mark the bar done only once the history was readable. Marking it first
   //--- meant a short CopyRates - routine while the terminal is still syncing
   //--- history after an attach - cleared every marker and then left the chart
   //--- blank until the NEXT bar closed. On D1 that is a full day of nothing.
   if(!LGCollect(g_lg, _Symbol, (ENUM_TIMEFRAMES)_Period, cfg, atr[0]))
      return(prev_calculated);

   g_lastBar = bar;

   //--- Print on attach (g_lastPrinted is 0) and whenever a NEW grab has
   //--- confirmed since the last print - never on every bar, so the Experts
   //--- tab stays readable. The list shows both directions every time.
   if(InpPrint && ArraySize(g_lg) > 0 && g_lg[0].time > g_lastPrinted)
     {
      LGPrintRecent(g_lg, InpPrintPerSide, _Symbol, (ENUM_TIMEFRAMES)_Period, atr[0]);
      g_lastPrinted = g_lg[0].time;
     }

   LGStyle st;
   st.bull      = InpColorBull;
   st.bear      = InpColorBear;
   st.labels    = InpLabels;
   st.fontSize  = (InpFontSize < 6 ? 6 : InpFontSize);
   st.maxPoints = InpMaxPoints;
   st.showLevel = InpShowLevel;

   LGDraw(g_lg, 0, g_prefix, _Symbol, (ENUM_TIMEFRAMES)_Period, st, atr[0]);
   ChartRedraw();

   return(rates_total);
  }
//+------------------------------------------------------------------+
