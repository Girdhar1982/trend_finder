//+------------------------------------------------------------------+
//|                                       QuantRegimeConfluence.mq5  |
//|          Statistical Regime + Multi-Timeframe Confluence Engine  |
//+==================================================================+
//|                                                                  |
//|                  ORIENTATION FOR FUTURE MAINTAINERS              |
//|                  (human or AI - read this first)                 |
//|                                                                  |
//| WHAT THIS IS                                                     |
//| A non-repainting MT5 signal indicator. It does NOT use RSI/MA    |
//| threshold crossings. Every input feature is a STATISTIC WITH A   |
//| KNOWN NULL DISTRIBUTION under a random walk, so each reading     |
//| answers "how surprising is this versus noise?" rather than       |
//| "is this line above that line?".                                 |
//|                                                                  |
//| The pipeline, in order (all inside OnCalculate):                 |
//|                                                                  |
//|   [1] BuildTFCtx()      per-timeframe raw series + feature       |
//|                         series, rebuilt only on a NEW BAR of     |
//|                         that timeframe (not per tick)            |
//|   [2] MapClosedIndex()  map chart bar i -> last CLOSED mid/high  |
//|                         timeframe bar  <-- NON-REPAINT CORE      |
//|   [3] ClassifyRegime()  4 statistics -> 3 linear discriminants   |
//|                         -> softmax -> argmax + confidence        |
//|   [4] direction gate    high timeframe decides LONG/SHORT/FLAT   |
//|   [5] trigger           chart-timeframe pullback + ignition      |
//|   [6] SignalScore()     10 features -> logistic -> 0..100        |
//|   [7] risk              ATR x regime volatility -> SL/TP         |
//|   [8] UpdateOpenSignals() forward-resolve past signals for the   |
//|                         win/loss panel                           |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| INVARIANT 1 - NEVER READ THE FORMING BAR                         |
//| The evaluation loop is  for(i = start; i <= rates_total-2; i++). |
//| Index rates_total-1 is the forming bar: it is cleared to         |
//| EMPTY_VALUE every tick and NEVER scored. If you change the loop  |
//| bound to rates_total-1 the indicator will repaint. Do not.       |
//|                                                                  |
//| INVARIANT 2 - HIGHER TIMEFRAMES MUST BE CLOSED                   |
//| MapClosedIndex() returns the largest j satisfying                |
//|        T_j + PeriodSeconds(tf)  <=  T_i + PeriodSeconds(_Period) |
//| i.e. the HTF bar had already closed when the chart bar closed.   |
//| This is THE reason this indicator does not repaint. Naive        |
//| iBarShift(), or CopyBuffer(handle,0,0,...) on a higher           |
//| timeframe, returns a bar that is still FORMING - that is the     |
//| single most common repaint bug in MTF indicators. Do not         |
//| "simplify" this function.                                        |
//|                                                                  |
//| INVARIANT 3 - EACH BAR IS SCORED EXACTLY ONCE, EVER              |
//|        if(time[i] <= g_lastBarTime) continue;                    |
//| MT5 re-runs OnCalculate on every tick. Without this guard the    |
//| win/loss statistics would double-count and objects would be      |
//| redrawn repeatedly. Any new per-bar side effect must live        |
//| AFTER this guard.                                                |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| STATISTICAL CALIBRATION  -  READ BEFORE TOUCHING ANY THRESHOLD   |
//|                                                                  |
//| Every statistic was validated against 3000 synthetic random      |
//| walks. These are MEASURED, not assumed. Null = the value the     |
//| statistic takes on pure noise:                                   |
//|                                                                  |
//|   statistic    null    p90     p95     p99    interpretation     |
//|   ---------------------------------------------------------------|
//|   ERn          1.00    2.07    2.42    3.09   directionality     |
//|   Tn           1.00    2.13    2.35    2.55   trend strength     |
//|   z_VR         0.00    1.36    1.80    2.63   persistence        |
//|   F ratio      1.00    1.40    1.51    1.73   volatility state   |
//|                                                                  |
//| The shipped thresholds sit at ~p90, so a reading at threshold    |
//| means "chance alone would produce this ~10% of the time".        |
//|                                                                  |
//| TRAP 1 - THE SLOPE t-STATISTIC IS NOT A SIGNIFICANCE TEST.       |
//| Regressing a random walk on time is the textbook spurious-       |
//| regression case (Granger-Newbold). Residuals are serially        |
//| correlated, SE(b) is understated, and raw |t| is large on pure   |
//| noise: at n=30 the random-walk MEAN of |t| is 5.80 and 75.7% of  |
//| random walks exceed |t| >= 2.0. A "textbook" threshold of 2.0 is |
//| therefore NOT A FILTER AT ALL. CalcSlopeT() divides by the       |
//| measured null 1.049*sqrt(n) to produce Tn with null mean 1.00.   |
//| If you ever revert to raw t, you must also change InpSlopeT      |
//| from ~2.1 to ~12 and it stops being lookback-invariant.          |
//|                                                                  |
//| TRAP 2 - THE VARIANCE RATIO IS DELIBERATELY BLIND TO DRIFT.      |
//| CalcVarRatio() subtracts q*mu from the q-period returns. A       |
//| constant drift is therefore removed completely. Measured:        |
//|                                                                  |
//|     series                        ERn     VR(4)   z_VR   Hurst   |
//|     random walk, no drift        1.017    1.003   0.014  0.494   |
//|     DRIFT only (0.4 sigma/bar)   2.069    1.003   0.014  0.494   |
//|     AR(1) phi = +0.35            1.408    1.657   3.512  0.677   |
//|     AR(1) phi = -0.35            0.735    0.585  -2.218  0.299   |
//|                                                                  |
//| This is CORRECT: drifting GBM is still a random walk, and the    |
//| VR test is a test for AUTOCORRELATION, not for direction. Note   |
//| how drift moves ERn (1.02 -> 2.07) while leaving VR at 1.00.     |
//| ERn and VR are complementary, NOT redundant - ERn sees           |
//| direction, VR sees persistence. If a future change makes VR      |
//| respond to drift, that change is a BUG, not an improvement.      |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| TIMEFRAME BEHAVIOUR                                              |
//| Works on ANY chart timeframe. The chart TF is always the signal  |
//| timeframe; ResolveLadder() derives a 1 : ~4 : ~16 ladder from    |
//| it when InpAutoLadder = true (the default), so M15 gives         |
//| M15/H1/H4 and H1 gives H1/H4/D1. Mapping only ever goes UPWARD   |
//| (chart bar -> higher TF bar), which is the direction that is     |
//| safe to make non-repainting.                                     |
//|                                                                  |
//| Setting InpTF_Mid/High BELOW the chart TF is not blocked but is  |
//| logically degenerate - the "higher timeframe filter" would sit   |
//| below the entry timeframe. OnInit prints a warning if you do.    |
//| On W1/MN1 charts nothing higher exists, so the ladder collapses  |
//| to two effective timeframes; this is expected and warned about.  |
//|                                                                  |
//| History requirement: each higher timeframe needs                 |
//| MaxLookback()+5 (~117) bars. Until MT5 has downloaded them,      |
//| BuildTFCtx() returns false and OnCalculate returns early with    |
//| NO output. This is self-healing - it starts drawing once the     |
//| history arrives. An empty chart is usually missing HTF history,  |
//| not a bug.                                                       |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| BUFFER CONTRACT (stable - an EA may depend on these)             |
//|   0  BuyArrow    price, or EMPTY_VALUE                           |
//|   1  SellArrow   price, or EMPTY_VALUE                           |
//|   2  Score       0..100 logistic signal strength, every bar      |
//|   3  Regime      0 = compression, 1 = expansion, 2 = trend       |
//|   4  Direction   +1 long candidate, -1 short, 0 none             |
//|   5  StopLoss    price on signal bars, else EMPTY_VALUE          |
//|   6  TakeProfit  price on signal bars, else EMPTY_VALUE          |
//| Buffers 2-6 are DRAW_NONE but are INDICATOR_DATA, so CopyBuffer  |
//| can read them. Do not renumber them.                             |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| HOW TO TEST  (in increasing order of strength)                   |
//|                                                                  |
//| T1. COMPILE                                                      |
//|     MetaEditor64.exe /compile:"...\QuantRegimeConfluence.mq5"    |
//|                     /log:"...\qrc.log"                           |
//|     The log is UTF-16. MetaEditor returns exit code 1 even on    |
//|     SUCCESS - parse the "Result: N errors" line, not the code.   |
//|                                                                  |
//| T2. PIPELINE ALIVE                                               |
//|     Defaults are strict and may legitimately produce zero        |
//|     arrows. Set InpScoreThreshold = 60 and InpMinRegimeConf =    |
//|     0.40 first. If arrows now appear, the pipeline works and     |
//|     the defaults were merely selective. If STILL nothing:        |
//|     check the Experts log for the "QRC ladder:" line and any     |
//|     history warning.                                             |
//|                                                                  |
//| T3. NON-REPAINT PROOF (the important one)                        |
//|     Strategy Tester -> Visual mode, slow speed. The tester       |
//|     feeds bars sequentially, so a repainting indicator visibly   |
//|     adds/moves/removes arrows on already-closed bars. Watch a    |
//|     printed arrow for 50+ bars: it must never move or vanish.    |
//|     Stronger, objective version: run to bar N, screenshot, let   |
//|     it run to N+200, compare the SAME historical bars. Any       |
//|     difference = repaint.                                        |
//|                                                                  |
//| T4. STATISTICAL SELF-TEST                                        |
//|     Run the companion script QRC_SelfTest.mq5 (same folder).     |
//|     It feeds synthetic random-walk, trending, and AR(1) series   |
//|     through the SAME estimator functions and asserts each        |
//|     returns its null value. Run it after ANY change to the math  |
//|     in the "MATH PRIMITIVES" section. Expected output is         |
//|     documented in that file.                                     |
//|                                                                  |
//| T5. FORWARD REALISM                                              |
//|     The on-chart win/loss panel is a closed-bar PATH SIMULATION, |
//|     not a backtest: no spread, no slippage, no commission, and   |
//|     a bar touching both SL and TP is booked as a LOSS (the       |
//|     conservative choice, since intrabar order is unknown).       |
//|     Treat it as signal quality only. Use the Strategy Tester     |
//|     with a real cost model for anything financial.               |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| MODIFICATION CHECKLIST - if you change X, also update Y          |
//|   * a threshold default -> re-derive it from the null quantile   |
//|     table above; do not pick a round number                      |
//|   * CalcSlopeT normalisation -> InpSlopeT default AND the f1     |
//|     centring term in SignalScore()                               |
//|   * any lookback input -> MaxLookback(), which drives warmup     |
//|     and the HTF history requirement                              |
//|   * buffer order -> the BUFFER CONTRACT above and any EA         |
//|   * a new per-bar side effect -> put it AFTER the                |
//|     g_lastBarTime guard (INVARIANT 3)                            |
//|   * feature count in SignalScore -> InpBias, or the score        |
//|     distribution shifts and InpScoreThreshold silently changes   |
//|     meaning                                                      |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Quant Regime Confluence Engine"
#property link      ""
#property version   "1.10"
#property description "INDICATOR ONLY - draws signals on the chart. It does NOT place trades."
#property description "Regime classification (variance F-test, normalised efficiency ratio,"
#property description "Lo-MacKinlay variance ratio, normalised trend stat) + 3-TF confluence"
#property description "+ logistic Signal Strength Score + ATR/regime dynamic SL-TP."
#property description "100% non-repainting: closed bars only."

