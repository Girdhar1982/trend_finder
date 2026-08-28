//+------------------------------------------------------------------+
//|                                       QuantRegimeConfluenceEA.mq5|
//|            Execution layer for QuantRegimeConfluence.mq5         |
//+==================================================================+
//|                                                                  |
//|                  ORIENTATION FOR FUTURE MAINTAINERS              |
//|                                                                  |
//| WHAT THIS IS                                                     |
//| The trading half of a two-part system. It contains NO signal     |
//| logic of its own. It attaches to QuantRegimeConfluence.mq5 via   |
//| iCustom, reads that indicator's buffers, and turns them into     |
//| orders with position sizing and risk management.                 |
//|                                                                  |
//| The split is deliberate. The indicator is the model and is       |
//| independently testable; this file is execution only. If a trade  |
//| looks wrong, first decide WHICH half is wrong: does the chart    |
//| show an arrow the EA ignored (execution bug, look here), or is   |
//| the arrow itself wrong (model bug, look in the indicator)?       |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| INVARIANT 1 - ONLY EVER READ SHIFT 1                             |
//| The indicator writes signals to the last CLOSED bar and always   |
//| clears the forming bar to EMPTY_VALUE. In series indexing that   |
//| means shift 0 = forming (always empty), shift 1 = last closed    |
//| bar = the signal. Reading shift 0 will never signal; reading     |
//| shift 2+ acts on stale bars. ALWAYS shift 1, exactly once per    |
//| new bar. See ReadSignal().                                       |
//|                                                                  |
//| INVARIANT 2 - iCustom PARAMETERS ARE POSITIONAL                  |
//| The call in OnInit reaches the indicator's first 27 PARAMETERS,  |
//| but must pass 32 ARGUMENTS to get there: `input group` DOES      |
//| consume a positional slot, and 5 groups fall inside that range.  |
//|                                                                  |
//| An earlier version of this file asserted the opposite and passed |
//| 27. Every value landed one slot left of where it belonged at     |
//| each group - InpMaxBars received 1, InpERPeriod received 2, and  |
//| InpScoreThreshold never arrived at all. It compiled, it ran, and |
//| it produced trades. Nothing failed loudly.                       |
//|                                                                  |
//| If anyone reorders, inserts, or deletes an input OR A GROUP in   |
//| the indicator above InpScoreThreshold, this EA silently feeds    |
//| the wrong values into the wrong parameters again. There is no    |
//| compiler check for it. The indicator prints its resolved config  |
//| at OnInit for exactly this reason - read that line before        |
//| trusting any result.                                             |
//|                                                                  |
//| Indicator inputs 28+ (the logistic weights InpBias, InpW1..W10)  |
//| are left at the indicator's own defaults. To optimise those too, |
//| extend the iCustom call and add matching inputs here, keeping    |
//| the order identical.                                             |
//|                                                                  |
//| INVARIANT 3 - ENTRY PRICE IS NOT THE INDICATOR'S ENTRY           |
//| The indicator computes SL/TP from the CLOSE of the signal bar.   |
//| This EA fills at market on the NEXT bar, so the real fill        |
//| differs by the opening gap. SL/TP are absolute price levels and  |
//| stay valid, but the realised R:R shifts. StaleSignalDrift()      |
//| rejects the trade when that gap has eaten too much of the        |
//| planned risk. Lots are always sized from the REAL fill distance, |
//| never the indicator's theoretical one.                           |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| KNOWN LIMITATION - R TRACKING ACROSS RESTARTS                    |
//| Break-even and trailing are expressed in R (multiples of the     |
//| original stop distance), which requires knowing the ORIGINAL     |
//| stop. That is held in memory (g_track). If the EA is restarted   |
//| while positions are open, OnInit reconstructs R from the CURRENT |
//| stop distance. If the stop had already moved to break-even, the  |
//| reconstruction is wrong, so such positions are flagged           |
//| reconstructed=true and are only trailed, never re-break-evened.  |
//| Positions opened before a restart therefore manage slightly      |
//| differently from ones opened after. Accepted trade-off: the      |
//| alternative is encoding state in the order comment, which        |
//| brokers are free to rewrite.                                     |
//|                                                                  |
//+------------------------------------------------------------------+
//|                                                                  |
//| HOW TO BACKTEST  (see also the TESTING section of the indicator) |
//|                                                                  |
//|  Modelling: use "Every tick based on real ticks" if your broker  |
//|  provides them. This EA enters on bar open, but exits are SL/TP  |
//|  hits INSIDE a bar, so intrabar path matters. "Open prices only" |
//|  is INVALID here and will produce nonsense. "1 minute OHLC" is   |
//|  an acceptable faster approximation.                             |
//|                                                                  |
//|  Costs: set a realistic spread (not "current"), and enter your   |
//|  broker's commission in the symbol settings. The indicator's     |
//|  on-chart win/loss panel models NEITHER, so the EA's tester      |
//|  result will always be worse than the panel. That gap is the     |
//|  cost of trading, not a bug.                                     |
//|                                                                  |
//|  Warm-up: the indicator needs ~117 bars of each higher timeframe |
//|  BEFORE the test start date. Start the test at least a few       |
//|  months after your data begins or the first trades are missing.  |
//|                                                                  |
//|  Optimising: optimise the indicator thresholds (inputs 12-27)    |
//|  and the risk block separately, never together - they interact   |
//|  and the joint space is far too large to trust.                  |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Market profile                                                   |
//|                                                                  |
//| The wrapper .mq5 defines one of these before including this file. |
//| ONLY DEFAULTS differ between profiles - every one runs identical  |
//| logic, so a fix made here reaches all of them. Nothing is locked: |
//| each value below is still an input the user can override.         |
//|                                                                  |
//| NOTE on DEF_MAX_SPREAD_PTS: this guard is in absolute POINTS, not |
//| a fraction of range, so it is instrument-specific by nature. The  |
//| crypto default is loose because a crypto CFD spread of 30 points  |
//| would be blocked outright by the forex value - which looks        |
//| exactly like the model never signalling. Tune it per symbol.      |
//+------------------------------------------------------------------+
#ifdef QRC_PROFILE_CRYPTO
   #define DEF_PROFILE_NAME     "crypto"
   #define DEF_MIN_TF           PERIOD_H1
   #define DEF_RISK_PCT         0.50
   #define DEF_MAX_SPREAD_PTS   60.0        // crypto CFD spreads dwarf FX ones
   #define DEF_NO_FRIDAY_LATE   false       // 24/7 market, no Friday close
   #define DEF_MAX_DAILY_LOSS   4.0
   #define DEF_MAGIC            20260830
   #define DEF_COMMENT          "QRC-C"
