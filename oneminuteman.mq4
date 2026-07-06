//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                                     Copyright 2025, nhasibuan     |
//|                          https://github.com/nhasibuan/oneminuteman|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, nhasibuan"
#property link      "https://github.com/nhasibuan/oneminuteman"
#property version   "8.00"
#property strict
#property description "OneMinuteMan: forced-M1 range + candle + PPM engine with virtual hidden SL, volume filter, trailing stop, TP, and ADR-spaced martingale (SAME or REVERSE direction)"

//==================================================================
// SECTION 0 — ENUMERATIONS (declared first so inputs can use them)
//==================================================================
enum ENUM_MART_MODE
{
   MART_SAME_DIRECTION    = 0,  // Re-enter SAME direction as the losing trade
   MART_REVERSE_DIRECTION = 1   // Re-enter OPPOSITE direction (reverse martingale)
};

enum TYPE_CANDLESTICK
{
   CAND_UNKNOWN = 0,
   CAND_LONG,
   CAND_SHORT,
   CAND_DOJI,
   CAND_MARUBOZU,
   CAND_HAMMER,
   CAND_INVERTED_HAMMER,
   CAND_SPINNING_TOP,
   CAND_DRAGONFLY_DOJI,
   CAND_GRAVESTONE_DOJI,
   CAND_LONG_LEGGED_DOJI
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
   PPM_ZONE_NONE   = 0,  // No data
   PPM_ZONE_LOW,         // < InpPpmMinHigh  — avoid
   PPM_ZONE_MEDIUM,      // >= InpPpmMinHigh — acceptable
   PPM_ZONE_HIGH         // >= InpPpmTarget  — ideal, enter
};

//==================================================================
// SECTION 1 — INPUTS
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
//--- Volume Filter
input bool   InpUseVolumeFilter = true;  // Enable volume spike filter
input int    InpVolLookback     = 20;    // Bars for average volume calculation
input double InpVolMultiplier   = 1.5;   // Volume must be >= this x average to allow entry
//--- Trade Management (order execution)
input bool   InpEnableTrading = false;  // Master switch: allow live order execution
input double InpBaseLots      = 0.01;   // Base lot size for the first entry
input int    InpSlippage      = 0;      // Max slippage (points); 0 = auto per symbol
input int    InpMaxSpread     = 0;      // Max spread to allow entry (points); 0 = auto per symbol
input int    InpMagic         = 202506; // Magic number (position tag)
input double InpTP_Pips       = 0;      // Take profit (pips); 0 = auto per symbol
input double InpSL_Pips       = 0;      // Stop loss (pips); 0 = auto per symbol
input bool   InpHideSL        = true;   // Hide SL from broker terminal (virtual SL)
input double InpTrailStart    = 0;      // Trailing activation (pips); 0 = auto
input double InpTrailStep     = 0;      // Trailing distance (pips); 0 = auto
//--- Martingale Re-entry (ADR-spaced)
input bool          InpUseMartingale = true;                 // Re-open after a loss (martingale)
input ENUM_MART_MODE InpMartMode     = MART_SAME_DIRECTION;  // Re-entry direction mode (SAME / REVERSE)
input double        InpMartMult      = 2.0;                  // Lot multiplier per martingale step
input int           InpMartMaxSteps  = 5;                    // Max martingale steps per cycle
input int           InpAdrPeriod     = 14;                   // ADR averaging period (days)
input double        InpAdrFraction   = 0.10;                 // Re-entry spacing = fraction of ADR
//--- Trading Session (local time = UTC + InpTzOffsetHours)
input int    InpTzOffsetHours    = 7;   // Local timezone offset from UTC (UTC+7)
input int    InpSessionStartHour = 5;   // Local hour to (re)start trading (Sydney~5 / Tokyo~7)
input int    InpSessionEndHour   = 24;  // Local hour to stop opening trades (24 = end of day)

//==================================================================
// SECTION 2 — CONSTANTS & BUFFER
//==================================================================
#define BUFFER_SIZE   1202
#define MAX_POSITIONS 20      // max simultaneous tracked virtual SL positions

