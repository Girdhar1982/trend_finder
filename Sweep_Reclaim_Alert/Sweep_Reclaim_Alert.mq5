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
//| v4.60 (12 Nov lesson: bought into a falling market, added 3x,     |
//| closed at the low): CONFIRM arrow = after a new 2h low, first     |
//| close above the last swing high (research\confirm_vs_early.py:    |
//| BUY +0.34p train / +1.08p test vs random -0.26 / -0.09; buying    |
//| the new low itself lost; sells lost -> off by default). Status    |
//| lines: turn state (WAIT / CONFIRMED), your open positions, an     |
//| "adding into new lows" size line (info only: those adds were your |
//| best trades, +203p, research\confirm_backtest.py) and a           |
//| round-number (.00) warning.                                       |
//| v4.70 higher timeframes (research\htf_direction.py): CONFIRM buys |
//| WITH an H4 uptrend ~0p; while H4 is pulled back (H4 close below a |
//| falling EMA20) +1.95p train / +4.17p test, 15/17 months positive  |
//| -> those are drawn as CONFIRM+. Status line shows H1/H4/D1.       |
//| v4.80 FLUSH (the user's daily pattern, alert so you can leave the |
//| laptop): an M15 candle closes above the last 1h high (breakout),  |
//| then within 1h an M5 bar drops >= 3 pips under that M15 candle's  |
//| low, and within 10 min an M5 bar closes back above the broken     |
//| level -> FLUSH BUY (sell = mirror). Popup + sound + phone push.   |
//| research\m15_break_flush.py: ~1/day; buys were not better than    |
//| random in testing - your own judgement makes the trade.           |
//| v4.90 RAPID (12 Nov 13:50-14:00 and 18:40 examples): price moves  |
//| >= max(12 pips, 2.5 ATR) within 10 min right after a new 2h       |
//| high/low. Checked on EVERY TICK, so the alert comes while the     |
//| move is happening, not after the bar closes. ~4-5/day.            |
//+------------------------------------------------------------------+
#property copyright "Sweep Reclaim Alert"
#property version   "4.90"
#property indicator_chart_window
#property indicator_buffers 20
#property indicator_plots   16

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
#property indicator_label9  "CONFIRM buy"
#property indicator_type9   DRAW_ARROW
#property indicator_color9  clrDarkViolet
#property indicator_width9  3
#property indicator_label10 "CONFIRM sell"
#property indicator_type10  DRAW_ARROW
#property indicator_color10 clrDarkViolet
#property indicator_width10 3
#property indicator_label11 "CONFIRM+ buy (H4 pulled back)"
#property indicator_type11  DRAW_ARROW
#property indicator_color11 clrMagenta
#property indicator_width11 5
#property indicator_label12 "CONFIRM+ sell (H4 bounced)"
#property indicator_type12  DRAW_ARROW
#property indicator_color12 clrMagenta
#property indicator_width12 5
#property indicator_label13 "FLUSH buy (M15 break, drop under, back above)"
#property indicator_type13  DRAW_ARROW
#property indicator_color13 clrTeal
#property indicator_width13 4
#property indicator_label14 "FLUSH sell (M15 break down, spike above, back below)"
#property indicator_type14  DRAW_ARROW
#property indicator_color14 clrCrimson
#property indicator_width14 4
#property indicator_label15 "RAPID drop after a new high"
#property indicator_type15  DRAW_ARROW
#property indicator_color15 clrMediumVioletRed
#property indicator_width15 3
#property indicator_label16 "RAPID jump after a new low"
#property indicator_type16  DRAW_ARROW
#property indicator_color16 clrNavy
#property indicator_width16 3

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
input int    InpGaugeY     = 25;     // Status Y (from the bottom)

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

input group "CONFIRM + discipline (12 Nov lesson: don't buy the falling knife)"
input bool   InpConfirm      = true;  // Show CONFIRM arrows (turn after a new 2h low)
input bool   InpConfirmSells = false; // Also CONFIRM sells (lost in testing)
input bool   InpConfirmPlan  = true;  // Draw stop (structure low - 1 pip) and +20 pip lines
input double InpConfirmTP    = 20.0;  // Target line, pips (as tested)
input bool   InpAlertConfirm = true;  // Alert on CONFIRM
input bool   InpPosPanel     = false; // Status lines for your open positions on this symbol
input double InpRoundWarn    = 10.0;  // Warn within N pips of a whole figure (.00), 0 = off
enum ENUM_KSHOW { KS_ALL = 0,  // All CONFIRMs (CONFIRM+ drawn bigger)
                  KS_PLUS = 1  // Only CONFIRM+ (H4 pulled back) - fewer, historically best
                };
input ENUM_KSHOW InpConfirmShow = KS_ALL; // Which CONFIRMs to show / alert
input bool   InpHTFLine      = true;  // Status line with H1 / H4 / D1 direction

enum ENUM_FLEVEL { FL_RES = 0,   // the broken 15m resistance / support
                   FL_M15 = 1    // the breakout M15 candle's low / high (fires more often)
                 };
input group "FLUSH: M15 breaks resistance -> M5 drops under that M15 low -> quick close back above"
input bool   InpFlush        = true;   // Detect FLUSH (works in every mode)
input bool   InpFlushBuys    = true;   // FLUSH buys
input bool   InpFlushSells   = true;   // FLUSH sells (mirror: M15 breaks support, spike above, close back below)
input int    InpFlushN       = 4;      // Resistance = high of the last N M15 candles (4 = 1 hour, 8 = 2 hours)
input double InpFlushDepth   = 3.0;    // Min drop under the breakout M15 candle's low, pips (0 = any)
input int    InpFlushWait    = 12;     // Drop must come within this many M5 bars after the break (12 = 1 hour)
input int    InpFlushRecl    = 2;      // Close back above within this many M5 bars after the drop bar (2 = 10 min)
input ENUM_FLEVEL InpFlushLevel = FL_RES; // Close back above what
input bool   InpFlushPlan    = true;   // Draw stop (drop low - 1 pip) and target lines
input double InpFlushTP      = 20.0;   // Target line, pips
input bool   InpAlertFlush   = true;   // Alert on FLUSH signal
input bool   InpAlertFlushPre = false; // Early heads-up alert when the drop happens (~8/day, gives you time to get to the screen)
input bool   InpFlushPhone   = true;   // FLUSH alerts also to phone (MetaQuotes ID set in Tools > Options > Notifications)

