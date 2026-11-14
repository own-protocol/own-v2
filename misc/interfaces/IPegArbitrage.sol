// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "./IPoolManagerSwap.sol";

/// @title IPegArbitrage — keeper tool that moves an eUSD pool to a target price through the PSM
/// @notice One call swaps in an eUSD/stablecoin v4 pool up to a price limit and settles the other
///         side against the PSM in the same transaction, so it needs no working capital when eUSD
///         is off $1 by more than the pool fee. eUSD above $1: sell eUSD into the pool, mint that
///         eUSD from the PSM with the stablecoin received. eUSD below $1: buy eUSD from the pool,
///         redeem it at the PSM, and pay the pool from the stablecoin received. A small stablecoin
///         float covers corrections smaller than the pool fee.
/// @dev Only OPERATOR (the keeper) can trade, bounded per call by `minProfit`; only ADMIN can take
///      funds out, and only to the registry treasury. Not upgradeable.
interface IPegArbitrage {
    /// @notice Emitted after each trade.
    /// @param asset    The pool's stablecoin.
    /// @param sellEusd True when eUSD was sold into the pool (eUSD above $1).
    /// @param eusd     eUSD sold into or bought from the pool (18 decimals).
    /// @param assetAmt Stablecoin received from or paid to the pool (asset units).
    /// @param profit   Change in the contract's stablecoin balance (asset units, may be negative).
    event Arbitraged(address indexed asset, bool sellEusd, uint256 eusd, uint256 assetAmt, int256 profit);

    /// @notice Emitted when the admin sends tokens to the treasury.
    /// @param token  The token.
    /// @param to     Treasury at the time of the call.
    /// @param amount Amount sent.
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();
    /// @notice The pool does not pair eUSD with another token.
    error NotAnEusdPool();
    /// @notice The callback did not come from the PoolManager during this contract's own trade.
    error UnauthorizedCallback();
    /// @notice The swap did not move any tokens.
    error NothingSwapped();
    /// @notice The trade lost more than the caller allowed.
    /// @param profit    Realised profit (asset units).
    /// @param minProfit The caller's floor (asset units).
    error ProfitTooLow(int256 profit, int256 minProfit);

    /// @notice Swap in `key`'s pool up to `sqrtPriceLimitX96` and settle through the PSM (OPERATOR).
    /// @param key               eUSD/stablecoin pool key (the stablecoin must be listed in the PSM).
    /// @param sellEusd          True to sell eUSD (eUSD above $1), false to buy it.
    /// @param sqrtPriceLimitX96 Target pool price; the swap stops there.
    /// @param maxIn             Most of the input token to swap (eUSD when selling, else the
    ///                          stablecoin); size it to the PSM's ceiling room or debt.
    /// @param minProfit         Least change in the contract's stablecoin balance (may be negative).
    /// @return profit Change in the contract's stablecoin balance (asset units).
    function arbitrage(
        PoolKey calldata key,
        bool sellEusd,
        uint160 sqrtPriceLimitX96,
        uint256 maxIn,
        int256 minProfit
    ) external returns (int256 profit);

    /// @notice Send `amount` of `token` to the registry treasury (ADMIN).
    /// @param token  The token.
    /// @param amount Amount.
    function withdraw(address token, uint256 amount) external;

    /// @notice Uniswap v4 unlock callback; only the PoolManager, during {arbitrage}.
    /// @param data Encoded trade.
    /// @return Empty.
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory);
}
