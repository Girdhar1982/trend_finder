# USDJPY monitors – how to start them

Three scripts watch the market and send alerts. **They only alert. None of them places orders.**

| Script | Timeframe | Watches for |
|---|---|---|
| `research/breakout_monitor.py` | M5 | Breakouts (and failed wicks) of key levels: 00–02 range, previous day high/low, 24h high/low, whole figures (160.00 …) |
| `research/nowick_monitor.py` | M15 | A no-wick candle in the trend direction, then a limit-order retest setup (entry, stop, 1:1 target) |
| `research/sweep_reclaim_monitor.py` | M5 | A **sweep** of a level (wick beyond it) followed by a **reclaim** (close back inside). Graded PLAY / LEVEL / DEEP |

All times are **MT5 server time** (New York + 7 h).

## Before you start

1. **MetaTrader 5 must be open and logged in** (the scripts read prices from it). USDJPY must be in Market Watch.
2. Python packages: `pip install MetaTrader5 pandas numpy` (already installed on this PC).
3. Open a terminal **in the project folder** and stay there. The logs use relative paths.

```
cd C:\myfiles\training_folder
```

## Start them (one terminal window per script)

**Terminal 1 – breakout monitor (M5)**
```
python research/breakout_monitor.py
```

**Terminal 2 – no-wick monitor (M15, breakout candles only – recommended)**
```
python research/nowick_monitor.py --breakout
```

**Terminal 3 – sweep / reclaim monitor (M5)**
```
python research/sweep_reclaim_monitor.py
```

Each prints its current state on start, then waits. Leave the windows open. Press **Ctrl+C** in a window to stop that script.

> A script blocks its window while it runs, so use one window per script.
> Alert times: live alerts show the time the candle **closed**; `--replay` shows the candle's open time.

## Check that alerts reach you (do this once)

```
python research/breakout_monitor.py --test-alert
python research/nowick_monitor.py --test-alert
python research/sweep_reclaim_monitor.py --test-alert
```

You should see a Windows pop-up in the corner. If not, check Windows **Focus Assist / Do Not Disturb** and allow notifications for "Windows PowerShell" (Settings → System → Notifications).

## What the alerts mean

**breakout_monitor.py**

| Event | Meaning |
|---|---|
| `BREAK UP/DOWN` | A candle **closed** beyond a level |
| `WICK above/below` | Price poked past a level (3+ pips) but **closed back inside**. These usually reverse |
| `FAILED` | A break closed back inside within 3 bars |
| `HELD` | A break was still beyond the level 3 bars later |

**nowick_monitor.py**

| Event | Meaning |
|---|---|
| `SIGNAL` | A no-wick candle closed. Gives the **limit price, stop, target** and when the order should be cancelled (9 candles). Labelled `BREAKOUT` or `inside range` |
| `TOUCH` | Price reached your limit price (live, before the candle closes) |
| `FILLED` / `TP` / `SL` | What the simulation says would have happened to the order |
| `EXPIRED` | The 9 candles passed without a retest. Cancel the order |

Rule used: trend = M15 close vs a rising/falling EMA50 · no-wick = both wicks ≤ 5% of range, body ≥ 0.7 ATR · limit at the candle's open · stop = last swing low/high + 3 pips · target 1:1.

**sweep_reclaim_monitor.py**

| Event | Meaning |
|---|---|
| `RECLAIM BUY/SELL [grade]` | A wick went beyond a level and a candle **closed back inside** (same bar, or within 2 bars). Shows the stop reference (just beyond the sweep extreme) and the risk in pips |
| `SWEEP … watch` | Price is beyond a level but has not closed back yet. Wait |
| `NO RECLAIM` | No close back inside within 2 bars: it behaved like a breakout, drop the idea |

Grades: **PLAY** = 24h high/low swept 0.5–3 pips, reclaimed on the same bar, with counter-trend stretch ≥ 0.62 (M5 only). **DEEP** = swept 3+ pips. **LEVEL** = every other reclaim.
By default only **PLAY** beeps / pops a Windows toast (it is the only grade with a positive backtest, see below). Everything is still printed and logged.
Levels watched: 24h high/low, previous day high/low, 00–02 range, whole figures (add `swing` with `--levels` if you want swing highs/lows too, about 10 extra events a day).

