//+------------------------------------------------------------------+
//| Hull Trend flip EA - crypto profile (H1+, 2.25xATR stop, 24/7).
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
#property description "Hull Trend flip EA - crypto profile (H1+, 2.25xATR stop, 24/7)."
#property description "Shared core with the forex build; only the defaults differ."

#define HULL_PROFILE_CRYPTO
#include "HullTrendEA_Core.mqh"
//+------------------------------------------------------------------+
