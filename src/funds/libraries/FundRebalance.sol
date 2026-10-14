// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../../interfaces/IFund.sol";
import {IFundFactory} from "../../interfaces/IFundFactory.sol";
import {IFundHook} from "../../interfaces/IFundHook.sol";
import {IFundLaunch} from "../../interfaces/IFundLaunch.sol";
import {IFundOracle} from "../../interfaces/IFundOracle.sol";
import {BasketEntry, DUST_BPS, MAX_BASKET_ASSETS} from "../../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundRebalance — basket changes: new target weights and the manager's bounded swap
/// @notice External library, linked at deployment and run in the fund's context (delegatecall), so
///         the fund stays under the contract size limit. The fund checks the caller and reentrancy.
library FundRebalance {
    using SafeERC20 for IERC20;

    /// @notice Replace the basket and its target weights. See {IFund-setTargetWeights}. Every new
    ///         asset needs an oracle feed; an asset dropped with a balance worth more than
    ///         `DUST_BPS` of the old basket (or with no price) blocks the change.
    /// @param o           The oracle.
    /// @param usdg        The factory's USDG.
    /// @param assets      The basket, replaced.
    /// @param basket      Basket membership, replaced.
    /// @param assets_     New assets.
    /// @param weightsBps_ New target weights (sum 10 000).
    function setBasket(
        IFundOracle o,
        address usdg,
        address[] storage assets,
        mapping(address => BasketEntry) storage basket,
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) public {
        address[] memory old = assets;
        for (uint256 i; i < old.length; ++i) {
            delete basket[old[i]];
        }
        _list(o, usdg, basket, assets_, weightsBps_);
        _checkDropped(o, basket, old);
        while (assets.length != 0) {
            assets.pop();
        }
        for (uint256 i; i < assets_.length; ++i) {
            assets.push(assets_[i]);
        }
        emit IFund.TargetWeightsSet(assets_, weightsBps_);
    }

    /// @notice Swap through an allowed router within the slippage and daily volume bounds. See
    ///         {IFund-rebalance}. Until the fund's pool is seeded (the launch rebalance) the swap may
    ///         buy USDG, and a USDG buy that leaves idle USDG within the pool's USDG is free of the
    ///         volume cap.
    /// @param factory         The fund's factory.
    /// @param usdg            The factory's USDG.
    /// @param assets          The basket.
    /// @param basket          Basket membership.
    /// @param params          The swap.
    /// @param volume          Rebalance volume before this swap (USD, 18 decimals).
    /// @param volumeUpdatedAt When `volume` was last updated.
    /// @return newVolume Volume after this swap.
    function rebalance(
        address factory,
        address usdg,
        address[] storage assets,
        mapping(address => BasketEntry) storage basket,
        IFund.RebalanceParams calldata params,
        uint256 volume,
        uint256 volumeUpdatedAt
    ) public returns (uint256 newVolume) {
        IFundFactory fac = IFundFactory(factory);
        if (!fac.isRouter(params.router) || basket[params.router].listed || params.router == address(this)) {
            revert IFund.RouterNotAllowed();
        }
        bool launching = !IFundHook(fac.hook()).isSeeded(address(this));
        if (
            (!basket[params.sellAsset].listed && params.sellAsset != usdg)
                || (!basket[params.buyAsset].listed && !(launching && params.buyAsset == usdg))
                || params.sellAsset == params.buyAsset
        ) {
            revert IFund.InvalidBasket();
        }
        if (params.sellAmount == 0) revert IFund.ZeroAmount();

        // Every basket asset plus idle USDG: only the sold one may fall, only the bought one rise.
        uint256 n = assets.length;
        address[] memory tracked = new address[](n + 1);
        for (uint256 i; i < n; ++i) {
            tracked[i] = assets[i];
        }
        tracked[n] = usdg;
        uint256 soldValue;
        {
            (uint256 sold, uint256 bought) = _swap(params, tracked);
            soldValue = _checkSwapValue(fac, usdg, params, sold, bought);
            emit IFund.Rebalanced(params.sellAsset, sold, params.buyAsset, bought);
            if (launching && params.buyAsset == usdg) soldValue = _beyondPoolUsdg(usdg, soldValue, bought);
        }
        newVolume = _trackVolume(fac, tracked, soldValue, volume, volumeUpdatedAt);
    }

    /// @dev The part of a launch USDG buy's `soldValue` that took idle USDG past the pool's USDG;
    ///      buying up to it is free of the volume cap.
    function _beyondPoolUsdg(address usdg, uint256 soldValue, uint256 bought) private view returns (uint256) {
        uint256 need = IFundLaunch(IFund(address(this)).launch()).poolUsdg();
        uint256 idle = IERC20(usdg).balanceOf(address(this));
        uint256 from = Math.max(idle - bought, need);
        return idle > from ? Math.mulDiv(soldValue, idle - from, bought, Math.Rounding.Ceil) : 0;
    }

    function _swap(
        IFund.RebalanceParams calldata params,
        address[] memory tracked
    ) private returns (uint256 sold, uint256 bought) {
        uint256[] memory before = _balances(tracked);
        uint256 sharesBefore = IERC20(address(this)).balanceOf(address(this));

        IERC20(params.sellAsset).forceApprove(params.router, params.sellAmount);
        (bool success,) = params.router.call(params.data);
        if (!success) revert IFund.RebalanceCallFailed();
        IERC20(params.sellAsset).forceApprove(params.router, 0);

        (sold, bought) = _swapDeltas(params, tracked, before);
        if (IERC20(address(this)).balanceOf(address(this)) < sharesBefore) revert IFund.RebalanceInvalid();
        if (sold > params.sellAmount || bought < params.minBuyAmount) revert IFund.RebalanceInvalid();
    }

    function _balances(
        address[] memory tokens
    ) private view returns (uint256[] memory bals) {
        bals = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            bals[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    function _swapDeltas(
        IFund.RebalanceParams calldata params,
        address[] memory tracked,
        uint256[] memory before
    ) private view returns (uint256 sold, uint256 bought) {
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            uint256 afterBal = IERC20(a).balanceOf(address(this));
            if (a == params.sellAsset) {
                if (afterBal > before[i]) revert IFund.RebalanceInvalid();
                sold = before[i] - afterBal;
            } else if (a == params.buyAsset) {
                if (afterBal < before[i]) revert IFund.RebalanceInvalid();
                bought = afterBal - before[i];
            } else if (afterBal < before[i]) {
                revert IFund.RebalanceInvalid();
            }
        }
    }

    /// @dev Reverts if the swap lost more than the slippage bound in oracle value; returns the
    ///      value sold.
    function _checkSwapValue(
        IFundFactory fac,
        address usdg,
        IFund.RebalanceParams calldata params,
        uint256 sold,
        uint256 bought
    ) private view returns (uint256 soldValue) {
        IFundOracle o = IFundOracle(fac.oracle());
        soldValue = _value(params.sellAsset, sold, params.sellAsset == usdg ? PRECISION : o.price(params.sellAsset));
        uint256 boughtValue =
            _value(params.buyAsset, bought, params.buyAsset == usdg ? PRECISION : o.price(params.buyAsset));
        uint256 minValue = Math.mulDiv(soldValue, BPS - fac.maxRebalanceSlippageBps(), BPS, Math.Rounding.Ceil);
        if (boughtValue < minValue) revert IFund.RebalanceInvalid();
    }

    /// @dev Measured against the post-trade basket and idle USDG (what the manager can trade), which
    ///      differs from pre-trade by at most the slippage bound. The last tracked token is USDG.
    function _trackVolume(
        IFundFactory fac,
        address[] memory tracked,
        uint256 soldValue,
        uint256 volume,
        uint256 updatedAt
    ) private view returns (uint256) {
        IFundOracle o = IFundOracle(fac.oracle());
        uint256 n = tracked.length - 1;
        uint256 tradable;
        for (uint256 i; i < n; ++i) {
            uint256 bal = IERC20(tracked[i]).balanceOf(address(this));
            if (bal != 0) tradable += _value(tracked[i], bal, o.price(tracked[i]));
        }
        tradable += _value(tracked[n], IERC20(tracked[n]).balanceOf(address(this)), PRECISION);
        uint256 cap = Math.mulDiv(tradable, fac.rebalanceVolumeCapBps(), BPS);
        uint256 drained = Math.mulDiv(cap, block.timestamp - updatedAt, 1 days);
        volume = (volume > drained ? volume - drained : 0) + soldValue;
        if (volume > cap) revert IFund.RebalanceVolumeExceeded();
        return volume;
    }

    function _list(
        IFundOracle o,
        address usdg,
        mapping(address => BasketEntry) storage basket,
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) private {
        uint256 n = assets_.length;
        if (n == 0 || n > MAX_BASKET_ASSETS || n != weightsBps_.length) revert IFund.InvalidBasket();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = assets_[i];
            if (a == address(0) || a == address(this) || a == usdg || basket[a].listed || !o.hasFeed(a)) {
                revert IFund.InvalidBasket();
            }
            basket[a] = BasketEntry({listed: true, weightBps: weightsBps_[i]});
            sum += weightsBps_[i];
        }
        if (sum != BPS) revert IFund.InvalidBasket();
    }

    /// @dev Anyone can send a dropped asset back to the fund, so a balance worth under `DUST_BPS`
    ///      of the old basket is left behind rather than blocking the change.
    function _checkDropped(
        IFundOracle o,
        mapping(address => BasketEntry) storage basket,
        address[] memory old
    ) private view {
        uint256 dustLimit;
        for (uint256 i; i < old.length; ++i) {
            address a = old[i];
            if (basket[a].listed) continue;
            uint256 bal = IERC20(a).balanceOf(address(this));
            if (bal == 0) continue;
            (bool ok, uint256 p) = o.tryPrice(a);
            if (dustLimit == 0) dustLimit = Math.mulDiv(_basketValue(o, old), DUST_BPS, BPS);
            if (!ok || _value(a, bal, p) > dustLimit) revert IFund.AssetHasBalance(a);
        }
    }

    /// @dev Value of the fund's holdings of `tokens` at oracle prices; a missing price reverts.
    function _basketValue(IFundOracle o, address[] memory tokens) private view returns (uint256 value) {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal != 0) value += _value(tokens[i], bal, o.price(tokens[i]));
        }
    }

    function _value(address asset, uint256 amount, uint256 price) private view returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** IERC20Metadata(asset).decimals());
    }
}
