# Chart Indicators & Economic Events Guide

Plain-English guide to the four on-chart indicators and to the main news events that move USDJPY.
Nothing here is trade advice.

---

## Part 1 – Your chart indicators

All four draw text at the top-right of the chart and update every second. They don't draw lines or
arrows and don't place trades.

| Indicator | What it shows | Folder |
|---|---|---|
| HTF_Countdown | Time left until the current H1, H4 and D1 candles close | `HTF_Countdown` |
| Session_Clock | Which trading sessions are open, how long they have been open, when they end | `Session_Clock` |
| Open_Positions | How many positions you have open, with profit/loss | `Open_Positions` |

### Installing / reloading
1. Files live in `MQL5\Indicators\<name>` inside the MT5 data folder (File → Open Data Folder).
2. Navigator (Ctrl+N) → right-click **Indicators** → **Refresh**, then drag the indicator onto the chart.
3. After any update, remove the old copy first (Ctrl+I → select it → Delete), then drag it on again.

### HTF_Countdown
Example: `H1 29:13   H4 02:29:13   D1 14:29:13`

- Each value is the time until that candle closes. Use it to wait for a candle close before acting.
- The text turns **blue** when 5 minutes or fewer are left (input "Warn when this many minutes or fewer are left").
- Times come from the broker's server clock.

### Session_Clock
Example (open): `London   OPEN   +02:10:05  ends in 06:49:55`
Example (closed): `Tokyo    closed opens in 05:10:00`

- `+02:10:05` is how long the session has been open. `ends in` is the time left.
- Green = open, gray = closed, dark red = opens or closes within 15 minutes.
- **Forex mode** (Sydney, Tokyo, London, New York): shows "Forex market closed (weekend)" from Friday
  21:00 UTC to Sunday 21:00 UTC.
- **Crypto mode** (Asia, Europe, US): runs 24/7.
- "Market" input: Auto picks crypto if the symbol's broker path contains "crypto". Otherwise set it by hand.
- Session hours are inputs in **UTC**. Defaults:

| Session | UTC hours |
|---|---|
| Sydney | 21:00–06:00 |
| Tokyo | 00:00–09:00 |
| London | 07:00–16:00 |
| New York | 12:00–21:00 |
| Asia (crypto) | 00:00–08:00 |
| Europe (crypto) | 07:00–16:00 |
| US (crypto) | 13:00–22:00 |

London and New York shift by one hour when daylight saving changes. Update the inputs then.
The crypto hours are a convention only.

### Open_Positions
Example header: `Open positions: 3  P/L +12.40 USD`
Example line: `USDJPY BUY  0.10 @ 158.123  +8.20`

- Count header on or off, and the position list on or off, are separate inputs.
- "Max position lines" sets how many lines show (default 10). The rest show as "... +N more".
- "Count positions on" is either all symbols or only the chart's symbol.
- P/L is profit plus swap. It does not include commission.
- Green = in profit, dark red = in loss.

---

## Part 2 – Where to find the economic calendar

