# OneMinuteMan

A MetaTrader 4 Expert Advisor (MQL4) that forces all analysis onto the **M1 (1-minute)** timeframe. It combines a tick-sampled range scanner, a candlestick recognizer, a **PPM (Pips-Per-Minute) efficiency engine**, a tick-volume spike filter, virtual (hidden) stop losses, trailing stops, take-profit, and an ADR-spaced martingale that can run in **SAME** or **REVERSE** direction.

> **High-risk software.** This EA uses martingale position sizing and broker-hidden (virtual) stop losses. Both dramatically increase blow-up risk. Use on a demo account first. Nothing here is financial advice.

## Table of contents
- [How it works](#how-it-works)
- [Signal logic](#signal-logic)
- [Martingale modes](#martingale-modes)
- [Installation](#installation)
- [Inputs](#inputs)
- [Risk warnings](#risk-warnings)


## How it works

Two event handlers drive the EA:

- **`OnTimer()`** (every `InpSampleMs`, default 50 ms): samples Ask into a circular buffer, recomputes the rolling high/low range and PPM, manages trailing stops, and enforces the virtual SL.
- **`OnTick()`** (each new M1 bar): recognizes the closed candle, refreshes ADR, updates cycle state, and evaluates entries.

Engines:

| Engine | Purpose |
|---|---|
| Range Scanner | ~60 s rolling high/low from tick samples (informational panel). |
| Candle Recognizer | Classifies the last closed M1 candle + trend vs. SMA. |
| PPM Engine | Efficiency = pip distance of last ZigZag(2-2-1) leg / M1 candles elapsed. |
| Trade Module | Orders, virtual SL, volume filter, trailing, TP, session gating, martingale. |

## Signal logic

A fresh trade opens only when **all** conditions hold:

1. `InpEnableTrading = true`
2. No open position, inside session hours, spread within limit
3. PPM zone is MEDIUM or HIGH
4. Tick volume >= `InpVolMultiplier` x average
5. The candle produces a directional signal

## Martingale modes

After a losing trade, and once price has moved adversely by `InpAdrFraction x ADR` pips, the EA re-enters with `InpMartMult` x the previous lot size. The re-entry direction is controlled by **`InpMartMode`**:

| Mode | Value | Behavior |
|---|---|---|
| `MART_SAME_DIRECTION` | 0 | Classic martingale — re-enter the **same** direction as the losing trade (average down). |
| `MART_REVERSE_DIRECTION` | 1 | **Reverse** martingale — re-enter the **opposite** direction. Because the tracked direction flips each step, consecutive re-entries alternate. |

Both modes stop after `InpMartMaxSteps` and then halt trading until the next session open.

## Installation

1. Copy `oneminuteman.mq4` into `MQL4/Experts/`.
2. Ensure the built-in **ZigZag** indicator is available in `MQL4/Indicators/`.
3. Restart MetaTrader 4 or refresh the Navigator, then compile in MetaEditor.
4. Attach to any chart (analysis is forced to M1) and allow automated trading.
5. Keep `InpEnableTrading = false` until you have demo-tested.

## Inputs

Key inputs (see the source for the full list):

- **Range/Candle/PPM:** `InpSampleMs`, `InpWindowSize`, `InpAverPeriod`, `InpZzDepth/Deviation/Backstep`, `InpZzLookback`, `InpPpmMinHigh`, `InpPpmTarget`, `InpAtrDailyRef`.
- **Volume filter:** `InpUseVolumeFilter`, `InpVolLookback`, `InpVolMultiplier`.
- **Execution:** `InpEnableTrading`, `InpBaseLots`, `InpSlippage`, `InpMaxSpread`, `InpMagic`, `InpTP_Pips`, `InpSL_Pips`, `InpHideSL`, `InpTrailStart`, `InpTrailStep`.
- **Martingale:** `InpUseMartingale`, **`InpMartMode` (SAME / REVERSE)**, `InpMartMult`, `InpMartMaxSteps`, `InpAdrPeriod`, `InpAdrFraction`.
- **Session:** `InpTzOffsetHours`, `InpSessionStartHour`, `InpSessionEndHour`.

## Risk warnings

- **Martingale** can produce large, fast drawdowns; a sustained adverse move can wipe an account.
- **Hidden/virtual SL** relies on the terminal staying connected. If the platform, VPS, or EA stops, positions have **no broker-side stop**. Consider adding a wide broker-side disaster SL.
- **Tick volume** is a proxy for real volume in MT4.
- **M1 trading** is heavily affected by spread and commission.
- Add an equity/drawdown kill-switch before any live use.
