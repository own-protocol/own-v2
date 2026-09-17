#!/usr/bin/env python3
"""Staking APR table for OwnStakingV2's linear boost curve.

Splits a fixed weekly SPY budget across boost tiers by weight (boost x eUSD) and
prints per-tier APR, quoted on eUSD staked alone (house convention — $MONEY capital
is never in the denominator). Money-free stakers earn the curve floor (0.1x), not 0x.

Usage:
    python3 script/staking_apr.py <weekly_budget_usd> <tvl_usd> <boost:share_pct> [...]
    python3 script/staking_apr.py base=<apr_pct> <tvl_usd> <boost:share_pct> [...]

The base= form solves the weekly budget that pegs the lowest tier's APR to the target,
then prints the same table. Example:
    python3 script/staking_apr.py 10000 100000 3.6:60 1.0:30 0.1:10
    python3 script/staking_apr.py base=6 1000000 3.0:50 1.0:40 0.1:10
"""

import sys


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    tvl = float(sys.argv[2])
    tiers = [(float(b), float(s)) for b, s in (a.split(":") for a in sys.argv[3:])]
    if abs(sum(s for _, s in tiers) - 100) > 1e-9:
        sys.exit("tier shares must sum to 100")

    total_weight = sum(b * tvl * s / 100 for b, s in tiers)
    if sys.argv[1].startswith("base="):
        floor = min(b for b, _ in tiers)
        budget = float(sys.argv[1][5:]) / 100 * total_weight / (52 * floor)
        print(f"weekly budget to peg {floor:.2f}x tier: ${budget:,.0f}\n")
    else:
        budget = float(sys.argv[1])
    per_weight = 52 * budget / total_weight  # annual $ per unit of weight

    print(f"{'boost':>6} {'eUSD':>12} {'weight':>12} {'stream %':>9} {'weekly $':>10} {'APR':>9}")
    for b, s in tiers:
        eusd = tvl * s / 100
        weight = b * eusd
        print(
            f"{b:>5.2f}x {eusd:>12,.0f} {weight:>12,.0f} "
            f"{100 * weight / total_weight:>8.1f}% {budget * weight / total_weight:>10,.0f} "
            f"{100 * per_weight * b:>8.1f}%"
        )
    print(
        f"\nblended APR {100 * 52 * budget / tvl:.1f}%  ·  total weight {total_weight:,.0f}"
        f"  ·  APR(b) = b x 52 x budget / total_weight"
    )


if __name__ == "__main__":
    main()
