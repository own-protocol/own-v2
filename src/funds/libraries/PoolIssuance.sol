// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../../interfaces/IFund.sol";

import {IFundFactory} from "../../interfaces/IFundFactory.sol";
import {IFundHook} from "../../interfaces/IFundHook.sol";
import {IssuanceConfig, IssuanceStep, PremiumConfig, PremiumConfigLib} from "../../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title PoolIssuance — the hook's pool issuance and position math
/// @notice External library, linked at deployment and run in the hook's context (delegatecall), so
///         the hook stays under the contract size limit.
/// @dev With `q` the square root of the pool price (USDG per fund token, raw units) and `L` the
///      pool's active liquidity, the AMM releases `(L / q) * dq / q` fund tokens as `q` rises by
///      `dq`, while issuing `d` of circulating supply `S` per doubling of price issues `c * dq / q`
///      with `c = 2 d S / ln 2`. So the hook fills `c q / (L + c q)` of a buy, priced at the AMM's own
///      average price over the rest of the buy (`q0 * q1`), and the AMM fills the rest. The split and
///      the density level are fixed at the swap's starting price.
library PoolIssuance {
    using StateLibrary for IPoolManager;

    // 2 / ln 2, 18 decimals.
    uint256 private constant TWO_OVER_LN2 = 2_885_390_081_777_926_815;

    uint256 private constant Q96 = 1 << 96;

    /// @notice A buy to fill in part.
    /// @param pm          The pool manager.
    /// @param fund        The fund.
    /// @param usdg        USDG.
    /// @param usdgUnit    One USDG in raw units.
    /// @param id          The fund's pool.
    /// @param usdgIs0     Whether USDG is the pool's currency 0.
    /// @param startBps    Premium over NAV below which nothing is issued, in basis points.
    /// @param potShareBps Share of the premium over NAV that goes to the Premium Pot.
    /// @param amount      For exact input the USDG left after the fee, for exact output the fund
    ///                    tokens bought.
    /// @param exactIn     Whether the buy is exact input.
    struct Buy {
        IPoolManager pm;
        address fund;
        address usdg;
        uint256 usdgUnit;
        PoolId id;
        bool usdgIs0;
        uint256 startBps;
        uint256 potShareBps;
        uint256 amount;
        bool exactIn;
    }

    /// @notice Fill part of a buy with new fund tokens, inside the pool manager's swap: the issued
    ///         tokens go to the pool manager for the buyer, and the USDG paid for them becomes pool
    ///         manager claims held by the hook for the fund (the buyer's USDG may not have arrived
    ///         yet). Issues nothing when NAV is unavailable, so a swap never fails for want of it.
    /// @param steps The fund's density steps.
    /// @param b     The buy.
    /// @return usdgIn    USDG claims taken for the fund.
    /// @return tokensOut Fund tokens issued.
    function issue(IssuanceStep[] storage steps, Buy memory b) external returns (uint256 usdgIn, uint256 tokensOut) {
        (bool ok, uint256 nav, uint256 supply) = IFund(b.fund).tryNav();
        if (!ok) return (0, 0);
        (usdgIn, tokensOut) = _split(steps, b, nav, supply);
        if (tokensOut == 0) return (0, 0);

        uint256 paid = Math.mulDiv(usdgIn, PRECISION, b.usdgUnit);
        uint256 atNav = Math.mulDiv(tokensOut, nav, PRECISION);
        uint256 pot = paid > atNav ? Math.mulDiv(paid - atNav, b.potShareBps, BPS) : 0;
        b.pm.mint(address(this), uint256(uint160(b.usdg)), usdgIn);
        b.pm.sync(Currency.wrap(b.fund));
        IFund(b.fund).hookIssue(address(b.pm), tokensOut, pot);
        b.pm.settle();
        emit IFundHook.Issued(b.fund, usdgIn, tokensOut, pot);
    }

    /// @notice Replace a fund's issuance settings with the factory's defaults. See {configure}.
    /// @param dst     The fund's stored steps.
    /// @param fund    The fund.
    /// @param factory The factory.
    /// @return startBps    Issuance start, for the hook to store.
    /// @return potShareBps Pot share, for the hook to store.
    function configureDefaults(
        IssuanceStep[] storage dst,
        address fund,
        IFundFactory factory
    ) external returns (uint16 startBps, uint16 potShareBps) {
        PremiumConfig memory c = factory.premiumConfig();
        return configure(
            dst,
            fund,
            IssuanceConfig({
                startBps: c.issuanceStartBps,
                potShareBps: c.potShareBps,
                steps: factory.defaultIssuanceSteps()
            })
        );
    }

    /// @notice Replace a fund's issuance settings, reverting unless they are within bounds. Stores
    ///         the density steps and returns the start and pot share for the hook to store.
    /// @param dst    The fund's stored steps.
    /// @param fund   The fund.
    /// @param config New settings.
    /// @return startBps    Issuance start.
    /// @return potShareBps Pot share.
    function configure(
        IssuanceStep[] storage dst,
        address fund,
        IssuanceConfig memory config
    ) public returns (uint16 startBps, uint16 potShareBps) {
        IssuanceStep[] memory steps = config.steps;
        if (config.potShareBps > BPS || !PremiumConfigLib.stepsValid(steps)) revert IFundHook.InvalidIssuance();
        while (dst.length != 0) {
            dst.pop();
        }
        for (uint256 i; i < steps.length; ++i) {
            dst.push(steps[i]);
        }
        emit IFundHook.IssuanceSet(fund, config);
        return (config.startBps, config.potShareBps);
    }

    /// @notice Square root of the price `amount1 / amount0` a pool is seeded at, Q96.
    /// @param amount0 Currency 0 seeded.
    /// @param amount1 Currency 1 seeded.
    /// @return The square root price.
    function seedSqrtPrice(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) {
            revert IFundHook.InvalidSeed();
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
        uint256 price = priceOf(usdgIs0 ? (1 << 192) / sqrtPrice : sqrtPrice, usdgUnit);
        shares = Math.mulDiv(usdgAmount, PRECISION * PRECISION * 1001, price * usdgUnit * 1000) + 1;
        (amount0, amount1) = usdgIs0 ? (usdgAmount, shares) : (shares, usdgAmount);
    }

    /// @notice USD per fund token (18 decimals each), counting USDG as $1.
    /// @param q        Square root of the pool price, USDG per fund token in raw units, Q96.
    /// @param usdgUnit One USDG in raw units.
    /// @return The price.
    function priceOf(uint256 q, uint256 usdgUnit) public pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(q, q, Q96), PRECISION * PRECISION / usdgUnit, Q96);
    }

    function _split(
        IssuanceStep[] storage steps,
        Buy memory b,
        uint256 nav,
        uint256 supply
    ) private view returns (uint256 usdgIn, uint256 tokensOut) {
        (uint160 sqrtPrice,,,) = b.pm.getSlot0(b.id);
        uint256 q = b.usdgIs0 ? (1 << 192) / sqrtPrice : sqrtPrice;
        uint256 liquidity = b.pm.getLiquidity(b.id);
        uint256 cq = _issuanceTerm(steps, b, nav, supply, q);
        if (cq == 0 || liquidity == 0 || b.amount == 0) return (0, 0);
        if (b.exactIn) {
            usdgIn = Math.mulDiv(b.amount, cq, liquidity + cq);
            uint256 q1 = q + Math.mulDiv(b.amount - usdgIn, Q96, liquidity);
            // Rounds down: the buyer never gets more than the USDG pays for at the AMM's average price.
            tokensOut = Math.mulDiv(Math.mulDiv(usdgIn, Q96, q), Q96, q1);
        } else {
            tokensOut = Math.mulDiv(b.amount, cq, liquidity + cq);
            // The AMM's rest lowers 1/q by its tokens over the liquidity.
            uint256 drop = Math.mulDiv(b.amount - tokensOut, q, Q96);
            if (drop >= liquidity) return (0, 0);
            uint256 q1 = Math.mulDiv(liquidity, q, liquidity - drop, Math.Rounding.Ceil);
            // Rounds up: the buyer pays at least the AMM's average price.
            usdgIn = Math.mulDiv(Math.mulDiv(tokensOut, q, Q96, Math.Rounding.Ceil), q1, Q96, Math.Rounding.Ceil);
        }
        if (usdgIn == 0 || tokensOut == 0) return (0, 0);
    }

    /// @dev `c * q` at the swap's starting price, zero below the issuance start.
    function _issuanceTerm(
        IssuanceStep[] storage steps,
        Buy memory b,
        uint256 nav,
        uint256 supply,
        uint256 q
    ) private view returns (uint256) {
        uint256 price = priceOf(q, b.usdgUnit);
        if (price * BPS < nav * (BPS + b.startBps)) return 0;
        uint256 premium = Math.mulDiv(price, BPS, nav) - BPS;
        uint256 density;
        for (uint256 i; i < steps.length; ++i) {
            IssuanceStep memory step = steps[i];
            if (premium < step.premiumBps) break;
            density = step.densityBps;
        }
        return Math.mulDiv(Math.mulDiv(supply, density * TWO_OVER_LN2, BPS * PRECISION), q, Q96);
    }
}
