//+------------------------------------------------------------------+
//|                                       HullTrendTelegramRelay.mq5 |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Relays HullTrend_MT5 reversal signals to Telegram.                |
//|                                                                   |
//| WHY THIS EXISTS: WebRequest() is prohibited in indicators, so the  |
//| indicator cannot send to Telegram itself no matter how the         |
//| terminal is configured. HullTrend_MT5 publishes every reversal to  |
//| a global variable and this EA - where WebRequest is legal -        |
//| forwards it. Publishing is unconditional on the indicator side:    |
//| there is no switch that can be left off by accident.               |
//|                                                                   |
//| ONE instance does the sending, and that is ENFORCED, not merely    |
//| documented: instances elect an owner through the HT_RELAY_LOCK     |
//| global variable and the rest sit passive. Attaching it to several  |
//| charts is therefore harmless. If the owning chart is closed, a     |
//| passive instance takes over within a few polls.                    |
//|                                                                   |
//| The relay serves EVERY symbol and timeframe, not just its own      |
//| chart, so all market data is read for the SIGNAL's symbol and      |
//| timeframe - never from _Symbol / _Period.                          |
//|                                                                   |
//| Attach it once - MT5 restores it on the chart after a restart, so  |
//| the relay stays up permanently without further action.            |
//|                                                                   |
//| Setup:                                                            |
//|   1. MQL5\Files\telegram.ini  - token + chat_id                    |
//|   2. Tools > Options > Expert Advisors > Allow WebRequest,         |
//|      add https://api.telegram.org                                  |
//|   3. Allow Algo Trading, attach this EA to any one chart           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.60"
#property description "Forwards HullTrend reversal signals to Telegram"
#property description "with live price, market context and open positions."

#include "Telegram.mqh"

//--- the indicator writes these; keep in step with RelayVarName()
#define RELAY_PREFIX  "HT_SIG_"
#define ACK_PREFIX    "HT_ACK_"

//--- ownership heartbeat and the last startup announcement, both global
//--- so they survive the OnInit/OnDeinit churn of a chart being edited
#define OWNER_PREFIX  "HT_RELAY_OWN_"
#define HELLO_VAR     "HT_RELAY_HELLO"

//--- bars pulled for the true-range average: 14 periods needs 15 bars
#define ATR_BARS      15

input group                 "Relay"
input int    InpPollSeconds   = 5;     // Poll interval (seconds)
input bool   InpSendOnAttach  = false; // Send whatever signal is already standing on attach
input bool   InpSendStartup   = false; // Send a "relay online" message (throttled; off by default)
input int    InpHelloCooldown = 900;   // Min seconds between "relay online" messages

//--- config may be wrong at attach; the EA stays alive and keeps retrying
bool g_ready      = false;
int  g_retryTicks = 0;
//--- only the owning instance sends; the others idle
bool g_owner      = false;

//+------------------------------------------------------------------+
int PollSeconds()
  {
   return (InpPollSeconds > 0 ? InpPollSeconds : 5);
  }

//+------------------------------------------------------------------+
//| Acknowledgement variable paired with a signal variable            |
//+------------------------------------------------------------------+
string AckNameFor(const string sigName)
  {
   return ACK_PREFIX + StringSubstr(sigName, StringLen(RELAY_PREFIX));
  }

//+------------------------------------------------------------------+
//| Same transform the indicator uses, so the two cannot drift        |
//+------------------------------------------------------------------+
string PeriodToString(const ENUM_TIMEFRAMES periodVal)
  {
   string name = EnumToString(periodVal);
   if(StringSubstr(name, 0, 7) == "PERIOD_")
      name = StringSubstr(name, 7);
   return name;
  }

