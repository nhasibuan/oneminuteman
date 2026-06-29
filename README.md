# OneMinuteMan

> **MetaTrader 4 Expert Advisor** — Rolling 1-minute price range scanner with single-bar candlestick pattern recognition engine.

[![Platform](https://img.shields.io/badge/Platform-MetaTrader%204-blue)](https://www.metatrader4.com)
[![Language](https://img.shields.io/badge/Language-MQL4-orange)](https://docs.mql4.com)
[![Version](https://img.shields.io/badge/Version-4.00-green)](https://github.com/nhasibuan/oneminuteman)
[![License](https://img.shields.io/badge/License-MIT-lightgrey)](LICENSE)

---

## Table of Contents

- [Product Requirements](#product-requirements)
- [Overview](#overview)
- [Features](#features)
- [Architecture & Blueprint](#architecture--blueprint)
- [Dataflow](#dataflow)
- [Installation](#installation)
- [Input Parameters](#input-parameters)
- [Data Dictionary](#data-dictionary)
- [Candle Classification Rules](#candle-classification-rules)
- [Known Limitations](#known-limitations)

---

## Product Requirements

### PRD — OneMinuteMan EA

#### Problem Statement

Manual traders monitoring short-term price action on MetaTrader 4 have no native, non-blocking tool that simultaneously tracks the intrabar price range (sub-minute resolution) and classifies the most recently closed bar into a named candlestick pattern with trend context. Existing solutions require separate indicators, introduce UI-blocking alert dialogs, or rely on architecturally unsafe infinite loops inside `OnInit()`.

#### Goals

| # | Goal | Success Metric |
|---|---|---|
| G1 | Track rolling 1-minute Ask price range in real time | High and low updated within 50 ms of price change |
| G2 | Classify the last closed bar into a named single-candle pattern | Pattern identified correctly within one tick of bar close |
| G3 | Display both range and pattern data on chart without blocking UI | `Comment()` overlay — zero modal popups |
| G4 | Provide clean, extensible entry point for order logic | `OnTick()` exposes `g_high`, `g_low`, `g_candle` for trade logic |
| G5 | Adhere to MQL4 best practices (event-driven, no `while(1)`) | Compiles with `#property strict`; EA removable cleanly |

#### Non-Goals

- Does **not** place, modify, or close orders (scaffolding only)
- Does **not** implement multi-candle patterns (Engulfing, Harami, Star composites)
- Does **not** support MQL5 / MetaTrader 5 natively (separate port required)
- Does **not** persist data between EA restarts (in-memory only)

#### User Stories

| ID | As a… | I want to… | So that… |
|---|---|---|---|
| US-01 | Scalp trader | See the 1-minute Ask high/low live on chart | I can gauge intrabar volatility at a glance |
| US-02 | Price action trader | Know the candlestick type of the last closed bar | I can confirm or reject a setup without switching tools |
| US-03 | EA developer | Have a clean `OnTick()` entry point with range + pattern data | I can add order logic without restructuring the EA |
| US-04 | MT4 user | Remove the EA without freezing the terminal | The EA lifecycle is correctly managed |

#### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Sample Ask price every `InpSampleMs` ms via `EventSetMillisecondTimer` | Must Have |
| FR-02 | Maintain circular buffer of `InpWindowSize` samples | Must Have |
| FR-03 | Compute true rolling high and low from buffer on every timer tick | Must Have |
| FR-04 | Detect new bar open once per bar via static datetime guard | Must Have |
| FR-05 | Classify last closed bar using 7-rule priority chain | Must Have |
| FR-06 | Display merged range + candle panel via `Comment()` | Must Have |
| FR-07 | Log bar classification to Experts journal via `Print()` | Should Have |
| FR-08 | Validate all inputs in `OnInit()`; return `INIT_PARAMETERS_INCORRECT` on failure | Must Have |
| FR-09 | Kill timer and clear comment on `OnDeinit()` | Must Have |
| FR-10 | Support configurable averaging period for body/trend baseline | Should Have |

#### Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Compiles with `#property strict` — zero warnings |
| NFR-02 | Single `.mq4` file — no external `.mqh` dependencies |
| NFR-03 | Circular buffer write is O(1); no O(n) array shifts |
| NFR-04 | `DBL_MAX` / `-DBL_MAX` sentinels — instrument-agnostic (works on JPY, indices, crypto CFDs) |
| NFR-05 | No `Alert()`, `MessageBox()`, or blocking calls in timer/tick handlers |
| NFR-06 | `EventKillTimer()` always paired with `EventSetMillisecondTimer()` |

---

## Overview

**OneMinuteMan** is a single-file MQL4 Expert Advisor that merges two independent engines:

1. **Range Scanner** — samples Ask every 50 ms into a circular buffer and continuously reports the rolling 1-minute high/low.
2. **Candlestick Recognizer** — on each new bar open, classifies the just-closed bar into one of 9 named single-candle patterns with trend context.

Both engines run concurrently via separate event handlers and expose their results through shared globals ready for trade signal logic.

---

## Features

- Rolling 1-minute high/low with sub-second resolution (configurable down to 10 ms)
- 9-pattern single-bar candlestick engine: Doji, Hammer, Inverted Hammer, Marubozu, Marubozu Long, Spinning Top, Short, Long, Star (reserved)
- Trend classification per bar: Ascending / Descending / Lateral (SMA-based)
- Circular buffer — O(1) write, no array shifting
- Live dual-panel `Comment()` overlay — range block + candle block
- `OnTick()` entry point with `g_high`, `g_low`, `g_candle` ready for order logic
- Full input validation with `INIT_PARAMETERS_INCORRECT` guard
- MQL4 strict-mode compliant — `(ENUM_TIMEFRAMES)_Period` cast for `EnumToString`

---

## Architecture & Blueprint

```
oneminuteman_merged.mq4 (374 lines)
│
├── [Constants]     BUFFER_SIZE = 1200  (1200 × 50 ms = 60 s)
├── [Inputs]        InpSampleMs | InpWindowSize | InpAverPeriod
├── [Enums]         TYPE_CANDLESTICK (9) | TYPE_TREND (3)
├── [Struct]        CANDLE_STRUCTURE (OHLC + time + trend + bull + bodysize + type)
├── [Globals]       g_prices[] | g_head | g_count | g_high | g_low
│                   g_candle | g_candle_valid
│
├── Section 1       TFLabel()            — safe timeframe string (strict-mode fix)
├── Section 2       IsNewBar()           — bar-open guard (static datetime)
├── Section 3       ScanHighLow()        — O(n) range scan with DBL_MAX sentinels
├── Section 4       CalcAverageClose()   — SMA for trend baseline
│                   CalcAverageBody()    — average body for size classification
│                   CalcShades()         — upper/lower shadow extraction
│                   RecognizeCandle()    — main 7-rule classification function
├── Section 5       CandleTypeName()     — enum → string
│                   TrendName()          — enum → string
├── Section 6       UpdateComment()      — merged dual-panel chart overlay
│
├── OnInit()        validate → allocate → EventSetMillisecondTimer()
├── OnDeinit()      EventKillTimer() → Comment("")
├── OnTimer()       sample Ask → write buffer → ScanHighLow → UpdateComment
└── OnTick()        IsNewBar guard → RecognizeCandle → Print log → trade entry
```

---

## Dataflow

### System Dataflow

```mermaid
flowchart TD
    subgraph MT4["MetaTrader 4 Platform"]
        BROKER["Broker Feed\n(Ask price)"]
        TIMER["System Timer\n(every 50 ms)"]
        TICK["New Tick Event"]
        BARS["Historical Bars\n(CopyRates / iTime)"]
    end

    subgraph EA["oneminuteman_merged.mq4"]
        direction TB

        subgraph RANGE["Range Engine  (OnTimer)"]
            T1["OnTimer()"]
            T2["Write Ask →\ng_prices[g_head]"]
            T3["Advance g_head\n(circular mod)"]
            T4["ScanHighLow()\nO(n) full scan"]
            T5["g_high / g_low\nupdated"]
        end

        subgraph CANDLE["Candle Engine  (OnTick)"]
            K1["OnTick()"]
            K2["IsNewBar()\nstatic datetime guard"]
            K3["RecognizeCandle()\nCopyRates → OHLC"]
            K4["CalcAverageClose()\nCalcAverageBody()\nCalcShades()"]
            K5["Classify pattern\n(CAND_* priority chain)"]
            K6["g_candle\ng_candle_valid"]
        end

        subgraph DISPLAY["Display"]
            D1["UpdateComment()\nStringFormat merged panel"]
            D2["Chart Comment()\nnon-blocking overlay"]
        end

        subgraph TRADE["Trade Logic Entry"]
            TR["OnTick() post-guard\ng_high + g_low + g_candle\navailable here"]
        end
    end

    BROKER -->|Ask| T1
    TIMER  -->|fires| T1
    T1 --> T2 --> T3 --> T4 --> T5
    T5 --> D1

    TICK   -->|tick event| K1
    BARS   -->|MqlRates[]| K3
    K1 --> K2
    K2 -->|new bar| K3
    K3 --> K4 --> K5 --> K6
    K6 --> D1
    K6 --> TR
    T5 --> TR

    D1 --> D2
```

### Circular Buffer Write Sequence

```mermaid
sequenceDiagram
    participant TMR  as System Timer
    participant OT   as OnTimer()
    participant BUF  as g_prices[]
    participant SCAN as ScanHighLow()
    participant UI   as Chart Comment

    loop every 50 ms
        TMR  ->> OT   : fires
        OT   ->> BUF  : g_prices[g_head] = Ask
        OT   ->> OT   : g_head = (g_head+1) % InpWindowSize
        OT   ->> OT   : if g_count < InpWindowSize: g_count++
        OT   ->> SCAN : ScanHighLow(g_high, g_low)
        SCAN ->> SCAN : iterate g_prices[0..g_count-1]
        SCAN -->> OT  : out_high, out_low
        OT   ->> UI   : UpdateComment()
    end
```

### Candle Recognition State Machine

```mermaid
stateDiagram-v2
    [*] --> CAND_NONE : RecognizeCandle() entry

    CAND_NONE --> CAND_LONG         : bodysize > avgBody × 1.3
    CAND_NONE --> CAND_SHORT        : bodysize < avgBody × 0.5
    CAND_LONG  --> CAND_DOJI        : bodysize < HL × 0.03
    CAND_SHORT --> CAND_DOJI        : bodysize < HL × 0.03
    CAND_NONE  --> CAND_DOJI        : bodysize < HL × 0.03
    CAND_LONG  --> CAND_MARIBOZU_LONG : shadow < body × 0.01
    CAND_SHORT --> CAND_MARIBOZU    : shadow < body × 0.01
    CAND_NONE  --> CAND_MARIBOZU    : shadow < body × 0.01
    CAND_NONE  --> CAND_HAMMER      : shade_low > body×2 AND shade_high < body×0.1
    CAND_NONE  --> CAND_INVERT_HAMMER : shade_low < body×0.1 AND shade_high > body×2
    CAND_SHORT --> CAND_SPIN_TOP    : both shadows > body

    CAND_HAMMER         --> [*]
    CAND_INVERT_HAMMER  --> [*]
    CAND_SPIN_TOP       --> [*]
    CAND_MARIBOZU_LONG  --> [*]
    CAND_MARIBOZU       --> [*]
    CAND_DOJI           --> [*]
    CAND_LONG           --> [*]
    CAND_SHORT          --> [*]
    CAND_NONE           --> [*]
```

### EA Lifecycle

```mermaid
flowchart TD
    A([EA Attached]) --> B[OnInit]
    B --> C{Validate Inputs}
    C -->|fail| D([INIT_PARAMETERS_INCORRECT])
    C -->|ok| E[ArrayResize + ArrayInitialize]
    E --> F[EventSetMillisecondTimer]
    F -->|fail| G([INIT_FAILED])
    F -->|ok| H([EA Running])
    H -->|every InpSampleMs| I[OnTimer]
    H -->|every tick| J[OnTick]
    H -->|remove / close| K[OnDeinit]
    K --> L[EventKillTimer]
    L --> M[Comment clear]
    M --> N([EA Stopped])
```

---

## Installation

1. Copy `oneminuteman_merged.mq4` to your MT4 `MQL4/Experts/` folder.
2. In MetaEditor, open the file and press **F7** to compile. Confirm zero errors and zero warnings.
3. In MetaTrader 4, open a chart (any symbol / timeframe).
4. Drag the EA from the Navigator panel onto the chart.
5. In the EA properties dialog, set `InpSampleMs`, `InpWindowSize`, `InpAverPeriod` as needed and enable **Allow live trading**.
6. Click **OK**. The dual-panel `Comment()` overlay appears on the chart within the first timer tick.

> **Tip for XAU/USD scalping:** Use default settings (`InpSampleMs=50`, `InpWindowSize=1200`, `InpAverPeriod=10`) on M1 for the most responsive 1-minute range. For H1 candle pattern context, attach a second instance with `InpAverPeriod=20` on an H1 chart.

---

## Input Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `InpSampleMs` | `50` | ≥ 10 | Timer interval in milliseconds. `50 ms × 1200 = 60 s` rolling window at defaults. |
| `InpWindowSize` | `1200` | 2 – 1200 | Circular buffer size (sample count). Window duration = `InpWindowSize × InpSampleMs` ms. |
| `InpAverPeriod` | `10` | ≥ 2 | Bars used to compute average body size and SMA close for trend direction. |

---

## Data Dictionary

### Enumerations

#### `TYPE_CANDLESTICK`

| Value | Description | Detection Condition |
|---|---|---|
| `CAND_NONE` | Unclassified | Default — no rule matched |
| `CAND_DOJI` | Doji | `bodysize < HL × 0.03` |
| `CAND_SHORT` | Short body | `bodysize < avgBody × 0.5` |
| `CAND_LONG` | Long body | `bodysize > avgBody × 1.3` |
| `CAND_MARIBOZU` | Marubozu | Either shadow `< body × 0.01` |
| `CAND_MARIBOZU_LONG` | Marubozu Long | `CAND_LONG` + either shadow `< body × 0.01` |
| `CAND_HAMMER` | Hammer | `shade_low > body×2` AND `shade_high < body×0.1` |
| `CAND_INVERT_HAMMER` | Inverted Hammer | `shade_low < body×0.1` AND `shade_high > body×2` |
| `CAND_SPIN_TOP` | Spinning Top | `CAND_SHORT` + both shadows `> body` |
| `CAND_STAR` | Star | Reserved — multi-candle composite |

#### `TYPE_TREND`

| Value | Condition |
|---|---|
| `TREND_UPPER` | SMA of previous closes `<` current close |
| `TREND_DOWN` | SMA of previous closes `>` current close |
| `TREND_LATERAL` | SMA of previous closes `==` current close |

### `CANDLE_STRUCTURE` Fields

| Field | Type | Description |
|---|---|---|
| `open` | `double` | Bar open price |
| `high` | `double` | Bar high price |
| `low` | `double` | Bar low price |
| `close` | `double` | Bar close price |
| `time` | `datetime` | Bar open time (Unix timestamp) |
| `trend` | `TYPE_TREND` | Trend direction vs `InpAverPeriod` SMA |
| `bull` | `bool` | `true` when `close > open` |
| `bodysize` | `double` | `MathAbs(open - close)` in price units |
| `type` | `TYPE_CANDLESTICK` | Classified pattern after full priority chain |

### Global State Variables

| Variable | Type | Description |
|---|---|---|
| `g_prices[]` | `double[]` | Circular buffer — `InpWindowSize` Ask samples |
| `g_head` | `int` | Next-write index; wraps at `InpWindowSize` |
| `g_count` | `int` | Valid sample count — capped at `InpWindowSize` |
| `g_high` | `double` | Current rolling high |
| `g_low` | `double` | Current rolling low |
| `g_candle` | `CANDLE_STRUCTURE` | Last classified bar pattern |
| `g_candle_valid` | `bool` | `true` when `g_candle` holds a valid result |

### Functions

| Function | Returns | Description |
|---|---|---|
| `TFLabel()` | `string` | Clean TF label (`M1`, `H4`) — casts `_Period` to `ENUM_TIMEFRAMES` |
| `IsNewBar()` | `bool` | `true` once per bar open — static datetime guard |
| `ScanHighLow(out_high, out_low)` | `void` | Full buffer scan; `DBL_MAX` sentinels |
| `CalcAverageClose(rt[], n)` | `double` | SMA of `rt[0..n-1].close` |
| `CalcAverageBody(rt[], n)` | `double` | Mean body size of `rt[1..n]` |
| `CalcShades(c, sl, sh)` | `void` | Upper/lower shadow calc for bull and bear bars |
| `RecognizeCandle(...)` | `bool` | Full candle classification — `false` if data insufficient |
| `CandleTypeName(t)` | `string` | `TYPE_CANDLESTICK` → human label |
| `TrendName(t)` | `string` | `TYPE_TREND` → human label |
| `UpdateComment()` | `void` | Merged dual-panel `Comment()` overlay |

---

## Candle Classification Rules

Rules are applied in priority order — later rules override earlier ones:

| Priority | Pattern | Condition |
|---|---|---|
| 1 | `CAND_LONG` | `bodysize > avgBody × 1.3` |
| 2 | `CAND_SHORT` | `bodysize < avgBody × 0.5` |
| 3 | `CAND_DOJI` | `HL > 0` AND `bodysize < HL × 0.03` |
| 4 | `CAND_MARIBOZU` / `CAND_MARIBOZU_LONG` | `bodysize > 0` AND (lower OR upper shadow `< body × 0.01`) |
| 5 | `CAND_HAMMER` | `shade_low > body × 2` AND `shade_high < body × 0.1` |
| 6 | `CAND_INVERT_HAMMER` | `shade_low < body × 0.1` AND `shade_high > body × 2` |
| 7 | `CAND_SPIN_TOP` | current type == `CAND_SHORT` AND both shadows `> body` |

---

## Known Limitations

| # | Limitation | Notes |
|---|---|---|
| 1 | Single-bar patterns only | Multi-candle composites (Engulfing, Harami, Star) require additional lookback in `OnTick()` |
| 2 | SMA trend — not directional | Equal close prices → `TREND_LATERAL` regardless of bar direction |
| 3 | `CAND_STAR` unassigned | Reserved; implement composite detection in `OnTick()` as needed |
| 4 | In-memory only | Buffer resets on EA restart or terminal close |
| 5 | Timer drift under load | `EventSetMillisecondTimer` is best-effort — intervals may drift under high CPU |
| 6 | Ask-only sampling | Replace `Ask` with `Bid` in `OnTimer()` for bid-based instruments |

---

## References

- [MQL4 Reference — EventSetMillisecondTimer](https://docs.mql4.com/eventfunctions/eventsetmillisecondtimer)
- [MQL4 Reference — CopyRates](https://docs.mql4.com/series/copyrates)
- [MQL5 Article — Analyzing Candlestick Patterns](https://www.mql5.com/en/articles/101)
- [MQL4 Reference — ENUM_TIMEFRAMES](https://docs.mql4.com/constants/chartconstants/enum_timeframes)
