//+------------------------------------------------------------------+
//|                                                 HullTrend_MT5.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "2.20"
#property description "Hull Moving Average trend filter."
#property description "Colour-coded slope, reversal arrows and configurable alerts."
#property description "Whipsaw control: volatility-scaled slope threshold + N-bar confirmation."

//--- show indicator in the main chart window
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   3

//--- plot 1: Hull Trend line
#property indicator_label1  "Hull Trend"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLimeGreen, clrRed
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- plot 2: bullish reversal marker
#property indicator_label2  "HMA Up"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLimeGreen
#property indicator_width2  2

//--- plot 3: bearish reversal marker
#property indicator_label3  "HMA Down"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  2

//--- colour indices used by the DRAW_COLOR_LINE plot
#define COLOR_UP   0
#define COLOR_DOWN 1

//--- which bar a signal is taken from
enum ENUM_SIGNAL_BAR
  {
   SIGNAL_CLOSED_BAR  = 0,  // Closed bar (confirmed, never repaints)
   SIGNAL_CURRENT_BAR = 1   // Current bar (early, can repaint)
  };

//--- how the minimum slope needed to change trend is measured
enum ENUM_SLOPE_FILTER
  {
   SLOPE_FILTER_NONE   = 0, // Off - any slope change flips the trend
   SLOPE_FILTER_POINTS = 1, // Fixed - minimum slope in points
   SLOPE_FILTER_ATR    = 2  // Adaptive - minimum slope as a fraction of ATR
  };

//--- Input Parameters
input group                             "Hull Moving Average"
input int                InpHMAPeriod   = 20;             // Hull period
input ENUM_APPLIED_PRICE InpHMAPrice    = PRICE_CLOSE;    // Applied price
input group                             "Whipsaw filter"
input ENUM_SLOPE_FILTER  InpSlopeFilter = SLOPE_FILTER_ATR; // Slope threshold mode
input double             InpSlopeATRMul = 0.05;           // ATR mode: slope must exceed ATR x this
input int                InpATRPeriod   = 14;             // ATR mode: ATR period
input double             InpSlopePoints = 0.0;            // Points mode: minimum slope (points)
input int                InpConfirmBars = 1;              // Counter-trend bars needed to flip (1 = none)
input group                             "Reversal arrows"
input bool               InpShowArrows  = true;           // Show reversal arrows
input int                InpArrowUp     = 233;            // Up arrow code (Wingdings)
input int                InpArrowDown   = 234;            // Down arrow code (Wingdings)
input int                InpArrowOffset = 10;             // Arrow distance from bar (points)
input group                             "Alerts"
input ENUM_SIGNAL_BAR    InpSignalBar   = SIGNAL_CLOSED_BAR; // Signal bar
input bool               InpEnableAlert = true;           // Enable pop-up alerts
input bool               InpEnableSound = false;          // Enable sound alerts
input string             InpSoundFile   = "alert.wav";    // Sound file
input bool               InpEnablePush  = false;          // Enable mobile push notifications
input bool               InpEnableEmail = false;          // Enable email alerts

//--- Indicator Buffers
double HMABuffer[];        // plot 0 - the Hull line
double ColorBuffer[];      // plot 0 - colour index
double UpArrowBuffer[];    // plot 1
double DownArrowBuffer[];  // plot 2
double PriceBuffer[];      // calculations - selected applied price
double DiffBuffer[];       // calculations - 2*LWMA(half) - LWMA(full)
double StreakBuffer[];     // calculations - consecutive counter-trend bars so far

//--- Derived settings (validated copies of the inputs)
int    g_period    = 20;   // Hull period, clamped to a usable value
int    g_half      = 10;   // period / 2
int    g_sqrt      = 4;    // floor(sqrt(period))
int    g_diffFirst = 19;   // first index with a valid DiffBuffer value
int    g_hmaFirst  = 22;   // first index with a valid HMABuffer value

//--- Pre-computed LWMA weight sums: period*(period+1)/2
double g_wHalf     = 0.0;
double g_wFull     = 0.0;
double g_wSqrt     = 0.0;

//--- Whipsaw filter state
int    g_confirmBars = 1;               // counter-trend bars required, always >= 1
int    g_atrHandle   = INVALID_HANDLE;  // only created for SLOPE_FILTER_ATR
double g_slopePoints = 0.0;             // pre-multiplied fixed threshold, in price units

//--- Alert state
datetime g_lastSignalTime = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- validate inputs: a Hull average needs at least 2 bars to have a slope
   g_period = InpHMAPeriod;
   if(g_period < 2)
     {
      g_period = 2;
      PrintFormat("Hull period %d is too small, using %d instead.", InpHMAPeriod, g_period);
     }

   g_half = g_period / 2;
   if(g_half < 1)
      g_half = 1;

   g_sqrt = (int)MathFloor(MathSqrt((double)g_period));
   if(g_sqrt < 1)
      g_sqrt = 1;

