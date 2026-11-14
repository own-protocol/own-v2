// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap v4 pool key, ABI-identical to v4-core's `PoolKey` (`Currency` and `IHooks` are
///         address-typed).
/// @param currency0   Lower-sorted token of the pair.
/// @param currency1   Higher-sorted token of the pair.
/// @param fee         Pool LP fee (hundredths of a bip), or the dynamic-fee flag.
/// @param tickSpacing Tick spacing.
/// @param hooks       Hook contract.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice Uniswap v4 swap arguments.
/// @param zeroForOne        True to sell currency0 for currency1.
/// @param amountSpecified   Negative for exact input, positive for exact output.
/// @param sqrtPriceLimitX96 The swap stops at this price.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @title IPoolManagerSwap — the subset of the Uniswap v4 PoolManager used to swap
/// @notice Swaps run inside `unlock`, which calls back `unlockCallback` on the caller. Deltas are
///         paid with `sync` + transfer + `settle` and collected with `take`.
interface IPoolManagerSwap {
    /// @notice Unlock the PoolManager and call `unlockCallback(data)` on the caller.
    /// @param data Passed to the callback.
    /// @return The callback's result.
    function unlock(
        bytes calldata data
    ) external returns (bytes memory);

    /// @notice Swap in a pool.
    /// @param key      Pool key.
    /// @param params   Swap arguments.
    /// @param hookData Data passed to the pool's hook.
    /// @return delta Caller's balance delta: amount0 in the upper 128 bits, amount1 in the lower,
    ///               negative for what the caller owes.
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (int256 delta);

    /// @notice Checkpoint a currency's balance before a payment.
    /// @param currency The currency.
    function sync(
        address currency
    ) external;

    /// @notice Credit the payment made since the last `sync`.
    /// @return paid Amount credited.
    function settle() external payable returns (uint256 paid);

    /// @notice Withdraw a currency owed to the caller.
    /// @param currency The currency.
    /// @param to       Recipient.
    /// @param amount   Amount.
    function take(address currency, address to, uint256 amount) external;
}