//--- Candle-recognition tuning constants (named for readability)
const double LONG_BODY_FACTOR   = 1.3;   // body > avg_body * this => Long
const double SHORT_BODY_FACTOR  = 0.5;   // body < avg_body * this => Short
const double DOJI_BODY_FACTOR   = 0.03;  // body < range * this     => Doji
const double MARUBOZU_SHADE     = 0.01;  // min shade / body < this => Marubozu
const double HAMMER_SHADE       = 2.0;   // long shade > body * this
const double HAMMER_OPP_SHADE   = 0.1;   // opposite shade < body * this
const double DOJI_TINY_FRACTION = 0.1;   // tiny shade threshold within a doji

//==================================================================
// SECTION 3 — STRUCTURES
//==================================================================
struct CANDLE_STRUCTURE
{
   TYPE_CANDLESTICK  type;
   TYPE_TREND        unit;
   double            bodysize;
   double            shade_high;
   double            shade_low;
   double            avg_close;
   double            avg_body;
   double            open;
   double            high;
   double            low;
   double            close;
};

struct PPM_RESULT
{
   double            ppm;          // Pips-per-minute efficiency
   double            pips;         // Pip distance of last ZZ leg
   int               candles;      // M1 candles in last ZZ leg
   double            atr_ratio;    // ppm / InpAtrDailyRef (volatility multiple)
   PPM_ZONE          zone;         // Efficiency classification
   datetime          pivot_start;  // Start pivot time
   datetime          pivot_end;    // End pivot time (most recent)
};

