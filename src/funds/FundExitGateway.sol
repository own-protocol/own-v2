// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundExitGateway} from "../interfaces/IFundExitGateway.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {CcipClient, ICcipRouter} from "../interfaces/external/ICcip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title FundExitGateway — exit a fund at NAV to USDG, selling Base-sourced assets on Base
/// @notice See {IFundExitGateway}.
contract FundExitGateway is IFundExitGateway, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Gas for the Base gateway's `ccipReceive` (unwrap plus one order record).
    uint256 public constant DEST_GAS_LIMIT = 300_000;

    /// @inheritdoc IFundExitGateway
    address public immutable override factory;
    /// @inheritdoc IFundExitGateway
    address public immutable override router;
    /// @inheritdoc IFundExitGateway
    uint64 public immutable override baseSelector;
    /// @inheritdoc IFundExitGateway
    address public immutable override baseGateway;

    address private immutable _usdg;

    /// @param factory_      The fund factory.
    /// @param router_       The CCIP Router on this chain.
    /// @param baseSelector_ CCIP selector of Base.
    /// @param baseGateway_  The Base gateway.
    constructor(address factory_, address router_, uint64 baseSelector_, address baseGateway_) {
        if (factory_ == address(0) || router_ == address(0) || baseGateway_ == address(0) || baseSelector_ == 0) {
            revert ZeroAddress();
        }
        factory = factory_;
        router = router_;
        baseSelector = baseSelector_;
        baseGateway = baseGateway_;
        _usdg = IFundFactory(factory_).usdg();
    }

    /// @inheritdoc IFundExitGateway
    function exit(
        address fund,
        uint256 shares,
        Route[] calldata routes,
        uint256 minUsdgOut,
        address receiver
    ) external payable override nonReentrant returns (uint256 usdgOut) {
        IFundFactory fac = IFundFactory(factory);
        if (!fac.isFund(fund)) revert NotFund();
        if (receiver == address(0)) revert ZeroAddress();
        address[] memory assets = IFund(fund).assets();
        if (routes.length != assets.length) revert LengthMismatch();

        IERC20(fund).safeTransferFrom(msg.sender, address(this), shares);
        (uint256[] memory amounts,) = IFund(fund).redeem(shares, address(this), new uint256[](0), 0);

        (uint256 feePaid, uint256 bridged) = _route(fac, fund, assets, amounts, routes, receiver);
        usdgOut = _payOut(assets, minUsdgOut, receiver);

        emit Exited(fund, msg.sender, receiver, shares, usdgOut, bridged);

        uint256 refund = msg.value - feePaid;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IFundExitGateway
    function quoteBridge(
        address token,
        uint256 amount,
        address receiver,
        uint256 minOut
    ) external view override returns (uint256) {
        return ICcipRouter(router).getFee(baseSelector, _message(token, amount, receiver, minOut));
    }

    function _route(
        IFundFactory fac,
        address fund,
        address[] memory assets,
        uint256[] memory amounts,
        Route[] calldata routes,
        address receiver
    ) internal returns (uint256 feePaid, uint256 bridged) {
        address usdg = _usdg;
        for (uint256 i; i < assets.length; ++i) {
            Route calldata r = routes[i];
            if (amounts[i] == 0 || assets[i] == usdg) continue;
            if (r.bridge) {
                if (r.router != address(0)) revert InvalidRoute();
                feePaid += _bridge(assets[i], amounts[i], receiver, r.minOut, msg.value - feePaid);
                ++bridged;
            } else if (r.router != address(0)) {
                _swap(fac, fund, usdg, assets[i], amounts[i], r);
            }
        }
    }

    // The gateway holds nothing between calls, so its whole balance is this exit's output.
    function _payOut(
        address[] memory assets,
        uint256 minUsdgOut,
        address receiver
    ) internal returns (uint256 usdgOut) {
        address usdg = _usdg;
        usdgOut = IERC20(usdg).balanceOf(address(this));
        if (usdgOut < minUsdgOut) revert Slippage();
        if (usdgOut != 0) IERC20(usdg).safeTransfer(receiver, usdgOut);
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == usdg) continue;
            uint256 left = IERC20(assets[i]).balanceOf(address(this));
            if (left != 0) IERC20(assets[i]).safeTransfer(receiver, left);
        }
    }

    function _swap(
        IFundFactory fac,
        address fund,
        address usdg,
        address asset,
        uint256 amount,
        Route calldata r
    ) internal {
        address target = r.router;
        if (!fac.isRouter(target) || target == fund || target == usdg) revert RouterNotAllowed();
        IERC20(asset).forceApprove(target, amount);
        (bool ok,) = target.call(r.data);
        if (!ok) revert SwapFailed();
        IERC20(asset).forceApprove(target, 0);
    }

    function _bridge(
        address token,
        uint256 amount,
        address receiver,
        uint256 minOut,
        uint256 available
    ) internal returns (uint256 fee) {
        CcipClient.EVM2AnyMessage memory message = _message(token, amount, receiver, minOut);
        ICcipRouter ccip = ICcipRouter(router);
        fee = ccip.getFee(baseSelector, message);
        if (fee > available) revert InsufficientFee(fee, available);
        IERC20(token).forceApprove(address(ccip), amount);
        bytes32 messageId = ccip.ccipSend{value: fee}(baseSelector, message);
        IERC20(token).forceApprove(address(ccip), 0);
        emit Bridged(messageId, receiver, token, amount, minOut, fee);
    }

    function _message(
        address token,
        uint256 amount,
        address receiver,
        uint256 minOut
    ) internal view returns (CcipClient.EVM2AnyMessage memory message) {
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: token, amount: amount});
        message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(baseGateway),
            data: abi.encode(receiver, minOut),
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: CcipClient.encodeExtraArgs(
                CcipClient.GenericExtraArgsV2({gasLimit: DEST_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });
    }
}
