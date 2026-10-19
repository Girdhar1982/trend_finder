//+------------------------------------------------------------------+
//| TrendUJ.mq5                                                      |
//| USDJPY trend identifier: Hull MA slope, tuned on H1.             |
//|                                                                  |
//|  - Hull(50) line, green while its slope is up, red while down.   |
//|  - An arrow marks each flip once the bar has CLOSED (no repaint  |
//|    of arrows; the forming bar's colour is provisional).          |
//|  - Panel: current state and how long/how far it has run, whether |
//|    it agrees with the DAILY trend (D1 EMA100 slope), and the     |
//|    honest scorecard of the last completed trend legs.            |
//|                                                                  |
//| Why these settings (USDJPY H1, 2014-2026, cost 1.2 pips/leg):    |
//|  period 45-60 and NO slope filter was the stable plateau; the    |
//|  common period-20 + ATR-slope-filter setting flipped ~550x/year  |
//|  and lost. Flips do not predict the next day's move: this is a   |
//|  trend FOLLOWER (few big winners, many small losers), not a      |
//|  forecaster. It is weak in sideways markets.                     |
//| Clock: broker server = New York + 7 hours all year.              |
//+------------------------------------------------------------------+
#property copyright "Trend USDJPY"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   3

#property indicator_label1  "Hull trend"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLimeGreen,clrRed
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3
#property indicator_label2  "Up flip"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLimeGreen
#property indicator_width2  2
#property indicator_label3  "Down flip"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  2

input int              InpPeriod        = 50;        // Hull period
input double           InpSlopeATRMul   = 0.0;       // Min slope as a multiple of ATR(14) (0 = off, recommended)
input int              InpD1EmaPeriod   = 100;       // Daily trend: EMA period on D1
input double           InpLegCostPips   = 1.2;       // Cost per trade leg used in the scorecard (pips)
input int              InpLegsShown     = 20;        // Completed legs in the scorecard
input int              InpServerAheadOfNY = 7;       // Broker server clock minus New York clock (hours)
input bool             InpAlert         = true;      // Pop-up alert on a confirmed flip
input bool             InpPush          = false;     // Push notification on a confirmed flip
input ENUM_BASE_CORNER InpCorner        = CORNER_LEFT_UPPER; // Panel corner
input int              InpX             = 10;        // Panel X offset
input int              InpY             = 20;        // Panel Y offset
input int              InpFontSize      = 10;        // Panel font size
input string           InpFont          = "Consolas"; // Panel font
input color            InpUpColor       = clrDarkGreen;     // Colour: up text
input color            InpDownColor     = clrCrimson;       // Colour: down text
input color            InpTextColor     = clrDimGray;       // Colour: neutral text

const string PANEL   = "TRUJ_";
const int    MAXROWS = 8;

double g_hull[], g_col[], g_up[], g_dn[], g_raw[], g_state[], g_atr[];
double   g_pip = 0;
datetime g_lastAlert = 0;
int      g_d1State = 0;                  // sign of the D1 EMA slope
datetime g_d1Stamp = 0;

//+------------------------------------------------------------------+
//| Time zones (display only)                                        |
//+------------------------------------------------------------------+
datetime NthSundayUtc(const int year, const int mon, const int n, const int hourUtc)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year;
   t.mon  = mon;
   t.day  = 1;
   datetime d = StructToTime(t);
   TimeToStruct(d, t);
   const int first = 1 + (7 - t.day_of_week) % 7;
   t.day  = first + 7 * (n - 1);
   t.hour = hourUtc;
   return StructToTime(t);
  }

int NyOffset(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc, t);
   const bool dst = utc >= NthSundayUtc(t.year, 3, 2, 7) && utc < NthSundayUtc(t.year, 11, 1, 6);
   return dst ? -4 * 3600 : -5 * 3600;
  }

int SydOffset(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc, t);
   const bool dst = utc < NthSundayUtc(t.year, 4, 1, 16) - 86400 || utc >= NthSundayUtc(t.year, 10, 1, 16) - 86400;
   return dst ? 11 * 3600 : 10 * 3600;
  }

//+------------------------------------------------------------------+
//| "dd.mm hh:mm NY / dd.mm hh:mm SYD" for a server timestamp        |
//+------------------------------------------------------------------+
string Both(const datetime srv)
  {
   const datetime ny  = srv - InpServerAheadOfNY * 3600;
   const datetime utc = ny - NyOffset(ny + 5 * 3600);
   const datetime syd = utc + SydOffset(utc);
   return StringFormat("%s NY / %s SYD", TimeToString(ny, TIME_DATE | TIME_MINUTES), TimeToString(syd, TIME_MINUTES));
  }