#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   7

//--- Plot 0 : Buy arrow
#property indicator_label1  "QRC Buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  3
//--- Plot 1 : Sell arrow
#property indicator_label2  "QRC Sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  3
//--- Plot 2 : Signal Strength Score (data buffer, readable by an EA)
#property indicator_label3  "Score"
#property indicator_type3   DRAW_NONE
//--- Plot 3 : Regime code  0=Compression 1=Expansion 2=Trend
#property indicator_label4  "Regime"
#property indicator_type4   DRAW_NONE
//--- Plot 4 : Candidate direction  +1 / -1 / 0
#property indicator_label5  "Direction"
#property indicator_type5   DRAW_NONE
//--- Plot 5 : Stop Loss price of the signal on that bar
#property indicator_label6  "StopLoss"
#property indicator_type6   DRAW_NONE
//--- Plot 6 : Take Profit price of the signal on that bar
#property indicator_label7  "TakeProfit"
#property indicator_type7   DRAW_NONE

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_QRC_REGIME
  {
   QRC_COMPRESSION = 0,  // Low-volatility compression
   QRC_EXPANSION   = 1,  // High-volatility expansion
   QRC_TREND       = 2   // Structured trend
  };

enum ENUM_REG_SRC
  {
   REG_LOW  = 0,         // Signal timeframe (chart)
   REG_MID  = 1,         // Mid timeframe
   REG_HIGH = 2          // High timeframe
  };

enum ENUM_SL_MODE
  {
   SL_ATR_ONLY  = 0,     // Pure ATR x regime multiple
   SL_STRUCTURE = 1      // Wider of ATR and swing structure
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "======== 1. Timeframes and scope ========"
input bool             InpAutoLadder      = true;        // Auto-derive mid/high TF from the chart TF
input ENUM_TIMEFRAMES  InpTF_Mid          = PERIOD_H1;   // Mid timeframe  (used when AutoLadder = false)
input ENUM_TIMEFRAMES  InpTF_High         = PERIOD_H4;   // High timeframe (used when AutoLadder = false)
input int              InpMaxBars         = 1500;        // History bars to calculate

input group "======== 2. Statistical regime model ========"
input ENUM_REG_SRC     InpRegimeSrc       = REG_MID;     // Timeframe the regime is measured on
input int              InpRetLookback     = 100;         // N: returns used by variance-ratio test
input int              InpVRq             = 4;           // q: variance-ratio aggregation
input int              InpVolFast         = 20;          // n_fast: fast variance window
input int              InpVolSlow         = 100;         // n_slow: slow variance window
input int              InpERPeriod        = 20;          // n: efficiency-ratio window
input int              InpSlopePeriod     = 30;          // n: OLS regression window

input group "======== 3. Regime decision thresholds ========"
//--- All four thresholds below sit at the ~p90 tail of the RANDOM-WALK null
//--- distribution, measured over 3000 synthetic random walks. A reading at
//--- the threshold therefore means "this would happen by chance ~10% of the
//--- time on pure noise". See the TESTING section in the file header.
input double           InpTrendERn        = 2.05;        // theta_ER : normalised ER   (1.00 = random walk, p90 = 2.07)
input double           InpSlopeT          = 2.10;        // theta_t  : normalised |Tn| (1.00 = random walk, p90 = 2.13)
input double           InpVRz             = 1.30;        // theta_VR : Lo-MacKinlay z  (0.00 = random walk, p90 = 1.36)
input double           InpExpandF         = 1.40;        // theta_F+ : variance F-ratio, expansion  (p90 = 1.40)
input double           InpCompressF       = 0.65;        // theta_F- : variance F-ratio, compression (p10 = 0.65)
input double           InpSoftmaxTemp     = 1.00;        // tau      : softmax temperature
input double           InpMinRegimeConf   = 0.55;        // Minimum regime confidence to arm signals
input bool             InpAllowExpansion  = false;       // Also allow signals in expansion regime

input group "======== 4. Regime discriminant weights ========"
input double           InpW_T1            = 1.00;        // Trend  : weight on (ERn - theta_ER)
input double           InpW_T2            = 0.50;        // Trend  : weight on (|t| - theta_t)
input double           InpW_T3            = 0.45;        // Trend  : weight on (zVR - theta_VR)
input double           InpW_E1            = 1.20;        // Expand : weight on (F - theta_F+)
input double           InpW_E2            = 0.60;        // Expand : weight on (theta_ER - ERn)
input double           InpW_C1            = 1.40;        // Compr  : weight on (theta_F- - F)
input double           InpW_C2            = 0.35;        // Compr  : weight on (theta_t - |t|)

input group "======== 5. Logistic Signal Strength Score ========"
input double           InpScoreThreshold  = 85.0;        // Fire arrow only when Score >=
input double           InpBias            = -2.60;       // b0 : logistic intercept
input double           InpW1_HTFStruct    = 1.20;        // w1 : HTF OLS structure
input double           InpW2_MTFMom       = 1.00;        // w2 : MTF standardised drift
input double           InpW3_LTFMom       = 0.80;        // w3 : LTF standardised drift
input double           InpW4_Efficiency   = 0.70;        // w4 : normalised efficiency edge
input double           InpW5_Persistence  = 0.60;        // w5 : variance-ratio persistence
input double           InpW6_Regime       = 0.90;        // w6 : regime favourability
input double           InpW7_Location     = 0.60;        // w7 : entry location vs value
input double           InpW8_Displacement = 0.70;        // w8 : trigger-bar displacement
input double           InpW9_Volume       = 0.40;        // w9 : volume confirmation
input double           InpW10_Alignment   = 1.00;        // w10: 3-timeframe alignment

input group "======== 6. Trigger (signal timeframe) ========"
input int              InpEMAPeriod       = 34;          // Value-line EMA period (all TFs)
input int              InpATRPeriod       = 14;          // ATR period (all TFs)
input int              InpPullbackBars    = 8;           // Lookback for the pullback-to-value test
input double           InpPullTolATR      = 0.35;        // Pullback tolerance around EMA (x ATR)
input double           InpMinBodyRatio    = 0.50;        // Trigger bar body / range minimum
input double           InpMinDisplATR     = 0.35;        // Trigger bar body / ATR minimum
input int              InpMomBars         = 3;           // Short momentum confirmation lookback
input int              InpMinBarsBetween  = 5;           // Minimum bars between signals
input bool             InpOneAtATime      = true;        // Block a new signal while one is open
input int              InpVolZPeriod      = 30;          // Tick-volume z-score window

input group "======== 7. Dynamic risk management ========"
input ENUM_SL_MODE     InpSLMode          = SL_STRUCTURE;// Stop placement mode
input double           InpATRmultSL       = 1.60;        // Base SL multiple of ATR
input double           InpRR              = 2.00;        // Reward : risk
input int              InpSwingLookback   = 12;          // Swing lookback for structural stop
input double           InpVolAdjMin       = 0.70;        // Min regime volatility adjuster
input double           InpVolAdjMax       = 1.60;        // Max regime volatility adjuster
input int              InpMaxHoldBars     = 60;          // Bars before a signal is timed out
input int              InpProjectBars     = 22;          // Bars to project SL/TP lines forward
input int              InpMaxSignalDraw   = 40;          // Max signals kept drawn on chart

input group "======== 8. Dashboard ========"
input bool             InpShowPanel       = true;        // Show dashboard
input ENUM_BASE_CORNER InpPanelCorner     = CORNER_LEFT_UPPER; // Panel corner
input int              InpPanelX          = 12;          // Panel X offset
input int              InpPanelY          = 22;          // Panel Y offset
input int              InpPanelWidth      = 320;         // Panel width (px)
input int              InpPanelRowH       = 16;          // Row height (px)
input int              InpPanelFont       = 8;           // Font size
input string           InpPanelFontName   = "Consolas";  // Font name
input color            InpPanelBG         = C'20,24,32'; // Panel background
input color            InpPanelText       = clrSilver;   // Panel label colour

input group "======== 9. Visuals and alerts ========"
input color            InpBuyColor        = clrDodgerBlue;
input color            InpSellColor       = clrOrangeRed;
input color            InpSLColor         = clrIndianRed;
input color            InpTPColor         = clrMediumSeaGreen;
input double           InpArrowATROffset  = 1.20;        // Arrow offset from bar extreme (x ATR)
input bool             InpAlertPopup      = false;       // Popup alert on new signal
input bool             InpAlertPush       = false;       // Push notification on new signal

//+------------------------------------------------------------------+
//| Indicator buffers                                                |
//+------------------------------------------------------------------+
double BufBuy[];
double BufSell[];
double BufScore[];
double BufRegime[];
double BufDir[];
double BufSL[];
double BufTP[];

//+------------------------------------------------------------------+
//| Timeframe context: raw series + precomputed feature series       |
//+------------------------------------------------------------------+
struct TFCtx
  {
   ENUM_TIMEFRAMES   tf;
   int               bars;
   datetime          tm[];
   double            cl[];
   double            hi[];
   double            lo[];
   double            ema[];
   double            atr[];
   double            fERn[];      // normalised efficiency ratio
   double            fT[];        // OLS slope t-stat
   double            fVR[];       // variance ratio
   double            fVRz[];      // variance-ratio z statistic
   double            fF[];        // variance F-ratio
   double            fDrift[];    // standardised drift
   int               hEMA;
   int               hATR;
   datetime          lastBuild;
  };

TFCtx g_mid;
TFCtx g_high;

//--- the ACTIVE ladder, resolved once in OnInit by ResolveLadder().
//--- Always read these, never InpTF_Mid / InpTF_High directly, or the
//--- auto-ladder is silently bypassed.
ENUM_TIMEFRAMES g_tfMid  = PERIOD_H1;
ENUM_TIMEFRAMES g_tfHigh = PERIOD_H4;

//--- signal-timeframe handles / series (series-indexed: [0] = current bar)
int    g_hEMA_L = INVALID_HANDLE;
int    g_hATR_L = INVALID_HANDLE;
double g_emaL[];
double g_atrL[];
int    g_lCount = 0;

//+------------------------------------------------------------------+
//| Signal record + running statistics                               |
//+------------------------------------------------------------------+
struct QSignal
  {
   datetime          tm;
   int               dir;
   double            entry;
   double            sl;
   double            tp;
   double            risk;
   int               bar;
   int               held;
   bool              isOpen;
   double            rMult;
  };

QSignal  g_sigs[];
int      g_nSig    = 0;
int      g_nWin    = 0;
int      g_nLoss   = 0;
int      g_nOpen   = 0;
double   g_sumRpos = 0.0;
double   g_sumRneg = 0.0;
double   g_sumR    = 0.0;

datetime g_lastBarTime = 0;
datetime g_lastAlert   = 0;
int      g_warmup      = 200;
string   g_pfx         = "QRC_";
string   g_drawn[];
int      g_nDrawn      = 0;

//--- Why the engine is not currently producing output, shown on the panel.
//--- Empty string means "running normally". Set this on EVERY early exit
//--- from OnCalculate, otherwise the chart silently renders nothing and
//--- the user cannot tell a warm-up from a bug.
string g_status = "initialising";

//--- live snapshot for the dashboard
ENUM_QRC_REGIME g_liveRegime = QRC_COMPRESSION;
double g_liveConf  = 0.0;
double g_liveF     = 0.0;
double g_liveERn   = 0.0;
double g_liveVR    = 1.0;
double g_liveVRz   = 0.0;
double g_liveHurst = 0.5;
double g_liveTH    = 0.0;
double g_liveTM    = 0.0;
double g_liveTL    = 0.0;
double g_liveScore = 0.0;
int    g_liveDir   = 0;
string g_liveLast  = "none";

//+------------------------------------------------------------------+
//|                        MATH PRIMITIVES                           |
//+------------------------------------------------------------------+
double SafeDiv(const double a, const double b, const double def = 0.0)
  {
   return (MathAbs(b) > 1e-12 ? a / b : def);
  }

double Clamp(const double v, const double lo, const double hi)
  {
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
  }

//+------------------------------------------------------------------+
//| Human-readable timeframe name.                                   |
//| EnumToString(PERIOD_M15) returns the literal "PERIOD_M15", which |
//| is what the enum is called in code but NOT what a trader expects |
//| to read on a chart. Every user-facing string uses this instead.  |
//+------------------------------------------------------------------+
string TFName(const ENUM_TIMEFRAMES tf)
  {
   const ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : tf);
   switch(t)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";
      case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";
      case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";
      case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";
      case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";
      case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";
      case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
     }
   return "TF?";
  }

