//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                                     Copyright 2025, nhasibuan     |
//|                          https://github.com/nhasibuan/oneminuteman|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, nhasibuan"
#property link      "https://github.com/nhasibuan/oneminuteman"
#property version   "9.10"
#property strict
#property description "OneMinuteMan: Forced-M1 range + candle + PPM engine. Includes dynamic ATR risk, virtual SL with safety-net, break-even, equity guards, and persistent martingale state."

//==================================================================
// SECTION 0 — ENUMERATIONS
//==================================================================
enum ENUM_MART_MODE {
   MART_SAME_DIRECTION = 0,
   MART_REVERSE_DIRECTION = 1
};

enum TYPE_CANDLESTICK {
   CAND_UNKNOWN = 0, CAND_LONG, CAND_SHORT, CAND_DOJI, CAND_MARUBOZU,
   CAND_HAMMER, CAND_INVERTED_HAMMER, CAND_SPINNING_TOP,
   CAND_DRAGONFLY_DOJI, CAND_GRAVESTONE_DOJI, CAND_LONG_LEGGED_DOJI
};

enum TYPE_TREND {
   TREND_UNKNOWN = 0, TREND_UPPER, TREND_DOWN, TREND_LATERAL
};

enum PPM_ZONE {
   PPM_ZONE_NONE = 0, PPM_ZONE_LOW, PPM_ZONE_MEDIUM, PPM_ZONE_HIGH
};

//==================================================================
// SECTION 1 — INPUTS
//==================================================================
//--- Range Scanner
input int    InpSampleMs    = 50;     // Sampling interval (ms)
input int    InpWindowSize  = 1200;   // Buffer size (samples): 1200 x 50ms = 60s

//--- Candle Recognizer
input int    InpAverPeriod  = 14;     // SMA period for trend + avg body

//--- PPM Engine
input int    InpZzDepth     = 2;      // ZigZag Depth
input int    InpZzDeviation = 2;      // ZigZag Deviation
input int    InpZzBackstep  = 1;      // ZigZag Backstep
input int    InpZzLookback  = 100;    // Bars to scan for ZigZag
input double InpPpmMinHigh  = 2.0;    // PPM threshold — low efficiency
input double InpPpmTarget   = 4.0;    // PPM target — ideal entry zone
input double InpAtrDailyRef = 1.5;    // PPM volatility baseline (display only)
input bool   InpShowPPM     = true;   // Show PPM panel

//--- Volume Filter
input bool   InpUseVolumeFilter = true;
input int    InpVolLookback     = 20;
input double InpVolMultiplier   = 1.5;

//--- Trade Management
input bool   InpEnableTrading = false;
input double InpBaseLots      = 0.01;
input int    InpSlippage      = 0;    // 0 = AUTO
input int    InpMaxSpread     = 0;    // 0 = AUTO
input int    InpMagic         = 202506;
input double InpTP_Pips       = 0;    // 0 = AUTO (ATR)
input double InpSL_Pips       = 0;    // 0 = AUTO (ATR)
input bool   InpHideSL        = true; // Virtual SL
input double InpTrailStart    = 0;    // 0 = AUTO (ATR)
input double InpTrailStep     = 0;    // 0 = AUTO (ATR)

//--- Break-Even & Safety
input double InpBE_TriggerMult = 1.0; // Break-even trigger (x ATR)
input double InpBE_LockPips    = 1.0; // Pips to lock at BE
input bool   InpUseSafetySL    = true;// Send real SL to broker as disconnect safety
input double InpSafetySLMult   = 5.0; // Safety SL distance (x Virtual SL)

//--- Dynamic Risk (ATR)
input int    InpAtrPeriod         = 14;
input double InpAtrSLMult         = 1.5;
input double InpAtrTPMult         = 2.0;
input double InpAtrTrailStartMult = 1.0;
input double InpAtrTrailStepMult  = 0.5;
input double InpMinRiskPips       = 1.0;

//--- Dynamic Execution
input double InpMaxSpreadMult = 2.5;
input double InpSlippageMult  = 1.5;
input double InpSprEmaAlpha   = 0.05;

//--- Martingale
input bool           InpUseMartingale = true;
input ENUM_MART_MODE InpMartMode      = MART_SAME_DIRECTION;
input double         InpMartMult      = 2.0;
input int            InpMartMaxSteps  = 5;
input int            InpMartCooldownBars = 2; // Cooldown bars between steps

