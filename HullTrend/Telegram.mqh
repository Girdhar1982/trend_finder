//+------------------------------------------------------------------+
//|                                                      Telegram.mqh|
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Telegram delivery for the HullTrend family.                       |
//|                                                                   |
//| The bot token is a CREDENTIAL and is deliberately NOT compiled in. |
//| It lives in MQL5\Files\telegram.ini, which is read at runtime, so  |
//| it never enters an .ex5, never reaches the git repo, and can be    |
//| rotated without recompiling anything.                             |
//|                                                                   |
//| WebRequest() is PROHIBITED IN INDICATORS by the terminal - it is   |
//| legal only in EAs and scripts. Nothing here may be called from an  |
//| indicator; the indicator publishes a signal and HullTrendTelegram  |
//| Relay.mq5 does the sending. See §10.1 of HullTrend_Documentation.md.|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#define TG_CONFIG_FILE  "telegram.ini"
#define TG_API_HOST     "https://api.telegram.org"
#define TG_TIMEOUT_MS   5000

//--- resolved once at OnInit, reused for every send
string g_tgToken  = "";
string g_tgBotId  = "";   // numeric half of the token, before the colon
string g_tgChat   = "";
bool   g_tgLoaded = false;

//+------------------------------------------------------------------+
//| Trim spaces, tabs and stray CR from both ends                    |
//+------------------------------------------------------------------+
string TgTrim(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   StringReplace(s, "\r", "");
   return s;
  }

//+------------------------------------------------------------------+
//| Escape text for parse_mode=HTML.                                  |
//|                                                                   |
//| Telegram parses the body as HTML, so a bare & or < in a symbol    |
//| name or broker string makes the whole message fail to parse -     |
//| the send returns HTTP 400 and the alert is simply lost. The       |
//| ampersand must be replaced FIRST or it would re-escape the        |
//| entities produced by the other two.                               |
//+------------------------------------------------------------------+
string TgHtmlEscape(string s)
  {
   StringReplace(s, "&", "&amp;");
   StringReplace(s, "<", "&lt;");
   StringReplace(s, ">", "&gt;");
   return s;
  }

//+------------------------------------------------------------------+
//| Percent-encode for application/x-www-form-urlencoded.            |
//| Operates on UTF-8 BYTES, not characters, so non-Latin symbol     |
//| names and messages survive the round trip intact.                |
//+------------------------------------------------------------------+
string TgUrlEncode(const string s)
  {
   uchar  bytes[];
   const int n = StringToCharArray(s, bytes, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   string out = "";

   for(int i = 0; i < n; i++)
     {
      const uchar c = bytes[i];
      //--- RFC 3986 unreserved set: everything else is escaped
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') ||
         c == '-' || c == '_' || c == '.' || c == '~')
         out += CharToString(c);
      else
         out += StringFormat("%%%02X", c);
     }
   return out;
  }

//+------------------------------------------------------------------+
//| A bot token is <bot_id>:<secret>. Pasting only one half is the    |
//| classic mistake and Telegram answers a bare 401, which says       |
//| nothing about which half is missing - so check the shape here.    |
//| Sets g_tgBotId as a side effect; the chat_id check needs it.      |
//+------------------------------------------------------------------+
bool TgTokenLooksValid(const string token)
  {
   const int colon = StringFind(token, ":");
   if(colon <= 0)
     {
      PrintFormat("Telegram: token is malformed - it must look like "
                  "<bot_id>:<secret> and contain a colon. Yours has none, so "
                  "the numeric bot id in front of the colon is missing. Copy "
                  "the WHOLE token from BotFather.");
      return false;
     }

   g_tgBotId = StringSubstr(token, 0, colon);
   for(int i = 0; i < StringLen(g_tgBotId); i++)
     {
      const ushort c = StringGetCharacter(g_tgBotId, i);
      if(c < '0' || c > '9')
        {
         PrintFormat("Telegram: token is malformed - the part before the colon "
                     "must be the numeric bot id, got '%s'.", g_tgBotId);
         g_tgBotId = "";
         return false;
        }
     }
   return true;
  }
