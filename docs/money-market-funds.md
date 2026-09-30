# MONEY Market Funds

Basket-backed fund tokens (MF1 first) that anyone on the launcher whitelist can create. Each fund
is an ERC-20 backed by a basket of Robinhood-chain tokens and stock tokens, trades in its own
Uniswap v4 pool against USDG, and pays stakers new tokens while it trades above NAV.

## Contracts (`src/funds/`)

| Contract | Role |
| --- | --- |
| `FundFactory` | UUPS. Platform admin hub: launcher whitelist (can be switched off), protocol fee (0.5% default, 5% cap), rebalance routers and limits, launch and governance parameters, the staking yield cap (3% a day default) and the platform metadata. Owns the four module beacons, so one call upgrades every fund. |
| `Fund` | Beacon proxy per fund. The fund token plus basket custody: mint, redeem, locks, rebalance. |
| `FundLaunch` | Beacon proxy per fund. The 36-hour deposit window, graduation and pool seeding. |
| `FundStaking` | Beacon proxy per fund. Staked fund token (sMF1) with premium-tiered issuance. |
| `FundGovernor` | Beacon proxy per fund. Creator-plus-holder voting on the basket; the only source of portfolio changes. The admin can swap it per fund. |
| `FundHook` | One Uniswap v4 hook for every fund pool: USDG swap fees, admin-set LP fee, and the permanently locked launch liquidity. |
| `FundOracle` | Per-asset Chainlink-style feeds. A fund token's own market price is read through the same surface. |
| `FundTwapFeed` | Per fund. Serves the fund's pool TWAP (recorded by the hook) as an aggregator, so the market price needs no keeper. |
| `FundRedeemZap` | Redeem a fund token and swap the basket to USDG through allowed routers in one transaction. |

## Lifecycle

1. **Create.** A whitelisted launcher calls `createFund` with the name, symbol, logo, description,
   basket, target weights, the manager (creator), a creator fee of 0 to 10%, the minimum raise,
   lock options and yield tiers. Only the admin can change the creator fee, lock options and yield
   tiers afterwards. The creator or the admin can update the name, symbol, logo and description;
   every fund also shows the platform metadata the admin sets on the factory.
2. **Launch window (36h).** Anyone deposits any basket asset plus USDG worth 30% of it. Deposits
   are not capped per asset; the manager rebalances any excess after launch.
3. **Finalize.** Assets are valued at closing oracle prices (basket value R, USDG U).
   - If R is below the minimum, every depositor is refunded. If nobody finalizes within 7 days of
     the close, anyone can mark the launch failed and refunds open.
   - Otherwise depositors get C = R fund tokens, one per dollar they brought. The pool gets
     M = U·C / (1.3R − U) newly minted tokens plus all the USDG, as one full-range position that
     the hook owns and can never remove.
   - Every token counts in NAV, the pool's included. So NAV = R / (C + M) and the pool opens at
     1.3 × NAV. With a 30% USDG ratio that is $1.00 against a NAV of about $0.77.
4. **Live.**
   - **Mint** with any basket asset at `max(marketTWAP × (1 − lockDiscount), NAV)`. Taking a lock
     option earns the discount and holds the tokens until it expires. A mint is never priced below
     NAV, so it never dilutes holders.
   - **Redeem** for a pro-rata slice of every basket asset at any time. It needs no oracle and
     cannot be paused. Converting the slice to USDG is left to a separate router.
   - **Pool trades** pay the protocol fee and the creator fee in USDG through the hook, plus an
     optional LP fee the admin sets per pool. LP fees on the locked position go to the LP fee
     recipient.
   - **Fees on mint and redeem** are the same two fees, charged in fund tokens.
   - **Staking:** while the market TWAP trades at a premium to NAV, sMF1 earns the daily rate of
     the highest tier that premium reaches, paid by minting new fund tokens. Every tier is capped
     by the factory's yield cap (3% a day by default, admin-set; lowering it clamps existing
     tiers at once). There is no yield at or below NAV.
   - **Portfolio changes:** only the governor can change assets and weights. The creator
     proposes and holds 30% of the vote; holders share 70% in proportion to the fund tokens they
     vote with (fund token, sMF1, or an admin-listed ERC-4626 wrapper of sMF1), measured against
     holder supply at proposal time (pool, locked mints, unclaimed launch tokens and the
     creator's own balance excluded). A proposal passes with at least 50% in favour, of which at
     least 20% from holders. Voting runs 3 days, then a 1-day delay in which the admin can veto,
     then anyone executes within 7 days. Votes are escrowed: tokens deposited to vote stay locked
     until the end of every proposal voted on, which rules out flash-loan and double votes. The
     admin can swap in another governor (quadratic, futarchy, bribes) per fund.
   - **Rebalancing:** the manager swaps between basket assets through admin-allowed routers. Each
     swap may lose at most 2% of oracle value, and the value sold is capped at 10% of the basket
     per rolling day. Dropping an asset takes a vote to weight 0, a rebalance out, then a vote to
     remove it.
   - **Market price:** the hook adds the pool tick to an accumulator before every swap and keeps
     checkpoints at least 5 minutes apart for over 3 hours. `FundTwapFeed` reads a 30-minute TWAP
     from it (USDG counted as $1). Anyone can call `hook.poke(fund)` to keep checkpoints regular
     while trading is quiet; no keeper pushes prices.

## Trust and limits

- **Admin (factory owner):** upgrades all modules and sets fees, the whitelist, routers, the LP fee
  and each fund's creator fee, lock options and yield tiers.
- **Manager:** trusted only within the rebalance bounds above.
- **Oracle feeds:** basket asset prices come from admin-set feeds; the fund's market price comes
  from its own pool TWAP. Redeem depends on neither.
- **Governance:** holders can be outvoted only up to the thresholds above; the admin can veto
  within the delay and can replace the governor.
- **USDG:** treated as $1 when sizing launch deposits.
- **Hook address:** the hook must be deployed (CREATE2-mined) at an address whose low bits encode
  `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta`.
  The Uniswap v4 PoolManager on Robinhood Chain is `0x8366a39cc670b4001a1121b8f6a443a643e40951`.

## Deployment

`script/funds/DeployFundsRobinhood.s.sol` deploys everything, mines the hook's CREATE2 salt
(`script/funds/HookMiner.sol`), wires the hook and platform metadata and hands ownership to
`FUNDS_ADMIN` (two-step). After a fund launches, `script/funds/AddFundTwapFeedRobinhood.s.sol`
deploys its TWAP feed and registers it in the oracle.

## Tests

- `test/unit/Fund*.t.sol` run against a real v4 PoolManager, deployed from precompiled bytecode in
  `test/helpers/v4/PoolManagerBytecode.sol` (v4-core pins solc 0.8.26; this repo pins 0.8.28).
- `test/invariant/FundInvariant.t.sol` checks that mints and redeems never lower NAV per token.