//--- LWMA(full) needs g_period bars, the smoothing LWMA needs g_sqrt more
   g_diffFirst = g_period - 1;
   g_hmaFirst  = g_diffFirst + g_sqrt - 1;

   g_wHalf = 0.5 * g_half   * (g_half   + 1);
   g_wFull = 0.5 * g_period * (g_period + 1);
   g_wSqrt = 0.5 * g_sqrt   * (g_sqrt   + 1);

//--- whipsaw filter setup
   g_confirmBars = InpConfirmBars;
   if(g_confirmBars < 1)
      g_confirmBars = 1;

   g_slopePoints = MathMax(0.0, InpSlopePoints) * _Point;

//--- a zero threshold turns the whipsaw filter off without any visible sign,
//--- which looks identical to "the filter is on but nothing is being filtered"
   if(InpSlopeFilter == SLOPE_FILTER_POINTS && g_slopePoints <= 0.0)
      Print("Hull Trend: Points mode with a zero minimum slope - whipsaw filter is OFF.");
   if(InpSlopeFilter == SLOPE_FILTER_ATR && InpSlopeATRMul <= 0.0)
      Print("Hull Trend: ATR mode with a zero multiplier - whipsaw filter is OFF.");

   g_atrHandle = INVALID_HANDLE;
   if(InpSlopeFilter == SLOPE_FILTER_ATR && InpSlopeATRMul > 0.0)
     {
      int atrPeriod = (InpATRPeriod < 1) ? 1 : InpATRPeriod;
      g_atrHandle = iATR(_Symbol, _Period, atrPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         //--- degrade to an unfiltered line rather than showing nothing at all
         Print("Hull Trend: could not create the ATR handle, slope filter disabled.");
        }
     }

//--- One line of resolved configuration. Nearly free on a chart, and the only
//--- way to catch an iCustom caller whose arguments have shifted: `input group`
//--- occupies a positional slot, so a caller that does not pass a placeholder
//--- for each group mis-assigns every parameter after the first one - silently.
   PrintFormat("Hull Trend config: period=%d price=%s filter=%s atrMul=%.3f "
               "atrPeriod=%d slopePts=%.1f confirm=%d",
               g_period, EnumToString(InpHMAPrice), EnumToString(InpSlopeFilter),
               InpSlopeATRMul, InpATRPeriod, InpSlopePoints, g_confirmBars);

//--- indicator buffers mapping
   SetIndexBuffer(0, HMABuffer,       INDICATOR_DATA);
   SetIndexBuffer(1, ColorBuffer,     INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, UpArrowBuffer,   INDICATOR_DATA);
   SetIndexBuffer(3, DownArrowBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, PriceBuffer,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, DiffBuffer,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, StreakBuffer,    INDICATOR_CALCULATIONS);

//--- all buffers stay in natural order (index 0 = oldest bar)
   ArraySetAsSeries(HMABuffer,       false);
   ArraySetAsSeries(ColorBuffer,     false);
   ArraySetAsSeries(UpArrowBuffer,   false);
   ArraySetAsSeries(DownArrowBuffer, false);
   ArraySetAsSeries(PriceBuffer,     false);
   ArraySetAsSeries(DiffBuffer,      false);
   ArraySetAsSeries(StreakBuffer,    false);

//--- nothing is drawn before enough history exists
   for(int plot = 0; plot < 3; plot++)
      PlotIndexSetDouble(plot, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, g_hmaFirst);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, g_hmaFirst + 1);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, g_hmaFirst + 1);

//--- arrow appearance
   PlotIndexSetInteger(1, PLOT_ARROW, InpArrowUp);
   PlotIndexSetInteger(2, PLOT_ARROW, InpArrowDown);
   if(!InpShowArrows)
     {
      PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
     }

