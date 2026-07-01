//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                                     Copyright 2025, nhasibuan    |
//|                          https://github.com/nhasibuan/oneminuteman|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, nhasibuan"
#property link      "https://github.com/nhasibuan/oneminuteman"
#property version   "5.00"
#property strict
#property description "OneMinuteMan: M1 rolling Ask range + candlestick recognition + PPM efficiency engine"

//==================================================================
// SECTION 0 — INPUTS
//==================================================================
//--- Range Scanner
input int    InpSampleMs    = 50;    // Sampling interval (ms), min 10
input int    InpWindowSize  = 1200;  // Buffer size (samples): 1200 x 50ms = 60s
//--- Candle Recognizer
input int    InpAverPeriod  = 14;    // SMA period for trend + avg body
//--- PPM Engine
input int    InpZzDepth     = 2;     // ZigZag Depth   (recommended: 2 for M1)
input int    InpZzDeviation = 2;     // ZigZag Deviation
input int    InpZzBackstep  = 1;     // ZigZag Backstep
input int    InpZzLookback  = 100;   // Bars to scan for ZigZag pivots
input double InpPpmMinHigh  = 2.0;   // PPM threshold — below this is low efficiency
input double InpPpmTarget   = 4.0;   // PPM target — ideal entry zone
input double InpAtrDailyRef = 1.5;   // ATR M1 daily baseline in pips (default 1.5)
input bool   InpShowPPM     = true;  // Show PPM panel in Comment()

//==================================================================
// SECTION 1 — CONSTANTS & BUFFER
//==================================================================
#define BUFFER_SIZE 1202

//==================================================================
// SECTION 2 — ENUMERATIONS
//==================================================================
enum TYPE_CANDLESTICK
{
   CAND_UNKNOWN = 0,
   CAND_LONG,
   CAND_SHORT,
   CAND_DOJI,
   CAND_MARUBOZU,
   CAND_HAMMER,
   CAND_INVERTED_HAMMER,
   CAND_SPINNING_TOP
};

enum TYPE_TREND
{
   TREND_UNKNOWN = 0,
   TREND_UPPER,
   TREND_DOWN,
   TREND_LATERAL
};

enum PPM_ZONE
{
   PPM_ZONE_NONE    = 0,  // No data
   PPM_ZONE_LOW,          // < InpPpmMinHigh  — avoid
   PPM_ZONE_MEDIUM,       // >= InpPpmMinHigh — acceptable
   PPM_ZONE_HIGH          // >= InpPpmTarget  — ideal, enter
};

//==================================================================
// SECTION 3 — STRUCTURES
//==================================================================
struct CANDLE_STRUCTURE
{
   TYPE_CANDLESTICK type;
   TYPE_TREND       unit;
   double           bodysize;
   double           shade_high;
   double           shade_low;
   double           avg_close;
   double           avg_body;
   double           open;
   double           high;
   double           low;
   double           close;
};

struct PPM_RESULT
{
   double   ppm;          // Pips-per-minute efficiency
   double   pips;         // Pip distance of last ZZ leg
   int      candles;      // M1 candles in last ZZ leg
   double   atr_ratio;    // ppm / InpAtrDailyRef (volatility multiple)
   PPM_ZONE zone;         // Efficiency classification
   datetime pivot_start;  // Start pivot time
   datetime pivot_end;    // End pivot time (most recent)
};

//==================================================================
// SECTION 4 — GLOBAL STATE
//==================================================================
static double           g_prices[BUFFER_SIZE];
static int              g_head    = 0;
static int              g_count   = 0;
static double           g_high    = 0.0;
static double           g_low     = 0.0;
static CANDLE_STRUCTURE g_candle;
static bool             g_candle_valid = false;
static PPM_RESULT       g_ppm;
static bool             g_ppm_valid    = false;

//==================================================================
// SECTION 5 — UTILITY: TIMEFRAME LABEL
//==================================================================
string TFLabel()
{
   string full = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(full, "PERIOD_", "");
   return full;
}

//==================================================================
// SECTION 6 — BAR GUARD
//==================================================================
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime cur = iTime(Symbol(), _Period, 0);
   if(cur != lastBarTime){ lastBarTime = cur; return true; }
   return false;
}

