//+------------------------------------------------------------------+
//|                                                 HullTrendRelay.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| The publish half of the Telegram bridge, shared by every HullTrend |
//| indicator so the five of them cannot drift apart.                  |
//|                                                                   |
//| WebRequest() is prohibited in indicators, so an indicator can      |
//| never send to Telegram itself. It publishes a global variable and  |
//| HullTrendTelegramRelay.mq5 - an EA, where WebRequest is legal -    |
//| forwards it. See §10.1 of HullTrend_Documentation.md.              |
//|                                                                   |
//| SLOT NAME:  HT_SIG_<KIND>_<SYMBOL>_<TF>                            |
//|   KIND must not contain '_' - the relay splits on the FIRST '_'    |
//|   for the kind and the LAST for the timeframe, because a symbol    |
//|   may legitimately contain one in the middle.                      |
//|                                                                   |
//| SLOT VALUE: the signal bar time, signed. Positive is bullish,      |
//|   negative bearish. One double carries both facts, and the         |
//|   magnitude is what lets the relay tell a new event from a repeat. |
//|                                                                   |
//| Publishing is UNCONDITIONAL by design. A GlobalVariableSet is      |
//| nearly free and inert when no relay is running, so gating it       |
//| behind an input would only create a way to miss alerts silently.   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#define HT_RELAY_PREFIX  "HT_SIG_"

//--- keep in step with the relay's KnownKind()
#define HT_KIND_TREND    "TREND"
#define HT_KIND_SR       "SR"
#define HT_KIND_LG       "LG"
#define HT_KIND_BO       "BO"
#define HT_KIND_FVG      "FVG"

//+------------------------------------------------------------------+
//| Readable timeframe name, e.g. PERIOD_H1 -> H1. Duplicated in the  |
//| relay, which reverses it - both sides derive from EnumToString so |
//| neither can invent a name the other does not recognise.           |
//+------------------------------------------------------------------+
string HTRelayTFName(const ENUM_TIMEFRAMES periodVal)
  {
   string name = EnumToString(periodVal);
   if(StringSubstr(name, 0, 7) == "PERIOD_")
      name = StringSubstr(name, 7);
   return name;
  }

//+------------------------------------------------------------------+
//| Publish one event for the relay to forward.                       |
//|                                                                   |
//| tf is the timeframe the event was DETECTED on, which is not       |
//| always the chart's: the breakout and FVG indicators analyse a     |
//| timeframe of their own choosing.                                   |
//+------------------------------------------------------------------+
void HTRelayPublish(const string kind, const bool bullish,
                    const datetime barTime, const ENUM_TIMEFRAMES tf)
  {
   if(barTime <= 0)
      return;

   const string slot = HT_RELAY_PREFIX + kind + "_" + _Symbol
                       + "_" + HTRelayTFName(tf);

   GlobalVariableSet(slot, bullish ? (double)barTime : -(double)barTime);
  }
//+------------------------------------------------------------------+
