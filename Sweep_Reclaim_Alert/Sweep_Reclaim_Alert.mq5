//+------------------------------------------------------------------+
//| Sweep_Reclaim_Alert.mq5  v4 - "Swing Radar" (USDJPY M5)          |
//| Goal: catch more of the important swings (30+ pip moves) early.  |
//| Five causal detectors run together on CLOSED bars:               |
//|   sweep  : low breaks the last swing low (3-bar pivot) and a bar  |
//|            closes back above it within 2 bars                     |
//|   retest : low comes back to the last swing low (within 0.3 ATR)  |
//|            without breaking it, bullish close                     |
//|   choch  : after a new 2h low, close above the last swing high    |
//|   trap30 / trap60 : your 5/6 Nov pattern on a 30m / 1h range      |
//|            (push out, back to the other edge, turn)               |
//| (SELL = mirror.) Each signal is graded:                           |
//|   A : stretch >= 0 AND tick volume >= 20-bar average              |
//|   B : stretch >= 0 OR within 3 ATR of the 24h low/high            |
//|   C : everything else (hidden by default)                         |
//| History (research\swing_recall.py / swing_tiers.py, 10 Mar-6 Nov  |
//| 2026; 'caught' = signal while >= 2/3 of a 30+ pip swing is ahead):|
//|   A      ~4.7/day, 26% of signals start a swing, catches ~15%     |
//|   A+B    ~12.6/day, 23%, catches ~24%                             |
//|   A+B+C  ~42/day,  17%, catches ~49%                              |
//|   old trap-only indicator: 3.3/day, 15%, caught 8%                |
//| With-trend pullbacks (like 6 Nov 09:40) score only C: as a group  |
//| they were no better than random. A radar, not a guarantee.        |
//+------------------------------------------------------------------+
#property copyright "Sweep Reclaim Alert"
#property version   "4.50"
#property indicator_chart_window
#property indicator_buffers 12
#property indicator_plots   8

#property indicator_label1  "A buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  4
#property indicator_label2  "A sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  4
#property indicator_label3  "B buy"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrMediumSeaGreen
#property indicator_width3  2
#property indicator_label4  "B sell"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrIndianRed
#property indicator_width4  2
#property indicator_label5  "C buy"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrDimGray
#property indicator_width5  1
#property indicator_label6  "C sell"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrDimGray
#property indicator_width6  1
#property indicator_label7  "PATTERN buy"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrDodgerBlue
#property indicator_width7  3
#property indicator_label8  "PATTERN sell"
#property indicator_type8   DRAW_ARROW
#property indicator_color8  clrDarkOrange
#property indicator_width8  3

input group "Timeframe"
input bool   InpOnlyM5     = true;   // Run only on M5 (other timeframes: nothing drawn, no alerts)

enum ENUM_TREND_FILTER { TF_WITH = 0,        // Only signals WITH the 24h trend (hide counter-trend)
                         TF_NOT_AGAINST = 1, // Hide only clearly counter-trend signals
                         TF_OFF = 2          // No trend filter (fades included)
                       };
input group "Trend filter (24h trend = price vs a rising/falling 24h EMA)"
input ENUM_TREND_FILTER InpTrend = TF_WITH; // Trend filter

input group "Grading (as validated)"
input double InpAStretch   = 0.0;    // A: min stretch
input double InpAVol       = 1.0;    // A: min tick volume vs 20-bar average
input double InpBStretch   = 0.0;    // B: min stretch ...
input double InpBNear24h   = 3.0;    // ... OR within this many ATR of the 24h low/high

input group "Display"
input bool   InpShowB      = false;  // Show B dots (weaker signals)
input bool   InpShowC      = false;  // Show C dots (about 30/day - noisy)
input bool   InpDrawPlan   = false;  // Also draw stop and +10 pip lines for A signals
input double InpTargetPips = 10.0;   // Target line, pips
input int    InpPlanBars   = 36;     // Plan line length, bars
input int    InpMaxMarks   = 300;    // Keep arrows of the last N A signals
input bool   InpGauge      = true;   // Status lines (top-right)
input int    InpGaugeX     = 10;     // Status X
input int    InpGaugeY     = 20;     // Status Y (from the top)

