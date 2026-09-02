//+------------------------------------------------------------------+
//|                                              HullTrendFVG_MT5.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Higher-timeframe fair value gaps on a lower-timeframe chart.     |
//|                                                                  |
//| Attach it to M15 and leave the defaults alone: it scans H4 for   |
//| recent unfilled imbalances, marks the order blocks and structure |
//| breaks that give them a direction, and then watches THIS chart   |
//| for the break that says the retracement into one is finished.    |
//|                                                                  |
//| WHAT LANDS ON THE CHART                                          |
//|   - H4 fair value gaps as filled boxes, with the 50% line        |
//|   - H4 order blocks as dotted boxes                              |
//|   - H4 BOS / CHoCH: the level, how long it held, and which       |
//|   - the same breaks on THIS timeframe - the entry trigger        |
//|   - the live setup: arrow, stop, target and the R it pays        |
//|   - a panel that says which way, into which zone, how far        |
//|                                                                  |
//| It shares the detection engine (HullTrendFVG.mqh) the same way   |
//| the S/R and liquidity-grab viewers share theirs, and that engine |
//| shares HullTrendSR.mqh for timeframe resolution - so the HTF     |
//| this indicator picks is the same one the rest of the suite would |
//| pick from the same chart.                                        |
//|                                                                  |
//| This is a SEPARATE indicator on purpose. Folding it into         |
//| HullTrend_MT5 would extend that indicator's positional iCustom   |
//| argument list, which the EA has to mirror exactly - the single   |
//| most fragile contract in this system - to publish data the EA    |
//| does not ask for.                                                |
//|                                                                  |
//| Nothing here repaints. Every pattern needs closed bars, so a     |
//| zone can appear one bar late but never moves once drawn; the     |
//| only value that tracks the live bar is a zone fill percentage,   |
//| and price can trade further into a gap but never back out of it. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.00"
#property description "Higher-timeframe fair value gaps, order blocks and BOS/CHoCH,"
#property description "drawn on the trading chart. Defaults: H4 zones on an M15 chart."
#property description "The entry trigger is a break of structure on THIS timeframe,"
#property description "taken inside the higher-timeframe zone. Nothing repaints."

#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include "HullTrendRelay.mqh"
#include <HullTrendFVG.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group                  "Higher timeframe (where the zones come from)"
input bool            InpHTFAuto      = false;          // Derive the HTF from the chart TF
input ENUM_TIMEFRAMES InpHTF          = PERIOD_H4;      // Higher TF (when Auto = false)
input double          InpHTFMult      = 16.0;           // Auto: HTF as a multiple of the chart TF

input group                  "Zones"
input int             InpLookback     = 180;            // HTF bars scanned
input int             InpMaxAgeBars   = 0;              // Drop zones older than N HTF bars (0 = lookback)
input double          InpMinGapATR    = 0.25;           // A gap must be at least this x HTF ATR
input bool            InpUseGaps      = true;           // Detect fair value gaps
input bool            InpUseOB        = true;           // Detect order blocks
input bool            InpOBBodyOnly   = false;          // Order block box = body only
input double          InpMitigatedPct = 100.0;          // Retire a zone once this % of it is filled
input int             InpMaxPerSide   = 4;              // Keep at most N zones per direction
input int             InpATRPeriod    = 14;             // ATR period (both timeframes)

input group                  "Structure"
input int             InpFractal      = 2;              // Closed bars each side of an HTF swing
input bool            InpShowBreaks   = true;           // Draw BOS / CHoCH markers
input int             InpMaxBreaks    = 4;              // How many, per timeframe (0 = all)

input group                  "Entry on this chart"
input int             InpEntryFractal = 2;              // Closed bars each side of a chart swing
input int             InpArmBars      = 12;             // Chart bars a visit to the zone stays live
input bool            InpShowSetup    = true;           // Draw the arrow, stop and target

input group                  "Experts log"
input bool            InpPrint        = true;           // Print the scan to the Experts tab
input int             InpPrintMax     = 6;              // Lines per section (0 = all)