//==================================================================
// SECTION 7 — RANGE SCANNER: circular buffer
//==================================================================
void ScanHighLow()
{
   double h = -DBL_MAX;
   double l =  DBL_MAX;
   int limit = (g_count < InpWindowSize) ? g_count : InpWindowSize;
   for(int i = 0; i < limit; i++)
   {
      if(g_prices[i] > h) h = g_prices[i];
      if(g_prices[i] < l) l = g_prices[i];
   }
   g_high = (h == -DBL_MAX) ? 0.0 : h;
   g_low  = (l ==  DBL_MAX) ? 0.0 : l;
}

//==================================================================
// SECTION 8 — CANDLE ENGINE: helpers
//==================================================================
void CalcShades(CANDLE_STRUCTURE &c)
{
   if(c.close >= c.open)
   { c.shade_high = c.high - c.close; c.shade_low = c.open - c.low; }
   else
   { c.shade_high = c.high - c.open;  c.shade_low = c.close - c.low; }
}

double CalcAverageClose(const string sym, const ENUM_TIMEFRAMES per,
                        const datetime t, int ap)
{
   MqlRates rt[];
   ArraySetAsSeries(rt, false);
   double sum = 0.0;
   int n = CopyRates(sym, per, t, ap, rt);
   for(int i = 0; i < n; i++) sum += rt[i].close;
   ArrayFree(rt);
   return (n > 0) ? sum / n : 0.0;
}

double CalcAverageBody(const string sym, const ENUM_TIMEFRAMES per,
                       const datetime t, int ap)
{
   MqlRates rt[];
   ArraySetAsSeries(rt, false);
   double sum = 0.0;
   int n = CopyRates(sym, per, t, ap, rt);
   for(int i = 0; i < n; i++) sum += MathAbs(rt[i].close - rt[i].open);
   ArrayFree(rt);
   return (n > 0) ? sum / n : 0.0;
}

//==================================================================
// SECTION 9 — CANDLE ENGINE: main recognizer
//==================================================================
bool RecognizeCandle(const string sym, const ENUM_TIMEFRAMES per,
                     const datetime t, int ap, CANDLE_STRUCTURE &res)
{
   MqlRates rt[];
   ArraySetAsSeries(rt, false);
   if(CopyRates(sym, per, t, 1, rt) < 1) return false;

   res.open     = rt[0].open;
   res.close    = rt[0].close;
   res.high     = rt[0].high;
   res.low      = rt[0].low;
   res.bodysize = MathAbs(res.close - res.open);
   CalcShades(res);
   res.avg_close = CalcAverageClose(sym, per, t, ap);
   res.avg_body  = CalcAverageBody(sym, per, t, ap);
   ArrayFree(rt);

   // Priority chain (lower = base, higher = override)
   res.type = CAND_UNKNOWN;
   if(res.bodysize > res.avg_body * 1.3)                                                   res.type = CAND_LONG;
   if(res.bodysize < res.avg_body * 0.5)                                                   res.type = CAND_SHORT;
   double HL = res.high - res.low;
   if(HL > 0.0 && res.bodysize < HL * 0.03)                                               res.type = CAND_DOJI;
   if(res.bodysize > 0.0 && MathMin(res.shade_high, res.shade_low) / res.bodysize < 0.01) res.type = CAND_MARUBOZU;
   if(res.shade_low  > res.bodysize * 2.0 && res.shade_high < res.bodysize * 0.1)         res.type = CAND_HAMMER;
   if(res.shade_high > res.bodysize * 2.0 && res.shade_low  < res.bodysize * 0.1)         res.type = CAND_INVERTED_HAMMER;
   if(res.type == CAND_SHORT &&
      res.shade_low > res.bodysize && res.shade_high > res.bodysize)                       res.type = CAND_SPINNING_TOP;

   // Trend
   if(res.close > res.avg_close)      res.unit = TREND_UPPER;
   else if(res.close < res.avg_close) res.unit = TREND_DOWN;
   else                               res.unit = TREND_LATERAL;

   return true;
}