input group "Alerts"
input bool   InpAlertA     = true;   // Alert on A
input bool   InpAlertB     = false;  // Alert on B
input bool   InpAlertS     = true;   // Alert on S (with-trend range sweep)

enum ENUM_MODE { MODE_PATTERN = 0, // PATTERN: only your setup (sweep / 1h trap), any trend (~5/day)
                 MODE_RADAR   = 1, // RADAR: graded A/B/C signals with the trend filter
                 MODE_BOTH    = 2  // Both
               };
input group "Mode"
input ENUM_MODE InpMode    = MODE_PATTERN; // What to show

input group "PATTERN: range -> wick through the edge -> close back inside (or the 1h trap)"
input bool   InpShowS      = true;   // Show PATTERN arrows (blue up / orange down)
input bool   InpSWithTrend = false;  // Sweeps only with the 24h trend (hides 6 Nov 09:40-type setups)
input int    InpSBox       = 12;     // Range length, bars (12 = 1 hour)
input double InpSMaxWidth  = 5.0;    // Max range width, ATR
input double InpSDepth     = 0.7;    // Min wick beyond the range edge, ATR
input double InpSVol       = 1.3;    // Min tick volume vs 20-bar average
input int    InpSRecl      = 2;      // Bars allowed to close back inside after the wick
input bool   InpPopup      = true;   // Popup
input bool   InpPhone      = false;  // Push notification to phone
input string InpSound      = "alert.wav"; // Sound (empty = none)

input group "Testing"
input int    InpMinBars    = 700;    // Bars before signals start
input int    InpLogLast    = 15;     // On load, print the last N A/B signals to the Experts log (0 = off)

//--- fixed detector settings (from research\swing_recall.py)
#define PIV_W      3
#define GAP        6
#define SWEEP_RECL 2
#define RETEST_TOL 0.3
#define CH_N       24
#define CH_WITHIN  24
#define TR_WMAX    5.0
#define TR_BAIT    0.3
#define TR_MAXW    24
#define TR_TOL     0.3
#define TR_RECL    3

const double MU48 = -1.5647647681, SD48 = 1.3383025567;
const double MU288 = -1.9859023515, SD288 = 5.7488277428;
const double MUDO = -2.6433684188, SDDO = 9.3743545638;

struct Pend { int push; double top; double bot; double a; int touch; };

double ABuy[], ASell[], BBuy[], BSell[], CBuy[], CSell[], SBuy[], SSell[];
double ATR[], E48[], E288[], DOpen[];

Pend   g_t30L[], g_t30S[], g_t60L[], g_t60S[];
// pivot sweep / retest / choch state per direction (0 = buy side, 1 = sell side)
bool   ps_has[2]; double ps_lv[2]; int ps_broke[2]; int ps_last[2];
bool   pr_has[2]; double pr_lv[2]; int pr_last[2];
// S detector: pending wick (bar, range edge, depth in ATR) and its own spacing
int    rs_k0[2]; double rs_bot[2]; double rs_dep[2]; int rs_last[2];
bool   ch_has[2]; double ch_ph[2]; int ch_recent[2]; int ch_last[2];
int    g_done = -1, g_seq = 0;
double g_pip = 0.01;
string g_log[];
string g_lastA = "none yet";
string g_lastS = "none yet";

//+------------------------------------------------------------------+
double TO(const double &open[], const int j, const int s)  { return s * open[j]; }
double TC(const double &close[], const int j, const int s) { return s * close[j]; }
double TL(const double &high[], const double &low[], const int j, const int s) { return s > 0 ? low[j] : -high[j]; }
double TH(const double &high[], const double &low[], const int j, const int s) { return s > 0 ? high[j] : -low[j]; }
string Tag(const int s) { return s > 0 ? "BUY" : "SELL"; }