input group                  "Appearance"
input color           InpColorBull    = clrMediumSeaGreen;  // Demand zone edge
input color           InpColorBear    = clrTomato;          // Supply zone edge
input color           InpFillBull     = C'18,46,34';        // Demand zone body
input color           InpFillBear     = C'62,26,26';        // Supply zone body
input color           InpColorOBBull  = clrSteelBlue;       // Bullish order block edge
input color           InpColorOBBear  = clrOrchid;          // Bearish order block edge
input color           InpColorStruct  = clrGoldenrod;       // BOS / CHoCH markers
input bool            InpShowMid      = true;           // Dotted 50% line inside each gap
input bool            InpLabels       = true;           // Text beside each zone
input int             InpFontSize     = 8;              // Font size for labels and panel
input int             InpRightPad     = 8;              // Zone extension past the last bar (bars)
input int             InpRedrawSecs   = 5;              // Intrabar refresh (secs, 0 = new bar only)

input group                  "Summary panel"
input bool             InpPanel       = true;           // Show the summary panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER; // Which corner it hangs from
input int              InpPanelX      = 12;             // Inset from that corner, X (pixels)
input int              InpPanelY      = 22;             // Inset from that corner, Y (pixels)
input color            InpPanelText   = clrSilver;      // Panel text colour
input color            InpPanelBg     = C'22,26,34';    // Panel backing plate (clrNONE = none)

input group                  "Alerts"
input bool            InpEnableAlert  = true;           // Enable pop-up alerts on a trigger
input bool            InpEnableSound  = false;          // Enable sound alerts
input string          InpSoundFile    = "alert.wav";    // Sound file
input bool            InpEnablePush   = false;          // Enable mobile push notifications
input bool            InpEnableEmail  = false;          // Enable email alerts

//--- state
FVGZone  g_zone[];
FVGBreak g_htfBrk[];
FVGBreak g_chartBrk[];
FVGBias  g_bias;
FVGSetup g_setup;

int      g_hATR_htf   = INVALID_HANDLE;   // zone scale, stop buffer, panel distances
int      g_hATR_chart = INVALID_HANDLE;   // arrow clearance on THIS chart
datetime g_lastBar    = 0;
datetime g_lastDraw   = 0;
datetime g_lastAlert  = 0;                // trigger bar already alerted
datetime g_lastPrint  = 0;                // newest zone already reported to the log

ENUM_TIMEFRAMES g_htf = PERIOD_H4;        // resolved once in OnInit, reported by the panel
string   g_prefix     = "HullFVGv_";      // "v" for viewer - must NOT collide with
                                          // anything else on the same chart

//+------------------------------------------------------------------+
//| The inputs as ONE config. Built here rather than inline in        |
//| OnCalculate so that the line OnInit logs and the scan that runs   |
//| can never drift apart.                                            |
//+------------------------------------------------------------------+
FVGConfig ViewerConfig()
  {
   FVGConfig cfg;
   cfg.lookback     = InpLookback;
   cfg.maxAgeBars   = InpMaxAgeBars;
   cfg.minGapATR    = InpMinGapATR;
   cfg.fractal      = InpFractal;
   cfg.useGaps      = InpUseGaps;
   cfg.useOB        = InpUseOB;
   cfg.obBodyOnly   = InpOBBodyOnly;
   cfg.mitigatedPct = InpMitigatedPct;
   cfg.maxPerSide   = InpMaxPerSide;
   cfg.entryFractal = InpEntryFractal;
   cfg.armBars      = InpArmBars;
   return(cfg);
  }

//+------------------------------------------------------------------+
//| Same, for the style.                                              |
//+------------------------------------------------------------------+
FVGStyle ViewerStyle()
  {
   FVGStyle st;
   st.bull        = InpColorBull;
   st.bear        = InpColorBear;
   st.bullFill    = InpFillBull;
   st.bearFill    = InpFillBear;
   st.obBull      = InpColorOBBull;
   st.obBear      = InpColorOBBear;
   st.structure   = InpColorStruct;
   st.showMid     = InpShowMid;
   st.labels      = InpLabels;
   st.showBreaks  = InpShowBreaks;
   st.maxBreaks   = InpMaxBreaks;
   st.fontSize    = (InpFontSize < 6 ? 6 : InpFontSize);
   st.rightPad    = InpRightPad;
   st.showSetup   = InpShowSetup;
   st.panel       = InpPanel;
   st.panelCorner = InpPanelCorner;
   st.panelX      = InpPanelX;
   st.panelY      = InpPanelY;
   st.panelText   = InpPanelText;
   st.panelBg     = InpPanelBg;
   return(st);
  }

