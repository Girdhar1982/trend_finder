//+------------------------------------------------------------------+
//|                                                   HTFZG_Grid.mqh |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+==================================================================+
//|                                                                  |
//| THE EXECUTION LAYER. Steps 9-12 of the spec: build the ladder,   |
//| size it, place it, manage it, tear it down.                      |
//|                                                                  |
//| It contains no signal logic. It is handed a scored HTFZGSignal   |
//| and its only judgement is geometric: do three levels FIT inside  |
//| this zone with a sane stop, and if not, what is the largest      |
//| ladder that does?                                                |
//|                                                                  |
//+==================================================================+
//|                                                                  |
//| INVARIANT 1 - ONE SHARED STOP, ALWAYS                            |
//| Every level carries grid.sharedSL. Not a per-level stop, not a   |
//| trailing stop, not "SL added after the fill". Re-verified on     |
//| every management tick against the broker and repaired if it      |
//| drifts, because a partial close can silently drop the stop on    |
//| some brokers. This is what makes total risk knowable in advance. |
//|                                                                  |
//| INVARIANT 2 - FIXED LOTS ACROSS LEVELS (spec conflict, resolved) |
//| The spec asks for two things that cannot both hold:              |
//|   "InpRiskPerLevel = 0.5%  per level"                            |
//|   "fixed lot per level (no multiplier)"                          |
//| Levels 2 and 3 sit CLOSER to the shared stop than Level 1, so    |
//| risking a flat 0.5% on each would require BIGGER lots the deeper |
//| the ladder goes. That is a martingale by shape even though it is |
//| not one by intent, and the spec bans lot escalation outright.    |
//|                                                                  |
//| RESOLUTION: size Level 1 at riskPerLevel over its own distance   |
//| to sharedSL, and use that SAME lot for every level. Deeper       |
//| levels then risk strictly LESS than 0.5% each, so worst case     |
//| total risk lands UNDER the 1.5% budget rather than over it, and  |
//| no lot ever increases. equalRisk = true exposes the literal      |
//| reading for anyone who wants to test it; the default is safe.    |
//|                                                                  |
//| INVARIANT 3 - TP1 CLOSES THE LADDER TO NEW FILLS                 |
//| The spec says TP1 closes 50% of the total position. If a pending |
//| level filled AFTER that partial, "50% of total" would be a       |
//| different, larger number than the half already banked, and the   |
//| remainder would no longer be at breakeven. So the moment TP1 is  |
//| taken, every unfilled pending is DELETED. The ladder is frozen   |
//| at whatever filled.                                              |
//|                                                                  |
//| INVARIANT 4 - R IS MEASURED FROM LEVEL 1, PARTIALS FROM AVERAGE  |
//| tp1/tp2 are fixed price levels derived from Level 1 at build     |
//| time (spec step 11: "2R based on Level1"), so they never move as |
//| levels fill. avgEntry is tracked separately and is what the      |
//| breakeven stop is computed from, because a stop at Level 1 would |
//| not be breakeven for a ladder that averaged down below it.       |
//|                                                                  |
//| INVARIANT 5 - A LEVEL IS NEVER NUDGED TO FIT                     |
//| A level outside the legal band drops the ladder to 2, or refuses |
//| the trade. It is never moved back inside. A level moved to fit   |
//| is a level the confluence never justified, and scale-in only     |
//| inside the zone is the entire premise.                           |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#include "HTFZG_Types.mqh"
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Execution tunables. Mirrors the EA inputs for the same reason    |
//| HTFZGCfg does - no globals reached from inside the module.       |
//+------------------------------------------------------------------+
struct HTFZGGridCfg
  {
   double            riskPerLevel;    // InpRiskPerLevel, percent of equity
   int               maxLevels;       // InpMaxGridLevels, clamped to HTFZG_MAX_LEVELS
   double            spacingATR;      // InpGridSpacingATR
   double            slBufferATR;     // InpSharedSL_ATR_Buffer
   double            tp1R;            // InpTP1_R
   double            tp2R;            // InpTP2_R
   double            deepestATR;      // InpDeepestLevelATR
   double            sweepBufferATR;  // InpSweepDepthATR - lower bound of the legal band
   double            entryTolATR;     // InpEntryTolATR - how far past the zone L1 may sit
   double            minRSpread;      // InpMinR_SpreadMult - 1R must be this x the spread
   int               expiryHours;     // InpPendingExpiryHours
   int               bePoints;        // InpBreakevenPoints
   bool              equalRisk;       // InpEqualRiskPerLevel - see INVARIANT 2
   long              magic;
   int               slippage;
  };