//--- Equity Protection
input double InpMaxDrawdownPct = 10.0; // Halt if daily drawdown >= 10%
input double InpMinEquity      = 100.0; // Halt if equity drops below this

//--- Trading Session
input int    InpTzOffsetHours    = 7;
input int    InpSessionStartHour = 5;
input int    InpSessionEndHour   = 24;

//==================================================================
// SECTION 2 — CONSTANTS & STRUCTURES
//==================================================================
#define MAX_POSITIONS 20

const double LONG_BODY_FACTOR   = 1.3;
const double SHORT_BODY_FACTOR  = 0.5;
const double DOJI_BODY_FACTOR   = 0.03;
const double MARUBOZU_SHADE     = 0.01;
const double HAMMER_SHADE       = 2.0;
const double HAMMER_OPP_SHADE   = 0.1;
const double DOJI_TINY_FRACTION = 0.1;

struct CANDLE_STRUCTURE {
   TYPE_CANDLESTICK type;
   TYPE_TREND       unit;
   double           bodysize, shade_high, shade_low, avg_close, avg_body;
   double           open, high, low, close;
};

struct PPM_RESULT {
   double   ppm, pips, atr_ratio;
   int      candles;
   PPM_ZONE zone;
   datetime pivot_start, pivot_end;
};

struct VSL_ENTRY {
   int    ticket;
   int    dir;
   double vsl_price;
   double be_price;
   double safety_sl_price;
   bool   active;
};

//==================================================================
// SECTION 3 — GLOBAL STATE
//==================================================================
double  g_prices[];      // Dynamic buffer
int     g_head = 0;
int     g_count = 0;
double  g_high = 0.0, g_low = 0.0;

CANDLE_STRUCTURE g_candle;
bool             g_candle_valid = false;
PPM_RESULT       g_ppm;
bool             g_ppm_valid = false;

bool     g_had_pos = false;
int      g_last_dir = 0;
double   g_last_lots = 0.0;
int      g_mart_step = 0;
bool     g_await_reentry = false;
datetime g_last_loss_time = 0;

double   g_spread_ema = 0.0;
datetime g_halt_until = 0;
bool     g_trading_halted = false;
double   g_day_start_balance = 0.0;
datetime g_last_history_scan = 0;
double   g_cached_loss = 0.0;

VSL_ENTRY g_vsl[MAX_POSITIONS];
int       g_vsl_count = 0;

//==================================================================
// SECTION 4 — UTILITY & LABELS
//==================================================================
string TFLabel() {
   string full = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(full, "PERIOD_", "");
   return full;
}

string MartModeName(ENUM_MART_MODE m) {
   return (m == MART_REVERSE_DIRECTION) ? "REVERSE" : "SAME";
}

string PpmZoneName(PPM_ZONE z) {
   switch(z) {
      case PPM_ZONE_HIGH:   return "HIGH [ENTER]";
      case PPM_ZONE_MEDIUM: return "MEDIUM [WATCH]";
      case PPM_ZONE_LOW:    return "LOW [AVOID]";
      default:              return "NO DATA";
   }
}

string CandleTypeName(TYPE_CANDLESTICK tp) {
   switch(tp) {
      case CAND_LONG:             return "Long";
      case CAND_SHORT:            return "Short";
      case CAND_DOJI:             return "Doji";
      case CAND_MARUBOZU:         return "Marubozu";
      case CAND_HAMMER:           return "Hammer";
      case CAND_INVERTED_HAMMER:  return "InvertedHammer";
      case CAND_SPINNING_TOP:     return "SpinningTop";
      case CAND_DRAGONFLY_DOJI:   return "DragonflyDoji";
      case CAND_GRAVESTONE_DOJI:  return "GravestoneDoji";
      case CAND_LONG_LEGGED_DOJI: return "LongLeggedDoji";
      default:                    return "Unknown";
   }
}

string TrendName(TYPE_TREND u) {
   switch(u) {
      case TREND_UPPER:   return "Ascending";
      case TREND_DOWN:    return "Descending";
      case TREND_LATERAL: return "Lateral";
      default:            return "Unknown";
   }
}

double PipSize() {
   return (Digits == 3 || Digits == 5) ? Point * 10 : Point;
}

double PipToPrice(double pips) {
   return pips * PipSize();
}

