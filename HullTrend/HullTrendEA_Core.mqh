//+------------------------------------------------------------------+
//|                                              HullTrendEA_Core.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Trades the trend flips published by HullTrend_MT5.                |
//|                                                                   |
//| DESIGN NOTES                                                      |
//|                                                                   |
//| 1. Signals are read from the COLOUR buffer (index 1), never from  |
//|    the arrow buffers. The arrows are derived from the same state  |
//|    machine, so they carry no extra information, and reading the   |
//|    colour makes the current trend available on every bar - which  |
//|    the higher-timeframe filter needs.                             |
//|                                                                   |
//| 2. Entries act on the last CLOSED bar only (shift 1). The         |
//|    indicator recomputes the forming bar on every tick, so a       |
//|    shift-0 read would repaint and make backtests fiction.         |
//|                                                                   |
//| 3. This is a stop-and-reverse trend follower. The natural exit is |
//|    the opposite flip; the stop is a disaster brake, not a target. |
//|                                                                   |
//| 4. A flip ARMS a signal rather than firing a single shot at it.   |
//|    The guards are then re-tested every tick for InpSignalArmBars  |
//|    bars. Two problems fall out of this. First, a reversal whose   |
//|    own close-out had not settled yet used to be vetoed by the     |
//|    position limit and lost forever - the EA closed the old trade  |
//|    and never opened the new one, which is the worst possible half |
//|    of a stop-and-reverse. Second, the HTF filter vetoing the flip |
//|    bar used to discard the whole move even when the HTF agreed    |
//|    two bars later. The drift guard is what expires a stale arm:   |
//|    the signal keeps the ORIGINAL bar close, so as price runs the  |
//|    measured drift grows until the trade is no longer the one the  |
//|    model asked for.                                               |
//|                                                                   |
//| 5. Support and resistance are used to VETO and to TAKE PROFIT,    |
//|    never to generate an entry. Bounce trading is a different      |
//|    strategy with a different edge and a different stop; mixing it |
//|    in here would make both untestable. Levels are clustered pivot |
//|    fractals confirmed k bars after the fact, so they never        |
//|    repaint.                                                       |
//|                                                                   |
//| 6. COST WARNING. An HMA flip system pays the spread on every      |
//|    reversal. Round-trip cost as a fraction of ATR(14) is roughly  |
//|    0.5-0.9x on M1 FX, 0.25-0.4x on M5 and 0.12-0.2x on M15. M1 on |
//|    retail FX does not clear its own costs. M5 is the practical    |
//|    floor for majors; M1 only makes sense where the spread is tiny |
//|    relative to the range (index CFDs, futures).                   |
//|                                                                   |
//| LOG FORMAT                                                        |
//|   Every line is "HullEA | TAG | ...", one record per line, so the |
//|   whole Experts tab can be pasted somewhere and read back. Tags:  |
//|     ENV    once at startup - symbol and broker facts              |
//|     BAR    one closed bar (level 3 only - noisy on M1)            |
//|     FLIP   the indicator changed trend                            |
//|     ARM    a flip is waiting for its guards to clear              |
//|     ENTRY  an order was placed                                    |
//|     VETO   a flip was NOT traded, and why                         |
//|     STOP   a stop was moved (break-even or trailing)              |
//|     CLOSE  a position ended, with its R multiple and the reason   |
//|     SUM    running totals, every InpSummaryBars bars and at exit  |
//|     ERROR  something failed                                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Market profile                                                   |
//|                                                                  |
//| The wrapper .mq5 defines one of these before including this file. |
//| ONLY DEFAULTS differ between profiles - every one runs identical  |
//| logic, so a fix made here reaches all of them. Nothing is locked: |
//| each value below is still an input the user can override in the   |
//| dialog. The magic numbers differ deliberately, so two profiles    |
//| on the same symbol cannot manage each other's positions.          |
//+------------------------------------------------------------------+
#ifdef HULL_PROFILE_CRYPTO
   #define DEF_PROFILE_NAME    "crypto"
   #define DEF_MIN_TF          PERIOD_H1    // below H1 the spread eats the edge
   #define DEF_SLOPE_ATR_MUL   0.25         // crypto ranges are wider - flip less
   #define DEF_SL_MUL_ATR      2.25         // fat tails: 1.5xATR is too thin
   #define DEF_MAX_SPREAD_ATR  0.30         // ~0.17 baseline at H1, block blowouts
   #define DEF_RISK_PCT        0.50
   #define DEF_NO_FRIDAY_LATE  false        // 24/7 market, no Friday close
   #define DEF_MAX_DAILY_LOSS  4.0
   #define DEF_SR_VETO_ATR     0.60         // wider ranges - less room ahead is normal
   #define DEF_MAGIC           20260828
   #define DEF_COMMENT         "HullCrypto"
#endif

#ifdef HULL_PROFILE_FOREX
   #define DEF_PROFILE_NAME    "forex"
   #define DEF_MIN_TF          PERIOD_M5    // M1 majors cannot pay their own spread
   #define DEF_SLOPE_ATR_MUL   0.20
   #define DEF_SL_MUL_ATR      1.50
   #define DEF_MAX_SPREAD_ATR  0.25
   #define DEF_RISK_PCT        0.50
   #define DEF_NO_FRIDAY_LATE  true         // weekend gap risk is real in FX
   #define DEF_MAX_DAILY_LOSS  3.0
   #define DEF_SR_VETO_ATR     0.75
   #define DEF_MAGIC           20260827
   #define DEF_COMMENT         "HullFX"
#endif

//--- no profile defined: the v1.20 defaults, unchanged
#ifndef DEF_PROFILE_NAME
   #define DEF_PROFILE_NAME    "generic"
   #define DEF_MIN_TF          PERIOD_M5
   #define DEF_SLOPE_ATR_MUL   0.20
   #define DEF_SL_MUL_ATR      1.50
   #define DEF_MAX_SPREAD_ATR  0.25
   #define DEF_RISK_PCT        0.50
   #define DEF_NO_FRIDAY_LATE  true
   #define DEF_MAX_DAILY_LOSS  3.0
   #define DEF_SR_VETO_ATR     0.75
   #define DEF_MAGIC           20260826
   #define DEF_COMMENT         "HullTrend"
#endif

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Number of arguments CreateHullHandle() must pass to iCustom: every input
//--- HullTrend_MT5 declares PLUS one slot per `input group`. Asserted against
//--- the live handle at OnInit, because getting it wrong is silent.
#define HULL_ICUSTOM_ARGS 24

//--- must mirror HullTrend_MT5.mq5 (same order, same values)
enum ENUM_SLOPE_FILTER_EA
  {
   EA_SLOPE_NONE   = 0, // Off - any slope change flips the trend
   EA_SLOPE_POINTS = 1, // Fixed - minimum slope in points
   EA_SLOPE_ATR    = 2  // Adaptive - minimum slope as a fraction of ATR
  };

enum ENUM_SL_MODE
  {
   SL_ATR   = 0, // ATR multiple below/above the fill
   SL_SWING = 1, // Recent swing / S-R level, padded by ATR
   SL_HMA   = 2  // The Hull line itself, padded by ATR
  };

enum ENUM_LOG_LEVEL
  {
   LOGL_OFF       = 0, // Off - errors only
   LOGL_EVENTS    = 1, // Events - flips, trades, summaries
   LOGL_DECISIONS = 2, // Decisions - every veto with its numbers
   LOGL_BARS      = 3  // Bars - one line per closed bar (short runs only)
  };

//--- why a flip did not become a trade. Every reject path returns one of
//--- these instead of just logging, so the summary can count them.
enum ENUM_VETO
  {
   VETO_NONE = 0,
   VETO_POSLIMIT,
   VETO_SAMEDIR,
   VETO_HTF,
   VETO_TIME,
   VETO_DAILYLOSS,
   VETO_TRADECAP,
   VETO_BARGAP,
   VETO_SPREAD,
   VETO_SR,
   VETO_STOPSIDE,
   VETO_DRIFT,
   VETO_LOTS,
   VETO_MARGIN,
   VETO_ORDERFAIL,
   VETO_COUNT
  };

//--- colour indices published by the indicator
#define TREND_UP   0
#define TREND_DOWN 1

//--- indicator buffer indices
#define BUF_HMA    0
#define BUF_COLOR  1

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "======== A. Signal (forwarded to the indicator) ========"
input int                  InpHMAPeriod    = 20;            // Hull period
input ENUM_APPLIED_PRICE   InpHMAPrice     = PRICE_CLOSE;   // Applied price
input ENUM_SLOPE_FILTER_EA InpSlopeFilter  = EA_SLOPE_ATR;  // Slope threshold mode
input double               InpSlopeATRMul  = DEF_SLOPE_ATR_MUL;   // ATR mode: slope must exceed ATR x this
input int                  InpATRPeriod    = 14;            // ATR mode: ATR period
input double               InpSlopePoints  = 0.0;           // Points mode: minimum slope (points)
input int                  InpConfirmBars  = 1;             // Counter-trend bars needed to flip
input int                  InpConfirmWindow = 0;            // Bars a pending flip stays alive (0 = 3x confirm bars)
input int                  InpSignalArmBars = 3;            // Bars a vetoed flip keeps retrying (0 = flip bar only)

input group "======== B. Higher-timeframe filter ========"
input bool                 InpUseHTF       = true;          // Only trade with the higher TF trend
input bool                 InpHTFAuto      = true;          // Auto-derive the higher TF from the chart TF
input ENUM_TIMEFRAMES      InpHTF          = PERIOD_H1;     // Higher TF (when Auto = false)
input double               InpHTFMult      = 12.0;          // Auto: target HTF as a multiple of the chart TF
input int                  InpHTFShift     = 1;             // HTF bar to read (1 = closed, 0 = forming/repaints)

input group "======== C. Risk and sizing ========"
input double               InpRiskPercent  = DEF_RISK_PCT;  // Risk per trade (% of balance)
input double               InpFixedLots    = 0.0;           // Fixed lots (>0 overrides risk %)
input double               InpMaxLots      = 5.0;           // Hard lot cap
input ENUM_SL_MODE         InpSLMode       = SL_ATR;        // Stop placement
input double               InpSLmulATR     = DEF_SL_MUL_ATR;// SL distance (x ATR) - ATR mode
input int                  InpSwingBars    = 12;            // Swing lookback (bars) - Swing mode
input double               InpSLpadATR     = 0.30;          // SL padding (x ATR) - Swing / HMA modes
input double               InpTPmulR       = 0.0;           // Take profit (R). 0 = none, exit on flip
input int                  InpSlippagePts  = 20;            // Max deviation (points)