// Virtual SL tracker — one entry per open position
struct VSL_ENTRY
{
   int               ticket;
   int               dir;        // +1 buy, -1 sell
   double            vsl_price;  // virtual stop loss price level
   bool              active;
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
//--- Trade state
static bool     g_had_pos       = false;
static int      g_last_dir      = 0;     // +1 long, -1 short
static double   g_last_entry    = 0.0;
static double   g_last_lots     = 0.0;
static int      g_mart_step     = 0;
static bool     g_await_reentry = false;
static double   g_adr_pips      = 0.0;
static datetime g_halt_until     = 0;
static bool     g_trading_halted = false;
//--- Virtual SL tracker
static VSL_ENTRY g_vsl[MAX_POSITIONS];
static int       g_vsl_count = 0;

//==================================================================
// SECTION 5 — UTILITY: LABELS
//==================================================================
string TFLabel()
{
   string full = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(full, "PERIOD_", "");
   return full;
}

string MartModeName(ENUM_MART_MODE m)
{
   return (m == MART_REVERSE_DIRECTION) ? "REVERSE" : "SAME";
}

//==================================================================
// SECTION 6 — BAR GUARD
//==================================================================
bool IsNewBar()
{
   // Forced M1: fire once per M1 bar regardless of the chart timeframe.
   static datetime lastBarTime = 0;
   datetime cur = iTime(Symbol(), PERIOD_M1, 0);
   if(cur != lastBarTime)
   {
      lastBarTime = cur;
      return true;
   }
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
   for(int i = 0; i < n; i++)
      sum += rt[i].close;
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
   for(int i = 0; i < n; i++)
      sum += MathAbs(rt[i].close - rt[i].open);
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
   if(CopyRates(sym, per, t, 1, rt) < 1)
      return false;

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
   if(res.bodysize > res.avg_body * LONG_BODY_FACTOR)
      res.type = CAND_LONG;
   if(res.bodysize < res.avg_body * SHORT_BODY_FACTOR)
      res.type = CAND_SHORT;
   double HL = res.high - res.low;
   if(HL > 0.0 && res.bodysize < HL * DOJI_BODY_FACTOR)
      res.type = CAND_DOJI;
   if(res.bodysize > 0.0 && MathMin(res.shade_high, res.shade_low) / res.bodysize < MARUBOZU_SHADE)
      res.type = CAND_MARUBOZU;
   if(res.shade_low  > res.bodysize * HAMMER_SHADE && res.shade_high < res.bodysize * HAMMER_OPP_SHADE)
      res.type = CAND_HAMMER;
   if(res.shade_high > res.bodysize * HAMMER_SHADE && res.shade_low  < res.bodysize * HAMMER_OPP_SHADE)
      res.type = CAND_INVERTED_HAMMER;
   if(res.type == CAND_SHORT &&
      res.shade_low > res.bodysize && res.shade_high > res.bodysize)
      res.type = CAND_SPINNING_TOP;

   // Doji sub-classification
   if(res.type == CAND_DOJI)
   {
      double rng  = res.high - res.low;
      double tiny = rng * DOJI_TINY_FRACTION;
      if(res.shade_low > 2.0 * res.shade_high && res.shade_high <= tiny)
         res.type = CAND_DRAGONFLY_DOJI;
      else if(res.shade_high > 2.0 * res.shade_low && res.shade_low <= tiny)
         res.type = CAND_GRAVESTONE_DOJI;
      else if(res.shade_high > tiny && res.shade_low > tiny)
         res.type = CAND_LONG_LEGGED_DOJI;
   }

   // Trend
   if(res.close > res.avg_close)
      res.unit = TREND_UPPER;
   else if(res.close < res.avg_close)
      res.unit = TREND_DOWN;
   else
      res.unit = TREND_LATERAL;

   return true;
}

//==================================================================
// SECTION 10 — PPM ENGINE: ZigZag pivot scanner
//==================================================================
bool CalcPPM(PPM_RESULT &res)
{
   res.ppm = 0.0; res.pips = 0.0; res.candles = 0;
   res.atr_ratio = 0.0; res.zone = PPM_ZONE_NONE;

   int bars = MathMin(InpZzLookback, Bars - 1);
   if(bars < 4)
      return false;

   double pivot1 = 0.0, pivot2 = 0.0;
   int    bar1   = -1,  bar2   = -1;

   for(int i = 1; i <= bars; i++)
   {
      double zzVal = iCustom(Symbol(), PERIOD_M1, "ZigZag",
                             InpZzDepth, InpZzDeviation, InpZzBackstep, 0, i);
      if(zzVal != 0.0 && zzVal != EMPTY_VALUE)
      {
         if(bar1 < 0) { pivot1 = zzVal; bar1 = i; }
         else         { pivot2 = zzVal; bar2 = i; break; }
      }
   }

   if(bar1 < 0 || bar2 < 0)
      return false;

   double priceDist = MathAbs(pivot1 - pivot2);
   int    barDiff   = bar2 - bar1;
   if(barDiff < 1)
      return false;

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
// SECTION 11 — LABELS: PPM / candle / trend
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
      case CAND_DRAGONFLY_DOJI:  return "DragonflyDoji";
      case CAND_GRAVESTONE_DOJI: return "GravestoneDoji";
      case CAND_LONG_LEGGED_DOJI:return "LongLeggedDoji";
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
// SECTION 12 — TRADE MODULE: pip / symbol helpers
//==================================================================
double PipSize()
{
   return (Digits == 3 || Digits == 5) ? Point * 10 : Point;
}

double PipToPrice(double pips)
{
   return pips * PipSize();
}

void GetSymbolProfile(double &tp, double &sl, double &trailStart, double &trailStep)
{
   string s = Symbol();
   if(StringFind(s, "XAU") >= 0)                                   // Gold (pip = 0.01)
   { tp = 150; sl = 250; trailStart = 100; trailStep = 50; }
   else if(StringFind(s, "EUR") >= 0 && StringFind(s, "USD") >= 0) // EUR/USD
   { tp = 6;   sl = 8;   trailStart = 5;   trailStep = 3;  }
   else                                                            // generic FX
   { tp = 10;  sl = 15;  trailStart = 8;   trailStep = 5;  }
}

void ResolveTradeParams(double &tp, double &sl, double &trailStart, double &trailStep)
{
   double atp, asl, ats, atstep;
   GetSymbolProfile(atp, asl, ats, atstep);
   tp         = (InpTP_Pips    > 0.0) ? InpTP_Pips    : atp;
   sl         = (InpSL_Pips    > 0.0) ? InpSL_Pips    : asl;
   trailStart = (InpTrailStart > 0.0) ? InpTrailStart : ats;
   trailStep  = (InpTrailStep  > 0.0) ? InpTrailStep  : atstep;
}

void GetSymbolExec(int &slippage, int &maxSpread)
{
   string s = Symbol();
   if(StringFind(s, "XAU") >= 0)
   { slippage = 30; maxSpread = 50; }
   else if(StringFind(s, "EUR") >= 0 && StringFind(s, "USD") >= 0)
   { slippage = 5;  maxSpread = 15; }
   else
   { slippage = 10; maxSpread = 25; }
}

int EffSlippage()
{
   int sl, ms; GetSymbolExec(sl, ms);
   return (InpSlippage > 0) ? InpSlippage : sl;
}

int EffMaxSpread()
{
   int sl, ms; GetSymbolExec(sl, ms);
   return (InpMaxSpread > 0) ? InpMaxSpread : ms;
}

bool SpreadOK()
{
   int spr = (int)MathRound((Ask - Bid) / Point);
   int mx  = EffMaxSpread();
   return (mx <= 0 || spr <= mx);
}

//==================================================================
// SECTION 13 — TRADE MODULE: session / ADR
//==================================================================
datetime LocalNow()
{
   return (datetime)(TimeGMT() + InpTzOffsetHours * 3600);
}

bool InSession()
{
   int hr   = TimeHour(LocalNow());
   int endh = (InpSessionEndHour <= InpSessionStartHour) ? 24 : InpSessionEndHour;
   return (hr >= InpSessionStartHour && hr < endh);
}

void HaltForToday()
{
   datetime loc      = LocalNow();
   datetime dayStart = loc - (loc % 86400);
   g_halt_until      = dayStart + 86400 + InpSessionStartHour * 3600;
   g_trading_halted  = true;
   Print("Martingale cycle maxed -> halt until next session open (local ", TimeToString(g_halt_until), ")");
}

bool TradingWindowOpen()
{
   if(g_trading_halted)
   {
      if(LocalNow() >= g_halt_until) g_trading_halted = false;
      else                          return false;
   }
   return InSession();
}

double CalcADR()
{
   double sum = 0.0;
   int cnt = 0;
   for(int i = 1; i <= InpAdrPeriod; i++)
   {
      double hi = iHigh(Symbol(), PERIOD_D1, i);
      double lo = iLow(Symbol(),  PERIOD_D1, i);
      if(hi > 0.0 && lo > 0.0) { sum += (hi - lo); cnt++; }
   }
   if(cnt == 0) return 0.0;
   return (sum / cnt) / PipSize();
}

double NormalizeLots(double lots)
{
   double minlot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxlot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   if(lots < minlot) lots = minlot;
   if(lots > maxlot) lots = maxlot;
   return NormalizeDouble(lots, 2);
}

//==================================================================
// SECTION 14 — TRADE MODULE: volume filter & signal
//==================================================================
bool VolumeOK()
{
   if(!InpUseVolumeFilter) return true;
   if(InpVolLookback < 2)  return true;

   long vol_last = iVolume(Symbol(), PERIOD_M1, 1);
   if(vol_last <= 0) return true;  // no volume data — pass through

   long vol_sum = 0;
   int  n       = 0;
   for(int i = 1; i <= InpVolLookback; i++)
   {
      long v = iVolume(Symbol(), PERIOD_M1, i);
      if(v > 0) { vol_sum += v; n++; }
   }
   if(n == 0) return true;
   double vol_avg = (double)vol_sum / n;
   return (vol_last >= vol_avg * InpVolMultiplier);
}

// Signal direction from candle: +1 long, -1 short, 0 none
int SignalDirection(const CANDLE_STRUCTURE &c)
{
   if(c.type == CAND_HAMMER)          return +1;  // bullish reversal
   if(c.type == CAND_DRAGONFLY_DOJI)  return +1;  // bullish reversal
   if(c.type == CAND_INVERTED_HAMMER) return -1;  // bearish reversal
   if(c.type == CAND_GRAVESTONE_DOJI) return -1;  // bearish reversal
   if(c.unit == TREND_UPPER && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return +1;
   if(c.unit == TREND_DOWN  && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return -1;
   return 0;
}

//==================================================================
// SECTION 15 — TRADE MODULE: position accounting
//==================================================================
int CountPositions()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic &&
         (OrderType() == OP_BUY || OrderType() == OP_SELL))
         n++;
   }
   return n;
}

double LastClosedProfit()
{
   datetime best = 0;
   double prof = 0.0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() > best)
      { best = OrderCloseTime(); prof = OrderProfit() + OrderSwap() + OrderCommission(); }
   }
   return prof;
}

