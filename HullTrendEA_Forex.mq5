//+------------------------------------------------------------------+
//| Hull Trend flip EA - forex profile (M5+, 1.5xATR stop, Friday cutoff).
//|                                  Copyright 2026, Trading Systems |
//|                                             https://trading.com  |
//+------------------------------------------------------------------+
//| Thin wrapper. All logic lives in HullTrendEA_Core.mqh - this file |
//| only picks the default profile. Fix bugs in the core, never here: |
//| there is exactly one copy of the strategy and three front doors.  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Systems"
#property link      "https://trading.com"
#property version   "1.30"
#property description "Hull Trend flip EA - forex profile (M5+, 1.5xATR stop, Friday cutoff)."
#property description "Shared core with the crypto build; only the defaults differ."

#define HULL_PROFILE_FOREX
#include "HullTrendEA_Core.mqh"
//+------------------------------------------------------------------+