input group "======== D. Trade management ========"
input bool                 InpCloseOnFlip  = true;          // Close on the opposite flip (stop and reverse)
input int                  InpMaxPositions = 1;             // Max simultaneous positions
input bool                 InpUseBreakEven = true;          // Move stop to break-even
input double               InpBEatR        = 1.00;          // Break-even trigger (R)
input double               InpBEoffsetPts  = 5.0;           // Break-even offset (points, covers costs)
input bool                 InpUseTrailing  = true;          // Trail the stop
input double               InpTrailStartR  = 1.50;          // Start trailing at (R)
input double               InpTrailDistR   = 1.00;          // Trail distance (R)
input double               InpTrailStepR   = 0.10;          // Min stop advance before modifying (R, 0 = every tick)

input group "======== E. Guards ========"
input double               InpMaxSpreadATR = DEF_MAX_SPREAD_ATR;  // Reject if spread > this x ATR (0 = off)
input double               InpMaxSpreadPts = 0.0;           // Reject if spread > this many points (0 = off)
input double               InpMaxDriftR    = 0.35;          // Reject if price drifted > this x risk
input int                  InpMinBarsGap   = 0;             // Min bars between entries (0 = off)
input bool                 InpUseTimeFilter = false;        // Restrict trading hours (server time)
input int                  InpStartHour    = 7;             // Start hour
input int                  InpEndHour      = 20;            // End hour
input bool                 InpNoFridayLate = DEF_NO_FRIDAY_LATE;  // No new trades late Friday
input int                  InpFridayStopHour = 19;          // Friday cut-off hour
input bool                 InpFlattenOnFriday = true;       // Also CLOSE open trades at the Friday cut-off
input double               InpMaxDailyLossPct = DEF_MAX_DAILY_LOSS;  // Halt for the day after this % loss (0 = off)
input bool                 InpFlattenOnLoss = true;         // Also CLOSE open trades when the daily limit hits
input int                  InpMaxTradesPerDay = 0;          // Max new trades per day (0 = unlimited)

input group "======== F. Support and resistance ========"
input bool                 InpUseSR        = true;          // Build S/R levels from pivot fractals
input int                  InpSRFractal    = 3;             // Bars each side of a pivot (confirmation lag)
input int                  InpSRLookback   = 400;           // Bars scanned on the trading TF
input bool                 InpSRUseHTF     = true;          // Also scan the higher timeframe
input double               InpSRClusterATR = 0.50;          // Merge pivots closer than this x ATR
input int                  InpSRMinTouches = 2;             // Ignore levels with fewer touches than this
input int                  InpSRMaxAgeBars = 0;             // Drop levels older than N bars (0 = 20 x Hull period)
input double               InpSRVetoATR    = DEF_SR_VETO_ATR;  // Veto if the level ahead is nearer than this x ATR (0 = off)
input double               InpSRTargetPart = 0.50;          // Fraction closed at the level ahead (0 = off)
input bool                 InpSRStop       = true;          // Swing mode places the stop at an S/R level
input bool                 InpSRDraw       = false;         // Draw the levels on the chart

input group "======== G. Logging ========"
input ENUM_LOG_LEVEL       InpLogLevel     = LOGL_DECISIONS; // Log level
input int                  InpSummaryBars  = 240;           // Print a running summary every N closed bars
input long                 InpMagic        = DEF_MAGIC;     // Magic number
input string               InpComment      = DEF_COMMENT;   // Order comment

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
CTrade        g_trade;
CPositionInfo g_pos;

int      g_hHull    = INVALID_HANDLE;   // indicator on the trading TF
int      g_hHullHTF = INVALID_HANDLE;   // indicator on the higher TF
int      g_hATR     = INVALID_HANDLE;   // ATR for sizing and the spread guard
ENUM_TIMEFRAMES g_htf = PERIOD_CURRENT;

datetime g_lastBar      = 0;
datetime g_lastEntryBar = 0;

//--- per-position R tracking
struct TrackRec
  {
   ulong             ticket;
   double            entry;
   double            risk;        // original stop distance in price units
   int               dir;
   bool              beDone;
   double            target;      // S/R level ahead at entry, 0 = none
   bool              targetHit;   // price actually reached that level
   int               partialTries;// failed partial-close attempts so far
   bool              partialDone; // ...and the partial has been settled, either way
  };
TrackRec g_track[];

//--- daily guards. The baseline is BALANCE at the roll, not equity: equity at
//--- midnight carries whatever was floating on an open position, so a day that
//--- opened inside a drawdown started from an artificially low bar and the halt
//--- fired late.
datetime g_dayStart        = 0;
double   g_dayStartBalance = 0.0;
int      g_tradesToday     = 0;
bool     g_dayBlocked      = false;
datetime g_lastFlatten     = 0;      // throttles the halt's close attempts

//--- armed flip waiting for its guards (see design note 4)
struct HullSignal
  {
   bool              flip;    // the trend changed on the signal bar
   int               dir;     // +1 up, -1 down: the trend AS OF the signal bar
   double            hma;     // Hull value on the signal bar
   double            atr;     // ATR on the signal bar
   double            entry;   // close of the signal bar - what the model assumed
  };
HullSignal g_armSig;
int      g_armDir       = 0;      // 0 = nothing armed
int      g_armBarsLeft  = 0;
bool     g_armLogged    = false;  // a veto has been logged for the current bar

//--- support / resistance
struct SRLevel
  {
   double            price;
   int               touches;
   datetime          last;
  };
SRLevel g_sr[];

//--- data-not-ready watchdogs. A handle that never fills makes the EA look
//--- like a strategy that simply never signals, with nothing in the log.
int      g_sigStall = 0;
int      g_htfStall = 0;
#define  STALL_ALARM 100

//--- diagnostics. None of this influences trading; it exists so a log can be
//--- read back and the behaviour reconstructed without the chart.
int      g_barsSeen   = 0;
int      g_nFlips     = 0;
int      g_nEntries   = 0;
int      g_nClosed    = 0;
int      g_nWins      = 0;
double   g_sumR       = 0.0;
int      g_veto[VETO_COUNT];
int      g_closeSL    = 0;
int      g_closeTP    = 0;
int      g_closeFlip  = 0;
int      g_closeOther = 0;
double   g_sprSum     = 0.0;   // spread as a multiple of ATR, sampled per bar
double   g_sprMax     = 0.0;
int      g_sprN       = 0;
int      g_nStopMods  = 0;
int      g_nStopFails = 0;
int      g_nArmed     = 0;
int      g_nArmLate   = 0;     // entries that needed the arm window
int      g_nArmExpire = 0;
int      g_nPartials  = 0;

//--- How much room the nearest level ahead actually leaves, sampled once per
//--- closed bar. Without this the S/R veto is unfalsifiable: a threshold set
//--- above the typical spacing between levels rejects everything, and the only
//--- symptom is an EA that stops trading. Compare it against InpSRVetoATR.
double   g_srRoomSum  = 0.0;
int      g_srRoomN    = 0;
int      g_lastSumBar = 0;
bool     g_preflight  = false;

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void LogAt(const int level, const string tag, const string msg)
  {
   if(InpLogLevel >= level)
      Print("HullEA | ", tag, " | ", msg);
  }

//--- errors bypass the level: a silent failure is the one thing that must
//--- never be tuned out
void LogErr(const string msg)
  {
   Print("HullEA | ERROR | ", msg);
  }

string VetoName(const ENUM_VETO v)
  {
   switch(v)
     {
      case VETO_NONE:      return "none";
      case VETO_POSLIMIT:  return "pos-limit";
      case VETO_SAMEDIR:   return "same-dir";
      case VETO_HTF:       return "htf-disagrees";
      case VETO_TIME:      return "out-of-hours";
      case VETO_DAILYLOSS: return "daily-loss";
      case VETO_TRADECAP:  return "trade-cap";
      case VETO_BARGAP:    return "bar-gap";
      case VETO_SPREAD:    return "spread";
      case VETO_SR:        return "no-room-to-level";
      case VETO_STOPSIDE:  return "stop-wrong-side";
      case VETO_DRIFT:     return "drift";
      case VETO_LOTS:      return "lots-too-small";
      case VETO_MARGIN:    return "margin";
      case VETO_ORDERFAIL: return "order-failed";
      default:             return "?";
     }
  }