//==================================================================
// SECTION 16 — VIRTUAL SL MANAGEMENT
//==================================================================
void VslRegister(int ticket, int dir, double vslPrice)
{
   for(int i = 0; i < g_vsl_count; i++)
   {
      if(g_vsl[i].ticket == ticket) { g_vsl[i].vsl_price = vslPrice; return; }
   }
   if(g_vsl_count >= MAX_POSITIONS) return;
   g_vsl[g_vsl_count].ticket    = ticket;
   g_vsl[g_vsl_count].dir       = dir;
   g_vsl[g_vsl_count].vsl_price = vslPrice;
   g_vsl[g_vsl_count].active    = true;
   g_vsl_count++;
}

void VslRemove(int ticket)
{
   for(int i = 0; i < g_vsl_count; i++)
   {
      if(g_vsl[i].ticket == ticket)
      {
         for(int j = i; j < g_vsl_count - 1; j++)
            g_vsl[j] = g_vsl[j+1];
         g_vsl_count--;
         return;
      }
   }
}

void VslCheck()
{
   if(!InpHideSL) return;
   for(int i = g_vsl_count - 1; i >= 0; i--)
   {
      if(!g_vsl[i].active) continue;
      bool triggered = false;
      if(g_vsl[i].dir > 0 && Bid <= g_vsl[i].vsl_price) triggered = true;  // buy hit SL
      if(g_vsl[i].dir < 0 && Ask >= g_vsl[i].vsl_price) triggered = true;  // sell hit SL
      if(!triggered) continue;

      if(OrderSelect(g_vsl[i].ticket, SELECT_BY_TICKET))
      {
         if(OrderCloseTime() == 0)  // still open
         {
            double closePrice = (g_vsl[i].dir > 0) ? Bid : Ask;
            if(!OrderClose(g_vsl[i].ticket, OrderLots(), closePrice, EffSlippage(), clrOrange))
               Print("VslCheck: OrderClose failed ticket=", g_vsl[i].ticket, " err=", GetLastError());
         }
      }
      VslRemove(g_vsl[i].ticket);
   }
}

