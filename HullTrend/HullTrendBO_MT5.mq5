//+------------------------------------------------------------------+
//|                                               HullTrendBO_MT5.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| The most recent range breakouts on a timeframe you choose,       |
//| marked on the chart and printed to the Experts log.              |
//|                                                                  |
//| Default: the three most recent breakouts of a 20-bar range, on   |
//| whatever timeframe the chart is showing. Set InpTF to scan a     |
//| DIFFERENT timeframe and the markers still land on this chart -   |
//| M15 chart, H4 breakouts, one picture.                            |
//|                                                                  |
//| WHAT LANDS ON THE CHART                                          |
//|   - the range each breakout broke out of, as a dotted outline    |
//|   - the level that gave way, carried right (price tests it       |
//|     again on the way back more often than not)                   |
//|   - an arrow on the bar that closed through it                   |
//|   - a SCORE out of 100 and a grade, from four things visible on  |
//|     the breakout bar itself                                      |
//|   - PENDING / held / FAILED - what happened after                |
//|   - a panel: the three side by side, the newest one's score      |
//|     broken into its parts, and how the set went                  |
//|                                                                  |
//| IS IT A VALID BREAKOUT?                                          |
//|   Two questions, kept apart because they are answerable at       |
//|   different times.                                               |
//|                                                                  |
//|   THE SCORE answers "does this look real", now, from the bar     |
//|   itself: how far past the level it closed, where that close sat |
//|   in its own bar, how tight the range it left was, and whether   |
//|   the effort expanded. Weighted 30/30/20/20 into 0-100. The      |
//|   panel and the tooltip show all four parts, so it is an         |
//|   argument you can disagree with rather than a verdict.          |
//|                                                                  |
//|   THE STATUS answers "did it work", later. A breakout inside its |
//|   confirmation window is PENDING - not "held". Claiming a        |
//|   one-bar-old breakout held is claiming knowledge of bars that   |
//|   have not happened yet.                                         |
//|                                                                  |
//|   Set InpMinScore to hide the weak ones, and InpAlertMinScore to |
//|   be woken only for the good ones.                               |
//|                                                                  |
//| COLOURS                                                          |
//|   Cyan and yellow, not green and red, and chunky block arrows    |
//|   rather than the thin glyphs the other studies use. Every other |
//|   study in this suite ships green/red, and on a chart carrying   |
//|   two of them the colour has to say which STUDY drew a marker    |
//|   before it says anything else. All of it is an input.           |
//|                                                                  |
//| It shares the detection engine (HullTrendBO.mqh) the same way    |
//| the S/R, liquidity-grab and FVG viewers share theirs.            |
//|                                                                  |
//| This is a SEPARATE indicator on purpose. Folding it into         |
//| HullTrend_MT5 would extend that indicator's positional iCustom   |
//| argument list, which the EA has to mirror exactly - the single   |
//| most fragile contract in this system - to publish data the EA    |
//| does not ask for.                                                |
//|                                                                  |
//| Nothing here repaints: a breakout needs a closed bar and the     |
//| failure test reads closed bars only, so a marker can appear one  |
//| bar late but never moves or changes verdict once drawn.          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.10"
#property description "The N most recent range breakouts on a timeframe you choose."
#property description "Draws the range that broke, the level that gave way, and scores"
#property description "each break out of 100 from push, close, compression and volume."
#property description "PENDING until the confirmation window elapses, then held or FAILED."
#property description "Scan timeframe is independent of the chart. Nothing repaints."

#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <HullTrendBO.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group                  "Which timeframe to scan"
input ENUM_TIMEFRAMES InpTF          = PERIOD_CURRENT;  // Timeframe (CURRENT = the chart)

input group                  "Detection"
input int             InpCount       = 3;      // How many recent breakouts to show (0 = all)
input int             InpRangeBars   = 20;     // Bars before each bar that define the range
input double          InpMinBreakATR = 0.15;   // The close must clear the level by this x ATR
input int             InpConfirmBars = 3;      // Bars in which a close back inside = FAILED
input int             InpMinScore    = 0;      // Hide breakouts scoring below this (0..100, 0 = show all)
input int             InpLookback    = 300;    // Bars scanned
input int             InpMaxAgeBars  = 0;      // Ignore breakouts older than N bars (0 = lookback)
input int             InpATRPeriod   = 14;     // ATR period for the push / run scale

input group                  "Experts log"
input bool            InpPrint       = true;   // Print the breakouts to the Experts tab