//==================================================================
// SECTION 5 — TIME & SESSION GUARDS
//==================================================================
datetime LocalNow() {
   return (datetime)(TimeGMT() + InpTzOffsetHours * 3600);
}

bool InSession() {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int gmt_hour = dt.hour;
   int local_hour = (gmt_hour + InpTzOffsetHours + 24) % 24;
   int endh = (InpSessionEndHour <= InpSessionStartHour) ? 24 : InpSessionEndHour;
   return (local_hour >= InpSessionStartHour && local_hour < endh);
}

void HaltForToday() {
   datetime now = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int current_local = (dt.hour + InpTzOffsetHours + 24) % 24;
   int days_to_add = (current_local >= InpSessionStartHour) ? 1 : 0;
   datetime target = now + days_to_add * 86400;
   TimeToStruct(target, dt);
   dt.hour = (InpSessionStartHour - InpTzOffsetHours + 24) % 24;
   dt.min = 0;
   dt.sec = 0;
   g_halt_until = StructToTime(dt);
   g_trading_halted = true;
   Print("Trading halted until next session (GMT: ", TimeToString(g_halt_until), ")");
}

bool TradingWindowOpen() {
   if(g_trading_halted) {
      if(TimeGMT() >= g_halt_until) {
         g_trading_halted = false;
         g_day_start_balance = AccountBalance(); // Reset daily balance on new session
      } else {
         return false;
      }
   }
   return InSession();
}

bool EquityGuardOK() {
   if(AccountEquity() < InpMinEquity) {
      Print("Equity below minimum threshold. Halting.");
      HaltForToday();
      return false;
   }
   if(g_day_start_balance > 0) {
      double dd = (g_day_start_balance - AccountEquity()) / g_day_start_balance * 100.0;
      if(dd >= InpMaxDrawdownPct) {
         Print("Max daily drawdown breached (", DoubleToStr(dd, 2), "%). Halting.");
         HaltForToday();
         return false;
      }
   }
   return true;
}

//==================================================================
// SECTION 6 — RANGE & VOLUME ENGINES
//==================================================================
void ScanHighLow() {
   double h = -DBL_MAX, l = DBL_MAX;
   int limit = (g_count < InpWindowSize) ? g_count : InpWindowSize;
   for(int i = 0; i < limit; i++) {
      if(g_prices[i] > h) h = g_prices[i];
      if(g_prices[i] < l) l = g_prices[i];
   }
   g_high = (h == -DBL_MAX) ? 0.0 : h;
   g_low  = (l ==  DBL_MAX) ? 0.0 : l;
}

bool VolumeOK() {
   if(!InpUseVolumeFilter || InpVolLookback < 2) return true;
   long vol_last = iVolume(Symbol(), PERIOD_M1, 1);
   if(vol_last <= 0) return true;
   
   long vol_sum = 0;
   int n = 0;
   for(int i = 1; i <= InpVolLookback; i++) {
      long v = iVolume(Symbol(), PERIOD_M1, i);
      if(v > 0) { vol_sum += v; n++; }
   }
   if(n == 0) return true;
   return (vol_last >= ((double)vol_sum / n) * InpVolMultiplier);
}

//==================================================================
// SECTION 7 — CANDLE ENGINE
//==================================================================
void CalcShades(CANDLE_STRUCTURE &c) {
   if(c.close >= c.open) {
      c.shade_high = c.high - c.close; c.shade_low = c.open - c.low;
   } else {
      c.shade_high = c.high - c.open;  c.shade_low = c.close - c.low;
   }
}

double CalcAverageClose(int shift, int period) {
   double sum = 0.0;
   for(int i = shift + 1; i <= shift + period; i++) sum += iClose(Symbol(), PERIOD_M1, i);
   return sum / period;
}

double CalcAverageBody(int shift, int period) {
   double sum = 0.0;
   for(int i = shift + 1; i <= shift + period; i++) sum += MathAbs(iClose(Symbol(), PERIOD_M1, i) - iOpen(Symbol(), PERIOD_M1, i));
   return sum / period;
}

