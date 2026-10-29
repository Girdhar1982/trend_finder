# USDJPY Rule Book v2 (M15 primary, M5 for timing only)

Built from your own indicators (Hull trend, Bollinger Bands, RSI, Order_Blocks, Prev_Day_HL, session clock)
and **benchmarked on 2.8 years of your broker's M15 history** (Jan 2024 – Oct 2026).
Not trade advice. Past results do not promise future ones.

**Two profiles, one shared checklist.** Pick by what you want:

| | **Profile A: High-win (OB-confirmed)** | **Profile B: Core** |
|---|---|---|
| Win rate | **81.8%** (95% range 73–88%) | 61.0% (56–66%) |
| Trades | 99 in 2.8 years, about **1 a week** | 405, about 1 every 2 days |
| Expectancy | +2.2 pips per trade | +1.55 pips per trade |
| Profit factor | 1.31 | 1.19 |
| Typical win / loss | +11 / −38 pips | +16 / −21 pips |
| Worst trade | −153 pips (news spike) | −103 pips |
| Longest losing streak | 3 | 6 |

---

## A. What an order block is, and why it matters here

**Definition (as your Order_Blocks indicator draws it):**
- An **impulse candle**: body at least 1.2 × ATR, closing beyond the last 10 candles' high (up) or low (down).
- The **order block** is the last opposite-colour candle within 6 candles before that impulse.
  - Last **down** candle before a strong up move = **bullish OB** (demand).
  - Last **up** candle before a strong down move = **bearish OB** (supply).
- The zone stays **active** until a candle **closes through** it. After that it is mitigated and ignored.

**The idea:** the impulse shows strong orders were placed there. When price returns, it often reacts
from the zone. So an OB tells you **where** a pullback is likely to end, which a moving average or band
cannot.

**What the test showed:**
- **OB alone is not an edge.** Using an order-block retest instead of the Bollinger middle band lost money
  (55.5% win, −0.4 pips per trade).
- **OB as an extra confirmation is valuable.** Requiring the pullback to also touch an active OB lifted the
  win rate from 61% to 63.5% at the same targets, and **allowed a high win rate with positive profit when
  paired with a small target** (Profile A). It also cut trades by about 75%.
- That is the real significance: **OB is a quality filter, not an entry signal.**

---

## B. Profile A: High-win rule

Use the Profile B entry rules in §2, **plus**:

9. **Order block touch:** in the last 4 candles, price reached an **active** OB in your trade's direction
   (SELL: a bearish OB, high reached the zone; BUY: a bullish OB, low reached the zone). An OB is active
   for at most 96 candles (24 hours) and until a candle closes through it.

**Exits for Profile A:**
- **Take profit: 1.0 × ATR** (about 10 pips).
- **Stop loss: 3.0 × ATR** (about 30 pips, wider in volatile hours).
- **Time stop:** close at market after 32 candles (8 hours).

**Why 80%+ is possible, and its price.** The target is small and the stop is wide, so you win often but
lose big: 81 wins averaged +11 pips, 12 stops averaged −38 pips. **One loss erases about 3.4 wins.** Of the
99 trades, 81 hit the target, 12 hit the stop and 6 timed out. Size the position for the stop, not the
target.

**Position size:** with a 30-pip stop, 0.01–0.02 lots risks about 3–6 AUD on your 535 AUD account (about
1%). Re-check with the actual ATR each time. A news spike once produced a −153 pip loss, so never trade
news.

---

## C. Profile A benchmark (cost 1.2 pips per trade)

| Measure | Value |
|---|---|
| Trades / win rate | 99 / 81.8% (95% range 73–88%) |
| Expectancy / profit factor | +2.18 pips / 1.31 |
| Net / max drawdown | +216 pips / 202 pips |
| BUY / SELL win rate | 83.9% (56 trades) / 79.1% (43 trades) |
| Trades per day | 0.14 (about 1 a week) |

**Out-of-sample:** settings chosen on the first 60% of the data won 84.6% (65 trades); the unseen last 40%
won **76.5%** (34 trades) with +0.3 pips per trade. Lower than the training half, though still positive.

**By half-year:** 75%, 86%, 86%, 85%, **54%**, 100%. **2026 H1 was a losing half (−135 pips).**

**Cost sensitivity (the edge is thin):**

