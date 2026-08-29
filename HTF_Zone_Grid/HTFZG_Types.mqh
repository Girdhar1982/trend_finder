//+------------------------------------------------------------------+
//|                                                  HTFZG_Types.mqh |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+==================================================================+
//|                                                                  |
//| THE SHARED VOCABULARY of HTF_Zone_Grid_3Level_EA.                |
//|                                                                  |
//| Every other file in this folder includes this one and NOTHING    |
//| includes them back. That is the whole point: Analysis, Grid and  |
//| Panel must never include each other, or the include graph turns  |
//| into a cycle the moment one of them needs a type from another.   |
//| All shared types live here, once.                                |
//|                                                                  |
//| Nothing in this file computes anything or touches the market.    |
//| It is data shapes and constants only.                            |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#define HTFZG_MAX_LEVELS 3          // hard ceiling - see PROTECTION in the spec

//+------------------------------------------------------------------+
//| Direction of the higher-timeframe bias.                          |
//|                                                                  |
//| The numeric values are deliberate: +1 / -1 / 0 lets price maths  |
//| be written once and signed by direction instead of duplicated in |
//| an if/else pair, which is where sign bugs breed in grid code.    |
//+------------------------------------------------------------------+
enum ENUM_HTFZG_DIR
  {
   HTFZG_DIR_SELL = -1,
   HTFZG_DIR_NONE =  0,
   HTFZG_DIR_BUY  =  1
  };

//+------------------------------------------------------------------+
//| The EA state machine. Exactly one grid per symbol, ever, so this |
//| is a single variable and not a collection.                       |
//|                                                                  |
//|   IDLE     - hunting. No orders of ours exist.                   |
//|   ACTIVE   - Level 1 filled; L2/L3 may be pending or filled.     |
//|   PARTIAL  - TP1 taken, 50% closed, remainder at breakeven+.     |
//|              All unfilled pendings have been deleted.            |
//|   COOLDOWN - a grid just closed, or the daily loss cap tripped.  |
//|                                                                  |
//| There is no ARMED state on purpose. A signal that scores >= 80   |
//| is acted on at that bar close or discarded; carrying a signal    |
//| forward would mean re-validating the whole confluence next bar,  |
//| which is the same work as simply re-scanning.                    |
//+------------------------------------------------------------------+
enum ENUM_HTFZG_STATE
  {
   HTFZG_IDLE     = 0,
   HTFZG_ACTIVE   = 1,
   HTFZG_PARTIAL  = 2,
   HTFZG_COOLDOWN = 3
  };

//+------------------------------------------------------------------+
//| A confluence zone on the 1H chart.                               |
//+------------------------------------------------------------------+
struct HTFZGZone
  {
   double            high;          // zHigh
   double            low;           // zLow
   datetime          formed;        // time of the pivot that anchors it
   int               touches;       // how many times price respected it
   bool              valid;

                     HTFZGZone() { high=0; low=0; formed=0; touches=0; valid=false; }
   double            Mid()    const { return (high + low) * 0.5; }
   double            Height() const { return high - low; }
  };

//+------------------------------------------------------------------+
//| One scan of the market: everything the grid builder needs, plus  |
//| the score breakdown that the dashboard and the log both print.   |
//|                                                                  |
//| `reject` carries the FIRST gate that failed. A blank string      |
//| means the scan ran to completion. This is the field that makes   |
//| a quiet EA debuggable - without it, "no trades in three months"  |
//| is indistinguishable from "broken since the last edit".          |
//+------------------------------------------------------------------+
struct HTFZGSignal
  {
   ENUM_HTFZG_DIR    dir;
   HTFZGZone         zone;

   double            sweepExtreme;  // wick low (BUY) / high (SELL) that swept the zone
   double            bosPrice;      // 5M structure break price = the Level 1 reference
   double            atr15;         // ATR(15M) - sets the SL buffer and the grid spacing
   double            atr5;

   //--- score components, so the dashboard can show WHY it scored what it did
   int               sTrend;        // 20  mandatory
   int               sZone;         // 20  mandatory
   int               sPivot;        // 15  bonus
   int               sSweep;        // 20  mandatory (defines sharedSL)
   int               sBOS;          // 15  mandatory (defines Level 1)
   int               sVol;          // 10  bonus
   int               total;

   string            reject;

                     HTFZGSignal() { Reset(); }
   void              Reset()
     {
      dir=HTFZG_DIR_NONE; zone=HTFZGZone(); sweepExtreme=0; bosPrice=0;
      atr15=0; atr5=0;
      sTrend=0; sZone=0; sPivot=0; sSweep=0; sBOS=0; sVol=0; total=0;
      reject="";
     }
   void              Sum() { total = sTrend+sZone+sPivot+sSweep+sBOS+sVol; }
  };