bool RecognizeCandle(int shift, CANDLE_STRUCTURE &res) {
   res.open  = iOpen(Symbol(), PERIOD_M1, shift);
   res.close = iClose(Symbol(), PERIOD_M1, shift);
   res.high  = iHigh(Symbol(), PERIOD_M1, shift);
   res.low   = iLow(Symbol(), PERIOD_M1, shift);
   if(res.close == 0) return false;
   
   res.bodysize = MathAbs(res.close - res.open);
   CalcShades(res);
   res.avg_close = CalcAverageClose(shift, InpAverPeriod);
   res.avg_body  = CalcAverageBody(shift, InpAverPeriod);

   res.type = CAND_UNKNOWN;
   if(res.bodysize > res.avg_body * LONG_BODY_FACTOR) res.type = CAND_LONG;
   if(res.bodysize < res.avg_body * SHORT_BODY_FACTOR) res.type = CAND_SHORT;
   
   double HL = res.high - res.low;
   if(HL > 0.0 && res.bodysize < HL * DOJI_BODY_FACTOR) res.type = CAND_DOJI;
   if(res.bodysize > 0.0 && MathMin(res.shade_high, res.shade_low) / res.bodysize < MARUBOZU_SHADE) res.type = CAND_MARUBOZU;
   
   if(res.shade_low > res.bodysize * HAMMER_SHADE && res.shade_high < res.bodysize * HAMMER_OPP_SHADE) res.type = CAND_HAMMER;
   if(res.shade_high > res.bodysize * HAMMER_SHADE && res.shade_low < res.bodysize * HAMMER_OPP_SHADE) res.type = CAND_INVERTED_HAMMER;
   if(res.type == CAND_SHORT && res.shade_low > res.bodysize && res.shade_high > res.bodysize) res.type = CAND_SPINNING_TOP;

   if(res.type == CAND_DOJI) {
      double tiny = HL * DOJI_TINY_FRACTION;
      if(res.shade_low > 2.0 * res.shade_high && res.shade_high <= tiny) res.type = CAND_DRAGONFLY_DOJI;
      else if(res.shade_high > 2.0 * res.shade_low && res.shade_low <= tiny) res.type = CAND_GRAVESTONE_DOJI;
      else if(res.shade_high > tiny && res.shade_low > tiny) res.type = CAND_LONG_LEGGED_DOJI;
   }

   if(res.close > res.avg_close) res.unit = TREND_UPPER;
   else if(res.close < res.avg_close) res.unit = TREND_DOWN;
   else res.unit = TREND_LATERAL;

   return true;
}

