//+------------------------------------------------------------------+
//|                                               HullTrendSR_MT5.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Draws the support / resistance levels the Hull Trend EA trades    |
//| against. It shares the EA's engine (HullTrendSR.mqh) rather than  |
//| reimplementing it, so what you see is what the EA sees - provided |
//| the inputs below match the EA's group F. Any mismatch and you are |
//| tuning against levels the EA never had.                           |
//|                                                                   |
//| This is a SEPARATE indicator on purpose. Folding it into          |
//| HullTrend_MT5 would extend that indicator's positional iCustom    |
//| argument list, which the EA has to mirror exactly - the single    |
//| most fragile contract in this system - to publish data the EA     |
//| does not want, because the EA computes its own levels in-process. |
//|                                                                   |
//| Nothing here repaints: a pivot is only examined once the bars to  |
//| its right have closed. A level can therefore appear late, but it  |
//| never moves or vanishes once drawn.                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.10"
#property description "Support / resistance levels from clustered pivot fractals."
#property description "Labels rank them R1/S1 outwards and give the distance in ATR and pips."
#property description "Shares the Hull Trend EA's engine - match the EA's group F inputs"
#property description "and this draws exactly the levels it trades against."

#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <HullTrendSR.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//|                                                                  |
//| The first group MUST mirror the EA's group F to be meaningful.   |
//| The defaults here are the EA's defaults.                         |
//+------------------------------------------------------------------+
input group                  "Levels (mirror the EA's group F)"
input int             InpFractal      = 3;              // Bars each side of a pivot
input int             InpLookback     = 400;            // Bars scanned on this timeframe
input double          InpClusterATR   = 0.50;           // Merge pivots closer than this x ATR
input int             InpMinTouches   = 2;              // Hide levels with fewer touches
input int             InpMaxAgeBars   = 0;              // Drop levels older than N bars (0 = 20 x Hull period)
input int             InpHMAPeriod    = 20;             // Hull period (only sets the default age above)
input int             InpATRPeriod    = 14;             // ATR period for the clustering scale

input group                  "Higher timeframe (mirror the EA's group B)"
input bool            InpUseHTF       = true;           // Also scan the higher timeframe
input bool            InpHTFAuto      = true;           // Auto-derive it from the chart TF
input ENUM_TIMEFRAMES InpHTF          = PERIOD_H1;      // Higher TF (when Auto = false)
input double          InpHTFMult      = 12.0;           // Auto: target HTF as a multiple of the chart TF

input group                  "Appearance"
input color           InpColorRes     = clrTomato;      // Levels above price (resistance)
input color           InpColorSup     = clrMediumSeaGreen; // Levels below price (support)
input int             InpMaxEachSide  = 4;              // Draw only the nearest N each side (0 = all)
input bool            InpLabels       = true;           // Per-level text beside each line
input ENUM_SR_LABEL   InpLabelDetail  = SR_LABEL_NORMAL;// How much that text says
input int             InpFontSize     = 8;              // Font size for labels and panel
input bool            InpRays         = true;           // Extend lines to the right edge
input int             InpLabelShift   = 3;              // Label offset to the right (bars)
input int             InpRedrawSecs   = 5;              // Intrabar refresh of colours/labels (secs, 0 = new bar only)

input group                  "Summary panel"
input bool             InpPanel       = true;           // Show the R1 / S1 summary panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER; // Which corner it hangs from
input int              InpPanelX      = 12;             // Inset from that corner, X (pixels)
input int              InpPanelY      = 22;             // Inset from that corner, Y (pixels)
input color            InpPanelText   = clrSilver;      // Panel text colour
input color            InpPanelBg     = C'22,26,34';    // Panel backing plate (clrNONE = none)

//--- state
SRLevel  g_sr[];
int      g_hATR    = INVALID_HANDLE;
datetime g_lastBar  = 0;
datetime g_lastDraw = 0;
ENUM_TIMEFRAMES g_htf = PERIOD_CURRENT;   // resolved once in OnInit, reported by the panel
string   g_prefix  = "HullSRv_";     // "v" for viewer - must NOT collide with the
                                     // EA's own "HullSR_" objects on the same chart