#endif

#ifdef QRC_PROFILE_FOREX
   #define DEF_PROFILE_NAME     "forex"
   #define DEF_MIN_TF           PERIOD_M15
   #define DEF_RISK_PCT         0.50
   #define DEF_MAX_SPREAD_PTS   25.0
   #define DEF_NO_FRIDAY_LATE   true        // weekend gap risk is real in FX
   #define DEF_MAX_DAILY_LOSS   3.0
   #define DEF_MAGIC            20260829
   #define DEF_COMMENT          "QRC-FX"
#endif

//--- no profile defined: the original defaults, unchanged
#ifndef DEF_PROFILE_NAME
   #define DEF_PROFILE_NAME     "generic"
   #define DEF_MIN_TF           PERIOD_M15
   #define DEF_RISK_PCT         0.50
   #define DEF_MAX_SPREAD_PTS   25.0
   #define DEF_NO_FRIDAY_LATE   false
   #define DEF_MAX_DAILY_LOSS   3.0
   #define DEF_MAGIC            20260825
   #define DEF_COMMENT          "QRC"
#endif

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- must mirror the indicator's enums (same order, same values)
enum ENUM_REG_SRC_EA
  {
   EA_REG_LOW  = 0,  // Signal timeframe (chart)
   EA_REG_MID  = 1,  // Mid timeframe
   EA_REG_HIGH = 2   // High timeframe
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "======== A. Model (passed straight to the indicator) ========"
//--- These 27 values are forwarded to QuantRegimeConfluence.mq5 in
//--- declaration order. Keep this block in sync with the indicator.
input bool    InpAutoLadder      = true;      // Auto-derive mid/high TF from chart TF
input ENUM_TIMEFRAMES InpTF_Mid  = PERIOD_H1; // Mid TF (when AutoLadder = false)
input ENUM_TIMEFRAMES InpTF_High = PERIOD_H4; // High TF (when AutoLadder = false)
input int     InpMaxBars         = 1500;      // Indicator history bars
input ENUM_REG_SRC_EA InpRegimeSrc = EA_REG_MID; // Regime measured on
input int     InpRetLookback     = 100;       // N: variance-ratio returns
input int     InpVRq             = 4;         // q: variance-ratio aggregation
input int     InpVolFast         = 20;        // n_fast variance window
input int     InpVolSlow         = 100;       // n_slow variance window
input int     InpERPeriod        = 20;        // efficiency-ratio window
input int     InpSlopePeriod     = 30;        // OLS regression window
input double  InpTrendERn        = 2.05;      // theta_ER  (1.00 = random walk)
input double  InpSlopeT          = 2.10;      // theta_t   (1.00 = random walk)
input double  InpVRz             = 1.30;      // theta_VR  (0.00 = random walk)
input double  InpExpandF         = 1.40;      // theta_F+  expansion
input double  InpCompressF       = 0.65;      // theta_F-  compression
input double  InpSoftmaxTemp     = 1.00;      // softmax temperature
input double  InpMinRegimeConf   = 0.55;      // min regime confidence
input bool    InpAllowExpansion  = false;     // allow signals in expansion regime
input double  InpW_T1            = 1.00;      // trend weight 1
input double  InpW_T2            = 0.50;      // trend weight 2
input double  InpW_T3            = 0.45;      // trend weight 3
input double  InpW_E1            = 1.20;      // expansion weight 1
input double  InpW_E2            = 0.60;      // expansion weight 2
input double  InpW_C1            = 1.40;      // compression weight 1
input double  InpW_C2            = 0.35;      // compression weight 2
input double  InpScoreThreshold  = 85.0;      // Signal Strength Score threshold

input group "======== B. Risk and sizing ========"
input double  InpRiskPercent     = DEF_RISK_PCT;      // Risk per trade (% of balance)
input double  InpFixedLots       = 0.0;       // Fixed lots (>0 overrides risk %)
input double  InpMaxLots         = 5.0;       // Hard lot cap
input double  InpMaxSpreadPts    = DEF_MAX_SPREAD_PTS;      // Max spread to enter (points, 0 = off)
input double  InpMaxDriftR       = 0.35;      // Reject if price drifted > this x risk
input int     InpSlippagePts     = 20;        // Max deviation (points)

input group "======== C. Trade management ========"
input int     InpMaxPositions    = 1;         // Max simultaneous positions
input bool    InpOnePerDirection = true;      // Block a 2nd position in the same direction
input bool    InpCloseOnOpposite = false;     // Close when an opposite signal prints
input bool    InpUseBreakEven    = true;      // Move stop to break-even
input double  InpBEatR           = 1.00;      // Break-even trigger (R)
input double  InpBEoffsetPts     = 5.0;       // Break-even offset (points, covers costs)
input bool    InpUseTrailing     = true;      // Trail the stop
input double  InpTrailStartR     = 1.50;      // Start trailing at (R)
input double  InpTrailDistR      = 1.00;      // Trail distance (R)
input double  InpTrailStepR      = 0.10;      // Min stop advance before modifying (R, 0 = every tick)

input group "======== D. Guards ========"
input bool    InpUseTimeFilter   = false;     // Restrict trading hours (server time)
input int     InpStartHour       = 7;         // Start hour
input int     InpEndHour         = 20;        // End hour
input bool    InpNoFridayLate    = DEF_NO_FRIDAY_LATE;     // No new trades late Friday
input int     InpFridayStopHour  = 19;        // Friday cut-off hour
input double  InpMaxDailyLossPct = DEF_MAX_DAILY_LOSS;       // Halt for the day after this % loss (0 = off)
input int     InpMaxTradesPerDay = 0;         // Max new trades per day (0 = unlimited)

input group "======== E. Bookkeeping ========"
input long    InpMagic           = DEF_MAGIC;  // Magic number
input string  InpComment         = DEF_COMMENT;     // Order comment
input bool    InpVerboseLog      = true;      // Log decisions to the Experts tab
input int     InpSummaryBars     = 12;        // Heartbeat every N closed bars (0 = off)

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        g_trade;
CPositionInfo g_pos;

int      g_hQRC     = INVALID_HANDLE;
datetime g_lastBar  = 0;

//--- per-position R tracking (see KNOWN LIMITATION in the header)
struct TrackRec
  {
   ulong             ticket;
   double            entry;
   double            risk;          // original stop distance in price units
   int               dir;
   bool              beDone;
   bool              reconstructed;
  };
TrackRec g_track[];

//--- daily guards
datetime g_dayStart      = 0;
double   g_dayStartEquity = 0.0;
int      g_tradesToday   = 0;
bool     g_dayBlocked    = false;

//--- Watchdog counters. This EA logs only when something happens, so a run
//--- that produces no signal produces no output at all - indistinguishable
//--- from a broken handle, a stopped terminal or an EA that was never really
//--- attached. The heartbeat below turns that silence into a number: how many
//--- bars were examined, and how close the last one came to the threshold.
int      g_barsSeen     = 0;
int      g_nSignals     = 0;
int      g_nEntries     = 0;
int      g_lastSumBar   = 0;
double   g_lastScore    = 0.0;
int      g_lastRegime   = -1;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   if(InpVerboseLog) Print("QRC-EA | ", msg);
  }