string DirName(const int dir)
  {
   if(dir > 0) return "UP";
   if(dir < 0) return "DOWN";
   return "flat";
  }

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double Pt()          { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
double Ask()         { return SymbolInfoDouble(_Symbol, SYMBOL_ASK);   }
double Bid()         { return SymbolInfoDouble(_Symbol, SYMBOL_BID);   }
double SpreadPrice() { return Ask() - Bid(); }
double SpreadPts()   { const double p = Pt(); return (p > 0.0 ? SpreadPrice() / p : 0.0); }

//--- Broker minimum distance for a NEW stop, in price units. The freeze level
//--- is a different rule - it governs how close to price an EXISTING order may
//--- be touched - so folding it in here made every initial stop wider than the
//--- broker actually requires on symbols that publish a large freeze band.
double StopsDist()
  {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * Pt();
}

//--- ...and the distance that matters when MODIFYING an existing stop, where
//--- both rules apply.
double ModifyDist()
  {
   const long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long frz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(lvl, frz) * Pt();
  }

double NormPrice(const double p)
  {
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

//--- Decimal places implied by the broker's volume step. Hard-coding 2 here
//--- silently destroyed sizing on any symbol with a finer step: on a 0.001-step
//--- crypto CFD a correctly computed 0.003 lots was normalised to 0.00 and the
//--- order was rejected, while 0.005 became 0.01 - double the intended risk.
int VolDigits()
  {
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 2;
   int    d = 0;
   double s = step;
   while(s < 1.0 - 1e-12 && d < 8)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

//--- One place that turns any desired size into a volume the broker will
//--- accept. The cap is applied BEFORE the step rounding, because a cap that
//--- is not itself a multiple of the step would otherwise produce an off-step
//--- volume and an "invalid volume" rejection.
double ClampLots(const double raw)
  {
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double cap = (maxL > 0.0 ? maxL : raw);
   if(InpMaxLots > 0.0)
      cap = MathMin(cap, InpMaxLots);

   double lots = MathMin(raw, cap);
   if(lots <= 0.0)
      return 0.0;

   if(step > 0.0)
     {
      lots = MathFloor(lots / step + 1e-9) * step;
      while(lots > cap + 1e-9)
         lots -= step;
     }
   if(lots < 0.0)
      lots = 0.0;
   return NormalizeDouble(lots, VolDigits());
  }

//--- EMPTY_VALUE is 1.79e308: arithmetic on it produces inf, so every value
//--- read out of an indicator buffer has to be screened before it is used
bool UsableValue(const double v)
  {
   return (v != EMPTY_VALUE && MathIsValidNumber(v) && MathAbs(v) < 1e30);
  }

//+------------------------------------------------------------------+
//| Candidate higher timeframes.                                     |
//|                                                                  |
//| Deliberately a SUBSET of what MT5 offers. M2/M3/M6/M12, H2/H3/H6 |
//| and friends are perfectly good CHART timeframes but poor regime  |
//| filters, and excluding them is what lets the formula below       |
//| reproduce the original hand-written ladder exactly while also    |
//| covering the timeframes that ladder had no answer for.           |
//+------------------------------------------------------------------+
#define HTF_CANDIDATES 8

ENUM_TIMEFRAMES HTFCandidate(const int i)
  {
   switch(i)
     {
      case 0:
         return PERIOD_M5;
      case 1:
         return PERIOD_M15;
      case 2:
         return PERIOD_M30;
      case 3:
         return PERIOD_H1;
      case 4:
         return PERIOD_H4;
      case 5:
         return PERIOD_D1;
      case 6:
         return PERIOD_W1;
      default:
         return PERIOD_MN1;
     }
  }

//+------------------------------------------------------------------+
//| Higher timeframe selection.                                      |
//|                                                                  |
//| Targets InpHTFMult x the chart timeframe and snaps to the        |
//| nearest candidate above. The previous version was a lookup table |
//| covering eight chart timeframes; every other one fell through to |
//| a default that returned the chart TF itself, which made OnInit   |
//| disable the filter. H2, H6, H8 and H12 are ordinary choices, so  |
//| that gap disabled the single most important filter in the system |
//| on one log line at startup.                                     |
//|                                                                  |
//| Resolves identically to the old table on all eight timeframes it |
//| did handle: M1->M15, M5->H1, M15->H4, M30->H4, H1->D1, H4->D1,   |
//| D1->W1. Nothing that already worked changes.                     |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES PickHTF()
  {
   if(!InpHTFAuto)
      return (InpHTF == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpHTF);

   const double chart = (double)PeriodSeconds((ENUM_TIMEFRAMES)_Period);
   if(chart <= 0.0)
      return (ENUM_TIMEFRAMES)_Period;

   const double mult   = (InpHTFMult < 2.0 ? 2.0 : InpHTFMult);
   const double target = chart * mult;

   ENUM_TIMEFRAMES best = (ENUM_TIMEFRAMES)_Period;
   double          bestErr = 0.0;
   bool            found   = false;

   for(int i = 0; i < HTF_CANDIDATES; i++)
     {
      const ENUM_TIMEFRAMES tf = HTFCandidate(i);
      const double secs = (double)PeriodSeconds(tf);
      if(secs <= chart)
         continue;                  // a "higher" timeframe has to be higher

      //--- Error measured in LOG space, so being 2x under target and 2x over
      //--- it count the same. A linear metric would bias every choice upward,
      //--- because the candidates get further apart as they get larger.
      const double err = MathAbs(MathLog(secs / target));
      if(!found || err < bestErr - 1e-9)
        {
         found   = true;
         best    = tf;
         bestErr = err;
        }
     }

   //--- Candidates ascend and the comparison above is strict, so an exact tie
   //--- keeps the SMALLER timeframe - the more responsive of the two.
   return (found ? best : (ENUM_TIMEFRAMES)_Period);
  }

//+------------------------------------------------------------------+
//| Build an indicator handle.                                       |
//|                                                                  |
//| iCustom arguments are POSITIONAL, and `input group` occupies a    |
//| slot of its own - verified against this build's Experts log, where |
//| an EA-created handle reports the profile's atrMul while a hand-    |
//| attached copy of the same indicator reports its own default.       |
//| HullTrend_MT5 declares 20 parameters spread over 4 groups, so this |
//| call must pass 24 arguments with a placeholder at every group      |
//| position. Getting it wrong fails SILENTLY: the values shift one    |
//| slot left and the indicator simply runs with the wrong settings.   |
//| CheckHullHandle() below cross-checks the count at startup.         |
//+------------------------------------------------------------------+
int CreateHullHandle(const ENUM_TIMEFRAMES tf)
  {
   return iCustom(_Symbol, tf, "HullTrend_MT5",
                  0,                     //  1 group "Hull Moving Average"
                  InpHMAPeriod,          //  2 Hull period
                  (int)InpHMAPrice,      //  3 applied price
                  0,                     //  4 group "Whipsaw filter"
                  (int)InpSlopeFilter,   //  5 slope threshold mode
                  InpSlopeATRMul,        //  6 ATR multiplier
                  InpATRPeriod,          //  7 ATR period
                  InpSlopePoints,        //  8 fixed slope, points
                  InpConfirmBars,        //  9 confirmation bars
                  InpConfirmWindow,      // 10 confirmation window
                  0,                     // 11 group "Reversal arrows"
                  false,                 // 12 show arrows   - the EA reads buffers
                  233,                   // 13 up arrow code
                  234,                   // 14 down arrow code
                  10,                    // 15 arrow offset, points
                  0.0,                   // 16 arrow offset, ATR - unused, keeps
                                         //    the indicator from building an ATR
                                         //    handle it does not need
                  0,                     // 17 group "Alerts"
                  0,                     // 18 signal bar    - closed bar
                  false,                 // 19 pop-up alerts - the EA logs instead
                  false,                 // 20 sound
                  "",                    // 21 sound file
                  false,                 // 22 push
                  false,                 // 23 email
                  false                  // 24 alert on attach
                 );
  }

//--- Hard-fail on an argument list that has drifted away from the indicator's
//--- input list. IndicatorParameters is only advisory - if the terminal cannot
//--- answer we warn rather than refuse to start - but a definite mismatch is
//--- fatal, because every setting past the first wrong slot would be garbage.
void CheckHullHandle(const int h, const string what)
  {
   ENUM_INDICATOR type;
   MqlParam       p[];
   const int n = IndicatorParameters(h, type, p);

   if(n <= 0)
     {
      LogAt(LOGL_EVENTS, "ENV",
            StringFormat("could not read back the %s handle's parameter list - "
                         "check the indicator's own 'Hull Trend config:' line instead", what));
      return;
     }

   //--- Some builds count the indicator NAME as parameter 0, so n and n-1 are
   //--- both honest readings of the same correct call.
   if(n == HULL_ICUSTOM_ARGS || n == HULL_ICUSTOM_ARGS + 1)
     {
      LogAt(LOGL_EVENTS, "ENV",
            StringFormat("%s handle: %d iCustom parameters, as expected (%d + optional name slot)",
                         what, n, HULL_ICUSTOM_ARGS));
      return;
     }

   //--- Deliberately NOT fatal. Exactly what IndicatorParameters() counts for an
   //--- iCustom handle is not documented tightly enough to bet a refusal-to-start
   //--- on, and an EA that will not run at all is worse than the bug this guards
   //--- against. The authoritative check remains the indicator's own
   //--- "Hull Trend config:" line - compare it against the profile values in the
   //--- ENV block below. If the two disagree, the arguments are not arriving.
   LogErr(StringFormat("the %s handle reports %d iCustom parameters, expected %d (or %d). "
                       "HullTrend_MT5's input list and CreateHullHandle() may have drifted "
                       "apart - every setting after the first mismatch would be silently wrong. "
                       "VERIFY the indicator's 'Hull Trend config:' line against the profile "
                       "values before trusting any result.",
                       what, n, HULL_ICUSTOM_ARGS, HULL_ICUSTOM_ARGS + 1));
  }

//+------------------------------------------------------------------+
//| Position sizing from a real stop distance.                       |
//| Uses tick value / tick size so it is correct for FX, metals,     |
//| indices and crypto alike - never assume 1 point = 1 unit.        |
//+------------------------------------------------------------------+
double CalcLots(const double stopDistance, const bool verbose)
  {
   const double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   //--- Fixed lots still have to be a legal volume. Returning the raw input
   //--- produced "invalid volume" rejections that surfaced only as order-failed,
   //--- with nothing anywhere saying the size was the problem.
   if(InpFixedLots > 0.0)
     {
      const double fixed = ClampLots(InpFixedLots);
      if(fixed < minL)
        {
         if(verbose)
            LogAt(LOGL_DECISIONS, "VETO",
                  StringFormat("lots-too-small: fixed %.4f lots clamps to %.4f, broker minimum %.4f",
                               InpFixedLots, fixed, minL));
         return 0.0;
        }
      return fixed;
     }

   if(stopDistance <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
     {
      LogErr("cannot size: broker reports tickValue/tickSize <= 0");
      return 0.0;
     }

   const double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   const double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   const double lots = ClampLots(riskMoney / lossPerLot);

   if(lots < minL)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("lots-too-small: risk %.2f%% of %.2f over a %s stop = %.4f lots, "
                            "broker minimum %.4f", InpRiskPercent,
                            AccountInfoDouble(ACCOUNT_BALANCE), DoubleToString(stopDistance, _Digits),
                            lots, minL));
      return 0.0;
     }
   return lots;
  }

//--- reject the order if we cannot afford it rather than letting the server do it
bool MarginOK(const ENUM_ORDER_TYPE type, const double lots, const double price,
              const bool verbose)
  {
   double need = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, need))
     {
      //--- this used to be the one reject path with no log line at all, so
      //--- VETO_MARGIN appeared in the summary with nothing explaining it
      LogErr(StringFormat("OrderCalcMargin failed for %.4f lots at %s: error %d",
                          lots, DoubleToString(price, _Digits), GetLastError()));
      return false;
     }
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(need > free * 0.90)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("margin: need %.2f, free %.2f", need, free));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Support and resistance                                           |
//|                                                                  |
//| Levels are pivot fractals - a high with k lower highs on each     |
//| side - clustered by ATR-scaled proximity, with a touch count as   |
//| their strength. A pivot at shift i is only examined once the k    |
//| bars to its RIGHT have closed, so a level never appears, moves or |
//| disappears after the fact. Highs and lows go into ONE list: a     |
//| broken resistance becomes support, and a price that is both a     |
//| pivot high and a pivot low is a stronger level, not two weak ones.|
//+------------------------------------------------------------------+
void SRAdd(const double price, const datetime when, const double tol)
  {
   const int n = ArraySize(g_sr);
   for(int i = 0; i < n; i++)
      if(MathAbs(g_sr[i].price - price) <= tol)
        {
         //--- touch-weighted running mean, so the level sits where price
         //--- actually turned rather than on whichever pivot arrived first
         g_sr[i].price = (g_sr[i].price * g_sr[i].touches + price) / (g_sr[i].touches + 1);
         g_sr[i].touches++;
         if(when > g_sr[i].last)
            g_sr[i].last = when;
         return;
        }

   ArrayResize(g_sr, n + 1);
   g_sr[n].price   = price;
   g_sr[n].touches = 1;
   g_sr[n].last    = when;
  }

