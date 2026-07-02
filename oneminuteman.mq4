//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                                     Copyright 2025, nhasibuan    |
//|                          https://github.com/nhasibuan/oneminuteman|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, nhasibuan"
#property link      "https://github.com/nhasibuan/oneminuteman"
#property version   "6.00"
#property strict
#property description "OneMinuteMan: forced-M1 range + candle + PPM engine with trade execution, trailing stop, TP, and ADR-spaced martingale"

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
//--- Trade Management (order execution)
input bool   InpEnableTrading = false;  // Master switch: allow live order execution
input double InpBaseLots      = 0.01;   // Base lot size for the first entry
input int    InpSlippage      = 0;      // Max slippage (points); 0 = auto per symbol
input int    InpMaxSpread     = 0;      // Max spread to allow entry (points); 0 = auto per symbol
input int    InpMagic         = 202506; // Magic number (position tag)
input double InpTP_Pips       = 0;      // Take profit (pips); 0 = auto per symbol
input double InpSL_Pips       = 0;      // Stop loss (pips); 0 = auto per symbol
input bool   InpHiddenSL      = false;  // Hide SL from broker (virtual/monitored SL)
input double InpTrailStart    = 0;      // Trailing activation (pips); 0 = auto
input double InpTrailStep     = 0;      // Trailing distance (pips); 0 = auto
//--- Volume-based entry confirmation
input bool   InpUseVolumeFilter = false; // Require above-average tick volume to enter
input int    InpVolLookback     = 20;    // Bars to average tick volume against
//--- Martingale Re-entry (ADR-spaced)
input bool   InpUseMartingale = true;   // Re-open after a loss (martingale)
input double InpMartMult      = 2.0;    // Lot multiplier per martingale step
input int    InpMartMaxSteps  = 5;      // Max martingale steps per cycle
input int    InpAdrPeriod     = 14;     // ADR averaging period (days)
input double InpAdrFraction   = 0.10;   // Re-entry spacing = fraction of ADR
//--- Trading Session (local time = UTC + InpTzOffsetHours)
input int    InpTzOffsetHours    = 7;   // Local timezone offset from UTC (UTC+7)
input int    InpSessionStartHour = 5;   // Local hour to (re)start trading (Sydney~5 / Tokyo~7)
input int    InpSessionEndHour   = 24;  // Local hour to stop opening trades (24 = end of day)

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
//--- Trade state
static bool    g_had_pos       = false;
static int     g_last_dir      = 0;     // +1 long, -1 short
static double  g_last_entry    = 0.0;
static double  g_last_lots     = 0.0;
static int     g_mart_step     = 0;
static bool    g_await_reentry = false;
static double  g_adr_pips      = 0.0;
static datetime g_halt_until     = 0;
static bool     g_trading_halted = false;
static double  g_hidden_sl_price = 0.0;  // Virtual SL level tracked when InpHiddenSL is on

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
   // Forced M1: fire once per M1 bar regardless of the chart timeframe.
   static datetime lastBarTime = 0;
   datetime cur = iTime(Symbol(), PERIOD_M1, 0);
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

   // Doji sub-classification: refine a detected Doji by shadow distribution
   if(res.type == CAND_DOJI)
   {
      double rng  = res.high - res.low;
      double tiny = rng * 0.1;
      if(res.shade_low > 2.0 * res.shade_high && res.shade_high <= tiny)
         res.type = CAND_DRAGONFLY_DOJI;
      else if(res.shade_high > 2.0 * res.shade_low && res.shade_low <= tiny)
         res.type = CAND_GRAVESTONE_DOJI;
      else if(res.shade_high > tiny && res.shade_low > tiny)
         res.type = CAND_LONG_LEGGED_DOJI;
   }

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
// SECTION 13 — TRADE MODULE (orders, trailing stop, ADR martingale)
//==================================================================
double PipSize()
{
   return (Digits == 3 || Digits == 5) ? Point * 10 : Point;
}

double PipToPrice(double pips)
{
   return pips * PipSize();
}

// Per-symbol recommended defaults (in EA "pips"). Auto-selected by symbol name.
void GetSymbolProfile(double &tp, double &sl, double &trailStart, double &trailStep)
{
   string s = Symbol();
   if(StringFind(s, "XAU") >= 0)                                  // Gold (pip = 0.01)
      { tp = 150; sl = 250; trailStart = 100; trailStep = 50; }
   else if(StringFind(s, "EUR") >= 0 && StringFind(s, "USD") >= 0) // EUR/USD
      { tp = 6;   sl = 8;   trailStart = 5;   trailStep = 3;  }
   else                                                            // generic FX
      { tp = 10;  sl = 15;  trailStart = 8;   trailStep = 5;  }
}

