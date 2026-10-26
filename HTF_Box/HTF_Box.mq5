//+------------------------------------------------------------------+
//| HTF_Box.mq5                                                      |
//| Draws a box around the higher-timeframe candle:                  |
//|   M1  chart -> M5  candle box                                    |
//|   M5  chart -> M15 candle box                                    |
//|   M15 chart -> H1  candle box                                    |
//|   H1  chart -> H4  candle box                                    |
//|   H4  chart -> D1  candle box                                    |
//| Any other timeframe draws nothing.                               |
//|                                                                  |
//| Decision aids: 50% midline, previous-box high/low levels,        |
//| trend/structure read-out and breakout alerts.                    |
//+------------------------------------------------------------------+
#property copyright "HTF Box"
#property version   "2.00"
#property indicator_chart_window
#property indicator_plots 0

input int   InpCount      = 1;             // Number of HTF candles to box (1 = current only)
input color InpBullColor  = clrDodgerBlue; // Box colour when HTF candle is bullish
input color InpBearColor  = clrOrangeRed;  // Box colour when HTF candle is bearish
input bool  InpFill       = false;         // Fill box
input int   InpWidth      = 2;             // Border width
input bool  InpMidline    = true;          // Draw 50% midline in each box
input bool  InpPrevLevels = true;          // Extend previous HTF candle high/low to the right
input bool  InpInfo       = true;          // Show trend / structure read-out
input bool  InpStartMin   = false;         // Start with the read-out minimized (verdict line only)
input ENUM_BASE_CORNER InpCorner = CORNER_LEFT_UPPER; // Read-out corner
input int   InpFontSize   = 10;            // Read-out font size
input color InpPanelColor = C'18,22,32';   // Read-out panel background
input int   InpRoomPct    = 60;            // Range below this % of average = "room to expand"
input int   InpExhaustPct = 100;           // Range at/above this % of average = "exhausted"
input bool  InpAlertCounter = false;      // Also alert on breaks against the higher-timeframe trend
input bool  InpAlerts    = true;          // Alert when price breaks previous HTF high/low
input bool  InpPush       = false;         // Also send push notification

const string PREFIX = "HTFBOX_";

datetime g_alertBar = 0;   // HTF bar already alerted
bool     g_primed   = false; // first evaluation after attach never alerts
bool     g_min      = InpStartMin; // read-out minimized to the verdict line

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES BoxTF()
  {
   switch(_Period)
     {
      case PERIOD_M1:  return PERIOD_M5;
      case PERIOD_M5:  return PERIOD_M15;
      case PERIOD_M15: return PERIOD_H1;
      case PERIOD_H1:  return PERIOD_H4;
      case PERIOD_H4:  return PERIOD_D1;
     }
   return PERIOD_CURRENT;   // unsupported -> no box
  }

//+------------------------------------------------------------------+
// One step above the box timeframe, used as trend context
ENUM_TIMEFRAMES ContextTF(const ENUM_TIMEFRAMES box)
  {
   switch(box)
     {
      case PERIOD_M5:  return PERIOD_M15;
      case PERIOD_M15: return PERIOD_H1;
      case PERIOD_H1:  return PERIOD_H4;
      case PERIOD_H4:  return PERIOD_D1;
      case PERIOD_D1:  return PERIOD_W1;
     }
   return PERIOD_CURRENT;
  }

//+------------------------------------------------------------------+
string FmtLeft(const long secs)
  {
   const long s = secs < 0 ? 0 : secs;
   if(s >= 3600)
      return StringFormat("%dh%02dm", (int)(s / 3600), (int)((s % 3600) / 60));
   return StringFormat("%dm%02ds", (int)(s / 60), (int)(s % 60));
  }

//+------------------------------------------------------------------+
string TFName(const ENUM_TIMEFRAMES tf)
  {
   return StringSubstr(EnumToString(tf), 7);
  }

//+------------------------------------------------------------------+
void Clear()
  {
   ObjectsDeleteAll(0, PREFIX);
  }

