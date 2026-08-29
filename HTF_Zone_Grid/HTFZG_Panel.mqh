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
//| Every object name starts with g_prefix ("HTFZG_"). Cleanup is    |
//| by prefix in OnDeinit - never ObjectsDeleteAll(0) with no        |
//| prefix, which would wipe the user's own drawings and any other   |
//| EA sharing the chart.                                            |
//|                                                                  |
//+==================================================================+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"

#include "HTFZG_Types.mqh"

//+------------------------------------------------------------------+
//| Dashboard fields required by the spec:                           |
//|   HTF Dir | Zone | Score | Grid Active? | Levels filled X/3      |
//|   Avg Entry | Shared SL | Daily PnL | Cooldown                   |
//|                                                                  |
//| Plus the score BREAKDOWN and signal.reject, which are not in the |
//| spec but are the difference between "score 65" and knowing that  |
//| the sweep never happened. A selective EA is idle most of the     |
//| time; the panel has to explain the idleness or it will be        |
//| mistaken for a fault.                                            |
//+------------------------------------------------------------------+
void HTFZG_PanelDraw(const string prefix, const HTFZGSignal &sig, const HTFZGGrid &g,
                     const HTFZGDayBook &book, ENUM_HTFZG_STATE state,
                     int corner, int x, int y, int fontSize, color fg, color bg);

//+------------------------------------------------------------------+
//| Chart visuals: the zone rectangle, one line per planned grid     |
//| level, and the shared stop.                                      |
//|                                                                  |
//| Drawn ONLY for the live grid, and cleared the moment it closes.  |
//| Leaving the ladder of a finished trade on the chart makes the    |
//| next signal unreadable, and on a long backtest it draws          |
//| thousands of objects and stalls the terminal.                    |
//+------------------------------------------------------------------+
void HTFZG_DrawZone(const string prefix, const HTFZGZone &z, datetime from, color c);
void HTFZG_DrawGrid(const string prefix, const HTFZGGrid &g, color cLevel, color cSL);
void HTFZG_ClearGrid(const string prefix);
void HTFZG_ClearAll(const string prefix);

//+------------------------------------------------------------------+
//  IMPLEMENTATION - see docs/DEVELOPMENT_PLAN.md, phase 4.
//+------------------------------------------------------------------+