//+------------------------------------------------------------------+
int OnInit()
  {
   const int atrP = (InpATRPeriod < 1 ? 1 : InpATRPeriod);
   g_hATR = iATR(_Symbol, _Period, atrP);
   if(g_hATR == INVALID_HANDLE)
     {
      Print("Hull Trend S/R: cannot create the ATR handle - clustering has no scale.");
      return INIT_FAILED;
     }

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("Hull S/R (%d, %d touches)", InpFractal, InpMinTouches));

   //--- The resolved configuration, for the same reason the trend indicator
   //--- prints its own: these values have to match the EA's group F, and the
   //--- only way to check that is to read both log lines side by side.
   g_htf = SRPickHTF((ENUM_TIMEFRAMES)_Period, InpHTFAuto, InpHTF, InpHTFMult);
   const ENUM_TIMEFRAMES htf = g_htf;
   PrintFormat("Hull Trend S/R config: fractal=%d lookback=%d cluster=%.2fxATR minTouches=%d "
               "maxAge=%d atrPeriod=%d htf=%s",
               InpFractal, InpLookback, InpClusterATR, InpMinTouches,
               (InpMaxAgeBars > 0 ? InpMaxAgeBars : 20 * InpHMAPeriod),
               atrP, (InpUseHTF ? EnumToString(htf) : "off"));

   g_lastBar  = 0;
   g_lastDraw = 0;
   ArrayResize(g_sr, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SRClear(0, g_prefix);
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
   if(rates_total < 2 * InpFractal + 4)
      return(0);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(close, false);

   //--- ATR on the last CLOSED bar. Using the forming bar's ATR would make the
   //--- clustering tolerance twitch every tick, and levels would merge and
   //--- split under the cursor for no reason anyone could act on.
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1)
      return(prev_calculated);
   if(atr[0] <= 0.0 || !MathIsValidNumber(atr[0]))
      return(prev_calculated);

   //--- Rebuild once per closed bar. The pivot set cannot change intrabar by
   //--- construction, so doing this per tick would burn CPU to redraw the same
   //--- picture. The labels do move with price, so redraw when it is worth it.
   const bool newBar = (time[rates_total - 1] != g_lastBar);
   if(newBar)
     {
      g_lastBar = time[rates_total - 1];

      SRConfig cfg;
      cfg.fractal    = InpFractal;
      cfg.lookback   = InpLookback;
      cfg.useHTF     = InpUseHTF;
      cfg.htf        = g_htf;
      cfg.clusterATR = InpClusterATR;
      cfg.maxAgeBars = (InpMaxAgeBars > 0 ? InpMaxAgeBars
                        : 20 * (InpHMAPeriod > 0 ? InpHMAPeriod : 20));

      SRBuild(g_sr, _Symbol, (ENUM_TIMEFRAMES)_Period, cfg, atr[0]);
     }

   //--- Which levels count as "nearest", which side of price they sit on, and
   //--- what the ATR distance to them is ALL depend on where price is NOW - not
   //--- on the level set, which cannot change intrabar. Redrawing only on a new
   //--- bar therefore froze the colours and the distance label for a whole bar,
   //--- which on H4 is four hours of a chart quietly lying to you. Refresh on a
   //--- throttle instead; the objects are few and the redraw is cheap.
   const bool refresh = (InpRedrawSecs > 0 &&
                         TimeCurrent() - g_lastDraw >= InpRedrawSecs);
   if(newBar || refresh)
     {
      SRStyle st;
      st.resistance  = InpColorRes;
      st.support     = InpColorSup;
      st.maxEachSide = InpMaxEachSide;
      st.labels      = InpLabels;
      st.rays        = InpRays;
      st.labelShift  = InpLabelShift;
      st.detail      = InpLabelDetail;
      st.fontSize    = (InpFontSize < 6 ? 6 : InpFontSize);
      st.panel       = InpPanel;
      st.panelCorner = InpPanelCorner;
      st.panelX      = InpPanelX;
      st.panelY      = InpPanelY;
      st.panelText   = InpPanelText;
      st.panelBg     = InpPanelBg;

      const double last = close[rates_total - 1];
      SRDraw(g_sr, 0, g_prefix, InpMinTouches, last, atr[0],
             (ENUM_TIMEFRAMES)_Period, st);

      //--- After SRDraw, never before: that call clears every object under the
      //--- prefix, panel included.
      SRDrawPanel(g_sr, 0, g_prefix, InpMinTouches, last, atr[0], _Symbol,
                  (ENUM_TIMEFRAMES)_Period,
                  (InpUseHTF ? SRTFName(g_htf) : "off"), st);
      g_lastDraw = TimeCurrent();
      ChartRedraw();
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