//+------------------------------------------------------------------+
void Rect(const string name, const datetime t0, const double p0, const datetime t1, const double p1,
          const color clr, const bool fill, const int width)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, p0, t1, p1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t0);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, p0);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, p1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,  fill);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
  }

//+------------------------------------------------------------------+
void Trend(const string name, const datetime t0, const double p0, const datetime t1, const double p1,
           const color clr, const ENUM_LINE_STYLE style, const bool ray)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t0, p0, t1, p1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t0);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, p0);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, p1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, ray);
  }

//+------------------------------------------------------------------+
// Structure of candle a vs candle b (a is newer): returns text, sets dir (+1/-1/0)
string Structure(const double hiA, const double loA, const double hiB, const double loB, int &dir)
  {
   dir = 0;
   if(hiA <= hiB && loA >= loB)
      return "Inside (compression)";
   if(hiA > hiB && loA < loB)
      return "Outside (expansion)";
   if(hiA > hiB && loA >= loB)
     { dir = 1;  return "HH+HL  Bullish"; }
   if(hiA <= hiB && loA < loB)
     { dir = -1; return "LH+LL  Bearish"; }
   return "Mixed";
  }

//+------------------------------------------------------------------+
// Solid background so the read-out stays legible over candles. Must be created before the labels.
void Panel()
  {
   const string name = PREFIX + "PANEL";
   const bool right = (InpCorner == CORNER_RIGHT_UPPER || InpCorner == CORNER_RIGHT_LOWER);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, right ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 12);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, (int)(72 * InpFontSize * 0.9));
   ObjectSetInteger(0, name, OBJPROP_YSIZE, (g_min ? 1 : 6) * (InpFontSize + 6) + 16);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, InpPanelColor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);

   // Minimize / restore button in the panel's top outer corner; created after the panel so it sits on top
   const string btn = PREFIX + "BTN";
   const int w = (int)(72 * InpFontSize * 0.9);
   if(ObjectFind(0, btn) < 0)
     {
      ObjectCreate(0, btn, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, btn, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, btn, OBJPROP_HIDDEN, true);
      ObjectSetString(0,  btn, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, btn, OBJPROP_BGCOLOR, clrDimGray);
      ObjectSetInteger(0, btn, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, btn, OBJPROP_BORDER_COLOR, clrDimGray);
     }
   ObjectSetInteger(0, btn, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, btn, OBJPROP_ANCHOR, right ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, btn, OBJPROP_XDISTANCE, right ? 9 : 5 + w - 22);
   ObjectSetInteger(0, btn, OBJPROP_YDISTANCE, 16);
   ObjectSetInteger(0, btn, OBJPROP_XSIZE, 18);
   ObjectSetInteger(0, btn, OBJPROP_YSIZE, 18);
   ObjectSetInteger(0, btn, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0,  btn, OBJPROP_TEXT, g_min ? "+" : "-");
   ObjectSetInteger(0, btn, OBJPROP_STATE, false);
  }

//+------------------------------------------------------------------+
void Label(const string name, int row, const string text, const color clr)
  {
   if(g_min)   // minimized: keep only the verdict line, on the first row
     {
      if(name != PREFIX + "I4")
        {
         ObjectDelete(0, name);
         return;
        }
      row = 0;
     }
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,
                       (InpCorner == CORNER_RIGHT_UPPER || InpCorner == CORNER_RIGHT_LOWER) ?
                       ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0,  name, OBJPROP_FONT, "Consolas");
     }
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 18 + row * (InpFontSize + 6));
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0,  name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
color DirColor(const int dir)
  {
   return dir > 0 ? InpBullColor : (dir < 0 ? InpBearColor : clrSilver);
  }

