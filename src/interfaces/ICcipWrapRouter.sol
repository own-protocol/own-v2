// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICcipWrapRouter — wrap and bridge in one transaction, and unwrap on arrival
/// @notice Lives on the chain where the underlying is (Base). `wrapAndSend` pulls the caller's
///         underlying (cbZEC, cbHYPE), wraps it 1:1 into its {ICcipWrappedToken} (rZEC, rHYPE) and
///         sends the wrapper over CCIP to `receiver` on the destination chain (Robinhood Chain), paying
///         the CCIP fee in ETH. The message carries tokens only, so it needs no gas on arrival.
///
///         Inbound, a CCIP message from the other chain can name this contract as receiver with
///         `abi.encode(recipient)` as data: every wrapper delivered is unwrapped to `recipient`. If an
///         unwrap fails (the issuer froze the recipient, say), the wrapper itself goes to `recipient`
///         instead, so a delivery never fails on our side. Without valid data the recipient is the
///         message's sender address.
///
///         Holds nothing between transactions and has no owner.
interface ICcipWrapRouter {
    /// @notice Emitted when a wrap-and-send leaves.
    /// @param messageId CCIP message id.
    /// @param wrapper   The wrapper sent.
    /// @param sender    Payer of the underlying and the fee.
    /// @param receiver  Receiver on the destination chain.
    /// @param amount    Amount wrapped and sent.
    /// @param fee       CCIP fee paid, in wei.
    event WrappedAndSent(
        bytes32 indexed messageId,
        address indexed wrapper,
        address indexed sender,
        address receiver,
        uint256 amount,
        uint256 fee
    );

    /// @notice Emitted when an inbound wrapper is unwrapped to its recipient.
    /// @param messageId CCIP message id.
    /// @param wrapper   The wrapper received.
    /// @param recipient Receiver of the underlying.
    /// @param amount    Amount.
    event Unwrapped(bytes32 indexed messageId, address indexed wrapper, address indexed recipient, uint256 amount);

    /// @notice Emitted when an inbound token could not be unwrapped and was forwarded as is.
    /// @param messageId CCIP message id.
    /// @param token     The token received.
    /// @param recipient Receiver of the token.
    /// @param amount    Amount.
    event Forwarded(bytes32 indexed messageId, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Zero address passed where an address is required.
    error ZeroAddress();

    /// @notice Zero amount.
    error ZeroAmount();

    /// @notice `ccipReceive` was not called by the CCIP Router.
    error NotRouter();

    /// @notice `msg.value` is below the CCIP fee.
    /// @param required The fee.
    /// @param paid     `msg.value`.
    error InsufficientFee(uint256 required, uint256 paid);

    /// @notice Returning unused `msg.value` failed.
    error RefundFailed();

    /// @notice The CCIP Router on this chain.
    /// @return The router.
    function router() external view returns (address);

    /// @notice CCIP selector of the destination chain.
    /// @return The selector.
    function destChainSelector() external view returns (uint64);

    /// @notice The CCIP fee in wei for a `wrapAndSend`.
    /// @param wrapper  The wrapper to send.
    /// @param amount   Amount.
    /// @param receiver Receiver on the destination chain.
    /// @return fee Fee in wei.
    function quote(address wrapper, uint256 amount, address receiver) external view returns (uint256 fee);

    /// @notice Wraps the caller's underlying and sends the wrapper to `receiver` on the destination chain.
    /// @dev Pulls `amount` of `wrapper.underlying()` from the caller. Unused `msg.value` is refunded.
    /// @param wrapper  The wrapper ({ICcipWrappedToken}) registered with CCIP.
    /// @param amount   Amount of underlying to wrap and send.
    /// @param receiver Receiver on the destination chain.
    /// @return messageId CCIP message id.
    function wrapAndSend(
        address wrapper,
        uint256 amount,
        address receiver
    ) external payable returns (bytes32 messageId);
}