CTrade g_htfzgTrade;                  // configured once by HTFZG_TradeInit

//+------------------------------------------------------------------+
void HTFZG_TradeInit(const HTFZGGridCfg &cfg)
  {
   g_htfzgTrade.SetExpertMagicNumber(cfg.magic);
   g_htfzgTrade.SetDeviationInPoints(cfg.slippage);
   g_htfzgTrade.SetAsyncMode(false);
   g_htfzgTrade.LogLevel(1);
  }

//+------------------------------------------------------------------+
//| Normalise a price to the symbol tick size. Sending an            |
//| unnormalised price is the most common source of "invalid price"  |
//| rejections, and the level maths below produces raw ATR fractions |
//| by construction.                                                 |
//+------------------------------------------------------------------+
double HTFZG_NormPrice(const string sym, const double price)
  {
   const double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      return NormalizeDouble(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   return NormalizeDouble(MathRound(price / ts) * ts,
                          (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| STEP 9a - Shared stop from the sweep extreme.                    |
//|                                                                  |
//| Beyond the wick, not at it: the stop has to sit past the         |
//| liquidity that was just taken, or the next probe of the same     |
//| low takes the whole ladder out at once.                          |
//+------------------------------------------------------------------+
double HTFZG_SharedSL(const ENUM_HTFZG_DIR dir, const double sweepExtreme,
                      const double atr15, const HTFZGGridCfg &cfg)
  {
   const double buf = cfg.slBufferATR * atr15;
   return (dir == HTFZG_DIR_BUY ? sweepExtreme - buf : sweepExtreme + buf);
  }

//+------------------------------------------------------------------+
//| STEP 10a - Lot from risk. See INVARIANT 2 for which distance is  |
//| passed in.                                                       |
//|                                                                  |
//| Returns 0 when the broker minimum lot would already exceed the   |
//| risk budget: the correct answer is then "do not trade", never    |
//| "trade smaller than allowed" (impossible) and never "round up"   |
//| (silently doubles the risk on small accounts).                   |
//+------------------------------------------------------------------+
double HTFZG_LotForLevel(const string sym, const double entry, const double sl,
                         const double riskPct, const double equity)
  {
   const double dist = MathAbs(entry - sl);
   if(dist <= 0.0 || equity <= 0.0 || riskPct <= 0.0)
      return 0.0;

   const double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   const double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSz <= 0.0)
      return 0.0;

   const double lossPerLot = (dist / tickSz) * tickVal;
   if(lossPerLot <= 0.0)
      return 0.0;

   const double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   const double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lots = (equity * riskPct / 100.0) / lossPerLot;
   if(step > 0.0)
      lots = MathFloor(lots / step) * step;          // floor, never round
   lots = NormalizeDouble(lots, 2);

   if(lots < minLot) return 0.0;                     // cannot afford the minimum
   if(lots > maxLot) lots = maxLot;
   return lots;
  }

//+------------------------------------------------------------------+
//| STEP 9b - Build the ladder and validate it.                      |
//|                                                                  |
//|   Level 1 = signal.bosPrice (reclaim + break)                    |
//|   Level 2 = Level 1 -/+ spacingATR x ATR(15M)                    |
//|   Level 3 = Level 2 -/+ spacingATR x ATR(15M)                    |
//|                                                                  |
//| Legal band for the SCALE-IN levels:                              |
//|   BUY:  [zLow - sweepBufferATR x ATR , zHigh]                    |
//|   SELL: [zLow , zHigh + sweepBufferATR x ATR]                    |
//| and Level 3 may not be deeper than sweepExtreme -/+ deepestATR.  |
//|                                                                  |
//| Level 1 is judged differently on purpose. It is the market       |
//| entry, and a break-of-structure close routinely prints just      |
//| beyond the zone it broke out of - the spec's own worked example  |
//| has it one point inside, but that is not guaranteed. So L1 is    |
//| allowed entryTolATR past the far edge and rejected beyond that   |
//| (the entry chased too far), while L2 and L3 must be strictly     |
//| inside the band. That is what "scale-in inside the confluence    |
//| zone only" actually constrains.                                  |
//|                                                                  |
//| Fewer than 2 levels is a refusal, not a 1-level trade: a lone    |
//| market entry is a different strategy than the one specified.     |
//+------------------------------------------------------------------+
bool HTFZG_BuildGrid(const string sym, const HTFZGSignal &sig,
                     const HTFZGGridCfg &cfg, HTFZGGrid &g, string &why)
  {
   g.Reset();
   why = "";

   const bool   buy  = (sig.dir == HTFZG_DIR_BUY);
   const double sign = (buy ? 1.0 : -1.0);
   const double atr  = sig.atr15;
   if(atr <= 0.0)
     { why = "ATR zero"; return false; }

   //--- 9a. the stop, and therefore R
   const double sl = HTFZG_SharedSL(sig.dir, sig.sweepExtreme, atr, cfg);
   const double l1 = sig.bosPrice;
   const double oneR = MathAbs(l1 - sl);
   if(oneR <= 0.0)
     { why = "zero R"; return false; }

   //--- the entry must be on the correct side of its own stop
   if((buy && sl >= l1) || (!buy && sl <= l1))
     { why = "SL on the wrong side of L1"; return false; }

   //--- broker minimum stop distance - never clamp, always refuse
   const double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   const long   stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLvl > 0 && oneR < (double)stopLvl * point)
     { why = StringFormat("R (%.1f pts) inside broker stop level (%d)",
                          oneR / point, (int)stopLvl); return false; }

   //--- R MUST BE WORTH MORE THAN THE COST OF ENTERING.
   //--- An ATR-derived stop says nothing about what the spread costs, and on
   //--- a wide-spread symbol the two can invert completely: measured on
   //--- XRPUSD, the average 1R was 0.0149 against a 0.025 spread - the trade
   //--- paid 168% of its own risk just to open, and every configuration of
   //--- every other parameter lost money because of it. Nothing downstream
   //--- can recover that, so it is refused here.
   const double spreadPx = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * point;
   if(cfg.minRSpread > 0.0 && spreadPx > 0.0 && oneR < spreadPx * cfg.minRSpread)
     { why = StringFormat("R (%.1f pts) < %.1f x spread (%.0f pts)",
                          oneR / point, cfg.minRSpread, spreadPx / point);
       return false; }

   //--- legal band
   const double bandLo = (buy ? sig.zone.low  - cfg.sweepBufferATR * atr : sig.zone.low);
   const double bandHi = (buy ? sig.zone.high : sig.zone.high + cfg.sweepBufferATR * atr);
   const double deepest = (buy ? sig.sweepExtreme - cfg.deepestATR * atr
                               : sig.sweepExtreme + cfg.deepestATR * atr);

   //--- L1 tolerance past the far edge of the zone
   const double entryTol = cfg.entryTolATR * atr;
   if(buy  && l1 > sig.zone.high + entryTol)
     { why = "L1 chased above the zone"; return false; }
   if(!buy && l1 < sig.zone.low - entryTol)
     { why = "L1 chased below the zone"; return false; }

   //--- 9b. the ladder
   const int  want = MathMin(cfg.maxLevels, HTFZG_MAX_LEVELS);
   const double step = cfg.spacingATR * atr;
   if(step <= 0.0)
     { why = "zero grid spacing"; return false; }

   double price[HTFZG_MAX_LEVELS];
   price[0] = l1;
   for(int i = 1; i < HTFZG_MAX_LEVELS; i++)
      price[i] = price[i-1] - sign * step;

   //--- count how many scale-in levels survive the band (INVARIANT 5)
   int keep = 1;
   for(int i = 1; i < want; i++)
     {
      const double p = price[i];
      if(p < bandLo || p > bandHi)                       break;   // outside the zone
      if(buy  ? (p < deepest) : (p > deepest))           break;   // deeper than the sweep
      if(buy  ? (p <= sl)     : (p >= sl))               break;   // through the stop
      keep++;
     }

   if(keep < 2)
     { why = "zone too tight for a second level"; return false; }

   //--- 10a. lots (INVARIANT 2)
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lot1 = HTFZG_LotForLevel(sym, l1, sl, cfg.riskPerLevel, equity);
   if(lot1 <= 0.0)
     { why = "risk budget below the minimum lot"; return false; }

   //--- 11/INVARIANT 4. targets, from Level 1, fixed for the life of the grid
   g.dir      = sig.dir;
   g.count    = keep;
   g.sharedSL = HTFZG_NormPrice(sym, sl);
   g.oneR     = oneR;
   g.tp1      = HTFZG_NormPrice(sym, l1 + sign * oneR * cfg.tp1R);
   g.tp2      = HTFZG_NormPrice(sym, l1 + sign * oneR * cfg.tp2R);
   g.avgEntry = l1;

   for(int i = 0; i < keep; i++)
     {
      g.lv[i].price    = HTFZG_NormPrice(sym, price[i]);
      g.lv[i].isMarket = (i == 0);
      g.lv[i].lots     = (cfg.equalRisk
                          ? HTFZG_LotForLevel(sym, price[i], sl, cfg.riskPerLevel, equity)
                          : lot1);
      if(g.lv[i].lots <= 0.0)
        { why = "a level could not be sized"; return false; }
     }

   g.score        = sig.total;
   g.zHigh        = sig.zone.high;
   g.zLow         = sig.zone.low;
   g.sweepExtreme = sig.sweepExtreme;
   g.expiry       = (datetime)(TimeCurrent() + (long)cfg.expiryHours * 3600);
   return true;
  }

//+------------------------------------------------------------------+
//| STEP 10b - Place the ladder.                                     |
//|                                                                  |
//| Level 1 at market. Levels 2-3 as BUY LIMIT / SELL LIMIT with     |
//| ORDER_TIME_SPECIFIED expiry. Every ticket carries sharedSL and   |
//| tp2 (INVARIANT 1).                                               |
//|                                                                  |
//| If Level 1 fails, NOTHING else is placed. Pendings without their |
//| anchor are an unmanaged position waiting to happen.              |
//+------------------------------------------------------------------+
bool HTFZG_PlaceGrid(const string sym, const HTFZGGridCfg &cfg, HTFZGGrid &g)
  {
   const bool buy = (g.dir == HTFZG_DIR_BUY);

   //--- Level 1, at market
   const bool ok1 = (buy ? g_htfzgTrade.Buy (g.lv[0].lots, sym, 0.0, g.sharedSL, g.tp2, "HTFZG L1")
                         : g_htfzgTrade.Sell(g.lv[0].lots, sym, 0.0, g.sharedSL, g.tp2, "HTFZG L1"));
   if(!ok1)
     {
      PrintFormat("HTFZG: Level 1 rejected (%d %s) - grid abandoned, no pendings placed.",
                  g_htfzgTrade.ResultRetcode(), g_htfzgTrade.ResultRetcodeDescription());
      g.Reset();
      return false;
     }

   g.lv[0].ticket = g_htfzgTrade.ResultOrder();   // ORDER ticket, like the pendings -
                                                  // OnTradeTransaction matches on it
   g.lv[0].placed = true;
   g.lv[0].filled = true;
   if(g_htfzgTrade.ResultPrice() > 0.0)
      g.lv[0].price = g_htfzgTrade.ResultPrice();     // the REAL fill, not the plan
   g.avgEntry = g.lv[0].price;
   g.opened   = TimeCurrent();

   //--- Levels 2..N, as limits inside the zone
   for(int i = 1; i < g.count; i++)
     {
      const bool ok = (buy
         ? g_htfzgTrade.BuyLimit (g.lv[i].lots, g.lv[i].price, sym, g.sharedSL, g.tp2,
                                  ORDER_TIME_SPECIFIED, g.expiry, "HTFZG L" + IntegerToString(i+1))
         : g_htfzgTrade.SellLimit(g.lv[i].lots, g.lv[i].price, sym, g.sharedSL, g.tp2,
                                  ORDER_TIME_SPECIFIED, g.expiry, "HTFZG L" + IntegerToString(i+1)));
      if(ok)
        {
         g.lv[i].ticket = g_htfzgTrade.ResultOrder();
         g.lv[i].placed = true;
        }
      else
         PrintFormat("HTFZG: Level %d limit rejected (%d %s) - continuing with %d levels.",
                     i + 1, g_htfzgTrade.ResultRetcode(),
                     g_htfzgTrade.ResultRetcodeDescription(), i);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Are any of OUR orders/positions still on this symbol?            |
//|                                                                  |
//| The truth comes from the terminal, not from the struct - a       |
//| stop-out, a TP or a manual close leaves g stale until this says  |
//| otherwise. This is what enforces one grid per symbol.            |
//+------------------------------------------------------------------+
bool HTFZG_GridExists(const string sym, const long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym
      && PositionGetInteger(POSITION_MAGIC)  == magic)
         return true;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym
      && OrderGetInteger(ORDER_MAGIC)  == magic)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Total live volume and volume-weighted average entry of our legs. |
//+------------------------------------------------------------------+
void HTFZG_LiveBook(const string sym, const long magic, double &volume, double &avgEntry)
  {
   volume   = 0.0;
   avgEntry = 0.0;
   double notional = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)      continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic)   continue;

      const double v = PositionGetDouble(POSITION_VOLUME);
      notional += PositionGetDouble(POSITION_PRICE_OPEN) * v;
      volume   += v;
     }
   if(volume > 0.0)
      avgEntry = notional / volume;
  }

