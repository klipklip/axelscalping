//+------------------------------------------------------------------+
//| MT5 Expert Advisor: Conservative Micro-Scalper for EURUSD         |
//| Purpose: many small, low-risk trades with hard safety limits      |
//| Default Symbol: EURUSD, Timeframe: M5                            |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade trade;

input string InpSymbol = "EURUSD";               // Default symbol set to EURUSD (conservative)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5;    // Timeframe for signals

// Indicator settings
input int FastEMA = 5;
input int SlowEMA = 20;
input int RSIPeriod = 14;
input int RSIUpper = 60;
input int RSILower = 40;

// Risk & money management (conservative defaults)
input double RiskPercentPerTrade = 0.10;    // % of equity risked per trade if dynamic lots used
input double FixedLotSize = 0.01;           // conservative fixed lot size
input bool UseFixedLot = true;
input double MaxEquityDrawdownPercent = 3.0; // stop trading if equity drops this % from peak
input double DailyLossLimitPercent = 1.0;    // stop after losing this % within the calendar day
input int MaxConcurrentTrades = 2;
input int MaxConsecutiveLosses = 5;

// Trade parameters (in points) -- adjust if your broker uses different point conventions
input int TakeProfitPoints = 20;   // TP in points (conservative for EURUSD on M5)
input int StopLossPoints = 50;     // SL in points (wider than TP to allow noise)
input int TrailingStart = 12;      // start trailing when profit (points)
input int TrailingStep = 8;        // trailing step in points

// Safety filters
input int MaxSpreadPoints = 50;   // maximum allowed spread (points) -- conservative for majors
input int MinMinutesBetweenTrades = 1; // throttling

// Misc
input int MagicNumber = 20251106;
input bool TradeOnMonday = true;
input bool TradeOnFriday = true;
input bool AllowTrading = true;

