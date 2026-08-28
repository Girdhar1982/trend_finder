//+------------------------------------------------------------------+
//|                                                 QRC_SelfTest.mq5 |
//|                                                                  |
//|  STATISTICAL SELF-TEST for QuantRegimeConfluence.mq5             |
//|                                                                  |
//|  WHY THIS EXISTS                                                 |
//|  The regime engine rests on four estimators whose whole value is |
//|  that they have a KNOWN value on pure noise. If someone edits    |
//|  the math and breaks that calibration, the thresholds silently   |
//|  stop meaning anything - nothing crashes, signals just quietly   |
//|  become wrong. This script re-derives the calibration from       |
//|  synthetic data and FAILS LOUDLY if an estimator has drifted.    |
//|                                                                  |
//|  HOW TO RUN                                                      |
//|    Compile, then drag onto any chart (it reads no market data).  |
//|    Results print to the Experts tab. Look for the final verdict. |
//|                                                                  |
//|  WHEN TO RUN                                                     |
//|    After ANY edit to the "MATH PRIMITIVES" section of            |
//|    QuantRegimeConfluence.mq5. The estimator code below is a      |
//|    deliberate COPY, so that this file tests the formulas rather  |
//|    than trivially agreeing with whatever the indicator now does. |
//|    If you change an estimator on purpose, update BOTH, and       |
//|    update the expected bands documented here.                    |
//|                                                                  |
//|  EXPECTED OUTPUT (measured over 3000 random walks in Python and  |
//|  reproduced here; bands are deliberately loose for 600 trials):  |
//|                                                                  |
//|    series                        ERn     VR(4)   z_VR   Hurst    |
//|    random walk, no drift        ~1.00    ~1.00   ~0.00  ~0.50    |
//|    DRIFT only (0.4 sigma/bar)   ~2.07    ~1.00   ~0.00  ~0.50    |
//|    AR(1) phi = +0.35            ~1.41    ~1.66   ~3.51  ~0.68    |
//|    AR(1) phi = -0.35            ~0.74    ~0.59  ~-2.22  ~0.30    |
//|                                                                  |
//|    Tn (normalised trend stat)   null mean ~1.00 for every n      |
//|                                                                  |
//|  NOTE the second row: drift moves ERn but NOT VR. That is        |
//|  correct and intentional - see TRAP 2 in the indicator header.   |
//+------------------------------------------------------------------+
#property copyright "Quant Regime Confluence Engine"
#property version   "1.10"
#property script_show_inputs
#property description "Validates the QRC estimators against known null distributions."

input int    InpTrials = 600;      // Monte-Carlo trials per case
input int    InpBars   = 400;      // Bars per synthetic series
input double InpSigma  = 0.001;    // Per-bar volatility of the synthetic series

//--- must mirror the indicator defaults
#define T_N        100
#define T_Q        4
#define T_NF       20
#define T_NS       100
#define T_ERN      20
#define T_SLOPEN   30
#define SLOPE_NULL_C 1.049

//+------------------------------------------------------------------+
//| Estimators - intentional copies of the indicator implementations |
//+------------------------------------------------------------------+
double Clamp(const double v, const double lo, const double hi)
  {
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
  }

double StdevRet(const double &c[], const int i, const int n)
  {
   if(n < 2 || i - n < 0) return 0.0;
   double s = 0.0, s2 = 0.0;
   for(int k = i - n + 1; k <= i; k++)
     {
      if(c[k] <= 0.0 || c[k-1] <= 0.0) return 0.0;
      const double r = MathLog(c[k] / c[k-1]);
      s += r; s2 += r * r;
     }
   const double m = s / n;
   const double v = (s2 - n * m * m) / (n - 1);
   return (v > 0.0 ? MathSqrt(v) : 0.0);
  }

double CalcVarF(const double &c[], const int i, const int nf, const int ns)
  {
   const double sf = StdevRet(c, i, nf);
   const double ss = StdevRet(c, i, ns);
   if(ss <= 0.0) return 1.0;
   return Clamp((sf * sf) / (ss * ss), 0.01, 25.0);
  }