void SRCollect(const ENUM_TIMEFRAMES tf, const int lookback, const double tol,
               const datetime cutoff)
  {
   const int k = (InpSRFractal < 1 ? 1 : InpSRFractal);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int n = CopyRates(_Symbol, tf, 0, lookback, r);
   if(n < 2 * k + 2)
      return;

   //--- shift 0 is still forming, and a pivot needs k CLOSED bars on its right,
   //--- so the newest bar that can carry one is at shift k + 1
   for(int i = k + 1; i < n - k; i++)
     {
      if(r[i].time < cutoff)
         break;                       // series is newest-first: everything older follows

      bool hi = true, lo = true;
      for(int j = 1; j <= k; j++)
        {
         if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high)
            hi = false;
         if(r[i].low  >= r[i - j].low  || r[i].low  >= r[i + j].low)
            lo = false;
        }

      if(hi)
         SRAdd(r[i].high, r[i].time, tol);
      if(lo)
         SRAdd(r[i].low,  r[i].time, tol);
     }
  }

void SRDraw()
  {
   ObjectsDeleteAll(0, "HullSR_");
   if(!InpSRDraw)
      return;

   const int minT = (InpSRMinTouches < 1 ? 1 : InpSRMinTouches);
   for(int i = 0; i < ArraySize(g_sr); i++)
     {
      if(g_sr[i].touches < minT)
         continue;
      const string nm = StringFormat("HullSR_%d", i);
      if(!ObjectCreate(0, nm, OBJ_HLINE, 0, 0, g_sr[i].price))
         continue;
      ObjectSetInteger(0, nm, OBJPROP_COLOR, (g_sr[i].touches >= 3 ? clrOrange : clrDimGray));
      ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, nm, OBJPROP_BACK, true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, nm, OBJPROP_TOOLTIP,
                      StringFormat("S/R %s  touches %d", DoubleToString(g_sr[i].price, _Digits),
                                   g_sr[i].touches));
     }
  }

//--- Rebuilt once per closed bar. O(lookback) with a tiny constant, which is
//--- nothing next to the CopyBuffer calls already happening on the same bar.
void BuildSR(const double atr)
  {
   ArrayResize(g_sr, 0);
   if(!InpUseSR || atr <= 0.0)
      return;

   const double tol = MathMax(InpSRClusterATR * atr, Pt());

   int maxAge = InpSRMaxAgeBars;
   if(maxAge <= 0)
      maxAge = 20 * (InpHMAPeriod > 0 ? InpHMAPeriod : 20);

   //--- one wall-clock horizon for both timeframes, expressed in chart bars
   const long    span   = (long)maxAge * PeriodSeconds((ENUM_TIMEFRAMES)_Period);
   const datetime cutoff = (datetime)MathMax(0.0, (double)TimeCurrent() - (double)span);

   SRCollect((ENUM_TIMEFRAMES)_Period, (InpSRLookback < 50 ? 50 : InpSRLookback), tol, cutoff);

   if(InpSRUseHTF && g_htf != (ENUM_TIMEFRAMES)_Period)
      SRCollect(g_htf, MathMax(60, InpSRLookback / 4), tol, cutoff);

   if(InpSRDraw)
      SRDraw();
  }

//--- Nearest level strictly on the `dir` side of `from` (+1 above, -1 below).
bool SRNearest(const double from, const int dir, double &lvl, int &touches)
  {
   bool   found = false;
   double bestD = 0.0;
   const int minT = (InpSRMinTouches < 1 ? 1 : InpSRMinTouches);

   lvl      = 0.0;
   touches  = 0;

   for(int i = 0; i < ArraySize(g_sr); i++)
     {
      if(g_sr[i].touches < minT)
         continue;
      const double d = (g_sr[i].price - from) * dir;
      if(d <= 0.0)
         continue;                    // wrong side, or exactly on it
      if(!found || d < bestD)
        {
         found   = true;
         bestD   = d;
         lvl     = g_sr[i].price;
         touches = g_sr[i].touches;
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
//| Position tracking                                                |
//+------------------------------------------------------------------+
int TrackFind(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_track); i++)
      if(g_track[i].ticket == ticket)
         return i;
   return -1;
  }

//--- Overwrites an existing record for the same ticket rather than appending a
//--- second one. TrackFind returns the FIRST match, so a duplicate would let a
//--- stale entry/risk silently win every R calculation for that position.
void TrackAdd(const ulong ticket, const double entry, const double risk,
              const int dir, const bool beAlready, const double target)
  {
   int n = TrackFind(ticket);
   if(n < 0)
     {
      n = ArraySize(g_track);
      ArrayResize(g_track, n + 1);
     }
   g_track[n].ticket      = ticket;
   g_track[n].entry       = entry;
   g_track[n].risk        = risk;
   g_track[n].dir         = dir;
   g_track[n].beDone      = beAlready;
   g_track[n].target      = target;
   g_track[n].targetHit   = false;
   g_track[n].partialTries = 0;
   g_track[n].partialDone = false;
  }

//+------------------------------------------------------------------+
//| Report a finished position: what it cost, what it made, and why  |
//| it ended. `risk` is the ORIGINAL stop distance, captured while    |
//| the position was still tracked - the broker no longer knows it    |
//| once break-even and trailing have moved the stop.                 |
//|                                                                   |
//| With a structural partial the position has two OUT deals; the R    |
//| below is measured against the LAST exit, so treat it as the        |
//| runner's result rather than the blended one.                       |
//+------------------------------------------------------------------+
void LogClosedPosition(const ulong ticket, const double risk)
  {
   if(!HistorySelectByPosition(ticket))
     {
      LogErr(StringFormat("#%I64u closed but its deal history could not be selected", ticket));
      return;
     }

   double   pnl = 0.0, entryPrice = 0.0, exitPrice = 0.0, lots = 0.0;
   int      dir = 0, nOut = 0;
   datetime exitTime = 0;
   ENUM_DEAL_REASON reason = DEAL_REASON_CLIENT;

   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;

      pnl += HistoryDealGetDouble(d, DEAL_PROFIT)
             + HistoryDealGetDouble(d, DEAL_SWAP)
             + HistoryDealGetDouble(d, DEAL_COMMISSION);

      const ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_IN)
        {
         entryPrice = HistoryDealGetDouble(d, DEAL_PRICE);
         lots       = HistoryDealGetDouble(d, DEAL_VOLUME);
         dir        = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY ? 1 : -1);
        }
      else
         if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
           {
            exitPrice = HistoryDealGetDouble(d, DEAL_PRICE);
            exitTime  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            reason    = (ENUM_DEAL_REASON)HistoryDealGetInteger(d, DEAL_REASON);
            nOut++;
           }
     }

   if(entryPrice <= 0.0 || exitPrice <= 0.0)
      return;   // still partially open, or a history the terminal has not filled in

   string why = "other";
   if(reason == DEAL_REASON_SL)          { why = "stop-loss";   g_closeSL++;   }
   else if(reason == DEAL_REASON_TP)     { why = "take-profit"; g_closeTP++;   }
   else if(reason == DEAL_REASON_EXPERT) { why = "ea-exit";     g_closeFlip++; }
   else                                  { g_closeOther++; }

   const double r = (risk > 0.0 ? ((exitPrice - entryPrice) * dir) / risk : 0.0);

   g_nClosed++;
   g_sumR += r;
   if(pnl > 0.0)
      g_nWins++;

   LogAt(LOGL_EVENTS, "CLOSE",
         StringFormat("#%I64u %s %.2f lots  %s -> %s  %+.2fR  pnl %+.2f  reason %s%s  (%s)",
                      ticket, DirName(dir), lots,
                      DoubleToString(entryPrice, _Digits), DoubleToString(exitPrice, _Digits),
                      r, pnl, why, (nOut > 1 ? " [scaled out]" : ""),
                      TimeToString(exitTime, TIME_DATE | TIME_MINUTES)));
  }

//--- drops records whose position no longer exists, reporting each one on the
//--- way out. The risk has to be read BEFORE the record is removed.
void TrackPrune()
  {
   for(int i = ArraySize(g_track) - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(g_track[i].ticket))
         continue;

      const ulong  ticket = g_track[i].ticket;
      const double risk   = g_track[i].risk;

      for(int k = i + 1; k < ArraySize(g_track); k++)
         g_track[k-1] = g_track[k];
      ArrayResize(g_track, ArraySize(g_track) - 1);

      LogClosedPosition(ticket, risk);
     }
  }

//--- Counts our positions PER DIRECTION. A single `dir` output could only
//--- report whichever position happened to be iterated last.
int OwnPositions(int &nLong, int &nShort)
  {
   nLong  = 0;
   nShort = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Symbol() != _Symbol)
         continue;
      if(g_pos.Magic() != InpMagic)
         continue;
      if(g_pos.PositionType() == POSITION_TYPE_BUY)
         nLong++;
      else
         nShort++;
     }
   return nLong + nShort;
  }

int OwnPositionCount()
  {
   int a = 0, b = 0;
   return OwnPositions(a, b);
  }

//+------------------------------------------------------------------+
//| Reading the indicator                                            |
//+------------------------------------------------------------------+

//--- Returns -1 when the data is not available yet. That is NOT "no signal":
//--- the caller must retry on the next tick instead of consuming the bar.
int ReadSignal(HullSignal &sig)
  {
   sig.flip  = false;
   sig.dir   = 0;
   sig.hma   = 0.0;
   sig.atr   = 0.0;
   sig.entry = 0.0;

   double col[], hma[], atr[];
   ArraySetAsSeries(col, true);
   ArraySetAsSeries(hma, true);
   ArraySetAsSeries(atr, true);

   //--- shifts 1 and 2: the last closed bar and the one before it
   if(CopyBuffer(g_hHull, BUF_COLOR, 1, 2, col) < 2)
      return -1;
   if(CopyBuffer(g_hHull, BUF_HMA,   1, 1, hma) < 1)
      return -1;
   if(CopyBuffer(g_hATR,  0,         1, 1, atr) < 1)
      return -1;

   //--- warm-up bars: the colour index carries no meaning until the Hull
   //--- line itself exists on that bar
   if(!UsableValue(hma[0]) || !UsableValue(atr[0]) || atr[0] <= 0.0)
      return -1;

   const int c0 = (int)MathRound(col[0]);
   const int c1 = (int)MathRound(col[1]);
   if((c0 != TREND_UP && c0 != TREND_DOWN) ||
      (c1 != TREND_UP && c1 != TREND_DOWN))
      return -1;

   sig.dir   = (c0 == TREND_UP ? 1 : -1);
   sig.flip  = (c0 != c1);
   sig.hma   = hma[0];
   sig.atr   = atr[0];
   sig.entry = iClose(_Symbol, _Period, 1);
   return 0;
  }

//--- returns -1 when the higher TF is not ready yet, otherwise 0 with dir set
int ReadHTF(int &dir)
  {
   dir = 0;
   if(g_hHullHTF == INVALID_HANDLE)
      return 0;                       // filter disabled

   double col[];
   ArraySetAsSeries(col, true);
   const int shift = (InpHTFShift < 0 ? 0 : InpHTFShift);
   if(CopyBuffer(g_hHullHTF, BUF_COLOR, shift, 1, col) < 1)
      return -1;

   const int c = (int)MathRound(col[0]);
   if(c != TREND_UP && c != TREND_DOWN)
      return -1;

   dir = (c == TREND_UP ? 1 : -1);
   return 0;
  }

