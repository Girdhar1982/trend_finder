//+------------------------------------------------------------------+
//| Prev_Day_HL.mq5                                                  |
//| Marks the previous completed daily candle's high and low on any  |
//| chart timeframe below D1, as lines extended to the right with a  |
//| price label.                                                     |
//+------------------------------------------------------------------+
#property copyright "Prev Day HL"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input color InpHighColor = clrDodgerBlue;  // Previous day high colour
input color InpLowColor  = clrOrangeRed;   // Previous day low colour
input ENUM_LINE_STYLE InpStyle = STYLE_SOLID; // Line style
input int   InpWidth     = 2;              // Line width
input bool  InpLabels    = true;           // Show price labels
input int   InpFontSize  = 9;              // Label font size
input bool  InpFromPrevOpen = true;        // Start line at previous day open (false = today's open)

const string PREFIX = "PDHL_";

//+------------------------------------------------------------------+
void Level(const string id, const double price, const datetime t0, const datetime tLabel,
           const color clr, const string title)
  {
   const string ln = PREFIX + id, tx = PREFIX + id + "_T";
   if(ObjectFind(0, ln) < 0)
     {
      ObjectCreate(0, ln, OBJ_TREND, 0, t0, price, t0 + 60, price);
      ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, ln, OBJPROP_BACK, true);
     }
   ObjectSetInteger(0, ln, OBJPROP_TIME,  0, t0);
   ObjectSetDouble(0,  ln, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME,  1, t0 + 60);
   ObjectSetDouble(0,  ln, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, ln, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, ln, OBJPROP_STYLE, InpStyle);
   ObjectSetInteger(0, ln, OBJPROP_WIDTH, InpWidth);

   if(!InpLabels)
     {
      ObjectDelete(0, tx);
      return;
     }
   if(ObjectFind(0, tx) < 0)
     {
      ObjectCreate(0, tx, OBJ_TEXT, 0, tLabel, price);
      ObjectSetInteger(0, tx, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, tx, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, tx, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, tx, OBJPROP_TIME, 0, tLabel);
   ObjectSetDouble(0,  tx, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, tx, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, tx, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetString(0,  tx, OBJPROP_TEXT, StringFormat(" %s %.*f", title, _Digits, price));
  }

//+------------------------------------------------------------------+
void Draw()
  {
   if(PeriodSeconds(_Period) >= PeriodSeconds(PERIOD_D1))
     {
      ObjectsDeleteAll(0, PREFIX);
      return;
     }
   const double hi = iHigh(_Symbol, PERIOD_D1, 1), lo = iLow(_Symbol, PERIOD_D1, 1);
   const datetime d1 = iTime(_Symbol, PERIOD_D1, 1), d0 = iTime(_Symbol, PERIOD_D1, 0);
   if(d1 == 0 || hi == 0)
      return;
   const datetime t0 = InpFromPrevOpen ? d1 : d0;
   const datetime tLabel = iTime(_Symbol, _Period, 0);   // label rides the latest bar
   Level("H", hi, t0, tLabel, InpHighColor, "PDH");
   Level("L", lo, t0, tLabel, InpLowColor,  "PDL");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
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
