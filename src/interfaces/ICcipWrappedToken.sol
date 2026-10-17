// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICcipWrappedToken — a 1:1 wrapper that carries a token we don't issue over Chainlink CCIP
/// @notice Wraps a token Own does not control (Coinbase's cbZEC and cbHYPE on Base) so it can be
///         registered as a CCIP cross-chain token: CCIP self-serve registration needs a token whose
///         `getCCIPAdmin()` we answer for. Deposit the underlying and get the same amount of wrapper;
///         burn the wrapper and get the underlying back. On Base the wrapper is locked in a CCIP
///         LockRelease pool and a matching BurnMint token is minted on the other chain.
///
///         There is no owner and no admin function. `getCCIPAdmin()` is fixed at deploy and only
///         matters for the one-time CCIP registration; after that the registry's own admin role
///         (transferred to the Safe) governs the pool. Every wrapper is backed by one underlying held
///         here: `underlying.balanceOf(this) >= totalSupply()`, more only if someone sends the
///         underlying in directly (it stays here as excess backing).
///
///         The wrapped token is `underlying()` (from OpenZeppelin's ERC20Wrapper).
///
///         The issuer of the underlying can still freeze this contract, which would stop unwrapping.
interface ICcipWrappedToken {
    /// @notice The deposit moved a different amount of the underlying than asked (a fee or rebase).
    error UnexpectedBalanceChange();

    /// @notice Zero address passed where an address is required.
    error ZeroAddress();

    /// @notice The registry admin CCIP's `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin` reads.
    /// @return admin The address that may register this token with CCIP.
    function getCCIPAdmin() external view returns (address admin);

    /// @notice Pulls `value` underlying from the caller and mints `value` wrapper to `account`.
    /// @param account Receiver of the wrapper.
    /// @param value   Amount, in the underlying's decimals (the wrapper uses the same).
    /// @return success Always true.
    function depositFor(address account, uint256 value) external returns (bool success);

    /// @notice Burns `value` wrapper from the caller and sends `value` underlying to `account`.
    /// @param account Receiver of the underlying.
    /// @param value   Amount.
    /// @return success Always true.
    function withdrawTo(address account, uint256 value) external returns (bool success);
}