// Internal globals
datetime lastTradeTime = 0;
double peakEquity = 0.0;
double dailyLossToday = 0.0;
int consecLosses = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("[EA] Initialized for %s on timeframe %d. FixedLot=%s %.2f", InpSymbol, InpTimeframe, UseFixedLot?"true":"false", FixedLotSize);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!AllowTrading) return;

   // update safety globals
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(curEquity>peakEquity) peakEquity = curEquity;

   // check equity drawdown
   if( (peakEquity - curEquity)/peakEquity*100.0 >= MaxEquityDrawdownPercent )
     {
      // emergency stop: disable trading
      AllowTrading = false;
      Print("[EA] Emergency stop: equity drawdown exceeded. Disabling trading.");
      return;
     }

   // check daily loss reset (simple calendar-day based)
   static datetime lastDay=0;
   datetime now = TimeCurrent();
   MqlDateTime mt; TimeToStruct(now,mt);
   if(lastDay!=mt.day)
     {
      dailyLossToday = 0.0; lastDay=mt.day;
     }

   // calculate daily loss percent relative to balance
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance>0 && (dailyLossToday / balance * 100.0) <= -DailyLossLimitPercent )
     {
      AllowTrading = false; Print("[EA] Daily loss limit exceeded. Disabling trading."); return;
     }

   // throttle by spread
   double spread = SymbolInfoDouble(InpSymbol,SYMBOL_SPREAD);
   if(spread>MaxSpreadPoints) return;

   // weekday filters
   int w = TimeDayOfWeek(now);
   if((w==1 && !TradeOnMonday) || (w==5 && !TradeOnFriday)) return;

   // limit concurrent trades
   int openCount = CountOpenTradesByMagic(MagicNumber, InpSymbol);
   if(openCount>=MaxConcurrentTrades) return;

   // ensure minimal time between trades
   if((now - lastTradeTime) < MinMinutesBetweenTrades*60) return;

   // Run signal on new bar of InpTimeframe
   static datetime lastBarTime = 0;
   datetime barTime = iTime(InpSymbol, InpTimeframe, 0);
   if(barTime==lastBarTime) return; // wait for new bar
   lastBarTime = barTime;

   double fast = iMA(InpSymbol, InpTimeframe, FastEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
   double slow = iMA(InpSymbol, InpTimeframe, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(InpSymbol, InpTimeframe, RSIPeriod, PRICE_CLOSE, 0);

   // conservative signal: trend-following with RSI confirmation
   if(fast>slow && rsi>52 && rsi<RSIUpper)
     {
      // try buy
      if(CanOpenLong()) OpenOrder(ORDER_TYPE_BUY);
     }
   else if(fast<slow && rsi<48 && rsi>RSILower)
     {
      // try sell
      if(CanOpenShort()) OpenOrder(ORDER_TYPE_SELL);
     }

   // manage trailing stops
   ManageTrailingStops();
  }

//+------------------------------------------------------------------+
bool CanOpenLong()
  {
   // extra checks can go here (session times, simple spread check done earlier)
   return true;
  }

bool CanOpenShort()
  {
   return true;
  }

//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type)
  {
   double lot = UseFixedLot ? FixedLotSize : CalculateLotSize();
   if(lot<=0) { Print("[EA] Calculated lot <= 0"); return; }

   double price = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(InpSymbol,SYMBOL_ASK) : SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   double sl = 0, tp = 0;
   if(type==ORDER_TYPE_BUY)
     {
      sl = price - StopLossPoints * _Point;
      tp = price + TakeProfitPoints * _Point;
     }
   else
     {
      sl = price + StopLossPoints * _Point;
      tp = price - TakeProfitPoints * _Point;
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(200);
   bool ok=false;
   if(type==ORDER_TYPE_BUY) ok = trade.Buy(lot, InpSymbol, price, sl, tp, "EA Micro-Scalper EURUSD");
   else ok = trade.Sell(lot, InpSymbol, price, sl, tp, "EA Micro-Scalper EURUSD");

   if(ok)
     {
      lastTradeTime = TimeCurrent();
      PrintFormat("[EA] Opened %s %.2f %s TP:%d SL:%d", EnumToString(type), lot, InpSymbol, TakeProfitPoints, StopLossPoints);
     }
   else
     {
      PrintFormat("[EA] Trade request failed: %d", GetLastError());
     }
  }

//+------------------------------------------------------------------+
double CalculateLotSize()
  {
   // simple risk based position sizing using StopLossPoints
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercentPerTrade/100.0);
   double slPrice = StopLossPoints * _Point;
   double tickValue = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0) tickSize = _Point;
   double lot = 0.0;
   if(tickValue>0)
     {
      double moneyPerPointPerLot = tickValue/tickSize;
      if(moneyPerPointPerLot>0)
         lot = NormalizeDouble(riskAmount / (StopLossPoints * moneyPerPointPerLot),2);
     }
   double maxV = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
   double minV = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
   if(maxV>0 && lot>maxV) lot=maxV;
   if(minV>0 && lot<minV) lot=0.0;
   return(lot);
  }

//+------------------------------------------------------------------+
int CountOpenTradesByMagic(int magic, string symbol)
  {
   int total=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if((int)PositionGetInteger(POSITION_MAGIC)==magic && PositionGetString(POSITION_SYMBOL)==symbol) total++;
        }
     }
   return total;
  }

//+------------------------------------------------------------------+
void ManageTrailingStops()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? SymbolInfoDouble(sym,SYMBOL_BID) : SymbolInfoDouble(sym,SYMBOL_ASK);
      double profitPoints = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;
      ulong ticketNum = PositionGetInteger(POSITION_TICKET);
      double newSL=0;
      if(profitPoints>TrailingStart)
        {
         if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
           {
            newSL = currentPrice - (TrailingStep*_Point);
            if(newSL>PositionGetDouble(POSITION_SL))
              {
               trade.PositionModify(ticketNum,newSL,PositionGetDouble(POSITION_TP));
              }
           }
         else
           {
            newSL = currentPrice + (TrailingStep*_Point);
            if(newSL<PositionGetDouble(POSITION_SL))
              {
               trade.PositionModify(ticketNum,newSL,PositionGetDouble(POSITION_TP));
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
string EnumToString(ENUM_ORDER_TYPE type)
  {
   if(type==ORDER_TYPE_BUY) return "BUY";
   if(type==ORDER_TYPE_SELL) return "SELL";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
// NOTE: This EA is tuned with conservative defaults for EURUSD on M5.
// You MUST backtest and forward-test on a demo account. Adjust TP/SL,
// spread limits and lot sizing to match your broker's symbol conventions.
//+------------------------------------------------------------------+

