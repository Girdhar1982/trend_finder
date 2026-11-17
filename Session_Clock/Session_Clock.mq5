//+------------------------------------------------------------------+
//| Session_Clock.mq5                                                |
//| Shows which trading sessions are open and the time left until    |
//| each one closes (or opens), in its own pane below the chart.     |
//| Forex : Sydney, Tokyo, London, New York (Mon-Fri only)           |
//| Crypto: Asia, Europe, US (24/7)                                  |
//| All session hours are UTC and editable; times use TimeGMT().     |
//| Also draws a coloured high/low box per session on the main chart;|
//| overlaps of 2+ sessions share one colour. Legend = clock rows.   |
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

input group "Chart boxes"
input bool  InpBoxes    = true;             // Draw session boxes on the chart
input int   InpDays     = 5;                // Days of boxes to draw
input color InpSydColor = clrMediumPurple;  // Sydney colour  (crypto: Asia)
input color InpTokColor = clrLightSeaGreen; // Tokyo colour   (crypto: Europe)
input color InpLonColor = clrDodgerBlue;    // London colour  (crypto: US)
input color InpNyColor  = clrOrange;        // New York colour
input color InpOvSydTok = clrGold;          // Overlap colour: Sydney + Tokyo
input color InpOvTokLon = clrLimeGreen;     // Overlap colour: Tokyo + London
input color InpOvLonNy  = clrRed;           // Overlap colour: London + New York

input group "Forex sessions (UTC hours)"
input int InpSydStart = 21; input int InpSydEnd = 6;
input int InpTokStart = 0;  input int InpTokEnd = 9;
input int InpLonStart = 7;  input int InpLonEnd = 16;
input int InpNyStart  = 12; input int InpNyEnd  = 21;
input group "Crypto sessions (UTC hours)"
input int InpAsiaStart = 0;  input int InpAsiaEnd = 8;
input int InpEurStart  = 7;  input int InpEurEnd  = 16;
input int InpUsStart   = 13; input int InpUsEnd   = 22;

const string PREFIX = "SESCLKP_";
const string BOXP   = "SESCLKB_"; // differs from the old chart-window version so the two never share objects
const int    MAXROWS = 8;

