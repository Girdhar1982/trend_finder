//+------------------------------------------------------------------+
//| Session_Clock.mq5                                                |
//| Shows which trading sessions are open and the time left until    |
//| each one closes (or opens), in its own pane below the chart.     |
//| Forex : Sydney, Tokyo, London, New York (Mon-Fri only)           |
//| Crypto: Asia, Europe, US (24/7)                                  |
//| All session hours are UTC and editable; times use TimeGMT().     |
//+------------------------------------------------------------------+
#property copyright "Session Clock"
#property version   "1.00"
#property indicator_separate_window
#property indicator_plots 0

enum ENUM_MARKET { MARKET_AUTO, MARKET_FOREX, MARKET_CRYPTO };

input ENUM_MARKET      InpMarket    = MARKET_AUTO;       // Market (Auto = by symbol path)
input int              InpX         = 10;                // X offset
input int              InpY         = 6;                 // Y offset
input int              InpFontSize  = 11;                // Font size
input string           InpFont      = "Consolas";        // Font
input color            InpOpenColor = clrDarkGreen;         // Colour: session open
input color            InpClosedColor = clrDimGray;        // Colour: session closed
input color            InpSoonColor = clrDarkRed;          // Colour: opens/closes within warn window
input int              InpWarnMins  = 15;                // Warn window (minutes)

input group "Forex sessions (UTC hours)"
input int InpSydStart = 21; input int InpSydEnd = 6;
input int InpTokStart = 0;  input int InpTokEnd = 9;
input int InpLonStart = 7;  input int InpLonEnd = 16;
input int InpNyStart  = 12; input int InpNyEnd  = 21;
input group "Crypto sessions (UTC hours)"
input int InpAsiaStart = 0;  input int InpAsiaEnd = 8;
input int InpEurStart  = 7;  input int InpEurEnd  = 16;
input int InpUsStart   = 13; input int InpUsEnd   = 22;

const string PREFIX = "SESCLKP_"; // differs from the old chart-window version so the two never share objects
const int    MAXROWS = 5;

string g_names[];
int    g_start[];
int    g_end[];
bool   g_forex = true;
int    g_subWin = 0;

//+------------------------------------------------------------------+
bool IsCryptoSymbol()
  {
   string path = SymbolInfoString(_Symbol, SYMBOL_PATH);
   StringToLower(path);
   return StringFind(path, "crypto") >= 0;
  }

//+------------------------------------------------------------------+
void AddSession(const string n, const int s, const int e)
  {
   const int k = ArraySize(g_names);
   ArrayResize(g_names, k + 1);
   ArrayResize(g_start, k + 1);
   ArrayResize(g_end,   k + 1);
   g_names[k] = n;
   g_start[k] = s;
   g_end[k]   = e;
  }

//+------------------------------------------------------------------+
string Fmt(const long secs)
  {
   const long s = secs < 0 ? 0 : secs;
   return StringFormat("%02d:%02d:%02d", (int)(s / 3600), (int)((s % 3600) / 60), (int)(s % 60));
  }

//+------------------------------------------------------------------+
//| Forex is closed from Fri 21:00 UTC to Sun 21:00 UTC (approx.)    |
//+------------------------------------------------------------------+
bool ForexWeekend(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc, t);
   if(t.day_of_week == 6)
      return true;
   if(t.day_of_week == 0 && t.hour < 21)
      return true;
   if(t.day_of_week == 5 && t.hour >= 21)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
void SetRow(const int i, const string text, const color clr)
  {
   const string name = PREFIX + IntegerToString(i);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, g_subWin, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  InpY + i * (InpFontSize + 8));
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
void Refresh()
  {
   if(g_subWin <= 0)
      g_subWin = ChartWindowFind();
   if(g_subWin <= 0)
      return;   // pane not attached yet; the next timer tick retries
   const datetime utc = TimeGMT();
   int row = 0;

   if(g_forex && ForexWeekend(utc))
     {
      SetRow(row++, "Forex market closed (weekend)", InpClosedColor);
     }
   else
     {
      const long tod = (long)utc % 86400;
      for(int k = 0; k < ArraySize(g_names); k++)
        {
         const long s = g_start[k] * 3600L;
         const long e = g_end[k] * 3600L;
         const bool open = (s < e) ? (tod >= s && tod < e) : (tod >= s || tod < e);
         const long left = open ? (e - tod + 86400) % 86400 : (s - tod + 86400) % 86400;
         const long since = (tod - s + 86400) % 86400;
         const string txt = open ? StringFormat("%-8s OPEN   +%s  ends in %s", g_names[k], Fmt(since), Fmt(left))
                                 : StringFormat("%-8s closed opens in %s", g_names[k], Fmt(left));
         color clr = open ? InpOpenColor : InpClosedColor;
         if(left < InpWarnMins * 60)
            clr = InpSoonColor;
         SetRow(row++, txt, clr);
        }
     }
   // clear any leftover rows (e.g. after weekend line replaced the session lines)
   for(int i = row; i < MAXROWS; i++)
      ObjectDelete(0, PREFIX + IntegerToString(i));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_forex = (InpMarket == MARKET_FOREX) || (InpMarket == MARKET_AUTO && !IsCryptoSymbol());
   if(g_forex)
     {
      AddSession("Sydney",   InpSydStart,  InpSydEnd);
      AddSession("Tokyo",    InpTokStart,  InpTokEnd);
      AddSession("London",   InpLonStart,  InpLonEnd);
      AddSession("New York", InpNyStart,   InpNyEnd);
     }
   else
     {
      AddSession("Asia",   InpAsiaStart, InpAsiaEnd);
      AddSession("Europe", InpEurStart,  InpEurEnd);
      AddSession("US",     InpUsStart,   InpUsEnd);
     }
   IndicatorSetString(INDICATOR_SHORTNAME, "Session Clock");
   IndicatorSetInteger(INDICATOR_HEIGHT, ArraySize(g_names) * (InpFontSize + 8) + InpY * 2);
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
