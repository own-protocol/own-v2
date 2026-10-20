// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundRedeemZap — redeem a fund token and swap the basket to USDG in one transaction
/// @notice Pulls the caller's fund tokens, redeems them for the pro-rata basket, swaps each asset
///         the caller routes through an admin-allowed router (the same allowlist funds rebalance
///         through) and pays out the USDG. Assets without a route, and anything a router leaves
///         unspent, are sent to the receiver in kind. Holds nothing between transactions.
interface IFundRedeemZap {
    /// @notice A swap for one basket asset.
    /// @param router Admin-allowed router, or zero to receive the asset in kind.
    /// @param data   Router calldata; the router is approved for exactly the redeemed amount and
    ///               must send the USDG back to this contract.
    struct Route {
        address router;
        bytes data;
    }

    /// @notice Emitted on a redeem to USDG.
    /// @param fund     The fund.
    /// @param sender   Holder that redeemed.
    /// @param receiver Receiver.
    /// @param shares   Fund tokens redeemed, fees included.
    /// @param usdgOut  USDG paid out.
    event RedeemedToUsdg(
        address indexed fund, address indexed sender, address indexed receiver, uint256 shares, uint256 usdgOut
    );

    /// @notice The fund was not created by the factory.
    error NotFund();

    /// @notice A route's router is not allowed.
    error RouterNotAllowed();

    /// @notice `routes` length does not match the basket.
    error LengthMismatch();

    /// @notice A router call failed.
    error SwapFailed();

    /// @notice USDG out is below the caller's minimum.
    error Slippage();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Redeem `shares` of `fund` and swap the basket to USDG.
    /// @param fund       The fund.
    /// @param shares     Fund tokens redeemed, fees included.
    /// @param routes     One route per basket asset, in {IFund-assets} order.
    /// @param minUsdgOut Minimum USDG to the receiver.
    /// @param receiver   Receiver of the USDG and of any asset left in kind.
    /// @return usdgOut USDG paid out.
    function redeemToUsdg(
        address fund,
        uint256 shares,
        Route[] calldata routes,
        uint256 minUsdgOut,
        address receiver
    ) external returns (uint256 usdgOut);

    /// @notice The fund factory.
    /// @return The factory.
    function factory() external view returns (address);
}