double Logistic(const double z)
  {
   if(z >  35.0) return 1.0;
   if(z < -35.0) return 0.0;
   return 1.0 / (1.0 + MathExp(-z));
  }

//--- squashing function, defined locally so the code does not depend
//--- on the presence of MathTanh in any particular terminal build
double Squash(const double x)
  {
   if(x >  20.0) return  1.0;
   if(x < -20.0) return -1.0;
   const double e = MathExp(2.0 * x);
   return (e - 1.0) / (e + 1.0);
  }

//+------------------------------------------------------------------+
//| Standard deviation of log returns r_k = ln(c[k]/c[k-1])          |
//| over the window ending at index i (inclusive), n returns.        |
//+------------------------------------------------------------------+
double StdevRet(const double &c[], const int i, const int n)
  {
   if(n < 2 || i - n < 0) return 0.0;
   double s = 0.0, s2 = 0.0;
   for(int k = i - n + 1; k <= i; k++)
     {
      if(c[k] <= 0.0 || c[k-1] <= 0.0) return 0.0;
      const double r = MathLog(c[k] / c[k-1]);
      s  += r;
      s2 += r * r;
     }
   const double m = s / n;
   const double v = (s2 - n * m * m) / (n - 1);
   return (v > 0.0 ? MathSqrt(v) : 0.0);
  }

//+------------------------------------------------------------------+
//| Feature A : variance F-ratio  sigma^2_fast / sigma^2_slow        |
//| Under homoskedasticity  F ~ F(n_f-1, n_s-1).                     |
//+------------------------------------------------------------------+
double CalcVarF(const double &c[], const int i, const int nf, const int ns)
  {
   const double sf = StdevRet(c, i, nf);
   const double ss = StdevRet(c, i, ns);
   if(ss <= 0.0) return 1.0;
   const double f = (sf * sf) / (ss * ss);
   return Clamp(f, 0.01, 25.0);
  }

//+------------------------------------------------------------------+
//| Feature B : normalised efficiency ratio  ERn = ER * sqrt(n)      |
//| ERn == 1.0 is the random-walk expectation, so the statistic is   |
//| directly comparable across timeframes and lookbacks.             |
//+------------------------------------------------------------------+
double CalcERn(const double &c[], const int i, const int n)
  {
   if(n < 2 || i - n < 0) return 1.0;
   const double num = MathAbs(c[i] - c[i-n]);
   double den = 0.0;
   for(int k = i - n + 1; k <= i; k++)
      den += MathAbs(c[k] - c[k-1]);
   if(den <= 0.0) return 1.0;
   return (num / den) * MathSqrt((double)n);
  }

//+------------------------------------------------------------------+
//| Feature C : Lo-MacKinlay overlapping variance ratio + z-stat     |
//|   VR(q) = sigma_c^2 / sigma_a^2,  VR == 1 under a random walk    |
//|   z     = (VR-1) / sqrt( 2(2q-1)(q-1) / (3qN) )  ~ N(0,1)        |
//+------------------------------------------------------------------+
double CalcVarRatio(const double &c[], const int i, const int N, const int q, double &vrOut)
  {
   vrOut = 1.0;
   if(q < 2 || N < q * 3 || i - N < 0) return 0.0;

   const int p0 = i - N;                         // index of log-price p_0
   if(c[p0] <= 0.0 || c[i] <= 0.0) return 0.0;

   const double mu = (MathLog(c[i]) - MathLog(c[p0])) / (double)N;

   //--- sigma_a^2 : one-period return variance
   double sa = 0.0;
   for(int k = p0 + 1; k <= i; k++)
     {
      if(c[k] <= 0.0 || c[k-1] <= 0.0) return 0.0;
      const double d = MathLog(c[k] / c[k-1]) - mu;
      sa += d * d;
     }
   sa /= (double)(N - 1);
   if(sa <= 0.0) return 0.0;

   //--- sigma_c^2 : overlapping q-period return variance (unbiased m)
   double sc = 0.0;
   for(int k = p0 + q; k <= i; k++)
     {
      if(c[k] <= 0.0 || c[k-q] <= 0.0) return 0.0;
      const double d = MathLog(c[k] / c[k-q]) - q * mu;
      sc += d * d;
     }
   const double m = (double)q * (double)(N - q + 1) * (1.0 - (double)q / (double)N);
   if(m <= 0.0) return 0.0;
   sc /= m;

   const double vr = sc / sa;
   vrOut = Clamp(vr, 0.01, 20.0);

   const double varz = 2.0 * (2.0 * q - 1.0) * (q - 1.0) / (3.0 * q * (double)N);
   if(varz <= 0.0) return 0.0;
   return Clamp((vrOut - 1.0) / MathSqrt(varz), -12.0, 12.0);
  }