//--- Proof of life, every InpSummaryBars closed bars. The score is the single
//--- number that explains a quiet run: if it never approaches the threshold
//--- the model is simply not finding this market, which is a very different
//--- problem from the EA not running.
void Heartbeat()
  {
   if(InpSummaryBars <= 0) return;
   //--- Always speak on the FIRST closed bar of a run. Waiting a full interval
   //--- to say anything is the same silence this is meant to cure: on M5 with
   //--- the default interval that is an hour before the log confirms the EA is
   //--- alive, which is long enough to conclude it is not.
   if(g_barsSeen > 1 && g_barsSeen - g_lastSumBar < InpSummaryBars) return;
   g_lastSumBar = g_barsSeen;

   int nLong = 0, nShort = 0;
   const int nPos = OwnPositions(nLong, nShort);
   Log(StringFormat("watching | bars %d  signals %d  entries %d  open %d | "
                    "last score %.1f (need >= %.1f)  regime %d  spread %.1f pts (max %.1f)",
                    g_barsSeen, g_nSignals, g_nEntries, nPos,
                    g_lastScore, InpScoreThreshold, g_lastRegime,
                    SpreadPts(), InpMaxSpreadPts));
  }

double Pt()       { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
double Ask()      { return SymbolInfoDouble(_Symbol, SYMBOL_ASK);   }
double Bid()      { return SymbolInfoDouble(_Symbol, SYMBOL_BID);   }
double SpreadPts(){ return (Ask() - Bid()) / Pt(); }

//--- broker minimum distance for stops, in price units
double MinStopDist()
  {
   const long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long frz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(lvl, frz) * Pt();
  }

double NormPrice(const double p)
  {
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| Position sizing from a real stop distance.                       |
//| Uses tick value / tick size so it is correct for FX, metals,     |
//| indices and crypto alike - never assume 1 point = 1 unit.        |
//+------------------------------------------------------------------+
double CalcLots(const double stopDistance)
  {
   if(InpFixedLots > 0.0) return InpFixedLots;
   if(stopDistance <= 0.0) return 0.0;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
     {
      Log("cannot size: broker reports tickValue/tickSize <= 0");
      return 0.0;
     }

   const double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   const double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;

   double lots = riskMoney / lossPerLot;

   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step > 0.0) lots = MathFloor(lots / step) * step;
   lots = MathMin(lots, MathMin(maxL, InpMaxLots));

   if(lots < minL)
     {
      Log(StringFormat("risk %.2f%% implies %.4f lots, below broker minimum %.4f - trade skipped "
                       "(reduce risk or use a smaller stop)", InpRiskPercent, lots, minL));
      return 0.0;
     }
   return NormalizeDouble(lots, 2);
  }

//--- reject the order if we cannot afford it rather than letting the server do it
bool MarginOK(const ENUM_ORDER_TYPE type, const double lots, const double price)
  {
   double need = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, need))
      return false;
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(need > free * 0.90)
     {
      Log(StringFormat("insufficient margin: need %.2f, free %.2f", need, free));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Position tracking                                                |
//+------------------------------------------------------------------+
int TrackFind(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_track); i++)
      if(g_track[i].ticket == ticket) return i;
   return -1;
  }