//+------------------------------------------------------------------+
//| One alert, through every channel that is switched on.            |
//+------------------------------------------------------------------+
void FireAlert(const FVGSetup &su)
  {
   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const string msg = StringFormat("%s %s: %s setup from the %s %s zone - "
                                   "entry %s  SL %s  TP %s  %.2fR",
                                   _Symbol, SRTFName((ENUM_TIMEFRAMES)_Period),
                                   (su.dir > 0 ? "LONG" : "SHORT"),
                                   SRTFName(g_htf),
                                   (su.zone >= 0 && su.zone < ArraySize(g_zone)
                                    ? FVGZoneTag(g_zone[su.zone]) : "?"),
                                   DoubleToString(su.entry, digits),
                                   DoubleToString(su.sl, digits),
                                   DoubleToString(su.tp, digits), su.rr);

   if(InpEnableAlert)
      Alert(msg);
   if(InpEnableSound)
      PlaySound(InpSoundFile);
   if(InpEnablePush)
      SendNotification(msg);
   if(InpEnableEmail)
      SendMail("Hull FVG setup", msg);

   //--- Always on the record, whatever the channels are set to. An alert that
   //--- fired at 3am and was dismissed leaves no trace anywhere else.
   Print("HullFVG | ALERT | " + msg);

   //--- Telegram, via the relay EA: WebRequest is illegal here
   HTRelayPublish(HT_KIND_FVG, su.dir > 0, su.time, (ENUM_TIMEFRAMES)_Period);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   const int atrP = (InpATRPeriod < 1 ? 1 : InpATRPeriod);

   //--- The higher timeframe, resolved through the SAME function the rest of
   //--- the suite uses, so an M15 chart lands on the same HTF everywhere.
   g_htf = SRPickHTF((ENUM_TIMEFRAMES)_Period, InpHTFAuto, InpHTF, InpHTFMult);

   //--- A "higher" timeframe at or below the chart is not a filter, it is the
   //--- chart again with extra steps - and silently accepting it would hand
   //--- back a picture that looks right and means nothing. Say so, loudly, and
   //--- carry on single-timeframe rather than refusing to load.
   if(PeriodSeconds(g_htf) <= PeriodSeconds((ENUM_TIMEFRAMES)_Period))
     {
      PrintFormat("Hull FVG: %s is not above the chart timeframe %s - "
                  "falling back to single-timeframe zones on %s.",
                  SRTFName(g_htf), SRTFName((ENUM_TIMEFRAMES)_Period),
                  SRTFName((ENUM_TIMEFRAMES)_Period));
      g_htf = (ENUM_TIMEFRAMES)_Period;
     }

   g_hATR_htf   = iATR(_Symbol, g_htf, atrP);
   g_hATR_chart = iATR(_Symbol, _Period, atrP);
   if(g_hATR_htf == INVALID_HANDLE || g_hATR_chart == INVALID_HANDLE)
     {
      Print("Hull FVG: cannot create the ATR handles - the gap filter has no scale.");
      return INIT_FAILED;
     }

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("Hull FVG (%s zones, min %.2f ATR)",
                                   SRTFName(g_htf), InpMinGapATR));

   //--- The resolved configuration, printed for the same reason the S/R and
   //--- liquidity-grab viewers print theirs: the numbers that produced this
   //--- picture have to be on record. EFFECTIVE values, with the engine's own
   //--- clamps applied - a lookback of 10 is logged as the 40 that will really
   //--- run, so the line describes the scan and not the dialog.
   FVGConfig cfg = ViewerConfig();
   PrintFormat("Hull FVG config: htf=%s chart=%s lookback=%d scanDepth=%d "
               "minGap=%.2fxATR fractal=%d gaps=%s ob=%s mitigated=%.0f%% "
               "maxPerSide=%d entryFractal=%d armBars=%d atrPeriod=%d",
               SRTFName(g_htf), SRTFName((ENUM_TIMEFRAMES)_Period),
               FVGScanBars(cfg.lookback), FVGScanDepth(cfg),
               cfg.minGapATR, FVGFractal(cfg.fractal),
               (cfg.useGaps ? "on" : "off"), (cfg.useOB ? "on" : "off"),
               FVGMitigated(cfg.mitigatedPct) * 100.0, cfg.maxPerSide,
               FVGFractal(cfg.entryFractal), FVGArmBars(cfg.armBars), atrP);

   g_lastBar   = 0;
   g_lastDraw  = 0;
   g_lastAlert = 0;
   g_lastPrint = 0;
   ArrayResize(g_zone,     0);
   ArrayResize(g_htfBrk,   0);
   ArrayResize(g_chartBrk, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   FVGClear(0, g_prefix);
   if(g_hATR_htf != INVALID_HANDLE)
     {
      IndicatorRelease(g_hATR_htf);
      g_hATR_htf = INVALID_HANDLE;
     }
   if(g_hATR_chart != INVALID_HANDLE)
     {
      IndicatorRelease(g_hATR_chart);
      g_hATR_chart = INVALID_HANDLE;
     }
   ChartRedraw();
  }

