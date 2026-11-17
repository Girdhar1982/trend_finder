//+------------------------------------------------------------------+
//| Session_Boxes.mq5                                                |
//| Coloured high/low boxes for Sydney, Tokyo, London, New York.     |
//| Where two or more sessions overlap, ONE shared colour is used.   |
//| Hours are SERVER time (broker server = New York + 7h).           |
//+------------------------------------------------------------------+
#property copyright "Session Boxes"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input int   InpDays      = 5;               // Days to draw
input bool  InpSydney    = true;            // Show Sydney
input int   InpSydStart  = 0;               // Sydney start (server hour)
input int   InpSydEnd    = 9;               // Sydney end   (server hour)
input color InpSydColor  = clrMediumPurple; // Sydney colour
input bool  InpTokyo     = true;            // Show Tokyo
input int   InpTokStart  = 2;               // Tokyo start (server hour)
input int   InpTokEnd    = 11;              // Tokyo end   (server hour)
input color InpTokColor  = clrLightSeaGreen;// Tokyo colour
input bool  InpLondon    = true;            // Show London
input int   InpLonStart  = 10;              // London start (server hour)
input int   InpLonEnd    = 19;              // London end   (server hour)
input color InpLonColor  = clrDodgerBlue;   // London colour
input bool  InpNewYork   = true;            // Show New York
input int   InpNYStart   = 15;              // New York start (server hour)
input int   InpNYEnd     = 24;              // New York end   (server hour, 24 = midnight)
input color InpNYColor   = clrOrange;       // New York colour
input color InpOverlap   = clrGold;         // ONE colour for any overlap of 2+ sessions

const string PREFIX = "SESSBOX_";

//+------------------------------------------------------------------+
// minute-of-day t (0..1439) inside [s,e) hours; supports wrap past midnight
bool Active(const bool on, const int s, const int e, const int t)
  {
   if(!on)
      return false;
   const int a = s * 60, b = e * 60;
   if(a == b)
      return false;
   return a < b ? (t >= a && t < b) : (t >= a || t < b);
  }

//+------------------------------------------------------------------+
void Box(const string name, const datetime t0, const datetime t1, const color clr)
  {
   // high/low of chart bars inside [t0,t1)
   const int b0 = iBarShift(_Symbol, _Period, t0, false);
   const int b1 = iBarShift(_Symbol, _Period, t1 - 1, false);
   if(b0 < 0 || b1 < 0)
      return;
   const int cnt = b0 - b1 + 1;
   if(cnt <= 0)
      return;
   const int ih = iHighest(_Symbol, _Period, MODE_HIGH, cnt, b1);
   const int il = iLowest(_Symbol, _Period, MODE_LOW, cnt, b1);
   if(ih < 0 || il < 0)
      return;
   const double hi = iHigh(_Symbol, _Period, ih), lo = iLow(_Symbol, _Period, il);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, hi, t1, lo);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t0);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, hi);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, lo);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
void Draw()
  {
   if(_Period > PERIOD_H4)
     {
      ObjectsDeleteAll(0, PREFIX);
      return;
     }
   ObjectsDeleteAll(0, PREFIX);
   // breakpoints (minutes of day) where the set of active sessions can change
   int bp[];
   ArrayResize(bp, 0);
   const int pts[8] = {InpSydStart, InpSydEnd, InpTokStart, InpTokEnd, InpLonStart, InpLonEnd, InpNYStart, InpNYEnd};
   ArrayResize(bp, 10);
   int n = 0;
   bp[n++] = 0;
   for(int i = 0; i < 8; i++)
      bp[n++] = (pts[i] * 60) % 1440 == 0 && pts[i] >= 24 ? 0 : pts[i] * 60;
   bp[n++] = 1440;
   ArrayResize(bp, n);
   ArraySort(bp);

   const datetime now = TimeCurrent();
   const datetime today = now - now % 86400;
   for(int d = 0; d < InpDays; d++)
     {
      const datetime day = today - (datetime)d * 86400;
      for(int k = 0; k + 1 < n; k++)
        {
         if(bp[k] == bp[k + 1])
            continue;
         const datetime t0 = day + bp[k] * 60;
         datetime t1 = day + bp[k + 1] * 60;
         if(t0 > now)
            continue;
         if(t1 > now)
            t1 = now;
         const int m = bp[k];   // segment start decides who is active
         const bool s1 = Active(InpSydney, InpSydStart, InpSydEnd, m);
         const bool s2 = Active(InpTokyo,  InpTokStart, InpTokEnd, m);
         const bool s3 = Active(InpLondon, InpLonStart, InpLonEnd, m);
         const bool s4 = Active(InpNewYork, InpNYStart, InpNYEnd, m);
         const int cnt = (int)s1 + (int)s2 + (int)s3 + (int)s4;
         if(cnt == 0)
            continue;
         color clr = InpOverlap;
         if(cnt == 1)
            clr = s1 ? InpSydColor : s2 ? InpTokColor : s3 ? InpLonColor : InpNYColor;
         Box(PREFIX + IntegerToString(d) + "_" + IntegerToString(k), t0, t1, clr);
        }
     }
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