//+------------------------------------------------------------------+
//| Reject a chat_id that cannot possibly work, with the reason.      |
//|                                                                   |
//| Telegram accepts a numeric id (negative for groups and channels)  |
//| or @publicchannelname. A bot USERNAME is the single most common   |
//| thing put here, and it fails far downstream as an opaque          |
//| "HTTP 400 - chat not found", so name it precisely up front.       |
//+------------------------------------------------------------------+
bool TgChatIdLooksValid(const string chat)
  {
   //--- checked first, and with or without the '@': a bot username is the
   //--- most common wrong answer here in either form
   if(StringLen(chat) > 4
      && StringSubstr(chat, StringLen(chat) - 4) == "_bot")
     {
      PrintFormat("Telegram: chat_id '%s' is a BOT username, not a chat. A bot "
                  "cannot message itself - chat_id must be the DESTINATION chat "
                  "(a numeric id).", chat);
      return false;
     }

   if(StringGetCharacter(chat, 0) == '@')
      return true;                     // @publicchannelname is legal

   //--- the bot's own id is not a chat. This happens when the token is
   //--- split across the two keys, which also breaks the token itself.
   if(g_tgBotId != "" && chat == g_tgBotId)
     {
      PrintFormat("Telegram: chat_id '%s' is this BOT'S OWN id (the number "
                  "before the colon in the token). It must be the id of the "
                  "PERSON or GROUP you want messaged, which is a different "
                  "number. A bot cannot message itself.", chat);
      return false;
     }

   //--- otherwise it must be a plain integer, optionally negative
   const int n = StringLen(chat);
   int       i = (StringGetCharacter(chat, 0) == '-' ? 1 : 0);
   bool      numeric = (n > i);

   for(; i < n && numeric; i++)
     {
      const ushort c = StringGetCharacter(chat, i);
      if(c < '0' || c > '9')
         numeric = false;
     }

   if(!numeric)
     {
      PrintFormat("Telegram: chat_id '%s' is not a numeric id. Send your bot a "
                  "message, open https://api.telegram.org/bot<TOKEN>/getUpdates "
                  "and copy result[0].message.chat.id (groups are negative).", chat);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Read token + chat id from MQL5\Files\telegram.ini.                |
//|                                                                   |
//| Format - one key=value per line, # or ; starts a comment:         |
//|   token   = 123456789:AAF...                                      |
//|   chat_id = -1001234567890                                        |
//|                                                                   |
//| Returns false with a specific reason in the Experts log, because  |
//| "Telegram silently does nothing" is the worst possible outcome.   |
//+------------------------------------------------------------------+
bool TelegramLoadConfig()
  {
   g_tgToken  = "";
   g_tgBotId  = "";
   g_tgChat   = "";
   g_tgLoaded = false;

   const int h = FileOpen(TG_CONFIG_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("Telegram: cannot open MQL5\\Files\\%s (error %d). "
                  "Create it with 'token=' and 'chat_id=' lines.",
                  TG_CONFIG_FILE, GetLastError());
      return false;
     }

   while(!FileIsEnding(h))
     {
      string line = TgTrim(FileReadString(h));

      if(line == "" || StringGetCharacter(line, 0) == '#'
                    || StringGetCharacter(line, 0) == ';')
         continue;

      const int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;

      string key = TgTrim(StringSubstr(line, 0, eq));
      string val = TgTrim(StringSubstr(line, eq + 1));
      StringToLower(key);

      if(key == "token")
         g_tgToken = val;
      else
         if(key == "chat_id" || key == "chatid")
            g_tgChat = val;
     }
   FileClose(h);

   //--- an unedited template is the likeliest failure, so name it exactly
   if(g_tgToken == "" || StringFind(g_tgToken, "PASTE_") == 0)
     {
      PrintFormat("Telegram: 'token' is missing or still the placeholder in %s.",
                  TG_CONFIG_FILE);
      return false;
     }
   if(!TgTokenLooksValid(g_tgToken))
      return false;
   if(g_tgChat == "" || StringFind(g_tgChat, "PASTE_") == 0)
     {
      PrintFormat("Telegram: 'chat_id' is missing or still the placeholder in %s.",
                  TG_CONFIG_FILE);
      return false;
     }
   if(!TgChatIdLooksValid(g_tgChat))
      return false;

   g_tgLoaded = true;
   PrintFormat("Telegram: config loaded, chat_id=%s, token=...%s",
               g_tgChat, StringSubstr(g_tgToken, StringLen(g_tgToken) - 4));
   return true;
  }

//+------------------------------------------------------------------+
//| POST one message to the configured chat. Returns true on HTTP 200.|
//|                                                                   |
//| MUST NOT be called from an indicator - WebRequest fails there with |
//| 4014 (function not allowed) no matter how the terminal is set up.  |
//+------------------------------------------------------------------+
bool TelegramSend(const string text)
  {
   if(!g_tgLoaded)
     {
      Print("Telegram: send skipped - config not loaded.");
      return false;
     }

   const string url  = TG_API_HOST + "/bot" + g_tgToken + "/sendMessage";
   const string body = "chat_id=" + TgUrlEncode(g_tgChat)
                     + "&text="   + TgUrlEncode(text)
                     + "&parse_mode=HTML"
                     + "&disable_web_page_preview=true";

   char data[];
   //--- drop the terminating zero: it is not part of the form body and
   //--- Telegram rejects the request with it attached
   const int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(data, len);

   char   result[];
   string resultHeaders;
   ResetLastError();

   const int status = WebRequest("POST", url,
                                 "Content-Type: application/x-www-form-urlencoded\r\n",
                                 TG_TIMEOUT_MS, data, result, resultHeaders);

   if(status == 200)
      return true;

   const int err = GetLastError();
   if(status == -1)
     {
      if(err == 4014)
         Print("Telegram: WebRequest is not permitted here. It is blocked in "
               "indicators entirely; in an EA, add " + TG_API_HOST +
               " to Tools > Options > Expert Advisors > Allow WebRequest.");
      else
         PrintFormat("Telegram: WebRequest failed, error %d. Check that %s is "
                     "whitelisted in Tools > Options > Expert Advisors.",
                     err, TG_API_HOST);
     }
   else
     {
      //--- surface Telegram's own error text: a bad chat_id or a revoked
      //--- token both answer 4xx with a readable description
      PrintFormat("Telegram: HTTP %d - %s", status,
                  CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
     }
   return false;
  }
//+------------------------------------------------------------------+