//+------------------------------------------------------------------+
//| "M15" -> PERIOD_M15, by asking PeriodToString rather than keeping |
//| a hand-written table that could disagree with the indicator.      |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES TimeframeFromName(const string name)
  {
   static ENUM_TIMEFRAMES all[] =
     {
      PERIOD_M1,  PERIOD_M2,  PERIOD_M3,  PERIOD_M4,  PERIOD_M5,  PERIOD_M6,
      PERIOD_M10, PERIOD_M12, PERIOD_M15, PERIOD_M20, PERIOD_M30,
      PERIOD_H1,  PERIOD_H2,  PERIOD_H3,  PERIOD_H4,  PERIOD_H6,
      PERIOD_H8,  PERIOD_H12, PERIOD_D1,  PERIOD_W1,  PERIOD_MN1
     };

   for(int i = 0; i < ArraySize(all); i++)
      if(PeriodToString(all[i]) == name)
         return all[i];

   return PERIOD_CURRENT;
  }

//+------------------------------------------------------------------+
//| Split "HT_SIG_TREND_EURUSD_M15" into kind, symbol and timeframe.  |
//|                                                                   |
//| The kind never contains '_' and the timeframe never does, but a   |
//| SYMBOL may - so take the kind from the FIRST separator and the    |
//| timeframe from the LAST, leaving whatever is between as the       |
//| symbol. Must mirror HullTrendRelay.mqh.                            |
//+------------------------------------------------------------------+
bool KnownKind(const string k)
  {
   return (k == "TREND" || k == "SR" || k == "LG" || k == "BO" || k == "FVG");
  }

bool SplitSlot(const string sigName, string &kind, string &sym,
               ENUM_TIMEFRAMES &tf)
  {
   const string body = StringSubstr(sigName, StringLen(RELAY_PREFIX));

   const int first = StringFind(body, "_");
   if(first <= 0)
      return false;

   int last = -1, at = 0;
   while((at = StringFind(body, "_", at)) >= 0)
     {
      last = at;
      at++;
     }
   if(last <= first)
      return false;                    // no room for a symbol between them

   kind = StringSubstr(body, 0, first);
   sym  = StringSubstr(body, first + 1, last - first - 1);
   tf   = TimeframeFromName(StringSubstr(body, last + 1));

   return (KnownKind(kind) && tf != PERIOD_CURRENT && sym != "");
  }

//+------------------------------------------------------------------+
//| What this kind of event is called, in the two directions          |
//+------------------------------------------------------------------+
string EventLabel(const string kind, const bool bullish)
  {
   if(kind == "SR")
      return (bullish ? "Resistance BREAK up" : "Support BREAK down");
   if(kind == "LG")
      return (bullish ? "BULLISH liquidity grab" : "BEARISH liquidity grab");
   if(kind == "BO")
      return (bullish ? "UPSIDE breakout" : "DOWNSIDE breakout");
   if(kind == "FVG")
      return (bullish ? "LONG setup (FVG)" : "SHORT setup (FVG)");

   return (bullish ? "BULLISH reversal" : "BEARISH reversal");
  }

//+------------------------------------------------------------------+
//| "HT_SIG_TREND_EURUSD_M15" -> "EURUSD M15" for the headline        |
//+------------------------------------------------------------------+
string DescribeSlot(const string sigName)
  {
   string          kind, sym;
   ENUM_TIMEFRAMES tf;
   if(!SplitSlot(sigName, kind, sym, tf))
      return StringSubstr(sigName, StringLen(RELAY_PREFIX));

   return sym + " " + PeriodToString(tf);
  }

//+------------------------------------------------------------------+
//| Market context for one signal.                                    |
//|                                                                   |
//| Every part is optional and flagged: a symbol that is not in       |
//| Market Watch, or one whose history has not downloaded, answers     |
//| nothing - and a message carrying fewer numbers is far better than  |
//| no message at all. Nothing here may fail the send.                 |
//+------------------------------------------------------------------+
struct AssetSnapshot
  {
   bool   havePrice;
   bool   haveSignal;
   bool   haveATR;
   bool   haveDay;
   int    digits;
   double point;
   double bid;
   double ask;
   double spreadPts;
   double signalClose;
   double movedPts;
   double movedATR;
   double atr;
   double dayOpen;
   double dayHigh;
   double dayLow;
   double dayChangePct;
   double rangePos;
  };

