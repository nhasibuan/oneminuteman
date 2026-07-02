# OneMinuteMan EA — v7.00

**OneMinuteMan** is a MetaTrader 4 Expert Advisor (MQL4) that combines three real-time engines on a forced M1 timeframe:

1. **Rolling 60-second range scanner** — circular buffer sampled every 50 ms
2. **M1 candlestick pattern recognizer** — 10 pattern types including Hammer, Marubozu, Doji variants
3. **ZigZag PPM (Pips-Per-Minute) efficiency engine** — ZZ(2-2-1) measures momentum quality

Trade execution is gated by PPM zone, candle signal, volume spike filter, session window, and spread filter. After a losing cycle, an ADR-spaced martingale re-entry is armed in the **same direction** as the losing trade.

---

## What's New in v7.00

| Feature | Description |
|---|---|
| **Virtual Hidden SL** | `InpHideSL=true` sends orders with SL=0 (invisible to broker); EA enforces stop internally via `VslCheck()` on every tick and timer |
| **Volume Spike Filter** | `InpUseVolumeFilter=true` suppresses entries on low-conviction bars; requires last bar volume ≥ `InpVolMultiplier × 20-bar average |
| **ADR pre-load on init** | `g_adr_pips` is now computed in `OnInit()`, eliminating the race where martingale re-entry fired with ADR=0 before the first timer tick |
| **Martingale direction clarified** | Re-entry is **same direction** as the losing trade (doubled-down, not counter-trade) — code, comments and README all now consistent |
| **Version display** | Comment panel updated to `v7.00`; log lines updated |

---

## Architecture

```
OnTimer() [every 50ms]
  ├─ Sample Ask → circular buffer
  ├─ ScanHighLow()        rolling 60s range
  ├─ CalcPPM()            ZigZag efficiency
  ├─ CalcADR()            daily range for martingale spacing
  ├─ ManageTrailing()     trail open positions
  ├─ VslCheck()           enforce virtual stop losses
  └─ UpdateComment()      HUD display

OnTick()
  ├─ IsNewBar()           M1 bar guard
  ├─ RecognizeCandle()    last closed M1 bar pattern
  ├─ UpdateTradeState()   detect closed cycles, arm martingale
  ├─ ManageTrailing()
  ├─ VslCheck()
  └─ ManageEntries()      entry logic (fresh + martingale re-entry)