//+------------------------------------------------------------------+
//| One rung of the ladder.                                          |
//|                                                                  |
//| `ticket` is the POSITION ticket once filled and the ORDER ticket |
//| while pending. `filled` says which one it currently is - never   |
//| infer that from the ticket value alone.                          |
//+------------------------------------------------------------------+
struct HTFZGLevel
  {
   double            price;
   double            lots;
   ulong             ticket;
   bool              placed;        // an order/position actually exists at the broker
   bool              filled;
   bool              isMarket;      // true only for Level 1

                     HTFZGLevel() { price=0; lots=0; ticket=0; placed=false; filled=false; isMarket=false; }
  };

//+------------------------------------------------------------------+
//| The live grid. One per symbol, ever.                             |
//|                                                                  |
//| INVARIANT: every placed level - pending or filled - carries      |
//| `sharedSL` as its stop loss, without exception. A level with a   |
//| different SL, or none, turns a bounded 1.5% risk into an         |
//| unbounded one. Re-verified on every management tick, not just    |
//| at placement, because a partial-close request can silently drop  |
//| the stop on some brokers.                                        |
//+------------------------------------------------------------------+
struct HTFZGGrid
  {
   ENUM_HTFZG_DIR    dir;
   HTFZGLevel        lv[HTFZG_MAX_LEVELS];
   int               count;         // levels actually planned: 2 or 3

   double            sharedSL;      // THE stop. Identical on every level.
   double            oneR;          // price distance Level 1 -> sharedSL
   double            tp1;           // 1R from Level 1
   double            tp2;           // 2R from Level 1
   double            avgEntry;      // volume-weighted, recomputed on each fill

   bool              tp1Done;
   datetime          opened;
   datetime          expiry;        // pendings die here (InpPendingExpiryHours)

   //--- snapshot of the signal that created it, for the close-out log line
   int               score;
   double            zHigh, zLow;
   double            sweepExtreme;

                     HTFZGGrid() { Reset(); }
   void              Reset()
     {
      dir=HTFZG_DIR_NONE; count=0; sharedSL=0; oneR=0; tp1=0; tp2=0; avgEntry=0;
      tp1Done=false; opened=0; expiry=0; score=0; zHigh=0; zLow=0; sweepExtreme=0;
      for(int i=0; i<HTFZG_MAX_LEVELS; i++)
         lv[i] = HTFZGLevel();
     }
   int               FilledCount() const
     {
      int n=0;
      for(int i=0; i<count; i++) if(lv[i].filled) n++;
      return n;
     }
  };

//+------------------------------------------------------------------+
//| Day-boundary risk accounting. Rolled over on the server date     |
//| changing, never on a timer, so a weekend gap cannot silently     |
//| clear a lockout.                                                 |
//+------------------------------------------------------------------+
struct HTFZGDayBook
  {
   datetime          day;           // server date this book covers
   double            startEquity;
   double            realisedPnL;
   int               gridsToday;
   datetime          cooldownUntil;
   bool              lockedOut;     // daily loss cap tripped - no new grids today

                     HTFZGDayBook() { day=0; startEquity=0; realisedPnL=0; gridsToday=0; cooldownUntil=0; lockedOut=false; }
  };
//+------------------------------------------------------------------+