//==================================================================
// SECTION 10 — PPM ENGINE: ZigZag pivot scanner
//   PPM = pip distance / M1 candles elapsed
//   ZigZag parameters 2-2-1 per PPM strategy spec
//==================================================================
bool CalcPPM(PPM_RESULT &res)
{
   res.ppm       = 0.0;
   res.pips      = 0.0;
   res.candles   = 0;
   res.atr_ratio = 0.0;
   res.zone      = PPM_ZONE_NONE;

   int bars = MathMin(InpZzLookback, Bars - 1);
   if(bars < 4) return false;

   // Collect two most recent distinct ZigZag pivots (non-zero iCustom values)
   double pivot1 = 0.0, pivot2 = 0.0;
   int    bar1   = -1,  bar2   = -1;

   for(int i = 1; i <= bars; i++)
   {
      double zzVal = iCustom(Symbol(), PERIOD_M1, "ZigZag",
                             InpZzDepth, InpZzDeviation, InpZzBackstep,
                             0, i);
      if(zzVal != 0.0 && zzVal != EMPTY_VALUE)
      {
         if(bar1 < 0) { pivot1 = zzVal; bar1 = i; }
         else         { pivot2 = zzVal; bar2 = i; break; }
      }
   }

   if(bar1 < 0 || bar2 < 0) return false;

   double priceDist = MathAbs(pivot1 - pivot2);
   int    barDiff   = bar2 - bar1;  // M1 candles between pivots
   if(barDiff < 1) return false;

   double pipSize = (Digits == 3 || Digits == 5) ? Point * 10 : Point;
   double pips    = priceDist / pipSize;
   double ppm     = pips / (double)barDiff;

   res.pips        = pips;
   res.candles     = barDiff;
   res.ppm         = ppm;
   res.atr_ratio   = (InpAtrDailyRef > 0.0) ? ppm / InpAtrDailyRef : 0.0;
   res.pivot_start = iTime(Symbol(), PERIOD_M1, bar2);
   res.pivot_end   = iTime(Symbol(), PERIOD_M1, bar1);

   if(ppm >= InpPpmTarget)       res.zone = PPM_ZONE_HIGH;
   else if(ppm >= InpPpmMinHigh) res.zone = PPM_ZONE_MEDIUM;
   else                          res.zone = PPM_ZONE_LOW;

   return true;
}

//==================================================================
// SECTION 11 — PPM ZONE LABEL
//==================================================================
string PpmZoneName(PPM_ZONE z)
{
   switch(z)
   {
      case PPM_ZONE_HIGH:   return "HIGH [ENTER]";
      case PPM_ZONE_MEDIUM: return "MEDIUM [WATCH]";
      case PPM_ZONE_LOW:    return "LOW [AVOID]";
      default:              return "NO DATA";
   }
}

//==================================================================
// SECTION 12 — CANDLE TYPE & TREND LABELS
//==================================================================
string CandleTypeName(TYPE_CANDLESTICK tp)
{
   switch(tp)
   {
      case CAND_LONG:            return "Long";
      case CAND_SHORT:           return "Short";
      case CAND_DOJI:            return "Doji";
      case CAND_MARUBOZU:        return "Marubozu";
      case CAND_HAMMER:          return "Hammer";
      case CAND_INVERTED_HAMMER: return "InvertedHammer";
      case CAND_SPINNING_TOP:    return "SpinningTop";
      default:                   return "Unknown";
   }
}

string TrendName(TYPE_TREND u)
{
   switch(u)
   {
      case TREND_UPPER:   return "Ascending";
      case TREND_DOWN:    return "Descending";
      case TREND_LATERAL: return "Lateral";
      default:            return "Unknown";
   }
}

//==================================================================
// SECTION 13 — DISPLAY: merged dual-panel + PPM overlay
//==================================================================
void UpdateComment()
{
   string tf  = TFLabel();
   string msg = "=== OneMinuteMan v5.00 ===\n";
   msg += StringFormat("Symbol:%-6s  TF:%s\n", Symbol(), tf);

   // --- Range panel
   msg += "--- Range (1-min rolling) ---\n";
   msg += StringFormat("Window : %d s (%d samples @ %d ms)\n",
                       InpWindowSize * InpSampleMs / 1000,
                       InpWindowSize, InpSampleMs);
   msg += StringFormat("Filled : %d / %d\n", g_count, InpWindowSize);
   msg += StringFormat("High   : %.5f\n", g_high);
   msg += StringFormat("Low    : %.5f\n", g_low);
   msg += StringFormat("Range  : %.5f\n", g_high - g_low);
   msg += StringFormat("Ask    : %.5f\n", Ask);

   // --- Candle panel
   msg += "--- Last Closed Bar ---\n";
   if(g_candle_valid)
   {
      msg += StringFormat("Pattern: %s | Trend: %s\n",
                          CandleTypeName(g_candle.type),
                          TrendName(g_candle.unit));
      msg += StringFormat("Body   : %.5f  AvgBody: %.5f\n",
                          g_candle.bodysize, g_candle.avg_body);
      msg += StringFormat("OHLC   : %.5f / %.5f / %.5f / %.5f\n",
                          g_candle.open, g_candle.high,
                          g_candle.low,  g_candle.close);
      msg += StringFormat("ShadeH : %.5f  ShadeL: %.5f\n",
                          g_candle.shade_high, g_candle.shade_low);
   }
   else
      msg += "Waiting for first bar close...\n";

   // --- PPM panel
   if(InpShowPPM)
   {
      msg += "--- PPM Efficiency (M1 ZigZag 2-2-1) ---\n";
      if(g_ppm_valid)
      {
         msg += StringFormat("PPM    : %.2f  [min:%.1f target:%.1f]\n",
                             g_ppm.ppm, InpPpmMinHigh, InpPpmTarget);
         msg += StringFormat("Pips   : %.1f  Candles: %d\n",
                             g_ppm.pips, g_ppm.candles);
         msg += StringFormat("ATR x  : %.1f  (ATR ref: %.1f pip)\n",
                             g_ppm.atr_ratio, InpAtrDailyRef);
         msg += StringFormat("Zone   : %s\n", PpmZoneName(g_ppm.zone));
         msg += StringFormat("Pivot  : %s  >>  %s\n",
                             TimeToString(g_ppm.pivot_start, TIME_MINUTES),
                             TimeToString(g_ppm.pivot_end,   TIME_MINUTES));
      }
      else
         msg += "Calculating PPM...\n";
   }

   Comment(msg);
}