string g_names[];
int    g_start[];
int    g_end[];
color  g_clr[];
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
void AddSession(const string n, const int s, const int e, const color c)
  {
   const int k = ArraySize(g_names);
   ArrayResize(g_names, k + 1);
   ArrayResize(g_start, k + 1);
   ArrayResize(g_end,   k + 1);
   ArrayResize(g_clr,   k + 1);
   g_names[k] = n;
   g_start[k] = s;
   g_end[k]   = e;
   g_clr[k]   = c;
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
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpX + 20);
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
void Swatch(const string name, const int row, const color clr, const string text)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, g_subWin, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpX);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetString(0,  name, OBJPROP_FONT,       InpFont);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpY + row * (InpFontSize + 8));
   ObjectSetString(0,  name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
// One colour per neighbouring-session overlap (bit k = session k active)
color OverlapColor(const int mask)
  {
   if((mask & 12) == 12)
      return InpOvLonNy;    // London + New York
   if((mask & 6) == 6)
      return InpOvTokLon;   // Tokyo + London
   return InpOvSydTok;      // Sydney + Tokyo (and any other overlap)
  }

//+------------------------------------------------------------------+
bool ActiveAt(const int k, const int minute)
  {
   const int a = g_start[k] * 60, b = g_end[k] * 60;
   if(a == b)
      return false;
   return a < b ? (minute >= a && minute < b) : (minute >= a || minute < b);
  }

//+------------------------------------------------------------------+
void Box(const string name, const datetime t0, const datetime t1, const color clr)
  {
   const int b0 = iBarShift(_Symbol, _Period, t0, false);
   const int b1 = iBarShift(_Symbol, _Period, t1 - 1, false);
   if(b0 < 0 || b1 < 0 || b0 < b1)
      return;
   const int cnt = b0 - b1 + 1;
   const int ih = iHighest(_Symbol, _Period, MODE_HIGH, cnt, b1);
   const int il = iLowest(_Symbol, _Period, MODE_LOW, cnt, b1);
   if(ih < 0 || il < 0)
      return;
   const double hi = iHigh(_Symbol, _Period, ih), lo = iLow(_Symbol, _Period, il);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, hi, t1, lo);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
// Session boxes on the main chart (window 0). Hours are UTC; shifted to server time for placement.
void DrawBoxes()
  {
   ObjectsDeleteAll(0, BOXP);
   if(!InpBoxes || _Period > PERIOD_H4)
      return;
   const datetime nowUtc = TimeGMT();
   const long off = (long)MathRound((double)(TimeCurrent() - nowUtc) / 3600.0) * 3600L;
   int bp[];
   ArrayResize(bp, 2 + 2 * ArraySize(g_names));
   int n = 0;
   bp[n++] = 0;
   bp[n++] = 1440;
   for(int k = 0; k < ArraySize(g_names); k++)
     {
      bp[n++] = (g_start[k] * 60) % 1440;
      bp[n++] = (g_end[k] * 60) % 1440;
     }
   ArraySort(bp);
   const datetime today = nowUtc - nowUtc % 86400;
   for(int d = 0; d < InpDays; d++)
     {
      const datetime day = today - (datetime)d * 86400;
      for(int i = 0; i + 1 < n; i++)
        {
         if(bp[i] == bp[i + 1])
            continue;
         const datetime u0 = day + bp[i] * 60;
         datetime u1 = day + bp[i + 1] * 60;
         if(u0 > nowUtc || (g_forex && ForexWeekend(u0)))
            continue;
         if(u1 > nowUtc)
            u1 = nowUtc;
         int cnt = 0, which = -1, i0Mask = 0;
         for(int k = 0; k < ArraySize(g_names); k++)
            if(ActiveAt(k, bp[i]))
              { cnt++; which = k; i0Mask |= (1 << k); }
         if(cnt == 0)
            continue;
         Box(BOXP + IntegerToString(d) + "_" + IntegerToString(i), (datetime)(u0 + off), (datetime)(u1 + off),
             cnt == 1 ? g_clr[which] : OverlapColor(i0Mask));
        }
     }
   ChartRedraw();
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
         Swatch(PREFIX + "SW" + IntegerToString(k), row, g_clr[k], "■");
         SetRow(row++, txt, clr);
        }
     }
   // legend row for the shared overlap colour
   const int ns = ArraySize(g_names);
   Swatch(PREFIX + "SWO0", ns,     InpOvSydTok, "■ overlap: " + g_names[0] + " + " + g_names[1]);
   Swatch(PREFIX + "SWO1", ns + 1, InpOvTokLon, "■ overlap: " + g_names[1] + " + " + g_names[2]);
   if(ns > 3)
      Swatch(PREFIX + "SWO2", ns + 2, InpOvLonNy, "■ overlap: " + g_names[2] + " + " + g_names[3]);
   // clear any leftover rows (e.g. after weekend line replaced the session lines)
   for(int i = row; i < MAXROWS; i++)
      ObjectDelete(0, PREFIX + IntegerToString(i));
   if(row == 1 && g_forex && ForexWeekend(utc))
      for(int k = 0; k < ArraySize(g_names); k++)
         ObjectDelete(0, PREFIX + "SW" + IntegerToString(k));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_forex = (InpMarket == MARKET_FOREX) || (InpMarket == MARKET_AUTO && !IsCryptoSymbol());
   if(g_forex)
     {
      AddSession("Sydney",   InpSydStart,  InpSydEnd, InpSydColor);
      AddSession("Tokyo",    InpTokStart,  InpTokEnd, InpTokColor);
      AddSession("London",   InpLonStart,  InpLonEnd, InpLonColor);
      AddSession("New York", InpNyStart,   InpNyEnd, InpNyColor);
     }
   else
     {
      AddSession("Asia",   InpAsiaStart, InpAsiaEnd, InpSydColor);
      AddSession("Europe", InpEurStart,  InpEurEnd, InpTokColor);
      AddSession("US",     InpUsStart,   InpUsEnd, InpLonColor);
     }
   IndicatorSetString(INDICATOR_SHORTNAME, "Session Clock");
   IndicatorSetInteger(INDICATOR_HEIGHT, (2 * ArraySize(g_names)) * (InpFontSize + 8) + InpY * 2);
   EventSetTimer(1);
   Refresh();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ObjectsDeleteAll(0, BOXP);
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
   static datetime last = 0;
   if(TimeLocal() != last)   // at most once a second
     {
      last = TimeLocal();
      DrawBoxes();
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