// Effective params: explicit input overrides, else per-symbol auto profile
void ResolveTradeParams(double &tp, double &sl, double &trailStart, double &trailStep)
{
   double atp, asl, ats, atstep;
   GetSymbolProfile(atp, asl, ats, atstep);
   tp         = (InpTP_Pips    > 0.0) ? InpTP_Pips    : atp;
   sl         = (InpSL_Pips    > 0.0) ? InpSL_Pips    : asl;
   trailStart = (InpTrailStart > 0.0) ? InpTrailStart : ats;
   trailStep  = (InpTrailStep  > 0.0) ? InpTrailStep  : atstep;
}

// Per-symbol execution defaults: slippage & max allowed spread (points)
void GetSymbolExec(int &slippage, int &maxSpread)
{
   string s = Symbol();
   if(StringFind(s, "XAU") >= 0)                                  // Gold
      { slippage = 30; maxSpread = 50; }
   else if(StringFind(s, "EUR") >= 0 && StringFind(s, "USD") >= 0) // EUR/USD
      { slippage = 5;  maxSpread = 15; }
   else                                                            // generic FX
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

// Local time = broker GMT + configured offset (UTC+7 by default)
datetime LocalNow()
{
   return (datetime)(TimeGMT() + InpTzOffsetHours * 3600);
}

// True while inside the daily trading window (local hours)
bool InSession()
{
   int hr   = TimeHour(LocalNow());
   int endh = (InpSessionEndHour <= InpSessionStartHour) ? 24 : InpSessionEndHour;
   return (hr >= InpSessionStartHour && hr < endh);
}

// Stop trading for the rest of the local day; resume tomorrow at session open
void HaltForToday()
{
   datetime loc      = LocalNow();
   datetime dayStart = loc - (loc % 86400);
   g_halt_until      = dayStart + 86400 + InpSessionStartHour * 3600;  // tomorrow @ session open (local)
   g_trading_halted  = true;
   Print("Martingale cycle maxed -> halt until next session open (local ", TimeToString(g_halt_until), ")");
}

// Combined gate: within session, not halted for the day
bool TradingWindowOpen()
{
   if(g_trading_halted)
   {
      if(LocalNow() >= g_halt_until) g_trading_halted = false;  // new day/session -> resume
      else                           return false;
   }
   return InSession();
}

// Average Daily Range over InpAdrPeriod days, expressed in pips
double CalcADR()
{
   double sum = 0.0; int cnt = 0;
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

// Signal direction from candle: +1 long, -1 short, 0 none
int SignalDirection(const CANDLE_STRUCTURE &c)
{
   if(c.type == CAND_HAMMER)          return +1;   // bullish reversal
   if(c.type == CAND_DRAGONFLY_DOJI)  return +1;   // bullish reversal
   if(c.type == CAND_INVERTED_HAMMER) return -1;   // bearish reversal
   if(c.type == CAND_GRAVESTONE_DOJI) return -1;   // bearish reversal
   if(c.unit == TREND_UPPER && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return +1;
   if(c.unit == TREND_DOWN  && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return -1;
   return 0;
}

int CountPositions()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic &&
         (OrderType() == OP_BUY || OrderType() == OP_SELL)) n++;
   }
   return n;
}

double LastClosedProfit()
{
   datetime best = 0; double prof = 0.0;
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

bool OpenTrade(int dir, double lots)
{
   double tp, sl, ts, tstep;
   ResolveTradeParams(tp, sl, ts, tstep);

   double price   = (dir > 0) ? Ask : Bid;
   double stopLvl = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double slDist  = MathMax(PipToPrice(sl), stopLvl);
   double tpDist  = MathMax(PipToPrice(tp), stopLvl);

   double slPrice = NormalizeDouble((dir > 0) ? price - slDist : price + slDist, Digits);
   double tpPrice = (dir > 0) ? price + tpDist : price - tpDist;
   int    type    = (dir > 0) ? OP_BUY : OP_SELL;

   // Hidden SL: send SL=0 to the broker (nothing shows in the terminal) and
   // monitor the intended level ourselves via CheckHiddenSL().
   double sendSL  = InpHiddenSL ? 0.0 : slPrice;

   int ticket = OrderSend(Symbol(), type, lots, NormalizeDouble(price, Digits),
                          EffSlippage(),
                          sendSL,
                          NormalizeDouble(tpPrice, Digits),
                          "OneMinuteMan", InpMagic, 0,
                          (dir > 0) ? clrBlue : clrRed);
   if(ticket < 0)
      Print("OrderSend failed: err=", GetLastError());
   else if(InpHiddenSL)
      g_hidden_sl_price = slPrice;
   return (ticket >= 0);
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
            if(InpHiddenSL)
            {
               // Trail the virtual SL only — nothing is sent to the broker.
               if(newSL > g_hidden_sl_price) g_hidden_sl_price = newSL;
            }
            else if(newSL > OrderStopLoss())
               OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen);
         }
      }
      else if(OrderType() == OP_SELL)
      {
         double gained = (OrderOpenPrice() - Ask) / ps;
         if(gained >= ts)
         {
            double newSL = NormalizeDouble(Ask + PipToPrice(tstep), Digits);
            if(InpHiddenSL)
            {
               if(g_hidden_sl_price == 0.0 || newSL < g_hidden_sl_price) g_hidden_sl_price = newSL;
            }
            else if(OrderStopLoss() == 0.0 || newSL < OrderStopLoss())
               OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen);
         }
      }
   }
}