//+------------------------------------------------------------------+
//| Weighted MA over x[pos-len+1..pos], newest weighted highest      |
//+------------------------------------------------------------------+
double Wma(const double &x[], const int pos, const int len)
  {
   double s = 0, ws = 0;
   for(int j = 0; j < len; j++)
     {
      const double w = j + 1;
      s  += x[pos - len + 1 + j] * w;
      ws += w;
     }
   return s / ws;
  }

//+------------------------------------------------------------------+
void SetRow(const int i, const string text, const color clr)
  {
   const string name = PANEL + IntegerToString(i);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     InpCorner);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  InpY + i * (InpFontSize + 7));
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetString(0,  name, OBJPROP_FONT,       InpFont);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   ObjectSetString(0,  name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//| Sign of the D1 EMA slope (closed daily bars only)                |
//+------------------------------------------------------------------+
void UpdateDaily()
  {
   const datetime d1 = iTime(_Symbol, PERIOD_D1, 0);
   if(d1 == g_d1Stamp && g_d1State != 0)
      return;
   double c[];
   const int got = CopyClose(_Symbol, PERIOD_D1, 1, 500, c);       // shift 1 = last closed day
   if(got < InpD1EmaPeriod + 5)
      return;
   ArraySetAsSeries(c, false);
   const double a = 2.0 / (InpD1EmaPeriod + 1);
   double e = c[0], prev = c[0];
   for(int i = 1; i < got; i++)
     {
      prev = e;
      e = a * c[i] + (1 - a) * e;
     }
   g_d1State = e > prev ? 1 : (e < prev ? -1 : 0);
   g_d1Stamp = d1;
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void Panel(const int total, const datetime &time[], const double &open[], const double &close[])
  {
   int row = 0;
   const int last = total - 2;                                     // last CLOSED bar
   SetRow(row++, StringFormat("TREND UJ   Hull(%d)   %s %s", InpPeriod, _Symbol, EnumToString((ENUM_TIMEFRAMES)Period())), clrDimGray);
   if(Period() != PERIOD_H1)
      SetRow(row++, "Tuned and tested on H1 only - other timeframes are untested.", clrDarkOrange);
   if(last < InpPeriod * 2 || g_state[last] == 0)
     {
      SetRow(row++, "Waiting for enough history...", InpTextColor);
      for(int i = row; i < MAXROWS; i++)
         ObjectDelete(0, PANEL + IntegerToString(i));
      return;
     }
   const int s = (int)g_state[last];
   int k = last;
   while(k > 0 && (int)g_state[k - 1] == s)
      k--;                                                          // k = bar where this run was confirmed
   const double now = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (k + 1 <= total - 1) ? open[k + 1] : close[k];
   const double runPips = s * (now - entry) / g_pip;
   const double hours = (double)(time[total - 1] - time[k]) / 3600.0;
   SetRow(row++, StringFormat("%s since %s", s > 0 ? "UP   " : "DOWN ", Both(time[k] + PeriodSeconds())), s > 0 ? InpUpColor : InpDownColor);
   SetRow(row++, StringFormat("Run: %.1f days, %+.1f pips from the flip entry %s", hours / 24.0, runPips, DoubleToString(entry, _Digits)),
          runPips >= 0 ? InpUpColor : InpDownColor);

   UpdateDaily();
   if(g_d1State == 0)
      SetRow(row++, "Daily trend: waiting for D1 history", InpTextColor);
   else
      SetRow(row++, StringFormat("Daily trend (D1 EMA%d): %s  -> this H1 trend is %s", InpD1EmaPeriod, g_d1State > 0 ? "UP" : "DOWN",
                                 g_d1State == s ? "WITH it (higher grade)" : "AGAINST it (lower grade)"),
             g_d1State == s ? InpUpColor : clrDarkOrange);

   // scorecard of the last completed legs: enter at the open after the flip bar, leave at the open after the next flip
   int flips[];
   int nf = 0;
   for(int i = last; i > 0 && nf < InpLegsShown + 2; i--)
      if(g_state[i] != g_state[i - 1] && g_state[i - 1] != 0)
        {
         ArrayResize(flips, nf + 1);
         flips[nf++] = i;
        }
   int legs = 0, wins = 0;
   double sum = 0, best = -1e9, worst = 1e9;
   for(int j = 1; j < nf && legs < InpLegsShown; j++)             // flips[] is newest first
     {
      const int a = flips[j] + 1, b = flips[j - 1] + 1;            // leg from flip j to flip j-1
      if(b > total - 1)
         continue;
      const double dir = g_state[flips[j]];
      const double p = dir * (open[b] - open[a]) / g_pip - InpLegCostPips;
      legs++; sum += p; best = MathMax(best, p); worst = MathMin(worst, p);
      if(p > 0)
         wins++;
     }
   if(legs > 0)
     {
      SetRow(row++, StringFormat("Last %d completed legs: %d won (%.0f%%), net %+.0f pips, avg %+.1f, best %+.0f, worst %+.0f", legs, wins,
                                 100.0 * wins / legs, sum, sum / legs, best, worst), sum >= 0 ? InpUpColor : InpDownColor);
      SetRow(row++, "Few big wins pay for many small losses; sideways markets whipsaw it.", InpTextColor);
     }
   SetRow(row++, "A flip does NOT predict tomorrow's move; it follows a move already made.", InpTextColor);
   for(int i = row; i < MAXROWS; i++)
      ObjectDelete(0, PANEL + IntegerToString(i));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_pip = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;
   SetIndexBuffer(0, g_hull,  INDICATOR_DATA);
   SetIndexBuffer(1, g_col,   INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, g_up,    INDICATOR_DATA);
   SetIndexBuffer(3, g_dn,    INDICATOR_DATA);
   SetIndexBuffer(4, g_raw,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, g_state, INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, g_atr,   INDICATOR_CALCULATIONS);
   PlotIndexSetInteger(1, PLOT_ARROW, 233);
   PlotIndexSetInteger(2, PLOT_ARROW, 234);
   for(int p = 0; p < 3; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("TrendUJ(%d)", InpPeriod));
   PrintFormat("TrendUJ: %s period=%d slopeATR=%.2f d1ema=%d legCost=%.1f legs=%d server=NY%+d", _Symbol, InpPeriod, InpSlopeATRMul,
               InpD1EmaPeriod, InpLegCostPips, InpLegsShown, InpServerAheadOfNY);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PANEL);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   const int half = MathMax(InpPeriod / 2, 1);
   const int sq   = (int)MathMax(MathRound(MathSqrt((double)InpPeriod)), 1);
   const int firstRaw  = InpPeriod - 1;
   const int firstHull = firstRaw + sq - 1;
   if(rates_total < firstHull + 5)
      return 0;
   ArraySetAsSeries(g_hull, false); ArraySetAsSeries(g_col, false); ArraySetAsSeries(g_up, false);
   ArraySetAsSeries(g_dn, false); ArraySetAsSeries(g_raw, false); ArraySetAsSeries(g_state, false);
   ArraySetAsSeries(g_atr, false);

   int start = prev_calculated > 1 ? prev_calculated - 1 : 0;
   if(start == 0)
      for(int i = 0; i < rates_total; i++)
        {
         g_hull[i] = EMPTY_VALUE; g_up[i] = EMPTY_VALUE; g_dn[i] = EMPTY_VALUE; g_col[i] = 0; g_raw[i] = 0; g_state[i] = 0; g_atr[i] = 0;
        }
   for(int i = start; i < rates_total; i++)
     {
      g_up[i] = EMPTY_VALUE; g_dn[i] = EMPTY_VALUE; g_hull[i] = EMPTY_VALUE;
      const double tr = i == 0 ? high[i] - low[i] : MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i - 1]), MathAbs(low[i] - close[i - 1])));
      g_atr[i] = i == 0 ? tr : (i < 14 ? (g_atr[i - 1] * i + tr) / (i + 1) : (g_atr[i - 1] * 13 + tr) / 14);
      if(i >= firstRaw)
         g_raw[i] = 2.0 * Wma(close, i, half) - Wma(close, i, InpPeriod);
      if(i >= firstHull)
         g_hull[i] = Wma(g_raw, i, sq);
      g_state[i] = i > 0 ? g_state[i - 1] : 0;
      if(i > firstHull && g_hull[i - 1] != EMPTY_VALUE)
        {
         const double slope = g_hull[i] - g_hull[i - 1], thr = InpSlopeATRMul * g_atr[i];
         if(slope > thr)
            g_state[i] = 1;
         else if(slope < -thr)
            g_state[i] = -1;
        }
      g_col[i] = g_state[i] < 0 ? 1 : 0;
      // confirmed flip arrows (closed bars only)
      if(i > 0 && i <= rates_total - 2 && g_state[i] != g_state[i - 1] && g_state[i - 1] != 0)
        {
         const double off = MathMax(g_atr[i] * 0.3, 10 * _Point);
         if(g_state[i] > 0)
            g_up[i] = low[i] - off;
         else
            g_dn[i] = high[i] + off;
         if(prev_calculated > 0 && i == rates_total - 2 && time[i] > g_lastAlert)
           {
            g_lastAlert = time[i];
            const string msg = StringFormat("%s trend flip to %s (Hull %d) at %s", _Symbol, g_state[i] > 0 ? "UP" : "DOWN", InpPeriod,
                                            DoubleToString(close[i], _Digits));
            if(InpAlert) Alert(msg);
            if(InpPush)  SendNotification(msg);
           }
        }
     }
   Panel(rates_total, time, open, close);
   return rates_total;
  }