input group "RAPID: sudden drop / jump right after a breakout (alert while it happens)"
input bool   InpRapid        = true;   // Detect RAPID moves
input double InpRapidPips    = 12.0;   // Min move, pips ...
input double InpRapidATR     = 2.5;    // ... and at least this many ATR
input int    InpRapidBars    = 2;      // Within this many M5 bars (2 = 10 min, includes the forming bar)
input bool   InpRapidAfterBrk = true;  // Only right after a breakout (new high/low within the last hour)
input int    InpRapidBrkN    = 24;     // Breakout = new high/low of the last N bars (24 = 2 hours)
input bool   InpRapidLive    = true;   // Alert on the tick it happens (not only at bar close)
input bool   InpAlertRapid   = true;   // Alert on RAPID (phone: uses the FLUSH phone setting)

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
#define K_N2H      24     // CONFIRM: "new 2h low" window, bars
#define K_WITHIN   24     // CONFIRM: turn must come within this many bars of that low
#define K_HOLD     36     // CONFIRM: plan line length / 'recent' window, bars

const double MU48 = -1.5647647681, SD48 = 1.3383025567;
const double MU288 = -1.9859023515, SD288 = 5.7488277428;
const double MUDO = -2.6433684188, SDDO = 9.3743545638;

struct Pend { int push; double top; double bot; double a; int touch; };