double CalcERn(const double &c[], const int i, const int n)
  {
   if(n < 2 || i - n < 0) return 1.0;
   const double num = MathAbs(c[i] - c[i-n]);
   double den = 0.0;
   for(int k = i - n + 1; k <= i; k++)
      den += MathAbs(c[k] - c[k-1]);
   if(den <= 0.0) return 1.0;
   return (num / den) * MathSqrt((double)n);
  }

double CalcVarRatio(const double &c[], const int i, const int N, const int q, double &vrOut)
  {
   vrOut = 1.0;
   if(q < 2 || N < q * 3 || i - N < 0) return 0.0;
   const int p0 = i - N;
   if(c[p0] <= 0.0 || c[i] <= 0.0) return 0.0;
   const double mu = (MathLog(c[i]) - MathLog(c[p0])) / (double)N;

   double sa = 0.0;
   for(int k = p0 + 1; k <= i; k++)
     {
      const double d = MathLog(c[k] / c[k-1]) - mu;
      sa += d * d;
     }
   sa /= (double)(N - 1);
   if(sa <= 0.0) return 0.0;

   double sc = 0.0;
   for(int k = p0 + q; k <= i; k++)
     {
      const double d = MathLog(c[k] / c[k-q]) - q * mu;
      sc += d * d;
     }
   const double m = (double)q * (double)(N - q + 1) * (1.0 - (double)q / (double)N);
   if(m <= 0.0) return 0.0;
   sc /= m;

   const double vr = sc / sa;
   vrOut = Clamp(vr, 0.01, 20.0);
   const double varz = 2.0 * (2.0 * q - 1.0) * (q - 1.0) / (3.0 * q * (double)N);
   if(varz <= 0.0) return 0.0;
   return Clamp((vrOut - 1.0) / MathSqrt(varz), -12.0, 12.0);
  }

double CalcSlopeT(const double &c[], const int i, const int n)
  {
   if(n < 5 || i - n + 1 < 0) return 0.0;
   double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
   for(int k = 0; k < n; k++)
     {
      const double x = (double)k;
      const double y = c[i - n + 1 + k];
      sx += x; sy += y; sxx += x * x; sxy += x * y;
     }
   const double xbar = sx / n, ybar = sy / n;
   const double Sxx = sxx - n * xbar * xbar;
   const double Sxy = sxy - n * xbar * ybar;
   if(Sxx <= 0.0) return 0.0;
   const double b = Sxy / Sxx;
   const double a = ybar - b * xbar;
   double sse = 0.0;
   for(int k = 0; k < n; k++)
     {
      const double e = c[i - n + 1 + k] - (a + b * (double)k);
      sse += e * e;
     }
   const double s2 = sse / (double)(n - 2);
   if(s2 <= 0.0) return 0.0;
   const double seb = MathSqrt(s2 / Sxx);
   if(seb <= 0.0) return 0.0;
   return Clamp((b / seb) / (SLOPE_NULL_C * MathSqrt((double)n)), -15.0, 15.0);
  }

double ImpliedHurst(const double vr, const int q)
  {
   if(vr <= 0.0 || q < 2) return 0.5;
   return Clamp(0.5 * (1.0 + MathLog(vr) / MathLog((double)q)), 0.0, 1.0);
  }

//+------------------------------------------------------------------+
//| Box-Muller normal, seeded through MathSrand for reproducibility  |
//+------------------------------------------------------------------+
double Gauss()
  {
   double u1 = (MathRand() + 1.0) / 32768.0;
   double u2 = (MathRand() + 1.0) / 32768.0;
   if(u1 < 1e-12) u1 = 1e-12;
   return MathSqrt(-2.0 * MathLog(u1)) * MathCos(2.0 * M_PI * u2);
  }

//--- phi != 0 gives AR(1) returns; drift != 0 gives a trending random walk
void MakeSeries(double &c[], const int bars, const double sigma,
                const double drift, const double phi)
  {
   ArrayResize(c, bars + 1);
   c[0] = 1.10000;
   double prev = 0.0;
   for(int k = 1; k <= bars; k++)
     {
      const double e = Gauss() * sigma;
      const double r = drift + phi * prev + e;
      c[k] = c[k-1] * MathExp(r);
      prev = r;
     }
  }

//+------------------------------------------------------------------+
struct CaseResult
  {
   double            ern, vr, z, f, tn, h;
  };

