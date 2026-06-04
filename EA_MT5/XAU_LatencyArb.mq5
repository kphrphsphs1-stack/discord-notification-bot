//+------------------------------------------------------------------+
//|                                              XAU_LatencyArb.mq5  |
//|                         XAUUSD Latency Arbitrage EA - MT5        |
//|                  Strategy: Dark Arb / Toxic Flow Detection        |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.00"
#property description "Latency Arbitrage EA for XAUUSD M15"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Arbitrage Settings
input group "=== ARBITRAGE SETTINGS ==="
input int    FastEMA_Period  = 5;     // Fast EMA Period
input int    SlowEMA_Period  = 20;    // Slow EMA Period
input double DevThreshold    = 0.08;  // Price Deviation Threshold (%)
input int    TickWindow      = 20;    // Tick buffer window size
input double MinSpread       = 2.0;   // Min spread to trade (points)
input double MaxSpread       = 30.0;  // Max spread to trade (points)

//--- Risk Management
input group "=== RISK MANAGEMENT ==="
input double RiskPercent     = 1.0;   // Risk per trade (% of balance)
input double SL_Points       = 500;   // Stop Loss (points)
input double TP_Points       = 1000;  // Take Profit (points)
input int    MaxTrades       = 1;     // Max simultaneous trades
input bool   UseTrailingStop = true;  // Enable Trailing Stop
input double TrailPoints     = 300;   // Trailing Stop distance (points)
input double TrailStep       = 50;    // Trailing Stop step (points)

//--- Session Filter
input group "=== SESSION FILTER ==="
input bool   London_Session  = true;  // London (08:00-16:00 GMT)
input bool   NewYork_Session = true;  // New York (13:00-21:00 GMT)
input bool   Asian_Session   = false; // Asian (00:00-08:00 GMT)

//--- Trade Settings
input group "=== TRADE SETTINGS ==="
input int    MagicNumber     = 20250604;
input int    Slippage        = 15;    // Max slippage (points)
input string TradeComment    = "XAU_LatArb";

//--- Global Variables
CTrade       trade;
CPositionInfo posInfo;