## Useful options

```
# more noticeable alerts (a window that stays until you click OK)
python research/breakout_monitor.py --popup BREAK,WICK
python research/nowick_monitor.py --breakout --popup SIGNAL,TOUCH

# quieter
python research/breakout_monitor.py --no-beep --toast none

# breakout monitor: choose levels / thresholds
python research/breakout_monitor.py --levels 00-02,PD,fig --min-wick 5 --buffer 1.0

# no-wick monitor: cap the stop size, all candles instead of breakout only
python research/nowick_monitor.py --max-risk 25
python research/nowick_monitor.py              # shows every no-wick candle, labelled BREAKOUT / inside range

# sweep/reclaim: alert on every grade, add swing levels, use M15
python research/sweep_reclaim_monitor.py --alert-grades all
python research/sweep_reclaim_monitor.py --levels 24h,swing,PD,00-02,fig
python research/sweep_reclaim_monitor.py --tf M15          # no PLAY grade on M15
python research/sweep_reclaim_monitor.py --popup RECLAIM --toast RECLAIM,SWEEP

# another symbol
python research/breakout_monitor.py --symbol EURUSD
```

`python research/<script>.py --help` lists every option.

## Test on history instead of live

```
python research/breakout_monitor.py --replay "2026-11-12 08:30" "2026-11-12 20:00"
python research/nowick_monitor.py --replay "2026-11-11 08:00" "2026-11-12 23:00"
python research/nowick_monitor.py --backtest      # full backtest table (takes a minute)
python research/sweep_reclaim_monitor.py --replay "2026-11-12 17:00" "2026-11-12 19:30"
python research/sweep_reclaim_monitor.py --stats  # what happened after every past RECLAIM (takes a minute)
```

**Prove the live loop works without waiting for the market** (feeds real history as if time were passing, no pop-ups):
```
python research/live_feed_test.py sweep_reclaim_monitor "2026-11-12 17:00" "2026-11-12 19:30"
python research/live_feed_test.py breakout_monitor "2026-11-12 17:00" "2026-11-12 19:30"
python research/live_feed_test.py nowick_monitor "2026-11-11 16:00" "2026-11-11 19:30" --breakout
```

Replay never pops anything up, so it's safe to run at any time.

## Logs

Every alert is also appended to a log file in the project folder:

- `research/breakout_monitor.log`
- `research/nowick_monitor.log`
- `research/sweep_reclaim_monitor.log`

## Troubleshooting

| Problem | Fix |
|---|---|
| `MT5 init failed` | Open MetaTrader 5 and log in, then start the script again |
| `no data for USDJPY` | Add USDJPY to Market Watch, open an M5/M15 chart once so history loads |
| `ModuleNotFoundError: breakout_monitor` | Run from the project folder as `python research/nowick_monitor.py` (don't use `python -I`) |
| No pop-ups | Run `--test-alert`; check Focus Assist; use `--popup` for a window that can't be missed |
| Nothing prints for a long time | Normal. It only speaks when a candle closes with a setup. The no-wick monitor fires roughly once every few days |

## Read this before trading on it

- **Sweep/reclaim backtest** (347 days of M5): 17 reclaims a day across all levels, about break-even to slightly negative (−0.30p per trade vs −0.46p for random entries, +10/−10 pip bracket, spread included). **Only PLAY was positive**: 259 events (0.75/day), +0.85p per trade, train +0.23 / test +2.03. It comes from **sells** (+1.43p, n=181); PLAY buys were −0.51p. Reclaims at whole figures were the worst (−1.0p).
- **Neither script is a proven edge.** On four years of M15 data the no-wick rule is about break-even; with `--breakout` it tested at about +0.1R per trade (roughly 1.6 standard errors, not statistically proven). Breakout monitoring was not profitable on its own in earlier tests.
- Use them to see setups, then decide using your own view. Forward-test on a demo account first.
- Re-run the numbers any time with `python research/nowick_monitor.py --backtest` and `python research/nowick_improve.py`.