//--- Overwrites an existing record for the same ticket rather than appending
//--- a second one. A duplicate would be invisible: TrackFind() returns the
//--- FIRST match, so the stale entry/risk would silently win and every R
//--- calculation for that position would be wrong.
void TrackAdd(const ulong ticket, const double entry, const double risk,
              const int dir, const bool reconstructed)
  {
   int n = TrackFind(ticket);
   if(n < 0)
     {
      n = ArraySize(g_track);
      ArrayResize(g_track, n + 1);
     }
   g_track[n].ticket        = ticket;
   g_track[n].entry         = entry;
   g_track[n].risk          = risk;
   g_track[n].dir           = dir;
   g_track[n].beDone        = reconstructed;   // never re-BE a reconstructed position
   g_track[n].reconstructed = reconstructed;
  }

//--- drop records whose position no longer exists
void TrackPrune()
  {
   for(int i = ArraySize(g_track) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_track[i].ticket))
        {
         for(int k = i + 1; k < ArraySize(g_track); k++)
            g_track[k-1] = g_track[k];
         ArrayResize(g_track, ArraySize(g_track) - 1);
        }
     }
  }

//--- Counts our positions PER DIRECTION. A single `dir` output cannot
//--- describe more than one position - it would only report whichever was
//--- iterated last, so the InpOnePerDirection guard would test an arbitrary
//--- position and could wave a duplicate entry through.
int OwnPositions(int &nLong, int &nShort)
  {
   nLong  = 0;
   nShort = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic() != InpMagic) continue;
      if(g_pos.PositionType() == POSITION_TYPE_BUY) nLong++;
      else                                          nShort++;
     }
   return nLong + nShort;
  }

