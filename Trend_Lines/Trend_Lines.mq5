//+------------------------------------------------------------------+
//| Trend_Lines.mq5                                                   |
//| Auto trend lines from confirmed swing pivots, any timeframe.      |
//| Support line  = rising swing lows  (uptrend)                      |
//| Resistance    = falling swing highs (downtrend)                   |
//| InpTF = PERIOD_CURRENT draws on the chart's own timeframe; pick   |
//| any other timeframe to overlay its trend lines on this chart.     |
//| Pivots are confirmed (N bars each side) so lines do not repaint.  |
//+------------------------------------------------------------------+
#property copyright "training_folder"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input ENUM_TIMEFRAMES InpTF        = PERIOD_CURRENT; // Timeframe for trend lines
input int     InpStrength          = 5;      // Pivot strength (bars each side)
input int     InpBars              = 1500;   // Bars of history to scan
input int     InpMaxPivotsBack     = 12;     // How many pivots back to pair
input bool    InpShowBroken        = true;   // Show broken lines (dotted)
input bool    InpAlertOnBreak      = true;   // Alert when a line breaks
input bool    InpPushAlert         = false;  // Also send push notification
input color   InpSupportColor      = clrDodgerBlue;
input color   InpResistColor       = clrTomato;
input color   InpBrokenColor       = clrGray;
input int     InpWidth             = 2;
input string  InpPrefix            = "TL_";  // Object name prefix

ENUM_TIMEFRAMES g_tf;
datetime        g_lastSrcBar = 0;
datetime        g_lastAlertBreak[2]; // [0]=support [1]=resistance

//+------------------------------------------------------------------+
int OnInit()
  {
   g_tf = (InpTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF;
   g_lastAlertBreak[0] = g_lastAlertBreak[1] = 0;
   g_lastSrcBar = 0;
   IndicatorSetString(INDICATOR_SHORTNAME, "Trend_Lines(" + EnumToString(g_tf) + ")");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, InpPrefix);
  }

//+------------------------------------------------------------------+
//| Pivot test on series-ordered arrays (index 0 = newest)            |
//+------------------------------------------------------------------+
bool IsPivot(const MqlRates &r[], int i, int k, bool low)
  {
   for(int j = 1; j <= k; j++)
     {
      if(low)
        { if(r[i].low >= r[i-j].low || r[i].low >= r[i+j].low) return false; }
      else
        { if(r[i].high <= r[i-j].high || r[i].high <= r[i+j].high) return false; }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Line through pivot a (older, larger idx) and b (newer).           |
//| support: price(k) = pb + slope*(b-k)                              |
//| returns 0 = none, 1 = valid unbroken, 2 = valid but broken        |
//| brokenIdx = series index of first close beyond the line (>=0)     |
//+------------------------------------------------------------------+
int EvalLine(const MqlRates &r[], int a, int b, bool support, double &slope, int &brokenIdx)
  {
   double pa = support ? r[a].low : r[a].high;
   double pb = support ? r[b].low : r[b].high;
   if(support  && !(pb > pa)) return 0;   // need rising lows
   if(!support && !(pb < pa)) return 0;   // need falling highs
   slope = (pb - pa) / (double)(a - b);   // per bar, forward in time

   // line must not be cut by closes between the two anchors
   for(int k = a - 1; k > b; k--)
     {
      double y = pb + slope * (b - k);
      if(support ? (r[k].close < y) : (r[k].close > y)) return 0;
     }
   // after anchor b: has it been broken?
   brokenIdx = -1;
   for(int k = b - 1; k >= 1; k--) // bar 0 is still forming
     {
      double y = pb + slope * (b - k);
      if(support ? (r[k].close < y) : (r[k].close > y)) { brokenIdx = k; break; }
     }
   return (brokenIdx < 0) ? 1 : 2;
  }

//+------------------------------------------------------------------+
void DrawLine(const string name, datetime t1, double p1, datetime t2, double p2,
              color clr, bool broken)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, broken ? 1 : InpWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE, broken ? STYLE_DOT : STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, !broken);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

//+------------------------------------------------------------------+
void BuildSide(const MqlRates &r[], const int &piv[], int n, bool support)
  {
   string name = InpPrefix + (support ? "Support" : "Resist");
   int side = support ? 0 : 1;

   int bestA = -1, bestB = -1, bestState = 0, bestBroken = -1;
   double bestSlope = 0;
   int maxB = MathMin(n - 1, 3);

   // prefer the newest valid unbroken line; fall back to newest valid broken
   for(int bi = 0; bi <= maxB && bestState != 1; bi++)
      for(int ai = bi + 1; ai < n && ai <= bi + InpMaxPivotsBack; ai++)
        {
         double s; int br;
         int st = EvalLine(r, piv[ai], piv[bi], support, s, br);
         if(st == 0) continue;
         if(st == 1) { bestA = piv[ai]; bestB = piv[bi]; bestState = 1; bestSlope = s; bestBroken = -1; break; }
         if(bestState == 0) { bestA = piv[ai]; bestB = piv[bi]; bestState = 2; bestSlope = s; bestBroken = br; }
        }

   if(bestState == 0 || (bestState == 2 && !InpShowBroken))
     {
      ObjectDelete(0, name);
      return;
     }

   double pa = support ? r[bestA].low : r[bestA].high;
   double pb = support ? r[bestB].low : r[bestB].high;
   bool broken = (bestState == 2);

   if(!broken)
      DrawLine(name, r[bestA].time, pa, r[bestB].time, pb,
               support ? InpSupportColor : InpResistColor, false);
   else
     {
      // draw only up to the break bar
      double yb = pb + bestSlope * (bestB - bestBroken);
      DrawLine(name, r[bestA].time, pa, r[bestBroken].time, yb, InpBrokenColor, true);

      if(InpAlertOnBreak && bestBroken == 1 && g_lastAlertBreak[side] != r[1].time)
        {
         g_lastAlertBreak[side] = r[1].time;
         string msg = StringFormat("%s %s %s trend line broken @ %s",
                                   _Symbol, EnumToString(g_tf),
                                   support ? "support" : "resistance",
                                   DoubleToString(r[1].close, _Digits));
         Alert(msg);
         if(InpPushAlert) SendNotification(msg);
        }
     }
  }

//+------------------------------------------------------------------+
void Rebuild()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = MathMax(InpBars, 4 * InpStrength + 20);
   int got = CopyRates(_Symbol, g_tf, 0, need, r);
   if(got < 2 * InpStrength + 5) return;

   int lows[], highs[];
   int nl = 0, nh = 0;
   ArrayResize(lows, 0);
   ArrayResize(highs, 0);
   // newest confirmed pivot is at index InpStrength
   for(int i = InpStrength; i < got - InpStrength; i++)
     {
      if(IsPivot(r, i, InpStrength, true))  { ArrayResize(lows, nl + 1);  lows[nl++]  = i; }
      if(IsPivot(r, i, InpStrength, false)) { ArrayResize(highs, nh + 1); highs[nh++] = i; }
     }

   if(nl >= 2) BuildSide(r, lows, nl, true);   else ObjectDelete(0, InpPrefix + "Support");
   if(nh >= 2) BuildSide(r, highs, nh, false); else ObjectDelete(0, InpPrefix + "Resist");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   datetime src = iTime(_Symbol, g_tf, 0);
   if(src == 0) return rates_total;      // history not ready yet
   if(src != g_lastSrcBar || prev_calculated == 0)
     {
      g_lastSrcBar = src;
      Rebuild();
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
