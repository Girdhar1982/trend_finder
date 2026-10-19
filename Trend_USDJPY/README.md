# TrendUJ - USDJPY trend identifier (H1)

`TrendUJ.mq5` colours a Hull(50) line green/red by slope, marks each CONFIRMED flip with an arrow,
and shows in a panel: current state, run length and pips, agreement with the daily trend
(D1 EMA100 slope), and a scorecard of the last 20 completed legs. Separate from the `HullTrend\` folder.

## How the settings were chosen (USDJPY H1, 2014-2026, 1.2 pips cost per leg, state-following P/L)
Tuned on 2014-2019 (choppy), checked on 2020-2026 (never used for tuning). 8 families compared.
- The usual HullTrend setting (period 20 + ATR slope filter 0.05): ~550 flips/yr, **-2,647 pips on
  2014-19 and -643 on 2020-26**. Slope filter and short periods hurt.
- Hull period 45-60, no slope filter: stable plateau, +7,400 to +9,400 pips over 13 years, 8-10 of 13
  years positive, ~300 flips/yr. Period 50 chosen (10 of 13 years positive).
- Supertrend, Donchian, EMA cross, ADX/DI, dual-Hull, Hull+efficiency-ratio, averages of several Hulls:
  none beat the plain Hull(50) robustly. Averaging periods was smoother but not better.
- Adding the D1 EMA100 agreement lowered the worst-year loss and drawdown (1,250 vs 1,758 pips) but
  gave up return, so it is shown as a grade, not a hard filter.

## What it cannot do
- A 5-vote agreement across H1/H4/D1 did NOT predict the next day or week (aligned move -1.1 pips in
  2014-19, +3.5 in 2020-26, hit rate 46-54%). Flips follow a move already made.
- It makes money through few large wins vs many small losses and loses in sideways markets
  (2015 and 2019 were -1,226 and -360 pips at Hull(50)). 2020-26 was a strong up-trend, buy&hold made
  +4,950 pips, so the 2020-26 result is flattered by trend.
- Swap and commission are not modelled. Tuned on H1; other timeframes are untested.