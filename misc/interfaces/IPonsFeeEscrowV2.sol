// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPonsFeeEscrowV2 — Pons launchpad V2 fee escrow interface
/// @notice Pull-based escrow the Pons V2 DEX pays trading fees into. Fees are credited to a
///         per-recipient balance (native coin and ERC-20s tracked separately) and only the
///         credited recipient can claim its own balance (`msg.sender`-scoped).
/// @dev Reconstructed from the deployed escrow 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e on
///      Robinhood Chain; selectors match its bytecode. Claiming a zero balance reverts.
interface IPonsFeeEscrowV2 {
    /// @notice Credit native coin to `account` (fee deposit path used by the DEX).
    /// @param account Account credited.
    function credit(
        address account
    ) external payable;

    /// @notice Pull `amount` of `token` from the caller and credit it to `account`.
    /// @param account Account credited.
    /// @param token   ERC-20 credited.
    /// @param amount  Amount credited.
    function creditToken(address account, address token, uint256 amount) external;

    /// @notice Claim the caller's full native-coin balance.
    /// @return amount Amount claimed.
    function claim() external returns (uint256 amount);

    /// @notice Claim `amount` of the caller's native-coin balance.
    /// @param amount Amount to claim.
    /// @return claimed Amount claimed.
    function claim(
        uint256 amount
    ) external returns (uint256 claimed);

    /// @notice Claim the caller's full balance of `token`.
    /// @param token ERC-20 to claim.
    /// @return amount Amount claimed.
    function claimToken(
        address token
    ) external returns (uint256 amount);

    /// @notice Claim `amount` of the caller's balance of `token`.
    /// @param token  ERC-20 to claim.
    /// @param amount Amount to claim.
    /// @return claimed Amount claimed.
    function claimToken(address token, uint256 amount) external returns (uint256 claimed);

    /// @notice Native-coin fee balance claimable by `account`.
    /// @param account Account to query.
    /// @return Claimable amount.
    function balanceOf(
        address account
    ) external view returns (uint256);

    /// @notice `token` fee balance claimable by `account`.
    /// @param account Account to query.
    /// @param token   ERC-20 to query.
    /// @return Claimable amount.
    function balanceOfToken(address account, address token) external view returns (uint256);
}
