//+------------------------------------------------------------------+
//| Sweep_Reclaim_Alert.mq5  v2                                      |
//| Prints only the sweep that mattered in the data: a sweep of the  |
//| 24-HOUR high/low (288 M5 bars) by 0.5-3 pips that closes back    |
//| inside on the same bar, while price is stretched.                |
//|                                                                  |
//| Evidence (research\sweep_size_study.py, sweep_play_rule.py,      |
//| USDJPY M5 10 Mar-6 Nov 2026, fill = next open + spread, fixed    |
//| +10 / -10 pip bracket, 36-bar time stop; train 60% / test 40%):  |
//|   PLAY  (24h level, 0.5-3p, stretch>=0.62): win 57% / 60%,       |
//|         +1.13p / +1.94p per trade, about 1.2 a day.              |
//|         Shorts carried it (+1.64p / +2.69p); longs about flat.   |
//|   LEVEL (24h level, 0.5-3p, any stretch):   +0.72p / +0.55p.     |
//|   AVOID (24h level swept by 3+ pips): -2.02p / -0.42p - these    |
//|         are breakouts; do not fade them.                         |
//|   Sweeps of small 2h levels: weak (+0.67p / +0.25p) - not shown. |
//|   Any reversal bar (baseline): -0.37p / -0.52p.                  |
//| First week of Nov 2026: 10 PLAY trades, -60p. Small edge, no     |
//| slippage modelled. A decision aid, not a guarantee.              |
//+------------------------------------------------------------------+
#property copyright "Sweep Reclaim Alert"
#property version   "2.00"
#property indicator_chart_window
#property indicator_buffers 10
#property indicator_plots   6

#property indicator_label1  "PLAY buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  5
#property indicator_label2  "PLAY sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  5
#property indicator_label3  "24h sweep buy (not stretched)"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrMediumSeaGreen
#property indicator_width3  2
#property indicator_label4  "24h sweep sell (not stretched)"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrIndianRed
#property indicator_width4  2
#property indicator_label5  "AVOID deep sweep (low)"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrGray
#property indicator_width5  2
#property indicator_label6  "AVOID deep sweep (high)"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrGray
#property indicator_width6  2

enum ENUM_SIDE { SIDE_BOTH = 0, // Both directions
                 SIDE_SELL = 1, // Sells only (carried the result in 2026)
                 SIDE_BUY  = 2  // Buys only
               };

input group "PLAY rule (as validated - change only after re-running the study)"
input int    InpLevelBars  = 288;    // Swept level lookback, bars (288 M5 = 24 hours)
input bool   InpAllLevels  = false;  // Also accept 24/48/96-bar levels (weaker in the data)
input double InpMinDepth   = 0.5;    // Min sweep beyond the level, pips
input double InpMaxDepth   = 3.0;    // Max sweep, pips (deeper = breakout = AVOID)
input double InpMinStretch = 0.62;   // Min stretch score for a PLAY
input ENUM_SIDE InpSide    = SIDE_BOTH; // Directions to print
input int    InpMinGap     = 6;      // Min bars between sweeps in the same direction

input group "Trade plan drawn (as tested)"
input double InpTpPips     = 10.0;   // Target, pips from entry
input double InpSlPips     = 10.0;   // Stop, pips from entry
input int    InpTimeBars   = 36;     // Time stop, bars (36 = 3h)
input bool   InpDrawPlan   = true;   // Draw level, TP, SL and label for PLAY signals
input int    InpMaxMarks   = 30;     // Keep plan objects of the last N signals

input group "Display"
input bool   InpShowLevel  = true;   // Show 24h sweeps that are the right size but not stretched
input bool   InpShowAvoid  = true;   // Show deep (breakout) sweeps as grey X
input bool   InpGauge      = true;   // Gauge: distance to 24h high/low and stretch
input int    InpGaugeX     = 10;     // Gauge X
input int    InpGaugeY     = 25;     // Gauge Y

input group "Alerts"
input bool   InpPopup      = true;   // Popup alert
input bool   InpPush       = false;  // Push notification to phone
input string InpSound      = "alert.wav"; // Sound file (empty = none)
input bool   InpLiveWatch  = true;   // Early alert while a PLAY sweep is forming (unconfirmed)
input bool   InpAlertLevel = false;  // Alert on not-stretched 24h sweeps too
input bool   InpAlertAvoid = false;  // Alert on deep (breakout) sweeps