//==================================================================
// SECTION 17 — TRADE MODULE: order execution & trailing
//==================================================================
bool OpenTrade(int dir, double lots)
{
   double tp, sl, ts, tstep;
   ResolveTradeParams(tp, sl, ts, tstep);

   double price   = (dir > 0) ? Ask : Bid;
   double stopLvl = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double slDist  = MathMax(PipToPrice(sl), stopLvl);
   double tpDist  = MathMax(PipToPrice(tp), stopLvl);

   double slPrice = (dir > 0) ? price - slDist : price + slDist;
   double tpPrice = (dir > 0) ? price + tpDist : price - tpDist;
   int    type    = (dir > 0) ? OP_BUY : OP_SELL;

   // When hiding SL: send 0 for stop loss in the order; track internally.
   double orderSL = InpHideSL ? 0.0 : NormalizeDouble(slPrice, Digits);

   int ticket = OrderSend(Symbol(), type, lots, NormalizeDouble(price, Digits),
                          EffSlippage(), orderSL, NormalizeDouble(tpPrice, Digits),
                          "OneMinuteMan", InpMagic, 0,
                          (dir > 0) ? clrBlue : clrRed);
   if(ticket < 0)
   {
      Print("OrderSend failed: err=", GetLastError());
      return false;
   }

   if(InpHideSL)
      VslRegister(ticket, dir, NormalizeDouble(slPrice, Digits));

   return true;
}

void ManageTrailing()
{
   double tp, sl, ts, tstep;
   ResolveTradeParams(tp, sl, ts, tstep);
   double ps = PipSize();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;

      if(OrderType() == OP_BUY)
      {
         double gained = (Bid - OrderOpenPrice()) / ps;
         if(gained >= ts)
         {
            double newSL = NormalizeDouble(Bid - PipToPrice(tstep), Digits);
            if(InpHideSL)
            {
               for(int v = 0; v < g_vsl_count; v++)
                  if(g_vsl[v].ticket == OrderTicket() && newSL > g_vsl[v].vsl_price)
                  { g_vsl[v].vsl_price = newSL; break; }
            }
            else
            {
               if(newSL > OrderStopLoss())
                  OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen);
            }
         }
      }
      else if(OrderType() == OP_SELL)
      {
         double gained = (OrderOpenPrice() - Ask) / ps;
         if(gained >= ts)
         {
            double newSL = NormalizeDouble(Ask + PipToPrice(tstep), Digits);
            if(InpHideSL)
            {
               for(int v = 0; v < g_vsl_count; v++)
                  if(g_vsl[v].ticket == OrderTicket() && (g_vsl[v].vsl_price == 0.0 || newSL < g_vsl[v].vsl_price))
                  { g_vsl[v].vsl_price = newSL; break; }
            }
            else
            {
               if(OrderStopLoss() == 0.0 || newSL < OrderStopLoss())
                  OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen);
            }
         }
      }
   }
}

