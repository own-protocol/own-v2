// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFeeCalculator — Per-asset mint and redemption fee lookup
/// @notice Returns fee rates (in BPS) for mint and redeem operations.
///         The contract is swappable via ProtocolRegistry to support
///         dynamic fee implementations that factor in utilisation,
///         market conditions, or order size.
interface IFeeCalculator {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when the mint fee for a volatility level is updated.
    /// @param volatilityLevel The volatility tier (1=low, 2=medium, 3=high).
    /// @param feeBps          New mint fee in basis points.
    event MintFeeUpdated(uint8 indexed volatilityLevel, uint256 feeBps);

    /// @notice Emitted when the redeem fee for a volatility level is updated.
    /// @param volatilityLevel The volatility tier (1=low, 2=medium, 3=high).
    /// @param feeBps          New redeem fee in basis points.
    event RedeemFeeUpdated(uint8 indexed volatilityLevel, uint256 feeBps);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The volatility level is invalid (must be 1, 2, or 3).
    error InvalidVolatilityLevel(uint8 level);

    /// @notice The fee exceeds the maximum allowed value.
    error FeeTooHigh(uint256 feeBps, uint256 maxFeeBps);

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @notice Set the mint fee for a volatility level.
    /// @param volatilityLevel Volatility tier (1=low, 2=medium, 3=high).
    /// @param feeBps          Fee in basis points (e.g. 30 = 0.30%).
    function setMintFee(uint8 volatilityLevel, uint256 feeBps) external;

    /// @notice Set the redeem fee for a volatility level.
    /// @param volatilityLevel Volatility tier (1=low, 2=medium, 3=high).
    /// @param feeBps          Fee in basis points (e.g. 30 = 0.30%).
    function setRedeemFee(uint8 volatilityLevel, uint256 feeBps) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the mint fee for a given asset and order amount.
    /// @param asset  Asset ticker (e.g. bytes32("TSLA")).
    /// @param amount Order amount in stablecoin.
    /// @return feeBps Fee in basis points.
    function getMintFee(bytes32 asset, uint256 amount) external view returns (uint256 feeBps);

    /// @notice Return the redeem fee for a given asset and order amount.
    /// @param asset  Asset ticker (e.g. bytes32("TSLA")).
    /// @param amount Order amount in eTokens.
    /// @return feeBps Fee in basis points.
    function getRedeemFee(bytes32 asset, uint256 amount) external view returns (uint256 feeBps);
}