//--- name for DataWindow and indicator label
   IndicatorSetString(INDICATOR_SHORTNAME, "Hull Trend (" + IntegerToString(g_period) + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_lastSignalTime = 0;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
//--- not enough history to produce a slope yet
   if(rates_total <= g_hmaFirst + 1)
      return(0);

//--- the direction of the supplied arrays is not guaranteed, so pin it down
   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   bool firstPass = (prev_calculated <= 0);

//--- recalculate the last known bar as well: it was still forming last time
   int start = firstPass ? 0 : prev_calculated - 1;
   if(start >= rates_total)
      start = rates_total - 1;

//--- first bar whose colour is decided by comparing against an earlier bar
   int colorFrom = (start > g_hmaFirst + 1) ? start : g_hmaFirst + 1;

//--- ATR values backing the adaptive slope threshold, fetched BEFORE the Hull
//--- line is rolled forward: if ATR is not ready the pass has to be repeated,
//--- and building the averages over the whole history first is wasted work.
   double atrVals[];
   int    atrFirst = rates_total;   // first bar index covered by atrVals
   if(g_atrHandle != INVALID_HANDLE)
     {
      ArraySetAsSeries(atrVals, false);
      int copied = CopyBuffer(g_atrHandle, 0, 0, rates_total - colorFrom, atrVals);
      if(copied <= 0)
         return(prev_calculated);   // not ready: retry next tick, keep what we have
      //--- a short copy is survivable: those early bars simply run unfiltered
      atrFirst = rates_total - copied;
     }

//--- clear the warm-up region once. The bound is INCLUSIVE: bar g_hmaFirst is
//--- only the state-machine seed, so the colour loop starts one bar later and
//--- used to leave that bar's arrow buffers holding 0.0 - invisible on the
//--- chart thanks to PLOT_DRAW_BEGIN, but CopyBuffer hands it to an EA as a
//--- signal at price zero.
   if(firstPass)
      for(int i = 0; i <= g_hmaFirst && i < rates_total; i++)
        {
         DiffBuffer[i]      = 0.0;
         HMABuffer[i]       = EMPTY_VALUE;
         ColorBuffer[i]     = COLOR_UP;
         StreakBuffer[i]    = 0.0;
         UpArrowBuffer[i]   = EMPTY_VALUE;
         DownArrowBuffer[i] = EMPTY_VALUE;
        }

//--- 1. selected applied price
   for(int i = start; i < rates_total; i++)
      PriceBuffer[i] = AppliedPrice(open, high, low, close, i, InpHMAPrice);

//--- 2. raw Hull series: 2*LWMA(price, period/2) - LWMA(price, period).
//---    Both LWMAs are rolled forward incrementally, so this costs O(1) per bar
//---    instead of O(period) - the original recomputed every window from scratch.
   int diffFrom = (start > g_diffFirst) ? start : g_diffFirst;
     {
      double numHalf = 0.0, sumHalf = 0.0, numFull = 0.0, sumFull = 0.0;

      for(int k = 0; k < g_half; k++)
        {
         double v = PriceBuffer[diffFrom - k];
         numHalf += v * (g_half - k);
         sumHalf += v;
        }
      for(int k = 0; k < g_period; k++)
        {
         double v = PriceBuffer[diffFrom - k];
         numFull += v * (g_period - k);
         sumFull += v;
        }
      DiffBuffer[diffFrom] = 2.0 * (numHalf / g_wHalf) - (numFull / g_wFull);

      for(int i = diffFrom + 1; i < rates_total; i++)
        {
         double vin = PriceBuffer[i];
         //--- numerator(t+1) = numerator(t) + period*newest - window sum(t)
         numHalf += g_half * vin - sumHalf;
         sumHalf += vin - PriceBuffer[i - g_half];
         numFull += g_period * vin - sumFull;
         sumFull += vin - PriceBuffer[i - g_period];
         DiffBuffer[i] = 2.0 * (numHalf / g_wHalf) - (numFull / g_wFull);
        }
     }

//--- 3. Hull line: LWMA(raw series, sqrt(period)), rolled forward the same way
   int hmaFrom = (start > g_hmaFirst) ? start : g_hmaFirst;
     {
      double num = 0.0, sum = 0.0;

      for(int k = 0; k < g_sqrt; k++)
        {
         double v = DiffBuffer[hmaFrom - k];
         num += v * (g_sqrt - k);
         sum += v;
        }
      HMABuffer[hmaFrom] = num / g_wSqrt;

      for(int i = hmaFrom + 1; i < rates_total; i++)
        {
         double vin = DiffBuffer[i];
         num += g_sqrt * vin - sum;
         sum += vin - DiffBuffer[i - g_sqrt];
         HMABuffer[i] = num / g_wSqrt;
        }
     }

//--- 4. slope colour and reversal arrows
   double offset = InpArrowOffset * _Point;

   if(colorFrom == g_hmaFirst + 1)
     {
      //--- no earlier bar to compare against, so seed the state machine
      ColorBuffer[g_hmaFirst]  = COLOR_UP;
      StreakBuffer[g_hmaFirst] = 0.0;
     }

   for(int i = colorFrom; i < rates_total; i++)
     {
      int    prevTrend  = (int)ColorBuffer[i - 1];
      int    prevStreak = (int)StreakBuffer[i - 1];
      double slope      = HMABuffer[i] - HMABuffer[i - 1];

      //--- minimum slope this bar must clear to count as directional
      double threshold = 0.0;
      if(InpSlopeFilter == SLOPE_FILTER_POINTS)
         threshold = g_slopePoints;
      else
         if(g_atrHandle != INVALID_HANDLE && i >= atrFirst)
            threshold = atrVals[i - atrFirst] * InpSlopeATRMul;

      //--- direction this bar argues for: up, down, or -1 for too flat to say
      int candidate = -1;
      if(slope > threshold)
         candidate = COLOR_UP;
      else
         if(-slope > threshold)
            candidate = COLOR_DOWN;

      int curTrend  = prevTrend;
      int curStreak = 0;

      if(candidate == -1)
        {
         //--- too flat to argue either way: hold the count instead of clearing
         //--- it. On low timeframes most bars sit inside the threshold band, so
         //--- resetting here made InpConfirmBars > 1 impossible to ever satisfy.
         curStreak = prevStreak;
        }
      else
         if(candidate == prevTrend)
           {
            //--- moving with the trend: any pending reversal is dead
            curStreak = 0;
           }
         else
           {
            //--- counter-trend bar: flip only once enough of them line up
            curStreak = prevStreak + 1;
            if(curStreak >= g_confirmBars)
              {
               curTrend  = candidate;
               curStreak = 0;
              }
           }

      ColorBuffer[i]     = curTrend;
      StreakBuffer[i]    = curStreak;
      UpArrowBuffer[i]   = EMPTY_VALUE;
      DownArrowBuffer[i] = EMPTY_VALUE;

      if(curTrend != prevTrend)
        {
         if(curTrend == COLOR_UP)
            UpArrowBuffer[i] = low[i] - offset;
         else
            DownArrowBuffer[i] = high[i] + offset;
        }
     }

//--- 5. alert on a fresh reversal
   int idx = (InpSignalBar == SIGNAL_CLOSED_BAR) ? rates_total - 2 : rates_total - 1;

   if(g_lastSignalTime == 0)
     {
      //--- first attach only: do not replay historical signals. Keying this on
      //--- firstPass meant every history reload / reconnect pushed the marker
      //--- forward to the current bar and swallowed a reversal landing on it.
      g_lastSignalTime = time[idx];
     }
   else
     {
      //--- strictly newer, so a signal fires once per bar and a history
      //--- reload cannot walk the marker backwards and re-alert
      if(idx > g_hmaFirst && time[idx] > g_lastSignalTime)
        {
         bool up   = (UpArrowBuffer[idx]   != EMPTY_VALUE);
         bool down = (DownArrowBuffer[idx] != EMPTY_VALUE);

         if(up || down)
           {
            g_lastSignalTime = time[idx];
            TriggerAlert(up ? "BULLISH reversal" : "BEARISH reversal", time[idx]);
           }
        }
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Extract the selected applied price for one bar                   |
//+------------------------------------------------------------------+
double AppliedPrice(const double &open[], const double &high[], const double &low[],
                    const double &close[], const int index, const ENUM_APPLIED_PRICE price_type)
  {
   switch(price_type)
     {
      case PRICE_OPEN:
         return(open[index]);
      case PRICE_HIGH:
         return(high[index]);
      case PRICE_LOW:
         return(low[index]);
      case PRICE_MEDIAN:
         return((high[index] + low[index]) / 2.0);
      case PRICE_TYPICAL:
         return((high[index] + low[index] + close[index]) / 3.0);
      case PRICE_WEIGHTED:
         return((high[index] + low[index] + 2.0 * close[index]) / 4.0);
      default:
         return(close[index]);
     }
  }

//+------------------------------------------------------------------+
//| Fire the enabled alert channels                                  |
//+------------------------------------------------------------------+
void TriggerAlert(const string trendMsg, const datetime barTime)
  {
   string tf      = PeriodToString(_Period);
   string subject = "Hull Trend Alert - " + _Symbol + " [" + tf + "]";
   string message = StringFormat("Hull Trend (%d) %s on %s %s at %s",
                                 g_period, trendMsg, _Symbol, tf,
                                 TimeToString(barTime, TIME_DATE | TIME_MINUTES));

   if(InpEnableAlert)
      Alert(message);
   if(InpEnableSound && InpSoundFile != "")
      PlaySound(InpSoundFile);
   if(InpEnablePush)
      SendNotification(message);
   if(InpEnableEmail)
      SendMail(subject, message);
  }

//+------------------------------------------------------------------+
//| Readable timeframe name, e.g. PERIOD_H1 -> H1                    |
//+------------------------------------------------------------------+
string PeriodToString(const ENUM_TIMEFRAMES periodVal)
  {
   string name = EnumToString(periodVal);
   if(StringSubstr(name, 0, 7) == "PERIOD_")
      name = StringSubstr(name, 7);
   return(name);
  }
//+------------------------------------------------------------------+
