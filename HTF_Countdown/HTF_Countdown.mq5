//+------------------------------------------------------------------+
//| HTF_Countdown.mq5                                                |
//| Shows time left until the current M15, H1, H4 and D1 candles     |
//| close, each with its RSI, as a single line at the top of the     |
//| bottom pane of the chart (its own sub-window, like RSI). Updates |
//| every second.                                                    |
//+------------------------------------------------------------------+
#property copyright "HTF Countdown"
#property version   "1.00"
#property indicator_separate_window
#property indicator_plots 0

input int              InpX        = 10;                // X offset
input int              InpY        = 6;                 // Y offset
input int              InpFontSize = 12;                // Font size
input string           InpFont     = "Consolas";        // Font
input color            InpColor    = clrDarkRed;        // Text colour (None = auto-contrast with background)
input color            InpWarnColor= clrBlue;           // Warning colour
input int              InpWarnMins = 5;                 // Warn when this many minutes or fewer are left
input int              InpRsiPeriod= 14;                // RSI period
input double           InpRsiOB    = 70.0;              // RSI overbought level
input double           InpRsiOS    = 30.0;              // RSI oversold level
input double           InpRsiNear  = 10.0;              // "Approaching" zone width (points inside the neutral band)
input color            InpColOB    = clrRed;            // RSI: overbought
input color            InpColNearOB= clrDarkOrange;     // RSI: approaching overbought
input color            InpColNeutral= clrGray;          // RSI: neutral
input color            InpColNearOS= clrTeal;           // RSI: approaching oversold
input color            InpColOS    = clrGreen;          // RSI: oversold

const string PREFIX = "HTFCDP_"; // differs from the old chart-window version so the two never share objects
#define N_TF 4
const ENUM_TIMEFRAMES TFS[N_TF] = {PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
const string NAMES[N_TF]        = {"M15", "H1", "H4", "D1"};
int rsiHandle[N_TF];
int subWin = 0;

//+------------------------------------------------------------------+
string Fmt(const long secs)
  {
   long s = secs < 0 ? 0 : secs;
   if(s >= 3600)
      return StringFormat("%02d:%02d:%02d", (int)(s / 3600), (int)((s % 3600) / 60), (int)(s % 60));
   return StringFormat("%02d:%02d", (int)(s / 60), (int)(s % 60));
  }

//+------------------------------------------------------------------+
void MakeLabel(const string name, const int x)
  {
   if(ObjectFind(0, name) >= 0)
      return;
   ObjectCreate(0, name, OBJ_LABEL, subWin, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  InpY);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetString(0,  name, OBJPROP_FONT,       InpFont);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

//+------------------------------------------------------------------+
double RsiValue(const int i)
  {
   double v[1];
   if(rsiHandle[i] == INVALID_HANDLE || CopyBuffer(rsiHandle[i], 0, 0, 1, v) != 1)
      return EMPTY_VALUE;
   return v[0];
  }

//+------------------------------------------------------------------+
color RsiColor(const double v)
  {
   if(v >= InpRsiOB)
      return InpColOB;
   if(v <= InpRsiOS)
      return InpColOS;
   if(v >= InpRsiOB - InpRsiNear)
      return InpColNearOB;
   if(v <= InpRsiOS + InpRsiNear)
      return InpColNearOS;
   return InpColNeutral;
  }

//+------------------------------------------------------------------+
color TextColor()
  {
   if(InpColor != clrNONE)
      return InpColor;
   const color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   const int r = bg & 0xFF, g = (bg >> 8) & 0xFF, b = (bg >> 16) & 0xFF;
   return (r * 299 + g * 587 + b * 114) / 1000 > 128 ? clrBlack : clrWhite;
  }

//+------------------------------------------------------------------+
void Refresh()
  {
   if(subWin <= 0)
      subWin = ChartWindowFind();
   if(subWin <= 0)
      return;   // pane not attached yet; the next timer tick retries
   const datetime now = TimeTradeServer();
   for(int i = 0; i < N_TF; i++)
     {
      const string rname = PREFIX + NAMES[i] + "_RSI";
      const int slot = InpX + i * InpFontSize * 21;
      MakeLabel(PREFIX + NAMES[i], slot);
      MakeLabel(rname, slot + InpFontSize * 12);   // RSI sits right of the countdown, own colour
      const datetime open = iTime(_Symbol, TFS[i], 0);
      if(open == 0)
         continue;
      const long left = (long)open + PeriodSeconds(TFS[i]) - (long)now;
      const string name = PREFIX + NAMES[i];
      ObjectSetString(0, name, OBJPROP_TEXT, NAMES[i] + " " + Fmt(left));
      ObjectSetInteger(0, name, OBJPROP_COLOR, left < InpWarnMins * 60 ? InpWarnColor : TextColor());
      const double rv = RsiValue(i);
      ObjectSetString(0, rname, OBJPROP_TEXT, rv == EMPTY_VALUE ? "RSI --" : StringFormat("RSI %.1f", rv));
      ObjectSetInteger(0, rname, OBJPROP_COLOR, rv == EMPTY_VALUE ? InpColNeutral : RsiColor(rv));
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   IndicatorSetString(INDICATOR_SHORTNAME, "HTF Countdown");
   IndicatorSetInteger(INDICATOR_HEIGHT, InpFontSize * 2 + InpY * 2);
   for(int i = 0; i < N_TF; i++)
      rsiHandle[i] = iRSI(_Symbol, TFS[i], InpRsiPeriod, PRICE_CLOSE);
   EventSetTimer(1);
   Refresh();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < N_TF; i++)
      if(rsiHandle[i] != INVALID_HANDLE)
         IndicatorRelease(rsiHandle[i]);
   ObjectsDeleteAll(0, PREFIX);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Refresh();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   return rates_total;
  }
//+------------------------------------------------------------------+