int SignalDirection(const CANDLE_STRUCTURE &c) {
   if(c.type == CAND_HAMMER || c.type == CAND_DRAGONFLY_DOJI) return +1;
   if(c.type == CAND_INVERTED_HAMMER || c.type == CAND_GRAVESTONE_DOJI) return -1;
   if(c.unit == TREND_UPPER && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return +1;
   if(c.unit == TREND_DOWN && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return -1;
   return 0;
}

//==================================================================
// SECTION 8 — PPM ENGINE
//==================================================================
bool CalcPPM(PPM_RESULT &res) {
   res.ppm = 0.0; res.pips = 0.0; res.candles = 0; res.atr_ratio = 0.0; res.zone = PPM_ZONE_NONE;
   int bars = MathMin(InpZzLookback, Bars - 1);
   if(bars < 4) return false;

   double pivot1 = 0.0, pivot2 = 0.0;
   int bar1 = -1, bar2 = -1;

   for(int i = 1; i <= bars; i++) {
      double zzVal = iCustom(Symbol(), PERIOD_M1, "ZigZag", InpZzDepth, InpZzDeviation, InpZzBackstep, 0, i);
      if(zzVal != 0.0 && zzVal != EMPTY_VALUE) {
         if(bar1 < 0) { pivot1 = zzVal; bar1 = i; }
         else { pivot2 = zzVal; bar2 = i; break; }
      }
   }

   if(bar1 < 0 || bar2 < 0) return false;
   int barDiff = bar2 - bar1;
   if(barDiff < 1) return false;

   double pips = MathAbs(pivot1 - pivot2) / PipSize();
   double ppm = pips / (double)barDiff;

   res.pips = pips; res.candles = barDiff; res.ppm = ppm;
   res.atr_ratio = (InpAtrDailyRef > 0.0) ? ppm / InpAtrDailyRef : 0.0;
   res.pivot_start = iTime(Symbol(), PERIOD_M1, bar2);
   res.pivot_end = iTime(Symbol(), PERIOD_M1, bar1);

   if(ppm >= InpPpmTarget) res.zone = PPM_ZONE_HIGH;
   else if(ppm >= InpPpmMinHigh) res.zone = PPM_ZONE_MEDIUM;
   else res.zone = PPM_ZONE_LOW;

   return true;
}

//==================================================================
// SECTION 9 — RISK & EXECUTION
//==================================================================
double AtrPips() {
   double atr = iATR(Symbol(), PERIOD_M1, InpAtrPeriod, 1);
   double p = atr / PipSize();
   return (p > 0.0) ? p : 0.0;
}

void ResolveTradeParams(double &tp, double &sl, double &trailStart, double &trailStep, double &be_trigger) {
   double atrPips = AtrPips();
   double floorP = (InpMinRiskPips > 0.0) ? InpMinRiskPips : 1.0;
   
   sl = (InpSL_Pips > 0.0) ? InpSL_Pips : MathMax(atrPips * InpAtrSLMult, floorP);
   tp = (InpTP_Pips > 0.0) ? InpTP_Pips : MathMax(atrPips * InpAtrTPMult, floorP);
   trailStart = (InpTrailStart > 0.0) ? InpTrailStart : MathMax(atrPips * InpAtrTrailStartMult, floorP);
   trailStep = (InpTrailStep > 0.0) ? InpTrailStep : MathMax(atrPips * InpAtrTrailStepMult, floorP * 0.5);
   be_trigger = MathMax(atrPips * InpBE_TriggerMult, floorP);
}

double AvgSpreadPoints() {
   return (g_spread_ema > 0.0) ? g_spread_ema : (Ask - Bid) / Point;
}

int EffSlippage() {
   if(InpSlippage > 0) return InpSlippage;
   int v = (int)MathCeil(AvgSpreadPoints() * InpSlippageMult);
   return (v < 1) ? 1 : v;
}

int EffMaxSpread() {
   if(InpMaxSpread > 0) return InpMaxSpread;
   int v = (int)MathCeil(AvgSpreadPoints() * InpMaxSpreadMult);
   return (v < 1) ? 1 : v;
}

bool SpreadOK() {
   int spr = (int)MathRound((Ask - Bid) / Point);
   return (EffMaxSpread() <= 0 || spr <= EffMaxSpread());
}

double NormalizeLots(double lots) {
   double minlot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxlot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   return NormalizeDouble(MathMin(MathMax(lots, minlot), maxlot), 2);
}

//==================================================================
// SECTION 10 — VIRTUAL SL & PERSISTENCE
//==================================================================
void VslRegister(int ticket, int dir, double vslPrice, double bePrice, double safetySl) {
   for(int i = 0; i < g_vsl_count; i++) {
      if(g_vsl[i].ticket == ticket) { g_vsl[i].vsl_price = vslPrice; return; }
   }
   if(g_vsl_count >= MAX_POSITIONS) return;
   g_vsl[g_vsl_count].ticket = ticket;
   g_vsl[g_vsl_count].dir = dir;
   g_vsl[g_vsl_count].vsl_price = vslPrice;
   g_vsl[g_vsl_count].be_price = bePrice;
   g_vsl[g_vsl_count].safety_sl_price = safetySl;
   g_vsl[g_vsl_count].active = true;
   g_vsl_count++;
}

void VslRemove(int ticket) {
   for(int i = 0; i < g_vsl_count; i++) {
      if(g_vsl[i].ticket == ticket) {
         for(int j = i; j < g_vsl_count - 1; j++) g_vsl[j] = g_vsl[j+1];
         g_vsl_count--;
         return;
      }
   }
}

void VslCheck() {
   if(!InpHideSL) return;
   for(int i = g_vsl_count - 1; i >= 0; i--) {
      if(!g_vsl[i].active) continue;
      bool triggered = (g_vsl[i].dir > 0 && Bid <= g_vsl[i].vsl_price) || (g_vsl[i].dir < 0 && Ask >= g_vsl[i].vsl_price);
      if(triggered) {
         if(OrderSelect(g_vsl[i].ticket, SELECT_BY_TICKET) && OrderCloseTime() == 0) {
            double closePrice = (g_vsl[i].dir > 0) ? Bid : Ask;
            if(!OrderClose(g_vsl[i].ticket, OrderLots(), closePrice, EffSlippage(), clrOrange))
               Print("VslCheck: OrderClose failed ticket=", g_vsl[i].ticket, " err=", GetLastError());
         }
         VslRemove(g_vsl[i].ticket);
      }
   }
}

string GetStateFileName() {
   return "OMM_State_" + Symbol() + "_" + IntegerToString(InpMagic) + ".bin";
}

void SaveState() {
   int h = FileOpen(GetStateFileName(), FILE_WRITE | FILE_BIN);
   if(h != INVALID_HANDLE) {
      FileWriteInteger(h, g_mart_step);
      FileWriteInteger(h, g_last_dir);
      FileWriteDouble(h, g_last_lots);
      FileWriteInteger(h, g_vsl_count);
      for(int i = 0; i < g_vsl_count; i++) {
         FileWriteInteger(h, g_vsl[i].ticket);
         FileWriteInteger(h, g_vsl[i].dir);
         FileWriteDouble(h, g_vsl[i].vsl_price);
         FileWriteDouble(h, g_vsl[i].be_price);
         FileWriteDouble(h, g_vsl[i].safety_sl_price);
      }
      FileClose(h);
   }
}

void LoadState() {
   int h = FileOpen(GetStateFileName(), FILE_READ | FILE_BIN);
   if(h != INVALID_HANDLE) {
      g_mart_step = FileReadInteger(h);
      g_last_dir = FileReadInteger(h);
      g_last_lots = FileReadDouble(h);
      int saved_count = FileReadInteger(h);
      for(int i = 0; i < saved_count && i < MAX_POSITIONS; i++) {
         g_vsl[i].ticket = FileReadInteger(h);
         g_vsl[i].dir = FileReadInteger(h);
         g_vsl[i].vsl_price = FileReadDouble(h);
         g_vsl[i].be_price = FileReadDouble(h);
         g_vsl[i].safety_sl_price = FileReadDouble(h);
         g_vsl[i].active = true;
         if(!OrderSelect(g_vsl[i].ticket, SELECT_BY_TICKET) || OrderCloseTime() != 0) {
            g_vsl[i].active = false;
         }
      }
      g_vsl_count = saved_count;
      FileClose(h);
      Print("State recovered: MartStep=", g_mart_step, " VSLs=", g_vsl_count);
   }
}

//==================================================================
// SECTION 11 — TRADE EXECUTION & MANAGEMENT
//==================================================================
bool OpenTrade(int dir, double lots) {
   double tp, sl, ts, tstep, be_trig;
   ResolveTradeParams(tp, sl, ts, tstep, be_trig);

   double price = (dir > 0) ? Ask : Bid;
   double stopLvl = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double slDist = MathMax(PipToPrice(sl), stopLvl);
   double tpDist = MathMax(PipToPrice(tp), stopLvl);

   double slPrice = (dir > 0) ? price - slDist : price + slDist;
   double tpPrice = (dir > 0) ? price + tpDist : price - tpDist;
   double bePrice = (dir > 0) ? price + PipToPrice(InpBE_LockPips) : price - PipToPrice(InpBE_LockPips);
   
   double orderSL = InpHideSL ? 0.0 : NormalizeDouble(slPrice, Digits);
   if(InpHideSL && InpUseSafetySL) {
      orderSL = NormalizeDouble((dir > 0) ? price - (slDist * InpSafetySLMult) : price + (slDist * InpSafetySLMult), Digits);
   }

   int ticket = OrderSend(Symbol(), (dir > 0) ? OP_BUY : OP_SELL, lots, NormalizeDouble(price, Digits),
                          EffSlippage(), orderSL, NormalizeDouble(tpPrice, Digits),
                          "OneMinuteMan", InpMagic, 0, (dir > 0) ? clrBlue : clrRed);
   if(ticket < 0) {
      Print("OrderSend failed: err=", GetLastError());
      return false;
   }

   if(InpHideSL) VslRegister(ticket, dir, NormalizeDouble(slPrice, Digits), NormalizeDouble(bePrice, Digits), orderSL);
   SaveState();
   return true;
}

void ManageTrailing() {
   double tp, sl, ts, tstep, be_trig;
   ResolveTradeParams(tp, sl, ts, tstep, be_trig);
   double ps = PipSize();

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;

      bool isBuy = (OrderType() == OP_BUY);
      double gained = isBuy ? (Bid - OrderOpenPrice()) / ps : (OrderOpenPrice() - Ask) / ps;
      
      if(gained >= be_trig) {
         double newSL = isBuy ? OrderOpenPrice() + PipToPrice(InpBE_LockPips) : OrderOpenPrice() - PipToPrice(InpBE_LockPips);
         if(InpHideSL) {
            for(int v = 0; v < g_vsl_count; v++) {
               if(g_vsl[v].ticket == OrderTicket()) {
                  if(isBuy && newSL > g_vsl[v].vsl_price) g_vsl[v].vsl_price = newSL;
                  if(!isBuy && (g_vsl[v].vsl_price == 0.0 || newSL < g_vsl[v].vsl_price)) g_vsl[v].vsl_price = newSL;
                  break;
               }
            }
         } else {
            if((isBuy && newSL > OrderStopLoss()) || (!isBuy && (OrderStopLoss() == 0.0 || newSL < OrderStopLoss())))
               OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen);
         }
      }

      if(gained >= ts) {
         double newSL = isBuy ? NormalizeDouble(Bid - PipToPrice(tstep), Digits) : NormalizeDouble(Ask + PipToPrice(tstep), Digits);
         if(InpHideSL) {
            for(int v = 0; v < g_vsl_count; v++) {
               if(g_vsl[v].ticket == OrderTicket()) {
                  if(isBuy && newSL > g_vsl[v].vsl_price) g_vsl[v].vsl_price = newSL;
                  if(!isBuy && (g_vsl[v].vsl_price == 0.0 || newSL < g_vsl[v].vsl_price)) g_vsl[v].vsl_price = newSL;
                  break;
               }
            }
         } else {
            if((isBuy && newSL > OrderStopLoss()) || (!isBuy && (OrderStopLoss() == 0.0 || newSL < OrderStopLoss())))
               OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen);
         }
      }
   }
}