//+------------------------------------------------------------------+
//| Stop placement                                                   |
//+------------------------------------------------------------------+
double StopLevel(const HullSignal &sig, const double fill)
  {
   if(InpSLMode == SL_SWING)
     {
      //--- A clustered level that price has turned at repeatedly is a better
      //--- stop than the lowest low of the last N bars, which may have been
      //--- touched exactly once. Fall back to the raw extreme when there is no
      //--- level, or when the nearest one is so far away it would size the
      //--- trade down to nothing.
      if(InpUseSR && InpSRStop)
        {
         double lvl = 0.0;
         int    t   = 0;
         if(SRNearest(fill, -sig.dir, lvl, t) &&
            MathAbs(fill - lvl) <= 3.0 * sig.atr)
            return lvl - sig.dir * InpSLpadATR * sig.atr;
        }

      const int n = (InpSwingBars < 2 ? 2 : InpSwingBars);
      if(sig.dir > 0)
        {
         const int k = iLowest(_Symbol, _Period, MODE_LOW, n, 1);
         if(k < 0)
            return fill - InpSLmulATR * sig.atr;
         return iLow(_Symbol, _Period, k) - InpSLpadATR * sig.atr;
        }
      const int k2 = iHighest(_Symbol, _Period, MODE_HIGH, n, 1);
      if(k2 < 0)
         return fill + InpSLmulATR * sig.atr;
      return iHigh(_Symbol, _Period, k2) + InpSLpadATR * sig.atr;
     }

   if(InpSLMode == SL_HMA)
      //--- the Hull line is the thesis: if price is through it, the trade is
      //--- wrong by its own definition
      return sig.hma - sig.dir * InpSLpadATR * sig.atr;

   return fill - sig.dir * InpSLmulATR * sig.atr;
  }

//+------------------------------------------------------------------+
//| Sizing pre-flight, run once as soon as ATR is available.          |
//|                                                                   |
//| The broker minimum lot puts a FLOOR under risk per trade. When     |
//| that floor sits above InpRiskPercent, CalcLots rounds down to zero |
//| and every signal is vetoed as lots-too-small - which looks exactly |
//| like the strategy never signalling at all. Say it once, up front,  |
//| with the number needed to fix it.                                  |
//+------------------------------------------------------------------+
void SizingPreflight(const double atr)
  {
   if(g_preflight || atr <= 0.0)
      return;
   g_preflight = true;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || minLot <= 0.0 || balance <= 0.0)
      return;

   //--- the ATR-mode distance; Swing and HMA modes land in the same ballpark
   const double slDist     = InpSLmulATR * atr;
   const double lossPerLot = (slDist / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return;

   const double rawLots  = (balance * InpRiskPercent / 100.0) / lossPerLot;
   const double floorPct = minLot * lossPerLot / balance * 100.0;

   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("sizing preflight: ATR %s  SL %.2fxATR = %s  -> %.4f lots wanted "
                      "(broker min %.4f step %.4f, %d volume digits)",
                      DoubleToString(atr, _Digits), InpSLmulATR,
                      DoubleToString(slDist, _Digits), rawLots, minLot,
                      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), VolDigits()));
   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("sizing preflight: one minimum lot risks %.2f = %.2f%% of balance, "
                      "your setting is %.2f%%",
                      minLot * lossPerLot, floorPct, InpRiskPercent));

   if(InpFixedLots > 0.0)
     {
      const double fixed = ClampLots(InpFixedLots);
      if(MathAbs(fixed - InpFixedLots) > 1e-8)
         LogAt(LOGL_EVENTS, "ENV",
               StringFormat("sizing preflight: fixed lots %.4f is not a legal volume here - "
                            "every order will use %.4f", InpFixedLots, fixed));
     }
   else
      if(rawLots < minLot)
         LogErr(StringFormat("sizing preflight: %.2f%% risk rounds to ZERO lots on this symbol - "
                             "every signal will be vetoed as lots-too-small. Raise risk above "
                             "%.2f%%, drop to a lower timeframe, or fund the account further.",
                             InpRiskPercent, floorPct));
  }

//+------------------------------------------------------------------+
//| Daily guards                                                     |
//+------------------------------------------------------------------+
void RollDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0;
   t.min  = 0;
   t.sec  = 0;
   const datetime today = StructToTime(t);
   if(today != g_dayStart)
     {
      g_dayStart        = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday     = 0;
      g_dayBlocked      = false;
      g_lastFlatten     = 0;
     }
  }

bool DailyLossHit()
  {
   if(InpMaxDailyLossPct <= 0.0)
      return false;
   if(g_dayStartBalance <= 0.0)
      return false;

   //--- equity against the day's OPENING BALANCE, so floating P&L on a position
   //--- that was already open at midnight cannot move the baseline
   const double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lost = (g_dayStartBalance - eq) / g_dayStartBalance * 100.0;
   if(lost >= InpMaxDailyLossPct)
     {
      if(!g_dayBlocked)
         LogAt(LOGL_EVENTS, "VETO",
               StringFormat("daily loss limit hit (-%.2f%% against the day's opening balance "
                            "%.2f) - no new trades today", lost, g_dayStartBalance));
      g_dayBlocked = true;
      return true;
     }
   return false;
  }

bool FridayCutoffNow()
  {
   if(!InpNoFridayLate)
      return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.day_of_week == 5 && t.hour >= InpFridayStopHour);
  }

bool TimeAllowed()
  {
   if(FridayCutoffNow())
      return false;
   if(!InpUseTimeFilter)
      return true;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpStartHour <= InpEndHour)
      return (t.hour >= InpStartHour && t.hour < InpEndHour);
   return (t.hour >= InpStartHour || t.hour < InpEndHour);   // wraps midnight
  }

//+------------------------------------------------------------------+
//| Exits                                                            |
//|                                                                  |
//| Returns TRUE only when nothing on the wrong side is left open.    |
//| The caller needs to know: a stop-and-reverse that closes the old  |
//| trade and then silently fails to open the new one is the worst    |
//| outcome available, and the position-limit veto used to make that  |
//| the DEFAULT behaviour whenever the close had not settled yet.     |
//+------------------------------------------------------------------+
bool CloseAgainst(const int newDir)
  {
   bool allGone = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic)
         continue;
      const int dir = (g_pos.PositionType() == POSITION_TYPE_BUY ? 1 : -1);
      if(dir == newDir)
         continue;

      const ulong ticket = g_pos.Ticket();
      if(!g_trade.PositionClose(ticket))
        {
         allGone = false;
         LogErr(StringFormat("#%I64u close FAILED: %d (%s) - the reversal will keep retrying "
                             "while the signal stays armed", ticket,
                             g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
        }
      else
         if(PositionSelectByTicket(ticket))
            allGone = false;          // accepted but not booked yet: retry next tick
      //--- the CLOSE line itself is emitted by TrackPrune on the next tick,
      //--- once the broker has actually booked the deal
     }
   return allGone;
  }

//--- Close everything we own, used by the Friday cut-off and the daily-loss
//--- halt. Blocking new entries while leaving the open trade to ride the very
//--- gap the cut-off exists to avoid was never the intent of those inputs.
void FlattenAll(const string why)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic)
         continue;
      if(g_trade.PositionClose(g_pos.Ticket()))
         closed++;
      else
         LogErr(StringFormat("#%I64u flatten FAILED: %d (%s)", g_pos.Ticket(),
                             g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
     }

   if(closed > 0)
      LogAt(LOGL_EVENTS, "CLOSE", StringFormat("flattened %d position(s): %s", closed, why));

   g_armDir = 0;   // nothing armed survives a halt
  }

//--- Run every tick. Cheap, and the cut-off has to bite the moment it arrives
//--- rather than on the next closed bar.
void HaltCheck()
  {
   string why = "";
   if(InpFlattenOnFriday && FridayCutoffNow())
      why = StringFormat("Friday cut-off (%02d:00 server)", InpFridayStopHour);
   else
      if(InpFlattenOnLoss && DailyLossHit())
         why = StringFormat("daily loss limit %.2f%%", InpMaxDailyLossPct);

   if(why == "")
      return;
   if(OwnPositionCount() == 0)
      return;

   //--- A close can be refused - a thin Friday-evening book, a requote storm,
   //--- a session that has already shut. Unthrottled, the retry runs on every
   //--- tick and writes one ERROR per position per tick, which is how a real
   //--- problem gets buried under thousands of copies of itself.
   if(g_lastFlatten > 0 && TimeCurrent() - g_lastFlatten < 10)
      return;
   g_lastFlatten = TimeCurrent();

   FlattenAll(why);
  }

