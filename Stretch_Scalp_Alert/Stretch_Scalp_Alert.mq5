//+------------------------------------------------------------------+
//| Stretch_Scalp_Alert.mq5                                          |
//| Mean-reversion scalp signal for USDJPY M5 (server time).         |
//|                                                                  |
//| SIGNAL (all on the CLOSED bar, never repaints):                  |
//|   stretch score >= threshold AND the bar closes back in the      |
//|   trade direction (bullish bar for BUY, bearish bar for SELL).   |
//|   Stretch = how far price is pushed AGAINST the trade, averaged  |
//|   from (close-EMA48)/ATR, (close-EMA288)/ATR, (close-dayopen)/ATR|
//|   each standardised with constants fitted on 10 Mar-7 Aug 2026.  |
//|                                                                  |
//| EVIDENCE (research\stretch_*.py, USDJPY M5, 10 Mar-6 Nov 2026,   |
//| fill = next open + spread, TP 1.5 ATR / SL 1.5 ATR, 24-bar stop):|
//|   score >= 1.531 (top 2% of bars):  train +1.2p/trade (n=164),   |
//|   test +1.85p/trade (n=111), win 58%/62%, longs and shorts and   |
//|   every test month positive. No stretch filter: -0.3p both halves|
//|   Scores in the 0.62-1.53 band LOST in the test period -> they   |
//|   are not signalled. About 1.6 signals/day. Edge is SMALL        |
//|   (about 2 pips/trade, ~2.5 standard errors); no slippage        |
//|   modelled; max drawdown in test was 70 pips. Not a guarantee.   |
//+------------------------------------------------------------------+
#property copyright "Stretch Scalp Alert"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   4

#property indicator_label1  "Buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrMediumSeaGreen
#property indicator_width1  3
#property indicator_label2  "Sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrIndianRed
#property indicator_width2  3
#property indicator_label3  "Buy STRONG"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrLime
#property indicator_width3  5
#property indicator_label4  "Sell STRONG"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  5

input group "Signal model (fitted on 10 Mar-7 Aug 2026; change only after re-running the study)"
input double InpThreshold = 1.531;   // Stretch score needed for a signal (top 2% of bars)
input double InpStrong    = 1.896;   // Stretch score for a STRONG signal (top 1%)
input int    InpMinGap    = 6;       // Min bars between signals in the same direction
input int    InpMinBars   = 300;     // Bars needed before signals start

input group "Trade plan drawn on the chart (as validated)"
input double InpTpATR     = 1.5;     // Take profit, ATR multiples
input double InpSlATR     = 1.5;     // Stop loss, ATR multiples
input int    InpTimeBars  = 24;      // Time stop, bars (24 = 2h)
input bool   InpDrawPlan  = true;    // Draw TP / SL lines and label
input int    InpMaxMarks  = 30;      // Keep plan objects of the last N signals

input group "Alerts"
input bool   InpPopup     = true;    // Popup alert
input bool   InpPush      = false;   // Push notification to phone
input string InpSound     = "alert.wav"; // Sound file (empty = none)
input bool   InpArmed     = true;    // ARMED alert: closed bar reached the extreme, wait for a reversal bar
input bool   InpLiveWatch = false;   // LIVE alert: stretch is at the extreme right now (intrabar, may vanish)

input group "Display"
input bool   InpGauge     = true;    // Show live stretch gauge (top-left)
input int    InpGaugeX    = 10;      // Gauge X
input int    InpGaugeY    = 25;      // Gauge Y

input group "Testing"
input bool   InpDebugCsv  = false;   // Write signals to MQL5\Files\StretchScalp_debug.csv

const double MU48 = -1.5647647681, SD48 = 1.3383025567;
const double MU288 = -1.9859023515, SD288 = 5.7488277428;
const double MUDO = -2.6433684188, SDDO = 9.3743545638;
const string PFX = "SSA_";

double BuyB[], SellB[], BuyS[], SellS[];
double ATR[], E48[], E288[], DOpen[];

