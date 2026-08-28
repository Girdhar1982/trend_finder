//+------------------------------------------------------------------+
//| QRC execution layer - generic profile, original defaults.
//|            Execution layer for QuantRegimeConfluence.mq5         |
//+------------------------------------------------------------------+
//| Thin wrapper. All logic lives in QuantRegimeConfluenceEA_Core.mqh |
//| - this file only picks the default profile. Fix bugs in the core, |
//| never here: one copy of the strategy, three front doors.          |
//+------------------------------------------------------------------+
#property copyright "Quant Regime Confluence Engine"
#property version   "1.10"
#property description "QRC execution layer - generic profile, original defaults."
#property description "Shared core with the crypto and forex builds."
#property description "Reads QuantRegimeConfluence via iCustom - no signal logic of its own."

#include "QuantRegimeConfluenceEA_Core.mqh"
//+------------------------------------------------------------------+