int          fastHandle, slowHandle;
double       fastBuf[], slowBuf[];
double       tickBuffer[];
int          tickCount    = 0;
datetime     lastBarTime  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(Symbol() != "XAUUSD" && Symbol() != "GOLD" && StringFind(Symbol(), "XAU") < 0)
      Print("WARNING: EA designed for XAUUSD. Current symbol: ", Symbol());

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   fastHandle = iMA(Symbol(), Period(), FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(Symbol(), Period(), SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA handles");
      return INIT_FAILED;
   }

   ArraySetAsSeries(fastBuf, true);
   ArraySetAsSeries(slowBuf, true);
   ArrayResize(tickBuffer, TickWindow + 1);
   ArrayInitialize(tickBuffer, 0.0);

   Print("=== XAU Latency Arb EA Started ===");
   Print("Symbol: ", Symbol(), " | TF: ", EnumToString(Period()));
   Print("Risk: ", RiskPercent, "% | SL: ", SL_Points, " pts | TP: ", TP_Points, " pts");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);
   Print("EA deinitialized | Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Filter by session
   if(!IsTradeSession()) return;

   // Filter by spread
   double currentSpread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * _Point;
   if(currentSpread < MinSpread * _Point || currentSpread > MaxSpread * _Point) return;

   // Update tick buffer every tick
   UpdateTickBuffer(SymbolInfoDouble(Symbol(), SYMBOL_BID));

   // Manage trailing stop on every tick
   if(UseTrailingStop) ManageTrailingStop();

   // New bar check - only recalculate on new M15 bar
   datetime currentBar = iTime(Symbol(), Period(), 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Skip if max trades reached
   if(CountOpenTrades() >= MaxTrades) return;

   // Refresh indicator buffers
   if(CopyBuffer(fastHandle, 0, 0, 3, fastBuf) < 3) return;
   if(CopyBuffer(slowHandle, 0, 0, 3, slowBuf) < 3) return;

   // Detect signal
   int signal = DetectArbitrageSignal();
   if(signal == 0) return;

   // Execute trade
   ExecuteTrade(signal == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
void UpdateTickBuffer(double price)
{
   // Shift buffer right, insert latest price at [0]
   for(int i = TickWindow - 1; i > 0; i--)
      tickBuffer[i] = tickBuffer[i - 1];
   tickBuffer[0] = price;

   if(tickCount < TickWindow) tickCount++;
}

//+------------------------------------------------------------------+
//| Core latency arbitrage detection logic                             |
//| Concept: Compare current "fast feed" price vs rolling average     |
//| of recent ticks (simulates "slow feed" / lagged broker price)     |
//+------------------------------------------------------------------+
int DetectArbitrageSignal()
{
   if(tickCount < TickWindow) return 0;

   double fastPrice = tickBuffer[0];

   // Rolling average of older ticks = "slow feed" simulation
   double slowAvg = 0;
   for(int i = 1; i < TickWindow; i++)
      slowAvg += tickBuffer[i];
   slowAvg /= (TickWindow - 1);

   if(slowAvg <= 0) return 0;

   // Price deviation of fast vs slow feed
   double deviation = (fastPrice - slowAvg) / slowAvg * 100.0;

   // EMA trend confirmation
   bool crossUp   = fastBuf[1] <= slowBuf[1] && fastBuf[0] > slowBuf[0];
   bool crossDown = fastBuf[1] >= slowBuf[1] && fastBuf[0] < slowBuf[0];
   bool upTrend   = fastBuf[0] > slowBuf[0];
   bool downTrend = fastBuf[0] < slowBuf[0];

   // BUY: Price dipped below slow average (underpriced) + bullish EMA
   if(deviation < -DevThreshold && (crossUp || upTrend))
   {
      Print("BUY Signal | Dev: ", DoubleToString(deviation, 4),
            "% | FastEMA: ", fastBuf[0], " | SlowEMA: ", slowBuf[0]);
      return 1;
   }

   // SELL: Price spiked above slow average (overpriced) + bearish EMA
   if(deviation > DevThreshold && (crossDown || downTrend))
   {
      Print("SELL Signal | Dev: ", DoubleToString(deviation, 4),
            "% | FastEMA: ", fastBuf[0], " | SlowEMA: ", slowBuf[0]);
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on % risk and fixed SL                   |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;

   double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0 || tickValue <= 0) return SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);

   double pointValue = (tickValue / tickSize) * _Point;
   double slValue    = SL_Points * pointValue;

   if(slValue <= 0) return SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);

   double lots    = riskAmount / slValue;
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return lots;
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType)
{
   double ask    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double slPts  = SL_Points * _Point;
   double tpPts  = TP_Points * _Point;
   double lots   = CalculateLotSize();
   double price, sl, tp;

   if(orderType == ORDER_TYPE_BUY)
   {
      price = ask;
      sl    = NormalizeDouble(price - slPts, _Digits);
      tp    = NormalizeDouble(price + tpPts, _Digits);
   }
   else
   {
      price = bid;
      sl    = NormalizeDouble(price + slPts, _Digits);
      tp    = NormalizeDouble(price - tpPts, _Digits);
   }

   string comment = TradeComment + "_" + IntegerToString(MagicNumber);
   bool   result  = trade.PositionOpen(Symbol(), orderType, lots, price, sl, tp, comment);

   if(result)
      Print("Trade opened | ", EnumToString(orderType),
            " | Lots: ", DoubleToString(lots, 2),
            " | Entry: ", DoubleToString(price, _Digits),
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits),
            " | Risk: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0, 2));
   else
      Print("Trade FAILED | Error: ", GetLastError(), " | ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double trailDist = TrailPoints * _Point;
   double trailStep = TrailStep * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != MagicNumber) continue;
      if(posInfo.Symbol() != Symbol()) continue;

      double currentSL = posInfo.StopLoss();
      double openPrice = posInfo.PriceOpen();
      double bid       = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double ask       = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         // Only move SL if it improves and moves by at least trailStep
         if(newSL > currentSL + trailStep && newSL > openPrice)
            trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < currentSL - trailStep && newSL < openPrice)
            trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
      }
   }
}

//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() == MagicNumber && posInfo.Symbol() == Symbol())
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Session filter (GMT+0 based)                                       |
//+------------------------------------------------------------------+
bool IsTradeSession()
{
   MqlDateTime dt;
   TimeGMT(dt);
   int h = dt.hour;

   if(Asian_Session  && h >= 0  && h < 8)  return true;
   if(London_Session && h >= 8  && h < 16) return true;
   if(NewYork_Session && h >= 13 && h < 21) return true;

   return false;
}

//+------------------------------------------------------------------+
//| Display info on chart                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   Comment("XAU Latency Arb EA\n",
           "Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), "\n",
           "Open Trades: ", CountOpenTrades(), "/", MaxTrades, "\n",
           "Risk/Trade: ", RiskPercent, "%\n",
           "Session: ", IsTradeSession() ? "ACTIVE" : "CLOSED");
}
//+------------------------------------------------------------------+
