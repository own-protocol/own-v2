// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ILiquidityVault — one DEX liquidity position held for an EUSDLiquidityManager position
/// @notice A vault holds one owner's liquidity in one asset/eUSD pool, plus idle asset and eUSD.
///         It is created by an {IEUSDLiquidityManager} as a beacon proxy, one per (pool, owner), so
///         every position's tokens sit in their own contract. Each DEX has its own implementation
///         (an "adapter", e.g. FablesAdapter); all vaults of a DEX share one upgradeable beacon.
///
///         Only the manager moves principal: adding and removing liquidity, staking, swapping
///         between the asset and eUSD, and token transfers out. The owner can collect what the
///         position earns on the DEX (swap fees, emissions), sweep tokens that are neither the
///         asset nor eUSD, and name a delegate that may manage the position through the manager.
///
///         The manager values a vault at the oracle price: {holdings} returns the amounts the
///         liquidity would hold if the pool traded at that price, plus idle balances. The pool's own
///         price is read only for {poolPrice}, which the manager compares with the oracle.
interface ILiquidityVault {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when liquidity is added.
    /// @param tickLower  Lower tick of the range.
    /// @param tickUpper  Upper tick of the range.
    /// @param liquidity  Liquidity added.
    /// @param assetUsed  Asset paid into the pool (asset units).
    /// @param eusdUsed   eUSD paid into the pool (18 decimals).
    event LiquidityAdded(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 assetUsed, uint256 eusdUsed);

    /// @notice Emitted when liquidity is removed into the vault.
    /// @param liquidity Liquidity removed.
    /// @param assetOut  Asset received (asset units).
    /// @param eusdOut   eUSD received (18 decimals).
    event LiquidityRemoved(uint128 liquidity, uint256 assetOut, uint256 eusdOut);

    /// @notice Emitted when the vault's liquidity is staked or unstaked.
    /// @param staked Whether the liquidity is now staked.
    event StakedSet(bool staked);

