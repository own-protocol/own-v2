// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAcrossSpokePool — the Across V3 SpokePool deposit the Base gateway makes
interface IAcrossSpokePool {
    /// @notice Deposits `inputAmount` of `inputToken` (pulled from the caller) for a relayer to fill
    ///         `outputAmount` of `outputToken` to `recipient` on `destinationChainId`.
    /// @param depositor           Credited with the deposit: may speed it up, and gets the refund on this
    ///                            chain if no relayer fills it by `fillDeadline`.
    /// @param recipient           Receiver on the destination chain.
    /// @param inputToken          Token deposited here.
    /// @param outputToken         Token paid on the destination chain.
    /// @param inputAmount         Amount deposited.
    /// @param outputAmount        Amount the relayer pays; the difference is the relayer and LP fee.
    /// @param destinationChainId  EVM chain id of the destination.
    /// @param exclusiveRelayer    Relayer with an exclusive fill window, or zero.
    /// @param quoteTimestamp      Timestamp of the fee quote (must be recent).
    /// @param fillDeadline        Latest fill time on the destination.
    /// @param exclusivityDeadline End of the exclusive window (zero with no exclusive relayer).
    /// @param message             Payload for a contract recipient (empty for a plain transfer).
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    /// @notice Longest allowed `fillDeadline - block.timestamp`.
    /// @return The buffer in seconds.
    function fillDeadlineBuffer() external view returns (uint32);
}
