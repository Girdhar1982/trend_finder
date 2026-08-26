//+------------------------------------------------------------------+
//| QRC execution layer - forex profile (M15+, Friday cutoff).
//|            Execution layer for QuantRegimeConfluence.mq5         |
//+------------------------------------------------------------------+
//| Thin wrapper. All logic lives in QuantRegimeConfluenceEA_Core.mqh |
//| - this file only picks the default profile. Fix bugs in the core, |
//| never here: one copy of the strategy, three front doors.          |
//+------------------------------------------------------------------+
#property copyright "Quant Regime Confluence Engine"
#property version   "1.10"
#property description "QRC execution layer - forex profile (M15+, Friday cutoff)."
#property description "Shared core with the crypto build; only the defaults differ."
#property description "Reads QuantRegimeConfluence via iCustom - no signal logic of its own."

#define QRC_PROFILE_FOREX
#include "QuantRegimeConfluenceEA_Core.mqh"
//+------------------------------------------------------------------+