int CountPositions() {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic)
         if(OrderType() == OP_BUY || OrderType() == OP_SELL) n++;
   }
   return n;
}

double LastClosedProfit() {
   datetime best = 0;
   double prof = 0.0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() > best) { best = OrderCloseTime(); prof = OrderProfit() + OrderSwap() + OrderCommission(); }
   }
   g_last_history_scan = TimeCurrent();
   g_cached_loss = prof;
   return prof;
}

//==================================================================
// SECTION 12 — CYCLE & ENTRY LOGIC
//==================================================================
void UpdateTradeState() {
   int n = CountPositions();
   if(n == 0 && g_had_pos) {
      double profit = LastClosedProfit();
      if(profit < 0.0 && InpUseMartingale && g_mart_step < InpMartMaxSteps) {
         g_await_reentry = true;
         g_last_loss_time = TimeCurrent();
      } else {
         if(profit < 0.0 && InpUseMartingale && g_mart_step >= InpMartMaxSteps) HaltForToday();
         g_await_reentry = false;
         g_mart_step = 0;
      }
      SaveState();
   }
   g_had_pos = (n > 0);
}

int ResolveMartingaleDir() {
   return (InpMartMode == MART_REVERSE_DIRECTION) ? -g_last_dir : g_last_dir;
}