//+------------------------------------------------------------------+
void Info(const ENUM_TIMEFRAMES tf)
  {
   const double h0 = iHigh(_Symbol, tf, 0), l0 = iLow(_Symbol, tf, 0);
   const double h1 = iHigh(_Symbol, tf, 1), l1 = iLow(_Symbol, tf, 1);
   const double h2 = iHigh(_Symbol, tf, 2), l2 = iLow(_Symbol, tf, 2);
   if(h2 == 0 || h1 == 0 || h0 == 0)
      return;
   const string tn = TFName(tf);
   Panel();

   // Bias from the last two COMPLETED candles - stable, does not repaint
   int dirC;
   const string sC = Structure(h1, l1, h2, l2, dirC);
   Label(PREFIX + "I0", 0, StringFormat("%s bias (closed): %s", tn, sC), DirColor(dirC));

   // Live candle vs the last completed one
   int dirL;
   const string sL = Structure(h0, l0, h1, l1, dirL);
   Label(PREFIX + "I1", 1, StringFormat("%s now: %s", tn, sL), DirColor(dirL));

   // Where is price inside the live box, and has it escaped the previous box?
   const double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double rng = h0 - l0;
   const double pos = rng > 0 ? (px - l0) / rng * 100.0 : 50.0;
   string where = pos >= 50.0 ? "premium" : "discount";
   int dirP = 0;
   if(px > h1)
     { where += " | ABOVE prev high"; dirP = 1; }
   else
      if(px < l1)
        { where += " | BELOW prev low"; dirP = -1; }
      else
         where += " | inside prev range";
   Label(PREFIX + "I2", 2, StringFormat("Price at %.0f%% of %s range (%s)", pos, tn, where),
         dirP != 0 ? DirColor(dirP) : clrSilver);

   // Volatility: live box range vs the average of the last 10 completed boxes, plus time left
   double sum = 0;
   int cnt = 0;
   for(int k = 1; k <= 10; k++)
     {
      const double r = iHigh(_Symbol, tf, k) - iLow(_Symbol, tf, k);
      if(r > 0)
        { sum += r; cnt++; }
     }
   const double avg = cnt > 0 ? sum / cnt : 0;
   const double ratio = avg > 0 ? rng / avg : 0;
   const long left = (long)(iTime(_Symbol, tf, 0) + PeriodSeconds(tf) - TimeCurrent());
   string vol = ratio >= InpExhaustPct / 100.0 ? "range exhausted - breakout may be stretched" :
                ratio >= InpRoomPct / 100.0 ? "normal" : "room to expand";
   Label(PREFIX + "I5", 5, StringFormat("Range %.0f%% of avg (%s) | %s left in %s candle",
                                        ratio * 100.0, vol, FmtLeft(left), tn), clrSilver);

   // Context: closed-candle bias one timeframe above the box timeframe
   int dirX = 0;
   const ENUM_TIMEFRAMES cx = ContextTF(tf);
   if(cx != PERIOD_CURRENT)
     {
      const string sX = Structure(iHigh(_Symbol, cx, 1), iLow(_Symbol, cx, 1),
                                  iHigh(_Symbol, cx, 2), iLow(_Symbol, cx, 2), dirX);
      Label(PREFIX + "I3", 3, StringFormat("%s context (closed): %s", TFName(cx), sX), DirColor(dirX));
     }

   // Agreement of closed bias + live structure + breakout, filtered by the higher context
   const int score = dirC + dirL + dirP;
   int v = 0;
   if(score >= 2)
      v = 1;
   else
      if(score <= -2)
         v = -1;
   string verdict = "Mixed / range - wait";
   if(v != 0)
     {
      verdict = v > 0 ? "BULLISH confluence" : "BEARISH confluence";
      if(dirX == v)
         verdict += " + " + TFName(cx) + " agrees (strong)";
      else
         if(dirX == -v)
            verdict += " but AGAINST " + TFName(cx) + " (counter-trend, caution)";
         else
            verdict += " (" + TFName(cx) + " neutral)";
     }
   Label(PREFIX + "I4", 4, "Verdict: " + verdict, DirColor(v));
  }