//==================================================================
// SECTION 18 — TRADE MODULE: cycle state & entries
//==================================================================
// Detect a just-closed cycle and arm martingale after a loss
void UpdateTradeState()
{
   int n = CountPositions();
   if(n == 0 && g_had_pos)
   {
      double profit = LastClosedProfit();
      if(profit < 0.0 && InpUseMartingale && g_mart_step < InpMartMaxSteps)
         g_await_reentry = true;
      else
      {
         if(profit < 0.0 && InpUseMartingale && g_mart_step >= InpMartMaxSteps)
            HaltForToday();
         g_await_reentry = false;
         g_mart_step     = 0;
      }
   }
   g_had_pos = (n > 0);
}

// Resolve the martingale re-entry direction based on the selected mode.
//  - SAME    : trade the same direction as the losing trade (classic martingale)
//  - REVERSE : trade the opposite direction (reverse martingale). Each
//              subsequent step flips again because g_last_dir is updated.
int ResolveMartingaleDir()
{
   return (InpMartMode == MART_REVERSE_DIRECTION) ? -g_last_dir : g_last_dir;
}

// Fresh entries + ADR-spaced martingale re-entry
void ManageEntries(bool allowFresh)
{
   if(!InpEnableTrading)     return;
   if(CountPositions() > 0)  return;
   if(!TradingWindowOpen())  return;
   if(!SpreadOK())           return;

   // Martingale re-entry, triggered after price has moved adversely by
   // >= InpAdrFraction x ADR pips relative to the previous losing entry.
   if(g_await_reentry && InpUseMartingale && g_mart_step < InpMartMaxSteps)
   {
      double adr     = (g_adr_pips > 0.0) ? g_adr_pips : CalcADR();
      double reentry = InpAdrFraction * adr;
      double adverse = (g_last_dir > 0) ? (g_last_entry - Bid) / PipSize()
                                        : (Ask - g_last_entry) / PipSize();
      if(reentry > 0.0 && adverse >= reentry)
      {
         int    reDir = ResolveMartingaleDir();   // SAME or REVERSE per InpMartMode
         double lots  = NormalizeLots(g_last_lots * InpMartMult);
         if(OpenTrade(reDir, lots))
         {
            g_mart_step++;
            g_last_dir      = reDir;   // track new direction (enables alternating in REVERSE mode)
            g_last_lots     = lots;
            g_last_entry    = (reDir > 0) ? Ask : Bid;
            g_await_reentry = false;
         }
      }
      return;
   }

   // Fresh signal (once per new M1 bar): PPM gate + candle + volume
   if(!allowFresh)                   return;
   if(!g_candle_valid || !g_ppm_valid) return;
   if(g_ppm.zone < PPM_ZONE_MEDIUM)  return;
   if(!VolumeOK())                   return;

   int dir = SignalDirection(g_candle);
   if(dir == 0) return;

   double lots = NormalizeLots(InpBaseLots);
   if(OpenTrade(dir, lots))
   {
      g_mart_step     = 1;
      g_last_dir      = dir;
      g_last_lots     = lots;
      g_last_entry    = (dir > 0) ? Ask : Bid;
      g_await_reentry = false;
   }
}