void ManageEntries(bool allowFresh) {
   if(!InpEnableTrading || CountPositions() > 0 || !TradingWindowOpen() || !SpreadOK() || !EquityGuardOK()) return;

   if(g_await_reentry && InpUseMartingale && g_mart_step < InpMartMaxSteps) {
      int barsSinceLoss = iBarShift(Symbol(), PERIOD_M1, g_last_loss_time);
      if(barsSinceLoss < InpMartCooldownBars) return;
      if(!VolumeOK()) return;

      int reDir = ResolveMartingaleDir();
      double lots = NormalizeLots(g_last_lots * InpMartMult);
      if(OpenTrade(reDir, lots)) {
         g_mart_step++;
         g_last_dir = reDir;
         g_last_lots = lots;
         g_await_reentry = false;
      }
      return;
   }

   if(!allowFresh || !g_candle_valid || !g_ppm_valid || g_ppm.zone < PPM_ZONE_MEDIUM || !VolumeOK()) return;

   int dir = SignalDirection(g_candle);
   if(dir == 0) return;

   double lots = NormalizeLots(InpBaseLots);
   if(OpenTrade(dir, lots)) {
      g_mart_step = 1;
      g_last_dir = dir;
      g_last_lots = lots;
      g_await_reentry = false;
   }
}

