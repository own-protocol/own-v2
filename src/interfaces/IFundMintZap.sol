// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundMintZap — mint a fund token from a single token in one transaction
/// @notice A fund mints only against a proportional slice of everything it holds (see
///         {IFund-mint}), so no oracle values the deposit and minters cannot pick what the fund
///         buys. This zap builds that slice from one token: it pulls the caller's token, runs the
///         caller's swaps through admin-allowed routers (the same allowlist funds rebalance
///         through), mints, and returns whatever is left to the caller. The minter pays the swap
///         slippage, not the fund's holders. Holds nothing between transactions.
interface IFundMintZap {
    /// @notice One swap.
    /// @param router   Admin-allowed router called with `data`.
    /// @param tokenIn  Token the router is approved to take.
    /// @param amountIn Amount the router is approved for.
    /// @param data     Router calldata; the router must send its output back to this contract.
    struct Swap {
        address router;
        address tokenIn;
        uint256 amountIn;
        bytes data;
    }

    /// @notice Emitted on a zap mint.
    /// @param fund     The fund.
    /// @param sender   Payer.
    /// @param receiver Receiver of the fund tokens (or owner of the lock).
    /// @param tokenIn  Token paid.
    /// @param amountIn Amount paid.
    /// @param shares   Fund tokens minted to the receiver.
    event ZapMinted(
        address indexed fund,
        address indexed sender,
        address indexed receiver,
        address tokenIn,
        uint256 amountIn,
        uint256 shares
    );

    /// @notice The fund was not created by the factory.
    error NotFund();

    /// @notice A swap's router is not allowed.
    error RouterNotAllowed();

    /// @notice A router call failed.
    error SwapFailed();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Pay `amountIn` of `tokenIn`, swap it into the slice a mint of `navShares` needs and
    ///         mint. See {IFund-previewMint} for the slice.
    /// @param fund         The fund.
    /// @param tokenIn      Token paid.
    /// @param amountIn     Amount paid.
    /// @param swaps        Swaps run in order before the mint.
    /// @param navShares    Size of the slice, in fund tokens at NAV.
    /// @param lockOption   0 for no lock, otherwise 1 + index into {IFund-lockOptions}.
    /// @param minSharesOut Minimum fund tokens to the receiver, after the fee.
    /// @param receiver     Receiver of the fund tokens (or owner of the lock).
    /// @return shares Fund tokens minted to the receiver.
    function zapMint(
        address fund,
        address tokenIn,
        uint256 amountIn,
        Swap[] calldata swaps,
        uint256 navShares,
        uint256 lockOption,
        uint256 minSharesOut,
        address receiver
    ) external returns (uint256 shares);

    /// @notice The fund factory.
    /// @return The factory.
    function factory() external view returns (address);
}