//+------------------------------------------------------------------+
//| Re-assert the shared stop on every leg (INVARIANT 1) and pull    |
//| the TP up to date. Called on every management tick, not just at  |
//| placement.                                                       |
//+------------------------------------------------------------------+
void HTFZG_EnforceStops(const string sym, const HTFZGGridCfg &cfg,
                        const double sl, const double tp)
  {
   const int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != cfg.magic) continue;

      const double curSL = NormalizeDouble(PositionGetDouble(POSITION_SL), digits);
      const double curTP = NormalizeDouble(PositionGetDouble(POSITION_TP), digits);
      const double wantSL = NormalizeDouble(sl, digits);
      const double wantTP = NormalizeDouble(tp, digits);

      if(MathAbs(curSL - wantSL) > 0.0 || MathAbs(curTP - wantTP) > 0.0)
         if(!g_htfzgTrade.PositionModify(t, wantSL, wantTP))
            PrintFormat("HTFZG: could not re-assert SL on #%I64u (%d %s)",
                        t, g_htfzgTrade.ResultRetcode(),
                        g_htfzgTrade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Delete every pending order of ours. Used by the expiry sweep,    |
//| by the TP1 freeze (INVARIANT 3) and by the teardown.             |
//+------------------------------------------------------------------+
int HTFZG_DeletePendings(const string sym, const long magic)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym)   continue;
      if(OrderGetInteger(ORDER_MAGIC)  != magic) continue;
      if(g_htfzgTrade.OrderDelete(t))
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Close half of the total live volume, proportionally across legs. |
//|                                                                  |
//| A leg whose half falls below the broker minimum is LEFT ALONE    |
//| rather than closed whole: closing it whole would exit more than  |
//| the 50% intended and forfeit its share of TP2. On a one-leg      |
//| minimum-lot grid that means no partial is possible at all - the  |
//| stop still moves to breakeven, and the shortfall is logged       |
//| rather than silently absorbed.                                   |
//+------------------------------------------------------------------+
double HTFZG_ClosePartialHalf(const string sym, const long magic)
  {
   const double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   const double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double closed = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)  continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic) continue;

      const double vol = PositionGetDouble(POSITION_VOLUME);
      double half = vol * 0.5;
      if(step > 0.0)
         half = MathFloor(half / step) * step;
      half = NormalizeDouble(half, 2);

      //--- must leave a tradeable remainder behind as well
      if(half < minLot || (vol - half) < minLot)
        {
         PrintFormat("HTFZG: leg #%I64u (%.2f lots) cannot be halved at this "
                     "broker minimum (%.2f) - left whole, stop still moves to BE.",
                     t, vol, minLot);
         continue;
        }

      if(g_htfzgTrade.PositionClosePartial(t, half))
         closed += half;
      else
         PrintFormat("HTFZG: partial close failed on #%I64u (%d %s)",
                     t, g_htfzgTrade.ResultRetcode(),
                     g_htfzgTrade.ResultRetcodeDescription());
     }
   return closed;
  }