//--- ATR on the last CLOSED bar of its own timeframe. The forming bar's ATR
//--- would make the minimum-gap filter twitch every tick, and zones would
//--- appear and vanish under the cursor for no reason anyone could act on.
bool ClosedATR(const int handle, double &out)
  {
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(handle, 0, 1, 1, a) < 1)
      return(false);
   if(a[0] <= 0.0 || !MathIsValidNumber(a[0]))
      return(false);
   out = a[0];
   return(true);
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
   if(rates_total < 10)
      return(0);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(close, false);

   double atrHTF = 0.0, atrChart = 0.0;
   if(!ClosedATR(g_hATR_htf, atrHTF) || !ClosedATR(g_hATR_chart, atrChart))
      return(prev_calculated);

   //--- Zones and structure cannot change intrabar by construction. Two things
   //--- they carry DO: how far price has come back into a zone, and whether
   //--- the chart timeframe has just triggered. Refreshing only on a new bar
   //--- froze both for a whole bar - fifteen minutes of a chart quietly
   //--- lying about where price is standing. The scan is a few linear passes
   //--- over a few hundred bars, so it runs on the refresh too.
   const datetime bar     = time[rates_total - 1];
   const bool     newBar  = (bar != g_lastBar);
   const bool     refresh = (InpRedrawSecs > 0 &&
                             TimeCurrent() - g_lastDraw >= InpRedrawSecs);
   if(!newBar && !refresh)
      return(rates_total);

   FVGConfig cfg = ViewerConfig();

   //--- Mark the bar done only once the history was readable. Marking it first
   //--- meant a short CopyRates - routine while the terminal is still syncing
   //--- history after an attach - cleared every zone and then left the chart
   //--- bare until the NEXT bar closed.
   if(!FVGCollect(g_zone, g_htfBrk, g_bias, _Symbol, g_htf, cfg, atrHTF))
      return(prev_calculated);

   const double price = close[rates_total - 1];
   if(!FVGEvaluate(g_setup, g_chartBrk, g_zone, g_bias, _Symbol,
                   (ENUM_TIMEFRAMES)_Period, cfg, price, atrHTF))
      return(prev_calculated);

   g_lastBar = bar;

   FVGStyle st = ViewerStyle();

   //--- The arrow offset is quoted in CHART ATR: the trigger sits on a chart
   //--- bar, and clearing it by a fraction of the H4 range would park the
   //--- glyph somewhere off the reaction entirely.
   FVGDraw(g_zone, g_htfBrk, g_chartBrk, g_setup, 0, g_prefix, _Symbol,
           (ENUM_TIMEFRAMES)_Period, g_htf, atrChart, st);

   //--- After FVGDraw, never before: that call clears every object under the
   //--- prefix, panel included.
   FVGDrawPanel(g_zone, g_bias, g_setup, 0, g_prefix, _Symbol,
                (ENUM_TIMEFRAMES)_Period, g_htf, price, atrHTF, st);

   g_lastDraw = TimeCurrent();
   ChartRedraw();

   //--- Print on attach (g_lastPrint is 0) and whenever a NEW zone has formed
   //--- since the last report - never on every refresh, so the Experts tab
   //--- stays readable.
   if(InpPrint && ArraySize(g_zone) > 0 && g_zone[0].time > g_lastPrint)
     {
      FVGPrintRecent(g_zone, g_htfBrk, g_bias, g_setup, _Symbol,
                     (ENUM_TIMEFRAMES)_Period, g_htf, price, atrHTF, InpPrintMax);
      g_lastPrint = g_zone[0].time;
     }

   //--- One alert per trigger bar. The trigger comes from a CLOSED chart bar,
   //--- so this cannot fire twice for the same break however often the refresh
   //--- re-evaluates it.
   if(g_setup.state == FVG_STATE_TRIGGER && g_setup.time != g_lastAlert)
     {
      g_lastAlert = g_setup.time;
      FireAlert(g_setup);
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