int OnInit()
  {
   SetIndexBuffer(0, ABuy, INDICATOR_DATA); SetIndexBuffer(1, ASell, INDICATOR_DATA);
   SetIndexBuffer(2, BBuy, INDICATOR_DATA); SetIndexBuffer(3, BSell, INDICATOR_DATA);
   SetIndexBuffer(4, CBuy, INDICATOR_DATA); SetIndexBuffer(5, CSell, INDICATOR_DATA);
   SetIndexBuffer(6, SBuy, INDICATOR_DATA);  SetIndexBuffer(7, SSell, INDICATOR_DATA);
   SetIndexBuffer(8, ATR, INDICATOR_CALCULATIONS);   SetIndexBuffer(9, E48, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, E288, INDICATOR_CALCULATIONS); SetIndexBuffer(11, DOpen, INDICATOR_CALCULATIONS);
   for(int p = 0; p < 8; p++) PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(6, PLOT_ARROW, 241); PlotIndexSetInteger(7, PLOT_ARROW, 242);
   PlotIndexSetInteger(0, PLOT_ARROW, 233); PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 159); PlotIndexSetInteger(3, PLOT_ARROW, 159);
   PlotIndexSetInteger(4, PLOT_ARROW, 159); PlotIndexSetInteger(5, PLOT_ARROW, 159);
   g_pip = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;
   IndicatorSetString(INDICATOR_SHORTNAME, "Swing Radar (Sweep Reclaim v4)");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { if(reason != REASON_CHARTCHANGE) ObjectsDeleteAll(0, "SRA_"); }

void Notify(const string msg)
  {
   Print(msg);
   if(InpPopup) Alert(msg);
   if(InpPhone) SendNotification(msg);
   if(StringLen(InpSound) > 0) PlaySound(InpSound);
  }

double Score(const int i, const int s, const double &close[])
  {
   const double a = ATR[i];
   if(a <= 0.0) return -99.0;
   const double t48 = s * (close[i] - E48[i]) / a, t288 = s * (close[i] - E288[i]) / a, dd = s * (close[i] - DOpen[i]) / a;
   return -(((t48 - MU48) / SD48 + (t288 - MU288) / SD288 + (dd - MUDO) / SDDO) / 3.0);
  }

//+------------------------------------------------------------------+
//| Detector 1/2: trap on a BOX-bar range (same as v3)               |
//+------------------------------------------------------------------+
bool Trap(Pend &arr[], const int BOX, const int s, const int i, const double &open[], const double &high[],
          const double &low[], const double &close[])
  {
   if(i < BOX + 20) return false;
   for(int k = 0; k < ArraySize(arr);)
     {
      bool remove = false;
      if(arr[k].touch < 0)
        {
         if(i <= arr[k].push + TR_MAXW - 1 && TL(high, low, i, s) <= arr[k].bot + TR_TOL * arr[k].a) arr[k].touch = i;
         else if(i > arr[k].push + TR_MAXW - 1) remove = true;
        }
      if(!remove && arr[k].touch >= 0)
        {
         if(i <= arr[k].touch + TR_RECL)
           {
            if(TC(close, i, s) > arr[k].bot && TC(close, i, s) > TO(open, i, s)) { ArrayResize(arr, 0); return true; }
           }
         else remove = true;
        }
      if(remove) ArrayRemove(arr, k, 1); else k++;
     }
   const double a = ATR[i - 1];
   if(a <= 0.0) return false;
   double top = -DBL_MAX, bot = DBL_MAX;
   for(int j = i - BOX; j <= i - 1; j++) { top = MathMax(top, TH(high, low, j, s)); bot = MathMin(bot, TL(high, low, j, s)); }
   if((top - bot) <= TR_WMAX * a && TC(close, i, s) > top + TR_BAIT * a && TC(close, i - 1, s) <= top)
     {
      const int z = ArraySize(arr); ArrayResize(arr, z + 1);
      arr[z].push = i; arr[z].top = top; arr[z].bot = bot; arr[z].a = a; arr[z].touch = -1;
     }
   return false;
  }

// pivot low (transformed) at j: TL[j] is the minimum of [j-w, j+w]
bool PivotLow(const int j, const int s, const double &high[], const double &low[])
  {
   const double x = TL(high, low, j, s);
   for(int m = j - PIV_W; m <= j + PIV_W; m++) if(TL(high, low, m, s) < x) return false;
   return true;
  }