input group "Testing"
input int    InpMinBars    = 300;    // Bars needed before signals start
input bool   InpDebugCsv   = false;  // Write every sweep to MQL5\Files\SweepReclaim_debug.csv

const double MU48 = -1.5647647681, SD48 = 1.3383025567;
const double MU288 = -1.9859023515, SD288 = 5.7488277428;
const double MUDO = -2.6433684188, SDDO = 9.3743545638;
const string PFX = "SRA_";

double PlayB[], PlayS[], LvlB[], LvlS[], AvB[], AvS[];
double ATR[], E48[], E288[], DOpen[];

int      g_done = -1, g_seq = 0, g_fh = INVALID_HANDLE;
int      g_lastSig[2];
datetime g_liveBar[2];
double   g_pip = 0.01;

//+------------------------------------------------------------------+
double TL(const double &low[], const double &high[], const int j, const int s) { return s > 0 ? low[j] : -high[j]; }
string Tag(const int s) { return s > 0 ? "BUY" : "SELL"; }
bool SideOK(const int s) { return InpSide == SIDE_BOTH || (InpSide == SIDE_SELL && s < 0) || (InpSide == SIDE_BUY && s > 0); }

int OnInit()
  {
   SetIndexBuffer(0, PlayB, INDICATOR_DATA); SetIndexBuffer(1, PlayS, INDICATOR_DATA);
   SetIndexBuffer(2, LvlB, INDICATOR_DATA);  SetIndexBuffer(3, LvlS, INDICATOR_DATA);
   SetIndexBuffer(4, AvB, INDICATOR_DATA);   SetIndexBuffer(5, AvS, INDICATOR_DATA);
   SetIndexBuffer(6, ATR, INDICATOR_CALCULATIONS);  SetIndexBuffer(7, E48, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, E288, INDICATOR_CALCULATIONS); SetIndexBuffer(9, DOpen, INDICATOR_CALCULATIONS);
   for(int p = 0; p < 6; p++) PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_ARROW, 233); PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 233); PlotIndexSetInteger(3, PLOT_ARROW, 234);
   PlotIndexSetInteger(4, PLOT_ARROW, 251); PlotIndexSetInteger(5, PLOT_ARROW, 251);
   g_pip = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;
   IndicatorSetString(INDICATOR_SHORTNAME, "Sweep Reclaim Alert v2");
   if(InpDebugCsv)
     {
      g_fh = FileOpen("SweepReclaim_debug.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(g_fh != INVALID_HANDLE) FileWrite(g_fh, "time", "dir", "level_bars", "depth_pips", "stretch", "class");
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_fh != INVALID_HANDLE) { FileClose(g_fh); g_fh = INVALID_HANDLE; }
   if(reason != REASON_CHARTCHANGE) ObjectsDeleteAll(0, PFX);
  }

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

//+------------------------------------------------------------------+
//| Most significant level (288 > 96 > 48 > 24 bars, formed >= 3 bars |
//| ago) that bar i swept AND closed back beyond. 0 = no sweep.       |
//+------------------------------------------------------------------+
int FindSweep(const int i, const int s, const double &high[], const double &low[], const double &close[],
              double &depthPips, double &levelPrice)
  {
   const int LV[4] = {288, 96, 48, 24};
   const double lo = TL(low, high, i, s), cl = s * close[i];
   for(int k = 0; k < 4; k++)
     {
      const int N = LV[k];
      if(N != InpLevelBars && N > InpLevelBars) continue;      // honour a smaller custom InpLevelBars
      if(i - N < 0) continue;
      double lv = DBL_MAX;
      for(int j = i - N; j <= i - 3; j++) lv = MathMin(lv, TL(low, high, j, s));
      if(lo < lv && cl > lv)
        {
         depthPips = (lv - lo) / g_pip;
         levelPrice = s * lv;
         return N;
        }
     }
   return 0;
  }

// 0 = ignore, 1 = PLAY, 2 = LEVEL (right size, not stretched), 3 = AVOID (deep)
int Classify(const int N, const double depthPips, const double stretch)
  {
   if(!InpAllLevels && N < InpLevelBars) return 0;
   if(depthPips >= InpMaxDepth) return 3;
   if(depthPips < InpMinDepth) return 0;
   return stretch >= InpMinStretch ? 1 : 2;
  }