```

---

## Input Parameters

### Range Scanner
| Parameter | Default | Description |
|---|---|---|
| `InpSampleMs` | 50 | Sampling interval in milliseconds (min 10) |
| `InpWindowSize` | 1200 | Buffer size: 1200 × 50ms = 60s rolling window |

### Candle Recognizer
| Parameter | Default | Description |
|---|---|---|
| `InpAverPeriod` | 14 | SMA period for average body and trend detection |

### PPM Engine
| Parameter | Default | Description |
|---|---|---|
| `InpZzDepth` | 2 | ZigZag depth (recommended 2 for M1) |
| `InpZzDeviation` | 2 | ZigZag deviation |
| `InpZzBackstep` | 1 | ZigZag backstep (must be < Depth) |
| `InpZzLookback` | 100 | Bars to scan for ZigZag pivots |
| `InpPpmMinHigh` | 2.0 | Minimum PPM to allow entry (MEDIUM zone) |
| `InpPpmTarget` | 4.0 | Target PPM for HIGH zone (ideal entry) |
| `InpAtrDailyRef` | 1.5 | ATR M1 baseline in pips (volatility ratio reference) |
| `InpShowPPM` | true | Show PPM panel in chart comment |

### Volume Filter
| Parameter | Default | Description |
|---|---|---|
| `InpUseVolumeFilter` | true | Enable volume spike filter for entry |
| `InpVolLookback` | 20 | Bars to average volume over |
| `InpVolMultiplier` | 1.5 | Last bar volume must be ≥ this × average |

### Trade Management
| Parameter | Default | Description |
|---|---|---|
| `InpEnableTrading` | false | Master switch — must be `true` for live execution |
| `InpBaseLots` | 0.01 | Base lot size for first entry |
| `InpSlippage` | 0 | Max slippage in points; 0 = auto per symbol |
| `InpMaxSpread` | 0 | Max spread in points; 0 = auto per symbol |
| `InpMagic` | 202506 | Magic number for position identification |
| `InpTP_Pips` | 0 | Take profit in pips; 0 = auto |
| `InpSL_Pips` | 0 | Stop loss in pips; 0 = auto |
| `InpHideSL` | true | **Virtual SL** — hide stop loss from broker terminal |
| `InpTrailStart` | 0 | Trailing stop activation distance in pips; 0 = auto |
| `InpTrailStep` | 0 | Trailing stop distance in pips; 0 = auto |

### Martingale Re-Entry (ADR-Spaced)
| Parameter | Default | Description |
|---|---|---|
| `InpUseMartingale` | true | Enable martingale re-entry after a loss |
| `InpMartMult` | 2.0 | Lot size multiplier per martingale step |
| `InpMartMaxSteps` | 5 | Maximum martingale steps before daily halt |
| `InpAdrPeriod` | 14 | Days to average for ADR calculation |
| `InpAdrFraction` | 0.10 | Re-entry spacing = this fraction × ADR pips |

> **Direction note**: Martingale re-entry fires in the **same direction** as the previous losing trade — it doubles down on the original bias, it does NOT counter-trade.

### Session Filter
| Parameter | Default | Description |
|---|---|---|
| `InpTzOffsetHours` | 7 | Local timezone offset from UTC (UTC+7 = WIB) |
| `InpSessionStartHour` | 5 | Local hour to start trading (Sydney open ~5) |
| `InpSessionEndHour` | 24 | Local hour to stop opening new trades |

---

## Per-Symbol Auto Profiles

When inputs are left at 0, the EA auto-selects sensible defaults:

| Symbol | TP | SL | Trail Start | Trail Step | Slippage | Max Spread |
|---|---|---|---|---|---|---|
| **XAU/USD** | 150 pips | 250 pips | 100 pips | 50 pips | 30 pts | 50 pts |
| **EUR/USD** | 6 pips | 8 pips | 5 pips | 3 pips | 5 pts | 15 pts |
| Generic FX | 10 pips | 15 pips | 8 pips | 5 pips | 10 pts | 25 pts |

> For XAU/USD ECN: actual realtime spread is typically 20–40 pts during London/NY overlap. Tighten `InpMaxSpread` to 35 for better quality fills during active sessions.

---

## Virtual Hidden Stop Loss

When `InpHideSL = true` (default):
- Orders are submitted with **SL = 0** — no stop loss visible to the broker or in the MT4 terminal
- The EA stores the intended SL price in an internal `VSL_ENTRY` array keyed by ticket number
- `VslCheck()` runs on **every timer tick (50ms) and every price tick** — if price crosses the virtual threshold, `OrderClose()` is called immediately
- Trailing stop updates also move the virtual SL level upward (for buys) / downward (for sells)
- This prevents broker stop-hunting on visible stop clusters, especially important for XAU/USD

---

## Volume Spike Filter

When `InpUseVolumeFilter = true` (default), fresh entries are suppressed unless:
```
iVolume(Symbol, M1, 1) >= InpVolMultiplier × average(iVolume, last InpVolLookback bars)
```
This uses MT4 tick volume as a proxy for institutional activity. Entries during high-volume bars (breakouts, news reactions) have statistically stronger follow-through than low-volume indecision patterns. The filter status (`[PASS]` / `[SUPPRESS]`) is shown in the HUD and printed to the Experts log on every new bar.

> Martingale re-entries **bypass** the volume filter intentionally — they are risk-management re-entries, not fresh signal entries.

---

## Martingale Risk Table

With defaults `InpBaseLots=0.01`, `InpMartMult=2.0`, `InpMartMaxSteps=5`:

| Step | Lots | Cumulative Lots |
|---|---|---|
| 1 (fresh) | 0.01 | 0.01 |
| 2 | 0.02 | 0.03 |
| 3 | 0.04 | 0.07 |
| 4 | 0.08 | 0.15 |
| 5 | 0.16 | 0.31 |

⚠️ On XAU/USD, 0.16 lots = ~$16/pip. A 250-pip adverse move at step 5 = $4,000 drawdown. Size `InpBaseLots` conservatively relative to account equity.

---

## PPM Efficiency Zones

| Zone | PPM Value | Meaning |
|---|---|---|
| LOW [AVOID] | < 2.0 | Market moving too slowly — skip |
| MEDIUM [WATCH] | ≥ 2.0 | Acceptable momentum — entry allowed |
| HIGH [ENTER] | ≥ 4.0 | Strong momentum — ideal entry conditions |

PPM = (pip distance between last two ZigZag pivots) ÷ (M1 candles elapsed between pivots)

---

## Candle Patterns & Signal Direction

| Pattern | Signal |
|---|---|
| Hammer | +1 (Long) |
| Dragonfly Doji | +1 (Long) |
| Inverted Hammer | -1 (Short) |
| Gravestone Doji | -1 (Short) |
| Long / Marubozu + Ascending trend | +1 (Long) |
| Long / Marubozu + Descending trend | -1 (Short) |
| All others | 0 (No signal) |

---

## Requirements

- MetaTrader 4 terminal
- Built-in **ZigZag** indicator must be available (standard MT4 indicator)
- VPS recommended for reliable 50ms timer resolution and low-latency order execution
- ECN/STP broker with raw spreads recommended for XAU/USD

---

## License

Copyright 2025, nhasibuan. See repository for license terms.