// Virtual SL monitor: closes an open position when Bid/Ask breaches the hidden
// SL level stored in g_hidden_sl_price (only active when InpHiddenSL is on).
void CheckHiddenSL()
{
   if(!InpHiddenSL || g_hidden_sl_price <= 0.0) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;

      if(OrderType() == OP_BUY && Bid <= g_hidden_sl_price)
      {
         if(!OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(Bid, Digits),
                        EffSlippage(), clrOrange))
            Print("Hidden SL close (BUY) failed: err=", GetLastError());
      }
      else if(OrderType() == OP_SELL && Ask >= g_hidden_sl_price)
      {
         if(!OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(Ask, Digits),
                        EffSlippage(), clrOrange))
            Print("Hidden SL close (SELL) failed: err=", GetLastError());
      }
   }
}

// Tick-volume confirmation stats: last closed M1 bar volume vs. the average of
// the preceding InpVolLookback bars. Returns false when history is insufficient.
bool VolumeStats(double &last, double &avg)
{
   last = 0.0; avg = 0.0;
   int lb = (InpVolLookback < 1) ? 1 : InpVolLookback;
   last = (double)iVolume(Symbol(), PERIOD_M1, 1);
   double sum = 0.0; int cnt = 0;
   for(int i = 2; i <= lb + 1; i++)
   {
      double v = (double)iVolume(Symbol(), PERIOD_M1, i);
      if(v > 0.0) { sum += v; cnt++; }
   }
   if(cnt == 0) return false;
   avg = sum / cnt;
   return true;
}

// True when the last closed bar shows above-average participation.
bool VolumeConfirms()
{
   double last, avg;
   if(!VolumeStats(last, avg)) return false;
   return (last > avg);
}

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
         // Cycle ended: a win, or the martingale ladder hit its max step
         if(profit < 0.0 && InpUseMartingale && g_mart_step >= InpMartMaxSteps)
            HaltForToday();   // max steps completed -> stop trading for today
         g_await_reentry = false;
         g_mart_step     = 0;
      }
   }
   if(n == 0) g_hidden_sl_price = 0.0;  // no position -> clear virtual SL
   g_had_pos = (n > 0);
}