input group                  "Appearance"
//--- The palette is deliberately NOT green/red: every other study in this
//--- suite already ships that pair, and on a chart carrying two of them the
//--- colour stops saying which STUDY drew a marker - which is what you need to
//--- know first. Direction is carried by the arrow, the level and the label.
input color           InpColorUp     = clrAqua;           // Broke the range high
input color           InpColorDown   = clrYellow;         // Broke the range low
input color           InpColorFailed = clrDimGray;        // ...and closed back inside
input color           InpColorRange  = C'26,30,38';       // The range box body (when filled)
input bool            InpFillRange   = false;  // Fill the range box (off = outline only)
input int             InpArrowUp     = 241;    // Up arrow code (Wingdings)
input int             InpArrowDown   = 242;    // Down arrow code (Wingdings)
input bool            InpShowRange   = true;   // Draw the range that was broken
input bool            InpShowLevel   = true;   // Draw the level that gave way
input bool            InpExtendLevel = true;   // Carry that level to the right
input bool            InpLabels      = true;   // Text beside each marker
input int             InpFontSize    = 8;      // Font size for labels and panel
input int             InpRedrawSecs  = 5;      // Intrabar refresh (secs, 0 = new bar only)

input group                  "Summary panel"
input bool             InpPanel       = true;                // Show the summary panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;   // Which corner it hangs from
input int              InpPanelX      = 12;                  // Inset from that corner, X (pixels)
input int              InpPanelY      = 22;                  // Inset from that corner, Y (pixels)
input color            InpPanelText   = clrSilver;           // Panel text colour
input color            InpPanelBg     = C'22,26,34';         // Panel backing plate (clrNONE = none)

input group                  "Alerts"
input bool            InpEnableAlert = true;           // Alert when a NEW breakout confirms
input int             InpAlertMinScore = 0;            // ...only if it scores at least this (0 = any)
input bool            InpEnableSound = false;          // Enable sound alerts
input string          InpSoundFile   = "alert.wav";    // Sound file
input bool            InpEnablePush  = false;          // Enable mobile push notifications
input bool            InpEnableEmail = false;          // Enable email alerts

//--- state
BOPoint  g_bo[];
int      g_hATR     = INVALID_HANDLE;
datetime g_lastBar  = 0;
datetime g_lastDraw = 0;
datetime g_lastSeen = 0;      // newest breakout already alerted and printed

ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;   // resolved once in OnInit
string   g_prefix    = "HullBOv_";       // "v" for viewer - must NOT collide with
                                         // anything else on the same chart

//+------------------------------------------------------------------+
//| The inputs as ONE config. Built here rather than inline in        |
//| OnCalculate so that the line OnInit logs and the scan that runs   |
//| can never drift apart.                                            |
//+------------------------------------------------------------------+
BOConfig ViewerConfig()
  {
   BOConfig cfg;
   cfg.lookback    = InpLookback;
   cfg.rangeBars   = InpRangeBars;
   cfg.minBreakATR = InpMinBreakATR;
   cfg.confirmBars = InpConfirmBars;
   cfg.minScore    = InpMinScore;
   cfg.maxAgeBars  = InpMaxAgeBars;
   cfg.maxShown    = InpCount;
   return(cfg);
  }

