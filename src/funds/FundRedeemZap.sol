// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundRedeemZap} from "../interfaces/IFundRedeemZap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FundRedeemZap — redeem to USDG
/// @notice See {IFundRedeemZap}.
contract FundRedeemZap is IFundRedeemZap, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFundRedeemZap
    address public immutable override factory;

    address private immutable _usdg;

    /// @param factory_ The fund factory.
    constructor(
        address factory_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        _usdg = IFundFactory(factory_).usdg();
    }

    /// @inheritdoc IFundRedeemZap
    function redeemToUsdg(
        address fund,
        uint256 shares,
        Route[] calldata routes,
        uint256 minUsdgOut,
        address receiver
    ) external override nonReentrant returns (uint256 usdgOut) {
        IFundFactory fac = IFundFactory(factory);
        if (!fac.isFund(fund)) revert NotFund();
        if (receiver == address(0)) revert ZeroAddress();
        address[] memory assets = IFund(fund).assets();
        if (routes.length != assets.length) revert LengthMismatch();

        IERC20 usdg = IERC20(_usdg);
        IERC20(fund).safeTransferFrom(msg.sender, address(this), shares);
        (uint256[] memory amounts,) = IFund(fund).redeem(shares, address(this), new uint256[](0), 0);
        _swap(fac, fund, address(usdg), assets, amounts, routes);

        // The zap holds nothing between calls, so its whole balance is this redeem's output.
        usdgOut = usdg.balanceOf(address(this));
        if (usdgOut < minUsdgOut) revert Slippage();
        if (usdgOut != 0) usdg.safeTransfer(receiver, usdgOut);
        _returnLeftovers(assets, address(usdg), receiver);

        emit RedeemedToUsdg(fund, msg.sender, receiver, shares, usdgOut);
    }

    function _swap(
        IFundFactory fac,
        address fund,
        address usdg,
        address[] memory assets,
        uint256[] memory amounts,
        Route[] calldata routes
    ) internal {
        for (uint256 i; i < assets.length; ++i) {
            address router = routes[i].router;
            if (router == address(0) || amounts[i] == 0 || assets[i] == usdg) continue;
            if (!fac.isRouter(router) || router == fund || router == usdg) revert RouterNotAllowed();
            IERC20 asset = IERC20(assets[i]);
            asset.forceApprove(router, amounts[i]);
            (bool ok,) = router.call(routes[i].data);
            if (!ok) revert SwapFailed();
            asset.forceApprove(router, 0);
        }
    }

    function _returnLeftovers(address[] memory assets, address usdg, address receiver) internal {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == usdg) continue;
            uint256 left = IERC20(assets[i]).balanceOf(address(this));
            if (left != 0) IERC20(assets[i]).safeTransfer(receiver, left);
        }
    }
}