//+------------------------------------------------------------------+
//| Feature D : NORMALISED trend statistic  Tn                       |
//|                                                                  |
//|   raw t = b / SE(b)  from OLS of close on bar index.             |
//|                                                                  |
//| WARNING TO FUTURE MAINTAINERS - DO NOT read the raw t as a       |
//| significance test. Regressing a random walk on time is the       |
//| classic spurious-regression case (Granger-Newbold): the residuals|
//| are serially correlated, so SE(b) is badly understated and |t|   |
//| is huge even on pure noise. Measured on 3000 synthetic random    |
//| walks (see the TESTING section in the file header):              |
//|                                                                  |
//|      n=30 random walk ->  mean |t| = 5.80 ,  p90 |t| = 12.4      |
//|      a naive threshold of |t| >= 2.0 fires on 75.7% of NOISE.    |
//|                                                                  |
//| The null grows as sqrt(n), and |t|/sqrt(n) is stable to within   |
//| 3.7% across n = 15..120. So we divide by the measured null:      |
//|                                                                  |
//|      Tn = t / (SLOPE_NULL_C * sqrt(n)) ,  SLOPE_NULL_C = 1.049   |
//|                                                                  |
//| Tn now has null mean 1.00 and null p90 = 2.13, EXACTLY like the  |
//| normalised efficiency ratio ERn. That makes InpSlopeT            |
//| lookback-invariant: you can optimise InpSlopePeriod without      |
//| silently changing what the threshold means.                      |
//| Sign is preserved and carries the trend direction.               |
//+------------------------------------------------------------------+
#define SLOPE_NULL_C 1.049

double CalcSlopeT(const double &c[], const int i, const int n)
  {
   if(n < 5 || i - n + 1 < 0) return 0.0;
   double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
   for(int k = 0; k < n; k++)
     {
      const double x = (double)k;
      const double y = c[i - n + 1 + k];
      sx  += x;
      sy  += y;
      sxx += x * x;
      sxy += x * y;
     }
   const double xbar = sx / n;
   const double ybar = sy / n;
   const double Sxx  = sxx - n * xbar * xbar;
   const double Sxy  = sxy - n * xbar * ybar;
   if(Sxx <= 0.0) return 0.0;

   const double b = Sxy / Sxx;
   const double a = ybar - b * xbar;

   double sse = 0.0;
   for(int k = 0; k < n; k++)
     {
      const double e = c[i - n + 1 + k] - (a + b * (double)k);
      sse += e * e;
     }
   const double s2 = sse / (double)(n - 2);
   if(s2 <= 0.0) return 0.0;

   const double seb = MathSqrt(s2 / Sxx);
   if(seb <= 0.0) return 0.0;

   //--- divide by the empirically measured random-walk null so that
   //--- |Tn| == 1.0 means "as trendy as noise", independent of n
   const double tn = (b / seb) / (SLOPE_NULL_C * MathSqrt((double)n));
   return Clamp(tn, -15.0, 15.0);
  }

//+------------------------------------------------------------------+
//| Standardised drift: n-bar log return / (sigma * sqrt(n)) ~ N(0,1)|
//+------------------------------------------------------------------+
double CalcDriftZ(const double &c[], const int i, const int n)
  {
   if(n < 2 || i - n < 0) return 0.0;
   if(c[i] <= 0.0 || c[i-n] <= 0.0) return 0.0;
   const double sig = StdevRet(c, i, n);
   if(sig <= 0.0) return 0.0;
   const double tot = MathLog(c[i] / c[i-n]);
   return Clamp(tot / (sig * MathSqrt((double)n)), -12.0, 12.0);
  }

//+------------------------------------------------------------------+
//| Implied Hurst exponent from the variance ratio: VR = q^(2H-1)    |
//+------------------------------------------------------------------+
double ImpliedHurst(const double vr, const int q)
  {
   if(vr <= 0.0 || q < 2) return 0.5;
   return Clamp(0.5 * (1.0 + MathLog(vr) / MathLog((double)q)), 0.0, 1.0);
  }

//+------------------------------------------------------------------+
//|                    TIMEFRAME LADDER                              |
//|                                                                  |
//| The engine needs THREE strictly increasing timeframes:           |
//|   LTF  = the chart timeframe   -> trigger + entry                |
//|   MTF  ~ 4x the chart TF       -> momentum agreement filter      |
//|   HTF  ~ 16-24x the chart TF   -> structural direction (veto)    |
//|                                                                  |
//| With InpAutoLadder = true these are derived from _Period, so the |
//| indicator can be dropped on ANY chart timeframe and keeps the    |
//| same 1 : 4 : 16 structural relationship. Hard-coding H1/H4 would |
//| make the logic meaningless on an M1 or a D1 chart.               |
//|                                                                  |
//| An explicit table is used rather than arithmetic because MT5     |
//| only offers a fixed, non-uniform set of periods.                 |
//+------------------------------------------------------------------+
void ResolveLadder(ENUM_TIMEFRAMES &mid, ENUM_TIMEFRAMES &high)
  {
   if(!InpAutoLadder)
     {
      mid  = InpTF_Mid;
      high = InpTF_High;
      return;
     }

   switch(_Period)
     {
      case PERIOD_M1:  mid = PERIOD_M5;  high = PERIOD_M30; break;
      case PERIOD_M2:  mid = PERIOD_M10; high = PERIOD_H1;  break;
      case PERIOD_M3:  mid = PERIOD_M15; high = PERIOD_H1;  break;
      case PERIOD_M4:  mid = PERIOD_M20; high = PERIOD_H2;  break;
      case PERIOD_M5:  mid = PERIOD_M30; high = PERIOD_H2;  break;
      case PERIOD_M6:  mid = PERIOD_M30; high = PERIOD_H3;  break;
      case PERIOD_M10: mid = PERIOD_H1;  high = PERIOD_H4;  break;
      case PERIOD_M12: mid = PERIOD_H1;  high = PERIOD_H4;  break;
      case PERIOD_M15: mid = PERIOD_H1;  high = PERIOD_H4;  break;
      case PERIOD_M20: mid = PERIOD_H2;  high = PERIOD_H6;  break;
      case PERIOD_M30: mid = PERIOD_H2;  high = PERIOD_H8;  break;
      case PERIOD_H1:  mid = PERIOD_H4;  high = PERIOD_D1;  break;
      case PERIOD_H2:  mid = PERIOD_H8;  high = PERIOD_D1;  break;
      case PERIOD_H3:  mid = PERIOD_H12; high = PERIOD_D1;  break;
      case PERIOD_H4:  mid = PERIOD_D1;  high = PERIOD_W1;  break;
      case PERIOD_H6:  mid = PERIOD_D1;  high = PERIOD_W1;  break;
      case PERIOD_H8:  mid = PERIOD_D1;  high = PERIOD_W1;  break;
      case PERIOD_H12: mid = PERIOD_D1;  high = PERIOD_W1;  break;
      case PERIOD_D1:  mid = PERIOD_W1;  high = PERIOD_MN1; break;
      //--- W1 and MN1 have no meaningful higher structure available
      default:         mid = PERIOD_W1;  high = PERIOD_MN1; break;
     }
  }

//+------------------------------------------------------------------+
//|                 TIMEFRAME CONTEXT MANAGEMENT                     |
//+------------------------------------------------------------------+
int MaxLookback()
  {
   int lb = InpRetLookback + InpVRq + 2;
   lb = MathMax(lb, InpVolSlow + 2);
   lb = MathMax(lb, InpSlopePeriod + 2);
   lb = MathMax(lb, InpERPeriod + 2);
   lb = MathMax(lb, InpEMAPeriod * 3);
   lb = MathMax(lb, InpATRPeriod * 3);
   return lb + 10;
  }

//+------------------------------------------------------------------+
//| Number of higher-timeframe bars needed to cover InpMaxBars of    |
//| the signal timeframe, plus the feature warm-up.                  |
//+------------------------------------------------------------------+
int RequiredTFBars(const ENUM_TIMEFRAMES tf)
  {
   const double ps  = (double)PeriodSeconds(tf);
   const double pl  = (double)PeriodSeconds(_Period);
   if(ps <= 0.0) return 500;
   int need = (int)MathCeil((double)InpMaxBars * pl / ps) + MaxLookback() + 20;
   return (int)Clamp((double)need, 300.0, 6000.0);
  }