// Fresh entries + ADR-spaced martingale re-entry
void ManageEntries(bool allowFresh)
{
   if(!InpEnableTrading)    return;
   if(CountPositions() > 0) return;
   if(!TradingWindowOpen()) return;   // session window + daily halt gate
   if(!SpreadOK())          return;   // spread filter

   // Martingale re-entry: same direction, after adverse move >= fraction of ADR
   if(g_await_reentry && InpUseMartingale && g_mart_step < InpMartMaxSteps)
   {
      double reentry = InpAdrFraction * g_adr_pips;   // pips
      double adverse = (g_last_dir > 0) ? (g_last_entry - Bid) / PipSize()
                                        : (Ask - g_last_entry) / PipSize();
      if(reentry > 0.0 && adverse >= reentry)
      {
         double lots = NormalizeLots(g_last_lots * InpMartMult);
         if(OpenTrade(g_last_dir, lots))
         {
            g_mart_step++;
            g_last_lots     = lots;
            g_last_entry    = (g_last_dir > 0) ? Ask : Bid;
            g_await_reentry = false;
         }
      }
      return;
   }

   // Fresh signal (once per new M1 bar): PPM efficiency gate + candle direction
   if(!allowFresh)                     return;
   if(!g_candle_valid || !g_ppm_valid) return;
   if(g_ppm.zone < PPM_ZONE_MEDIUM)    return;

   int dir = SignalDirection(g_candle);
   if(dir == 0) return;

   // Volume confirmation: require above-average participation on the last bar
   if(InpUseVolumeFilter && !VolumeConfirms()) return;

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
// SECTION 14 — DISPLAY: merged range + candle + PPM + trade overlay
//==================================================================
void UpdateComment()
{
   string tf  = TFLabel();
   string msg = "=== OneMinuteMan v5.00 ===\n";
   msg += StringFormat("Symbol:%-6s  Engines:M1 (forced)  Chart:%s\n", Symbol(), tf);

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

   // --- Trade panel (M1 engine)
   msg += "--- Trade / Money Mgmt ---\n";
   {
      double tp, sl, ts, tstep; ResolveTradeParams(tp, sl, ts, tstep);
      msg += StringFormat("Trading: %s  Magic:%d\n", InpEnableTrading ? "ON" : "OFF", InpMagic);
      msg += StringFormat("TP:%.0f SL:%.0f Trail:%.0f/%.0f pips  SL:%s\n",
                          tp, sl, ts, tstep, InpHiddenSL ? "HIDDEN" : "VISIBLE");
      if(InpHiddenSL && g_hidden_sl_price > 0.0)
         msg += StringFormat("HiddenSL@ %.5f\n", g_hidden_sl_price);
   }
   if(InpUseVolumeFilter)
   {
      double vlast, vavg;
      if(VolumeStats(vlast, vavg))
         msg += StringFormat("Vol:%.0f Avg:%.0f (%d) %s\n",
                             vlast, vavg, InpVolLookback,
                             (vlast > vavg) ? "[CONFIRM]" : "[WAIT]");
      else
         msg += StringFormat("Vol: n/a (need %d bars)\n", InpVolLookback);
   }
   msg += StringFormat("Open:%d  Mart:%d/%d %s\n",
                       CountPositions(), g_mart_step, InpMartMaxSteps,
                       g_await_reentry ? "[AWAIT RE-ENTRY]" : "");
   msg += StringFormat("ADR:%.0f pips  Re-entry@%.0f pips\n",
                       g_adr_pips, InpAdrFraction * g_adr_pips);
   msg += StringFormat("Session: %s (UTC+%d %dh-%dh)  Spread<=%d\n",
                       (TradingWindowOpen() ? "OPEN" : (g_trading_halted ? "HALTED" : "CLOSED")),
                       InpTzOffsetHours, InpSessionStartHour, InpSessionEndHour, EffMaxSpread());
   if(g_trading_halted)
      msg += StringFormat("Resume : %s (local)\n", TimeToString(g_halt_until));

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
   if(InpBaseLots <= 0.0)
      { Print("Error: InpBaseLots must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUseVolumeFilter && InpVolLookback < 1)
      { Print("Error: InpVolLookback must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
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

   ArrayResize(g_prices, BUFFER_SIZE);
   ArrayInitialize(g_prices, 0.0);

   if(!EventSetMillisecondTimer(InpSampleMs))
      { Print("Error: EventSetMillisecondTimer failed"); return INIT_FAILED; }

   Print("OneMinuteMan v6.00 initialized: ", Symbol(), " (engines forced to M1)",
         " | ZZ:", InpZzDepth, "-", InpZzDeviation, "-", InpZzBackstep,
         " | PPM min:", InpPpmMinHigh, " target:", InpPpmTarget,
         " | Trading:", (InpEnableTrading ? "ON" : "OFF"),
         " Martingale:", (InpUseMartingale ? "ON" : "OFF"),
         " | Session UTC+", InpTzOffsetHours, " ", InpSessionStartHour, "h-", InpSessionEndHour, "h");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("OneMinuteMan v6.00 stopped. Reason: ", reason);
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

   // Refresh ADR (used by martingale spacing + panel) and manage open trades
   g_adr_pips = CalcADR();
   ManageTrailing();
   CheckHiddenSL();   // enforce virtual SL between ticks when InpHiddenSL is on

   UpdateComment();
}

// Tick: fires on each new price quote — recognizes last closed bar pattern
void OnTick()
{
   // Forced M1 context: candle engine always reads the M1 timeframe,
   // matching the M1 PPM engine and the 60s rolling range.
   bool newBar = IsNewBar();

   if(newBar)
   {
      CANDLE_STRUCTURE bar;
      if(RecognizeCandle(Symbol(), PERIOD_M1,
                         iTime(Symbol(), PERIOD_M1, 1),
                         InpAverPeriod, bar))
      {
         g_candle       = bar;
         g_candle_valid = true;

         Print(StringFormat("[M1] Candle:%s Trend:%s | Body=%.5f OHLC=%.5f/%.5f/%.5f/%.5f | PPM=%.2f Zone=%s",
               CandleTypeName(bar.type),
               TrendName(bar.unit),
               bar.bodysize,
               bar.open, bar.high, bar.low, bar.close,
               g_ppm_valid ? g_ppm.ppm : 0.0,
               g_ppm_valid ? PpmZoneName(g_ppm.zone) : "N/A"));
      }
   }

   // Trade management: detect closed cycles, arm martingale, trail, and enter.
   UpdateTradeState();
   ManageTrailing();
   ManageEntries(newBar);
}
//+------------------------------------------------------------------+