//==================================================================
// EA EVENT HANDLERS
//==================================================================
int OnInit()
{
   if(InpSampleMs < 10)
      { Print("Error: InpSampleMs must be >= 10"); return INIT_PARAMETERS_INCORRECT; }
   if(InpWindowSize < 60 || InpWindowSize > 20000)
      { Print("Error: InpWindowSize must be 60-20000"); return INIT_PARAMETERS_INCORRECT; }
   if(InpAverPeriod < 1 || InpAverPeriod > 500)
      { Print("Error: InpAverPeriod must be 1-500"); return INIT_PARAMETERS_INCORRECT; }
   if(InpZzDepth < 1 || InpZzBackstep < 1)
      { Print("Error: ZigZag params must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpZzBackstep >= InpZzDepth)
      { Print("Error: InpZzBackstep must be < InpZzDepth"); return INIT_PARAMETERS_INCORRECT; }

   ArrayResize(g_prices, BUFFER_SIZE);
   ArrayInitialize(g_prices, 0.0);

   if(!EventSetMillisecondTimer(InpSampleMs))
      { Print("Error: EventSetMillisecondTimer failed"); return INIT_FAILED; }

   Print("OneMinuteMan v5.00 initialized: ", Symbol(), " ", TFLabel(),
         " | ZZ:", InpZzDepth, "-", InpZzDeviation, "-", InpZzBackstep,
         " | PPM min:", InpPpmMinHigh, " target:", InpPpmTarget);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("OneMinuteMan stopped. Reason: ", reason);
}

// Timer: runs every InpSampleMs — samples Ask, updates rolling range + PPM
void OnTimer()
{
   RefreshRates();

   // Write Ask to circular buffer
   g_prices[g_head] = Ask;
   g_count = MathMin(g_count + 1, InpWindowSize);
   g_head  = (g_head + 1) % InpWindowSize;

   // Update rolling range
   ScanHighLow();

   // Refresh PPM on every timer tick (lightweight ZZ scan)
   PPM_RESULT ppmTmp;
   if(CalcPPM(ppmTmp))
   {
      g_ppm       = ppmTmp;
      g_ppm_valid = true;
   }

   UpdateComment();
}

// Tick: fires on each new price quote — recognizes last closed bar pattern
void OnTick()
{
   if(!IsNewBar()) return;

   CANDLE_STRUCTURE bar;
   if(RecognizeCandle(Symbol(), (ENUM_TIMEFRAMES)_Period,
                      iTime(Symbol(), _Period, 1),
                      InpAverPeriod, bar))
   {
      g_candle       = bar;
      g_candle_valid = true;

      Print(StringFormat("[%s] Candle:%s Trend:%s | Body=%.5f OHLC=%.5f/%.5f/%.5f/%.5f | PPM=%.2f Zone=%s",
            TFLabel(),
            CandleTypeName(bar.type),
            TrendName(bar.unit),
            bar.bodysize,
            bar.open, bar.high, bar.low, bar.close,
            g_ppm_valid ? g_ppm.ppm : 0.0,
            g_ppm_valid ? PpmZoneName(g_ppm.zone) : "N/A"));
   }
}
//+------------------------------------------------------------------+