//+------------------------------------------------------------------+
void BuildSnapshot(const string sym, const ENUM_TIMEFRAMES tf,
                   const datetime barTime, AssetSnapshot &s)
  {
   ZeroMemory(s);

   //--- the signal may name a symbol this chart never selected
   if(!SymbolSelect(sym, true))
      return;

   s.digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   s.point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   s.bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   s.ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

   if(s.bid > 0.0 && s.point > 0.0)
     {
      s.havePrice = true;
      s.spreadPts = (s.ask - s.bid) / s.point;
     }

   //--- close of the bar the reversal actually fired on
   MqlRates sig[];
   if(CopyRates(sym, tf, barTime, barTime, sig) == 1)
     {
      s.haveSignal  = true;
      s.signalClose = sig[0].close;
      if(s.havePrice)
         s.movedPts = (s.bid - s.signalClose) / s.point;
     }

   //--- ATR from raw rates rather than an iATR handle: a freshly created
   //--- indicator handle is not calculated yet, so CopyBuffer right after
   //--- it would return nothing. This runs once per signal, so there is
   //--- nothing to gain from caching a handle either.
   MqlRates bars[];
   if(CopyRates(sym, tf, 0, ATR_BARS, bars) == ATR_BARS)
     {
      double sum = 0.0;
      for(int i = 1; i < ATR_BARS; i++)
        {
         const double hl = bars[i].high - bars[i].low;
         const double hc = MathAbs(bars[i].high - bars[i - 1].close);
         const double lc = MathAbs(bars[i].low  - bars[i - 1].close);
         sum += MathMax(hl, MathMax(hc, lc));
        }
      s.atr     = sum / (ATR_BARS - 1);
      s.haveATR = (s.atr > 0.0);

      if(s.haveATR && s.haveSignal && s.havePrice)
         s.movedATR = (s.bid - s.signalClose) / s.atr;
     }

   //--- where today sits: change from the open and position in the range
   MqlRates day[];
   if(CopyRates(sym, PERIOD_D1, 0, 1, day) == 1 && day[0].open > 0.0)
     {
      s.haveDay  = true;
      s.dayOpen  = day[0].open;
      s.dayHigh  = day[0].high;
      s.dayLow   = day[0].low;

      if(s.havePrice)
        {
         s.dayChangePct = (s.bid - s.dayOpen) / s.dayOpen * 100.0;
         const double rng = s.dayHigh - s.dayLow;
         s.rangePos = (rng > 0.0 ? (s.bid - s.dayLow) / rng * 100.0 : 0.0);
        }
     }
  }

//+------------------------------------------------------------------+
//| Render the snapshot as an aligned block. Empty when there is      |
//| nothing to say, so the caller can simply omit it.                 |
//+------------------------------------------------------------------+
string FormatSnapshot(const AssetSnapshot &s)
  {
   if(!s.havePrice)
      return "";

   const int d = s.digits;
   string t = "Now      " + DoubleToString(s.bid, d);

   if(s.haveSignal)
     {
      t += "\nSignal   " + DoubleToString(s.signalClose, d);
      t += StringFormat("\nMoved    %+.1f pts", s.movedPts);
      if(s.haveATR)
         t += StringFormat(" (%+.2f ATR)", s.movedATR);
     }

   t += StringFormat("\nSpread   %.1f pts", s.spreadPts);

   if(s.haveATR)
      t += "\nATR(14)  " + DoubleToString(s.atr, d);

   if(s.haveDay)
     {
      t += StringFormat("\nDay      %+.2f%%", s.dayChangePct);
      t += "\nRange    " + DoubleToString(s.dayLow, d)
           + " - " + DoubleToString(s.dayHigh, d);
      t += StringFormat("\nAt       %.0f%% of range", s.rangePos);
     }

   return t;
  }