int      g_done = -1, g_seq = 0, g_fh = INVALID_HANDLE;
int      g_lastSig[2];
bool     g_wasExtreme[2];
datetime g_liveBar[2];

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyB, INDICATOR_DATA);  SetIndexBuffer(1, SellB, INDICATOR_DATA);
   SetIndexBuffer(2, BuyS, INDICATOR_DATA);  SetIndexBuffer(3, SellS, INDICATOR_DATA);
   SetIndexBuffer(4, ATR, INDICATOR_CALCULATIONS);  SetIndexBuffer(5, E48, INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, E288, INDICATOR_CALCULATIONS); SetIndexBuffer(7, DOpen, INDICATOR_CALCULATIONS);
   for(int p = 0; p < 4; p++) PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_ARROW, 233); PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 233); PlotIndexSetInteger(3, PLOT_ARROW, 234);
   IndicatorSetString(INDICATOR_SHORTNAME, "Stretch Scalp Alert");
   if(InpDebugCsv)
     {
      g_fh = FileOpen("StretchScalp_debug.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(g_fh != INVALID_HANDLE) FileWrite(g_fh, "time", "dir", "score", "strong", "close", "tp", "sl");
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_fh != INVALID_HANDLE) { FileClose(g_fh); g_fh = INVALID_HANDLE; }
   if(reason != REASON_CHARTCHANGE) ObjectsDeleteAll(0, PFX);
  }

//+------------------------------------------------------------------+
//| Stretch score at bar i against direction s (+1 = price stretched |
//| DOWN, a BUY candidate; -1 = stretched UP, a SELL candidate).     |
//+------------------------------------------------------------------+
double Score(const int i, const int s, const double &close[])
  {
   const double a = ATR[i];
   if(a <= 0.0) return -99.0;
   const double t48 = s * (close[i] - E48[i]) / a;
   const double t288 = s * (close[i] - E288[i]) / a;
   const double dd = s * (close[i] - DOpen[i]) / a;
   return -(((t48 - MU48) / SD48 + (t288 - MU288) / SD288 + (dd - MUDO) / SDDO) / 3.0);
  }

void Notify(const string msg)
  {
   Print(msg);
   if(InpPopup) Alert(msg);
   if(InpPush) SendNotification(msg);
   if(StringLen(InpSound) > 0) PlaySound(InpSound);
  }

string Tag(const int s) { return s > 0 ? "BUY" : "SELL"; }

