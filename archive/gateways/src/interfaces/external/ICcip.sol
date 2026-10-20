// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title CcipClient — the subset of Chainlink CCIP's `Client` library the wrap router uses
/// @notice Field order and types match `Client.sol` in the npm contracts-ccip 2.0.0 package, so these
///         structs ABI-encode exactly as the CCIP Router expects.
library CcipClient {
    /// @notice Tag for `GenericExtraArgsV2` (bytes4(keccak256("CCIP GenericExtraArgsV2"))).
    bytes4 internal constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

    /// @notice A token amount in a CCIP message.
    /// @param token  Token address on the chain the struct is read on.
    /// @param amount Amount in that token's decimals.
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    /// @notice A message delivered to a receiver on this chain.
    /// @param messageId           CCIP message id.
    /// @param sourceChainSelector CCIP selector of the source chain.
    /// @param sender              abi.encode(sender) on the source chain.
    /// @param data                Payload set by the sender.
    /// @param destTokenAmounts    Tokens delivered with the message, in this chain's representation.
    struct Any2EVMMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        bytes sender;
        bytes data;
        EVMTokenAmount[] destTokenAmounts;
    }

    /// @notice A message sent from this chain.
    /// @param receiver     abi.encode(receiver) on the destination chain.
    /// @param data         Payload for the receiver.
    /// @param tokenAmounts Tokens to send.
    /// @param feeToken     Fee token, or address(0) to pay in native gas.
    /// @param extraArgs    Encoded `GenericExtraArgsV2`.
    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    /// @notice Destination execution settings.
    /// @param gasLimit                 Gas for the receiver's `ccipReceive` (0 for a token-only transfer to an EOA).
    /// @param allowOutOfOrderExecution Whether the message may execute out of order.
    struct GenericExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    /// @notice Encodes `extraArgs` for a message.
    /// @param args The settings.
    /// @return The tagged encoding.
    function encodeExtraArgs(
        GenericExtraArgsV2 memory args
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, args);
    }
}

/// @title ICcipRouter — the CCIP Router calls the wrap router makes
interface ICcipRouter {
    /// @notice Whether the router can send to a chain.
    /// @param destChainSelector CCIP selector of the destination chain.
    /// @return supported True when a lane exists.
    function isChainSupported(
        uint64 destChainSelector
    ) external view returns (bool supported);

    /// @notice The fee for a message.
    /// @param destChainSelector CCIP selector of the destination chain.
    /// @param message           The message.
    /// @return fee Fee in `message.feeToken` (native gas when address(0)).
    function getFee(
        uint64 destChainSelector,
        CcipClient.EVM2AnyMessage memory message
    ) external view returns (uint256 fee);

    /// @notice Sends a message; tokens are pulled from the caller.
    /// @param destChainSelector CCIP selector of the destination chain.
    /// @param message           The message.
    /// @return messageId The CCIP message id.
    function ccipSend(
        uint64 destChainSelector,
        CcipClient.EVM2AnyMessage calldata message
    ) external payable returns (bytes32 messageId);
}

/// @title IAny2EVMMessageReceiver — a contract the CCIP Router delivers messages to
interface IAny2EVMMessageReceiver {
    /// @notice Called by the Router to deliver a message. A revert fails the whole delivery, tokens included.
    /// @param message The message.
    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external;
}