//+------------------------------------------------------------------+
//| STEP 11 - Per-tick management. Called while ACTIVE or PARTIAL.   |
//|                                                                  |
//|   1. Reconcile fills, recompute avgEntry, re-assert sharedSL.    |
//|   2. Expire pendings past g.expiry.                              |
//|   3. TP1 once: close 50%, delete remaining pendings, move the    |
//|      stop to avgEntry +/- bePoints, state -> PARTIAL.            |
//|   4. Nothing else. No trailing - TP2 and sharedSL do the rest.   |
//|                                                                  |
//| Returns true while the grid still exists.                        |
//+------------------------------------------------------------------+
bool HTFZG_Manage(const string sym, const HTFZGGridCfg &cfg, HTFZGGrid &g,
                  ENUM_HTFZG_STATE &state)
  {
   if(!HTFZG_GridExists(sym, cfg.magic))
      return false;                                   // stopped out, TP'd, or closed by hand

   //--- 1. reconcile
   double vol = 0.0, avg = 0.0;
   HTFZG_LiveBook(sym, cfg.magic, vol, avg);
   if(vol > 0.0)
      g.avgEntry = avg;

   //--- A pending that has left the active book either FILLED or was DELETED
   //--- (expired, or killed by the TP1 freeze). Those are opposite outcomes
   //--- and only history separates them. Assuming "filled" makes both the
   //--- dashboard and the close-out log overstate the ladder that actually
   //--- traded - which is exactly the number a post-mortem depends on.
   for(int i = 0; i < g.count; i++)
     {
      if(!g.lv[i].placed || g.lv[i].filled) continue;
      if(OrderSelect(g.lv[i].ticket))       continue;      // still resting
      if(HistoryOrderSelect(g.lv[i].ticket)
      && (ENUM_ORDER_STATE)HistoryOrderGetInteger(g.lv[i].ticket, ORDER_STATE)
         == ORDER_STATE_FILLED)
         g.lv[i].filled = true;
      else
         g.lv[i].placed = false;                           // deleted, never filled
     }

   const double wantSL = (g.tp1Done
      ? HTFZG_NormPrice(sym, g.avgEntry + (g.dir == HTFZG_DIR_BUY ? 1.0 : -1.0)
                              * cfg.bePoints * SymbolInfoDouble(sym, SYMBOL_POINT))
      : g.sharedSL);
   HTFZG_EnforceStops(sym, cfg, wantSL, g.tp2);

   //--- 2. expiry (the broker honours ORDER_TIME_SPECIFIED, but not every
   //---    broker does, and an orphaned limit is exactly what must not survive)
   if(!g.tp1Done && TimeCurrent() >= g.expiry)
     {
      const int n = HTFZG_DeletePendings(sym, cfg.magic);
      if(n > 0)
         PrintFormat("HTFZG: %d unfilled level(s) expired after %dh.", n, cfg.expiryHours);
     }

   //--- 3. TP1, exactly once
   if(!g.tp1Done && vol > 0.0)
     {
      const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      const bool hit = (g.dir == HTFZG_DIR_BUY ? bid >= g.tp1 : ask <= g.tp1);
      if(hit)
        {
         const int killed = HTFZG_DeletePendings(sym, cfg.magic);   // INVARIANT 3
         const double cut = HTFZG_ClosePartialHalf(sym, cfg.magic);

         HTFZG_LiveBook(sym, cfg.magic, vol, avg);
         if(vol > 0.0)
            g.avgEntry = avg;

         const double be = HTFZG_NormPrice(sym,
            g.avgEntry + (g.dir == HTFZG_DIR_BUY ? 1.0 : -1.0)
                       * cfg.bePoints * SymbolInfoDouble(sym, SYMBOL_POINT));
         HTFZG_EnforceStops(sym, cfg, be, g.tp2);

         g.tp1Done = true;
         state     = HTFZG_PARTIAL;
         PrintFormat("HTFZG: TP1 at %.5f - closed %.2f lots, deleted %d pending, "
                     "stop to breakeven %.5f, %.2f lots run to TP2 %.5f.",
                     g.tp1, cut, killed, be, vol, g.tp2);
        }
     }

   return HTFZG_GridExists(sym, cfg.magic);
  }