CaseResult RunCase(const string label, const double drift, const double phi)
  {
   double sErn = 0, sVr = 0, sZ = 0, sF = 0, sTn = 0, sH = 0;
   double c[];
   for(int t = 0; t < InpTrials; t++)
     {
      MakeSeries(c, InpBars, InpSigma, drift, phi);
      const int i = ArraySize(c) - 1;
      double vr = 1.0;
      const double z = CalcVarRatio(c, i, T_N, T_Q, vr);
      sErn += CalcERn(c, i, T_ERN);
      sVr  += vr;
      sZ   += z;
      sF   += CalcVarF(c, i, T_NF, T_NS);
      sTn  += MathAbs(CalcSlopeT(c, i, T_SLOPEN));
      sH   += ImpliedHurst(vr, T_Q);
     }
   CaseResult r;
   const double n = (double)InpTrials;
   r.ern = sErn / n; r.vr = sVr / n; r.z = sZ / n;
   r.f = sF / n;     r.tn = sTn / n; r.h = sH / n;
   PrintFormat("  %-30s ERn=%6.3f  VR=%6.3f  z=%7.3f  F=%6.3f  |Tn|=%6.3f  H=%6.3f",
               label, r.ern, r.vr, r.z, r.f, r.tn, r.h);
   return r;
  }

int g_fail = 0;
void Check(const string name, const double val, const double lo, const double hi)
  {
   const bool ok = (val >= lo && val <= hi);
   if(!ok) g_fail++;
   PrintFormat("  [%s] %-38s %8.3f   expected [%.2f , %.2f]",
               (ok ? "PASS" : "FAIL"), name, val, lo, hi);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   MathSrand(20240101);

   Print("========================================================");
   Print("QRC SELF-TEST  -  estimator calibration");
   PrintFormat("trials=%d  bars=%d  sigma=%.5f", InpTrials, InpBars, InpSigma);
   Print("--------------------------------------------------------");

   const CaseResult rw = RunCase("A random walk (null)",      0.0,               0.0);
   const CaseResult dr = RunCase("B drift only 0.4 sigma",    0.4 * InpSigma,    0.0);
   const CaseResult pp = RunCase("C AR(1) phi=+0.35",         0.0,              0.35);
   const CaseResult mr = RunCase("D AR(1) phi=-0.35",         0.0,             -0.35);

   Print("--------------------------------------------------------");
   Print("Assertions:");

   //--- 1. every statistic must sit at its null on a random walk
   Check("RW  ERn  == 1.0 (null)",        rw.ern, 0.85, 1.15);
   Check("RW  VR   == 1.0 (null)",        rw.vr,  0.85, 1.15);
   Check("RW  z_VR == 0.0 (null)",        rw.z,  -0.70, 0.70);
   Check("RW  F    == 1.0 (null)",        rw.f,   0.85, 1.20);
   Check("RW  |Tn| == 1.0 (normalised)",  rw.tn,  0.80, 1.25);
   Check("RW  Hurst== 0.5 (null)",        rw.h,   0.44, 0.56);

   //--- 2. drift must move ERn but NOT the variance ratio (TRAP 2)
   Check("DRIFT raises ERn",              dr.ern, 1.60, 3.00);
   Check("DRIFT leaves VR at null",       dr.vr,  0.85, 1.15);
   Check("DRIFT leaves z_VR at null",     dr.z,  -0.70, 0.70);

   //--- 3. genuine persistence must be detected
   Check("AR+ raises VR above 1",         pp.vr,  1.30, 2.20);
   Check("AR+ z_VR strongly positive",    pp.z,   2.00, 8.00);
   Check("AR+ Hurst above 0.5",           pp.h,   0.58, 0.85);

   //--- 4. mean reversion must be detected with the opposite sign
   Check("AR- pushes VR below 1",         mr.vr,  0.30, 0.85);
   Check("AR- z_VR strongly negative",    mr.z,  -8.00, -1.50);
   Check("AR- Hurst below 0.5",           mr.h,   0.15, 0.44);

   Print("--------------------------------------------------------");
   if(g_fail == 0)
      Print("VERDICT: PASS - all estimators match their null distributions.");
   else
      PrintFormat("VERDICT: FAIL - %d assertion(s) broken. The regime thresholds "
                  "in QuantRegimeConfluence.mq5 are no longer calibrated.", g_fail);
   Print("========================================================");
  }
//+------------------------------------------------------------------+