//==================================================================
// SECTION 19 — DISPLAY
//==================================================================
void UpdateComment()
{
   string tf  = TFLabel();
   string msg = "=== OneMinuteMan v8.00 ===\n";
   msg += StringFormat("Symbol:%-6s  Engines:M1 (forced)  Chart:%s\n", Symbol(), tf);

   // --- Range panel
   msg += "--- Range (1-min rolling) ---\n";
   msg += StringFormat("Window : %d s (%d samples @ %d ms)\n",
                       InpWindowSize * InpSampleMs / 1000, InpWindowSize, InpSampleMs);
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
                          CandleTypeName(g_candle.type), TrendName(g_candle.unit));
      msg += StringFormat("Body   : %.5f  AvgBody: %.5f\n", g_candle.bodysize, g_candle.avg_body);
      msg += StringFormat("OHLC   : %.5f / %.5f / %.5f / %.5f\n",
                          g_candle.open, g_candle.high, g_candle.low, g_candle.close);
      msg += StringFormat("ShadeH : %.5f  ShadeL: %.5f\n", g_candle.shade_high, g_candle.shade_low);
   }
   else msg += "Waiting for first bar close...\n";

   // --- PPM panel
   if(InpShowPPM)
   {
      msg += "--- PPM Efficiency (M1 ZigZag 2-2-1) ---\n";
      if(g_ppm_valid)
      {
         msg += StringFormat("PPM    : %.2f  [min:%.1f target:%.1f]\n",
                             g_ppm.ppm, InpPpmMinHigh, InpPpmTarget);
         msg += StringFormat("Pips   : %.1f  Candles: %d\n", g_ppm.pips, g_ppm.candles);
         msg += StringFormat("ATR x  : %.1f  (ATR ref: %.1f pip)\n", g_ppm.atr_ratio, InpAtrDailyRef);
         msg += StringFormat("Zone   : %s\n", PpmZoneName(g_ppm.zone));
         msg += StringFormat("Pivot  : %s  >>  %s\n",
                             TimeToString(g_ppm.pivot_start, TIME_MINUTES),
                             TimeToString(g_ppm.pivot_end,   TIME_MINUTES));
      }
      else msg += "Calculating PPM...\n";
   }

   // --- Volume filter status
   if(InpUseVolumeFilter)
   {
      long vol_last = iVolume(Symbol(), PERIOD_M1, 1);
      long vol_sum  = 0; int vn = 0;
      for(int i = 1; i <= InpVolLookback; i++)
      {
         long v = iVolume(Symbol(), PERIOD_M1, i);
         if(v > 0) { vol_sum += v; vn++; }
      }
      double vol_avg = (vn > 0) ? (double)vol_sum / vn : 0.0;
      msg += StringFormat("--- Volume Filter ---\nVol(last):%d  Avg:%d  Req:x%.1f  %s\n",
                          (int)vol_last, (int)vol_avg, InpVolMultiplier,
                          VolumeOK() ? "[PASS]" : "[SUPPRESS]");
   }

   // --- Trade panel
   msg += "--- Trade / Money Mgmt ---\n";
   {
      double tp, sl, ts, tstep;
      ResolveTradeParams(tp, sl, ts, tstep);
      msg += StringFormat("Trading: %s  Magic:%d  HideSL:%s\n",
                          InpEnableTrading ? "ON" : "OFF", InpMagic, InpHideSL ? "ON" : "OFF");
      msg += StringFormat("TP:%.0f SL:%.0f Trail:%.0f/%.0f pips\n", tp, sl, ts, tstep);
   }
   msg += StringFormat("Open:%d  Mart:%d/%d (%s) %s\n",
                       CountPositions(), g_mart_step, InpMartMaxSteps,
                       MartModeName(InpMartMode),
                       g_await_reentry ? "[AWAIT RE-ENTRY]" : "");
   msg += StringFormat("ADR:%.0f pips  Re-entry@%.0f pips\n",
                       g_adr_pips, InpAdrFraction * g_adr_pips);
   if(InpHideSL && g_vsl_count > 0)
      msg += StringFormat("VSL tracking: %d position(s)\n", g_vsl_count);
   msg += StringFormat("Session: %s (UTC+%d %dh-%dh)  Spread<=%d\n",
                       (TradingWindowOpen() ? "OPEN" : (g_trading_halted ? "HALTED" : "CLOSED")),
                       InpTzOffsetHours, InpSessionStartHour, InpSessionEndHour, EffMaxSpread());
   if(g_trading_halted)
      msg += StringFormat("Resume : %s (local)\n", TimeToString(g_halt_until));

   Comment(msg);
}