//+------------------------------------------------------------------+
//| Open positions, for the signal's symbol and for the account.      |
//|                                                                   |
//| The reason this is in the alert at all is the conflict check: a   |
//| reversal firing AGAINST something you are already holding is the  |
//| one case where you need to look immediately. Both hedging and     |
//| netting accounts are handled by aggregating each side separately  |
//| rather than assuming one position per symbol.                     |
//+------------------------------------------------------------------+
struct PositionSnapshot
  {
   bool   haveSym;
   int    countSym;
   int    countAll;
   double volBuy;
   double volSell;
   double avgBuy;
   double avgSell;
   double profitSym;
   double profitAll;
  };

//+------------------------------------------------------------------+
void BuildPositions(const string sym, PositionSnapshot &p)
  {
   ZeroMemory(p);

   double buyWeighted = 0.0, sellWeighted = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      //--- PositionGetTicket also SELECTS the position for the getters
      if(PositionGetTicket(i) == 0)
         continue;

      p.countAll++;
      p.profitAll += PositionGetDouble(POSITION_PROFIT);

      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;

      p.countSym++;
      p.profitSym += PositionGetDouble(POSITION_PROFIT);

      const double vol  = PositionGetDouble(POSITION_VOLUME);
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         p.volBuy     += vol;
         buyWeighted  += open * vol;
        }
      else
        {
         p.volSell    += vol;
         sellWeighted += open * vol;
        }
     }

   if(p.volBuy > 0.0)
      p.avgBuy = buyWeighted / p.volBuy;
   if(p.volSell > 0.0)
      p.avgSell = sellWeighted / p.volSell;

   p.haveSym = (p.countSym > 0);
  }

//+------------------------------------------------------------------+
string FormatPositions(const string sym, const bool bullish,
                       const PositionSnapshot &p, const int digitsIn)
  {
   const string cur = AccountInfoString(ACCOUNT_CURRENCY);

   //--- digitsIn is 0 when the market snapshot could not resolve the
   //--- symbol; fall back rather than print entry prices as integers
   int digits = digitsIn;
   if(digits <= 0)
      digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(digits <= 0)
      digits = 5;
   string t = "";

   if(!p.haveSym)
      t += "Position no open " + sym;
   else
     {
      if(p.volBuy > 0.0)
         t += StringFormat("Long     %.2f @ %s", p.volBuy,
                           DoubleToString(p.avgBuy, digits));
      if(p.volSell > 0.0)
        {
         if(p.volBuy > 0.0)
            t += "\n";
         t += StringFormat("Short    %.2f @ %s", p.volSell,
                           DoubleToString(p.avgSell, digits));
        }
      t += StringFormat("\nP/L      %+.2f %s", p.profitSym, cur);

      //--- the whole reason this block exists
      const double net = p.volBuy - p.volSell;
      if(net > 0.0 && !bullish)
         t += "\nWARNING  bearish signal AGAINST your open LONG";
      else
         if(net < 0.0 && bullish)
            t += "\nWARNING  bullish signal AGAINST your open SHORT";
         else
            if(net > 0.0 && bullish)
               t += "\nSignal   agrees with your open LONG";
            else
               if(net < 0.0 && !bullish)
                  t += "\nSignal   agrees with your open SHORT";
     }

   t += StringFormat("\nAccount  %d open, floating %+.2f %s",
                     p.countAll, p.profitAll, cur);
   return t;
  }

//+------------------------------------------------------------------+
//| Ownership: exactly one instance may send.                         |
//|                                                                   |
//| Each instance stamps a heartbeat named after its own chart, and    |
//| the owner is the lowest chart id still beating. A stale stamp means |
//| that chart is gone, so its entry is cleaned up and the next lowest  |
//| instance takes over on its next tick.                               |
//+------------------------------------------------------------------+
string MyOwnerVar()
  {
   return OWNER_PREFIX + IntegerToString(ChartID());
  }