//+------------------------------------------------------------------+
//| Rebuild a timeframe context (raw series + all feature series).   |
//| Called only when that timeframe prints a new bar, or on a full   |
//| recalculation - not on every tick.                               |
//+------------------------------------------------------------------+
bool BuildTFCtx(TFCtx &ctx, const bool force)
  {
   const datetime cur = (datetime)SeriesInfoInteger(_Symbol, ctx.tf, SERIES_LASTBAR_DATE);
   if(!force && cur == ctx.lastBuild && ctx.bars > 0)
      return true;

   const int need = RequiredTFBars(ctx.tf);

   MqlRates rt[];
   ArraySetAsSeries(rt, false);
   const int got = CopyRates(_Symbol, ctx.tf, 0, need, rt);
   if(got < MaxLookback() + 5)
      return false;

   ArrayResize(ctx.tm,  got);
   ArrayResize(ctx.cl,  got);
   ArrayResize(ctx.hi,  got);
   ArrayResize(ctx.lo,  got);
   for(int k = 0; k < got; k++)
     {
      ctx.tm[k] = rt[k].time;
      ctx.cl[k] = rt[k].close;
      ctx.hi[k] = rt[k].high;
      ctx.lo[k] = rt[k].low;
     }

   ArraySetAsSeries(ctx.ema, false);
   ArraySetAsSeries(ctx.atr, false);
   if(CopyBuffer(ctx.hEMA, 0, 0, got, ctx.ema) < got) return false;
   if(CopyBuffer(ctx.hATR, 0, 0, got, ctx.atr) < got) return false;

   ArrayResize(ctx.fERn,   got);
   ArrayResize(ctx.fT,     got);
   ArrayResize(ctx.fVR,    got);
   ArrayResize(ctx.fVRz,   got);
   ArrayResize(ctx.fF,     got);
   ArrayResize(ctx.fDrift, got);

   const int lb = MaxLookback();
   for(int k = 0; k < got; k++)
     {
      if(k < lb)
        {
         ctx.fERn[k]   = 1.0;
         ctx.fT[k]     = 0.0;
         ctx.fVR[k]    = 1.0;
         ctx.fVRz[k]   = 0.0;
         ctx.fF[k]     = 1.0;
         ctx.fDrift[k] = 0.0;
         continue;
        }
      double vr = 1.0;
      ctx.fVRz[k]   = CalcVarRatio(ctx.cl, k, InpRetLookback, InpVRq, vr);
      ctx.fVR[k]    = vr;
      ctx.fERn[k]   = CalcERn(ctx.cl, k, InpERPeriod);
      ctx.fT[k]     = CalcSlopeT(ctx.cl, k, InpSlopePeriod);
      ctx.fF[k]     = CalcVarF(ctx.cl, k, InpVolFast, InpVolSlow);
      ctx.fDrift[k] = CalcDriftZ(ctx.cl, k, InpVolFast);
     }

   ctx.bars      = got;
   ctx.lastBuild = cur;
   return true;
  }

//+------------------------------------------------------------------+
//|  NON-REPAINT MAPPING                                             |
//|  Return the largest index j such that the timeframe bar j had    |
//|  already CLOSED by the moment the signal bar closed:             |
//|        T_j + P_tf  <=  ltfCloseTime                              |
//|  Returns -1 when no such closed bar exists.                      |
//+------------------------------------------------------------------+
int MapClosedIndex(TFCtx &ctx, const datetime ltfCloseTime)
  {
   if(ctx.bars <= 0) return -1;
   const int ps = PeriodSeconds(ctx.tf);
   if(ps <= 0) return -1;

   int lo = 0, hi = ctx.bars - 1, res = -1;
   while(lo <= hi)
     {
      const int mid = (lo + hi) / 2;
      if((long)ctx.tm[mid] + (long)ps <= (long)ltfCloseTime)
        {
         res = mid;
         lo  = mid + 1;
        }
      else
         hi = mid - 1;
     }
   return res;
  }

//+------------------------------------------------------------------+
//|                    REGIME CLASSIFICATION                         |
//|  Three linear discriminant scores -> softmax -> argmax.          |
//|  Returns the regime, writes the max posterior into conf.         |
//+------------------------------------------------------------------+
ENUM_QRC_REGIME ClassifyRegime(const double ERn, const double tstat,
                               const double zVR, const double F,
                               double &conf)
  {
   const double at = MathAbs(tstat);

   const double sTrend = InpW_T1 * (ERn   - InpTrendERn)
                       + InpW_T2 * (at    - InpSlopeT)
                       + InpW_T3 * (zVR   - InpVRz);

   const double sExpand = InpW_E1 * (F           - InpExpandF)
                        + InpW_E2 * (InpTrendERn - ERn);

   const double sCompr  = InpW_C1 * (InpCompressF - F)
                        + InpW_C2 * (InpSlopeT    - at);

   const double tau = (InpSoftmaxTemp > 0.05 ? InpSoftmaxTemp : 0.05);

   double s[3];
   s[0] = sCompr  / tau;   // QRC_COMPRESSION
   s[1] = sExpand / tau;   // QRC_EXPANSION
   s[2] = sTrend  / tau;   // QRC_TREND

   double mx = s[0];
   int    am = 0;
   for(int k = 1; k < 3; k++)
      if(s[k] > mx) { mx = s[k]; am = k; }

   double sum = 0.0;
   for(int k = 0; k < 3; k++)
      sum += MathExp(Clamp(s[k] - mx, -60.0, 0.0));

   conf = (sum > 0.0 ? 1.0 / sum : 0.34);
   return (ENUM_QRC_REGIME)am;
  }

//+------------------------------------------------------------------+
//|              LOGISTIC SIGNAL STRENGTH SCORE (0..100)             |
//+------------------------------------------------------------------+
double SignalScore(const int dir,
                   const double tH, const double driftM, const double driftL,
                   const double ERn, const double zVR,
                   const ENUM_QRC_REGIME reg, const double conf,
                   const double distToValueATR, const double displATR,
                   const double volZ, const int agreeCount)
  {
   const double d = (double)dir;

   //--- f1 is centred on the random-walk null: d*tH == 1.0 is "as trendy as
   //--- noise" and scores 0. Aligned real trends score positive, opposed
   //--- trends score negative. Same convention as f4 (ERn - 1.0).
   const double f1 = Squash((d * tH - 1.0) / 1.5);      // HTF structural trend, direction-aligned
   const double f2 = Squash(d * driftM / 2.0);          // MTF standardised drift, direction-aligned
   const double f3 = Squash(d * driftL / 2.0);          // LTF standardised drift, direction-aligned
   const double f4 = Squash(ERn - 1.0);                 // efficiency above the random-walk baseline
   const double f5 = Squash(zVR / 2.0);                 // persistence is direction-agnostic
   double regSign = -1.0;
   if(reg == QRC_TREND)     regSign =  1.00;
   if(reg == QRC_EXPANSION) regSign =  0.30;
   const double f6  = conf * regSign;                   // regime favourability, confidence-weighted
   const double f7  = 1.0 - Clamp(distToValueATR, 0.0, 1.0); // entering near value, not extended
   const double f8  = Squash(displATR / 0.80);          // trigger-bar displacement
   const double f9  = Squash(volZ / 2.0);               // participation confirmation
   const double f10 = 2.0 * ((double)agreeCount / 3.0) - 1.0; // 3-timeframe alignment

   const double z = InpBias
                  + InpW1_HTFStruct    * f1
                  + InpW2_MTFMom       * f2
                  + InpW3_LTFMom       * f3
                  + InpW4_Efficiency   * f4
                  + InpW5_Persistence  * f5
                  + InpW6_Regime       * f6
                  + InpW7_Location     * f7
                  + InpW8_Displacement * f8
                  + InpW9_Volume       * f9
                  + InpW10_Alignment   * f10;

   return 100.0 * Logistic(z);
  }

//+------------------------------------------------------------------+
//|                        OBJECT HELPERS                            |
//+------------------------------------------------------------------+
void ObjDelPrefix(const string pfx)
  {
   const int total = ObjectsTotal(0, -1, -1);
   for(int k = total - 1; k >= 0; k--)
     {
      const string nm = ObjectName(0, k, -1, -1);
      if(StringFind(nm, pfx, 0) == 0)
         ObjectDelete(0, nm);
     }
  }

void MakeSeg(const string nm, const datetime t1, const datetime t2,
             const double price, const color c, const int width,
             const ENUM_LINE_STYLE style)
  {
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_TREND, 0, t1, price, t2, price);
   else
     {
      ObjectMove(0, nm, 0, t1, price);
      ObjectMove(0, nm, 1, t2, price);
     }
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, style);
   ObjectSetInteger(0, nm, OBJPROP_RAY_LEFT,  false);
   ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Draw entry / SL / TP for one signal, keeping the object count    |
//| bounded by InpMaxSignalDraw.                                     |
//+------------------------------------------------------------------+
void DrawSignalLevels(const datetime t, const int dir,
                      const double entry, const double sl, const double tp)
  {
   if(InpProjectBars <= 0) return;

   const datetime t2 = t + (datetime)(PeriodSeconds(_Period) * InpProjectBars);
   const string   id = g_pfx + "SIG_" + IntegerToString((long)t) + "_";

   MakeSeg(id + "E",  t, t2, entry, (dir > 0 ? InpBuyColor : InpSellColor), 1, STYLE_DOT);
   MakeSeg(id + "SL", t, t2, sl,    InpSLColor, 2, STYLE_SOLID);
   MakeSeg(id + "TP", t, t2, tp,    InpTPColor, 2, STYLE_SOLID);

   ArrayResize(g_drawn, g_nDrawn + 1);
   g_drawn[g_nDrawn++] = id;

   while(g_nDrawn > InpMaxSignalDraw)
     {
      ObjDelPrefix(g_drawn[0]);
      for(int k = 1; k < g_nDrawn; k++)
         g_drawn[k-1] = g_drawn[k];
      g_nDrawn--;
      ArrayResize(g_drawn, g_nDrawn);
     }
  }