//+------------------------------------------------------------------+
//| Entry. Returns VETO_NONE if an order went in, otherwise the      |
//| reason it did not - so the caller can both log and count it.     |
//|                                                                  |
//| `verbose` is false on the intrabar retries of an armed signal:   |
//| the guards are re-tested every tick and logging each rejection   |
//| would bury the log under thousands of identical lines.           |
//+------------------------------------------------------------------+
ENUM_VETO TryEnter(const HullSignal &sig, const int htfDir, const bool verbose)
  {
   int nLong = 0, nShort = 0;
   const int nPos = OwnPositions(nLong, nShort);

   if(nPos >= InpMaxPositions)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO", StringFormat("pos-limit: %d open, max %d", nPos, InpMaxPositions));
      return VETO_POSLIMIT;
     }
   if((sig.dir > 0 && nLong > 0) || (sig.dir < 0 && nShort > 0))
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO", "same-dir: already in this direction");
      return VETO_SAMEDIR;
     }

   //--- The higher TF has to agree. This is the single biggest whipsaw filter
   //--- on low timeframes: a per-bar slope threshold cannot see regime.
   if(InpUseHTF && g_hHullHTF != INVALID_HANDLE && htfDir != 0 && htfDir != sig.dir)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("htf-disagrees: signal %s, %s is %s",
                            DirName(sig.dir), EnumToString(g_htf), DirName(htfDir)));
      return VETO_HTF;
     }

   if(!TimeAllowed())
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO", "out-of-hours");
      return VETO_TIME;
     }
   if(DailyLossHit())
      return VETO_DAILYLOSS;
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("trade-cap: %d taken today, max %d", g_tradesToday, InpMaxTradesPerDay));
      return VETO_TRADECAP;
     }

   if(InpMinBarsGap > 0 && g_lastEntryBar > 0)
     {
      const int since = iBarShift(_Symbol, _Period, g_lastEntryBar, false);
      if(since >= 0 && since < InpMinBarsGap)
        {
         if(verbose)
            LogAt(LOGL_DECISIONS, "VETO",
                  StringFormat("bar-gap: %d bars since the last entry, need %d", since, InpMinBarsGap));
         return VETO_BARGAP;
        }
     }

   //--- Spread guard, scaled to ATR rather than to a fixed point count so it
   //--- keeps its meaning across instruments and across volatility regimes.
   const double sprATR = (sig.atr > 0.0 ? SpreadPrice() / sig.atr : 0.0);
   if(InpMaxSpreadATR > 0.0 && SpreadPrice() > InpMaxSpreadATR * sig.atr)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("spread: %.1f pts = %.2f x ATR, limit %.2f", SpreadPts(), sprATR, InpMaxSpreadATR));
      return VETO_SPREAD;
     }
   if(InpMaxSpreadPts > 0.0 && SpreadPts() > InpMaxSpreadPts)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("spread: %.1f pts > %.1f", SpreadPts(), InpMaxSpreadPts));
      return VETO_SPREAD;
     }

   const double fill = (sig.dir > 0 ? Ask() : Bid());

   //--- Structural room. A long entered a fraction of an ATR under a level that
   //--- has already turned price away several times is taking a full-size stop
   //--- for a truncated move; that is a losing bet whatever the trend says.
   double srLevel = 0.0;
   int    srTouch = 0;
   const bool srAhead = (InpUseSR && SRNearest(fill, sig.dir, srLevel, srTouch));
   const double srRoom = (srAhead ? MathAbs(srLevel - fill) : 0.0);

   if(srAhead && InpSRVetoATR > 0.0 && sig.atr > 0.0 && srRoom < InpSRVetoATR * sig.atr)
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("no-room-to-level: %s ahead at %s is %.2fxATR away (%d touches), "
                            "need %.2f", DirName(sig.dir), DoubleToString(srLevel, _Digits),
                            srRoom / sig.atr, srTouch, InpSRVetoATR));
      return VETO_SR;
     }

   double sl = StopLevel(sig, fill);

   //--- a stop on the wrong side of the fill means price has already run
   //--- through the level this trade was supposed to be protected by
   if((sig.dir > 0 && sl >= fill) || (sig.dir < 0 && sl <= fill))
     {
      if(verbose)
         LogAt(LOGL_DECISIONS, "VETO",
               StringFormat("stop-wrong-side: fill %s, stop %s",
                            DoubleToString(fill, _Digits), DoubleToString(sl, _Digits)));
      return VETO_STOPSIDE;
     }

   //--- Reject a signal price has already run away from: taking it here ruins
   //--- the risk:reward the model assumed. This is also what expires an armed
   //--- signal, because sig.entry stays pinned to the flip bar's close.
   const double modelRisk = MathAbs(sig.entry - sl);
   double drift = 0.0;
   if(modelRisk > 0.0)
     {
      drift = ((fill - sig.entry) * sig.dir) / modelRisk;
      if(drift > InpMaxDriftR)
        {
         if(verbose)
            LogAt(LOGL_DECISIONS, "VETO",
                  StringFormat("drift: price moved %.2fR past the signal close %s, limit %.2fR",
                               drift, DoubleToString(sig.entry, _Digits), InpMaxDriftR));
         return VETO_DRIFT;
        }
     }

   //--- respect the broker's minimum stop distance, widening if needed. This
   //--- has to happen BEFORE the take profit is derived: computing TP from the
   //--- pre-widened distance left it claiming an R multiple the trade no longer
   //--- had.
   const double minD = StopsDist();
   if(minD > 0.0 && MathAbs(fill - sl) < minD)
      sl = (sig.dir > 0 ? fill - minD : fill + minD);

   sl = NormPrice(sl);

   double tp = 0.0;
   if(InpTPmulR > 0.0)
     {
      tp = fill + sig.dir * InpTPmulR * MathAbs(fill - sl);
      if(minD > 0.0 && MathAbs(tp - fill) < minD)
         tp = (sig.dir > 0 ? fill + minD : fill - minD);
      tp = NormPrice(tp);
     }

   //--- size from the REAL distance, not the theoretical one
   const double realRisk = MathAbs(fill - sl);
   const double lots     = CalcLots(realRisk, verbose);
   if(lots <= 0.0)
      return VETO_LOTS;

   const ENUM_ORDER_TYPE type = (sig.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!MarginOK(type, lots, fill, verbose))
      return VETO_MARGIN;

   g_trade.SetDeviationInPoints(InpSlippagePts);
   const string cmt = InpComment + (sig.dir > 0 ? " L" : " S");

   const bool ok = (sig.dir > 0) ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt)
                   : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);
   if(!ok)
     {
      LogErr(StringFormat("order FAILED: retcode=%d (%s)",
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      return VETO_ORDERFAIL;
     }

   const ulong  ticket   = g_trade.ResultOrder();
   const double realFill = (g_trade.ResultPrice() > 0.0 ? g_trade.ResultPrice() : fill);
   g_tradesToday++;
   g_lastEntryBar = iTime(_Symbol, _Period, 0);
   g_nEntries++;

   //--- Everything needed to reconstruct this decision offline: the size, the
   //--- levels, the volatility it was scaled to, and the cost it paid to get in.
   LogAt(LOGL_EVENTS, "ENTRY",
         StringFormat("%s %.2f lots @ %s  SL %s (%s = %.2fxATR)  TP %s | "
                      "level ahead %s  ATR %s  spread %.1f pts = %.2fxATR  drift %.2fR  "
                      "risk %.2f%%  bal %.2f",
                      DirName(sig.dir), lots, DoubleToString(realFill, _Digits),
                      DoubleToString(sl, _Digits), DoubleToString(realRisk, _Digits),
                      (sig.atr > 0.0 ? realRisk / sig.atr : 0.0),
                      (tp > 0.0 ? DoubleToString(tp, _Digits) : "none"),
                      (srAhead ? StringFormat("%s (%.2fxATR, %d touches)",
                                              DoubleToString(srLevel, _Digits),
                                              (sig.atr > 0.0 ? srRoom / sig.atr : 0.0), srTouch)
                               : "none"),
                      DoubleToString(sig.atr, _Digits), SpreadPts(), sprATR,
                      drift, InpRiskPercent, AccountInfoDouble(ACCOUNT_BALANCE)));

   //--- Identify the position THIS order created. Scanning for the first
   //--- symbol+magic match would bind this trade's risk to an older ticket.
   ulong posTicket = 0;
   if(ticket > 0 && PositionSelectByTicket(ticket))            // hedging
      posTicket = ticket;
   if(posTicket == 0 && PositionSelect(_Symbol) &&             // netting
      PositionGetInteger(POSITION_MAGIC) == InpMagic)
      posTicket = (ulong)PositionGetInteger(POSITION_TICKET);

   if(posTicket > 0)
      TrackAdd(posTicket, realFill, realRisk, sig.dir, false,
               (InpSRTargetPart > 0.0 && srAhead ? srLevel : 0.0));
   else
      LogErr("order placed but the position could not be found for R tracking");

   return VETO_NONE;
  }

//+------------------------------------------------------------------+
//| Service an armed flip. Called once per closed bar (loudly) and    |
//| on every tick in between (quietly), so a reversal blocked by its  |
//| own unsettled close-out gets in as soon as the slot frees up      |
//| instead of being discarded with the bar.                          |
//+------------------------------------------------------------------+
void ServiceArm()
  {
   if(g_armDir == 0)
      return;

   int htfDir = 0;
   if(ReadHTF(htfDir) < 0)
      return;                       // HTF not ready: try again, keep the arm

   const bool loud = !g_armLogged;
   const ENUM_VETO v = TryEnter(g_armSig, htfDir, loud);

   if(loud)
     {
      g_veto[v]++;
      g_armLogged = true;
     }

   if(v == VETO_NONE)
     {
      if(g_armBarsLeft < MathMax(0, InpSignalArmBars))
         g_nArmLate++;              // needed the window, would have been lost before
      g_armDir = 0;
     }
  }

void Disarm(const string why)
  {
   if(g_armDir == 0)
      return;
   LogAt(LOGL_DECISIONS, "ARM",
         StringFormat("%s signal disarmed: %s", DirName(g_armDir), why));
   g_armDir = 0;
   g_nArmExpire++;
  }

//+------------------------------------------------------------------+
//| Break-even and trailing, both expressed in R                     |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   TrackPrune();

   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic)
         continue;

      const ulong  ticket = g_pos.Ticket();
      const int    dir    = (g_pos.PositionType() == POSITION_TYPE_BUY ? 1 : -1);
      const double open   = g_pos.PriceOpen();
      const double curSL  = g_pos.StopLoss();
      const double curTP  = g_pos.TakeProfit();
      const double vol    = g_pos.Volume();
      const double price  = (dir > 0 ? Bid() : Ask());

      int idx = TrackFind(ticket);
      if(idx < 0)
        {
         //--- Restarted with this position open: reconstruct R from its stop.
         //--- Break-even is only marked done when the stop is ALREADY at or
         //--- beyond the entry - blanket-disabling it meant a restart at 0.9R
         //--- permanently lost break-even protection on that trade.
         const double r = (curSL > 0.0 ? MathAbs(open - curSL) : 0.0);
         if(r <= 0.0)
            continue;
         const bool alreadyBE = (curSL > 0.0 && (curSL - open) * dir >= 0.0);
         TrackAdd(ticket, open, r, dir, alreadyBE, 0.0);
         idx = TrackFind(ticket);
         LogAt(LOGL_EVENTS, "STOP",
               StringFormat("adopted position #%I64u, R reconstructed as %s, break-even %s",
                            ticket, DoubleToString(r, _Digits),
                            (alreadyBE ? "already set" : "still pending")));
        }

      const double risk = g_track[idx].risk;
      if(risk <= 0.0)
         continue;

      const double rNow = ((price - open) * dir) / risk;

      //--- Structural partial: bank part of the trade where price is most
      //--- likely to stall. This is the answer to the give-back problem a pure
      //--- flip system has - the only exit is the opposite flip, which by
      //--- definition arrives after the move has already turned over.
      if(InpUseSR && InpSRTargetPart > 0.0 && !g_track[idx].partialDone &&
         g_track[idx].target > 0.0 && (price - g_track[idx].target) * dir >= 0.0)
        {
         g_track[idx].targetHit = true;

         const double cut = ClampLots(vol * InpSRTargetPart);
         if(cut >= minLot && (vol - cut) >= minLot)
           {
            if(g_trade.PositionClosePartial(ticket, cut))
              {
               g_track[idx].partialDone = true;
               g_nPartials++;
               LogAt(LOGL_EVENTS, "CLOSE",
                     StringFormat("#%I64u partial %.4f of %.4f lots at level %s (%.2fR) - "
                                  "runner goes to break-even", ticket, cut, vol,
                                  DoubleToString(g_track[idx].target, _Digits), rNow));
              }
            else
              {
               //--- Bounded retry. A requote is worth trying again; a broker that
               //--- keeps refusing is not, and an unbounded retry writes one ERROR
               //--- per tick for the life of the position.
               g_track[idx].partialTries++;
               LogErr(StringFormat("#%I64u partial close FAILED (attempt %d/5): %d (%s)",
                                   ticket, g_track[idx].partialTries,
                                   g_trade.ResultRetcode(),
                                   g_trade.ResultRetcodeDescription()));
               if(g_track[idx].partialTries >= 5)
                 {
                  g_track[idx].partialDone = true;
                  LogErr(StringFormat("#%I64u giving up on the structural partial - "
                                      "the whole position runs on to the flip or the stop",
                                      ticket));
                 }
              }
           }
         else
           {
            //--- too small to split: stop retrying it every tick
            g_track[idx].partialDone = true;
            LogAt(LOGL_DECISIONS, "CLOSE",
                  StringFormat("#%I64u reached its level but %.4f lots cannot be split "
                               "(broker minimum %.4f) - running the whole position on",
                               ticket, vol, minLot));
           }
        }

      double newSL     = curSL;
      bool   beApplied = false;

      //--- beDone is set only once the stop is actually AT break-even, never
      //--- merely because we tried: the modify below can still be refused by
      //--- the broker's freeze band, and marking it done here would mean
      //--- break-even is never retried.
      //---
      //--- REACHING the structural level arms break-even regardless of R, whether
      //--- or not the partial could actually be split off: price has arrived where
      //--- the trade said it would, so the rest should not be allowed to lose.
      const bool beTrigger = (rNow >= InpBEatR) || g_track[idx].targetHit;
      if(InpUseBreakEven && !g_track[idx].beDone && beTrigger)
        {
         const double be = open + dir * InpBEoffsetPts * Pt();
         if((dir > 0 && be > curSL) || (dir < 0 && (curSL == 0.0 || be < curSL)))
           {
            newSL     = be;
            beApplied = true;
           }
         else
            g_track[idx].beDone = true;   // already at or beyond break-even
        }

      //--- Trailing, throttled by a minimum advance. Unthrottled, the stop
      //--- moves on every one-point tick in our favour, and each move is a
      //--- PositionModify server call - which floods the broker on a trending
      //--- low-timeframe position and can be refused outright under rate
      //--- limiting. The step costs nothing in placement: the stop ends up in
      //--- the same place, it just gets there in fewer hops.
      if(InpUseTrailing && rNow >= InpTrailStartR)
        {
         const double trail = price - dir * InpTrailDistR * risk;
         const double step  = MathMax(0.0, InpTrailStepR) * risk;

         //--- The advance is measured against the stop the broker currently
         //--- holds, not against newSL. Measuring against newSL would let a
         //--- break-even move staged on this same tick satisfy the step on the
         //--- trail's behalf, and the throttle would do nothing on the one tick
         //--- where both fire.
         const bool   noStop  = (curSL == 0.0);
         const double advance = (noStop ? 0.0 : (trail - curSL) * dir);

         if((dir > 0 && trail > newSL) || (dir < 0 && (newSL == 0.0 || trail < newSL)))
            if(noStop || advance >= step)
               newSL = trail;
        }

      if(newSL != curSL && newSL > 0.0)
        {
         //--- never push the stop inside the broker's freeze band
         const double minD = ModifyDist();
         if(MathAbs(price - newSL) < minD)
            continue;
         newSL = NormPrice(newSL);
         if(newSL == NormPrice(curSL))
           {
            if(beApplied)
               g_track[idx].beDone = true;
            continue;
           }

         const double moved = (curSL > 0.0 ? (newSL - curSL) * dir / risk : 0.0);

         if(g_trade.PositionModify(ticket, newSL, curTP))
           {
            if(beApplied)
               g_track[idx].beDone = true;
            g_nStopMods++;
            LogAt(LOGL_EVENTS, "STOP",
                  StringFormat("#%I64u %s -> %s  (+%.2fR advance) at %.2fR open",
                               ticket, (beApplied ? "break-even" : "trail"),
                               DoubleToString(newSL, _Digits), moved, rNow));
           }
         else
           {
            g_nStopFails++;
            LogErr(StringFormat("#%I64u stop modify failed: %d (%s)", ticket,
                                g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Running totals. This is the line that answers "is it working" -   |
//| the veto histogram shows which filter is doing the rejecting, and |
//| the spread figure shows whether the timeframe can pay its costs.  |
//+------------------------------------------------------------------+
void PrintSummary(const string when)
  {
   string vetoes = "";
   for(int v = 1; v < VETO_COUNT; v++)
      if(g_veto[v] > 0)
         vetoes += StringFormat("%s=%d ", VetoName((ENUM_VETO)v), g_veto[v]);
   if(vetoes == "")
      vetoes = "none ";

   const int    nLoss   = g_nClosed - g_nWins;
   const double winPct  = (g_nClosed > 0 ? 100.0 * g_nWins / g_nClosed : 0.0);
   const double avgR    = (g_nClosed > 0 ? g_sumR / g_nClosed : 0.0);
   const double avgSpr  = (g_sprN   > 0 ? g_sprSum / g_sprN   : 0.0);

   LogAt(LOGL_EVENTS, "SUM",
         StringFormat("%s | bars %d  flips %d  entries %d  open %d  stopMods %d (%d failed)",
                      when, g_barsSeen, g_nFlips, g_nEntries, ArraySize(g_track),
                      g_nStopMods, g_nStopFails));
   LogAt(LOGL_EVENTS, "SUM",
         StringFormat("%s | vetoes: %s", when, vetoes));
   const double avgRoom = (g_srRoomN > 0 ? g_srRoomSum / g_srRoomN : 0.0);

   LogAt(LOGL_EVENTS, "SUM",
         StringFormat("%s | armed %d  filled late %d  expired %d  | S/R levels %d  "
                      "avg room ahead %.2fxATR  veto at %.2f  partials %d",
                      when, g_nArmed, g_nArmLate, g_nArmExpire, ArraySize(g_sr),
                      avgRoom, InpSRVetoATR, g_nPartials));

   //--- The S/R veto is the one guard that can quietly stop the strategy dead:
   //--- set it above the typical spacing between levels and nothing ever has
   //--- enough room. Say so with the number needed to fix it.
   if(InpUseSR && InpSRVetoATR > 0.0 && g_veto[VETO_SR] > 0 && g_veto[VETO_SR] >= g_nEntries)
      LogAt(LOGL_EVENTS, "SUM",
            StringFormat("%s | WARNING: no-room-to-level rejected %d attempt(s) against %d "
                         "entries. The nearest level ahead averages %.2fxATR - set "
                         "InpSRVetoATR below that (or 0 to disable) unless you mean to be "
                         "this selective.", when, g_veto[VETO_SR], g_nEntries, avgRoom));
   LogAt(LOGL_EVENTS, "SUM",
         StringFormat("%s | closed %d  win %d / loss %d (%.0f%%)  total %+.2fR  avg %+.2fR  "
                      "| exits: stop %d  tp %d  ea %d  other %d",
                      when, g_nClosed, g_nWins, nLoss, winPct, g_sumR, avgR,
                      g_closeSL, g_closeTP, g_closeFlip, g_closeOther));
   LogAt(LOGL_EVENTS, "SUM",
         StringFormat("%s | spread avg %.2f x ATR  max %.2f x ATR  (a flip system needs this "
                      "well under 0.25 to be viable)", when, avgSpr, g_sprMax));
   LogAt(LOGL_EVENTS, "SUM",
         StringFormat("%s | balance %.2f  equity %.2f", when,
                      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY)));
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- Every counter the summary prints is reset TOGETHER. MT5 keeps globals
   //--- alive across a re-init (changing the chart timeframe, or the inputs,
   //--- deinits and re-inits the same instance), so clearing only some of them
   //--- produced a SUM line that contradicted itself: the veto counts were
   //--- wiped while the flip count survived, and the log read "flips 3
   //--- entries 0 vetoes: none" - which looks exactly like an EA that sees
   //--- signals and silently refuses to trade them. It was neither: the vetoes
   //--- had simply been erased by the next OnInit.
   ArrayInitialize(g_veto, 0);
   g_preflight  = false;
   g_nStopMods  = 0;
   g_nStopFails = 0;
   g_barsSeen   = 0;
   g_nFlips     = 0;
   g_nEntries   = 0;
   g_nClosed    = 0;
   g_nWins      = 0;
   g_sumR       = 0.0;
   g_closeSL    = 0;
   g_closeTP    = 0;
   g_closeFlip  = 0;
   g_closeOther = 0;
   g_sprSum     = 0.0;
   g_sprMax     = 0.0;
   g_sprN       = 0;
   g_nArmed     = 0;
   g_nArmLate   = 0;
   g_nArmExpire = 0;
   g_nPartials  = 0;
   g_srRoomSum  = 0.0;
   g_srRoomN    = 0;
   g_sigStall   = 0;
   g_htfStall   = 0;
   g_armDir     = 0;
   g_armLogged  = false;
   ArrayResize(g_sr, 0);

   g_hHull = CreateHullHandle((ENUM_TIMEFRAMES)_Period);
   if(g_hHull == INVALID_HANDLE)
     {
      LogErr("FATAL: cannot create the indicator handle. Is HullTrend_MT5.ex5 in MQL5\\Indicators ?");
      return INIT_FAILED;
     }
   CheckHullHandle(g_hHull, "trading-TF");

   g_htf = PickHTF();
   if(InpUseHTF && g_htf != (ENUM_TIMEFRAMES)_Period)
     {
      g_hHullHTF = CreateHullHandle(g_htf);
      if(g_hHullHTF == INVALID_HANDLE)
        {
         LogErr("FATAL: cannot create the higher-timeframe indicator handle.");
         return INIT_FAILED;
        }
      CheckHullHandle(g_hHullHTF, "higher-TF");
     }
   else
      if(InpUseHTF)
         LogAt(LOGL_EVENTS, "ENV", "higher-TF filter requested but resolves to the chart TF - disabled");

   const int atrP = (InpATRPeriod < 1 ? 1 : InpATRPeriod);
   g_hATR = iATR(_Symbol, _Period, atrP);
   if(g_hATR == INVALID_HANDLE)
     {
      LogErr("FATAL: cannot create the ATR handle.");
      return INIT_FAILED;
     }

   //--- Broker and symbol facts. Half the "why did it not trade" questions are
   //--- answered here: a minimum lot that is too large for the risk, a stops
   //--- level that swallows the stop, a tick value the terminal cannot supply.
   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("%s %s | digits %d  point %s  tickSize %s  tickValue %.5f",
                      _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), _Digits,
                      DoubleToString(Pt(), 8),
                      DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 8),
                      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)));
   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("lots min %.4f step %.4f max %.4f (%d volume digits) | stopsLevel %d  "
                      "freezeLevel %d | spread now %.1f pts | fill mode %d",
                      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
                      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), VolDigits(),
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
                      SpreadPts(),
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)));

   //--- A symbol the broker will not let us trade produces order failures at
   //--- the worst possible moment instead of a refusal at startup.
   const long tmode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tmode == SYMBOL_TRADE_MODE_DISABLED)
      LogErr("this symbol is DISABLED for trading - no order will ever be accepted");
   else
      if(tmode == SYMBOL_TRADE_MODE_CLOSEONLY)
         LogErr("this symbol is CLOSE-ONLY - existing positions can be managed but no new "
                "trade will be accepted");
      else
         if(tmode == SYMBOL_TRADE_MODE_LONGONLY)
            LogAt(LOGL_EVENTS, "ENV", "symbol is LONG-ONLY - every short flip will be rejected");
         else
            if(tmode == SYMBOL_TRADE_MODE_SHORTONLY)
               LogAt(LOGL_EVENTS, "ENV", "symbol is SHORT-ONLY - every long flip will be rejected");

   //--- Netting vs hedging decides whether two EAs can share a symbol at all.
   //--- On netting there is one position per symbol, so they cannot: each would
   //--- be trading a position the other also believes it owns.
   const long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   const bool hedging    = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("account: %s | currency %s | leverage 1:%d",
                      (hedging ? "HEDGING"
                               : (marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE
                                  ? "EXCHANGE" : "NETTING")),
                      AccountInfoString(ACCOUNT_CURRENCY),
                      (int)AccountInfoInteger(ACCOUNT_LEVERAGE)));
   if(!hedging)
      LogAt(LOGL_EVENTS, "ENV",
            "NOTE: netting account - the broker keeps exactly ONE position per "
            "symbol. A second EA trading this same symbol shares that position: "
            "its orders can reduce or close what this EA opened, and the magic- "
            "number filter cannot separate them. Give each EA its own symbol, or "
            "use a hedging account.");

   //--- Name the resolved HTF together with the multiple it actually works
   //--- out to, so an unexpected ladder choice is visible rather than inferred.
   string htfDesc = "off";
   if(g_hHullHTF != INVALID_HANDLE)
      htfDesc = StringFormat("%s (%.0fx)", EnumToString(g_htf),
                             (double)PeriodSeconds(g_htf) /
                             (double)PeriodSeconds((ENUM_TIMEFRAMES)_Period));

   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("profile %s | HTF %s | risk %.2f%% | SL %s | closeOnFlip %s | "
                      "arm %d bars | balance %.2f | magic %I64d", DEF_PROFILE_NAME, htfDesc,
                      InpRiskPercent, EnumToString(InpSLMode),
                      (InpCloseOnFlip ? "yes" : "no"), InpSignalArmBars,
                      AccountInfoDouble(ACCOUNT_BALANCE), InpMagic));

   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("S/R %s | fractal %d  lookback %d  htf %s  cluster %.2fxATR  "
                      "minTouches %d | veto %.2fxATR  partial %.0f%%  stop %s",
                      (InpUseSR ? "on" : "off"), InpSRFractal, InpSRLookback,
                      (InpSRUseHTF ? "yes" : "no"), InpSRClusterATR, InpSRMinTouches,
                      InpSRVetoATR, InpSRTargetPart * 100.0,
                      (InpSRStop ? "yes" : "no")));

   //--- These two changed behaviour in v1.40. Blocking new entries while the
   //--- open trade rode the very gap the cut-off exists to avoid was a bug, but
   //--- it is also how every earlier backtest ran - say which mode this is.
   LogAt(LOGL_EVENTS, "ENV",
         StringFormat("halts: Friday cut-off %s (flatten %s) | daily loss %.2f%% (flatten %s)",
                      (InpNoFridayLate ? StringFormat("%02d:00", InpFridayStopHour) : "off"),
                      (InpFlattenOnFriday ? "YES" : "no"),
                      InpMaxDailyLossPct, (InpFlattenOnLoss ? "YES" : "no")));

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      LogErr("algo trading is disabled for this account/terminal - nothing will be executed");

   //--- The timeframe is only a proxy. What actually decides viability is
   //--- spread / ATR, and the SUM line measures that once bars arrive - but the
   //--- proxy is free and catches the obvious case before any money moves.
   if(PeriodSeconds((ENUM_TIMEFRAMES)_Period) < PeriodSeconds(DEF_MIN_TF))
      LogAt(LOGL_EVENTS, "ENV",
            StringFormat("WARNING: the %s profile expects %s or higher, this chart is %s. "
                         "Watch the SUM 'spread avg x ATR' line - a flip system needs it well "
                         "under 0.25 to clear its own costs.",
                         DEF_PROFILE_NAME, EnumToString(DEF_MIN_TF),
                         EnumToString((ENUM_TIMEFRAMES)_Period)));

   if(InpLogLevel >= LOGL_BARS && _Period <= PERIOD_M5)
      LogAt(LOGL_EVENTS, "ENV",
            "WARNING: bar-level logging on this timeframe produces hundreds of lines per day. "
            "Use it for a short diagnostic run, then drop back to level 2.");

   RollDay();
   ArrayFree(g_track);
   g_lastBar      = 0;
   g_lastEntryBar = 0;
   g_lastSumBar   = 0;

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintSummary("final");

   ObjectsDeleteAll(0, "HullSR_");

   if(g_hHull    != INVALID_HANDLE)
      IndicatorRelease(g_hHull);
   if(g_hHullHTF != INVALID_HANDLE)
      IndicatorRelease(g_hHullHTF);
   if(g_hATR     != INVALID_HANDLE)
      IndicatorRelease(g_hATR);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   RollDay();

   //--- management runs every tick: stops must react intrabar
   ManagePositions();

   //--- so must the halts - a Friday cut-off that waits for the next closed
   //--- bar is not a cut-off
   HaltCheck();

   const datetime bt     = iTime(_Symbol, _Period, 0);
   const bool     newBar = (bt != g_lastBar);

   if(!newBar)
     {
      //--- Intrabar: keep working an armed signal. This is what makes the
      //--- stop-and-reverse whole - the close and the re-entry are separate
      //--- server round trips, and the position slot frees up somewhere
      //--- between two ticks, not on a bar boundary.
      ServiceArm();
      return;
     }

   HullSignal sig;
   if(ReadSignal(sig) < 0)
     {
      //--- not ready - retry, bar NOT consumed. A handle that never fills used
      //--- to look exactly like a strategy that never signals.
      if(++g_sigStall == STALL_ALARM)
         LogErr(StringFormat("the Hull/ATR buffers have returned no usable data for %d "
                             "consecutive ticks - check that HullTrend_MT5 is compiled and "
                             "that %s history is loaded", STALL_ALARM, _Symbol));
      return;
     }
   g_sigStall = 0;

   int htfDir = 0;
   if(ReadHTF(htfDir) < 0)
     {
      if(++g_htfStall == STALL_ALARM)
         LogErr(StringFormat("the %s higher-timeframe buffer has returned no data for %d "
                             "consecutive ticks - is that timeframe's history available? "
                             "Nothing will trade until it is.",
                             EnumToString(g_htf), STALL_ALARM));
      return;                          // same: do not consume the bar
     }
   g_htfStall = 0;

   g_lastBar   = bt;                   // bar consumed
   g_armLogged = false;                // one loud veto per bar from here
   g_barsSeen++;

   //--- cost telemetry, sampled once per bar so the average is not dominated
   //--- by whichever ticks happened to arrive
   const double sprATR = (sig.atr > 0.0 ? SpreadPrice() / sig.atr : 0.0);
   g_sprSum += sprATR;
   g_sprN++;
   if(sprATR > g_sprMax)
      g_sprMax = sprATR;

   SizingPreflight(sig.atr);

   //--- levels are rebuilt once per closed bar, before anything consults them
   BuildSR(sig.atr);

   //--- sample the room the trend direction actually has, so the veto threshold
   //--- can be judged against the instrument instead of guessed
   if(InpUseSR && sig.atr > 0.0)
     {
      double roomLvl = 0.0;
      int    roomT   = 0;
      if(SRNearest(sig.entry, sig.dir, roomLvl, roomT))
        {
         g_srRoomSum += MathAbs(roomLvl - sig.entry) / sig.atr;
         g_srRoomN++;
        }
     }

   int nLong = 0, nShort = 0;
   const int nPos = OwnPositions(nLong, nShort);

   LogAt(LOGL_BARS, "BAR",
         StringFormat("%s | trend %-4s htf %-4s | hma %s  atr %s  spread %.2fxATR | "
                      "flip %d  pos %d  levels %d",
                      TimeToString(iTime(_Symbol, _Period, 1), TIME_DATE | TIME_MINUTES),
                      DirName(sig.dir), (g_hHullHTF != INVALID_HANDLE ? DirName(htfDir) : "off"),
                      DoubleToString(sig.hma, _Digits), DoubleToString(sig.atr, _Digits),
                      sprATR, (sig.flip ? 1 : 0), nPos, ArraySize(g_sr)));

   if(InpSummaryBars > 0 && g_barsSeen - g_lastSumBar >= InpSummaryBars)
     {
      g_lastSumBar = g_barsSeen;
      PrintSummary("running");
     }

   //--- age an armed signal from the previous bar
   if(g_armDir != 0)
     {
      if(sig.dir != g_armDir)
         Disarm("the indicator turned the other way before it could be filled");
      else
         if(--g_armBarsLeft < 0)
            Disarm(StringFormat("no entry within %d bars", MathMax(0, InpSignalArmBars)));
     }

   if(sig.flip)
     {
      g_nFlips++;
      LogAt(LOGL_EVENTS, "FLIP",
            StringFormat("%s | now %s | htf %s | close %s  hma %s  atr %s  spread %.2fxATR  pos %d",
                         TimeToString(iTime(_Symbol, _Period, 1), TIME_DATE | TIME_MINUTES),
                         DirName(sig.dir), (g_hHullHTF != INVALID_HANDLE ? DirName(htfDir) : "off"),
                         DoubleToString(sig.entry, _Digits), DoubleToString(sig.hma, _Digits),
                         DoubleToString(sig.atr, _Digits), sprATR, nPos));

      //--- The exit is unconditional. Every entry guard can veto a new trade,
      //--- but none of them is a reason to keep holding a position the model
      //--- has just declared wrong.
      if(InpCloseOnFlip && !CloseAgainst(sig.dir))
         LogAt(LOGL_DECISIONS, "ARM",
               "the opposite position is not closed yet - the entry will retry each tick");

      //--- Arm rather than fire once. See design note 4.
      g_armSig      = sig;
      g_armDir      = sig.dir;
      g_armBarsLeft = MathMax(0, InpSignalArmBars);
      g_nArmed++;
     }

   ServiceArm();
  }
//+------------------------------------------------------------------+
