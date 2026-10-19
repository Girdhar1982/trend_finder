//+------------------------------------------------------------------+
//| Volume_Profile_POC.mq5                                           |
//| Volume profile over the last N bars with the Point of Control    |
//| (POC) and the Value Area (VAH / VAL).                            |
//| Each bar's tick volume is spread evenly over the price bins its  |
//| high-low range touches. The histogram is drawn at the right edge |
//| of the profile range; the POC line extends to the right.         |
//+------------------------------------------------------------------+
#property copyright "Volume Profile POC"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input int   InpLookback    = 200;           // Bars in the profile
input int   InpBins        = 60;            // Price bins (rows)
input int   InpValueAreaPct = 70;           // Value area (% of volume)
input int   InpMaxWidthBars = 40;           // Histogram max width (bars)
input bool  InpShowValueArea = true;        // Show VAH / VAL lines
input bool  InpShowLabels  = true;          // Show POC / VAH / VAL labels
input color InpHistColor   = clrSteelBlue;  // Colour: histogram
input color InpVaColor     = clrCornflowerBlue; // Colour: value-area rows
input color InpPocColor    = clrOrangeRed;  // Colour: POC
input color InpVaLineColor = clrGoldenrod;  // Colour: VAH / VAL
input int   InpPocWidth    = 2;             // POC line width

const string PREFIX = "VPOC_";

//+------------------------------------------------------------------+
void ClearObjects()
  {
   ObjectsDeleteAll(0, PREFIX);
  }

//+------------------------------------------------------------------+
void DrawHLine(const string name, const datetime t1, const datetime t2, const double price,
               const color clr, const int width, const ENUM_LINE_STYLE style)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void DrawLabel(const string name, const datetime t, const double price, const string text, const color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void DrawBin(const string name, const datetime t1, const datetime t2, const double p1, const double p2,
             const color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void Build()
  {
   const int bins = MathMax(10, InpBins);
   const int n    = MathMin(InpLookback, Bars(_Symbol, _Period) - 1);
   if(n < 5)
      return;

   double hi[], lo[];
   long   vol[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(vol, true);
   // bar 0 is still forming, so start at shift 1 to keep the profile stable
   if(CopyHigh(_Symbol, _Period, 1, n, hi) != n ||
      CopyLow(_Symbol, _Period, 1, n, lo) != n ||
      CopyTickVolume(_Symbol, _Period, 1, n, vol) != n)
      return;

   double top = hi[0], bot = lo[0];
   for(int i = 1; i < n; i++)
     {
      top = MathMax(top, hi[i]);
      bot = MathMin(bot, lo[i]);
     }
   if(top <= bot)
      return;

   const double step = (top - bot) / bins;
   double hist[];
   ArrayResize(hist, bins);
   ArrayInitialize(hist, 0.0);

   for(int i = 0; i < n; i++)
     {
      int b1 = (int)MathFloor((lo[i] - bot) / step);
      int b2 = (int)MathFloor((hi[i] - bot) / step);
      b1 = MathMax(0, MathMin(bins - 1, b1));
      b2 = MathMax(0, MathMin(bins - 1, b2));
      const double share = (double)vol[i] / (b2 - b1 + 1);
      for(int b = b1; b <= b2; b++)
         hist[b] += share;
     }

   // POC = bin with the most volume
   int    poc = 0;
   double total = 0.0;
   for(int b = 0; b < bins; b++)
     {
      total += hist[b];
      if(hist[b] > hist[poc])
         poc = b;
     }
   if(total <= 0.0)
      return;

   // Value area: grow outward from the POC, adding the larger neighbour each time
   int    lowB = poc, highB = poc;
   double acc = hist[poc];
   const double target = total * InpValueAreaPct / 100.0;
   while(acc < target && (lowB > 0 || highB < bins - 1))
     {
      const double down = lowB > 0 ? hist[lowB - 1] : -1.0;
      const double up   = highB < bins - 1 ? hist[highB + 1] : -1.0;
      if(up >= down)
        {
         highB++;
         acc += hist[highB];
        }
      else
        {
         lowB--;
         acc += hist[lowB];
        }
     }

   // chart x-range: profile spans the sampled bars; histogram is anchored at the newest sampled bar
   datetime tNewest[1], tOldest[1];
   if(CopyTime(_Symbol, _Period, 1, 1, tNewest) != 1 || CopyTime(_Symbol, _Period, n, 1, tOldest) != 1)
      return;
   const int psec = PeriodSeconds();
   const datetime tRight = tNewest[0] + (datetime)(psec * (InpMaxWidthBars + 1));
   const datetime tLineEnd = tNewest[0] + (datetime)(psec * (InpMaxWidthBars + 15));

   // Histogram grows leftwards from the right edge, i.e. the longest row is InpMaxWidthBars long.
   // Anchor the histogram just right of the newest bar so it never covers the price action.
   const datetime tBase = tNewest[0] + (datetime)psec * 2;
   const double   maxV  = hist[poc];
   for(int b = 0; b < bins; b++)
     {
      if(hist[b] <= 0.0)
         continue;
      const int len = MathMax(1, (int)MathRound(InpMaxWidthBars * hist[b] / maxV));
      const double p1 = bot + b * step;
      const double p2 = p1 + step * 0.9;
      const bool inVa = (b >= lowB && b <= highB);
      DrawBin(PREFIX + "BIN_" + IntegerToString(b), tBase, tBase + (datetime)(psec * len), p1, p2,
              inVa ? InpVaColor : InpHistColor);
     }

   const double pocPrice = bot + (poc + 0.5) * step;
   const double vah = bot + (highB + 1) * step;
   const double val = bot + lowB * step;

   // POC runs across the whole profile range and past the histogram
   DrawHLine(PREFIX + "POC", tOldest[0], tLineEnd, pocPrice, InpPocColor, InpPocWidth, STYLE_SOLID);
   if(InpShowValueArea)
     {
      DrawHLine(PREFIX + "VAH", tOldest[0], tRight, vah, InpVaLineColor, 1, STYLE_DOT);
      DrawHLine(PREFIX + "VAL", tOldest[0], tRight, val, InpVaLineColor, 1, STYLE_DOT);
     }
   if(InpShowLabels)
     {
      const datetime tl = tLineEnd + (datetime)psec;
      DrawLabel(PREFIX + "POC_L", tl, pocPrice, "POC " + DoubleToString(pocPrice, _Digits), InpPocColor);
      if(InpShowValueArea)
        {
         DrawLabel(PREFIX + "VAH_L", tl, vah, "VAH " + DoubleToString(vah, _Digits), InpVaLineColor);
         DrawLabel(PREFIX + "VAL_L", tl, val, "VAL " + DoubleToString(val, _Digits), InpVaLineColor);
        }
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ClearObjects();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ClearObjects();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[],
                const double &close[], const long &tick_volume[], const long &volume[],
                const int &spread[])
  {
   // the profile only uses closed bars, so rebuild once per new bar
   static datetime lastBar = 0;
   if(prev_calculated == 0 || time[rates_total - 1] != lastBar)
     {
      lastBar = time[rates_total - 1];
      // bin count can shrink between runs; drop stale rows first
      ObjectsDeleteAll(0, PREFIX + "BIN_");
      Build();
      ChartRedraw();
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