//+------------------------------------------------------------------+
//|                          DASHBOARD                               |
//+------------------------------------------------------------------+
void PanelLabel(const string sub, const int row, const int xoff,
                const string text, const color c, const bool bold)
  {
   const string nm = g_pfx + "P_" + sub + IntegerToString(row);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER,    InpPanelCorner);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpPanelX + 8 + xoff);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpPanelY + 8 + row * InpPanelRowH);
   ObjectSetString (0, nm, OBJPROP_TEXT,      text);
   ObjectSetString (0, nm, OBJPROP_FONT,      bold ? "Arial Bold" : InpPanelFontName);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,  InpPanelFont);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,     c);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN,    true);
   ObjectSetInteger(0, nm, OBJPROP_BACK,      false);
  }

void PanelRow(const int row, const string key, const string val, const color vc)
  {
   PanelLabel("k", row, 0, key, InpPanelText, false);
   PanelLabel("v", row, (int)(InpPanelWidth * 0.46), val, vc, false);
}

string RegimeName(const ENUM_QRC_REGIME r)
  {
   if(r == QRC_TREND)      return "STRUCTURED TREND";
   if(r == QRC_EXPANSION)  return "VOL EXPANSION";
   return "VOL COMPRESSION";
  }

color RegimeColor(const ENUM_QRC_REGIME r)
  {
   if(r == QRC_TREND)      return clrLimeGreen;
   if(r == QRC_EXPANSION)  return clrGold;
   return clrDeepSkyBlue;
  }

void UpdatePanel()
  {
   if(!InpShowPanel) return;

   const int rows = 17;
   const string bg = g_pfx + "P_BG";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER,    InpPanelCorner);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE,     InpPanelWidth);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE,     rows * InpPanelRowH + 18);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,   InpPanelBG);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR,     clrDimGray);
   ObjectSetInteger(0, bg, OBJPROP_BACK,      false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN,    true);

   int r = 0;
   PanelLabel("t", r, 0,
              "QUANT REGIME CONFLUENCE   " + _Symbol + "  " + TFName((ENUM_TIMEFRAMES)_Period),
              clrWhite, true);
   r++;

   //--- status first: a blank chart must always explain itself
   if(g_status == "")
      PanelRow(r++, "Status", "running", clrLimeGreen);
   else
     {
      PanelRow(r++, "Status", g_status, clrGold);
      PanelLabel("k", r, 0, "  (no signals until this clears)", clrDimGray, false);
      r++;
      ChartRedraw(0);
      return;                       // nothing below is meaningful yet
     }

   PanelRow(r++, "Regime", RegimeName(g_liveRegime) + "  " +
                 DoubleToString(g_liveConf * 100.0, 0) + "%", RegimeColor(g_liveRegime));

   PanelRow(r++, "Variance F (fast/slow)", DoubleToString(g_liveF, 2),
            (g_liveF > InpExpandF ? clrGold : (g_liveF < InpCompressF ? clrDeepSkyBlue : clrSilver)));

   PanelRow(r++, "Efficiency ERn (RW=1.00)", DoubleToString(g_liveERn, 2),
            (g_liveERn >= InpTrendERn ? clrLimeGreen : clrSilver));

   PanelRow(r++, "VarRatio VR(" + IntegerToString(InpVRq) + ")",
            DoubleToString(g_liveVR, 2) + "  z=" + DoubleToString(g_liveVRz, 2),
            (g_liveVRz >= 2.0 ? clrLimeGreen : (g_liveVRz <= -2.0 ? clrOrangeRed : clrSilver)));

   PanelRow(r++, "Implied Hurst H", DoubleToString(g_liveHurst, 3),
            (g_liveHurst > 0.55 ? clrLimeGreen : (g_liveHurst < 0.45 ? clrOrangeRed : clrSilver)));

   PanelLabel("k", r, 0, "--- Trend strength Tn  (1.00 = random walk) ---", clrDimGray, false);
   r++;

   PanelRow(r++, "  HTF " + TFName(g_tfHigh), DoubleToString(g_liveTH, 2),
            (MathAbs(g_liveTH) >= InpSlopeT ? (g_liveTH > 0 ? clrLimeGreen : clrOrangeRed) : clrSilver));
   PanelRow(r++, "  MTF " + TFName(g_tfMid), DoubleToString(g_liveTM, 2),
            (MathAbs(g_liveTM) >= InpSlopeT ? (g_liveTM > 0 ? clrLimeGreen : clrOrangeRed) : clrSilver));
   PanelRow(r++, "  LTF " + TFName((ENUM_TIMEFRAMES)_Period), DoubleToString(g_liveTL, 2),
            (MathAbs(g_liveTL) >= InpSlopeT ? (g_liveTL > 0 ? clrLimeGreen : clrOrangeRed) : clrSilver));

   string dirTxt = "FLAT";
   color  dirCol = clrSilver;
   if(g_liveDir > 0) { dirTxt = "LONG BIAS";  dirCol = InpBuyColor;  }
   if(g_liveDir < 0) { dirTxt = "SHORT BIAS"; dirCol = InpSellColor; }
   PanelRow(r++, "Signal Strength Score",
            DoubleToString(g_liveScore, 1) + " / 100  " + dirTxt,
            (g_liveScore >= InpScoreThreshold ? dirCol : clrSilver));

   PanelLabel("k", r, 0, "--- Closed-bar signal statistics ---", clrDimGray, false);
   r++;

   const int    closed = g_nWin + g_nLoss;
   const double wr     = (closed > 0 ? 100.0 * g_nWin / closed : 0.0);
   const double pf     = (g_sumRneg < -1e-9 ? g_sumRpos / MathAbs(g_sumRneg) : 0.0);
   const double exp_r  = (closed > 0 ? g_sumR / closed : 0.0);

   PanelRow(r++, "Signals / Open",
            IntegerToString(g_nSig) + "  /  " + IntegerToString(g_nOpen), clrSilver);
   PanelRow(r++, "Wins / Losses / Win%",
            IntegerToString(g_nWin) + " / " + IntegerToString(g_nLoss) + " / " +
            DoubleToString(wr, 1) + "%",
            (wr >= 50.0 ? clrLimeGreen : (closed > 0 ? clrOrangeRed : clrSilver)));
   PanelRow(r++, "Expectancy R / PF",
            DoubleToString(exp_r, 2) + "R  /  " + DoubleToString(pf, 2),
            (exp_r > 0.0 ? clrLimeGreen : (closed > 0 ? clrOrangeRed : clrSilver)));

   PanelLabel("k", r, 0, "Last: " + g_liveLast, clrLightGray, false);
   r++;

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|                       STATISTICS ENGINE                          |
//+------------------------------------------------------------------+
void ResetState()
  {
   ArrayFree(g_sigs);
   g_nSig = 0; g_nWin = 0; g_nLoss = 0; g_nOpen = 0;
   g_sumRpos = 0.0; g_sumRneg = 0.0; g_sumR = 0.0;
   g_lastBarTime = 0;
   g_liveLast = "none";
   ArrayFree(g_drawn);
   g_nDrawn = 0;
   ObjDelPrefix(g_pfx + "SIG_");
  }

void CloseSignal(const int idx, const double rMult)
  {
   g_sigs[idx].isOpen = false;
   g_sigs[idx].rMult  = rMult;
   g_nOpen--;
   if(rMult > 0.0) { g_nWin++;  g_sumRpos += rMult; }
   else            { g_nLoss++; g_sumRneg += rMult; }
   g_sumR += rMult;
  }

//+------------------------------------------------------------------+
//| Resolve every open signal against the newly closed bar i.        |
//| Ambiguous bars (SL and TP both touched) are counted as losses -  |
//| the conservative assumption, since intrabar order is unknown.    |
//+------------------------------------------------------------------+
void UpdateOpenSignals(const int i, const double &high[], const double &low[], const double &close[])
  {
   const int n = ArraySize(g_sigs);
   for(int k = 0; k < n; k++)
     {
      if(!g_sigs[k].isOpen)  continue;
      if(g_sigs[k].bar >= i) continue;

      g_sigs[k].held++;

      const bool hitSL = (g_sigs[k].dir > 0 ? low[i]  <= g_sigs[k].sl
                                            : high[i] >= g_sigs[k].sl);
      const bool hitTP = (g_sigs[k].dir > 0 ? high[i] >= g_sigs[k].tp
                                            : low[i]  <= g_sigs[k].tp);

      if(hitSL)                    { CloseSignal(k, -1.0);    continue; }
      if(hitTP)                    { CloseSignal(k, InpRR);   continue; }

      if(g_sigs[k].held >= InpMaxHoldBars)
        {
         const double r = SafeDiv((close[i] - g_sigs[k].entry) * g_sigs[k].dir, g_sigs[k].risk, 0.0);
         CloseSignal(k, r);
        }
     }
  }

int BarsSinceLastSignal(const int i)
  {
   const int n = ArraySize(g_sigs);
   if(n == 0) return 100000;
   return i - g_sigs[n-1].bar;
  }

bool HasOpenSignal()
  {
   return (g_nOpen > 0);
  }

