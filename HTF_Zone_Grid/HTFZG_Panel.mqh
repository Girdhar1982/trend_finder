//+------------------------------------------------------------------+
//|                                                  HTFZG_Panel.mqh |
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+==================================================================+
//|                                                                  |
//| PRESENTATION ONLY. The dashboard and the chart drawing.          |
//|                                                                  |
//| Nothing here decides anything. It is handed the current signal,  |
//| grid and daybook and renders them. Deleting this file would      |
//| leave a fully functional EA, which is the test of whether the    |
//| separation held.                                                 |
//|                                                                  |
//| Every object name starts with the caller's prefix ("HTFZG_").    |
//| Cleanup is BY PREFIX - never ObjectsDeleteAll(0) with no filter, |
//| which would wipe the user's own drawings and anything belonging  |
//| to another EA sharing the chart.                                 |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#include "HTFZG_Types.mqh"

//+------------------------------------------------------------------+
//| One dashboard row.                                               |
//+------------------------------------------------------------------+
void HTFZG_Row(const string name, const int x, const int y, const int corner,
               const string text, const color c, const int size)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   size);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetString (0, name, OBJPROP_FONT,       "Consolas");
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
  }

//+------------------------------------------------------------------+
string HTFZG_DirText(const ENUM_HTFZG_DIR d)
  {
   if(d == HTFZG_DIR_BUY)  return "BUY";
   if(d == HTFZG_DIR_SELL) return "SELL";
   return "NEUTRAL";
  }

//+------------------------------------------------------------------+
string HTFZG_StateText(const ENUM_HTFZG_STATE s)
  {
   switch(s)
     {
      case HTFZG_ACTIVE:   return "ACTIVE";
      case HTFZG_PARTIAL:  return "PARTIAL (TP1 taken)";
      case HTFZG_COOLDOWN: return "COOLDOWN";
     }
   return "IDLE";
  }

//+------------------------------------------------------------------+
//| The dashboard.                                                   |
//|                                                                  |
//| The spec's nine fields, plus the score BREAKDOWN and             |
//| signal.reject. Those two are not in the spec but they are the    |
//| difference between "score 65" and knowing the sweep never        |
//| happened. A deliberately selective EA is idle almost all of the  |
//| time; the panel has to explain the idleness or it gets mistaken  |
//| for a fault and "fixed".                                         |
//+------------------------------------------------------------------+
void HTFZG_PanelDraw(const string prefix, const HTFZGSignal &sig, const HTFZGGrid &g,
                     const HTFZGDayBook &book, const ENUM_HTFZG_STATE state,
                     const int minScore, const int maxTrades,
                     const int corner, const int x, const int y,
                     const int fontSize, const color fg, const color bg)
  {
   const int    dg   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const int    lh   = fontSize + 6;
   const bool   live = (state == HTFZG_ACTIVE || state == HTFZG_PARTIAL);
   const string bgN  = prefix + "bg";

   //--- backing plate
   if(bg != clrNONE)
     {
      if(ObjectFind(0, bgN) < 0)
         ObjectCreate(0, bgN, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgN, OBJPROP_CORNER,     corner);
      ObjectSetInteger(0, bgN, OBJPROP_XDISTANCE,  x - 8);
      ObjectSetInteger(0, bgN, OBJPROP_YDISTANCE,  y - 8);
      ObjectSetInteger(0, bgN, OBJPROP_XSIZE,      330);
      ObjectSetInteger(0, bgN, OBJPROP_YSIZE,      lh * 12 + 16);
      ObjectSetInteger(0, bgN, OBJPROP_BGCOLOR,    bg);
      ObjectSetInteger(0, bgN, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgN, OBJPROP_COLOR,      bg);
      ObjectSetInteger(0, bgN, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgN, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, bgN, OBJPROP_BACK,       false);
     }

   const color cScore = (sig.total >= minScore ? clrLimeGreen
                       : sig.total >= minScore - 20 ? clrGold : clrSilver);
   const color cState = (live ? clrDeepSkyBlue
                       : state == HTFZG_COOLDOWN ? clrGold : fg);
   const color cLoss  = (book.realisedPnL < 0.0 ? clrTomato : clrLimeGreen);

   int row = 0;
   HTFZG_Row(prefix + "t", x, y + lh * (row++), corner,
             "HTF ZONE GRID  3-LEVEL", clrWhite, fontSize + 1);

   HTFZG_Row(prefix + "r0", x, y + lh * (row++), corner,
             StringFormat("HTF dir (H4)  : %s", HTFZG_DirText(sig.dir)),
             (sig.dir == HTFZG_DIR_NONE ? clrSilver : clrDeepSkyBlue), fontSize);

   HTFZG_Row(prefix + "r1", x, y + lh * (row++), corner,
             (sig.zone.valid
              ? StringFormat("Zone (H1)     : %s - %s  (%d touch)",
                             DoubleToString(sig.zone.low, dg),
                             DoubleToString(sig.zone.high, dg), sig.zone.touches)
              : "Zone (H1)     : none"), fg, fontSize);

   HTFZG_Row(prefix + "r2", x, y + lh * (row++), corner,
             StringFormat("Score         : %d / %d", sig.total, minScore), cScore, fontSize);

   HTFZG_Row(prefix + "r3", x, y + lh * (row++), corner,
             StringFormat("  T%-3d Z%-3d P%-3d S%-3d B%-3d V%-3d",
                          sig.sTrend, sig.sZone, sig.sPivot,
                          sig.sSweep, sig.sBOS, sig.sVol), clrSilver, fontSize);

   HTFZG_Row(prefix + "r4", x, y + lh * (row++), corner,
             StringFormat("Blocked by    : %s",
                          (sig.reject == "" ? "-" : sig.reject)),
             (sig.reject == "" ? clrSilver : clrGold), fontSize);

   HTFZG_Row(prefix + "r5", x, y + lh * (row++), corner,
             StringFormat("Grid          : %s", HTFZG_StateText(state)), cState, fontSize);

   HTFZG_Row(prefix + "r6", x, y + lh * (row++), corner,
             (live ? StringFormat("Levels filled : %d / %d", g.FilledCount(), g.count)
                   : "Levels filled : -"), fg, fontSize);

   HTFZG_Row(prefix + "r7", x, y + lh * (row++), corner,
             (live ? StringFormat("Avg entry     : %s", DoubleToString(g.avgEntry, dg))
                   : "Avg entry     : -"), fg, fontSize);

   HTFZG_Row(prefix + "r8", x, y + lh * (row++), corner,
             (live ? StringFormat("Shared SL     : %s%s", DoubleToString(g.sharedSL, dg),
                                  (g.tp1Done ? "  (at BE)" : ""))
                   : "Shared SL     : -"),
             (live ? clrTomato : fg), fontSize);

   HTFZG_Row(prefix + "r9", x, y + lh * (row++), corner,
             StringFormat("Daily PnL     : %.2f  (%d/%d grids)",
                          book.realisedPnL, book.gridsToday,
                          maxTrades), cLoss, fontSize);

   const long left = (long)(book.cooldownUntil - TimeCurrent());
   HTFZG_Row(prefix + "r10", x, y + lh * (row++), corner,
             (book.lockedOut ? "Cooldown      : LOCKED OUT (daily loss)"
              : left > 0 ? StringFormat("Cooldown      : %d min left", (int)(left / 60))
              : "Cooldown      : ready"),
             (book.lockedOut ? clrTomato : left > 0 ? clrGold : clrLimeGreen), fontSize);
  }

