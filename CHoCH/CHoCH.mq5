//+------------------------------------------------------------------+
//| CHoCH.mq5                                                        |
//| Highlights Change of Character (CHoCH) only.                     |
//|                                                                  |
//| Trend is read from confirmed swing highs / lows:                 |
//|   uptrend   -> a close below the last swing low = bearish CHoCH  |
//|   downtrend -> a close above the last swing high = bullish CHoCH |
//| Breaks in the direction of the trend (BOS) are not drawn.        |
//| Swings are confirmed InpSwing bars after they form, and breaks   |
//| are taken on candle close, so nothing repaints.                  |
//+------------------------------------------------------------------+
#property copyright "CHoCH"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input int   InpSwing     = 5;             // Swing strength (bars each side of the pivot)
input int   InpHistory   = 1500;          // Bars of history to scan
input color InpBullColor = clrDodgerBlue; // Bullish CHoCH colour
input color InpBearColor = clrOrangeRed;  // Bearish CHoCH colour
input int   InpWidth     = 2;             // Line width
input bool  InpArrows    = true;          // Arrow on the breaking candle
input int   InpFontSize  = 9;             // Label font size
input bool  InpAlerts    = false;         // Alert on a new CHoCH
input bool  InpPush      = false;         // Also send push notification

const string PREFIX = "CHOCH_";
datetime g_lastBar   = 0;
datetime g_alertBar  = 0;
bool     g_primed    = false;

void Mark(const bool bull, datetime t1, datetime t2, double level, double barPrice)
  {
   color  clr = bull ? InpBullColor : InpBearColor;
   string id  = PREFIX + (bull ? "U_" : "D_") + TimeToString(t2, TIME_DATE | TIME_MINUTES);

   ObjectCreate(0, id + "_L", OBJ_TREND, 0, t1, level, t2, level);
   ObjectSetInteger(0, id + "_L", OBJPROP_COLOR, clr);
   ObjectSetInteger(0, id + "_L", OBJPROP_WIDTH, InpWidth);
   ObjectSetInteger(0, id + "_L", OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, id + "_L", OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, id + "_L", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, id + "_L", OBJPROP_HIDDEN, true);

   datetime mid = t1 + (t2 - t1) / 2;
   ObjectCreate(0, id + "_T", OBJ_TEXT, 0, mid, level);
   ObjectSetString(0, id + "_T", OBJPROP_TEXT, "CHoCH");
   ObjectSetInteger(0, id + "_T", OBJPROP_COLOR, clr);
   ObjectSetInteger(0, id + "_T", OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, id + "_T", OBJPROP_ANCHOR, bull ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, id + "_T", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, id + "_T", OBJPROP_HIDDEN, true);

   if(InpArrows)
     {
      ObjectCreate(0, id + "_A", OBJ_ARROW, 0, t2, barPrice);
      ObjectSetInteger(0, id + "_A", OBJPROP_ARROWCODE, bull ? 233 : 234);
      ObjectSetInteger(0, id + "_A", OBJPROP_COLOR, clr);
      ObjectSetInteger(0, id + "_A", OBJPROP_ANCHOR, bull ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(0, id + "_A", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, id + "_A", OBJPROP_HIDDEN, true);
     }
  }

int OnInit()
  {
   IndicatorSetString(INDICATOR_SHORTNAME, "CHoCH");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[],
                const double &close[], const long &tick_volume[], const long &volume[],
                const int &spread[])
  {
   int n = InpSwing;
   if(rates_total < 4 * n + 5)
      return 0;
   if(time[rates_total - 1] == g_lastBar && prev_calculated > 0)
      return rates_total;   // rebuild once per new bar
   g_lastBar = time[rates_total - 1];

   ObjectsDeleteAll(0, PREFIX);

   int last  = rates_total - 2;                       // last closed bar
   int start = MathMax(n, rates_total - InpHistory);

   double shLevel = 0, slLevel = 0;                   // active (unbroken) swing levels
   int    shIdx = -1, slIdx = -1;
   int    trend = 0;                                  // 1 up, -1 down, 0 unknown
   int    lastChochBar = -1;
   bool   lastChochBull = false;

   for(int i = start + n; i <= last; i++)
     {
      // confirm the pivot that formed n bars ago
      int p = i - n;
      bool isH = true, isL = true;
      for(int k = 1; k <= n; k++)
        {
         if(high[p] <= high[p - k] || high[p] < high[p + k]) isH = false;
         if(low[p]  >= low[p - k]  || low[p]  > low[p + k])  isL = false;
        }
      if(isH) { shLevel = high[p]; shIdx = p; }
      if(isL) { slLevel = low[p];  slIdx = p; }

      if(shIdx >= 0 && close[i] > shLevel)
        {
         if(trend == -1)
           {
            Mark(true, time[shIdx], time[i], shLevel, low[i]);
            lastChochBar = i; lastChochBull = true;
           }
         trend = 1;
         shIdx = -1;                                  // level consumed
        }
      else if(slIdx >= 0 && close[i] < slLevel)
        {
         if(trend == 1)
           {
            Mark(false, time[slIdx], time[i], slLevel, high[i]);
            lastChochBar = i; lastChochBull = false;
           }
         trend = -1;
         slIdx = -1;
        }
     }

   if(InpAlerts && lastChochBar == last)
     {
      if(g_primed && g_alertBar != time[last])
        {
         string msg = StringFormat("%s %s: %s CHoCH", _Symbol, EnumToString(_Period),
                                   lastChochBull ? "Bullish" : "Bearish");
         Alert(msg);
         if(InpPush)
            SendNotification(msg);
        }
      g_alertBar = time[last];
     }
   g_primed = true;

   ChartRedraw();
   return rates_total;
  }