double ABuy[], ASell[], BBuy[], BSell[], CBuy[], CSell[], SBuy[], SSell[], KBuy[], KSell[], K2Buy[], K2Sell[], FBuy[], FSell[], RDn[], RUp[];
// RAPID state per side (0 = drop after new high, 1 = jump after new low): last breakout bar, last fire, bar time already alerted
int    rp_brk[2]; int rp_last[2]; datetime rp_alerted[2];
string g_lastR = "none yet";
// FLUSH state per side (transformed prices): break bar, broken level, breakout M15 low, drop bar, lowest low since drop
int    fl_brk[2]; double fl_R[2]; double fl_BL[2]; int fl_drop[2]; double fl_low[2]; int fl_last[2];
string g_lastF = "none yet";
// higher-timeframe direction (closed HTF bars only): +1 close above a rising EMA, -1 below a falling EMA, 0 mixed
struct HTF { ENUM_TIMEFRAMES tf; int span; int slope; int n; datetime t[]; double c[]; double e[]; };
HTF    g_h1, g_h4, g_d1;
// CONFIRM state per side: last pivot high, bar of the last new 2h low, low already used, last fire, stop
bool   kc_has[2]; double kc_ph[2]; int kc_low[2]; int kc_used[2]; int kc_last[2]; double kc_stop[2];
int    g_kseq = 0;
string g_lastK = "none yet";
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
   SetIndexBuffer(8, KBuy, INDICATOR_DATA);  SetIndexBuffer(9, KSell, INDICATOR_DATA);
   SetIndexBuffer(10, K2Buy, INDICATOR_DATA); SetIndexBuffer(11, K2Sell, INDICATOR_DATA);
   SetIndexBuffer(12, FBuy, INDICATOR_DATA);  SetIndexBuffer(13, FSell, INDICATOR_DATA);
   SetIndexBuffer(14, RDn, INDICATOR_DATA);   SetIndexBuffer(15, RUp, INDICATOR_DATA);
   SetIndexBuffer(16, ATR, INDICATOR_CALCULATIONS);  SetIndexBuffer(17, E48, INDICATOR_CALCULATIONS);
   SetIndexBuffer(18, E288, INDICATOR_CALCULATIONS); SetIndexBuffer(19, DOpen, INDICATOR_CALCULATIONS);
   PlotIndexSetInteger(14, PLOT_ARROW, 171); PlotIndexSetInteger(15, PLOT_ARROW, 171);
   for(int p = 0; p < 16; p++) PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(12, PLOT_ARROW, 233); PlotIndexSetInteger(13, PLOT_ARROW, 234);
   PlotIndexSetInteger(6, PLOT_ARROW, 241); PlotIndexSetInteger(7, PLOT_ARROW, 242);
   PlotIndexSetInteger(8, PLOT_ARROW, 225); PlotIndexSetInteger(9, PLOT_ARROW, 226);
   PlotIndexSetInteger(10, PLOT_ARROW, 225); PlotIndexSetInteger(11, PLOT_ARROW, 226);
   g_h1.tf = PERIOD_H1; g_h1.span = 50; g_h1.slope = 5;
   g_h4.tf = PERIOD_H4; g_h4.span = 20; g_h4.slope = 3;
   g_d1.tf = PERIOD_D1; g_d1.span = 20; g_d1.slope = 3;
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
//| CONFIRM (research\confirm_vs_early.py, same bar-by-bar logic):    |
//| a bar makes a new 2h (24-bar) low; within 24 bars a bar closes    |
//| above the last confirmed swing high (3-bar pivot). Once per low.  |
//| Stop = lowest low since the 2h low - 1 pip. stopT = transformed.  |
//+------------------------------------------------------------------+
bool Confirm(const int d, const int s, const int i, const double &high[], const double &low[], const double &close[],
             double &stopT)
  {
   if(i < 30) return false;
   const int j = i - PIV_W;
   if(PivotHigh(j, s, high, low)) { kc_has[d] = true; kc_ph[d] = TH(high, low, j, s); }
   double mn = DBL_MAX;
   for(int m = i - K_N2H + 1; m <= i; m++) mn = MathMin(mn, TL(high, low, m, s));
   if(TL(high, low, i, s) <= mn) kc_low[d] = i;
   if(kc_has[d] && i - kc_low[d] <= K_WITHIN && TC(close, i, s) > kc_ph[d] && TC(close, i - 1, s) <= kc_ph[d]
      && i - kc_last[d] >= GAP && kc_used[d] != kc_low[d])
     {
      double lo = DBL_MAX;
      for(int m = kc_low[d]; m <= i; m++) lo = MathMin(lo, TL(high, low, m, s));
      stopT = lo; kc_last[d] = i; kc_used[d] = kc_low[d];
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Higher timeframes (same as research\htf_direction.py)             |
//+------------------------------------------------------------------+
bool HtfLoad(HTF &h, const int need)
  {
   const int cnt = MathMin(need, Bars(_Symbol, h.tf));
   if(cnt < h.span + h.slope + 5) return false;
   if(CopyTime(_Symbol, h.tf, 0, cnt, h.t) != cnt || CopyClose(_Symbol, h.tf, 0, cnt, h.c) != cnt) { h.n = 0; return false; }
   ArrayResize(h.e, cnt);
   const double k = 2.0 / (h.span + 1.0);
   h.e[0] = h.c[0];
   for(int m = 1; m < cnt; m++) h.e[m] = k * h.c[m] + (1.0 - k) * h.e[m - 1];
   h.n = cnt;
   return true;
  }

// direction from the last HTF bar that had CLOSED by time tc
int HtfDir(const HTF &h, const datetime tc)
  {
   if(h.n == 0) return 0;
   const datetime lim = tc - PeriodSeconds(h.tf);
   int lo = 0, hi = h.n - 1, k = -1;
   while(lo <= hi) { const int m = (lo + hi) / 2; if(h.t[m] <= lim) { k = m; lo = m + 1; } else hi = m - 1; }
   if(k < h.slope) return 0;
   if(h.c[k] > h.e[k] && h.e[k] > h.e[k - h.slope]) return 1;
   if(h.c[k] < h.e[k] && h.e[k] < h.e[k - h.slope]) return -1;
   return 0;
  }

string DirTxt(const int v) { return v > 0 ? "UP" : (v < 0 ? "DOWN" : "mixed"); }

bool kc_plus[2];

void MarkConfirm(const int i, const int s, const double stopT, const bool plus, const bool live, const datetime &time[],
                 const double &high[], const double &low[], const double &close[])
  {
   const double a = ATR[i];
   const double stop = (s > 0) ? stopT - g_pip : -stopT + g_pip;
   const double tp = close[i] + s * InpConfirmTP * g_pip;
   const double risk = s * (close[i] - stop) / g_pip;
   kc_stop[s > 0 ? 0 : 1] = stop;
   const string nmK = plus ? "CONFIRM+" : "CONFIRM";
   if(plus) { if(s > 0) K2Buy[i] = low[i] - 0.9 * a; else K2Sell[i] = high[i] + 0.9 * a; }
   else     { if(s > 0) KBuy[i] = low[i] - 0.9 * a;  else KSell[i] = high[i] + 0.9 * a; }
   if(InpConfirmPlan)
     {
      const string id = "SRA_K" + IntegerToString(g_kseq);
      const datetime x2 = time[i] + K_HOLD * PeriodSeconds();
      ObjectCreate(0, id + "_sl", OBJ_TREND, 0, time[i], stop, x2, stop);
      ObjectCreate(0, id + "_tp", OBJ_TREND, 0, time[i], tp, x2, tp);
      ObjectSetInteger(0, id + "_sl", OBJPROP_COLOR, clrOrangeRed); ObjectSetInteger(0, id + "_tp", OBJPROP_COLOR, clrSeaGreen);
      const string nm[2] = {"_sl", "_tp"};
      for(int k = 0; k < 2; k++)
        {
         ObjectSetInteger(0, id + nm[k], OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, id + nm[k], OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, id + nm[k], OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, id + nm[k], OBJPROP_HIDDEN, true);
         ObjectSetString(0, id + nm[k], OBJPROP_TOOLTIP, k == 0 ? "CONFIRM stop: structure broken below this" : "CONFIRM +20 pips");
        }
      const int old = g_kseq - InpMaxMarks;
      if(old >= 0) ObjectsDeleteAll(0, "SRA_K" + IntegerToString(old) + "_");
      g_kseq++;
     }
   g_lastK = StringFormat("%s %s %s stop %.*f", nmK, Tag(s), TimeToString(time[i], TIME_DATE | TIME_MINUTES), _Digits, stop);
   if(InpLogLast > 0)
     {
      if(ArraySize(g_log) >= InpLogLast) ArrayRemove(g_log, 0, 1);
      const int z = ArraySize(g_log); ArrayResize(g_log, z + 1);
      g_log[z] = StringFormat("%s %s %s close %.*f stop %.*f (%.1f pips)", TimeToString(time[i], TIME_DATE | TIME_MINUTES),
                              Tag(s), nmK, _Digits, close[i], _Digits, stop, risk);
     }
   if(live && InpAlertConfirm)
      Notify(StringFormat("%s %s %s %s: turn after new 2h %s%s | close %.*f  stop %.*f (%.1f pips)  target %.*f",
             _Symbol, EnumToString(Period()), nmK, Tag(s), s > 0 ? "low" : "high",
             plus ? (s > 0 ? ", H4 pulled back" : ", H4 bounced") : "", _Digits, close[i], _Digits, stop, risk, _Digits, tp));
  }

//+------------------------------------------------------------------+
//| FLUSH (research\m15_break_flush.py, same bar-by-bar logic).       |
//| Buy side in transformed prices (sell = mirror):                   |
//|  1. an M15 candle (3 M5 bars) closes above the high of the        |
//|     previous InpFlushN M15 candles, previous M15 close was not    |
//|  2. within InpFlushWait M5 bars an M5 low goes under that M15     |
//|     candle's low by >= InpFlushDepth pips                         |
//|  3. that bar or one of the next InpFlushRecl bars closes back     |
//|     above the broken level -> signal. Stop = lowest low - 1 pip.  |
//| Returns 0 nothing, 1 the drop happened on this bar, 2 signal.     |
//+------------------------------------------------------------------+
int g_fseq = 0;
int Flush(const int d, const int s, const int i, const datetime &time[], const double &high[], const double &low[],
          const double &close[], double &stopT, double &outR, int &outBrk)
  {
   if(i < 3 * InpFlushN + 10) return 0;
   int ev = 0;
   if(fl_brk[d] >= 0)
     {
      if(fl_drop[d] < 0)
        {
         if(i - fl_brk[d] > InpFlushWait) fl_brk[d] = -1;
         else if(TL(high, low, i, s) < fl_BL[d] - InpFlushDepth * g_pip) { fl_drop[d] = i; fl_low[d] = TL(high, low, i, s); ev = 1; }
        }
      else fl_low[d] = MathMin(fl_low[d], TL(high, low, i, s));
      if(fl_brk[d] >= 0 && fl_drop[d] >= 0)
        {
         if(i - fl_drop[d] <= InpFlushRecl)
           {
            const double lv = (InpFlushLevel == FL_RES) ? fl_R[d] : fl_BL[d];
            if(TC(close, i, s) > lv && i > fl_last[d])
              {
               stopT = fl_low[d]; outR = fl_R[d]; outBrk = fl_brk[d];
               fl_last[d] = i; fl_brk[d] = -1; fl_drop[d] = -1;
               return 2;
              }
           }
         else { fl_brk[d] = -1; fl_drop[d] = -1; }
        }
     }
   // a new M15 candle closed on bar i (3 consecutive M5 bars ending at :10/:25/:40/:55)
   const int ps = PeriodSeconds();
   if(fl_drop[d] < 0 && (time[i] + ps) % 900 == 0 && time[i] - time[i - 2] == 2 * ps)
     {
      double R = -DBL_MAX;
      for(int m = i - 2 - 3 * InpFlushN; m <= i - 3; m++) R = MathMax(R, TH(high, low, m, s));
      const double bl = MathMin(TL(high, low, i, s), MathMin(TL(high, low, i - 1, s), TL(high, low, i - 2, s)));
      // the M15 candle must trade through the level (a gap open over it, e.g. Monday, is not a break)
      if(TC(close, i, s) > R && TC(close, i - 3, s) <= R && bl <= R)
        { fl_brk[d] = i; fl_R[d] = R; fl_drop[d] = -1; fl_BL[d] = bl; }
     }
   return ev;
  }

void FNotify(const string msg)
  {
   Print(msg);
   if(InpPopup) Alert(msg);
   if(InpPhone || InpFlushPhone) SendNotification(msg);
   if(StringLen(InpSound) > 0) PlaySound(InpSound);
  }

void MarkFlush(const int i, const int s, const double stopT, const double R, const int brk, const bool live,
               const datetime &time[], const double &high[], const double &low[], const double &close[])
  {
   const double a = ATR[i];
   if(s > 0) FBuy[i] = low[i] - 0.75 * a; else FSell[i] = high[i] + 0.75 * a;
   const double stop = s * stopT - s * g_pip, lvl = s * R, lo = s * stopT;
   const double tp = close[i] + s * InpFlushTP * g_pip;
   const double risk = s * (close[i] - stop) / g_pip;
   const string brkT = TimeToString(time[brk] + PeriodSeconds(), TIME_MINUTES);
   if(InpFlushPlan)
     {
      const string id = "SRA_F" + IntegerToString(g_fseq);
      const datetime x2 = time[i] + K_HOLD * PeriodSeconds();
      ObjectCreate(0, id + "_sl", OBJ_TREND, 0, time[i], stop, x2, stop);
      ObjectCreate(0, id + "_tp", OBJ_TREND, 0, time[i], tp, x2, tp);
      ObjectCreate(0, id + "_lv", OBJ_TREND, 0, time[brk - 2], lvl, time[i], lvl);
      ObjectSetInteger(0, id + "_sl", OBJPROP_COLOR, clrOrangeRed); ObjectSetInteger(0, id + "_tp", OBJPROP_COLOR, clrSeaGreen);
      ObjectSetInteger(0, id + "_lv", OBJPROP_COLOR, s > 0 ? clrTeal : clrCrimson);
      const string nm[3] = {"_sl", "_tp", "_lv"};
      for(int k = 0; k < 3; k++)
        {
         ObjectSetInteger(0, id + nm[k], OBJPROP_STYLE, k == 2 ? STYLE_SOLID : STYLE_DOT);
         ObjectSetInteger(0, id + nm[k], OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, id + nm[k], OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, id + nm[k], OBJPROP_HIDDEN, true);
        }
      ObjectSetString(0, id + "_sl", OBJPROP_TOOLTIP, "FLUSH stop: drop extreme - 1 pip");
      ObjectSetString(0, id + "_tp", OBJPROP_TOOLTIP, "FLUSH target");
      ObjectSetString(0, id + "_lv", OBJPROP_TOOLTIP, s > 0 ? "15m resistance that broke" : "15m support that broke");
      const int old = g_fseq - InpMaxMarks;
      if(old >= 0) ObjectsDeleteAll(0, "SRA_F" + IntegerToString(old) + "_");
      g_fseq++;
     }
   g_lastF = StringFormat("%s %s (level %.*f)", Tag(s), TimeToString(time[i], TIME_DATE | TIME_MINUTES), _Digits, lvl);
   if(InpLogLast > 0)
     {
      if(ArraySize(g_log) >= InpLogLast) ArrayRemove(g_log, 0, 1);
      const int z = ArraySize(g_log); ArrayResize(g_log, z + 1);
      g_log[z] = StringFormat("%s %s FLUSH  M15 break %s level %.*f, %s %.*f, close %.*f stop %.*f (%.1f pips)",
                              TimeToString(time[i], TIME_DATE | TIME_MINUTES), Tag(s), brkT, _Digits, lvl,
                              s > 0 ? "low" : "high", _Digits, lo, _Digits, close[i], _Digits, stop, risk);
     }
   if(live && InpAlertFlush)
      FNotify(StringFormat("%s FLUSH %s: M15 broke %s %.*f at %s, %s to %.*f, closed back %s | close %.*f stop %.*f (%.1fp) target %.*f",
              _Symbol, Tag(s), s > 0 ? "above" : "below", _Digits, lvl, brkT, s > 0 ? "dropped" : "spiked", _Digits, lo,
              s > 0 ? "above" : "below", _Digits, close[i], _Digits, stop, risk, _Digits, tp));
  }

//+------------------------------------------------------------------+
//| RAPID. Side d=0 watches DROPS after a new high (s=+1 transformed),|
//| d=1 watches JUMPS after a new low (mirror).                      |
//| Move = highest high of the last InpRapidBars bars minus the low   |
//| (closed bar) or minus the current price (forming bar, live).      |
//+------------------------------------------------------------------+
double RapidMove(const int s, const int i, const bool closed, const double &open[], const double &high[],
                 const double &low[], const double &close[])
  {
   const int N = MathMax(1, InpRapidBars);
   double top = -DBL_MAX;
   for(int m = i - N + 1; m <= i; m++) top = MathMax(top, TH(high, low, m, s));
   if(closed)
     {
      // this bar made the top and closed up: its low came BEFORE its high, so measure from the earlier bars
      if(TH(high, low, i, s) >= top && TO(open, i, s) <= TC(close, i, s))
        {
         if(N == 1) return 0.0;
         top = -DBL_MAX;
         for(int m = i - N + 1; m <= i - 1; m++) top = MathMax(top, TH(high, low, m, s));
        }
      return (top - TL(high, low, i, s)) / g_pip;
     }
   return (top - TC(close, i, s)) / g_pip;
  }

bool RapidBrk(const int d, const int s, const int i, const double &high[], const double &low[])
  {
   if(!InpRapidAfterBrk) return true;
   double mx = -DBL_MAX;
   for(int m = i - InpRapidBrkN; m <= i - 1; m++) mx = MathMax(mx, TH(high, low, m, s));
   if(TH(high, low, i, s) > mx) return true;
   return rp_brk[d] >= i - MathMax(1, InpRapidBars) + 1 - 12;
  }

double RapidThr(const int i) { return MathMax(InpRapidPips, InpRapidATR * ATR[i - 1] / g_pip); }

void RapidAlert(const int d, const int s, const int i, const double mv, const bool atClose, const datetime &time[],
                const double &high[], const double &low[], const double &close[])
  {
   double top = -DBL_MAX;
   for(int m = i - MathMax(1, InpRapidBars) + 1; m <= i; m++) top = MathMax(top, TH(high, low, m, s));
   FNotify(StringFormat("%s RAPID %s: %.1f pips in %d min (%.1fx ATR)%s from %.*f | now %.*f%s", _Symbol, s > 0 ? "DROP" : "JUMP",
           mv, 5 * MathMax(1, InpRapidBars), mv * g_pip / ATR[i - 1],
           InpRapidAfterBrk ? (s > 0 ? " right after a new 2h high" : " right after a new 2h low") : "",
           _Digits, s * top, _Digits, close[i], atClose ? " (bar closed)" : " (bar still forming)"));
   rp_alerted[d] = time[i];
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
      double kst = 0.0;
      const bool fK = Confirm(d, s, i, high, low, close, kst);
      if(fK)
        {
         // CONFIRM+ = the H4 trend points AGAINST the trade (buy while H4 is pulled back)
         const bool plus = HtfDir(g_h4, time[i] + PeriodSeconds()) * s == -1;
         kc_plus[d] = plus;
         if(InpConfirm && i >= InpMinBars && (s > 0 || InpConfirmSells) && (plus || InpConfirmShow == KS_ALL))
            MarkConfirm(i, s, kst, plus, live, time, high, low, close);
        }
      // RAPID on the closed bar (history arrows; alert here only if the live tick alert did not already fire)
      if(i > InpRapidBrkN + 2)
        {
         const bool rb = RapidBrk(d, s, i, high, low);
         double mx = -DBL_MAX;
         for(int m = i - InpRapidBrkN; m <= i - 1; m++) mx = MathMax(mx, TH(high, low, m, s));
         if(TH(high, low, i, s) > mx) rp_brk[d] = i;
         if(InpRapid && i >= InpMinBars && rb && i - rp_last[d] > InpRapidBars)
           {
            const double mv = RapidMove(s, i, true, open, high, low, close);
            if(mv >= RapidThr(i))
              {
               rp_last[d] = i;
               const double a = ATR[i];
               if(s > 0) RDn[i] = high[i] + 0.5 * a; else RUp[i] = low[i] - 0.5 * a;
               g_lastR = StringFormat("%s %s %.1fp", s > 0 ? "DROP" : "JUMP", TimeToString(time[i], TIME_DATE | TIME_MINUTES), mv);
               if(InpLogLast > 0)
                 {
                  if(ArraySize(g_log) >= InpLogLast) ArrayRemove(g_log, 0, 1);
                  const int z = ArraySize(g_log); ArrayResize(g_log, z + 1);
                  g_log[z] = StringFormat("%s RAPID %s %.1f pips in %d min (%.1fx ATR)", TimeToString(time[i], TIME_DATE | TIME_MINUTES),
                                          s > 0 ? "DROP" : "JUMP", mv, 5 * InpRapidBars, mv * g_pip / ATR[i - 1]);
                 }
               if(live && InpAlertRapid && rp_alerted[d] != time[i]) RapidAlert(d, s, i, mv, true, time, high, low, close);
              }
           }
        }
      // FLUSH: state updates every bar; arrows/alerts only for enabled sides
      double fst = 0.0, fR = 0.0; int fbrk = -1;
      const int fev = Flush(d, s, i, time, high, low, close, fst, fR, fbrk);
      if(InpFlush && (s > 0 ? InpFlushBuys : InpFlushSells) && i >= InpMinBars)
        {
         if(fev == 2) MarkFlush(i, s, fst, fR, fbrk, live, time, high, low, close);
         else if(fev == 1 && live && InpAlertFlushPre)
            FNotify(StringFormat("%s FLUSH watch %s: M15 broke %s %.*f, now %.1f pips %s the M15 %s. Signal if an M5 bar closes back %s %.*f in the next %d min",
                    _Symbol, Tag(s), s > 0 ? "above" : "below", _Digits, s * fl_R[d], (fl_BL[d] - fl_low[d]) / g_pip,
                    s > 0 ? "under" : "over", s > 0 ? "low" : "high", s > 0 ? "above" : "below", _Digits,
                    s * (InpFlushLevel == FL_RES ? fl_R[d] : fl_BL[d]), 5 * InpFlushRecl));
        }
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
#define D_ROWS 6
#define PANEL_CHARS 78
// panel palette (fixed dark card, high contrast on light or dark charts)
#define P_BG     C'22,27,38'
#define P_BORDER C'60,70,90'
#define P_TITLE  C'120,185,255'   // headings
#define P_TXT    C'200,208,220'   // neutral info
#define P_OK     C'70,215,130'    // confirmed / good
#define P_WARN   C'255,175,50'    // wait / caution
#define P_ALERT  C'255,95,95'     // warning
void GLine(const string nm, const int row, const string text, const color clr)
  {
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpGaugeX);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
     }
   // anchored bottom-right: row 1 (title) is the highest line, row -6 the lowest
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpGaugeY + 16 * (row + 1 + D_ROWS));
   // fixed-width card: clip to the chart width, pad so every row has the same box
   int w = (int)((ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) - 2 * InpGaugeX - 12) / 7);
   w = MathMax(20, MathMin(PANEL_CHARS, w));
   string t = " " + text;
   if(StringLen(t) > w - 1) t = StringSubstr(t, 0, w - 3) + "..";
   while(StringLen(t) < w) t += " ";
   ObjectSetString(0, nm, OBJPROP_TEXT, t);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   // opaque dark card + front layer: readable over candles, profile bars and lines on any chart theme
   ObjectSetInteger(0, nm, OBJPROP_BACK, false);
   ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, P_BG);
   ObjectSetInteger(0, nm, OBJPROP_BORDER_COLOR, P_BORDER);
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
   const color cHot = P_OK, cTxt = P_TXT;
   if(InpMode == MODE_PATTERN)
     {
      GLine("SRA_g1", 1, StringFormat("Pattern scanner  |  24h trend %s", trend), P_TITLE);
      GLine("SRA_g2", 0, "Last pattern: " + g_lastS, cTxt);
     }
   else
     {
      GLine("SRA_g1", 1, StringFormat("Swing Radar  24h trend %-5s  BUY: %-4s  SELL: %-4s", trend, qb, qs), good ? cHot : cTxt);
      GLine("SRA_g2", 0, "Last A: " + g_lastA + "   |   Last pattern: " + g_lastS, cTxt);
     }
  }