| Cost per trade | Expectancy | Net |
|---|---|---|
| 0.8 pips | +2.58 | +256 |
| 1.2 pips | +2.18 | +216 |
| 2.0 pips | +1.38 | +137 |
| 3.0 pips | +0.38 | +38 |

An even smaller-target variant (target 0.5 × ATR, stop 2.0 × ATR, ATR at least 9 pips) won **86.5%** over
89 trades but earned only **+0.98 pips per trade** and turned negative at a 3-pip cost. I don't
recommend it.

### What this does and does not prove
- **80%+ is reachable only at about 1 trade a week.** No test produced 80%+ at 4–5 trades a day. More
  trades meant weaker setups, and the win rate fell to 55–60%.
- **The sample is small** (99 trades) and was **picked from 576 settings combinations**. The best of many
  tries looks better than it will perform live. The unseen-data result (76.5%) is the more honest guide.
- **A single bad stretch can undo months** because of the 11-vs-38 pip size mismatch.
- **Forward-test on demo for at least 30 Profile A trades (about 6 months)** before using real money.
  Continue only if the win rate stays above about 70%.

---

## D. Profile B (Core): what the benchmark says

| Your goal | Result |
|---|---|
| Win rate 60%+ | **Met on M15: 61.0%** (95% range 56–66%). |
| 4–5 trades a day, max | **Cap met, but the rule gives ~0.55 trades a day**, about 1 every 2 days. 5 is the most it ever produced in a day. Forcing 4–5 a day means taking weaker setups, and every test of that lost money (see §6). |
| Profitable | **Barely.** +1.55 pips per trade after a 1.2-pip cost, profit factor 1.19, +629 pips over 2.8 years. |
| Works on M5 | **No.** The same rule on M5 lost money (51% win, −2.3 pips per trade). Use M5 only to time the entry. |

A 60%+ win rate is easy to get and does not mean profit. Here the average win (15.8 pips) is smaller
than the average loss (−20.7 pips), so the edge is thin and costs matter a lot (§5).

---

## C2. Profile C: H1 (hourly) rule

Same ideas on the H1 chart, with the **H4 Hull** as the higher-timeframe filter instead of the H1 Hull.
Tested on 3.2 years of H1 history (Aug 2023 – Oct 2026).

**Entry (SELL; BUY is the mirror), checked on the H1 candle close:**
1. **H1 Hull down and H4 Hull down.**
2. H1 ATR at least **15 pips**.
3. In the last 6 candles price reached the Bollinger middle band **and** an active bearish order block.
4. RSI was 50 or higher in those candles and is now **below 50 and above 30**, and the candle closes below
   the middle band.
5. Previous-day high/low room check is **not** used on H1 (it did not help).

**Exits:** stop **3.0 × H1 ATR** (about 60 pips), time stop 24 candles (24 hours). Choose the target:

| Variant | Target | Hours | Trades | Win rate | Expectancy | Profit factor | Net | Max DD |
|---|---|---|---|---|---|---|---|---|
| **C-high-win** | 0.75 × ATR (about 15 pips) | server 03:00–19:00 | 74 | **79.7%** | +2.0 pips | 1.16 | +151 | 165 |
| C-balanced | 1.0 × ATR | server 03:00–19:00 | 68 | 73.5% | +3.4 pips | 1.23 | +230 | 186 |
| **C-profit** | 1.5 × ATR (about 30 pips) | all hours | 84 | 65.5% | **+7.4 pips** | 1.39 | +621 | 284 |

- **About 1 trade every 10 days** (0.09–0.10 a day). A stop of about 60 pips means 0.01 lots risks about
  6 AUD on your account, so **use 0.01 lots only**.
- **Cost tolerance:** C-profit still earned +5.6 pips per trade at a 3-pip cost, much better than the M15
  rules. C-high-win nearly vanished at 3 pips.
- **First half-years were weak:** 2023 H2 and 2024 H1 lost money in every variant (40–57% win rate). Later
  periods were mostly strong.
- **Out-of-sample:** C-profit won 63.6% in the training part and 69.0% in the unseen part, both
  profitable. C-high-win won 77% then 83%.

---

## C3. Is any of this proven? No

I bootstrapped each profile's average profit per trade (resampling the trades 5,000 times). The 95% range
**includes zero in every case**:

