//+------------------------------------------------------------------+
//| RSI_Divergence.mq5                                               |
//| RSI in a sub-window + regular divergences, armed by the extremes:|
//|                                                                  |
//|  BULL (green): RSI makes a swing low BELOW 30 (arms the search). |
//|    A later RSI swing low that is HIGHER while price makes a      |
//|    LOWER low = bullish divergence.                               |
//|  BEAR (red):  RSI makes a swing high ABOVE 70 (arms the search). |
//|    A later RSI swing high that is LOWER while price makes a      |
//|    HIGHER high = bearish divergence.                             |
//|                                                                  |
//|  The search is cancelled if RSI reaches the opposite extreme     |
//|  in between, or the two swings are more than MaxBars apart.      |
//|  The RSI line between the two swings must not be cut (a cleaner |
//|  divergence). Lines are drawn on RSI and on price.               |
//|                                                                  |
//|  v1.10: cloud fill - the divergence span is shaded in the RSI    |
//|  window only (RSI vs the 30/70 level).                         |
//|                                                                  |
//|  Swings are confirmed PivotRight bars later on CLOSED bars, so   |
//|  once a signal is drawn it does not repaint.                     |
//+------------------------------------------------------------------+
#property copyright "RSI Divergence"
#property version   "1.10"
#property indicator_separate_window
#property indicator_minimum 0
#property indicator_maximum 100
#property indicator_buffers 7
#property indicator_plots   5
#property indicator_level1  30
#property indicator_level2  70
#property indicator_level3  45
#property indicator_level4  55
#property indicator_levelcolor clrDimGray
#property indicator_levelstyle STYLE_DOT

// clouds first so the RSI line and arrows are drawn on top of them
#property indicator_label1  "Bull cloud"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  C'120,200,120',C'120,200,120'
#property indicator_label2  "Bear cloud"
#property indicator_type2   DRAW_FILLING
#property indicator_color2  C'230,130,130',C'230,130,130'
#property indicator_label3  "RSI"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrSilver
#property indicator_width3  1
#property indicator_label4  "Bull divergence"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLime
#property indicator_width4  2
#property indicator_label5  "Bear divergence"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_width5  2

input int                InpRSIPeriod   = 14;          // RSI period
input ENUM_APPLIED_PRICE InpPrice       = PRICE_CLOSE; // RSI applied price
input double             InpOversold    = 30.0;        // Oversold level (arms bull search)
input double             InpOverbought  = 70.0;        // Overbought level (arms bear search)
input double             InpMidLow      = 45.0;        // Middle level (lower)
input double             InpMidHigh     = 55.0;        // Middle level (upper)
input int                InpPivotLeft   = 5;           // Swing: bars to the left
input int                InpPivotRight  = 2;           // Swing: bars to the right (confirmation lag)
input int                InpMinBars     = 5;           // Min bars between the two swings
input int                InpMaxBars     = 60;          // Max bars between the two swings
input double             InpBullMaxRSI  = 50.0;        // Bull: 2nd RSI low must be below
input double             InpBearMinRSI  = 50.0;        // Bear: 2nd RSI high must be above
input bool               InpCleanLine   = true;        // RSI must not cut the divergence line
input bool               InpDrawOnPrice = true;        // Also draw lines on the price chart
input color              InpBullColor   = clrLime;     // Bull colour (lines/arrows)
input color              InpBearColor   = clrRed;      // Bear colour (lines/arrows)
input bool               InpCloudRSI    = true;        // Cloud fill in the RSI window
input color              InpBullCloud   = C'120,200,120';  // Bull cloud colour
input color              InpBearCloud   = C'230,130,130';  // Bear cloud colour
input int                InpHistoryBars = 5000;        // Bars of history to scan
input bool               InpAlert       = true;        // Popup alert on new divergence
input bool               InpPush        = false;       // Push notification
input bool               InpSound       = false;       // Play sound

double BullFillA[], BullFillB[];
double BearFillA[], BearFillB[];
double RsiBuf[];
double BullBuf[];
double BearBuf[];