- **MT5:** Ctrl+T → **Calendar** tab → right-click → Filter → Country: United States, Importance: Medium/High.
- **Web:** [Forex Factory](https://www.forexfactory.com/calendar),
  [Investing.com](https://www.investing.com/economic-calendar/),
  [FXStreet](https://www.fxstreet.com/economic-calendar).
- Every event shows a **Forecast** (what economists expect), a **Previous** value and the **Actual**
  result. Price moves on the *surprise* (Actual vs Forecast), not on the number itself.

---

## Part 3 – Main events and what they mean

**Rule of thumb for USDJPY:** USDJPY rises when US rates or US yields rise or Japan stays loose, and
falls when US data disappoints or the Bank of Japan tightens. Spreads widen and price can jump at the
release time, so many traders stay out around high-impact events.

### United States (moves the dollar)

| Event | What it is | How often | Why it matters |
|---|---|---|---|
| **FOMC rate decision** | The Federal Reserve sets the US interest rate, followed by a press conference. | 8 times a year | Biggest mover. Higher or hawkish (rate-rise-friendly) means dollar up. Lower or dovish (rate-cut-friendly) means dollar down. |
| **Fed chair speech / FOMC minutes** | Hints about future rate moves. | Irregular / ~3 weeks after FOMC | Can shift rate-cut expectations. |
| **NFP (Non-Farm Payrolls)** | Number of jobs added in the US, excluding farms. | Usually the first Friday of the month | Strong jobs means the dollar goes up, since the Fed may keep rates high. Weak jobs means the dollar goes down. Very volatile. |
| **Unemployment rate** | % of people without jobs (released with NFP). | Monthly | Higher unemployment is weaker for the dollar. |
| **CPI (Consumer Price Index)** | How fast consumer prices rise (inflation). | Monthly | Higher than forecast means the Fed may raise or hold rates, so the dollar goes up. Lower than forecast means the dollar goes down. |
| **PCE price index** | The Fed's favoured inflation measure. | Monthly | Same logic as CPI. |
| **GDP** | Size and growth of the US economy. | Quarterly | Stronger growth supports the dollar. |
| **Retail Sales** | Consumer spending. | Monthly | Strong spending means a strong economy, so the dollar goes up. |
| **ISM / PMI** | Surveys of business activity. Above 50 is expansion. | Monthly | Quick read on economic health. |
| **Initial Jobless Claims** | New unemployment applications. | Weekly (Thursday) | Rising claims is weaker for the dollar. Smaller mover. |
| **Treasury yields** (not an event) | Return on US government bonds. | Constant | USDJPY follows the US 10-year yield closely. |

### Japan (moves the yen)

| Event | What it is | Why it matters |
|---|---|---|
| **BoJ rate decision and statement** | The Bank of Japan sets Japanese interest rates, roughly 8 times a year. | Hawkish (raising or hinting at hikes) means yen up and USDJPY down. Staying loose means the yen weakens. |
| **BoJ Governor Ueda press conference** | Signals the future policy path. | Comments on further tightening often move USDJPY several tens of pips. |
| **Japan CPI / wage data** | Inflation and pay growth. | Higher inflation or wages raises the odds of BoJ hikes, so the yen goes up. |
| **Tankan survey** | Quarterly business sentiment survey. | Strong readings support the yen. |
| **Ministry of Finance intervention** | Japan sells dollars and buys yen to stop a fast fall in the yen. | Usually feared near **160**. It can drop USDJPY by hundreds of pips within minutes. Often comes without warning. |

### Market-wide

| Term | Meaning |
|---|---|
| **Risk-on / risk-off** | Risk-on (stocks up) tends to weaken the yen, since traders borrow cheap yen to buy riskier assets. Risk-off (fear) tends to strengthen the yen, a "safe-haven" currency. |
| **Hawkish / dovish** | Hawkish = favours higher interest rates. Dovish = favours lower rates. |
| **Rate differential** | The gap between US and Japanese rates. A wide gap supports USDJPY. |

### Impact colours (Forex Factory)
Red = high impact (FOMC, NFP, CPI, BoJ decision). Orange = medium. Yellow = low.

---

## Part 4 – A simple routine before trading

1. Open the calendar and filter for United States and Japan, medium and high impact.
2. Note the times of red events today. Check the time zone shown matches yours.
3. Glance at Session_Clock. Volatility is usually highest while **London and New York overlap**
   (12:00–16:00 UTC by default), and Tokyo matters most for yen moves.
4. Use HTF_Countdown to wait for a candle close before acting on a signal.
5. Check Open_Positions so you know your total exposure before the news.

---

## Part 5 – Examples: what you will see

All numbers below are made up to show how to read things. They are not real data or predictions.

### 5.1 What the indicators look like on the chart (top-right corner)

```
H1 29:13    H4 02:29:13    D1 14:29:13          <- HTF_Countdown
Sydney   closed opens in 11:30:00               <- Session_Clock
Tokyo    OPEN   +08:10:05  ends in 00:49:55
London   closed opens in 00:49:55
New York closed opens in 05:49:55
Open positions: 2  P/L +12.40 USD               <- Open_Positions
USDJPY BUY  0.10 @ 158.123  +8.20
EURUSD SELL 0.05 @ 1.0850   +4.20
```

How to read it:
- Tokyo has been open for 8 hours 10 minutes and closes in 49 minutes. London opens in the same 49 minutes,
  so expect more activity soon. Tokyo and London lines turn dark red because they are inside the 15-minute window.
- The H1 candle closes in 29 minutes. When the number gets to 05:00 or less, it turns blue.
- You hold two positions and are up 12.40 USD in total.

### 5.2 Worked news examples

**Example A – NFP (jobs report), Friday 8:30 New York time**

| | Number |
|---|---|
| Forecast | +180,000 jobs |
| Previous | +150,000 |
| Actual | +260,000 |

- Actual is far above forecast. This is a strong-economy surprise, so the market expects the Fed to keep rates higher.
- **Likely reaction:** the dollar goes up, USDJPY spikes up within seconds, then it may reverse or settle.
- **What you see on the chart:** a very large green M1 or M5 candle at 8:30 New York time, then a wider spread.
- If Actual had been +90,000, the dollar goes down and you would see a large red candle.

**Example B – CPI (inflation), 8:30 New York time**

| | Number |
|---|---|
| Forecast | 0.3% month-on-month |
| Actual | 0.5% |

- Inflation is hotter than expected. Traders expect the Fed to be slower to cut rates, so the dollar goes up.
- If Actual were 0.1%, inflation is cooler, rate cuts look more likely, and the dollar goes down.

**Example C – FOMC rate decision, 2:00 pm New York time, press conference 2:30 pm**

- The Fed holds rates but says it expects fewer cuts. That is a hawkish message, so the dollar goes up.
- You often see a first spike at 2:00 pm, then a second, sometimes opposite, move during the press conference.
  The decision alone doesn't tell you the direction. The wording does.

**Example D – BoJ decision / Ueda press conference**

- The BoJ keeps rates unchanged, but Ueda says more rate hikes are possible if inflation stays near 2%.
- That is a hawkish message for the yen, so the yen goes up and USDJPY falls.
- If Ueda sounds cautious, the yen weakens and USDJPY rises.

**Example E – Intervention near 160**

- USDJPY climbs to 159.80 and Japanese officials warn about "excessive moves".
- A sudden tall red candle of 300+ pips can appear within minutes with no scheduled news. That is the Ministry of Finance
  buying yen. Stop-losses and long positions get hit hard, so avoid chasing longs close to 160.

### 5.3 What to check on the calendar before each event

1. The **time** (convert it to your time zone) and the **colour** (red, orange or yellow).
2. **Forecast vs Previous.** The market is already pricing the forecast.
3. After release: compare **Actual with Forecast**. A bigger gap means a bigger move.
4. Wait for the first candle to close (use HTF_Countdown or an M1/M5 candle) before deciding. The first move is
   often a spike that reverses.