//+------------------------------------------------------------------+
void CheckAlert(const ENUM_TIMEFRAMES tf)
  {
   const datetime bar = iTime(_Symbol, tf, 0);
   const double h1 = iHigh(_Symbol, tf, 1), l1 = iLow(_Symbol, tf, 1);
   if(bar == 0 || h1 == 0)
      return;
   // Confirmed break only: the last CLOSED chart-timeframe candle must close beyond the level
   const double c = iClose(_Symbol, _Period, 1);
   int dir = 0;
   if(c > h1)
      dir = 1;
   else
      if(c < l1)
         dir = -1;
   if(!g_primed)   // first evaluation after attach: record state, never alert
     {
      g_primed = true;
      if(dir != 0)
         g_alertBar = bar;
      return;
     }
   if(dir == 0)
      return;
   // Trend filter: stay silent for breaks against the higher-timeframe context
   if(!InpAlertCounter)
     {
      const ENUM_TIMEFRAMES cx = ContextTF(tf);
      int dirX = 0;
      if(cx != PERIOD_CURRENT)
         Structure(iHigh(_Symbol, cx, 1), iLow(_Symbol, cx, 1), iHigh(_Symbol, cx, 2), iLow(_Symbol, cx, 2), dirX);
      if(dirX == -dir)
         return;
     }
   // At most one alert per HTF candle
   if(bar == g_alertBar)
      return;
   g_alertBar = bar;
   const string msg = StringFormat("%s: %s closed %s previous %s %s (%.*f)", _Symbol, TFName(_Period),
                                   dir > 0 ? "above" : "below", TFName(tf), dir > 0 ? "HIGH" : "LOW", _Digits, c);
   Alert(msg);
   if(InpPush)
      SendNotification(msg);
  }

//+------------------------------------------------------------------+
void Draw()
  {
   const ENUM_TIMEFRAMES tf = BoxTF();
   if(tf == PERIOD_CURRENT)
     {
      Clear();
      return;
     }
   const int n = MathMax(1, InpCount);
   const int secs = PeriodSeconds(tf);
   for(int i = 0; i < n; i++)
     {
      const datetime t0 = iTime(_Symbol, tf, i);
      if(t0 == 0)
         break;
      const double hi = iHigh(_Symbol, tf, i), lo = iLow(_Symbol, tf, i);
      const bool bull = iClose(_Symbol, tf, i) >= iOpen(_Symbol, tf, i);
      const color clr = bull ? InpBullColor : InpBearColor;
      const string id = IntegerToString(i);
      Rect(PREFIX + id, t0, hi, t0 + secs, lo, clr, InpFill, InpWidth);
      if(InpMidline)
         Trend(PREFIX + "M" + id, t0, (hi + lo) / 2, t0 + secs, (hi + lo) / 2, clr, STYLE_DOT, false);
     }
   // remove boxes left over from a larger InpCount
   for(int i = n; ObjectFind(0, PREFIX + IntegerToString(i)) >= 0; i++)
     {
      ObjectDelete(0, PREFIX + IntegerToString(i));
      ObjectDelete(0, PREFIX + "M" + IntegerToString(i));
     }

   // Previous completed HTF candle high/low, extended to the right as key levels
   if(InpPrevLevels)
     {
      const datetime t1 = iTime(_Symbol, tf, 1);
      if(t1 != 0)
        {
         Trend(PREFIX + "PH", t1, iHigh(_Symbol, tf, 1), t1 + secs, iHigh(_Symbol, tf, 1), clrSilver, STYLE_DASH, true);
         Trend(PREFIX + "PL", t1, iLow(_Symbol, tf, 1),  t1 + secs, iLow(_Symbol, tf, 1),  clrSilver, STYLE_DASH, true);
        }
     }
   else
     {
      ObjectDelete(0, PREFIX + "PH");
      ObjectDelete(0, PREFIX + "PL");
     }

   if(InpInfo)
      Info(tf);
   if(InpAlerts)
      CheckAlert(tf);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   Clear();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Clear();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == PREFIX + "BTN")
     {
      g_min = !g_min;
      Draw();
     }
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