//--- Every instance stamps its OWN variable, and the owner is simply the
//--- lowest chart id still beating. Nothing is claimed, so there is no
//--- race, and an instance can only ever delete its own name - which is
//--- what the single shared lock got wrong: one chart's removal released
//--- the lock another chart was holding, and then everybody elected
//--- itself and every reversal was sent once per chart.
void Heartbeat()
  {
   GlobalVariableSet(MyOwnerVar(), (double)TimeLocal());
  }

bool AmTheOwner()
  {
   const int    stale = (3 * PollSeconds() > 20 ? 3 * PollSeconds() : 20);
   const long   me    = ChartID();
   const string mine  = MyOwnerVar();
   long         best  = me;

   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      const string name = GlobalVariableName(i);
      if(StringFind(name, OWNER_PREFIX) != 0 || name == mine)
         continue;

      if((TimeLocal() - (datetime)GlobalVariableGet(name)) >= stale)
        {
         GlobalVariableDel(name);      // that chart is gone
         continue;
        }

      const long other = StringToInteger(StringSubstr(name, StringLen(OWNER_PREFIX)));
      if(other < best)
         best = other;
     }

   return (best == me);
  }

//+------------------------------------------------------------------+
//| Seed every ack to the current signal WITHOUT sending.             |
//| Without this an attach would replay whatever flip happened to be  |
//| standing, which for an old chart could be days stale.             |
//+------------------------------------------------------------------+
void SeedAcks()
  {
   int seeded = 0;
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      const string name = GlobalVariableName(i);
      if(StringFind(name, RELAY_PREFIX) != 0)
         continue;

      //--- ONLY slots never seen before. Re-seeding every slot on every
      //--- attach acknowledged signals that had not been sent yet, so a
      //--- reversal firing while the EA was being re-added was silently
      //--- swallowed - which is exactly when alerts went missing.
      const string ack = AckNameFor(name);
      if(GlobalVariableCheck(ack))
         continue;

      GlobalVariableSet(ack, GlobalVariableGet(name));
      seeded++;
     }
   PrintFormat("Relay: seeded %d NEW signal slot(s); existing marks kept.", seeded);
  }

//+------------------------------------------------------------------+
//| Announce, but at most once per InpHelloCooldown seconds.          |
//| Editing a chart re-runs OnInit, and without this throttle every    |
//| such re-init put another "relay online" message in the chat.       |
//+------------------------------------------------------------------+
void SayHello()
  {
   if(!InpSendStartup)
      return;

   const datetime now  = TimeLocal();
   const int      cool = (InpHelloCooldown > 0 ? InpHelloCooldown : 900);

   if(GlobalVariableCheck(HELLO_VAR)
      && (now - (datetime)GlobalVariableGet(HELLO_VAR)) < cool)
     {
      Print("Relay: startup message suppressed - one was already sent recently.");
      return;
     }

   if(TelegramSend("HullTrend relay online on " + AccountInfoString(ACCOUNT_SERVER)))
      GlobalVariableSet(HELLO_VAR, (double)now);
   else
      Print("Relay: startup message failed - see the error above. "
            "Signals will still be attempted.");
  }

