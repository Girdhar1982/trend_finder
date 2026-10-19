//+------------------------------------------------------------------+
//| Open_Positions.mq5                                               |
//| Prints the number of open positions and (optionally) one line    |
//| per position at the top of the chart. Updates every second.      |
//+------------------------------------------------------------------+
#property copyright "Open Positions"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

enum ENUM_SCOPE { SCOPE_THIS_SYMBOL, SCOPE_ALL_SYMBOLS };

input ENUM_SCOPE       InpScope      = SCOPE_ALL_SYMBOLS; // Count positions on
input bool             InpShowCount  = true;              // Show "Open positions: N" header
input bool             InpShowList   = true;              // Show one line per position
input int              InpMaxRows    = 10;                // Max position lines
input ENUM_BASE_CORNER InpCorner     = CORNER_RIGHT_UPPER; // Corner
input int              InpX          = 10;                // X offset
input int              InpY          = 135;               // Y offset (below Session_Clock)
input int              InpFontSize   = 11;                // Font size
input string           InpFont       = "Consolas";        // Font
input color            InpHeadColor  = clrNavy;           // Header colour
input color            InpProfitColor= clrDarkGreen;      // Colour: position in profit
input color            InpLossColor  = clrDarkRed;        // Colour: position in loss

const string PREFIX  = "OPENPOS_";
const int    HARDMAX = 50;

//+------------------------------------------------------------------+
void SetRow(const int i, const string text, const color clr)
  {
   const string name = PREFIX + IntegerToString(i);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     InpCorner);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  InpY + i * (InpFontSize + 8));
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetString(0,  name, OBJPROP_FONT,       InpFont);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   ObjectSetString(0,  name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
void Refresh()
  {
   int    count = 0, shown = 0, row = 0;
   double total = 0.0;
   string lines[];
   color  clrs[];

   for(int i = 0; i < PositionsTotal(); i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      const string sym = PositionGetString(POSITION_SYMBOL);
      if(InpScope == SCOPE_THIS_SYMBOL && sym != _Symbol)
         continue;
      count++;
      const double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      total += pl;
      if(!InpShowList || shown >= InpMaxRows || shown >= HARDMAX)
         continue;
      const bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      const int  dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      ArrayResize(lines, shown + 1);
      ArrayResize(clrs,  shown + 1);
      lines[shown] = StringFormat("%s %-4s %.2f @ %s  %+.2f", sym, buy ? "BUY" : "SELL",
                                  PositionGetDouble(POSITION_VOLUME),
                                  DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), dg), pl);
      clrs[shown]  = pl >= 0 ? InpProfitColor : InpLossColor;
      shown++;
     }

   if(InpShowCount)
     {
      const string scope = InpScope == SCOPE_THIS_SYMBOL ? " (" + _Symbol + ")" : "";
      string head = StringFormat("Open positions%s: %d", scope, count);
      if(count > 0)
         head += StringFormat("  P/L %+.2f %s", total, AccountInfoString(ACCOUNT_CURRENCY));
      SetRow(row++, head, InpHeadColor);
     }
   for(int k = 0; k < shown; k++)
      SetRow(row++, lines[k], clrs[k]);
   if(InpShowList && count > shown)
      SetRow(row++, StringFormat("... +%d more", count - shown), InpHeadColor);

   for(int i = row; i < HARDMAX + 2; i++)
      if(!ObjectDelete(0, PREFIX + IntegerToString(i)))
         if(i > row + 2)
            break;
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(1);
   Refresh();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Refresh();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   return rates_total;
  }
//+------------------------------------------------------------------+