//==================================================================
// SECTION 13 — DISPLAY
//==================================================================
void UpdateComment() {
   string msg = "=== OneMinuteMan v9.10 ===\n";
   msg += StringFormat("Symbol:%-6s  Engines:M1 (forced)  Chart:%s\n", Symbol(), TFLabel());
   msg += "--- Range ---\n";
   msg += StringFormat("High:%.5f  Low:%.5f  Range:%.5f\n", g_high, g_low, g_high - g_low);
   msg += "--- Candle ---\n";
   if(g_candle_valid) msg += StringFormat("Pattern:%s Trend:%s\n", CandleTypeName(g_candle.type), TrendName(g_candle.unit));
   if(InpShowPPM && g_ppm_valid) msg += StringFormat("PPM:%.2f  Zone:%s\n", g_ppm.ppm, PpmZoneName(g_ppm.zone));
   msg += "--- Trade ---\n";
   msg += StringFormat("Trading:%s  Spread:%d/%d  Equity:$%.2f\n", InpEnableTrading ? "ON" : "OFF", (int)((Ask-Bid)/Point), EffMaxSpread(), AccountEquity());
   msg += StringFormat("Open:%d  Mart:%d/%d (%s) %s\n", CountPositions(), g_mart_step, InpMartMaxSteps, MartModeName(InpMartMode), g_await_reentry ? "[AWAIT]" : "");
   msg += StringFormat("Session: %s  HideSL:%s  VSLs:%d\n", TradingWindowOpen() ? "OPEN" : "CLOSED", InpHideSL ? "ON" : "OFF", g_vsl_count);
   if(g_trading_halted) msg += StringFormat("HALTED until: %s (GMT)\n", TimeToString(g_halt_until, TIME_MINUTES));
   Comment(msg);
}

//==================================================================
// SECTION 14 — EVENT HANDLERS
//==================================================================
int OnInit() {
   if(InpWindowSize < 60 || InpWindowSize > 50000) { Print("Error: InpWindowSize must be 60-50000"); return INIT_PARAMETERS_INCORRECT; }
   if(InpBaseLots <= 0.0) { Print("Error: InpBaseLots must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   
   double zz = iCustom(Symbol(), PERIOD_M1, "ZigZag", InpZzDepth, InpZzDeviation, InpZzBackstep, 0, 1);
   if(zz == 0 || zz == EMPTY_VALUE) { Print("ERROR: ZigZag indicator not found or returning empty values."); return INIT_FAILED; }

   ArrayResize(g_prices, InpWindowSize);
   ArrayInitialize(g_prices, 0.0);
   
   g_vsl_count = 0;
   g_spread_ema = 0.0;
   g_day_start_balance = AccountBalance();
   
   LoadState();
   
   if(!EventSetMillisecondTimer(InpSampleMs)) { Print("Error: Timer failed"); return INIT_FAILED; }
   Print("OneMinuteMan v9.10 initialized successfully.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   Comment("");
   SaveState();
}

void OnTimer() {
   RefreshRates();
   
   double curSpr = (Ask - Bid) / Point;
   if(curSpr > 0.0) {
      g_spread_ema = (g_spread_ema <= 0.0) ? curSpr : g_spread_ema + InpSprEmaAlpha * (curSpr - g_spread_ema);
   }

   g_prices[g_head] = Ask;
   g_count = MathMin(g_count + 1, InpWindowSize);
   g_head = (g_head + 1) % InpWindowSize;

   ScanHighLow();

   PPM_RESULT ppmTmp;
   if(CalcPPM(ppmTmp)) { g_ppm = ppmTmp; g_ppm_valid = true; }

   ManageTrailing();
   VslCheck();
   UpdateComment();
}

void OnTick() {
   bool newBar = IsNewBar();

   if(newBar) {
      CANDLE_STRUCTURE bar;
      if(RecognizeCandle(1, bar)) {
         g_candle = bar;
         g_candle_valid = true;
      }
   }

   UpdateTradeState();
   ManageTrailing();
   VslCheck();
   ManageEntries(newBar);
}

bool IsNewBar() {
   static datetime lastBarTime = 0;
   datetime cur = iTime(Symbol(), PERIOD_M1, 0);
   if(cur != lastBarTime) { lastBarTime = cur; return true; }
   return false;
}
//+------------------------------------------------------------------+