| Profile | Trades | Expectancy 95% range (pips per trade) |
|---|---|---|
| B (M15 core) | 405 | −0.5 to +3.6 |
| A (M15 high-win) | 99 | −2.8 to +6.3 |
| C-high-win (H1) | 74 | −6.7 to +9.5 |
| C-profit (H1) | 84 | −3.9 to +18.0 |

That means the data can't rule out that these profits are luck. In the H1 search only **39 of 3,848**
settings combinations were profitable in both halves of the history, so the winners are a small, hand-picked
group. Treat all profiles as **candidates to prove on a demo account**, not as proven systems.

**What was consistent across M15 and H1, which makes it the most believable part:**
- The **higher-timeframe Hull must agree** (removing it destroys the result).
- An **active order block touch** is the best quality filter.
- A **wide stop (about 3 × ATR) with a smaller target** is what produces high win rates.
- **Fewer trades beat more trades.** Every attempt at 4–5 trades a day lost money.

---

## 1. What each indicator is for

| Job | Tool | Setting |
|---|---|---|
| **Direction filter** | Hull trend, M15 **and** H1 | Hull 20, slope filter ATR × 0.05. Both must point the same way. |
| **Pullback location** | Bollinger Bands | 20, 2.0. Use the **middle band**. |
| **Timing trigger** | RSI | 14. Used to confirm the pullback has turned. |
| **Room to run** | Prev_Day_HL | No entry within 0.5 × ATR of yesterday's high/low in the trade's direction. |
| **Stop and target size** | ATR | 14 on M15. |
| **When to trade** | Session_Clock | Server time 03:00–19:00 only. |
| **Time left in the candle** | HTF_Countdown | Enter on the M15 candle close, not mid-candle. |

Each one answers a different question, so they don't repeat each other. Removing the H1 Hull was the
most damaging change in the test (§6).

---

## 2. Entry rules, SELL (mirror them for BUY)

Check these on the **close** of an M15 candle. All must be true:

1. **M15 Hull is down** and **H1 Hull is down**.
2. **Server time is 03:00–19:00.** (That is about 20:00 to 12:00 New York, since server = New York + 7h.)
3. **M15 ATR is at least 6 pips.** Quiet markets don't pay for the spread.
4. **Pullback:** in the last 4 candles, price reached the Bollinger **middle band** or higher.
5. **RSI turned down:** RSI was **50 or higher** in those 4 candles, and it is now **below 50 but above 40**.
6. The candle **closes below the middle band.**
7. **Room:** the close is at least 0.5 × ATR above yesterday's low (PDL).
8. Daily limits are not used up (§4).