void Notify(const string msg)
  {
   Print(msg);
   if(InpPopup) Alert(msg);
   if(InpPush) SendNotification(msg);
   if(StringLen(InpSound) > 0) PlaySound(InpSound);
  }

//+------------------------------------------------------------------+
void DrawPlan(const int i, const int s, const int N, const double depthPips, const double stretch, const double levelPrice,
              const datetime &time[], const double &high[], const double &low[], const double &close[])
  {
   const int ps = PeriodSeconds();
   const string id = PFX + IntegerToString(g_seq);
   const datetime t2 = time[i] + InpTimeBars * ps;
   const double tp = close[i] + s * InpTpPips * g_pip, sl = close[i] - s * InpSlPips * g_pip;
   const string nm[3] = {"_LV", "_TP", "_SL"};
   const double pr[3] = {levelPrice, tp, sl};
   const datetime ta[3] = {time[MathMax(0, i - 24)], time[i], time[i]};
   const color cl[3] = {clrGold, clrLimeGreen, clrOrangeRed};
   const ENUM_LINE_STYLE st[3] = {STYLE_DASH, STYLE_DOT, STYLE_DOT};
   for(int k = 0; k < 3; k++)
     {
      const string o = id + nm[k];
      ObjectCreate(0, o, OBJ_TREND, 0, ta[k], pr[k], (k == 0 ? time[i] + 6 * ps : t2), pr[k]);
      ObjectSetInteger(0, o, OBJPROP_COLOR, cl[k]);
      ObjectSetInteger(0, o, OBJPROP_STYLE, st[k]);
      ObjectSetInteger(0, o, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
     }
   const double a = ATR[i];
   const double py = (s > 0) ? low[i] - 1.1 * a : high[i] + 1.1 * a;
   ObjectCreate(0, id + "_T", OBJ_TEXT, 0, time[i], py);
   ObjectSetString(0, id + "_T", OBJPROP_TEXT, StringFormat("PLAY %s 24h sweep %.1fp | stretch %.2f", Tag(s), depthPips, stretch));
   ObjectSetInteger(0, id + "_T", OBJPROP_COLOR, s > 0 ? clrLime : clrRed);
   ObjectSetInteger(0, id + "_T", OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, id + "_T", OBJPROP_ANCHOR, s > 0 ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, id + "_T", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, id + "_T", OBJPROP_HIDDEN, true);
   const int old = g_seq - InpMaxMarks;
   if(old >= 0)
     {
      const string oid = PFX + IntegerToString(old);
      ObjectDelete(0, oid + "_LV"); ObjectDelete(0, oid + "_TP"); ObjectDelete(0, oid + "_SL"); ObjectDelete(0, oid + "_T");
     }
   g_seq++;
  }

//+------------------------------------------------------------------+
void ProcessBar(const int i, const bool live, const datetime &time[], const double &high[], const double &low[],
                const double &close[])
  {
   if(i < InpMinBars) return;
   for(int d = 0; d < 2; d++)
     {
      const int s = (d == 0) ? 1 : -1;
      if(i - g_lastSig[d] < InpMinGap) continue;
      double depth, lvl;
      const int N = FindSweep(i, s, high, low, close, depth, lvl);
      if(N == 0) continue;
      g_lastSig[d] = i;                          // any sweep starts the gap (as in the study)
      if(!SideOK(s)) continue;
      const double sc = Score(i, s, close);
      const int cls = Classify(N, depth, sc);
      if(cls == 0) continue;
      const double a = ATR[i];
      const double yb = low[i] - 0.3 * a, ys = high[i] + 0.3 * a;
      if(cls == 1)
        {
         if(s > 0) PlayB[i] = yb; else PlayS[i] = ys;
         if(InpDrawPlan) DrawPlan(i, s, N, depth, sc, lvl, time, high, low, close);
        }
      else if(cls == 2 && InpShowLevel) { if(s > 0) LvlB[i] = yb; else LvlS[i] = ys; }
      else if(cls == 3 && InpShowAvoid) { if(s > 0) AvB[i] = yb; else AvS[i] = ys; }
      if(g_fh != INVALID_HANDLE)
         FileWrite(g_fh, TimeToString(time[i], TIME_DATE | TIME_MINUTES), s, N, DoubleToString(depth, 1),
                   DoubleToString(sc, 3), cls == 1 ? "PLAY" : (cls == 2 ? "LEVEL" : "AVOID"));
      if(!live) continue;
      if(cls == 1)
         Notify(StringFormat("%s %s PLAY %s: swept the %dh %s by %.1f pips and closed back inside, stretch %.2f | enter next bar ~%.*f  TP %.*f  SL %.*f  (time stop %d bars)",
                _Symbol, EnumToString(Period()), Tag(s), N * PeriodSeconds() / 3600, s > 0 ? "low" : "high", depth, sc,
                _Digits, close[i], _Digits, close[i] + s * InpTpPips * g_pip, _Digits, close[i] - s * InpSlPips * g_pip, InpTimeBars));
      else if(cls == 2 && InpAlertLevel)
         Notify(StringFormat("%s %s 24h sweep %s %.1f pips (stretch %.2f below %.2f - weaker)", _Symbol, EnumToString(Period()), Tag(s), depth, sc, InpMinStretch));
      else if(cls == 3 && InpAlertAvoid)
         Notify(StringFormat("%s %s AVOID: 24h %s swept by %.1f pips - looks like a breakout, do not fade", _Symbol, EnumToString(Period()), s > 0 ? "low" : "high", depth));
     }
  }

//+------------------------------------------------------------------+
void Gauge(const int f, const double &high[], const double &low[], const double &close[])
  {
   const string nm = PFX + "gauge";
   if(!InpGauge || f - InpLevelBars < 0) { ObjectDelete(0, nm); return; }
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
   double lo = DBL_MAX, hi = -DBL_MAX;
   for(int j = f - InpLevelBars; j <= f - 3; j++) { lo = MathMin(lo, low[j]); hi = MathMax(hi, high[j]); }
   const double dLo = (close[f] - lo) / g_pip, dHi = (hi - close[f]) / g_pip;
   const double sb = Score(f, 1, close), ss = Score(f, -1, close);
   ObjectSetString(0, nm, OBJPROP_TEXT, StringFormat("24h low %.*f (%.1fp away) stretch BUY %.2f  |  24h high %.*f (%.1fp away) stretch SELL %.2f  [PLAY needs %.2f]",
                   _Digits, lo, dLo, sb, _Digits, hi, dHi, ss, InpMinStretch));
   const bool hot = (dLo <= 3.0 && sb >= InpMinStretch) || (dHi <= 3.0 && ss >= InpMinStretch);
   const bool warm = (sb >= InpMinStretch || ss >= InpMinStretch);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, hot ? clrYellow : (warm ? clrGold : clrSilver));
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
      for(int d = 0; d < 2; d++) { g_lastSig[d] = -1000; g_liveBar[d] = 0; }
      ObjectsDeleteAll(0, PFX);
     }
   const double k48 = 2.0 / 49.0, k288 = 2.0 / 289.0;
   for(int i = first; i < rates_total; i++)
     {
      PlayB[i] = PlayS[i] = LvlB[i] = LvlS[i] = AvB[i] = AvS[i] = EMPTY_VALUE;
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
      ProcessBar(i, !historical && i == rates_total - 2, time, high, low, close);
   g_done = rates_total - 2;
   const int f = rates_total - 1;
   Gauge(f, high, low, close);
   if(InpLiveWatch && !historical && f >= InpMinBars)
      for(int d = 0; d < 2; d++)
        {
         const int s = (d == 0) ? 1 : -1;
         if(!SideOK(s) || g_liveBar[d] == time[f] || f - g_lastSig[d] < InpMinGap) continue;
         double depth, lvl;
         const int N = FindSweep(f, s, high, low, close, depth, lvl);
         if(N == 0) continue;
         const double sc = Score(f, s, close);
         if(Classify(N, depth, sc) != 1) continue;
         g_liveBar[d] = time[f];
         Notify(StringFormat("%s %s forming PLAY %s (unconfirmed): 24h %s swept by %.1f pips, stretch %.2f - wait for the bar to close back inside",
                _Symbol, EnumToString(Period()), Tag(s), s > 0 ? "low" : "high", depth, sc));
        }
   return rates_total;
  }
//+------------------------------------------------------------------+
