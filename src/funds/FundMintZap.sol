// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundMintZap} from "../interfaces/IFundMintZap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title FundMintZap — mint from a single token
/// @notice See {IFundMintZap}.
contract FundMintZap is IFundMintZap, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFundMintZap
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

    /// @inheritdoc IFundMintZap
    function zapMint(
        address fund,
        address tokenIn,
        uint256 amountIn,
        Swap[] calldata swaps,
        uint256 navShares,
        uint256 lockOption,
        uint256 minSharesOut,
        address receiver
    ) external override nonReentrant returns (uint256 shares) {
        IFundFactory fac = IFundFactory(factory);
        if (!fac.isFund(fund)) revert NotFund();
        if (receiver == address(0)) revert ZeroAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        for (uint256 i; i < swaps.length; ++i) {
            Swap calldata s = swaps[i];
            if (!fac.isRouter(s.router) || s.router == fund) revert RouterNotAllowed();
            IERC20(s.tokenIn).forceApprove(s.router, s.amountIn);
            (bool ok,) = s.router.call(s.data);
            if (!ok) revert SwapFailed();
            IERC20(s.tokenIn).forceApprove(s.router, 0);
        }

        address[] memory assets = IFund(fund).assets();
        address usdg = _usdg;
        _approveAll(fund, assets, usdg, true);
        shares = IFund(fund).mint(navShares, lockOption, minSharesOut, receiver);
        _approveAll(fund, assets, usdg, false);

        // The zap holds nothing between calls, so every balance left is this caller's.
        _refund(tokenIn);
        _refund(usdg);
        for (uint256 i; i < assets.length; ++i) {
            _refund(assets[i]);
        }
        for (uint256 i; i < swaps.length; ++i) {
            _refund(swaps[i].tokenIn);
        }

        emit ZapMinted(fund, msg.sender, receiver, tokenIn, amountIn, shares);
    }

    function _approveAll(address fund, address[] memory assets, address usdg, bool on) internal {
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).forceApprove(fund, on ? IERC20(assets[i]).balanceOf(address(this)) : 0);
        }
        IERC20(usdg).forceApprove(fund, on ? IERC20(usdg).balanceOf(address(this)) : 0);
    }

    function _refund(
        address token
    ) internal {
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left != 0) IERC20(token).safeTransfer(msg.sender, left);
    }
}