bool PivotHigh(const int j, const int s, const double &high[], const double &low[])
  {
   const double x = TH(high, low, j, s);
   for(int m = j - PIV_W; m <= j + PIV_W; m++) if(TH(high, low, m, s) > x) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Detector 3: sweep of the last pivot low, close back above        |
//+------------------------------------------------------------------+
bool Sweep(const int d, const int s, const int i, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   if(i < 30) return false;
   const int j = i - 1 - PIV_W;
   if(j - PIV_W >= 0 && PivotLow(j, s, high, low)) { ps_has[d] = true; ps_lv[d] = TL(high, low, j, s); ps_broke[d] = -1; }
   if(!ps_has[d] || i - ps_last[d] < GAP) return false;
   const double lv = ps_lv[d];
   if(TL(high, low, i, s) < lv && ps_broke[d] < 0) ps_broke[d] = i;
   if(ps_broke[d] >= 0 && i - ps_broke[d] <= SWEEP_RECL && TC(close, i, s) > lv && TC(close, i, s) > TO(open, i, s))
     {
      ps_last[d] = i; ps_broke[d] = -1; ps_lv[d] = TL(high, low, i, s);   // the sweep low becomes the new level
      return true;
     }
   else if(ps_broke[d] >= 0 && i - ps_broke[d] > SWEEP_RECL) { ps_has[d] = false; ps_broke[d] = -1; }
   return false;
  }

//+------------------------------------------------------------------+
//| Detector 4: retest of the last pivot low (holds), bullish close  |
//+------------------------------------------------------------------+
bool Retest(const int d, const int s, const int i, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   if(i < 30) return false;
   const int j = i - 1 - PIV_W;
   if(j - PIV_W >= 0 && PivotLow(j, s, high, low)) { pr_has[d] = true; pr_lv[d] = TL(high, low, j, s); }
   if(!pr_has[d] || i - pr_last[d] < GAP) return false;
   const double lv = pr_lv[d], lo = TL(high, low, i, s);
   if(lo >= lv && lo <= lv + RETEST_TOL * ATR[i] && TC(close, i, s) > TO(open, i, s) && TC(close, i, s) > lv)
     { pr_last[d] = i; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| Detector 5: change of character - new 2h low, then close above   |
//| the last pivot high                                              |
//+------------------------------------------------------------------+
bool Choch(const int d, const int s, const int i, const double &high[], const double &low[], const double &close[])
  {
   if(i < CH_N + 5) return false;
   const int j = i - 1 - PIV_W;
   if(j - PIV_W >= 0 && PivotHigh(j, s, high, low)) { ch_has[d] = true; ch_ph[d] = TH(high, low, j, s); }
   double mn = DBL_MAX;
   for(int m = i - CH_N + 1; m <= i; m++) mn = MathMin(mn, TL(high, low, m, s));
   if(TL(high, low, i, s) <= mn) ch_recent[d] = i;
   if(!ch_has[d] || i - ch_last[d] < GAP) return false;
   if(i - ch_recent[d] <= CH_WITHIN && TC(close, i, s) > ch_ph[d] && TC(close, i - 1, s) <= ch_ph[d]) { ch_last[d] = i; return true; }
   return false;
  }

//+------------------------------------------------------------------+
// +1 = with the 24h trend (price on the trade side of EMA288 and EMA288 moving that way over 3h),
// -1 = against it, 0 = mixed
int TrendCtx(const int i, const int s, const double &close[])
  {
   const double a = ATR[i];
   if(a <= 0.0 || i < 36) return 0;
   const double up = s * (close[i] - E288[i]) / a, sl = s * (E288[i] - E288[i - 36]) / a;
   if(up > 0.0 && sl > 0.0) return 1;
   if(up < 0.0 && sl < 0.0) return -1;
   return 0;
  }

void Signal(const int i, const int s, const string types, const bool live, const datetime &time[], const double &high[],
            const double &low[], const double &close[], const long &vol[])
  {
   if(i < InpMinBars) return;
   const double a = ATR[i];
   const int ctx = TrendCtx(i, s, close);
   if(InpTrend == TF_WITH && ctx != 1) return;
   if(InpTrend == TF_NOT_AGAINST && ctx == -1) return;
   const double st = Score(i, s, close);
   double va = 0.0; for(int m = i - 19; m <= i; m++) va += (double)vol[m]; va /= 20.0;
   const double vx = va > 0.0 ? (double)vol[i] / va : 0.0;
   double ext = (s > 0) ? DBL_MAX : -DBL_MAX;
   for(int m = i - 288; m <= i - 1; m++) ext = (s > 0) ? MathMin(ext, low[m]) : MathMax(ext, high[m]);
   const double d24 = (s > 0) ? (close[i] - ext) / a : (ext - close[i]) / a;
   const int tier = (st >= InpAStretch && vx >= InpAVol) ? 1 : ((st >= InpBStretch || d24 <= InpBNear24h) ? 2 : 3);
   const double yb = low[i] - 0.35 * a, ys = high[i] + 0.35 * a;
   if(tier == 1) { if(s > 0) ABuy[i] = yb; else ASell[i] = ys; }
   else if(tier == 2 && InpShowB) { if(s > 0) BBuy[i] = yb; else BSell[i] = ys; }
   else if(tier == 3 && InpShowC) { if(s > 0) CBuy[i] = yb; else CSell[i] = ys; }
   const string tl = tier == 1 ? "A" : (tier == 2 ? "B" : "C");
   double stop = 0.0;
   if(tier == 1)
     {
      stop = (s > 0) ? MathMin(low[i], MathMin(low[i - 1], low[i - 2])) - g_pip : MathMax(high[i], MathMax(high[i - 1], high[i - 2])) + g_pip;
      const string id = "SRA_" + IntegerToString(g_seq);
      if(InpDrawPlan)
        {
         const datetime x2 = time[i] + InpPlanBars * PeriodSeconds();
         const double tp = close[i] + s * InpTargetPips * g_pip;
         ObjectCreate(0, id + "_sl", OBJ_TREND, 0, time[i], stop, x2, stop);
         ObjectCreate(0, id + "_tp", OBJ_TREND, 0, time[i], tp, x2, tp);
         ObjectSetInteger(0, id + "_sl", OBJPROP_COLOR, clrOrangeRed); ObjectSetInteger(0, id + "_tp", OBJPROP_COLOR, clrLimeGreen);
         const string nm[2] = {"_sl", "_tp"};
         for(int k = 0; k < 2; k++)
           {
            ObjectSetInteger(0, id + nm[k], OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, id + nm[k], OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, id + nm[k], OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, id + nm[k], OBJPROP_HIDDEN, true);
            ObjectSetString(0, id + nm[k], OBJPROP_TOOLTIP, k == 0 ? "stop" : "+10 pips");
           }
        }
      const int old = g_seq - InpMaxMarks;
      if(old >= 0) ObjectsDeleteAll(0, "SRA_" + IntegerToString(old) + "_");
      g_seq++;
      g_lastA = StringFormat("%s %s (%s)", Tag(s), TimeToString(time[i], TIME_DATE | TIME_MINUTES), types);
     }
   if(tier <= 2 && InpLogLast > 0)
     {
      if(ArraySize(g_log) >= InpLogLast) ArrayRemove(g_log, 0, 1);
      const int z = ArraySize(g_log); ArrayResize(g_log, z + 1);
      g_log[z] = StringFormat("%s %s %s %-20s stretch %5.2f vol %4.2f d24 %5.2f", TimeToString(time[i], TIME_DATE | TIME_MINUTES),
                              Tag(s), tl, types, st, vx, d24);
     }
   if(live && ((tier == 1 && InpAlertA) || (tier == 2 && InpAlertB)))
      Notify(StringFormat("%s %s SWING %s %s (%s): stretch %.2f, volume %.1fx, %.1f ATR from 24h %s | close %.*f%s",
             _Symbol, EnumToString(Period()), tl, Tag(s), types, st, vx, d24, s > 0 ? "low" : "high", _Digits, close[i],
             tier == 1 ? StringFormat("  stop %.*f  target %.*f", _Digits, stop, _Digits, close[i] + s * InpTargetPips * g_pip) : ""));
  }

//+------------------------------------------------------------------+
//| S detector (research\trend_range_sweep.py): a bar wicks below the |
//| low of the last InpSBox bars, then that bar or one of the next    |
//| InpSRecl bars closes back above it (bullish). Shown only WITH the |
//| 24h trend, wick >= InpSDepth ATR and volume >= InpSVol x average. |
//| History: ~0.9/day, +20 before -10 in 30.9% / 30.3% (train/test)   |
//| vs 26.7% for random with-trend bars; break-even is 33%.           |
//+------------------------------------------------------------------+
bool RangeSweepS(const int d, const int s, const int i, const double &open[], const double &high[], const double &low[],
                 const double &close[], const long &vol[], double &outDep, double &outVx)
  {
   outDep = 0.0; outVx = 0.0;
   if(i < MathMax(InpMinBars, InpSBox + 40)) return false;
   const double a = ATR[i];
   if(a <= 0.0) return false;
   int k0 = -1; double dep = 0.0;
   bool fired = false;
   if(rs_k0[d] >= 0)
     {
      if(i - rs_k0[d] > InpSRecl) rs_k0[d] = -1;
      else if(TC(close, i, s) > rs_bot[d] && TC(close, i, s) > TO(open, i, s) && i - rs_last[d] >= GAP)
        { k0 = rs_k0[d]; dep = rs_dep[d]; fired = true; rs_k0[d] = -1; }
     }
   if(!fired)
     {
      double top = -DBL_MAX, bot = DBL_MAX;
      for(int j = i - InpSBox; j <= i - 1; j++) { top = MathMax(top, TH(high, low, j, s)); bot = MathMin(bot, TL(high, low, j, s)); }
      if(ATR[i - 1] > 0.0 && (top - bot) / ATR[i - 1] <= InpSMaxWidth && TL(high, low, i, s) < bot)
        {
         rs_k0[d] = i; rs_bot[d] = bot; rs_dep[d] = (bot - TL(high, low, i, s)) / a;
         if(TC(close, i, s) > bot && TC(close, i, s) > TO(open, i, s) && i - rs_last[d] >= GAP)
           { k0 = i; dep = rs_dep[d]; fired = true; rs_k0[d] = -1; }
        }
     }
   if(!fired) return false;
   rs_last[d] = i;
   double va = 0.0; for(int m = i - 19; m <= i; m++) va += (double)vol[m]; va /= 20.0;
   outVx = va > 0.0 ? (double)MathMax(vol[k0], vol[i]) / va : 0.0;
   outDep = dep;
   if(InpSWithTrend && TrendCtx(i, s, close) != 1) return false;
   return (dep >= InpSDepth && outVx >= InpSVol);
  }

//+------------------------------------------------------------------+
//| Mark one PATTERN signal (sweep and/or 1h trap) on bar i           |
//+------------------------------------------------------------------+
void MarkPattern(const int i, const int s, const string what, const double dep, const double vx, const bool live,
                 const datetime &time[], const double &high[], const double &low[], const double &close[])
  {
   if(!InpShowS) return;
   const double a = ATR[i];
   if(s > 0) SBuy[i] = low[i] - 0.6 * a; else SSell[i] = high[i] + 0.6 * a;
   const int ctx = TrendCtx(i, s, close);
   const string tr = ctx == 1 ? "with 24h trend" : (ctx == -1 ? "against 24h trend" : "24h trend mixed");
   const string det = StringLen(what) > 5 || what == "sweep" ? StringFormat("wick %.1f ATR, vol %.1fx", dep, vx) : "";
   g_lastS = StringFormat("%s %s %s", Tag(s), TimeToString(time[i], TIME_DATE | TIME_MINUTES), what);
   if(InpLogLast > 0)
     {
      if(ArraySize(g_log) >= InpLogLast) ArrayRemove(g_log, 0, 1);
      const int z = ArraySize(g_log); ArrayResize(g_log, z + 1);
      g_log[z] = StringFormat("%s %s PATTERN %-12s %s %s", TimeToString(time[i], TIME_DATE | TIME_MINUTES), Tag(s), what, det, tr);
     }
   if(live && InpAlertS)
      Notify(StringFormat("%s %s PATTERN %s (%s, %s) %s | close %.*f", _Symbol, EnumToString(Period()), Tag(s), what, tr, det, _Digits, close[i]));
  }

//+------------------------------------------------------------------+
void ProcessBar(const int i, const bool live, const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &vol[])
  {
   for(int d = 0; d < 2; d++)
     {
      const int s = (d == 0) ? 1 : -1;
      string types = "";
      // all detectors must update their state on every bar, so evaluate each one unconditionally
      const bool f30 = (d == 0) ? Trap(g_t30L, 6, s, i, open, high, low, close) : Trap(g_t30S, 6, s, i, open, high, low, close);
      const bool f60 = (d == 0) ? Trap(g_t60L, 12, s, i, open, high, low, close) : Trap(g_t60S, 12, s, i, open, high, low, close);
      const bool fsw = Sweep(d, s, i, open, high, low, close);
      const bool fre = Retest(d, s, i, open, high, low, close);
      const bool fch = Choch(d, s, i, high, low, close);
      double sdep, svx;
      const bool fS = RangeSweepS(d, s, i, open, high, low, close, vol, sdep, svx);
      // PATTERN = your setup: deep range sweep with volume and/or the 1h trap, any trend direction
      if(InpMode != MODE_RADAR && i >= InpMinBars && (fS || f60))
         MarkPattern(i, s, (fS && f60) ? "sweep+trap" : (fS ? "sweep" : "trap"), sdep, svx, live, time, high, low, close);
      if(InpMode == MODE_PATTERN) continue;                 // radar grades are hidden in pattern mode
      if(f30) types += "trap30+";
      if(f60) types += "trap60+";
      if(fsw) types += "sweep+";
      if(fre) types += "retest+";
      if(fch) types += "choch+";
      if(StringLen(types) == 0) continue;
      types = StringSubstr(types, 0, StringLen(types) - 1);
      Signal(i, s, types, live, time, high, low, close, vol);
     }
  }

//+------------------------------------------------------------------+
void GLine(const string nm, const int row, const string text, const color clr)
  {
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpGaugeX);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpGaugeY + 16 * (1 - row));
   ObjectSetString(0, nm, OBJPROP_TEXT, text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
  }

// setup quality if a pattern fired now: GOOD = would be A, OK = would be B, LOW = C
string Quality(const double st, const double vx, const double d24)
  {
   if(st >= InpAStretch && vx >= InpAVol) return "GOOD";
   if(st >= InpBStretch || d24 <= InpBNear24h) return "OK";
   return "LOW";
  }

void Gauge(const int f, const double &high[], const double &low[], const double &close[], const long &vol[])
  {
   if(!InpGauge || f < 300) { ObjectDelete(0, "SRA_g1"); ObjectDelete(0, "SRA_g2"); return; }
   double lo = DBL_MAX, hi = -DBL_MAX;
   for(int m = f - 288; m <= f - 1; m++) { lo = MathMin(lo, low[m]); hi = MathMax(hi, high[m]); }
   const double a = ATR[f];
   double va = 0.0; for(int m = f - 19; m <= f; m++) va += (double)vol[m]; va /= 20.0;
   const double vx = va > 0 ? (double)vol[f] / va : 0.0;
   const int cb = TrendCtx(f, 1, close);
   const string trend = cb == 1 ? "UP" : (cb == -1 ? "DOWN" : "mixed");
   const bool showB = (InpTrend == TF_OFF) || (InpTrend == TF_WITH ? cb == 1 : cb != -1);
   const bool showS = (InpTrend == TF_OFF) || (InpTrend == TF_WITH ? cb == -1 : cb != 1);
   const string qb = showB ? Quality(Score(f, 1, close), vx, (close[f] - lo) / a) : "off";
   const string qs = showS ? Quality(Score(f, -1, close), vx, (hi - close[f]) / a) : "off";
   const bool good = (qb == "GOOD" || qs == "GOOD");
   // readable on light and dark chart backgrounds
   const color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   const bool light = ((bg & 0xFF) + ((bg >> 8) & 0xFF) + ((bg >> 16) & 0xFF)) > 384;
   const color cHot = light ? clrDarkOrange : clrGold, cTxt = light ? clrDimGray : clrSilver;
   if(InpMode == MODE_PATTERN)
     {
      GLine("SRA_g1", 1, StringFormat("Pattern scanner  |  24h trend %s", trend), cTxt);
      GLine("SRA_g2", 0, "Last pattern: " + g_lastS, cTxt);
     }
   else
     {
      GLine("SRA_g1", 1, StringFormat("Swing Radar  24h trend %-5s  BUY: %-4s  SELL: %-4s", trend, qb, qs), good ? cHot : cTxt);
      GLine("SRA_g2", 0, "Last A: " + g_lastA + "   |   Last pattern: " + g_lastS, cTxt);
     }
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[], const double &open[],
                const double &high[], const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   if(InpOnlyM5 && Period() != PERIOD_M5)
     {
      if(prev_calculated <= 0)
        {
         ArrayInitialize(ABuy, EMPTY_VALUE); ArrayInitialize(ASell, EMPTY_VALUE); ArrayInitialize(BBuy, EMPTY_VALUE);
         ArrayInitialize(BSell, EMPTY_VALUE); ArrayInitialize(CBuy, EMPTY_VALUE); ArrayInitialize(CSell, EMPTY_VALUE); ArrayInitialize(SBuy, EMPTY_VALUE); ArrayInitialize(SSell, EMPTY_VALUE);
         ObjectsDeleteAll(0, "SRA_");
         ObjectCreate(0, "SRA_off", OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, "SRA_off", OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, "SRA_off", OBJPROP_XDISTANCE, InpGaugeX);
         ObjectSetInteger(0, "SRA_off", OBJPROP_YDISTANCE, InpGaugeY);
         ObjectSetInteger(0, "SRA_off", OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, "SRA_off", OBJPROP_COLOR, clrDimGray);
         ObjectSetString(0, "SRA_off", OBJPROP_TEXT, "Swing Radar: M5 only (switch to M5)");
         ObjectSetInteger(0, "SRA_off", OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, "SRA_off", OBJPROP_HIDDEN, true);
        }
      else
         for(int i = prev_calculated - 1; i < rates_total; i++) ABuy[i] = ASell[i] = BBuy[i] = BSell[i] = CBuy[i] = CSell[i] = SBuy[i] = SSell[i] = EMPTY_VALUE;
      return rates_total;
     }
   if(rates_total < 400) return 0;
   const bool historical = (prev_calculated <= 0);
   const int first = historical ? 0 : prev_calculated - 1;
   if(historical)
     {
      g_done = -1; g_seq = 0; g_lastA = "none yet"; g_lastS = "none yet";
      ArrayResize(g_t30L, 0); ArrayResize(g_t30S, 0); ArrayResize(g_t60L, 0); ArrayResize(g_t60S, 0); ArrayResize(g_log, 0);
      for(int d = 0; d < 2; d++)
        {
         ps_has[d] = false; ps_broke[d] = -1; ps_last[d] = -1000;
         pr_has[d] = false; pr_last[d] = -1000;
         rs_k0[d] = -1; rs_last[d] = -1000;
         ch_has[d] = false; ch_recent[d] = -1000000; ch_last[d] = -1000;
        }
      ObjectsDeleteAll(0, "SRA_");
     }
   const double k48 = 2.0 / 49.0, k288 = 2.0 / 289.0;
   for(int i = first; i < rates_total; i++)
     {
      ABuy[i] = ASell[i] = BBuy[i] = BSell[i] = CBuy[i] = CSell[i] = SBuy[i] = SSell[i] = EMPTY_VALUE;
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
   for(int i = MathMax(g_done + 1, 26); i <= rates_total - 2; i++)
      ProcessBar(i, !historical && i == rates_total - 2, time, open, high, low, close, tick_volume);
   g_done = rates_total - 2;
   if(historical && InpLogLast > 0)
     {
      PrintFormat("Swing Radar v4 on %s %s: %d bars. Last %d A/B/S signals:", _Symbol, EnumToString(Period()), rates_total, ArraySize(g_log));
      for(int k = 0; k < ArraySize(g_log); k++) Print("  ", g_log[k]);
      int na = 0;
      for(int k = 0; k < rates_total; k++) if(ABuy[k] != EMPTY_VALUE || ASell[k] != EMPTY_VALUE) na++;
      PrintFormat("diag: A arrows=%d, B shown=%d, C shown=%d, last A: %s, last S: %s", na, InpShowB, InpShowC, g_lastA, g_lastS);
     }
   Gauge(rates_total - 1, high, low, close, tick_volume);
   return rates_total;
  }
//+------------------------------------------------------------------+
