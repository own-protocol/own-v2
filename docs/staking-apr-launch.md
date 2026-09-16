# OwnStakingV2 — launch APR reference

Boost model (`LinearBoostCalculator`, live): `boost = min(0.1 + 1.1667 × coverage, 3.6)`.
Weight = boost × eUSD; a fixed weekly SPY budget splits pro-rata by weight, so
`APR(boost) = boost × 52 × weeklyBudget / totalWeight`. APR is quoted on eUSD staked alone
($MONEY capital never enters the denominator). Money-free stakers earn the 0.1× floor, not 0×.
Rewards are SPY tokens (USD value drifts with SPY intra-week); APRs scale inversely with TVL at a
fixed budget, and blended APR is always `52 × budget / TVL` regardless of the tier mix — boosts
only redistribute the pot. Uniform boost (whatever its level) therefore pays everyone the blended
rate. Regenerate any mix with `script/staking_apr.py <weekly_budget> <tvl> <boost:share_pct> …`.

All tables: **$10k/week budget, $100k eUSD staked** (blended 520%).

## Mix A — 60% full boost / 30% at 1× / 10% floor

| Boost | eUSD | Stream % | Weekly $ | APR |
|---|---|---|---|---|
| 3.6× | $60k | 87.4% | $8,745 | 758% |
| 1.0× | $30k | 12.1% | $1,215 | 211% |
| 0.1× | $10k | 0.4% | $40 | 21% |

Total weight 247,000.

## Mix B — 30/30/20/10/10 ladder

| Boost | eUSD | Stream % | Weekly $ | APR |
|---|---|---|---|---|
| 3.0× | $30k | 51.1% | $5,114 | 886% |
| 2.0× | $30k | 34.1% | $3,409 | 591% |
| 1.0× | $20k | 11.4% | $1,136 | 295% |
| 0.5× | $10k | 2.8% | $284 | 148% |
| 0.1× | $10k | 0.6% | $57 | 30% |

Total weight 176,000.

## Mix C — 100% fully boosted (3.6×)

| Boost | eUSD | Stream % | Weekly $ | APR |
|---|---|---|---|---|
| 3.6× | $100k | 100% | $10,000 | 520% |

Total weight 360,000. Everyone at the same boost ⇒ everyone earns the blended 520% — identical
to a 100%-unboosted pool. Boost only pays relative to stakers with less of it.
