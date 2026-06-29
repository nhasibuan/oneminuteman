//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict
#property description "OneMinuteMan: 1-min rolling Ask range + candle pattern recognition"
#property description "Merged: rolling range scanner + candlestick pattern recognizer"
//--- Input Parameters
input int    InpSampleMs    = 50;    // Sampling interval (ms)
input int    InpWindowSize  = 1200;  // Window size (samples)
input int    InpAverPeriod  = 14;    // SMA average period for trend
//--- Constants
#define BUFFER_SIZE 1202
//--- Enumerations
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
//--- Candle Structure
struct CANDLE_STRUCTURE
{
   TYPE_CANDLESTICK type;
   TYPE_TREND unit;
   double bodysize;
   double shade_high;
   double shade_low;
   double avg_close;
   double avg_body;
   double open;
   double high;
   double low;
   double close;
};
//--- Globals
static double g_prices[BUFFER_SIZE];
static int    g_head  = 0;
static int    g_count = 0;
static double g_high  = 0.0;
static double g_low   = 0.0;
static CANDLE_STRUCTURE g_candle;
//+------------------------------------------------------------------+
string TFLabel()
{
   string full = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(full, "PERIOD_", "");
   return full;
}
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime cur = Time[0];
   if(cur != lastBarTime){ lastBarTime = cur; return true; }
   return false;
}
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
void CalcShades(CANDLE_STRUCTURE &c)
{
   if(c.close >= c.open)
   { c.shade_high = c.high - c.close; c.shade_low = c.open - c.low; }
   else
   { c.shade_high = c.high - c.open;  c.shade_low = c.close - c.low; }
}
double CalcAverageClose(const string sym, const ENUM_TIMEFRAMES per, const datetime t, int ap)
{
   MqlRates rt[]; ArraySetAsSeries(rt,false);
   double sum=0.0; int n=CopyRates(sym,per,t,ap,rt);
   for(int i=0;i<n;i++) sum+=rt[i].close;
   ArrayFree(rt); return (n>0)?sum/n:0.0;
}
double CalcAverageBody(const string sym, const ENUM_TIMEFRAMES per, const datetime t, int ap)
{
   MqlRates rt[]; ArraySetAsSeries(rt,false);
   double sum=0.0; int n=CopyRates(sym,per,t,ap,rt);
   for(int i=0;i<n;i++) sum+=MathAbs(rt[i].close-rt[i].open);
   ArrayFree(rt); return (n>0)?sum/n:0.0;
}
bool RecognizeCandle(const string sym, const ENUM_TIMEFRAMES per, const datetime t, int ap, CANDLE_STRUCTURE &res)
{
   MqlRates rt[]; ArraySetAsSeries(rt,false);
   if(CopyRates(sym,per,t,1,rt)<1) return false;
   res.open=rt[0].open; res.close=rt[0].close;
   res.high=rt[0].high; res.low=rt[0].low;
   res.bodysize=MathAbs(res.close-res.open);
   CalcShades(res);
   res.avg_close=CalcAverageClose(sym,per,t,ap);
   res.avg_body=CalcAverageBody(sym,per,t,ap);
   ArrayFree(rt);
   if(res.bodysize>res.avg_body*1.3) res.type=CAND_LONG;
   if(res.bodysize<res.avg_body*0.5) res.type=CAND_SHORT;
   double HL=res.high-res.low;
   if(HL>0.0 && res.bodysize<HL*0.03) res.type=CAND_DOJI;
   if(res.bodysize>0.0)
   {
      double ms=MathMin(res.shade_high,res.shade_low);
      if(ms/res.bodysize<0.01) res.type=CAND_MARUBOZU;
   }
   if(res.shade_low>res.bodysize*2.0 && res.shade_high<res.bodysize*0.1) res.type=CAND_HAMMER;
   if(res.shade_high>res.bodysize*2.0 && res.shade_low<res.bodysize*0.1) res.type=CAND_INVERTED_HAMMER;
   if(res.type==CAND_SHORT && res.shade_low>res.bodysize && res.shade_high>res.bodysize) res.type=CAND_SPINNING_TOP;
   if(res.close>res.avg_close) res.unit=TREND_UPPER;
   else if(res.close<res.avg_close) res.unit=TREND_DOWN;
   else res.unit=TREND_LATERAL;
   return true;
}
string CandleTypeName(TYPE_CANDLESTICK tp)
{
   switch(tp)
   {
      case CAND_LONG: return "Long";
      case CAND_SHORT: return "Short";
      case CAND_DOJI: return "Doji";
      case CAND_MARUBOZU: return "Marubozu";
      case CAND_HAMMER: return "Hammer";
      case CAND_INVERTED_HAMMER: return "InvertedHammer";
      case CAND_SPINNING_TOP: return "SpinningTop";
      default: return "Unknown";
   }
}
string TrendName(TYPE_TREND u)
{
   switch(u)
   {
      case TREND_UPPER: return "Ascending";
      case TREND_DOWN: return "Descending";
      case TREND_LATERAL: return "Lateral";
      default: return "Unknown";
   }
}
void UpdateComment()
{
   string tf=TFLabel();
   string msg="=== OneMinuteMan + Candle Scanner ===\n";
   msg+=StringFormat("Symbol:%s TF:%s\n",Symbol(),tf);
   msg+=StringFormat("Window:%d s (%d samples @%d ms)\n",InpWindowSize,InpWindowSize,InpSampleMs);
   msg+=StringFormat("Filled:%d/%d\n",g_count,InpWindowSize);
   msg+="---\n";
   msg+=StringFormat("High:%.5f Low:%.5f Range:%.5f\n",g_high,g_low,g_high-g_low);
   msg+=StringFormat("Ask:%.5f\n",Ask);
   msg+="---\n";
   msg+=StringFormat("Candle:%s Trend:%s Body:%.5f\n",CandleTypeName(g_candle.type),TrendName(g_candle.unit),g_candle.bodysize);
   msg+=StringFormat("OHLC:%.5f/%.5f/%.5f/%.5f\n",g_candle.open,g_candle.high,g_candle.low,g_candle.close);
   Comment(msg);
}
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpSampleMs<10){Print("Error: InpSampleMs>=10");return INIT_PARAMETERS_INCORRECT;}
   if(InpWindowSize<60||InpWindowSize>20000){Print("Error: InpWindowSize 60-20000");return INIT_PARAMETERS_INCORRECT;}
   if(InpAverPeriod<1||InpAverPeriod>500){Print("Error: InpAverPeriod 1-500");return INIT_PARAMETERS_INCORRECT;}
   ArrayResize(g_prices,BUFFER_SIZE);
   ArrayInitialize(g_prices,0.0);
   EventSetMillisecondTimer(InpSampleMs);
   Print("OneMinuteMan initialized: ",Symbol()," ",TFLabel());
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("OneMinuteMan stopped. Reason: ",reason);
}
void OnTimer()
{
   RefreshRates();
   g_prices[g_head]=Ask;
   g_count=MathMin(g_count+1,InpWindowSize);
   g_head=(g_head+1)%InpWindowSize;
   ScanHighLow();
   UpdateComment();
}
void OnTick()
{
   if(!IsNewBar()) return;
   CANDLE_STRUCTURE bar;
   if(RecognizeCandle(Symbol(),_Period,iTime(Symbol(),_Period,1),InpAverPeriod,bar))
   {
      g_candle=bar;
      Print(StringFormat("[%s] %s %s | Body=%.5f OHLC=%.5f/%.5f/%.5f/%.5f",
         TFLabel(),CandleTypeName(bar.type),TrendName(bar.unit),
         bar.bodysize,bar.open,bar.high,bar.low,bar.close));
   }
}