//+------------------------------------------------------------------+
//| Discipline lines (stacked under the status lines, no gaps)        |
//+------------------------------------------------------------------+
string g_rt[]; color g_rc[];
void Row(const string nm, const int row, const string text, const color clr)
  {
   if(StringLen(text) == 0) return;
   const int z = ArraySize(g_rt); ArrayResize(g_rt, z + 1); ArrayResize(g_rc, z + 1);
   g_rt[z] = text; g_rc[z] = clr;
  }

void Discipline(const int rates_total, const datetime &time[], const double &high[], const double &low[], const double &close[])
  {
   if(!InpGauge || rates_total < 300) { ObjectsDeleteAll(0, "SRA_d"); return; }
   ArrayResize(g_rt, 0); ArrayResize(g_rc, 0);
   const int L = rates_total - 2;                       // last closed bar
   const color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   const bool light = ((bg & 0xFF) + ((bg >> 8) & 0xFF) + ((bg >> 16) & 0xFF)) > 384;
   const color cHot = P_WARN, cTxt = P_TXT, cOk = P_OK;
   // 0) higher-timeframe direction (closed bars)
   if(InpHTFLine)
     {
      const datetime now = time[L] + PeriodSeconds();
      const int v1 = HtfDir(g_h1, now), v4 = HtfDir(g_h4, now), vd = HtfDir(g_d1, now);
      string hint = "";
      color ch = cTxt;
      if(v4 < 0) { hint = "H4 pulled back: buy turns here were best (CONFIRM+)"; ch = cOk; }
      else if(v4 > 0) hint = "H4 up: CONFIRM buys ~flat; your sells vs H4 up lost -70p";
      else hint = "H4 mixed";
      Row("", 0, StringFormat("HTF  H1 %s  H4 %s  D1 %s  |  %s", DirTxt(v1), DirTxt(v4), DirTxt(vd), hint), ch);
     }
   // 1) turn state on the buy side
   string t1 = "";
   color c1 = cTxt;
   if(InpConfirm)
     {
      if(L - kc_low[0] <= K_WITHIN && kc_used[0] != kc_low[0])
        {
         t1 = StringFormat("BUY: WAIT - new 2h low %.*f made %d bars ago; CONFIRM = close above %.*f", _Digits, low[kc_low[0]],
                           L - kc_low[0], _Digits, kc_ph[0]);
         c1 = cHot;
        }
      else if(L - kc_last[0] <= K_HOLD)
        {
         t1 = StringFormat("BUY: %s %s - structure stop %.*f", kc_plus[0] ? "CONFIRM+ (H4 pulled back)" : "CONFIRMED",
                           TimeToString(time[kc_last[0]], TIME_MINUTES), _Digits, kc_stop[0]);
         c1 = cOk;
        }
      else t1 = "BUY: no fresh pullback turn  |  last CONFIRM: " + g_lastK;
     }
   Row("SRA_d1", -1, t1, c1);
   // 1b) FLUSH watcher state
   if(InpFlush)
     {
      string tf = "";
      color cf = cTxt;
      for(int d = 0; d < 2; d++)
        {
         const int s = d == 0 ? 1 : -1;
         if(!(s > 0 ? InpFlushBuys : InpFlushSells) || fl_brk[d] < 0) continue;
         const double lv = s * (InpFlushLevel == FL_RES ? fl_R[d] : fl_BL[d]);
         if(StringLen(tf) > 0) tf += "  |  ";
         if(fl_drop[d] < 0)
            tf += StringFormat("FLUSH %s: M15 broke %s %.*f - waiting for a drop %s %.*f until %s", Tag(s), s > 0 ? "above" : "below",
                               _Digits, s * fl_R[d], s > 0 ? "under" : "over", _Digits, s * fl_BL[d] - s * InpFlushDepth * g_pip,
                               TimeToString(time[fl_brk[d]] + (InpFlushWait + 1) * PeriodSeconds(), TIME_MINUTES));
         else
           {
            tf += StringFormat("FLUSH %s: %s to %.*f - signal if a bar closes %s %.*f by %s", Tag(s), s > 0 ? "dropped" : "spiked",
                               _Digits, s * fl_low[d], s > 0 ? "above" : "below", _Digits, lv,
                               TimeToString(time[fl_drop[d]] + (InpFlushRecl + 1) * PeriodSeconds(), TIME_MINUTES));
            cf = cHot;
           }
        }
      if(StringLen(tf) == 0) tf = "FLUSH: no M15 break pending  |  last FLUSH: " + g_lastF;
      Row("", 0, tf, cf);
     }
   // 2) your positions on this symbol
   string t2 = "", t3 = "";
   if(InpPosPanel)
     {
      int nb = 0, ns = 0; double vb = 0, vs = 0, pb = 0, ps = 0, prof = 0;
      datetime lb = 0, ls = 0;
      for(int k = PositionsTotal() - 1; k >= 0; k--)
        {
         if(PositionGetSymbol(k) != _Symbol) continue;
         const double v = PositionGetDouble(POSITION_VOLUME), p = PositionGetDouble(POSITION_PRICE_OPEN);
         const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
         prof += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { nb++; vb += v; pb += v * p; if(t > lb) lb = t; }
         else { ns++; vs += v; ps += v * p; if(t > ls) ls = t; }
        }
      if(nb + ns > 0)
        {
         const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(nb > 0) t2 += StringFormat("BUYS %d x %.2f lots avg %.*f (%+.1fp)  ", nb, vb, _Digits, pb / vb, (bid - pb / vb) / g_pip);
         if(ns > 0) t2 += StringFormat("SELLS %d x %.2f lots avg %.*f (%+.1fp)  ", ns, vs, _Digits, ps / vs, (ps / vs - ask) / g_pip);
         t2 += StringFormat("P/L %.2f %s", prof, AccountInfoString(ACCOUNT_CURRENCY));
         // 3) add guard: still falling (WAIT state), or under water with no CONFIRM since your last entry
         for(int d = 0; d < 2; d++)
           {
            const datetime lt = d == 0 ? lb : ls;
            if(lt == 0) continue;
            const int sh = iBarShift(_Symbol, _Period, lt, false);
            if(sh < 0) continue;
            const int ib = rates_total - 1 - sh;
            const bool falling = (L - kc_low[d] <= K_WITHIN && kc_used[d] != kc_low[d]);
            const bool under = d == 0 ? bid < pb / vb : ask > ps / vs;
            const bool confirmedSince = kc_last[d] >= ib;
            // information only: on the user's own deals (1 Oct-12 Nov) these adds made +203p, 77% win
            if(falling || (under && !confirmedSince))
               t3 += StringFormat("Adding %s: %d open, %.2f lots (%s). Size so you can hold; turn = close %s %.*f  ",
                                  d == 0 ? "into new lows" : "into new highs", d == 0 ? nb : ns, d == 0 ? vb : vs,
                                  falling ? (d == 0 ? "still making new 2h lows" : "still making new 2h highs")
                                          : "under water since " + TimeToString(lt, TIME_MINUTES),
                                  d == 0 ? "above" : "below", _Digits, d == 0 ? kc_ph[0] : -kc_ph[1]);
           }
        }
     }
   Row("SRA_d2", -2, t2, cTxt);
   Row("SRA_d3", -3, t3, cTxt);
   // 4) whole-figure warning
   string t4 = "";
   if(InpRoundWarn > 0.0)
     {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), fig = 100.0 * g_pip;
      const double up = MathCeil(bid / fig) * fig, dn = MathFloor(bid / fig) * fig;
      const double du = (up - bid) / g_pip, dd = (bid - dn) / g_pip;
      if(du <= InpRoundWarn && du <= dd)
         t4 = StringFormat("%.*f is %.1fp above: longs take profit / trail - whole figures often spike and reverse", _Digits, up, du);
      else if(dd <= InpRoundWarn)
         t4 = StringFormat("%.*f is %.1fp below: shorts take profit / trail - whole figures often spike and reverse", _Digits, dn, dd);
     }
   Row("SRA_d4", -4, t4, P_ALERT);
   for(int r = 0; r < D_ROWS; r++)
     {
      const string nm = "SRA_d" + IntegerToString(r);
      if(r < ArraySize(g_rt)) GLine(nm, -1 - r, g_rt[r], g_rc[r]); else ObjectDelete(0, nm);
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
         ArrayInitialize(KBuy, EMPTY_VALUE); ArrayInitialize(KSell, EMPTY_VALUE);
         ArrayInitialize(K2Buy, EMPTY_VALUE); ArrayInitialize(K2Sell, EMPTY_VALUE); ArrayInitialize(FBuy, EMPTY_VALUE); ArrayInitialize(FSell, EMPTY_VALUE); ArrayInitialize(RDn, EMPTY_VALUE); ArrayInitialize(RUp, EMPTY_VALUE);
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
         for(int i = prev_calculated - 1; i < rates_total; i++) ABuy[i] = ASell[i] = BBuy[i] = BSell[i] = CBuy[i] = CSell[i] = SBuy[i] = SSell[i] = KBuy[i] = KSell[i] = K2Buy[i] = K2Sell[i] = FBuy[i] = FSell[i] = RDn[i] = RUp[i] = EMPTY_VALUE;
      return rates_total;
     }
   if(rates_total < 400) return 0;
   // higher-timeframe data: reload whenever a new M5 bar has closed (H4 is needed for CONFIRM+ grading)
   if(prev_calculated <= 0 || rates_total - 2 > g_done)
     {
      static int tries = 0;
      const int sec = (int)(time[rates_total - 1] - time[0]);
      const bool ok4 = HtfLoad(g_h4, sec / PeriodSeconds(PERIOD_H4) + 200);
      HtfLoad(g_h1, sec / PeriodSeconds(PERIOD_H1) + 200);
      HtfLoad(g_d1, sec / PeriodSeconds(PERIOD_D1) + 100);
      if(!ok4 && prev_calculated <= 0 && tries++ < 20) return 0;   // H4 history still loading - try again next tick
      if(!ok4 && prev_calculated <= 0) Print("Swing Radar: H4 history unavailable - CONFIRM+ grading off");
     }
   const bool historical = (prev_calculated <= 0);
   const int first = historical ? 0 : prev_calculated - 1;
   if(historical)
     {
      g_done = -1; g_seq = 0; g_lastA = "none yet"; g_lastS = "none yet"; g_kseq = 0; g_lastK = "none yet"; g_fseq = 0; g_lastF = "none yet"; g_lastR = "none yet";
      ArrayResize(g_t30L, 0); ArrayResize(g_t30S, 0); ArrayResize(g_t60L, 0); ArrayResize(g_t60S, 0); ArrayResize(g_log, 0);
      for(int d = 0; d < 2; d++)
        {
         ps_has[d] = false; ps_broke[d] = -1; ps_last[d] = -1000;
         pr_has[d] = false; pr_last[d] = -1000;
         rs_k0[d] = -1; rs_last[d] = -1000;
         ch_has[d] = false; ch_recent[d] = -1000000; ch_last[d] = -1000;
         kc_has[d] = false; kc_ph[d] = 0.0; kc_low[d] = -1000000; kc_used[d] = -1; kc_last[d] = -1000000; kc_stop[d] = 0.0;
         kc_plus[d] = false;
         rp_brk[d] = -1000000; rp_last[d] = -1000; rp_alerted[d] = 0;
         fl_brk[d] = -1; fl_drop[d] = -1; fl_last[d] = -1000; fl_R[d] = 0.0; fl_BL[d] = 0.0; fl_low[d] = 0.0;
        }
      ObjectsDeleteAll(0, "SRA_");
     }
   const double k48 = 2.0 / 49.0, k288 = 2.0 / 289.0;
   for(int i = first; i < rates_total; i++)
     {
      ABuy[i] = ASell[i] = BBuy[i] = BSell[i] = CBuy[i] = CSell[i] = SBuy[i] = SSell[i] = KBuy[i] = KSell[i] = K2Buy[i] = K2Sell[i] = FBuy[i] = FSell[i] = RDn[i] = RUp[i] = EMPTY_VALUE;
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
   // RAPID live: check the forming bar on every tick
   if(!historical && InpRapid && InpRapidLive && InpAlertRapid && rates_total - 1 >= InpMinBars)
     {
      const int f = rates_total - 1;
      for(int d = 0; d < 2; d++)
        {
         const int s = (d == 0) ? 1 : -1;
         if(rp_alerted[d] == time[f] || f - rp_last[d] <= InpRapidBars - 1 || !RapidBrk(d, s, f, high, low)) continue;
         const double mv = RapidMove(s, f, false, open, high, low, close);
         if(mv >= RapidThr(f)) RapidAlert(d, s, f, mv, false, time, high, low, close);
        }
     }
   if(historical && InpLogLast > 0)
     {
      PrintFormat("Swing Radar v4 on %s %s: %d bars. Last %d A/B/S signals:", _Symbol, EnumToString(Period()), rates_total, ArraySize(g_log));
      for(int k = 0; k < ArraySize(g_log); k++) Print("  ", g_log[k]);
      int na = 0;
      for(int k = 0; k < rates_total; k++) if(ABuy[k] != EMPTY_VALUE || ASell[k] != EMPTY_VALUE) na++;
      PrintFormat("diag: A arrows=%d, B shown=%d, C shown=%d, last A: %s, last S: %s, last CONFIRM: %s, last FLUSH: %s, last RAPID: %s", na, InpShowB, InpShowC,
                  g_lastA, g_lastS, g_lastK, g_lastF, g_lastR);
     }
   Gauge(rates_total - 1, high, low, close, tick_volume);
   Discipline(rates_total, time, high, low, close);
   return rates_total;
  }
//+------------------------------------------------------------------+