int    g_handle = INVALID_HANDLE;
string g_prefix;

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BullFillA, INDICATOR_DATA);
   SetIndexBuffer(1, BullFillB, INDICATOR_DATA);
   SetIndexBuffer(2, BearFillA, INDICATOR_DATA);
   SetIndexBuffer(3, BearFillB, INDICATOR_DATA);
   SetIndexBuffer(4, RsiBuf,    INDICATOR_DATA);
   SetIndexBuffer(5, BullBuf,   INDICATOR_DATA);
   SetIndexBuffer(6, BearBuf,   INDICATOR_DATA);
   ArraySetAsSeries(BullFillA, false);
   ArraySetAsSeries(BullFillB, false);
   ArraySetAsSeries(BearFillA, false);
   ArraySetAsSeries(BearFillB, false);
   ArraySetAsSeries(RsiBuf,    false);
   ArraySetAsSeries(BullBuf,   false);
   ArraySetAsSeries(BearBuf,   false);

   // plots: 0 bull cloud, 1 bear cloud, 2 RSI, 3 bull arrow, 4 bear arrow
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, InpBullCloud);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, InpBullCloud);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 0, InpBearCloud);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 1, InpBearCloud);
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(1, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(3, PLOT_ARROW, 233);   // up arrow
   PlotIndexSetInteger(4, PLOT_ARROW, 234);   // down arrow
   PlotIndexSetInteger(3, PLOT_LINE_COLOR, InpBullColor);
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, InpBearColor);
   for(int p = 0; p < 5; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetInteger(INDICATOR_DIGITS, 1);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, InpOversold);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, InpOverbought);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, InpMidLow);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 3, InpMidHigh);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("RSI Div(%d) %.0f/%.0f", InpRSIPeriod, InpOversold, InpOverbought));

   g_handle = iRSI(_Symbol, _Period, InpRSIPeriod, InpPrice);
   if(g_handle == INVALID_HANDLE)
     {
      Print("RSI_Divergence: iRSI failed, error ", GetLastError());
      return INIT_FAILED;
     }
   g_prefix = StringFormat("RSIDiv_%d_", (int)(GetTickCount() % 100000));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
   if(g_handle != INVALID_HANDLE)
      IndicatorRelease(g_handle);
  }

//+------------------------------------------------------------------+
//| Swing tests on the RSI (non-series arrays, index 0 = oldest).    |
//| Ties on the left are allowed, ties on the right are not, so a    |
//| flat bottom gives exactly one swing.                             |
//+------------------------------------------------------------------+
bool IsPivotLow(const int i, const int total)
  {
   if(i - InpPivotLeft < 0 || i + InpPivotRight >= total) return false;
   double v = RsiBuf[i];
   if(v == EMPTY_VALUE) return false;
   for(int k = 1; k <= InpPivotLeft; k++)
      if(RsiBuf[i - k] == EMPTY_VALUE || RsiBuf[i - k] < v) return false;
   for(int k = 1; k <= InpPivotRight; k++)
      if(RsiBuf[i + k] <= v) return false;
   return true;
  }

bool IsPivotHigh(const int i, const int total)
  {
   if(i - InpPivotLeft < 0 || i + InpPivotRight >= total) return false;
   double v = RsiBuf[i];
   if(v == EMPTY_VALUE) return false;
   for(int k = 1; k <= InpPivotLeft; k++)
      if(RsiBuf[i - k] == EMPTY_VALUE || RsiBuf[i - k] > v) return false;
   for(int k = 1; k <= InpPivotRight; k++)
      if(RsiBuf[i + k] >= v) return false;
   return true;
  }

