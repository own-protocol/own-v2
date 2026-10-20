// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICcipWrapRouter} from "../interfaces/ICcipWrapRouter.sol";
import {ICcipWrappedToken} from "../interfaces/ICcipWrappedToken.sol";
import {CcipClient, IAny2EVMMessageReceiver, ICcipRouter} from "../interfaces/external/ICcip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title CcipWrapRouter — wrap-and-send and unwrap-on-arrival for CCIP wrappers
/// @notice See {ICcipWrapRouter}.
contract CcipWrapRouter is ICcipWrapRouter, IAny2EVMMessageReceiver, IERC165, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc ICcipWrapRouter
    address public immutable override router;

    /// @inheritdoc ICcipWrapRouter
    uint64 public immutable override destChainSelector;

    /// @param router_            The CCIP Router on this chain.
    /// @param destChainSelector_ CCIP selector of the chain wrappers are sent to.
    constructor(address router_, uint64 destChainSelector_) {
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
        destChainSelector = destChainSelector_;
    }

    /// @inheritdoc ICcipWrapRouter
    function wrapAndSend(
        address wrapper,
        uint256 amount,
        address receiver
    ) external payable override nonReentrant returns (bytes32 messageId) {
        if (wrapper == address(0) || receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        CcipClient.EVM2AnyMessage memory message = _message(wrapper, amount, receiver);
        uint256 fee = ICcipRouter(router).getFee(destChainSelector, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        IERC20 token = ERC20Wrapper(wrapper).underlying();
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.forceApprove(wrapper, amount);
        ICcipWrappedToken(wrapper).depositFor(address(this), amount);
        token.forceApprove(wrapper, 0);

        IERC20(wrapper).forceApprove(router, amount);
        messageId = ICcipRouter(router).ccipSend{value: fee}(destChainSelector, message);
        IERC20(wrapper).forceApprove(router, 0);

        emit WrappedAndSent(messageId, wrapper, msg.sender, receiver, amount, fee);

        uint256 refund = msg.value - fee;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice Unwraps every delivered wrapper to the recipient named in `message.data`.
    /// @dev Never reverts for a router delivery, so the CCIP transfer always lands: a token that can't be
    ///      unwrapped is forwarded as is. Tokens stay here only if they can't even be transferred, or the
    ///      message names no EVM recipient.
    /// @param message The CCIP message.
    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external override {
        if (msg.sender != router) revert NotRouter();
        address recipient = _recipient(message);
        if (recipient == address(0)) return;
        uint256 n = message.destTokenAmounts.length;
        for (uint256 i; i < n; ++i) {
            address token = message.destTokenAmounts[i].token;
            uint256 amount = message.destTokenAmounts[i].amount;
            if (_tryCall(token, abi.encodeCall(ICcipWrappedToken.withdrawTo, (recipient, amount)))) {
                emit Unwrapped(message.messageId, token, recipient, amount);
            } else if (_tryCall(token, abi.encodeCall(IERC20.transfer, (recipient, amount)))) {
                emit Forwarded(message.messageId, token, recipient, amount);
            }
        }
    }

    /// @inheritdoc ICcipWrapRouter
    function quote(address wrapper, uint256 amount, address receiver) external view override returns (uint256) {
        return ICcipRouter(router).getFee(destChainSelector, _message(wrapper, amount, receiver));
    }

    /// @notice ERC-165: the CCIP OffRamp only calls `ccipReceive` on contracts that report it.
    /// @param interfaceId The interface id.
    /// @return True for IAny2EVMMessageReceiver and IERC165.
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // Low-level so a token without code or with odd return data can't revert the delivery.
    function _tryCall(address token, bytes memory data) internal returns (bool) {
        if (token.code.length == 0) return false;
        (bool ok, bytes memory ret) = token.call(data);
        return ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (uint256)) == 1));
    }

    function _recipient(
        CcipClient.Any2EVMMessage calldata message
    ) internal pure returns (address) {
        if (message.data.length == 32) {
            uint256 word = abi.decode(message.data, (uint256));
            if (word != 0 && word <= type(uint160).max) return address(uint160(word));
        }
        if (message.sender.length == 32) {
            uint256 word = abi.decode(message.sender, (uint256));
            if (word <= type(uint160).max) return address(uint160(word));
        }
        return address(0);
    }

    function _message(
        address wrapper,
        uint256 amount,
        address receiver
    ) internal pure returns (CcipClient.EVM2AnyMessage memory message) {
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: wrapper, amount: amount});
        message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "",
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: CcipClient.encodeExtraArgs(
                CcipClient.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true})
            )
        });
    }
}