//==================================================================
// SECTION 20 — EA EVENT HANDLERS
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
   if(InpBaseLots <= 0.0)
   { Print("Error: InpBaseLots must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUseMartingale && (InpMartMult < 1.0 || InpMartMaxSteps < 1))
   { Print("Error: martingale needs InpMartMult >= 1.0 and InpMartMaxSteps >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpAdrPeriod < 1)
   { Print("Error: InpAdrPeriod must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpAdrFraction <= 0.0)
   { Print("Error: InpAdrFraction must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23)
   { Print("Error: InpSessionStartHour must be 0-23"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionEndHour < 1 || InpSessionEndHour > 24)
   { Print("Error: InpSessionEndHour must be 1-24"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUseVolumeFilter && InpVolLookback < 2)
   { Print("Error: InpVolLookback must be >= 2"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUseVolumeFilter && InpVolMultiplier <= 0.0)
   { Print("Error: InpVolMultiplier must be > 0"); return INIT_PARAMETERS_INCORRECT; }

   ArrayResize(g_prices, BUFFER_SIZE);
   ArrayInitialize(g_prices, 0.0);
   g_vsl_count = 0;

   // Pre-load ADR so martingale spacing is available from the first tick
   g_adr_pips = CalcADR();

   if(!EventSetMillisecondTimer(InpSampleMs))
   { Print("Error: EventSetMillisecondTimer failed"); return INIT_FAILED; }

   Print("OneMinuteMan v8.00 initialized: ", Symbol(), " (engines forced to M1)",
         " | ZZ:", InpZzDepth, "-", InpZzDeviation, "-", InpZzBackstep,
         " | PPM min:", InpPpmMinHigh, " target:", InpPpmTarget,
         " | HideSL:", (InpHideSL ? "ON" : "OFF"),
         " | VolFilter:", (InpUseVolumeFilter ? "ON" : "OFF"),
         " | Trading:", (InpEnableTrading ? "ON" : "OFF"),
         " Martingale:", (InpUseMartingale ? "ON" : "OFF"),
         " Mode:", MartModeName(InpMartMode),
         " | Session UTC+", InpTzOffsetHours, " ", InpSessionStartHour, "h-", InpSessionEndHour, "h",
         " | ADR=", g_adr_pips, " pips");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("OneMinuteMan v8.00 stopped. Reason: ", reason);
}

void OnTimer()
{
   RefreshRates();

   g_prices[g_head] = Ask;
   g_count = MathMin(g_count + 1, InpWindowSize);
   g_head  = (g_head + 1) % InpWindowSize;

   ScanHighLow();

   PPM_RESULT ppmTmp;
   if(CalcPPM(ppmTmp)) { g_ppm = ppmTmp; g_ppm_valid = true; }

   // ADR is recomputed once per new M1 bar (see OnTick), not every 50ms timer tick.
   ManageTrailing();
   VslCheck();     // enforce virtual SL on every timer tick for fast response

   UpdateComment();
}

void OnTick()
{
   bool newBar = IsNewBar();

   if(newBar)
   {
      // Clean-code/perf: refresh ADR once per bar instead of every 50ms timer tick.
      g_adr_pips = CalcADR();

      CANDLE_STRUCTURE bar;
      if(RecognizeCandle(Symbol(), PERIOD_M1, iTime(Symbol(), PERIOD_M1, 1), InpAverPeriod, bar))
      {
         g_candle       = bar;
         g_candle_valid = true;

         Print(StringFormat("[M1] Candle:%s Trend:%s | Body=%.5f OHLC=%.5f/%.5f/%.5f/%.5f | PPM=%.2f Zone=%s | Vol:%s",
               CandleTypeName(bar.type), TrendName(bar.unit), bar.bodysize,
               bar.open, bar.high, bar.low, bar.close,
               g_ppm_valid ? g_ppm.ppm : 0.0,
               g_ppm_valid ? PpmZoneName(g_ppm.zone) : "N/A",
               VolumeOK() ? "PASS" : "LOW"));
      }
   }

   UpdateTradeState();
   ManageTrailing();
   VslCheck();     // also check on every tick for tight stop enforcement
   ManageEntries(newBar);
}
//+------------------------------------------------------------------+