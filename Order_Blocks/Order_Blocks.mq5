//+------------------------------------------------------------------+
//| Order_Blocks.mq5                                                 |
//| Draws bullish / bearish order block zones. Tuned for M15.        |
//|                                                                  |
//| Bullish OB: last bearish candle before an impulsive up-candle    |
//|             that closes above the recent swing high (BOS).       |
//| Bearish OB: last bullish candle before an impulsive down-candle  |
//|             that closes below the recent swing low (BOS).        |
//| A zone extends to the right until a candle closes through it     |
//| (mitigated). Evaluated on closed bars only - no repainting.      |
//+------------------------------------------------------------------+
#property copyright "Order Blocks"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input int   InpAtrPeriod   = 14;            // ATR period
input double InpImpulse    = 1.2;           // Impulse candle body >= this x ATR
input int   InpStructBars  = 10;            // Structure lookback (bars) the impulse must break
input int   InpMaxBack     = 6;             // Max bars back to search for the OB candle
input int   InpHistory     = 1000;          // Bars of history to scan
input int   InpMaxZones    = 4;             // Max zones shown per side
input bool  InpBodyOnly    = false;         // Zone = candle body only (else full high-low)
input bool  InpShowMitigated = false;       // Keep mitigated zones (ended at mitigation bar)
input int   InpExtendBars  = 8;             // Project active zones this many bars past now
input color InpBullColor   = clrDodgerBlue; // Bullish OB colour
input color InpBearColor   = clrOrangeRed;  // Bearish OB colour
input bool  InpFill        = true;          // Fill zones

const string PREFIX = "OB_";
datetime g_lastBar = 0;

double TrueRange(const double &h[], const double &l[], const double &c[], int i)
  {
   return MathMax(h[i] - l[i], MathMax(MathAbs(h[i] - c[i - 1]), MathAbs(l[i] - c[i - 1])));
  }

double Atr(const double &h[], const double &l[], const double &c[], int i)
  {
   double s = 0;
   for(int k = 0; k < InpAtrPeriod; k++)
      s += TrueRange(h, l, c, i - k);
   return s / InpAtrPeriod;
  }

void DrawZone(const string name, datetime t1, datetime t2, double top, double bottom, color clr)
  {
   if(ObjectFind(0, name) >= 0)
      return;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, top, t2, bottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, InpFill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

int OnInit()
  {
   IndicatorSetString(INDICATOR_SHORTNAME, "Order Blocks");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[],
                const double &close[], const long &tick_volume[], const long &volume[],
                const int &spread[])
  {
   int minBars = MathMax(InpAtrPeriod, InpStructBars) + InpMaxBack + 2;
   if(rates_total < minBars)
      return 0;
   if(time[rates_total - 1] == g_lastBar && prev_calculated > 0)
      return rates_total;   // rebuild once per new bar
   g_lastBar = time[rates_total - 1];

   ObjectsDeleteAll(0, PREFIX);

   int last  = rates_total - 2;                       // last closed bar
   int first = MathMax(minBars, rates_total - InpHistory);
   datetime endActive = time[rates_total - 1] + (datetime)(PeriodSeconds() * InpExtendBars);
   int nBull = 0, nBear = 0;

   for(int i = last; i >= first && (nBull < InpMaxZones || nBear < InpMaxZones); i--)
     {
      double body = close[i] - open[i];
      double atr  = Atr(high, low, close, i);
      if(atr <= 0 || MathAbs(body) < InpImpulse * atr)
         continue;

      if(body > 0 && nBull < InpMaxZones)
        {
         double hh = high[i - 1];
         for(int k = 2; k <= InpStructBars; k++)
            hh = MathMax(hh, high[i - k]);
         if(close[i] <= hh)
            continue;
         for(int j = i - 1; j >= i - InpMaxBack; j--)
           {
            if(close[j] >= open[j])
               continue;
            double top = InpBodyOnly ? open[j] : high[j];
            double bot = InpBodyOnly ? close[j] : low[j];
            datetime end = endActive;
            bool mitigated = false;
            for(int m = i + 1; m <= last; m++)
               if(close[m] < bot) { mitigated = true; end = time[m]; break; }
            if(mitigated && !InpShowMitigated)
               break;
            string nm = PREFIX + "BULL_" + TimeToString(time[j], TIME_DATE | TIME_MINUTES);
            if(ObjectFind(0, nm) < 0)
              {
               DrawZone(nm, time[j], end, top, bot, InpBullColor);
               if(!mitigated)
                  nBull++;
              }
            break;
           }
        }
      else if(body < 0 && nBear < InpMaxZones)
        {
         double ll = low[i - 1];
         for(int k = 2; k <= InpStructBars; k++)
            ll = MathMin(ll, low[i - k]);
         if(close[i] >= ll)
            continue;
         for(int j = i - 1; j >= i - InpMaxBack; j--)
           {
            if(close[j] <= open[j])
               continue;
            double top = InpBodyOnly ? close[j] : high[j];
            double bot = InpBodyOnly ? open[j] : low[j];
            datetime end = endActive;
            bool mitigated = false;
            for(int m = i + 1; m <= last; m++)
               if(close[m] > top) { mitigated = true; end = time[m]; break; }
            if(mitigated && !InpShowMitigated)
               break;
            string nm = PREFIX + "BEAR_" + TimeToString(time[j], TIME_DATE | TIME_MINUTES);
            if(ObjectFind(0, nm) < 0)
              {
               DrawZone(nm, time[j], end, top, bot, InpBearColor);
               if(!mitigated)
                  nBear++;
              }
            break;
           }
        }
     }
   ChartRedraw();
   return rates_total;
  }