//+------------------------------------------------------------------+
void DrawLine(const string name, const int window,
              const datetime t1, const double p1,
              const datetime t2, const double p2, const color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, window, t1, p1, t2, p2);
   else
     {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

//+------------------------------------------------------------------+
//| Cloud: RSI window fill between RSI and the 30/70 level over the  |
//| divergence span (RSI window only).                               |
//+------------------------------------------------------------------+
void FillRSI(double &fa[], double &fb[], const int a, const int c, const double level)
  {
   if(!InpCloudRSI) return;
   for(int k = a; k <= c; k++)
     {
      fa[k] = RsiBuf[k];
      fb[k] = level;
     }
  }

void Notify(const string what, const datetime t)
  {
   string msg = StringFormat("%s %s: %s RSI divergence (swing bar %s)",
                             _Symbol, EnumToString(_Period), what,
                             TimeToString(t, TIME_DATE | TIME_MINUTES));
   if(InpAlert) Alert(msg);
   if(InpPush)  SendNotification(msg);
   if(InpSound) PlaySound("alert.wav");
  }

//+------------------------------------------------------------------+
//| Bullish: c is a fresh RSI swing low. Look back for an armed      |
//| anchor (RSI swing low < oversold) with price low ABOVE price at  |
//| c and RSI BELOW RSI at c.                                        |
//+------------------------------------------------------------------+
bool CheckBull(const int c, const int total, const double &low[], int &anchor)
  {
   if(RsiBuf[c] >= InpBullMaxRSI) return false;
   int stop = MathMax(InpPivotLeft, c - InpMaxBars);
   for(int j = c - 1; j >= stop; j--)
     {
      if(RsiBuf[j] == EMPTY_VALUE) break;
      if(RsiBuf[j] > InpOverbought) break;            // opposite extreme cancels the search
      if(c - j < InpMinBars) continue;
      if(RsiBuf[j] >= InpOversold) continue;          // anchor must be oversold
      if(!IsPivotLow(j, total)) continue;
      if(!(low[c] < low[j] && RsiBuf[c] > RsiBuf[j])) continue;
      if(InpCleanLine)
        {
         bool ok = true;
         double slope = (RsiBuf[c] - RsiBuf[j]) / (c - j);
         for(int k = j + 1; k < c; k++)
            if(RsiBuf[k] < RsiBuf[j] + slope * (k - j)) { ok = false; break; }
         if(!ok) continue;
        }
      anchor = j;
      return true;
     }
   return false;
  }

bool CheckBear(const int c, const int total, const double &high[], int &anchor)
  {
   if(RsiBuf[c] <= InpBearMinRSI) return false;
   int stop = MathMax(InpPivotLeft, c - InpMaxBars);
   for(int j = c - 1; j >= stop; j--)
     {
      if(RsiBuf[j] == EMPTY_VALUE) break;
      if(RsiBuf[j] < InpOversold) break;              // opposite extreme cancels the search
      if(c - j < InpMinBars) continue;
      if(RsiBuf[j] <= InpOverbought) continue;        // anchor must be overbought
      if(!IsPivotHigh(j, total)) continue;
      if(!(high[c] > high[j] && RsiBuf[c] < RsiBuf[j])) continue;
      if(InpCleanLine)
        {
         bool ok = true;
         double slope = (RsiBuf[c] - RsiBuf[j]) / (c - j);
         for(int k = j + 1; k < c; k++)
            if(RsiBuf[k] > RsiBuf[j] + slope * (k - j)) { ok = false; break; }
         if(!ok) continue;
        }
      anchor = j;
      return true;
     }
   return false;
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
   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);

   int need = InpRSIPeriod + InpPivotLeft + InpPivotRight + 2;
   if(rates_total < need) return 0;
   if(BarsCalculated(g_handle) < rates_total) return prev_calculated;

   // --- RSI values (copy only what changed)
   int toCopy = (prev_calculated > 0) ? rates_total - prev_calculated + 1 : rates_total;
   double tmp[];
   ArraySetAsSeries(tmp, false);
   if(CopyBuffer(g_handle, 0, 0, toCopy, tmp) != toCopy) return prev_calculated;
   int base = rates_total - toCopy;
   for(int i = 0; i < toCopy; i++)
      RsiBuf[base + i] = (i + base < InpRSIPeriod) ? EMPTY_VALUE : tmp[i];

   // --- swing candidates: bar c is a swing once bar c+PivotRight is CLOSED
   int lastClosed = rates_total - 2;
   int firstC;
   if(prev_calculated == 0)
     {
      ArrayInitialize(BullBuf,   EMPTY_VALUE);
      ArrayInitialize(BearBuf,   EMPTY_VALUE);
      ArrayInitialize(BullFillA, EMPTY_VALUE);
      ArrayInitialize(BullFillB, EMPTY_VALUE);
      ArrayInitialize(BearFillA, EMPTY_VALUE);
      ArrayInitialize(BearFillB, EMPTY_VALUE);
      ObjectsDeleteAll(0, g_prefix);
      firstC = MathMax(InpRSIPeriod + InpPivotLeft, rates_total - InpHistoryBars);
     }
   else
     {
      for(int i = prev_calculated; i < rates_total; i++)
        {
         BullBuf[i]   = EMPTY_VALUE; BearBuf[i]   = EMPTY_VALUE;
         BullFillA[i] = EMPTY_VALUE; BullFillB[i] = EMPTY_VALUE;
         BearFillA[i] = EMPTY_VALUE; BearFillB[i] = EMPTY_VALUE;
        }
      firstC = (prev_calculated - 2) - InpPivotRight + 1;   // continue where we stopped
     }
   int lastC = lastClosed - InpPivotRight;
   bool live = (prev_calculated > 0);
   int  sub  = ChartWindowFind();

   for(int c = MathMax(firstC, InpPivotLeft); c <= lastC; c++)
     {
      int a;
      if(BullBuf[c] == EMPTY_VALUE && IsPivotLow(c, lastClosed + 1) && CheckBull(c, lastClosed + 1, low, a))
        {
         BullBuf[c] = RsiBuf[c] - 4.0;
         string id = IntegerToString((long)time[c]);
         FillRSI(BullFillA, BullFillB, a, c, InpOversold);
         if(sub >= 0)
            DrawLine(g_prefix + "BuR_" + id, sub, time[a], RsiBuf[a], time[c], RsiBuf[c], InpBullColor);
         if(InpDrawOnPrice)
            DrawLine(g_prefix + "BuP_" + id, 0, time[a], low[a], time[c], low[c], InpBullColor);
         if(live) Notify("BULLISH", time[c]);
        }
      if(BearBuf[c] == EMPTY_VALUE && IsPivotHigh(c, lastClosed + 1) && CheckBear(c, lastClosed + 1, high, a))
        {
         BearBuf[c] = RsiBuf[c] + 4.0;
         string id = IntegerToString((long)time[c]);
         FillRSI(BearFillA, BearFillB, a, c, InpOverbought);
         if(sub >= 0)
            DrawLine(g_prefix + "BeR_" + id, sub, time[a], RsiBuf[a], time[c], RsiBuf[c], InpBearColor);
         if(InpDrawOnPrice)
            DrawLine(g_prefix + "BeP_" + id, 0, time[a], high[a], time[c], high[c], InpBearColor);
         if(live) Notify("BEARISH", time[c]);
        }
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
