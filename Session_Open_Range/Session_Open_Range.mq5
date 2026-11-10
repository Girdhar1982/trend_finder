//+------------------------------------------------------------------+
//| Session_Open_Range.mq5                                           |
//| Marks the high and low of the first 15 minutes (editable) of     |
//| each new trading session - Sydney, Tokyo, London, New York - as  |
//| a box plus high/low lines extended for a set time, with labels.  |
//| Session start times are UTC; the broker server clock is NY+7h    |
//| (UTC+3 in US summer, UTC+2 in US winter), converted internally.  |
//| The range is measured on M1 bars so it works on any timeframe.   |
//+------------------------------------------------------------------+
#property copyright "Session Open Range"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

enum ENUM_LABEL_POS { LABEL_LEFT, LABEL_RIGHT };

input int    InpRangeMins   = 15;            // Opening range length (minutes)
input int    InpExtendMins  = 120;           // Extend high/low lines after the range (minutes)
input int    InpDays        = 2;             // Days of history to draw (today = 1)
input bool   InpBox         = true;          // Draw outline box around the opening range
input bool   InpFill        = false;         // Fill the box (hides less when off)
input bool   InpLabels      = true;          // Show high/low labels
input ENUM_LABEL_POS InpLabelPos = LABEL_LEFT; // Label position (left of box / end of line)
input int    InpFontSize    = 8;             // Label font size
input int    InpWidth       = 1;             // Line width

input group "Sydney"
input bool   InpSydOn   = true;              // Enabled
input int    InpSydHour = 21;                // Start hour (UTC)
input int    InpSydMin  = 0;                 // Start minute
input color  InpSydClr  = clrMediumOrchid;   // Colour
input group "Tokyo"
input bool   InpTokOn   = true;              // Enabled
input int    InpTokHour = 0;                 // Start hour (UTC)
input int    InpTokMin  = 0;                 // Start minute
input color  InpTokClr  = clrDeepPink;       // Colour
input group "London"
input bool   InpLonOn   = true;              // Enabled
input int    InpLonHour = 7;                 // Start hour (UTC)
input int    InpLonMin  = 0;                 // Start minute
input color  InpLonClr  = clrDodgerBlue;     // Colour
input group "New York"
input bool   InpNyOn    = true;              // Enabled
input int    InpNyHour  = 12;                // Start hour (UTC)
input int    InpNyMin   = 0;                 // Start minute
input color  InpNyClr   = clrOrange;         // Colour

const string PREFIX = "SOR_";

string g_name[4];
bool   g_on[4];
int    g_hour[4];
int    g_min[4];
color  g_clr[4];

//+------------------------------------------------------------------+
//| n-th Sunday (1-based) of a month, 00:00                          |
//+------------------------------------------------------------------+
datetime NthSunday(const int year, const int month, const int n)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year;
   t.mon  = month;
   t.day  = 1;
   const datetime first = StructToTime(t);
   TimeToStruct(first, t);
   const int firstSun = 1 + (7 - t.day_of_week) % 7;
   return first + (datetime)((firstSun - 1 + (n - 1) * 7) * 86400);
  }

//+------------------------------------------------------------------+
//| US DST: 2nd Sun March 07:00 UTC to 1st Sun Nov 06:00 UTC         |
//+------------------------------------------------------------------+
bool IsUsDst(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc, t);
   const datetime from = NthSunday(t.year, 3, 2) + 7 * 3600;
   const datetime to   = NthSunday(t.year, 11, 1) + 6 * 3600;
   return utc >= from && utc < to;
  }