//+------------------------------------------------------------------+
//| STEP 12 - Teardown: daily loss cap tripped, or H4 direction      |
//| went neutral/opposite.                                           |
//|                                                                  |
//| `pendingOnly` is the direction-change case: the spec deletes     |
//| unfilled levels but leaves filled ones to their shared stop,     |
//| because a filled leg already has bounded risk and closing it on  |
//| an H4 flicker is how a good entry gets thrown away. The daily    |
//| loss cap passes false and closes everything.                     |
//+------------------------------------------------------------------+
void HTFZG_CloseAll(const string sym, const HTFZGGridCfg &cfg, HTFZGGrid &g,
                    const bool pendingOnly)
  {
   const int n = HTFZG_DeletePendings(sym, cfg.magic);
   if(pendingOnly)
     {
      if(n > 0)
         PrintFormat("HTFZG: HTF direction changed - %d unfilled level(s) deleted, "
                     "filled legs left to the shared stop %.5f.", n, g.sharedSL);
      for(int i = 0; i < g.count; i++)
         if(!g.lv[i].filled)
            g.lv[i].placed = false;
      return;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)  continue;
      if(PositionGetInteger(POSITION_MAGIC)  != cfg.magic) continue;
      if(!g_htfzgTrade.PositionClose(t))
         PrintFormat("HTFZG: emergency close failed on #%I64u (%d %s)",
                     t, g_htfzgTrade.ResultRetcode(),
                     g_htfzgTrade.ResultRetcodeDescription());
     }
   PrintFormat("HTFZG: full teardown - %d pending deleted, all positions closed.", n);
  }
//+------------------------------------------------------------------+
