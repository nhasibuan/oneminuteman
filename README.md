# OneMinuteMan

A MetaTrader 4 Expert Advisor (MQL4) that forces all analysis onto the **M1 (1-minute)** timeframe. It combines a tick-sampled range scanner, a candlestick recognizer, a **PPM (Pips-Per-Minute) efficiency engine**, a tick-volume spike filter, **ATR-dynamic** virtual (hidden) stop losses / take-profit / trailing, **adaptive slippage & max-spread** (from rolling averages, any symbol), and an **immediate, volume-gated** martingale that can run in **SAME** or **REVERSE** direction.

> **High-risk software.** This EA uses martingale position sizing and broker-hidden (virtual) stop losses, and re-enters immediately after a loss. These dramatically increase blow-up risk. Use on a demo account first. Nothing here is financial advice.

## Table of contents
- [How it works](#how-it-works)
- [Signal logic](#signal-logic)
- [Martingale modes](#martingale-modes)
- [Dynamic risk (ATR)](#dynamic-risk-atr)
- [Adaptive execution (spread & slippage)](#adaptive-execution-spread--slippage)
- [Installation](#installation)
- [Inputs](#inputs)
- [Risk warnings](#risk-warnings)
- [Changelog](#changelog)

## How it works

Two event handlers drive the EA:

- **`OnTimer()`** (every `InpSampleMs`, default 50 ms): samples Ask into a circular buffer, updates the rolling average spread (`g_spread_ema`), recomputes the range and PPM, manages trailing stops, and enforces the virtual SL.
- **`OnTick()`** (each new M1 bar): recognizes the closed candle, updates cycle state, and evaluates entries.

Engines:

| Engine | Purpose |
|---|---|
| Range Scanner | ~60 s rolling high/low from tick samples (informational panel). |
| Candle Recognizer | Classifies the last closed M1 candle + trend vs. SMA. |
| PPM Engine | Efficiency = pip distance of last ZigZag(2-2-1) leg / M1 candles elapsed. |
| Trade Module | Orders, ATR-dynamic virtual SL/TP/trailing, volume filter, adaptive execution, session gating, martingale. |

## Signal logic

A fresh trade opens only when **all** conditions hold:

1. `InpEnableTrading = true`
2. No open position, inside session hours, spread within the adaptive limit
3. PPM zone is MEDIUM or HIGH
4. Tick volume >= `InpVolMultiplier` x average
5. The candle produces a directional signal

## Martingale modes

After a losing trade the EA **re-enters immediately as soon as the volume filter passes** — there is **no ADR / adverse-move spacing**. It re-enters with `InpMartMult` x the previous lot size. The re-entry direction is controlled by **`InpMartMode`**:

| Mode | Value | Behavior |
|---|---|---|
| `MART_SAME_DIRECTION` | 0 | Classic martingale — re-enter the **same** direction as the losing trade (average down). |
| `MART_REVERSE_DIRECTION` | 1 | **Reverse** martingale — re-enter the **opposite** direction. Because the tracked direction flips each step, consecutive re-entries alternate. |

Both modes stop after `InpMartMaxSteps` and then halt trading until the next session open.

## Dynamic risk (ATR)

Stop loss, take profit, and trailing values are derived from the recent **M1 ATR** so they adapt to current volatility:

- `SL pips = ATR(pips) x InpAtrSLMult`
- `TP pips = ATR(pips) x InpAtrTPMult`
- `Trailing activation = ATR(pips) x InpAtrTrailStartMult`
- `Trailing distance = ATR(pips) x InpAtrTrailStepMult`
- A floor (`InpMinRiskPips`) prevents zero/near-zero values when ATR is tiny.

Each of `InpSL_Pips`, `InpTP_Pips`, `InpTrailStart`, `InpTrailStep` acts as a manual override: set it above 0 to use a fixed value instead of the ATR-derived one.

## Adaptive execution (spread & slippage)

Max allowed spread and slippage are computed from a **rolling EMA of the live spread** (in points), so the EA works on **any symbol** without hardcoded gold/EUR profiles:

- `Max spread = avg spread(points) x InpMaxSpreadMult`
- `Slippage = avg spread(points) x InpSlippageMult`
- `InpSprEmaAlpha` controls how quickly the average adapts.
- `InpMaxSpread` / `InpSlippage` act as manual overrides when set above 0.

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
- **Dynamic risk (ATR):** `InpAtrPeriod`, `InpAtrSLMult`, `InpAtrTPMult`, `InpAtrTrailStartMult`, `InpAtrTrailStepMult`, `InpMinRiskPips`.
- **Adaptive execution:** `InpMaxSpreadMult`, `InpSlippageMult`, `InpSprEmaAlpha`.
- **Martingale:** `InpUseMartingale`, **`InpMartMode` (SAME / REVERSE)**, `InpMartMult`, `InpMartMaxSteps`.
- **Session:** `InpTzOffsetHours`, `InpSessionStartHour`, `InpSessionEndHour`.

## Risk warnings

- **Immediate martingale re-entry** removes the previous ADR spacing, so losing cycles can stack up very quickly. Combined with lot multiplication this is extremely aggressive.
- **Martingale** can produce large, fast drawdowns; a sustained adverse move can wipe an account.
- **Hidden/virtual SL** relies on the terminal staying connected. If the platform, VPS, or EA stops, positions have **no broker-side stop**. Consider adding a wide broker-side disaster SL.
- **Tick volume** is a proxy for real volume in MT4.
- **M1 trading** is heavily affected by spread and commission.
- Add an equity/drawdown kill-switch before any live use.

## Changelog

### v9.00
- **Immediate martingale re-entry:** removed ADR-based spacing; re-entry now fires as soon as the volume filter passes.
- **ATR-dynamic risk:** SL, TP, and trailing are derived from M1 ATR (with manual overrides and a safety floor).
- **Adaptive execution:** slippage and max spread are computed from a rolling average spread and work on any symbol; removed the hardcoded XAU/EUR profiles.
- Updated panel, input validation, version header, and description.

### v8.00
- SAME/REVERSE martingale direction via `ENUM_MART_MODE`; named candle-recognition constants; ADR pre-loaded in `OnInit()`.

### v7.00
- Virtual hidden SL (`InpHideSL`); volume spike filter; version display panel.