//+------------------------------------------------------------------+
void Put(const string name, const ENUM_OBJECT type, const datetime t0, const double p0,
         const datetime t1, const double p1, const color clr, const bool exists)
  {
   if(!exists)
     {
      ObjectCreate(0, name, type, 0, t0, p0, t1, p1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t0);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, p0);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, p1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
void Label(const string name, const datetime t, const double price, const color clr,
           const string text, const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetString(0,  name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| Draw one session opening range starting at server time 'start'   |
//+------------------------------------------------------------------+
void DrawRange(const int s, const datetime start)
  {
   const datetime now = TimeCurrent();
   if(start > now)
      return;
   const datetime rangeEnd = start + InpRangeMins * 60;
   const string id = PREFIX + g_name[s] + "_" + IntegerToString((long)start);

   // a finished range never changes - leave it alone once drawn
   if(now >= rangeEnd && ObjectFind(0, id + "_H") >= 0)
      return;

   MqlRates r[];
   if(CopyRates(_Symbol, PERIOD_M1, start, rangeEnd - 1, r) <= 0)
      return;
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < ArraySize(r); i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }

   const datetime lineEnd = rangeEnd + InpExtendMins * 60;
   const color clr = g_clr[s];

   Put(id + "_H", OBJ_TREND, start, hi, lineEnd, hi, clr, ObjectFind(0, id + "_H") >= 0);
   Put(id + "_L", OBJ_TREND, start, lo, lineEnd, lo, clr, ObjectFind(0, id + "_L") >= 0);
   ObjectSetInteger(0, id + "_H", OBJPROP_WIDTH, InpWidth);
   ObjectSetInteger(0, id + "_L", OBJPROP_WIDTH, InpWidth);

   if(InpBox)
     {
      Put(id + "_B", OBJ_RECTANGLE, start, hi, rangeEnd, lo, clr, ObjectFind(0, id + "_B") >= 0);
      ObjectSetInteger(0, id + "_B", OBJPROP_FILL, InpFill);
     }
   if(InpLabels)
     {
      const bool left = (InpLabelPos == LABEL_LEFT);
      const datetime lt = left ? start : lineEnd;
      Label(id + "_HT", lt, hi, clr, StringFormat(left ? "%s H %.*f " : " %s H %.*f", g_name[s], _Digits, hi),
            left ? ANCHOR_RIGHT_LOWER : ANCHOR_LEFT_LOWER);
      Label(id + "_LT", lt, lo, clr, StringFormat(left ? "%s L %.*f " : " %s L %.*f", g_name[s], _Digits, lo),
            left ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
     }
  }

//+------------------------------------------------------------------+
//| Remove objects older than the history window                     |
//+------------------------------------------------------------------+
void Cleanup(const datetime oldest)
  {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
     {
      const string n = ObjectName(0, i);
      if(StringFind(n, PREFIX) != 0)
         continue;
      const int a = StringFind(n, "_", StringLen(PREFIX));
      const int b = StringFind(n, "_", a + 1);
      if(a < 0 || b < 0)
         continue;
      if((datetime)StringToInteger(StringSubstr(n, a + 1, b - a - 1)) < oldest)
         ObjectDelete(0, n);
     }
  }

//+------------------------------------------------------------------+
void Draw()
  {
   const datetime utcNow = TimeGMT();
   const datetime utcDay = utcNow - utcNow % 86400;
   datetime oldest = TimeCurrent();

   for(int s = 0; s < 4; s++)
     {
      if(!g_on[s])
         continue;
      for(int d = 0; d < InpDays; d++)
        {
         const datetime startUtc = utcDay - d * 86400 + g_hour[s] * 3600 + g_min[s] * 60;
         const datetime start = startUtc + (IsUsDst(startUtc) ? 3 : 2) * 3600;
         MqlDateTime t;
         TimeToStruct(start, t);
         if(t.day_of_week == 0 || t.day_of_week == 6)   // server Sat/Sun = market closed
            continue;
         oldest = MathMin(oldest, start);
         DrawRange(s, start);
        }
     }
   Cleanup(oldest - 3600);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_name[0] = "SYD";    g_on[0] = InpSydOn; g_hour[0] = InpSydHour; g_min[0] = InpSydMin; g_clr[0] = InpSydClr;
   g_name[1] = "TKY";    g_on[1] = InpTokOn; g_hour[1] = InpTokHour; g_min[1] = InpTokMin; g_clr[1] = InpTokClr;
   g_name[2] = "LDN";    g_on[2] = InpLonOn; g_hour[2] = InpLonHour; g_min[2] = InpLonMin; g_clr[2] = InpLonClr;
   g_name[3] = "NY";     g_on[3] = InpNyOn;  g_hour[3] = InpNyHour;  g_min[3] = InpNyMin;  g_clr[3] = InpNyClr;
   ObjectsDeleteAll(0, PREFIX);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[],
                const double &close[], const long &tick_volume[], const long &volume[],
                const int &spread[])
  {
   Draw();
   return rates_total;
  }
//+------------------------------------------------------------------+