**Enter** at the open of the next candle (use M5 to get a clean entry; don't chase a spike).

**BUY** is the mirror: Hull up on both, price reached the middle band or lower, RSI was 50 or lower and
is now **above 50 but below 60**, candle closes above the middle band, and the close is at least
0.5 × ATR below yesterday's high (PDH).

---

## 3. Exits

- **Stop loss:** 2.0 × M15 ATR from entry (about 20 pips at today's volatility).
- **Take profit:** 1.5 × M15 ATR (about 15 pips).
- **Time stop:** close at market after 16 candles (4 hours) if neither is hit.
- Don't move the stop further away. Don't take profit early on small gains: the 61% win rate depends on
  letting winners reach the target.

---

## 4. Daily rules

- **Max 5 trades a day.** The rule itself rarely gives more than 1.
- **One trade open at a time.**
- **Stop for the day after 3 losing trades.**
- The "day" rolls at server midnight (17:00 New York).
- Skip the 30 minutes either side of high-impact news (US data, BoJ, Fed) and the rollover spread spike.
- **Check the spread before entering:** skip if it is above about 2 pips.
- Risk 0.5–1% of the account per trade. On a 535 AUD account that is roughly 3–5 AUD, which fits
  0.02–0.03 lots with a 20-pip stop. Check the lot size against your real stop each time.

---

## 5. Benchmark results (USDJPY M15, cost 1.2 pips per trade)

| Measure | Value |
|---|---|
| Period / trades | 8 Jan 2024 – 29 Oct 2026 / 405 |
| Win rate | 61.0% (TP 222, SL 120, time stop 63) |
| Average win / average loss | +15.8 / −20.7 pips |
| Expectancy | **+1.55 pips per trade** |
| Profit factor | 1.19 |
| Net | +629 pips |
| Max drawdown | 284 pips |
| Longest losing streak | 6 trades |
| Worst day | −102.5 pips |
| Trades per day | 0.55 on average, 5 at most |
| BUY / SELL | BUY 65.0%, +543 pips; SELL 57.8%, +86 pips |

**Out-of-sample check.** I chose the settings using only the first 60% of the data, then tested on the
last 40% that the choice never saw. The training half (268 trades) won 60.1% with +1.4 pips per trade. The unseen
half (137 trades) won 62.8% with +1.9 pips per trade, which is consistent but still a small sample.

**Cost sensitivity.** The edge disappears if each trade costs more:

| Cost per trade | Expectancy | Net |
|---|---|---|
| 0.8 pips | +1.95 | +791 |
| 1.2 pips | +1.55 | +629 |
| 2.0 pips | +0.75 | +305 |
| 3.0 pips | −0.25 | −100 |

**By quarter.** Profitable in 8 of 12 quarters. Losing quarters: 2024 Q1 (41% win, −126), 2024 Q2,
2024 Q4, 2026 Q2. Expect losing stretches.

---

## 6. What did not work (so you don't repeat it)

| Change | Trades | Win | Expectancy | Net |
|---|---|---|---|---|
| **The rule as written** | 405 | 61.0% | **+1.55** | **+629** |
| Without the H1 Hull | 1,825 | 56.4% | −0.65 | −1,178 |
| Trading all hours | 533 | 57.4% | +0.26 | +140 |
| RSI floor 30 instead of 40 (lets in oversold chases) | 548 | 57.3% | +0.14 | +78 |
| Without the previous-day room check | 459 | 60.6% | +1.37 | +631 |
| Tighter 1.0 target / 1.5 stop | 447 | 62.6% | −0.11 | −49 |
| **Same rule on M5** (13 months) | 221 | 51.1% | −2.27 | −502 |

Lessons:
- **More trades means worse trades.** Loosening the filters gave 2–5 trades a day and turned the result
  negative.
- **A higher win rate from a smaller target** (1.0 vs 1.5) looks better on paper and loses money.
- **The previous-day check barely changes the result**, so treat it as optional common sense, not an edge.
- **Don't scalp M5 with this rule.**

---

## 7. Limits of this benchmark

- **Spread is assumed (1.2 pips).** Your broker's history does not store a usable spread, so I used the
  current quote (about 1.1 pips) plus slippage. Real news and rollover spreads are much wider.
- **If a candle hit both stop and target, I counted the stop** (pessimistic).
- **I tried 2,304 setting combinations.** Choosing the best one from that many flatters the result even
  with an out-of-sample check. The same cluster of settings (target 1.5, stop 2.0, RSI floor 40, 4-candle
  pullback, H1 Hull on) also held up in neighbouring combinations, which is encouraging but not proof.
- **One pair, one broker, 2.8 years.** The edge is also thin: a bad cost assumption or a regime change
  can erase it.
- **No commissions or swaps were counted.** Your history shows commission is 0, and swap is small for
  intraday holds.

**Before real money:** forward-test on a demo account for at least 50 trades, and only continue if the
win rate and expectancy stay close to the table above.

---

## 8. Daily checklist

1. Server time 03:00–19:00? No news in the next 30 minutes? Spread under 2 pips?
2. M15 and H1 Hull agree? Direction chosen.
3. Wait for the pullback to the Bollinger middle band and an RSI turn through 50.
4. Act only on the M15 candle close. Check the 5 rule lines in §2.
5. Set the stop and target **before** you leave the screen: Profile B is SL 2 × ATR / TP 1.5 × ATR; Profile A is SL 3 × ATR / TP 1.0 × ATR and needs the order-block touch (rule 9).
6. Log the trade. Stop after 3 losses or 5 trades.

---

## Re-running the benchmark

The scripts are in `research/`: `bt.py` (the engine), `grid.py` (the settings search) and `final.py`
(the Profile B report); `final2.py` and `hi_win.py` cover Profile A. Run `python -I final.py` from that folder, with MT5 open and logged in. The trade list is in
`research/trades_M15.csv`.
