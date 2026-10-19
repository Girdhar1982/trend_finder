//+------------------------------------------------------------------+
//| HTF_Countdown.mq5                                                |
//| Shows time left until the current H1, H4 and D1 candles close,   |
//| as a single line at the top of the chart. Updates every second.  |
//+------------------------------------------------------------------+
#property copyright "HTF Countdown"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input ENUM_BASE_CORNER InpCorner   = CORNER_RIGHT_UPPER; // Corner
input int              InpX        = 10;                // X offset
input int              InpY        = 20;                // Y offset
input int              InpFontSize = 12;                // Font size
input string           InpFont     = "Consolas";        // Font
input color            InpColor    = clrDarkRed;        // Text colour (None = auto-contrast with background)
input color            InpWarnColor= clrBlue;           // Warning colour
input int              InpWarnMins = 5;                 // Warn when this many minutes or fewer are left

const string PREFIX = "HTFCD_";
const ENUM_TIMEFRAMES TFS[3] = {PERIOD_H1, PERIOD_H4, PERIOD_D1};
const string NAMES[3]        = {"H1", "H4", "D1"};

//+------------------------------------------------------------------+
string Fmt(const long secs)
  {
   long s = secs < 0 ? 0 : secs;
   if(s >= 3600)
      return StringFormat("%02d:%02d:%02d", (int)(s / 3600), (int)((s % 3600) / 60), (int)(s % 60));
   return StringFormat("%02d:%02d", (int)(s / 60), (int)(s % 60));
  }

//+------------------------------------------------------------------+
void MakeLabel(const int i)
  {
   const string name = PREFIX + NAMES[i];
   if(ObjectFind(0, name) >= 0)
      return;
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     InpCorner);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpX + (2 - i) * InpFontSize * 11);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  InpY);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetString(0,  name, OBJPROP_FONT,       InpFont);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
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
   const datetime now = TimeTradeServer();
   for(int i = 0; i < 3; i++)
     {
      MakeLabel(i);
      const datetime open = iTime(_Symbol, TFS[i], 0);
      if(open == 0)
         continue;
      const long left = (long)open + PeriodSeconds(TFS[i]) - (long)now;
      const string name = PREFIX + NAMES[i];
      ObjectSetString(0, name, OBJPROP_TEXT, NAMES[i] + " " + Fmt(left));
      ObjectSetInteger(0, name, OBJPROP_COLOR, left < InpWarnMins * 60 ? InpWarnColor : TextColor());
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(1);
   Refresh();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
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
