// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap v4 pool key, ABI-identical to v4-core's `PoolKey` (`Currency` and `IHooks` are
///         address-typed). The pool id is `keccak256(abi.encode(key))`.
/// @param currency0   Lower-sorted token of the pair.
/// @param currency1   Higher-sorted token of the pair.
/// @param fee         Pool LP fee (hundredths of a bip), or the dynamic-fee flag.
/// @param tickSpacing Tick spacing; range bounds must be multiples of it.
/// @param hooks       Hook contract; for a Fables pool this is the pool's FablesLedger.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title IFablesLedger — the subset of the Fables ledger hook used by Own
/// @notice Each Fables pool's hook is a ledger that holds LP liquidity, issues ERC-6909 share
///         receipts per range (one share per unit of liquidity), and stakes shares into the pool's
///         gauge. Staked shares give up swap fees and earn FABLES emissions through the
///         {IFablesEmissionStream}.
interface IFablesLedger {
    /// @notice Add `liquidity` to a range. Principal is pulled from the caller by `transferFrom`.
    /// @param key        Pool key.
    /// @param tickLower  Lower tick of the range.
    /// @param tickUpper  Upper tick of the range.
    /// @param liquidity  Liquidity to add (shares minted 1:1).
    /// @param amount0Max Most currency0 the caller will pay.
    /// @param amount1Max Most currency1 the caller will pay.
    /// @param deadline   Latest block timestamp for the call.
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable;

    /// @notice Burn shares and pay the principal to `to`. Never pausable; unstakes as needed.
    /// @param key        Pool key.
    /// @param tickLower  Lower tick of the range.
    /// @param tickUpper  Upper tick of the range.
    /// @param liquidity  Liquidity (shares) to remove.
    /// @param to         Recipient of the principal.
    /// @param amount0Min Least currency0 the caller accepts.
    /// @param amount1Min Least currency1 the caller accepts.
    /// @param deadline   Latest block timestamp for the call.
    function withdraw(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external;

    /// @notice Pay the caller's accrued swap fees for a range to `to`.
    /// @param key       Pool key.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param to        Fee recipient.
    /// @param maxFeeBps Highest claim fee the caller accepts (BPS).
    function claimFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, address to, uint16 maxFeeBps) external;

    /// @notice Stake the caller's unstaked shares of a range into the pool's gauge.
    /// @param key            Pool key.
    /// @param tickLower      Lower tick of the range.
    /// @param tickUpper      Upper tick of the range.
    /// @param shares         Shares to stake.
    /// @param minGaugeWeight Least gauge weight the caller accepts (0 = any).
    function stake(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 shares,
        uint256 minGaugeWeight
    ) external;

    /// @notice Unstake the caller's staked shares of a range. Never pausable.
    /// @param key       Pool key.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param shares    Shares to unstake.
    function unstake(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares) external;
}

/// @title IFablesEmissionStream — the subset of the Fables emission stream used by Own
/// @notice Pays FABLES emissions against cumulative Merkle roots. A LIQUID claim (kind 0) for an
///         account `id = uint160(account)` mints to that account; anyone may call it.
interface IFablesEmissionStream {
    /// @notice Pay what `(kind, id)` has earned since its last claim.
    /// @param kind       0 = LIQUID (paid to the account), 1 = LOCK (deposited into a lock).
    /// @param id         The account as uint160 for LIQUID, the lock id for LOCK.
    /// @param cumulative Total ever earned by the key, per the root.
    /// @param proof      Merkle proof of the leaf.
    /// @return amount FABLES paid.
    function claim(
        uint8 kind,
        uint256 id,
        uint256 cumulative,
        bytes32[] calldata proof
    ) external returns (uint256 amount);

    /// @notice The FABLES token.
    /// @return The token address.
    function ff() external view returns (address);
}

/// @title IExtsload — Uniswap v4 PoolManager raw storage reads
interface IExtsload {
    /// @notice Read one storage slot of the PoolManager.
    /// @param slot The slot.
    /// @return value The slot's value.
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value);
}