    /// @notice Emitted when the manager moves a token out of the vault.
    /// @param token  Token moved.
    /// @param to     Recipient.
    /// @param amount Amount moved.
    event TokenTransferred(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the owner sweeps a token that is neither the asset nor eUSD.
    /// @param token  Token swept.
    /// @param amount Amount sent to the owner.
    event Swept(address indexed token, uint256 amount);

    /// @notice Emitted when the owner sets or clears the delegate.
    /// @param delegate The new delegate (zero when cleared).
    event DelegateSet(address indexed delegate);

    /// @notice Emitted when the vault swaps one token for another.
    /// @param tokenIn   Token sold.
    /// @param tokenOut  Token bought.
    /// @param amountIn  Amount sold (tokenIn units).
    /// @param amountOut Amount bought (tokenOut units).
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Thrown when a manager-only function is called by another address.
    error OnlyManager();

    /// @notice Thrown when an owner-only function is called by another address.
    error OnlyOwner();

    /// @notice Thrown when the pool data does not describe a supported asset/eUSD pool.
    error InvalidPool();

    /// @notice Thrown when a range is malformed (lower ≥ upper, out of bounds or off the spacing).
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    error InvalidRange(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when liquidity is added to a range other than the vault's open range.
    /// @param tickLower Open range's lower tick.
    /// @param tickUpper Open range's upper tick.
    error RangeMismatch(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when the amounts given fund no liquidity at the pool price.
    error ZeroLiquidity();

    /// @notice Thrown when more liquidity is removed than the vault holds.
    /// @param requested Liquidity requested.
    /// @param available Liquidity held.
    error InsufficientLiquidity(uint128 requested, uint128 available);

    /// @notice Thrown when the owner tries to sweep the asset or eUSD.
    /// @param token The token.
    error ProtectedToken(address token);

    /// @notice Thrown when the pool has not been initialized on the DEX.
    error PoolNotInitialized();

    /// @notice Thrown when a swap returns less than the minimum.
    /// @param amountOut Amount received.
    /// @param minOut    Least amount accepted.
    error InsufficientOutput(uint256 amountOut, uint256 minOut);

    /// @notice Thrown when a swap route is empty of hops it needs, too long, leaves the DEX's
    ///         pools, or does not lead from the token sold to the token bought.
    error InvalidRoute();

    /// @notice Thrown when the DEX adapter does not support swaps.
    error SwapUnsupported();

    // ──────────────────────────────────────────────────────────
    //  Manager
    // ──────────────────────────────────────────────────────────

    /// @notice Initialize a new vault. The caller becomes its manager.
    /// @param owner    Position owner.
    /// @param asset    The pool's non-eUSD token.
    /// @param eusd     The eUSD token.
    /// @param poolData DEX-specific pool description (Fables: an abi-encoded `PoolKey`; Aero: the
    ///                 abi-encoded pool address).
    function initialize(address owner, address asset, address eusd, bytes calldata poolData) external;

    /// @notice Add liquidity to the vault's range from its own balances. Pays at most `assetMax`
    ///         asset and `eusdMax` eUSD (each capped at the vault's balance); the rest stays in the
    ///         vault. Stakes the new liquidity when the vault is staked. Opens the range when the
    ///         vault holds no liquidity.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param assetMax  Most asset to pay (asset units).
    /// @param eusdMax   Most eUSD to pay (18 decimals).
    /// @return liquidity Liquidity added.
    /// @return assetUsed Asset paid (asset units).
    /// @return eusdUsed  eUSD paid (18 decimals).
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 assetMax,
        uint256 eusdMax
    ) external returns (uint128 liquidity, uint256 assetUsed, uint256 eusdUsed);

    /// @notice Remove liquidity into the vault. Works whatever the DEX's pause state.
    /// @param liquidity Liquidity to remove.
    /// @param assetMin  Least asset to receive (asset units).
    /// @param eusdMin   Least eUSD to receive (18 decimals).
    /// @return assetOut Asset received (asset units).
    /// @return eusdOut  eUSD received (18 decimals).
    function removeLiquidity(
        uint128 liquidity,
        uint256 assetMin,
        uint256 eusdMin
    ) external returns (uint256 assetOut, uint256 eusdOut);

    /// @notice Stake or unstake all of the vault's liquidity, now and for liquidity added later.
    ///         New vaults start unstaked.
    /// @param staked Whether the liquidity should be staked.
    function setStaked(
        bool staked
    ) external;

    /// @notice Send a token held by the vault.
    /// @param token  Token.
    /// @param to     Recipient.
    /// @param amount Amount.
    function transferToken(address token, address to, uint256 amount) external;

    /// @notice Swap the vault's asset for eUSD or eUSD for asset, exact input, on the DEX. The
    ///         bought tokens stay in the vault.
    /// @param assetToEusd Whether asset is sold for eUSD (else eUSD for asset).
    /// @param amountIn    Amount sold (token units).
    /// @param minOut      Least amount bought.
    /// @param route       DEX-specific route; empty swaps in the vault's own pool.
    /// @return amountOut Amount bought.
    function swap(
        bool assetToEusd,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata route
    ) external returns (uint256 amountOut);

    // ──────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────

    /// @notice Send a token that is neither the asset nor eUSD (e.g. emissions) to the owner.
    /// @param token Token.
    function sweep(
        address token
    ) external;

    /// @notice Name the address that may manage this position through the manager besides the
    ///         owner, or clear it with zero. A delegate can never move tokens out of the vault.
    /// @param delegate The delegate.
    function setDelegate(
        address delegate
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Check that `poolData` describes a supported, initialized asset/eUSD pool.
    /// @dev Called on the implementation by the manager when a pool is added. Reverts with
    ///      {InvalidPool} or {PoolNotInitialized} otherwise.
    /// @param asset    The pool's non-eUSD token.
    /// @param eusd     The eUSD token.
    /// @param poolData DEX-specific pool description.
    function checkPool(address asset, address eusd, bytes calldata poolData) external view;

    /// @notice The manager that created the vault.
    /// @return The manager address.
    function manager() external view returns (address);

    /// @notice The position owner.
    /// @return The owner address.
    function owner() external view returns (address);

    /// @notice The pool's non-eUSD token.
    /// @return The asset address.
    function asset() external view returns (address);

    /// @notice The position's delegate (zero when none).
    /// @return The delegate address.
    function delegate() external view returns (address);

    /// @notice The vault's open range and its liquidity. All zero when the vault holds no liquidity.
    /// @return tickLower Lower tick.
    /// @return tickUpper Upper tick.
    /// @return liquidity Liquidity held.
    function range() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @notice Whether the vault's liquidity is staked.
    /// @return Staked flag.
    function staked() external view returns (bool);

    /// @notice Asset and eUSD the vault holds when its liquidity is valued at `price`: the amounts
    ///         the range would hold if the pool traded at `price`, plus idle balances.
    /// @param price Asset price in eUSD per whole asset (18 decimals).
    /// @return assetAmount Asset (asset units).
    /// @return eusdAmount  eUSD (18 decimals).
    function holdings(
        uint256 price
    ) external view returns (uint256 assetAmount, uint256 eusdAmount);

    /// @notice The pool's current price of the asset in eUSD per whole asset.
    /// @return Price (18 decimals).
    function poolPrice() external view returns (uint256);
}