//+------------------------------------------------------------------+
//| Forward anything whose signal differs from its acknowledgement    |
//+------------------------------------------------------------------+
void PollOnce()
  {
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      const string name = GlobalVariableName(i);
      if(StringFind(name, RELAY_PREFIX) != 0)
         continue;

      const double sig = GlobalVariableGet(name);
      if(sig == 0.0)
         continue;

      const string ack = AckNameFor(name);
      if(GlobalVariableCheck(ack) && GlobalVariableGet(ack) == sig)
         continue;                      // already relayed

      //--- sign is the direction, magnitude is the signal bar time
      const bool     bullish = (sig > 0);
      const datetime barTime = (datetime)MathAbs(sig);

      //--- A slot that will not parse is a leftover from an older build,
      //--- whose names carried no kind. Drop it rather than send a message
      //--- with no context, and it will not come back.
      string          kind, sym;
      ENUM_TIMEFRAMES tf;
      if(!SplitSlot(name, kind, sym, tf))
        {
         PrintFormat("Relay: discarding unrecognised slot %s", name);
         GlobalVariableDel(name);
         GlobalVariableDel(ack);
         continue;
        }

      //--- plain ASCII on purpose: MQL5 string literals are UTF-16, so a
      //--- \x byte escape cannot spell a UTF-8 emoji. HTML bold is enough.
      string text = StringFormat("<b>%s</b>\n%s\nBar: %s",
                                 TgHtmlEscape(EventLabel(kind, bullish)),
                                 TgHtmlEscape(DescribeSlot(name)),
                                 TimeToString(barTime, TIME_DATE | TIME_MINUTES));

      //--- market context and exposure, both for the SIGNAL's symbol
      //--- rather than this chart's; kind, sym and tf resolved above
        {
         AssetSnapshot snap;
         BuildSnapshot(sym, tf, barTime, snap);

         string block = FormatSnapshot(snap);

         PositionSnapshot pos;
         BuildPositions(sym, pos);
         const string posBlock = FormatPositions(sym, bullish, pos, snap.digits);

         if(block != "" && posBlock != "")
            block += "\n\n" + posBlock;
         else
            if(posBlock != "")
               block = posBlock;
         if(block != "")
            text += "\n<pre>" + TgHtmlEscape(block) + "</pre>";
        }

      //--- only acknowledge a send that actually landed, so a transient
      //--- network failure retries on the next poll instead of vanishing
      if(TelegramSend(text))
        {
         GlobalVariableSet(ack, sig);
         PrintFormat("Relay: sent %s - %s", DescribeSlot(name),
                     EventLabel(kind, bullish));
        }
     }
  }

//+------------------------------------------------------------------+
//| Re-elect on every tick, and act only on a change of role          |
//+------------------------------------------------------------------+
void UpdateOwnership()
  {
   Heartbeat();
   const bool nowOwner = AmTheOwner();

   if(nowOwner && !g_owner)
     {
      g_owner = true;
      if(!InpSendOnAttach)
         SeedAcks();
      SayHello();
      Print("Relay: live - this chart is the sending instance.");
     }
   else
      if(!nowOwner && g_owner)
        {
         g_owner = false;
         Print("Relay: passive - a chart with a lower id is sending.");
        }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(PollSeconds());

   //--- A bad telegram.ini must NOT detach the EA. Returning INIT_FAILED
   //--- would drop it off the chart and force a manual re-attach after
   //--- every typo; instead stay resident and re-read the file until it
   //--- is valid, so correcting the file alone brings the relay up.
   if(!TelegramLoadConfig())
     {
      Print("Relay: config not usable yet - see the reason above. Staying "
            "attached and re-reading the config every minute.");
      return INIT_SUCCEEDED;
     }
   g_ready = true;

   UpdateOwnership();
   if(!g_owner)
      Print("Relay: passive - another chart is sending. That is fine; this "
            "one takes over automatically if that chart is closed.");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

   //--- Only ever remove our OWN heartbeat, so a passive instance can take
   //--- over at once instead of waiting for it to go stale. The previous
   //--- version deleted a single shared lock whenever it thought it was the
   //--- owner, which released a lock some other chart was holding.
   if(reason != REASON_RECOMPILE)
      GlobalVariableDel(MyOwnerVar());
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!g_ready)
     {
      //--- retry about once a minute rather than every tick, so a broken
      //--- config does not flood the Experts log
      if(++g_retryTicks * PollSeconds() < 60)
         return;
      g_retryTicks = 0;

      if(!TelegramLoadConfig())
         return;
      g_ready = true;
     }

   UpdateOwnership();
   if(!g_owner)
      return;                           // another chart is doing the work

   PollOnce();
  }
//+------------------------------------------------------------------+