//+------------------------------------------------------------------+
//| Read the indicator at shift 1 - the last CLOSED bar (INVARIANT 1)|
//+------------------------------------------------------------------+
struct QRCSignal
  {
   bool              valid;
   int               dir;        // +1 buy, -1 sell, 0 none
   double            score;
   int               regime;
   double            entry;      // close of the signal bar, per the indicator
   double            sl;
   double            tp;
  };

//--- returns: -1 = indicator data not available yet (do NOT consume the bar)
//---            0 = bar read fine, no signal on it
//---           +1 = signal present
int ReadSignal(QRCSignal &sig)
  {
   sig.valid = false; sig.dir = 0; sig.score = 0.0; sig.regime = -1;
   sig.entry = 0.0; sig.sl = 0.0; sig.tp = 0.0;

   double buy[], sell[], score[], regime[], sl[], tp[];
   ArraySetAsSeries(buy, true);  ArraySetAsSeries(sell, true);
   ArraySetAsSeries(score, true);ArraySetAsSeries(regime, true);
   ArraySetAsSeries(sl, true);   ArraySetAsSeries(tp, true);

   //--- shift 1, exactly one value: the last closed bar
   //--- a failed CopyBuffer means the indicator has not calculated this bar
   //--- yet (warm-up, history gap). That is NOT "no signal" - report -1 so
   //--- OnTick retries on the next tick instead of discarding the bar.
   if(CopyBuffer(g_hQRC, 0, 1, 1, buy)    < 1) return -1;
   if(CopyBuffer(g_hQRC, 1, 1, 1, sell)   < 1) return -1;
   if(CopyBuffer(g_hQRC, 2, 1, 1, score)  < 1) return -1;
   if(CopyBuffer(g_hQRC, 3, 1, 1, regime) < 1) return -1;
   if(CopyBuffer(g_hQRC, 5, 1, 1, sl)     < 1) return -1;
   if(CopyBuffer(g_hQRC, 6, 1, 1, tp)     < 1) return -1;

   sig.score  = score[0];
   sig.regime = (int)regime[0];

   const bool hasBuy  = (buy[0]  != EMPTY_VALUE && buy[0]  != 0.0 && MathAbs(buy[0])  < 1e30);
   const bool hasSell = (sell[0] != EMPTY_VALUE && sell[0] != 0.0 && MathAbs(sell[0]) < 1e30);
   if(!hasBuy && !hasSell) return 0;

   //--- arrow without levels should be impossible; treat as no signal, loudly
   if(sl[0] == EMPTY_VALUE || tp[0] == EMPTY_VALUE)
     {
      Log("arrow present but SL/TP empty - ignoring (indicator/EA version mismatch?)");
      return 0;
     }

   sig.dir   = (hasBuy ? 1 : -1);
   sig.sl    = sl[0];
   sig.tp    = tp[0];
   sig.entry = iClose(_Symbol, _Period, 1);   // indicator entry = close of signal bar
   sig.valid = true;
   return 1;
  }

//+------------------------------------------------------------------+
//| How far price has run away from the indicator's entry, in R.     |
//| Large drift means the move already happened without us; taking   |
//| the trade there ruins the risk:reward the model assumed.         |
//+------------------------------------------------------------------+
double StaleSignalDrift(const QRCSignal &sig, const double fill)
  {
   const double risk = MathAbs(sig.entry - sig.sl);
   if(risk <= 0.0) return 999.0;
   return ((fill - sig.entry) * sig.dir) / risk;   // positive = moved our way
  }

//+------------------------------------------------------------------+
//| Daily guards                                                     |
//+------------------------------------------------------------------+
void RollDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   const datetime today = StructToTime(t);
   if(today != g_dayStart)
     {
      g_dayStart        = today;
      g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday     = 0;
      g_dayBlocked      = false;
     }
  }

bool DailyLossHit()
  {
   if(InpMaxDailyLossPct <= 0.0) return false;
   if(g_dayStartEquity   <= 0.0) return false;
   const double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lost = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
   if(lost >= InpMaxDailyLossPct)
     {
      if(!g_dayBlocked)
         Log(StringFormat("daily loss limit hit (-%.2f%%) - no new trades today", lost));
      g_dayBlocked = true;
      return true;
     }
   return false;
  }

bool TimeAllowed()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpNoFridayLate && t.day_of_week == 5 && t.hour >= InpFridayStopHour)
      return false;
   if(!InpUseTimeFilter) return true;
   if(InpStartHour <= InpEndHour)
      return (t.hour >= InpStartHour && t.hour < InpEndHour);
   return (t.hour >= InpStartHour || t.hour < InpEndHour);   // wraps midnight
  }