//+------------------------------------------------------------------+
//| Chart visuals: the zone rectangle, one line per planned level,   |
//| and the shared stop.                                             |
//|                                                                  |
//| Drawn ONLY for the live grid and cleared the moment it closes.   |
//| Leaving a finished trade's ladder on the chart makes the next    |
//| signal unreadable, and across a long backtest it accumulates     |
//| thousands of objects and stalls the terminal.                    |
//+------------------------------------------------------------------+
void HTFZG_DrawZone(const string prefix, const HTFZGZone &z, const datetime from, const color c)
  {
   const string n = prefix + "zone";
   const datetime t2 = TimeCurrent() + PeriodSeconds(PERIOD_H1) * 8;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE, 0, from, z.low, t2, z.high);
   ObjectSetInteger(0, n, OBJPROP_TIME,  0, from);
   ObjectSetDouble (0, n, OBJPROP_PRICE, 0, z.low);
   ObjectSetInteger(0, n, OBJPROP_TIME,  1, t2);
   ObjectSetDouble (0, n, OBJPROP_PRICE, 1, z.high);
   ObjectSetInteger(0, n, OBJPROP_COLOR,      c);
   ObjectSetInteger(0, n, OBJPROP_FILL,       true);
   ObjectSetInteger(0, n, OBJPROP_BACK,       true);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
  }

//+------------------------------------------------------------------+
void HTFZG_Line(const string name, const double price, const color c,
                const ENUM_LINE_STYLE style, const int width, const string text)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      c);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,    text);
  }

//+------------------------------------------------------------------+
void HTFZG_DrawGrid(const string prefix, const HTFZGGrid &g,
                    const color cLevel, const color cSL)
  {
   for(int i = 0; i < g.count; i++)
      HTFZG_Line(prefix + "lv" + IntegerToString(i), g.lv[i].price, cLevel,
                 (g.lv[i].filled ? STYLE_SOLID : STYLE_DOT), 1,
                 StringFormat("L%d %s %.2f lots", i + 1,
                              (g.lv[i].filled ? "filled" : "pending"), g.lv[i].lots));

   HTFZG_Line(prefix + "sl",  g.sharedSL, cSL,          STYLE_SOLID, 2, "Shared SL");
   HTFZG_Line(prefix + "tp1", g.tp1,      clrMediumSeaGreen, STYLE_DASH,  1, "TP1 (50% out)");
   HTFZG_Line(prefix + "tp2", g.tp2,      clrMediumSeaGreen, STYLE_SOLID, 1, "TP2");
  }

//+------------------------------------------------------------------+
//| Clear only the trade objects, leaving the dashboard in place.    |
//+------------------------------------------------------------------+
void HTFZG_ClearGrid(const string prefix)
  {
   ObjectsDeleteAll(0, prefix + "lv");
   ObjectDelete(0, prefix + "sl");
   ObjectDelete(0, prefix + "tp1");
   ObjectDelete(0, prefix + "tp2");
   ObjectDelete(0, prefix + "zone");
  }

//+------------------------------------------------------------------+
void HTFZG_ClearAll(const string prefix)
  {
   ObjectsDeleteAll(0, prefix);
  }
//+------------------------------------------------------------------+