//+------------------------------------------------------------------+
void DrawPlan(const int i, const int s, const double score, const bool strong, const double tp, const double sl,
              const datetime &time[], const double &high[], const double &low[])
  {
   const int ps = PeriodSeconds();
   const string id = PFX + IntegerToString(g_seq);
   const datetime t2 = time[i] + InpTimeBars * ps;
   const string nm[2] = {"_TP", "_SL"};
   const double pr[2] = {tp, sl};
   const color cl[2] = {clrLimeGreen, clrOrangeRed};
   for(int k = 0; k < 2; k++)
     {
      const string o = id + nm[k];
      ObjectCreate(0, o, OBJ_TREND, 0, time[i], pr[k], t2, pr[k]);
      ObjectSetInteger(0, o, OBJPROP_COLOR, cl[k]);
      ObjectSetInteger(0, o, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, o, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
     }
   const double a = ATR[i];
   const double py = (s > 0) ? low[i] - 1.1 * a : high[i] + 1.1 * a;
   ObjectCreate(0, id + "_T", OBJ_TEXT, 0, time[i], py);
   ObjectSetString(0, id + "_T", OBJPROP_TEXT, StringFormat("%s%s %.2f", Tag(s), strong ? "!" : "", score));
   ObjectSetInteger(0, id + "_T", OBJPROP_COLOR, s > 0 ? clrLime : clrRed);
   ObjectSetInteger(0, id + "_T", OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, id + "_T", OBJPROP_ANCHOR, s > 0 ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, id + "_T", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, id + "_T", OBJPROP_HIDDEN, true);
   const int old = g_seq - InpMaxMarks;
   if(old >= 0)
     {
      const string oid = PFX + IntegerToString(old);
      ObjectDelete(0, oid + "_TP"); ObjectDelete(0, oid + "_SL"); ObjectDelete(0, oid + "_T");
     }
   g_seq++;
  }

//+------------------------------------------------------------------+
void ProcessBar(const int i, const bool live, const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[])
  {
   if(i < InpMinBars) return;
   for(int d = 0; d < 2; d++)
     {
      const int s = (d == 0) ? 1 : -1;
      const double sc = Score(i, s, close);
      const bool extreme = (sc >= InpThreshold);
      const bool reversal = (s * (close[i] - open[i]) > 0.0);
      const bool freshExtreme = extreme && !g_wasExtreme[d];
      g_wasExtreme[d] = extreme;
      if(!extreme) continue;
      if(extreme && reversal && i - g_lastSig[d] >= InpMinGap)
        {
         g_lastSig[d] = i;
         const bool strong = (sc >= InpStrong);
         const double a = ATR[i];
         const double tp = close[i] + s * InpTpATR * a, sl = close[i] - s * InpSlATR * a;
         if(s > 0) { if(strong) BuyS[i] = low[i] - 0.3 * a; else BuyB[i] = low[i] - 0.3 * a; }
         else      { if(strong) SellS[i] = high[i] + 0.3 * a; else SellB[i] = high[i] + 0.3 * a; }
         if(InpDrawPlan) DrawPlan(i, s, sc, strong, tp, sl, time, high, low);
         if(g_fh != INVALID_HANDLE)
            FileWrite(g_fh, TimeToString(time[i], TIME_DATE | TIME_MINUTES), s, DoubleToString(sc, 3), strong ? 1 : 0,
                      DoubleToString(close[i], _Digits), DoubleToString(tp, _Digits), DoubleToString(sl, _Digits));
         if(live)
            Notify(StringFormat("%s %s: %s%s signal, stretch %.2f | enter next bar ~%.*f  TP %.*f (%.1f pips)  SL %.*f (%.1f pips)  time stop %d bars",
                   _Symbol, EnumToString(Period()), Tag(s), strong ? " STRONG" : "", sc, _Digits, close[i], _Digits, tp,
                   InpTpATR * a / (_Point * 10.0), _Digits, sl, InpSlATR * a / (_Point * 10.0), InpTimeBars));
        }
      else if(live && InpArmed && freshExtreme)
         Notify(StringFormat("%s %s ARMED %s: stretch %.2f is at the extreme - wait for a bar that closes %s",
                _Symbol, EnumToString(Period()), Tag(s), sc, s > 0 ? "UP (bullish)" : "DOWN (bearish)"));
     }
  }

//+------------------------------------------------------------------+
void Gauge(const int f, const double &close[])
  {
   const string nm = PFX + "gauge";
   if(!InpGauge) { ObjectDelete(0, nm); return; }
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpGaugeX);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpGaugeY);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
     }
   const double sb = Score(f, 1, close), ss = Score(f, -1, close);
   const double best = MathMax(sb, ss);
   ObjectSetString(0, nm, OBJPROP_TEXT, StringFormat("Stretch  BUY %5.2f   SELL %5.2f   (signal >= %.2f)", sb, ss, InpThreshold));
   ObjectSetInteger(0, nm, OBJPROP_COLOR, best >= InpThreshold ? (sb >= ss ? clrLime : clrRed) : (best >= 0.75 * InpThreshold ? clrGold : clrSilver));
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[], const double &open[],
                const double &high[], const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   if(rates_total < InpMinBars + 5) return 0;
   const int first = prev_calculated <= 0 ? 0 : prev_calculated - 1;
   if(prev_calculated <= 0)
     {
      g_done = -1; g_seq = 0;
      for(int d = 0; d < 2; d++) { g_lastSig[d] = -1000; g_wasExtreme[d] = false; g_liveBar[d] = 0; }
      ObjectsDeleteAll(0, PFX);
     }
   const double k48 = 2.0 / 49.0, k288 = 2.0 / 289.0;
   for(int i = first; i < rates_total; i++)
     {
      BuyB[i] = SellB[i] = BuyS[i] = SellS[i] = EMPTY_VALUE;
      E48[i]  = (i == 0) ? close[0] : k48  * close[i] + (1.0 - k48)  * E48[i - 1];
      E288[i] = (i == 0) ? close[0] : k288 * close[i] + (1.0 - k288) * E288[i - 1];
      DOpen[i] = (i == 0 || time[i] / 86400 != time[i - 1] / 86400) ? open[i] : DOpen[i - 1];
      if(i < 13) { ATR[i] = 0.0; continue; }
      double sum = 0.0;
      for(int j = i - 13; j <= i; j++)
        {
         const double pc = (j == 0) ? close[0] : close[j - 1];
         sum += MathMax(high[j] - low[j], MathMax(MathAbs(high[j] - pc), MathAbs(low[j] - pc)));
        }
      ATR[i] = sum / 14.0;
     }
   const bool historical = (prev_calculated <= 0);
   for(int i = g_done + 1; i <= rates_total - 2; i++)
      ProcessBar(i, !historical && i == rates_total - 2, time, open, high, low, close);
   g_done = rates_total - 2;
   const int f = rates_total - 1;
   Gauge(f, close);
   if(InpLiveWatch && !historical)
      for(int d = 0; d < 2; d++)
        {
         const int s = (d == 0) ? 1 : -1;
         const double sc = Score(f, s, close);
         if(sc >= InpThreshold && g_liveBar[d] != time[f] && f - g_lastSig[d] >= InpMinGap)
           {
            g_liveBar[d] = time[f];
            Notify(StringFormat("%s %s LIVE %s: stretch %.2f at the extreme right now (unconfirmed) - wait for the bar to close %s",
                   _Symbol, EnumToString(Period()), Tag(s), sc, s > 0 ? "bullish" : "bearish"));
           }
        }
   return rates_total;
  }
//+------------------------------------------------------------------+
