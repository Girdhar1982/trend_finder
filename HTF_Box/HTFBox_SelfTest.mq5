//+------------------------------------------------------------------+
//| HTFBox_SelfTest.mq5 - loads HTF_Box in the tester, prints objects |
//+------------------------------------------------------------------+
#property version "1.00"
int h = INVALID_HANDLE;
int ticks = 0;
bool done = false;

int OnInit()
  {
   h = iCustom(_Symbol, _Period, "HTF_Box\HTF_Box");
   PrintFormat("SELFTEST handle=%d period=%s", h, EnumToString(_Period));
   if(h == INVALID_HANDLE)
      return INIT_FAILED;
   ChartIndicatorAdd(0, 0, h);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   if(done || ++ticks < 2000)
      return;
   done = true;
   double b[];
   CopyBuffer(h, 0, 0, 1, b);
   int total = ObjectsTotal(0, 0, -1), n = 0, rects = 0, trends = 0, labels = 0;
   for(int i = 0; i < total; i++)
     {
      string nm = ObjectName(0, i, 0, -1);
      if(StringFind(nm, "HTFBOX_") != 0)
         continue;
      n++;
      long t = ObjectGetInteger(0, nm, OBJPROP_TYPE);
      if(t == OBJ_RECTANGLE) rects++;
      if(t == OBJ_TREND) trends++;
      if(t == OBJ_LABEL)
        {
         labels++;
         PrintFormat("SELFTEST %s = %s", nm, ObjectGetString(0, nm, OBJPROP_TEXT));
        }
      else
         PrintFormat("SELFTEST %s type=%d p0=%.5f p1=%.5f", nm, (int)t,
                     ObjectGetDouble(0, nm, OBJPROP_PRICE, 0), ObjectGetDouble(0, nm, OBJPROP_PRICE, 1));
     }
   PrintFormat("SELFTEST total=%d rects=%d trends=%d labels=%d total_objs=%d", n, rects, trends, labels, total);
   PrintFormat("SELFTEST %s", (rects >= 1 && labels >= 5) ? "PASS" : "FAIL");
  }
