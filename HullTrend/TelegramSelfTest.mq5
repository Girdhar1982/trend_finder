//+------------------------------------------------------------------+
//|                                              TelegramSelfTest.mq5|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Drag onto any chart to prove the Telegram path end to end.       |
//|                                                                   |
//| A script, not an indicator, precisely because WebRequest() is      |
//| prohibited in indicators - the same reason the relay is an EA.     |
//|                                                                   |
//| Checks, in order, and names the first thing that is wrong:         |
//|   1. MQL5\Files\telegram.ini exists and parses                     |
//|   2. token has the <bot_id>:<secret> shape                         |
//|   3. chat_id is a real destination, not the bot itself             |
//|   4. https://api.telegram.org is whitelisted for WebRequest        |
//|   5. Telegram accepts a real message                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.00"
#property description "Verifies telegram.ini and sends one test message."
#property script_show_inputs

#include "Telegram.mqh"

input string InpTestText = "HullTrend Telegram self-test - if you can read this, alerts will arrive.";

//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=== Telegram self-test ===");

   //--- steps 1-3 all report their own specific reason
   if(!TelegramLoadConfig())
     {
      Print("RESULT: FAILED at the config stage. Fix the reason printed above "
            "in MQL5\\Files\\telegram.ini, then run this script again.");
      return;
     }
   Print("Config OK: token shape valid, chat_id is a plausible destination.");

   //--- steps 4-5: the only way to tell them apart is to actually try
   if(TelegramSend(InpTestText))
     {
      Print("RESULT: SUCCESS - Telegram accepted the message. Check your chat.");
      Print("The relay EA will now deliver reversals the same way.");
      return;
     }

   Print("RESULT: FAILED at the send stage. The error above says which:");
   Print("  error 4014 -> Algo Trading is off, or this was run from an indicator.");
   Print("  error 5203 / status -1 -> https://api.telegram.org is not in");
   Print("     Tools > Options > Expert Advisors > Allow WebRequest for listed URL.");
   Print("  HTTP 401 -> the token is wrong or was revoked by BotFather.");
   Print("  HTTP 400 chat not found -> chat_id is not a chat this bot can reach.");
   Print("     Message the bot from your own account first, then read");
   Print("     https://api.telegram.org/bot<TOKEN>/getUpdates for the real id.");
  }
//+------------------------------------------------------------------+