//+------------------------------------------------------------------+
//| Entry                                                            |
//+------------------------------------------------------------------+
void TryEnter(const QRCSignal &sig)
  {
   int nLong = 0, nShort = 0;
   const int nPos = OwnPositions(nLong, nShort);

   if(nPos >= InpMaxPositions)
     { Log("signal ignored: position limit reached"); return; }
   if(InpOnePerDirection &&
      ((sig.dir > 0 && nLong > 0) || (sig.dir < 0 && nShort > 0)))
     { Log("signal ignored: already in this direction"); return; }
   if(!TimeAllowed())
     { Log("signal ignored: outside trading window"); return; }
   if(DailyLossHit())
     { return; }
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
     { Log("signal ignored: daily trade cap reached"); return; }
   if(InpMaxSpreadPts > 0.0 && SpreadPts() > InpMaxSpreadPts)
     { Log(StringFormat("signal ignored: spread %.1f pts > %.1f", SpreadPts(), InpMaxSpreadPts)); return; }

   const double fill = (sig.dir > 0 ? Ask() : Bid());

   //--- INVARIANT 3: reject a signal price has already run away from
   const double drift = StaleSignalDrift(sig, fill);
   if(drift > InpMaxDriftR)
     {
      Log(StringFormat("signal ignored: price already moved %.2fR past the model entry "
                       "(limit %.2fR)", drift, InpMaxDriftR));
      return;
     }
   //--- also refuse if price gapped THROUGH the stop
   if((sig.dir > 0 && fill <= sig.sl) || (sig.dir < 0 && fill >= sig.sl))
     { Log("signal ignored: price already beyond the stop level"); return; }

   double sl = sig.sl;
   double tp = sig.tp;

   //--- respect the broker's minimum stop distance, widening if needed
   const double minD = MinStopDist();
   if(minD > 0.0)
     {
      if(MathAbs(fill - sl) < minD)
         sl = (sig.dir > 0 ? fill - minD : fill + minD);
      if(MathAbs(tp - fill) < minD)
         tp = (sig.dir > 0 ? fill + minD : fill - minD);
     }

   sl = NormPrice(sl);
   tp = NormPrice(tp);

   //--- size from the REAL distance, not the indicator's theoretical one
   const double realRisk = MathAbs(fill - sl);
   const double lots     = CalcLots(realRisk);
   if(lots <= 0.0) return;

   const ENUM_ORDER_TYPE type = (sig.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!MarginOK(type, lots, fill)) return;

   g_trade.SetDeviationInPoints(InpSlippagePts);

   const string cmt = InpComment + (sig.dir > 0 ? " L " : " S ") +
                      DoubleToString(sig.score, 0);

   bool ok = (sig.dir > 0) ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt)
                           : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);

   if(!ok)
     {
      Log(StringFormat("order FAILED: retcode=%d (%s)",
                       g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      return;
     }

   const ulong  ticket   = g_trade.ResultOrder();
   const double realFill = (g_trade.ResultPrice() > 0.0 ? g_trade.ResultPrice() : fill);
   g_tradesToday++;
   g_nEntries++;

   Log(StringFormat("%s %.2f lots @ %s  SL %s  TP %s  | score %.1f  regime %d  "
                    "risk %.2f%%  drift %.2fR",
                    (sig.dir > 0 ? "BUY " : "SELL"), lots, DoubleToString(realFill, _Digits),
                    DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
                    sig.score, sig.regime, InpRiskPercent, drift));

   //--- Identify the position THIS order created, and start tracking R.
   //--- Scanning PositionsTotal() for the first symbol+magic match is wrong
   //--- as soon as two positions can be open: it can bind this trade's entry
   //--- and risk to an older ticket, corrupting that position's break-even
   //--- and trailing. Resolve the ticket explicitly instead.
   ulong posTicket = 0;

   //--- hedging accounts: the position ticket IS the opening order ticket
   if(ticket > 0 && PositionSelectByTicket(ticket))
      posTicket = ticket;

   //--- netting accounts: exactly one position per symbol, so this is
   //--- unambiguous. Note the order may have merged into an existing
   //--- position - TrackAdd() overwrites rather than duplicating.
   if(posTicket == 0 && PositionSelect(_Symbol) &&
      PositionGetInteger(POSITION_MAGIC) == InpMagic)
      posTicket = (ulong)PositionGetInteger(POSITION_TICKET);

   if(posTicket > 0)
      TrackAdd(posTicket, realFill, MathAbs(realFill - sl), sig.dir, false);
   else
      Log("warning: order placed but position not found for R tracking");
  }

//+------------------------------------------------------------------+
//| Break-even and trailing, both expressed in R                     |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   TrackPrune();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic) continue;

      const ulong  ticket = g_pos.Ticket();
      const int    dir    = (g_pos.PositionType() == POSITION_TYPE_BUY ? 1 : -1);
      const double open   = g_pos.PriceOpen();
      const double curSL  = g_pos.StopLoss();
      const double curTP  = g_pos.TakeProfit();
      const double price  = (dir > 0 ? Bid() : Ask());

      int idx = TrackFind(ticket);
      if(idx < 0)
        {
         //--- restarted with this position open: reconstruct R (see LIMITATION)
         const double r = (curSL > 0.0 ? MathAbs(open - curSL) : 0.0);
         if(r <= 0.0) continue;
         TrackAdd(ticket, open, r, dir, true);
         idx = TrackFind(ticket);
         Log(StringFormat("adopted existing position #%I64u, R reconstructed as %.5f", ticket, r));
        }

      const double risk = g_track[idx].risk;
      if(risk <= 0.0) continue;

      const double rNow = ((price - open) * dir) / risk;
      double newSL     = curSL;
      bool   beApplied = false;

      //--- break-even. beDone is set only once the stop is actually AT
      //--- break-even, never merely because we tried: the modify below can
      //--- still be abandoned by the broker's freeze band, and marking it
      //--- done here would mean break-even is never retried.
      if(InpUseBreakEven && !g_track[idx].beDone && rNow >= InpBEatR)
        {
         const double be = open + dir * InpBEoffsetPts * Pt();
         if((dir > 0 && be > curSL) || (dir < 0 && (curSL == 0.0 || be < curSL)))
           {
            newSL     = be;
            beApplied = true;
           }
         else
            //--- stop is already at or beyond break-even: nothing to do
            g_track[idx].beDone = true;
        }

      //--- Trailing, throttled by a minimum advance. Unthrottled, the stop
      //--- moves on every one-point tick in our favour, and each move is a
      //--- PositionModify server call - which floods the broker on a trending
      //--- position and can be refused outright under rate limiting.
      //---
      //--- The advance is measured against the stop the broker currently holds,
      //--- not against newSL: measuring against newSL would let a break-even
      //--- move staged on this same tick satisfy the step on the trail's
      //--- behalf, and the throttle would do nothing on the one tick where
      //--- both fire. Break-even itself is never throttled - it is a one-shot
      //--- move that must happen when it is earned.
      if(InpUseTrailing && rNow >= InpTrailStartR)
        {
         const double trail = price - dir * InpTrailDistR * risk;
         const double step  = MathMax(0.0, InpTrailStepR) * risk;

         const bool   noStop  = (curSL == 0.0);
         const double advance = (noStop ? 0.0 : (trail - curSL) * dir);

         if((dir > 0 && trail > newSL) || (dir < 0 && (newSL == 0.0 || trail < newSL)))
            if(noStop || advance >= step)
               newSL = trail;
        }

      if(newSL != curSL && newSL > 0.0)
        {
         //--- never push the stop inside the broker's freeze band
         const double minD = MinStopDist();
         if(MathAbs(price - newSL) < minD) continue;
         newSL = NormPrice(newSL);
         if(newSL == NormPrice(curSL))
           {
            if(beApplied) g_track[idx].beDone = true;   // already there
            continue;
           }

         if(g_trade.PositionModify(ticket, newSL, curTP))
           {
            if(beApplied) g_track[idx].beDone = true;
            Log(StringFormat("#%I64u stop -> %s (%.2fR open)", ticket,
                             DoubleToString(newSL, _Digits), rNow));
           }
         else
            Log(StringFormat("#%I64u stop modify failed: %d (%s)", ticket,
                             g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
        }
     }
  }

void CloseOpposite(const int newDir)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != InpMagic) continue;
      const int dir = (g_pos.PositionType() == POSITION_TYPE_BUY ? 1 : -1);
      if(dir == newDir) continue;
      if(g_trade.PositionClose(g_pos.Ticket()))
         Log(StringFormat("#%I64u closed on opposite signal", g_pos.Ticket()));
     }
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

   //--- INVARIANT 2: iCustom arguments are POSITIONAL, and `input group`
   //--- occupies a slot of its own. QuantRegimeConfluence declares 74
   //--- parameters, and 5 groups fall inside the range we forward, so
   //--- reaching InpScoreThreshold takes 32 arguments - not 27. Passing 27
   //--- shifts every value one slot left at each group and fails SILENTLY:
   //--- the indicator runs happily with the wrong numbers. Do not reorder,
   //--- and do not drop the placeholders.
   g_hQRC = iCustom(_Symbol, _Period, "QuantRegimeConfluence",
                    0,                    //  1 group "A. Timeframes"
                    InpAutoLadder,        //  2
                    InpTF_Mid,            //  3
                    InpTF_High,           //  4
                    InpMaxBars,           //  5
                    0,                    //  6 group "B. Regime model"
                    (int)InpRegimeSrc,    //  7
                    InpRetLookback,       //  8
                    InpVRq,               //  9
                    InpVolFast,           // 10
                    InpVolSlow,           // 11
                    InpERPeriod,          // 12
                    InpSlopePeriod,       // 13
                    0,                    // 14 group "C. Regime thresholds"
                    InpTrendERn,          // 15
                    InpSlopeT,            // 16
                    InpVRz,               // 17
                    InpExpandF,           // 18
                    InpCompressF,         // 19
                    InpSoftmaxTemp,       // 20
                    InpMinRegimeConf,     // 21
                    InpAllowExpansion,    // 22
                    0,                    // 23 group "D. Confluence weights"
                    InpW_T1,              // 24
                    InpW_T2,              // 25
                    InpW_T3,              // 26
                    InpW_E1,              // 27
                    InpW_E2,              // 28
                    InpW_C1,              // 29
                    InpW_C2,              // 30
                    0,                    // 31 group "E. Signal"
                    InpScoreThreshold     // 32
                   );

   if(g_hQRC == INVALID_HANDLE)
     {
      Print("QRC-EA | FATAL: cannot create the indicator handle. ",
            "Is QuantRegimeConfluence.ex5 in MQL5\\Indicators ?");
      return INIT_FAILED;
     }

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("QRC-EA | WARNING: algo trading is disabled for this account/terminal.");

   RollDay();
   ArrayFree(g_track);

   //--- Cleared together, so the heartbeat always describes THIS run rather
   //--- than a mixture of this one and whatever the instance did before the
   //--- last timeframe or parameter change.
   g_lastBar    = 0;
   g_barsSeen   = 0;
   g_nSignals   = 0;
   g_nEntries   = 0;
   g_lastSumBar = 0;
   g_lastScore  = 0.0;
   g_lastRegime = -1;

   //--- Netting vs hedging decides whether two EAs can share a symbol at all.
   //--- On netting there is one position per symbol, so they cannot: each would
   //--- be trading a position the other also believes it owns.
   const long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   const bool hedging    = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   Log(StringFormat("account: %s | currency %s | leverage 1:%d",
                    (hedging ? "HEDGING"
                             : (marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE
                                ? "EXCHANGE" : "NETTING")),
                    AccountInfoString(ACCOUNT_CURRENCY),
                    (int)AccountInfoInteger(ACCOUNT_LEVERAGE)));
   if(!hedging)
      Log("NOTE: netting account - the broker keeps exactly ONE position per "
          "symbol. A second EA trading this same symbol shares that position: "
          "its orders can reduce or close what this EA opened, and the magic- "
          "number filter cannot separate them. Give each EA its own symbol, or "
          "use a hedging account.");

   //--- The timeframe is only a proxy for what actually matters, which is
   //--- spread relative to the range this model trades. It is free, though,
   //--- and it catches the obvious case before any money moves.
   if(PeriodSeconds((ENUM_TIMEFRAMES)_Period) < PeriodSeconds(DEF_MIN_TF))
      Log(StringFormat("WARNING: the %s profile expects %s or higher, this chart is %s - "
                       "check that the spread is small against the stop distances the "
                       "indicator is producing.",
                       DEF_PROFILE_NAME, EnumToString(DEF_MIN_TF),
                       EnumToString((ENUM_TIMEFRAMES)_Period)));

   Log(StringFormat("started on %s %s | profile %s | risk %.2f%% | score>=%.0f | "
                    "maxSpread %.0f pts | magic %I64d",
                    _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), DEF_PROFILE_NAME,
                    InpRiskPercent, InpScoreThreshold, InpMaxSpreadPts, InpMagic));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_hQRC != INVALID_HANDLE) IndicatorRelease(g_hQRC);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   RollDay();

   //--- management runs every tick: stops must react intrabar
   ManagePositions();

   //--- entries run once per closed bar (INVARIANT 1)
   const datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == g_lastBar) return;

   QRCSignal sig;
   const int rc = ReadSignal(sig);
   if(rc < 0) return;              // not ready - retry next tick, bar NOT consumed
   g_lastBar = bt;                 // bar consumed
   g_barsSeen++;
   g_lastScore  = sig.score;
   g_lastRegime = sig.regime;
   Heartbeat();
   if(rc == 0) return;             // read fine, nothing on this bar
   g_nSignals++;

   if(InpCloseOnOpposite) CloseOpposite(sig.dir);

   TryEnter(sig);
  }
//+------------------------------------------------------------------+
