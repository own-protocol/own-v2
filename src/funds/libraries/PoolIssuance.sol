// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundFactory} from "../../interfaces/IFundFactory.sol";
import {IFundVenue} from "../../interfaces/IFundVenue.sol";
import {IssuanceConfig, IssuanceStep, PremiumConfig, PremiumConfigLib} from "../../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title PoolIssuance — the venue's pool issuance and price math
/// @notice External library, linked at deployment and run in the venue's context (delegatecall).
///         The small price conversions are internal, so they compile into the venue.
/// @dev Prices are carried as `q`, the square root of the pool price as USDG per fund token in raw
///      units, Q96. With `L` the pool's active liquidity and `A = L * 2^96`, moving the price from
///      `q` to `q'` takes `A / q - A / q'` fund tokens out of the pool, while issuing `d` of
///      circulating supply `S` per doubling of price issues `c * ln(q' / q)` with `c = 2 d S / ln 2`
///      (`d` the density step the price is in). So after buys lift the price from the anchor `r` to
///      `q1`, selling `A / q2 - A / q1` newly issued tokens brings it to the `q2` where the sale plus
///      what was issued since the anchor equals the issuance from `r` to `q2`: the pool and the
///      supply end where issuing along the way would have left them.
library PoolIssuance {
    // 2 / ln 2, 18 decimals.
    uint256 private constant TWO_OVER_LN2 = 2_885_390_081_777_926_815;

    uint256 private constant Q96 = 1 << 96;

    // ln 2, 18 decimals.
    uint256 private constant LN2 = 693_147_180_559_945_309;

    // Newton steps allowed per density step; each at least doubles the distance covered, then
    // converges quadratically.
    uint256 private constant MAX_NEWTON_STEPS = 48;

    /// @notice The pool's state for {target}.
    /// @param anchor    `q` where the current issuance run starts.
    /// @param issued    Fund tokens issued since the anchor.
    /// @param q1        The pool's `q` now.
    /// @param liquidity The pool's active liquidity.
    struct Pool {
        uint256 anchor;
        uint256 issued;
        uint256 q1;
        uint256 liquidity;
    }

    // Hourly issuance cap a new fund starts with: 5% of circulating supply.
    uint16 private constant DEFAULT_HOURLY_CAP_BPS = 500;

    /// @notice Replace a fund's issuance settings with the factory's defaults. See {configure}.
    /// @param dst     The fund's stored steps.
    /// @param factory The factory.
    /// @return startBps     Issuance start, for the venue to store.
    /// @return potShareBps  Pot share, for the venue to store.
    /// @return hourlyCapBps Hourly cap, for the venue to store.
    function configureDefaults(
        IssuanceStep[] storage dst,
        IFundFactory factory
    ) external returns (uint16 startBps, uint16 potShareBps, uint16 hourlyCapBps) {
        PremiumConfig memory c = factory.premiumConfig();
        return configure(
            dst,
            IssuanceConfig({
                startBps: c.issuanceStartBps,
                potShareBps: c.potShareBps,
                hourlyCapBps: DEFAULT_HOURLY_CAP_BPS,
                steps: factory.defaultIssuanceSteps()
            })
        );
    }

    /// @notice Replace a fund's issuance settings, reverting unless they are within bounds. Stores
    ///         the density steps and returns the rest for the venue to store.
    /// @param dst    The fund's stored steps.
    /// @param config New settings.
    /// @return startBps     Issuance start.
    /// @return potShareBps  Pot share.
    /// @return hourlyCapBps Hourly cap.
    function configure(
        IssuanceStep[] storage dst,
        IssuanceConfig memory config
    ) public returns (uint16 startBps, uint16 potShareBps, uint16 hourlyCapBps) {
        IssuanceStep[] memory steps = config.steps;
        if (config.potShareBps > BPS || config.hourlyCapBps > BPS || !PremiumConfigLib.stepsValid(steps)) {
            revert IFundVenue.InvalidIssuance();
        }
        while (dst.length != 0) {
            dst.pop();
        }
        for (uint256 i; i < steps.length; ++i) {
            dst.push(steps[i]);
        }
        emit IFundVenue.IssuanceSet(config);
        return (config.startBps, config.potShareBps, config.hourlyCapBps);
    }

    /// @notice The `q` an issuing sale may bring the pool down to, or zero when nothing is due:
    ///         none while `q1` is at or below the later of the anchor and the issuance start, or
    ///         when what was issued since the anchor already covers the rise.
    /// @param steps    The fund's density steps.
    /// @param startBps Issuance start, in basis points over NAV.
    /// @param nav      NAV per fund token, 18 decimals.
    /// @param supply   Circulating supply.
    /// @param pool     The pool's state.
    /// @param usdgUnit One USDG in raw units.
    /// @return q The target `q`.
    function target(
        IssuanceStep[] storage steps,
        uint256 startBps,
        uint256 nav,
        uint256 supply,
        Pool memory pool,
        uint256 usdgUnit
    ) external view returns (uint256 q) {
        q = Math.max(pool.anchor, qOf(Math.mulDiv(nav, BPS + startBps, BPS, Math.Rounding.Ceil), usdgUnit));
        if (pool.q1 <= q) return 0;
        uint256 a = pool.liquidity * Q96;
        // Tokens out of the pool from the anchor, plus those issued since, must cover `due`: the
        // issuance from the anchor, accumulated one density step at a time.
        uint256 floor = a / pool.q1;
        uint256 due;
        uint256 density;
        uint256 i;
        uint256 next;
        while (true) {
            while (i < steps.length) {
                next = qOf(Math.mulDiv(nav, BPS + steps[i].premiumBps, BPS), usdgUnit);
                if (next > q) break;
                density = steps[i].densityBps;
                ++i;
            }
            uint256 hi = i < steps.length ? Math.min(next, pool.q1) : pool.q1;
            uint256 c = Math.mulDiv(supply, density * TWO_OVER_LN2, BPS * PRECISION);
            uint256 grown = Math.mulDiv(c, _ln(Math.mulDiv(hi, PRECISION, q)), PRECISION);
            if (a / hi + pool.issued > floor + due + grown) {
                // The whole step is covered: nothing due if it ends at the current price.
                if (hi == pool.q1) return 0;
                (q, due) = (hi, due + grown);
                continue;
            }
            q = _solve(q, a, floor + due, pool.issued, c) + 1;
            return q < pool.q1 ? q : 0;
        }
    }
    /// @notice Square root of the price `amount1 / amount0` a pool opens at, Q96.
    /// @param amount0 Currency 0 added.
    /// @param amount1 Currency 1 added.
    /// @return The square root price.

    function seedSqrtPrice(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) {
            revert IFundVenue.InvalidSeed();
        }
        return uint160(sqrtPrice);
    }

    /// @notice Amounts to add to a full-range position for `usdgAmount` of USDG at `sqrtPrice`:
    ///         the fund tokens worth it at that price plus 0.1%, so the USDG binds and the extra
    ///         tokens are left over (to be burned).
    /// @param sqrtPrice  The pool's square root price, Q96.
    /// @param usdgIs0    Whether USDG is the pool's currency 0.
    /// @param usdgUnit   One USDG in raw units.
    /// @param usdgAmount USDG to add.
    /// @return amount0 Currency 0 amount.
    /// @return amount1 Currency 1 amount.
    /// @return shares  Fund tokens to mint.
    function matchUsdg(
        uint160 sqrtPrice,
        bool usdgIs0,
        uint256 usdgUnit,
        uint256 usdgAmount
    ) external pure returns (uint256 amount0, uint256 amount1, uint256 shares) {
        uint256 price = priceOf(qAt(sqrtPrice, usdgIs0), usdgUnit);
        shares = Math.mulDiv(usdgAmount, PRECISION * PRECISION * 1001, price * usdgUnit * 1000) + 1;
        (amount0, amount1) = usdgIs0 ? (usdgAmount, shares) : (shares, usdgAmount);
    }

    /// @notice The pool's square root price at `price` USD per fund token (18 decimals), held
    ///         within Uniswap's range.
    /// @param price    USD per fund token, 18 decimals.
    /// @param usdgIs0  Whether USDG is the pool's currency 0.
    /// @param usdgUnit One USDG in raw units.
    /// @return The square root price, Q96.
    function sqrtPriceAt(uint256 price, bool usdgIs0, uint256 usdgUnit) internal pure returns (uint160) {
        uint256 q = qOf(price, usdgUnit);
        if (q == 0) return TickMath.MAX_SQRT_PRICE - 1;
        uint256 sqrtPrice = usdgIs0 ? (1 << 192) / q : q;
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (sqrtPrice >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sqrtPrice);
    }

    /// @notice `q` at the pool's square root price.
    /// @param sqrtPrice The pool's square root price, Q96.
    /// @param usdgIs0   Whether USDG is the pool's currency 0.
    /// @return `q`.
    function qAt(uint160 sqrtPrice, bool usdgIs0) internal pure returns (uint256) {
        return usdgIs0 ? (1 << 192) / sqrtPrice : sqrtPrice;
    }

    /// @notice USD per fund token (18 decimals each), counting USDG as $1.
    /// @param q        Square root of the pool price, USDG per fund token in raw units, Q96.
    /// @param usdgUnit One USDG in raw units.
    /// @return The price.
    function priceOf(uint256 q, uint256 usdgUnit) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(q, q, Q96), PRECISION * PRECISION / usdgUnit, Q96);
    }

    /// @notice `q` at `price` USD per fund token (18 decimals each); the inverse of {priceOf}.
    /// @param price    USD per fund token, 18 decimals.
    /// @param usdgUnit One USDG in raw units.
    /// @return `q`.
    function qOf(uint256 price, uint256 usdgUnit) internal pure returns (uint256) {
        return Math.sqrt(Math.mulDiv(price * usdgUnit, 1 << 192, PRECISION * PRECISION));
    }

    /// @dev Newton's method from `base` for `a / q + issued = need + c * ln(q / base)`. The left side
    ///      less the right is convex and falling, so every step lands at or below the root: the
    ///      result never prices the pool above the issuance due.
    function _solve(
        uint256 base,
        uint256 a,
        uint256 need,
        uint256 issued,
        uint256 c
    ) private pure returns (uint256 q) {
        q = base;
        for (uint256 k; k < MAX_NEWTON_STEPS; ++k) {
            uint256 have = a / q + issued;
            uint256 owed = need + Math.mulDiv(c, _ln(Math.mulDiv(q, PRECISION, base)), PRECISION);
            if (have <= owed) break;
            uint256 step = Math.mulDiv(have - owed, q, a / q + c);
            if (step <= q >> 48) break;
            q += step;
        }
    }

    /// @dev Natural log of `x` >= 1 (18 decimals): `k ln 2` for the power of two, then the atanh
    ///      series to the ninth power on the rest, whose error is under 2e-6 and always low.
    function _ln(
        uint256 x
    ) private pure returns (uint256) {
        uint256 k = Math.log2(x / PRECISION);
        uint256 m = x >> k;
        uint256 z = Math.mulDiv(m - PRECISION, PRECISION, m + PRECISION);
        uint256 z2 = Math.mulDiv(z, z, PRECISION);
        uint256 term = z;
        uint256 sum = z;
        for (uint256 n = 3; n <= 9; n += 2) {
            term = Math.mulDiv(term, z2, PRECISION);
            sum += term / n;
        }
        return k * LN2 + 2 * sum;
    }
}