//+------------------------------------------------------------------+
//|                          OnInit                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Resolved configuration, printed once. `input group` occupies a positional
//--- iCustom slot, so a caller that omits placeholders mis-assigns every
//--- parameter after the first group - silently. These seven span both ends of
//--- the range an EA forwards, so a shift at either end shows up here.
   PrintFormat("QRC config: autoLadder=%s tfMid=%s tfHigh=%s maxBars=%d "
               "regimeSrc=%d retLookback=%d scoreThreshold=%.1f",
               (InpAutoLadder ? "true" : "false"), EnumToString(InpTF_Mid),
               EnumToString(InpTF_High), InpMaxBars, (int)InpRegimeSrc,
               InpRetLookback, InpScoreThreshold);

   SetIndexBuffer(0, BufBuy,    INDICATOR_DATA);
   SetIndexBuffer(1, BufSell,   INDICATOR_DATA);
   SetIndexBuffer(2, BufScore,  INDICATOR_DATA);
   SetIndexBuffer(3, BufRegime, INDICATOR_DATA);
   SetIndexBuffer(4, BufDir,    INDICATOR_DATA);
   SetIndexBuffer(5, BufSL,     INDICATOR_DATA);
   SetIndexBuffer(6, BufTP,     INDICATOR_DATA);

   ArraySetAsSeries(BufBuy,    false);
   ArraySetAsSeries(BufSell,   false);
   ArraySetAsSeries(BufScore,  false);
   ArraySetAsSeries(BufRegime, false);
   ArraySetAsSeries(BufDir,    false);
   ArraySetAsSeries(BufSL,     false);
   ArraySetAsSeries(BufTP,     false);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpBuyColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpSellColor);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(5, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(6, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   //--- resolve the 1 : 4 : 16 timeframe ladder for THIS chart
   ResolveLadder(g_tfMid, g_tfHigh);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      "QRC " + TFName((ENUM_TIMEFRAMES)_Period) + "/" +
                      TFName(g_tfMid) + "/" + TFName(g_tfHigh));

   //--- sanity checks on the timeframe ladder
   if(PeriodSeconds(g_tfMid) <= PeriodSeconds(_Period))
      Print("QRC warning: mid timeframe (", TFName(g_tfMid), ") is not above the chart ",
            "timeframe (", TFName((ENUM_TIMEFRAMES)_Period), "). The MTF filter is degenerate; ",
            "enable InpAutoLadder or raise InpTF_Mid.");
   if(PeriodSeconds(g_tfHigh) <= PeriodSeconds(g_tfMid))
      Print("QRC warning: high timeframe (", TFName(g_tfHigh), ") is not above the mid ",
            "timeframe (", TFName(g_tfMid), "). Confluence collapses to two timeframes ",
            "(expected on W1/MN1 charts, where nothing higher exists).");
   if(InpRetLookback < InpVRq * 3)
      Print("QRC warning: InpRetLookback should be at least 3*q for a stable variance ratio.");

   Print("QRC ladder: LTF=", TFName((ENUM_TIMEFRAMES)_Period),
         "  MTF=", TFName(g_tfMid),
         "  HTF=", TFName(g_tfHigh),
         (InpAutoLadder ? "  (auto)" : "  (manual)"));

   //--- indicator handles
   g_hEMA_L = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR_L = iATR(_Symbol, _Period, InpATRPeriod);

   g_mid.tf    = g_tfMid;
   g_mid.hEMA  = iMA(_Symbol, g_tfMid, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_mid.hATR  = iATR(_Symbol, g_tfMid, InpATRPeriod);
   g_mid.bars  = 0;
   g_mid.lastBuild = 0;

   g_high.tf   = g_tfHigh;
   g_high.hEMA = iMA(_Symbol, g_tfHigh, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_high.hATR = iATR(_Symbol, g_tfHigh, InpATRPeriod);
   g_high.bars = 0;
   g_high.lastBuild = 0;

   if(g_hEMA_L == INVALID_HANDLE || g_hATR_L == INVALID_HANDLE ||
      g_mid.hEMA == INVALID_HANDLE || g_mid.hATR == INVALID_HANDLE ||
      g_high.hEMA == INVALID_HANDLE || g_high.hATR == INVALID_HANDLE)
     {
      Print("QRC: failed to create indicator handles.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(g_emaL, true);
   ArraySetAsSeries(g_atrL, true);

   g_warmup = MaxLookback();
   ResetState();

   //--- draw the panel straight away so the user sees the engine is alive
   //--- even before the first tick / while history is still downloading
   g_status = "initialising";
   UpdatePanel();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|                         OnDeinit                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjDelPrefix(g_pfx);
   if(g_hEMA_L    != INVALID_HANDLE) IndicatorRelease(g_hEMA_L);
   if(g_hATR_L    != INVALID_HANDLE) IndicatorRelease(g_hATR_L);
   if(g_mid.hEMA  != INVALID_HANDLE) IndicatorRelease(g_mid.hEMA);
   if(g_mid.hATR  != INVALID_HANDLE) IndicatorRelease(g_mid.hATR);
   if(g_high.hEMA != INVALID_HANDLE) IndicatorRelease(g_high.hEMA);
   if(g_high.hATR != INVALID_HANDLE) IndicatorRelease(g_high.hATR);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|                        OnChartEvent                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
      UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Early exit from OnCalculate that still tells the user WHY.        |
//| Never `return` out of OnCalculate without going through this, or  |
//| the chart goes blank with no explanation - which reads as a       |
//| broken indicator when it is usually just missing history.         |
//+------------------------------------------------------------------+
int QrcBail(const string why, const int ret)
  {
   g_status = why;
   UpdatePanel();
   return ret;
  }

//+------------------------------------------------------------------+
//|                        OnCalculate                               |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < g_warmup + 20)
      return QrcBail("chart history too short: need " +
                     IntegerToString(g_warmup + 20) + " bars, have " +
                     IntegerToString(rates_total), 0);

   ArraySetAsSeries(time,        false);
   ArraySetAsSeries(open,        false);
   ArraySetAsSeries(high,        false);
   ArraySetAsSeries(low,         false);
   ArraySetAsSeries(close,       false);
   ArraySetAsSeries(tick_volume, false);
   ArraySetAsSeries(spread,      false);

   const bool full = (prev_calculated <= 0);

   //--- higher-timeframe contexts: rebuilt only when those TFs print a new bar
   if(!BuildTFCtx(g_mid,  full))
      return QrcBail("loading " + TFName(g_tfMid) + " history (need " +
                     IntegerToString(MaxLookback() + 5) + " bars)", prev_calculated);
   if(!BuildTFCtx(g_high, full))
      return QrcBail("loading " + TFName(g_tfHigh) + " history (need " +
                     IntegerToString(MaxLookback() + 5) + " bars)", prev_calculated);

   //--- signal-timeframe EMA / ATR (series-indexed: [0] = forming bar)
   g_lCount = MathMin(rates_total, InpMaxBars + g_warmup + 50);
   ArraySetAsSeries(g_emaL, true);
   ArraySetAsSeries(g_atrL, true);
   if(CopyBuffer(g_hEMA_L, 0, 0, g_lCount, g_emaL) < g_lCount)
      return QrcBail("waiting for " + TFName((ENUM_TIMEFRAMES)_Period) + " EMA buffer", prev_calculated);
   if(CopyBuffer(g_hATR_L, 0, 0, g_lCount, g_atrL) < g_lCount)
      return QrcBail("waiting for " + TFName((ENUM_TIMEFRAMES)_Period) + " ATR buffer", prev_calculated);

   int start;
   if(full)
     {
      ArrayInitialize(BufBuy,    EMPTY_VALUE);
      ArrayInitialize(BufSell,   EMPTY_VALUE);
      ArrayInitialize(BufScore,  0.0);
      ArrayInitialize(BufRegime, 0.0);
      ArrayInitialize(BufDir,    0.0);
      ArrayInitialize(BufSL,     EMPTY_VALUE);
      ArrayInitialize(BufTP,     EMPTY_VALUE);
      ResetState();
      start = MathMax(g_warmup + 2, rates_total - InpMaxBars);
     }
   else
      start = MathMax(g_warmup + 2, prev_calculated - 2);

   //--- the forming bar is always cleared and never evaluated
   const int last = rates_total - 1;
   BufBuy[last]    = EMPTY_VALUE;
   BufSell[last]   = EMPTY_VALUE;
   BufSL[last]     = EMPTY_VALUE;
   BufTP[last]     = EMPTY_VALUE;
   BufScore[last]  = 0.0;
   BufRegime[last] = 0.0;
   BufDir[last]    = 0.0;

   const int psL = PeriodSeconds(_Period);

   for(int i = start; i <= rates_total - 2 && !IsStopped(); i++)
     {
      //--- never re-process a bar that has already been scored:
      //--- this keeps the statistics and the drawn objects idempotent
      if(time[i] <= g_lastBarTime) continue;

      //--- 1) resolve outstanding signals against this newly closed bar
      UpdateOpenSignals(i, high, low, close);

      //--- 2) map to the last CLOSED higher-timeframe bars (non-repaint core)
      const datetime tClose = time[i] + (datetime)psL;
      const int jm = MapClosedIndex(g_mid,  tClose);
      const int jh = MapClosedIndex(g_high, tClose);

      const int lb = MaxLookback();
      if(jm < lb || jh < lb)
        {
         g_lastBarTime = time[i];
         continue;
        }

      const int s = rates_total - 1 - i;          // series index for EMA/ATR arrays
      if(s < 0 || s >= g_lCount) { g_lastBarTime = time[i]; continue; }

      const double atrL = g_atrL[s];
      const double emaL = g_emaL[s];
      const double emaLp = (s + 1 < g_lCount ? g_emaL[s+1] : emaL);
      if(atrL <= 0.0) { g_lastBarTime = time[i]; continue; }

      //--- 3) signal-timeframe features (computed on closed bars only)
      double vrL = 1.0;
      const double zvrL   = CalcVarRatio(close, i, InpRetLookback, InpVRq, vrL);
      const double ernL   = CalcERn(close, i, InpERPeriod);
      const double tL     = CalcSlopeT(close, i, InpSlopePeriod);
      const double fL     = CalcVarF(close, i, InpVolFast, InpVolSlow);
      const double driftL = CalcDriftZ(close, i, InpVolFast);

      const double tM     = g_mid.fT[jm];
      const double driftM = g_mid.fDrift[jm];
      const double tH     = g_high.fT[jh];

      //--- 4) regime, measured on the selected timeframe
      double rERn, rT, rVR, rVRz, rF;
      if(InpRegimeSrc == REG_HIGH)
        { rERn = g_high.fERn[jh]; rT = g_high.fT[jh]; rVR = g_high.fVR[jh]; rVRz = g_high.fVRz[jh]; rF = g_high.fF[jh]; }
      else if(InpRegimeSrc == REG_MID)
        { rERn = g_mid.fERn[jm];  rT = g_mid.fT[jm];  rVR = g_mid.fVR[jm];  rVRz = g_mid.fVRz[jm];  rF = g_mid.fF[jm];  }
      else
        { rERn = ernL; rT = tL; rVR = vrL; rVRz = zvrL; rF = fL; }

      double conf = 0.0;
      const ENUM_QRC_REGIME reg = ClassifyRegime(rERn, rT, rVRz, rF, conf);

      BufRegime[i] = (double)reg;

      //--- 5) structural direction from the high timeframe
      int dir = 0;
      const double emaH = g_high.ema[jh];
      const double clH  = g_high.cl[jh];
      if(tH >= InpSlopeT  && clH > emaH) dir =  1;
      if(tH <= -InpSlopeT && clH < emaH) dir = -1;

      //--- 6) hard vetoes -------------------------------------------------
      bool regimeOK = (reg == QRC_TREND) ||
                      (InpAllowExpansion && reg == QRC_EXPANSION);
      if(conf < InpMinRegimeConf) regimeOK = false;

      //--- mid timeframe must not oppose the high-timeframe structure
      bool midOK = false;
      if(dir > 0) midOK = (driftM > 0.0 && g_mid.cl[jm] > g_mid.ema[jm]);
      if(dir < 0) midOK = (driftM < 0.0 && g_mid.cl[jm] < g_mid.ema[jm]);

      //--- 7) signal-timeframe trigger ------------------------------------
      const double rng  = high[i] - low[i];
      const double body = MathAbs(close[i] - open[i]);
      const double bodyRatio = SafeDiv(body, rng, 0.0);
      const double displATR  = SafeDiv(close[i] - open[i], atrL, 0.0) * (dir >= 0 ? 1.0 : -1.0);

      //--- pullback to value must have occurred inside the lookback window
      bool pulled = false;
      const int pb = MathMax(2, InpPullbackBars);
      for(int k = i - pb; k <= i - 1; k++)
        {
         if(k < 1) continue;
         const int sk = rates_total - 1 - k;
         if(sk < 0 || sk >= g_lCount) continue;
         const double ek = g_emaL[sk];
         if(dir > 0 && low[k]  <= ek + InpPullTolATR * atrL) { pulled = true; break; }
         if(dir < 0 && high[k] >= ek - InpPullTolATR * atrL) { pulled = true; break; }
        }

      bool trigger = false;
      if(dir > 0)
         trigger = pulled
                && close[i] > open[i]
                && close[i] > high[i-1]
                && close[i] > emaL
                && close[i] > close[i - MathMax(1, InpMomBars)]
                && bodyRatio >= InpMinBodyRatio
                && displATR  >= InpMinDisplATR
                && emaL >= emaLp;
      else if(dir < 0)
         trigger = pulled
                && close[i] < open[i]
                && close[i] < low[i-1]
                && close[i] < emaL
                && close[i] < close[i - MathMax(1, InpMomBars)]
                && bodyRatio >= InpMinBodyRatio
                && displATR  >= InpMinDisplATR
                && emaL <= emaLp;

      //--- 8) confluence count and volume z-score -------------------------
      int agree = 0;
      if(dir != 0)
        {
         if((dir > 0 && tH     > 0.0) || (dir < 0 && tH     < 0.0)) agree++;
         if((dir > 0 && driftM > 0.0) || (dir < 0 && driftM < 0.0)) agree++;
         if((dir > 0 && driftL > 0.0) || (dir < 0 && driftL < 0.0)) agree++;
        }

      double volZ = 0.0;
      if(i - InpVolZPeriod >= 0 && InpVolZPeriod > 2)
        {
         double sv = 0.0, sv2 = 0.0;
         for(int k = i - InpVolZPeriod + 1; k <= i; k++)
           {
            const double v = (double)tick_volume[k];
            sv  += v;
            sv2 += v * v;
           }
         const double mv = sv / InpVolZPeriod;
         const double vv = (sv2 - InpVolZPeriod * mv * mv) / (InpVolZPeriod - 1);
         const double sd = (vv > 0.0 ? MathSqrt(vv) : 0.0);
         volZ = (sd > 0.0 ? Clamp(((double)tick_volume[i] - mv) / sd, -6.0, 6.0) : 0.0);
        }

      const double distValATR = SafeDiv(MathAbs(close[i] - emaL), atrL * 2.0, 1.0);

      //--- 9) logistic score ----------------------------------------------
      double score = 0.0;
      if(dir != 0)
         score = SignalScore(dir, tH, driftM, driftL, rERn, rVRz, reg, conf,
                             distValATR, displATR, volZ, agree);

      BufScore[i] = score;
      BufDir[i]   = (double)dir;
      BufBuy[i]   = EMPTY_VALUE;
      BufSell[i]  = EMPTY_VALUE;
      BufSL[i]    = EMPTY_VALUE;
      BufTP[i]    = EMPTY_VALUE;

      //--- 10) fire -------------------------------------------------------
      const bool spacingOK = (BarsSinceLastSignal(i) >= InpMinBarsBetween);
      const bool slotOK    = (!InpOneAtATime || !HasOpenSignal());

      if(dir != 0 && trigger && regimeOK && midOK && agree >= 2 &&
         score >= InpScoreThreshold && spacingOK && slotOK)
        {
         //--- dynamic risk: ATR scaled by the regime variance ratio
         const double volAdj = Clamp(MathSqrt(MathMax(rF, 0.01)), InpVolAdjMin, InpVolAdjMax);
         double risk = InpATRmultSL * atrL * volAdj;

         if(InpSLMode == SL_STRUCTURE)
           {
            const int a = MathMax(0, i - MathMax(2, InpSwingLookback) + 1);
            double sw = (dir > 0 ? low[a] : high[a]);
            for(int k = a; k <= i; k++)
              {
               if(dir > 0) sw = MathMin(sw, low[k]);
               else        sw = MathMax(sw, high[k]);
              }
            const double structRisk = MathAbs(close[i] - sw) + 0.25 * atrL;
            risk = MathMax(risk, structRisk);
           }

         if(risk <= _Point) risk = 2.0 * atrL;

         const double entry = close[i];
         const double sl    = (dir > 0 ? entry - risk : entry + risk);
         const double tp    = (dir > 0 ? entry + risk * InpRR : entry - risk * InpRR);

         if(dir > 0) BufBuy[i]  = low[i]  - InpArrowATROffset * atrL;
         else        BufSell[i] = high[i] + InpArrowATROffset * atrL;
         BufSL[i] = sl;
         BufTP[i] = tp;

         const int n = ArraySize(g_sigs);
         ArrayResize(g_sigs, n + 1);
         g_sigs[n].tm     = time[i];
         g_sigs[n].dir    = dir;
         g_sigs[n].entry  = entry;
         g_sigs[n].sl     = sl;
         g_sigs[n].tp     = tp;
         g_sigs[n].risk   = risk;
         g_sigs[n].bar    = i;
         g_sigs[n].held   = 0;
         g_sigs[n].isOpen = true;
         g_sigs[n].rMult  = 0.0;
         g_nSig++;
         g_nOpen++;

         DrawSignalLevels(time[i], dir, entry, sl, tp);

         g_liveLast = (dir > 0 ? "BUY  " : "SELL ") +
                      DoubleToString(entry, _Digits) + "  @ " +
                      TimeToString(time[i], TIME_DATE | TIME_MINUTES);

         //--- alerts fire on the CLOSE of the signal bar, once per bar
         if(i == rates_total - 2 && time[i] > g_lastAlert)
           {
            g_lastAlert = time[i];
            const string msg = StringFormat("QRC %s %s: %s  score %.1f  regime %s  SL %s  TP %s",
                                            _Symbol, TFName((ENUM_TIMEFRAMES)_Period),
                                            (dir > 0 ? "BUY" : "SELL"), score, RegimeName(reg),
                                            DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
            if(InpAlertPopup) Alert(msg);
            if(InpAlertPush)  SendNotification(msg);
           }
        }

      //--- 11) dashboard snapshot from the most recent closed bar
      if(i == rates_total - 2)
        {
         g_liveRegime = reg;
         g_liveConf   = conf;
         g_liveF      = rF;
         g_liveERn    = rERn;
         g_liveVR     = rVR;
         g_liveVRz    = rVRz;
         g_liveHurst  = ImpliedHurst(rVR, InpVRq);
         g_liveTH     = tH;
         g_liveTM     = tM;
         g_liveTL     = tL;
         g_liveScore  = score;
         g_liveDir    = dir;
        }

      g_lastBarTime = time[i];
     }

   g_status = "";                 // a full pass completed: panel shows live data
   UpdatePanel();
   return rates_total;
  }
//+------------------------------------------------------------------+
