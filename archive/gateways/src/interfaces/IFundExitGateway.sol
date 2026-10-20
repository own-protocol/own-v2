// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundExitGateway — exit a fund at NAV to USDG, including the basket assets sold on Base
/// @notice Robinhood Chain side of the cash-out. One transaction pulls the caller's fund tokens, redeems
///         them at NAV and, per basket asset, either swaps it to USDG here (an admin-allowed router, the
///         same allowlist funds rebalance through), sends it over CCIP to the Base gateway to be sold
///         there and paid back as USDG on this chain, or pays it out in kind. The local USDG is paid at
///         once; each bridged leg lands later (CCIP plus the Across fill). The caller pays the CCIP fees
///         in native gas; any excess is refunded. Holds nothing between transactions.
interface IFundExitGateway {
    /// @notice What to do with one basket asset.
    /// @param router  Admin-allowed router to swap the asset to USDG here, or zero.
    /// @param data    Router calldata; the router is approved for exactly the redeemed amount and must
    ///                send the USDG back to this contract.
    /// @param bridge  Send the asset to the Base gateway instead (`router` must be zero).
    /// @param minOut  For a bridged asset: minimum USDG the receiver must get on this chain after the
    ///                Base sale and bridge, else the Base gateway holds the asset for the receiver to claim.
    struct Route {
        address router;
        bytes data;
        bool bridge;
        uint256 minOut;
    }

    /// @notice Emitted on an exit.
    /// @param fund     The fund.
    /// @param sender   Holder that redeemed.
    /// @param receiver Receiver.
    /// @param shares   Fund tokens redeemed, fees included.
    /// @param usdgOut  USDG paid out on this chain.
    /// @param bridged  Number of assets sent to the Base gateway.
    event Exited(
        address indexed fund,
        address indexed sender,
        address indexed receiver,
        uint256 shares,
        uint256 usdgOut,
        uint256 bridged
    );

    /// @notice Emitted for each asset sent to the Base gateway.
    /// @param messageId CCIP message id (the Base order is keyed by it).
    /// @param receiver  Receiver of the USDG on this chain, and owner of the order on Base.
    /// @param token     The asset.
    /// @param amount    Amount sent.
    /// @param minOut    Minimum USDG for the receiver.
    /// @param fee       CCIP fee paid, in native gas.
    event Bridged(
        bytes32 indexed messageId,
        address indexed receiver,
        address indexed token,
        uint256 amount,
        uint256 minOut,
        uint256 fee
    );

    /// @notice The fund was not created by the factory.
    error NotFund();

    /// @notice A route's router is not allowed.
    error RouterNotAllowed();

    /// @notice A route both swaps and bridges.
    error InvalidRoute();

    /// @notice `routes` length does not match the basket.
    error LengthMismatch();

    /// @notice A router call failed.
    error SwapFailed();

    /// @notice USDG out is below the caller's minimum.
    error Slippage();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice The native value sent does not cover the CCIP fees.
    /// @param required Fees owed so far.
    /// @param provided Native value sent.
    error InsufficientFee(uint256 required, uint256 provided);

    /// @notice Refunding the excess native value failed.
    error RefundFailed();

    /// @notice Redeem `shares` of `fund` at NAV and cash the basket out to USDG.
    /// @param fund       The fund.
    /// @param shares     Fund tokens redeemed, fees included.
    /// @param routes     One route per basket asset, in {IFund-assets} order.
    /// @param minUsdgOut Minimum USDG paid on this chain in this transaction.
    /// @param receiver   Receiver of the USDG (here and from the bridged legs) and of any asset in kind.
    /// @return usdgOut USDG paid out in this transaction.
    function exit(
        address fund,
        uint256 shares,
        Route[] calldata routes,
        uint256 minUsdgOut,
        address receiver
    ) external payable returns (uint256 usdgOut);

    /// @notice CCIP fee to bridge one asset to the Base gateway.
    /// @param token    The asset.
    /// @param amount   Amount.
    /// @param receiver Receiver.
    /// @param minOut   Minimum USDG for the receiver.
    /// @return fee Fee in native gas.
    function quoteBridge(
        address token,
        uint256 amount,
        address receiver,
        uint256 minOut
    ) external view returns (uint256 fee);

    /// @notice The fund factory.
    /// @return The factory.
    function factory() external view returns (address);

    /// @notice The CCIP Router on this chain.
    /// @return The router.
    function router() external view returns (address);

    /// @notice CCIP selector of Base.
    /// @return The selector.
    function baseSelector() external view returns (uint64);

    /// @notice The Base gateway that sells bridged assets.
    /// @return The gateway.
    function baseGateway() external view returns (address);
}