//+------------------------------------------------------------------+
//| Same, for the style.                                              |
//+------------------------------------------------------------------+
BOStyle ViewerStyle()
  {
   BOStyle st;
   st.up          = InpColorUp;
   st.down        = InpColorDown;
   st.failed      = InpColorFailed;
   st.range       = InpColorRange;
   st.fillRange   = InpFillRange;
   st.arrowUp     = InpArrowUp;
   st.arrowDown   = InpArrowDown;
   st.showRange   = InpShowRange;
   st.showLevel   = InpShowLevel;
   st.extendLevel = InpExtendLevel;
   st.labels      = InpLabels;
   st.fontSize    = (InpFontSize < 6 ? 6 : InpFontSize);
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
void FireAlert(const BOPoint &p, const double atr)
  {
   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const string msg = StringFormat("%s %s: %s breakout, score %d %s - closed %s "
                                   "through %s (%.2f ATR)%s",
                                   _Symbol, SRTFName(g_tf),
                                   (p.dir > 0 ? "UPSIDE" : "DOWNSIDE"),
                                   p.score, BOGrade(p.score),
                                   DoubleToString(p.close, digits),
                                   DoubleToString(p.level, digits),
                                   (atr > 0.0 ? p.push / atr : 0.0),
                                   (p.failed() ? " - already FAILED back inside" : ""));

   if(InpEnableAlert)
      Alert(msg);
   if(InpEnableSound)
      PlaySound(InpSoundFile);
   if(InpEnablePush)
      SendNotification(msg);
   if(InpEnableEmail)
      SendMail("Hull breakout", msg);

   //--- Always on the record, whatever the channels are set to. An alert that
   //--- fired at 3am and was dismissed leaves no trace anywhere else.
   Print("HullBO | ALERT | " + msg);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   const int atrP = (InpATRPeriod < 1 ? 1 : InpATRPeriod);

   //--- PERIOD_CURRENT resolved ONCE, here. Leaving it unresolved would mean
   //--- every log line, panel header and tooltip had to re-derive it, and the
   //--- first one that forgot would print "CURRENT" at a reader who needs to
   //--- know which timeframe these levels came from.
   g_tf = (InpTF == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpTF);

   g_hATR = iATR(_Symbol, g_tf, atrP);
   if(g_hATR == INVALID_HANDLE)
     {
      Print("Hull Breakout: cannot create the ATR handle - the push filter has no scale.");
      return INIT_FAILED;
     }

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("Hull Breakout (%s, %d-bar range)",
                                   SRTFName(g_tf), BORangeBars(InpRangeBars)));

   //--- The resolved configuration, printed for the same reason the other
   //--- viewers print theirs: the numbers that produced these markers have to
   //--- be on record. EFFECTIVE values, with the engine's own clamps applied -
   //--- a range of 1 is logged as the 2 the scan will really use, so the line
   //--- describes the run and not the dialog.
   BOConfig cfg = ViewerConfig();
   PrintFormat("Hull Breakout config: tf=%s chart=%s show=%s rangeBars=%d "
               "minBreak=%.2fxATR minScore=%d alertMinScore=%d confirm=%d "
               "lookback=%d scanDepth=%d atrPeriod=%d",
               SRTFName(g_tf), SRTFName((ENUM_TIMEFRAMES)_Period),
               (cfg.maxShown > 0 ? StringFormat("%d most recent", cfg.maxShown) : "all"),
               BORangeBars(cfg.rangeBars), cfg.minBreakATR,
               BOMinScore(cfg.minScore), BOMinScore(InpAlertMinScore),
               BOConfirmBars(cfg.confirmBars), BOScanBars(cfg.lookback),
               BOScanDepth(cfg), atrP);

   g_lastBar  = 0;
   g_lastDraw = 0;
   g_lastSeen = 0;
   ArrayResize(g_bo, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   BOClear(0, g_prefix);
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

   //--- ATR on the last CLOSED bar of the SCANNED timeframe. A forming bar's
   //--- ATR would make the minimum-push filter twitch every tick, and markers
   //--- would appear and vanish under the cursor for no reason anyone could
   //--- act on.
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1)
      return(prev_calculated);
   if(atr[0] <= 0.0 || !MathIsValidNumber(atr[0]))
      return(prev_calculated);

   //--- The breakout set cannot change intrabar by construction. Two things it
   //--- carries DO: how far the newest one has run, and - when the scan
   //--- timeframe is above the chart - the fact that a new one confirmed
   //--- partway through a chart bar. So the scan runs on the refresh too; it
   //--- is a couple of linear passes over a few hundred bars.
   const datetime bar     = time[rates_total - 1];
   const bool     newBar  = (bar != g_lastBar);
   const bool     refresh = (InpRedrawSecs > 0 &&
                             TimeCurrent() - g_lastDraw >= InpRedrawSecs);
   if(!newBar && !refresh)
      return(rates_total);

   BOConfig cfg = ViewerConfig();

   //--- Mark the bar done only once the history was readable. Marking it first
   //--- meant a short CopyRates - routine while the terminal is still syncing
   //--- history after an attach - cleared every marker and then left the chart
   //--- bare until the NEXT bar closed. On H4 that is four hours.
   if(!BOCollect(g_bo, _Symbol, g_tf, cfg, atr[0]))
      return(prev_calculated);

   g_lastBar = bar;

   BOStyle st = ViewerStyle();
   BODraw(g_bo, 0, g_prefix, _Symbol, g_tf, atr[0], st);

   //--- After BODraw, never before: that call clears every object under the
   //--- prefix, panel included.
   BODrawPanel(g_bo, 0, g_prefix, _Symbol, g_tf, (ENUM_TIMEFRAMES)_Period,
               atr[0], cfg, st);

   g_lastDraw = TimeCurrent();
   ChartRedraw();

   //--- Print on attach (g_lastSeen is 0) and whenever a NEW breakout has
   //--- confirmed since the last report - never on every refresh, so the
   //--- Experts tab stays readable.
   if(ArraySize(g_bo) > 0 && g_bo[0].time > g_lastSeen)
     {
      const bool first = (g_lastSeen == 0);
      g_lastSeen = g_bo[0].time;

      if(InpPrint)
         BOPrintRecent(g_bo, _Symbol, g_tf, atr[0], cfg);

      //--- No alert on the attach pass. The newest breakout in the lookback
      //--- may be days old, and waking someone up for it would teach them to
      //--- ignore the alert that matters.
      //---
      //--- The score gate is SEPARATE from InpMinScore on purpose: plenty of
      //--- people want every break drawn on the chart for context but only
      //--- want to be woken for the good ones.
      if(!first && g_bo[0].score >= BOMinScore(InpAlertMinScore))
         FireAlert(g_bo[0], atr[0]);
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
