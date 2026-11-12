// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILiquidityVault} from "../../interfaces/ILiquidityVault.sol";
import {
    IExtsload,
    IFablesEmissionStream,
    IFablesLedger,
    IFablesPoolRegistry,
    IPoolManagerSwap,
    PoolKey,
    SwapParams
} from "../../interfaces/external/IFables.sol";
import {LiquidityMath} from "../../libraries/LiquidityMath.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FablesAdapter — liquidity vault for Fables pools
/// @notice See {ILiquidityVault}. Holds one owner's range in one Fables asset/eUSD pool (a
///         Uniswap v4 pool whose hook is a FablesLedger). Liquidity goes through the ledger, which
///         issues shares 1:1 with liquidity and stakes them into the pool's gauge. Staked shares
///         earn FABLES from the emission stream; unstaked shares earn swap fees, claimable by the
///         owner. FABLES are claimed to the owner, or harvested by the owner or the delegate into
///         eUSD, the asset or FABLES, kept in the vault or sent to the owner as the owner sets.
///         Swaps run on the PoolManager through the vault's hook pools or pools in the Fables registry.
///         The owner or the delegate may set a tight range: a share of each newly opened range goes
///         into a narrow range centred on the pool price, held beside the main range and removed in
///         the same proportion.
/// @dev Each vault is a BeaconProxy; this is the implementation behind the Fables beacon. The
///      PoolManager and emission stream are DEX-wide, so they are immutables of the
///      implementation; the pool key is per vault. Native-currency pools are not supported.
///      Tokens must not charge transfer fees.
contract FablesAdapter is ILiquidityVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice What harvested FABLES become.
    enum HarvestOut {
        Eusd,
        Asset,
        Fables
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when the owner sets what harvests produce and where they go.
    /// @param out     What harvested FABLES become.
    /// @param toOwner Whether the output is sent to the owner (else kept in the vault).
    event HarvestConfigSet(HarvestOut out, bool toOwner);

    /// @notice Emitted on a harvest.
    /// @param caller    The owner or the delegate.
    /// @param fablesIn  FABLES harvested (claimed now or already in the vault).
    /// @param tokenOut  Token produced (FABLES when not swapped).
    /// @param amountOut Amount produced (tokenOut units).
    /// @param toOwner   Whether the output was sent to the owner (else kept in the vault).
    event EmissionsHarvested(
        address indexed caller, uint256 fablesIn, address indexed tokenOut, uint256 amountOut, bool toOwner
    );

    /// @notice Emitted when the owner or the delegate sets the tight range.
    /// @param caller    The owner or the delegate.
    /// @param shareBps  Share of a newly opened range placed in the tight range (BPS; 0 = off).
    /// @param halfWidth Half-width of the tight range in ticks.
    event TightRangeSet(address indexed caller, uint16 shareBps, int24 halfWidth);

    /// @notice Emitted when the tight range is opened beside a newly opened main range.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param liquidity Liquidity added.
    /// @param assetUsed Asset paid into the pool (asset units).
    /// @param eusdUsed  eUSD paid into the pool (18 decimals).
    event TightRangeOpened(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 assetUsed, uint256 eusdUsed);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Thrown when a function for the owner or the delegate is called by another address.
    error OnlyOwnerOrDelegate();

    /// @notice Thrown when the PoolManager callback is called by another address.
    error OnlyPoolManager();

    /// @notice Thrown when a harvest finds no FABLES in the vault.
    error NothingToHarvest();

    /// @notice Thrown when a tight range share is above {MAX_TIGHT_SHARE_BPS} or its half-width is
    ///         not a positive multiple of the tick spacing.
    /// @param shareBps  Share given (BPS).
    /// @param halfWidth Half-width given (ticks).
    error InvalidTightRange(uint16 shareBps, int24 halfWidth);

    // ──────────────────────────────────────────────────────────
    //  Constants & immutables
    // ──────────────────────────────────────────────────────────

    /// @dev Uniswap v4 PoolManager storage slot of the `pools` mapping.
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));

    /// @dev Emission-stream claim kind paid liquid to an account.
    uint8 private constant KIND_LIQUID = 0;

    /// @dev Most pools a swap route may cross.
    uint256 private constant MAX_HOPS = 3;

    /// @dev Basis-point denominator.
    uint256 private constant BPS = 10_000;

    /// @notice Largest share of a newly opened range the tight range may take (BPS).
    uint16 public constant MAX_TIGHT_SHARE_BPS = 5000;

    /// @dev v4 `MIN_SQRT_PRICE + 1`: no price limit when selling currency0.
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;

    /// @dev v4 `MAX_SQRT_PRICE - 1`: no price limit when selling currency1.
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    /// @notice Uniswap v4 PoolManager the Fables pools live in (read for the pool price).
    IExtsload public immutable poolManager;

    /// @notice Fables emission stream that pays FABLES to staked liquidity.
    IFablesEmissionStream public immutable emissionStream;

    /// @notice Fables pool registry; swap routes may use any pool registered in it (zero: none).
    IFablesPoolRegistry public immutable poolRegistry;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidityVault
    address public override manager;

    /// @inheritdoc ILiquidityVault
    address public override owner;

    /// @inheritdoc ILiquidityVault
    address public override asset;

    /// @dev The eUSD token.
    address private _eusd;

    /// @dev The pool key; `hooks` is the pool's FablesLedger.
    PoolKey private _key;

    /// @dev Whether the asset is currency0.
    bool private _assetIsZero;

    /// @dev 10^assetDecimals.
    uint256 private _assetScale;

    /// @dev Lower tick of the open range.
    int24 private _tickLower;

    /// @dev Upper tick of the open range.
    int24 private _tickUpper;

    /// @dev Liquidity held in the open range.
    uint128 private _liquidity;

    /// @inheritdoc ILiquidityVault
    bool public override staked;

    /// @inheritdoc ILiquidityVault
    address public override delegate;

    /// @notice What harvested FABLES become. Defaults to eUSD.
    HarvestOut public harvestOut;

    /// @notice Whether harvests are sent to the owner. Defaults to kept in the vault.
    bool public harvestToOwner;

    /// @notice Share of a newly opened range placed in the tight range (BPS; 0 = off).
    uint16 public tightShareBps;

    /// @notice Half-width of the tight range in ticks, a multiple of the tick spacing.
    int24 public tightHalfWidth;

    /// @dev Lower tick of the open tight range.
    int24 private _tightLower;

    /// @dev Upper tick of the open tight range.
    int24 private _tightUpper;

    /// @dev Liquidity held in the tight range; nonzero only while the main range is open.
    uint128 private _tightLiquidity;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev Reverts unless called by the manager.
    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    /// @dev Reverts unless called by the owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev Reverts unless called by the owner or the delegate.
    modifier onlyOwnerOrDelegate() {
        if (msg.sender != owner && msg.sender != delegate) revert OnlyOwnerOrDelegate();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization
    // ──────────────────────────────────────────────────────────

    /// @notice Deploy the implementation. Locks its initializers; it is only used behind beacon proxies.
    /// @param poolManager_    Uniswap v4 PoolManager.
    /// @param emissionStream_ Fables emission stream.
    /// @param poolRegistry_   Fables pool registry, or zero to route only through the vault's hook.
    constructor(address poolManager_, address emissionStream_, address poolRegistry_) {
        if (poolManager_ == address(0) || emissionStream_ == address(0)) revert InvalidPool();
        poolManager = IExtsload(poolManager_);
        emissionStream = IFablesEmissionStream(emissionStream_);
        poolRegistry = IFablesPoolRegistry(poolRegistry_);
        _disableInitializers();
    }

    /// @inheritdoc ILiquidityVault
    function initialize(
        address owner_,
        address asset_,
        address eusd_,
        bytes calldata poolData
    ) external override initializer {
        (PoolKey memory key, bool assetIsZero) = _decodePool(asset_, eusd_, poolData);
        manager = msg.sender;
        owner = owner_;
        asset = asset_;
        _eusd = eusd_;
        _key = key;
        _assetIsZero = assetIsZero;
        _assetScale = 10 ** _decimals(asset_);
    }

    // ──────────────────────────────────────────────────────────
    //  Manager
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidityVault
    /// @dev When this opens the range and a tight range is set, {tightShareBps} of the amounts go
    ///      first into the tight range at the pool price; the returned liquidity is the main range's,
    ///      and the amounts used include both.
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 assetMax,
        uint256 eusdMax
    ) external override onlyManager nonReentrant returns (uint128 liquidity, uint256 assetUsed, uint256 eusdUsed) {
        if (_liquidity > 0) {
            if (tickLower != _tickLower || tickUpper != _tickUpper) revert RangeMismatch(_tickLower, _tickUpper);
        } else {
            _checkRange(tickLower, tickUpper);
        }

        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 eusdBefore = IERC20(_eusd).balanceOf(address(this));
        if (assetMax > assetBefore) assetMax = assetBefore;
        if (eusdMax > eusdBefore) eusdMax = eusdBefore;
        if (_liquidity == 0 && tightShareBps > 0) (assetMax, eusdMax) = _openTight(assetMax, eusdMax);
        (uint256 max0, uint256 max1) = _assetIsZero ? (assetMax, eusdMax) : (eusdMax, assetMax);
        liquidity = _liquidityFor(tickLower, tickUpper, max0, max1);
        if (liquidity == 0) revert ZeroLiquidity();

        _tickLower = tickLower;
        _tickUpper = tickUpper;
        _liquidity += liquidity;
        _deposit(tickLower, tickUpper, liquidity, max0, max1);

        assetUsed = assetBefore - IERC20(asset).balanceOf(address(this));
        eusdUsed = eusdBefore - IERC20(_eusd).balanceOf(address(this));
        emit LiquidityAdded(tickLower, tickUpper, liquidity, assetUsed, eusdUsed);
    }

    /// @inheritdoc ILiquidityVault
    /// @dev Fables `withdraw` is never pausable and unstakes the shares it needs. Removes the same
    ///      share of the tight range (rounded up; all of it with the last of the main range), and
    ///      the minimums apply to both ranges together.
    function removeLiquidity(
        uint128 liquidity,
        uint256 assetMin,
        uint256 eusdMin
    ) external override onlyManager nonReentrant returns (uint256 assetOut, uint256 eusdOut) {
        uint128 held = _liquidity;
        if (liquidity == 0 || liquidity > held) revert InsufficientLiquidity(liquidity, held);
        int24 tickLower = _tickLower;
        int24 tickUpper = _tickUpper;
        _liquidity = held - liquidity;
        if (held == liquidity) (_tickLower, _tickUpper) = (0, 0);

        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 eusdBefore = IERC20(_eusd).balanceOf(address(this));
        _withdraw(tickLower, tickUpper, liquidity);
        _removeTight(liquidity, held);
        assetOut = IERC20(asset).balanceOf(address(this)) - assetBefore;
        eusdOut = IERC20(_eusd).balanceOf(address(this)) - eusdBefore;
        if (assetOut < assetMin) revert InsufficientOutput(assetOut, assetMin);
        if (eusdOut < eusdMin) revert InsufficientOutput(eusdOut, eusdMin);
        emit LiquidityRemoved(liquidity, assetOut, eusdOut);
    }

    /// @inheritdoc ILiquidityVault
    /// @dev Staking needs the pool's gauge to be earning; unstaking always works.
    function setStaked(
        bool staked_
    ) external override onlyManager nonReentrant {
        if (staked_ == staked) return;
        staked = staked_;
        _setRangeStaked(_tickLower, _tickUpper, _liquidity, staked_);
        _setRangeStaked(_tightLower, _tightUpper, _tightLiquidity, staked_);
        emit StakedSet(staked_);
    }

    /// @inheritdoc ILiquidityVault
    function transferToken(address token, address to, uint256 amount) external override onlyManager nonReentrant {
        IERC20(token).safeTransfer(to, amount);
        emit TokenTransferred(token, to, amount);
    }

    /// @inheritdoc ILiquidityVault
    /// @dev Exact input through Fables pools on the PoolManager. Only the bought amount is
    ///      measured, so the vault's other balances never count as output.
    function swap(
        bool assetToEusd,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata route
    ) external override onlyManager nonReentrant returns (uint256 amountOut) {
        (address tokenIn, address tokenOut) = assetToEusd ? (asset, _eusd) : (_eusd, asset);
        amountOut = _swap(tokenIn, tokenOut, amountIn, route);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// @notice PoolManager callback: run the swap route encoded by {_swap} and settle it.
    /// @dev Only the PoolManager calls this, and it calls back only the contract that unlocked it.
    /// @param data abi-encoded (token sold, amount sold, route).
    /// @return Empty.
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address tokenIn, uint256 amountIn, PoolKey[] memory hops) = abi.decode(data, (address, uint256, PoolKey[]));
        IPoolManagerSwap pm = IPoolManagerSwap(msg.sender);
        address token = tokenIn;
        uint256 amount = amountIn;
        for (uint256 i; i < hops.length; ++i) {
            (token, amount) = _swapHop(pm, hops[i], token, amount);
        }
        pm.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(msg.sender, amountIn);
        pm.settle();
        pm.take(token, address(this), amount);
        return "";
    }

    // ──────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidityVault
    function setDelegate(
        address delegate_
    ) external override onlyOwner {
        delegate = delegate_;
        emit DelegateSet(delegate_);
    }

    /// @notice Set what harvests produce and where they go.
    /// @param out     What harvested FABLES become.
    /// @param toOwner Whether the output is sent to the owner (else kept in the vault).
    function setHarvestConfig(HarvestOut out, bool toOwner) external onlyOwner {
        harvestOut = out;
        harvestToOwner = toOwner;
        emit HarvestConfigSet(out, toOwner);
    }

    /// @notice Set the tight range for ranges opened from now on (a rebalance reopens the range).
    ///         Liquidity already in the pool does not move.
    /// @param shareBps  Share of a newly opened range placed in the tight range (BPS, at most
    ///                  {MAX_TIGHT_SHARE_BPS}; 0 turns it off).
    /// @param halfWidth Half-width in ticks, a positive multiple of the tick spacing (ignored when off).
    function setTightRange(uint16 shareBps, int24 halfWidth) external onlyOwnerOrDelegate {
        if (shareBps > MAX_TIGHT_SHARE_BPS || (shareBps > 0 && (halfWidth <= 0 || halfWidth % _key.tickSpacing != 0))) {
            revert InvalidTightRange(shareBps, halfWidth);
        }
        tightShareBps = shareBps;
        tightHalfWidth = halfWidth;
        emit TightRangeSet(msg.sender, shareBps, halfWidth);
    }

    /// @notice Claim the vault's FABLES (when a proof is given) and turn all FABLES in the vault
    ///         into the owner's chosen output, kept in the vault or sent to the owner in this call.
    /// @dev Only the swap's output leaves the vault, never eUSD or asset the vault already held.
    ///      FABLES has no oracle, so the caller's `minOut` is the only price check: the owner trusts
    ///      the delegate with the price of each harvest. Refused when FABLES is the pool's asset.
    /// @param cumulative Total FABLES the vault has ever earned, per the posted root.
    /// @param proof      Merkle proof of the vault's leaf; empty skips the claim.
    /// @param route      abi-encoded `PoolKey[]` from FABLES to the output (unused for FABLES).
    /// @param minOut     Least output accepted (output token units).
    /// @return amountOut Output produced (output token units).
    function harvest(
        uint256 cumulative,
        bytes32[] calldata proof,
        bytes calldata route,
        uint256 minOut
    ) external onlyOwnerOrDelegate nonReentrant returns (uint256 amountOut) {
        if (proof.length > 0) emissionStream.claim(KIND_LIQUID, uint256(uint160(address(this))), cumulative, proof);
        address fables = emissionStream.ff();
        if (fables == asset) revert ProtectedToken(fables);
        uint256 fablesIn = IERC20(fables).balanceOf(address(this));
        if (fablesIn == 0) revert NothingToHarvest();

        HarvestOut out = harvestOut;
        address tokenOut = out == HarvestOut.Eusd ? _eusd : out == HarvestOut.Asset ? asset : fables;
        if (out == HarvestOut.Fables) {
            amountOut = fablesIn;
        } else {
            if (route.length == 0) revert InvalidRoute();
            amountOut = _swap(fables, tokenOut, fablesIn, route);
        }
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        bool toOwner = harvestToOwner;
        if (toOwner) IERC20(tokenOut).safeTransfer(owner, amountOut);
        emit EmissionsHarvested(msg.sender, fablesIn, tokenOut, amountOut, toOwner);
    }

    /// @inheritdoc ILiquidityVault
    function sweep(
        address token
    ) external override onlyOwner nonReentrant {
        _sweep(token);
    }

    /// @notice Send the vault's accrued swap fees for a range (the open one or a past one) to the owner.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param maxFeeBps Highest Fables claim fee the owner accepts (BPS).
    function claimFees(int24 tickLower, int24 tickUpper, uint16 maxFeeBps) external onlyOwner nonReentrant {
        IFablesLedger(_key.hooks).claimFees(_key, tickLower, tickUpper, owner, maxFeeBps);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidityVault
    function checkPool(address asset_, address eusd_, bytes calldata poolData) external view override {
        _decodePool(asset_, eusd_, poolData);
    }

    /// @inheritdoc ILiquidityVault
    function range() external view override returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        return (_tickLower, _tickUpper, _liquidity);
    }

    /// @inheritdoc ILiquidityVault
    function holdings(
        uint256 price
    ) external view override returns (uint256 assetAmount, uint256 eusdAmount) {
        uint256 sqrtPrice = LiquidityMath.sqrtPriceFromOracle(price, _assetScale, _assetIsZero);
        (assetAmount, eusdAmount) = _rangeAmounts(sqrtPrice, _tickLower, _tickUpper, _liquidity);
        (uint256 tightAsset, uint256 tightEusd) = _rangeAmounts(sqrtPrice, _tightLower, _tightUpper, _tightLiquidity);
        assetAmount += tightAsset + IERC20(asset).balanceOf(address(this));
        eusdAmount += tightEusd + IERC20(_eusd).balanceOf(address(this));
    }

    /// @notice The open tight range (zeros when none).
    /// @return tickLower Lower tick.
    /// @return tickUpper Upper tick.
    /// @return liquidity Liquidity held.
    function tightRange() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        return (_tightLower, _tightUpper, _tightLiquidity);
    }

    /// @inheritdoc ILiquidityVault
    function poolPrice() external view override returns (uint256) {
        return LiquidityMath.priceFromSqrtPrice(_sqrtPriceX96(_key), _assetScale, _assetIsZero);
    }

    /// @notice The vault's pool key.
    /// @return The key.
    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Send the vault's whole balance of a non-protected token to the owner.
    /// @param token Token.
    function _sweep(
        address token
    ) private {
        if (token == asset || token == _eusd) revert ProtectedToken(token);
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) IERC20(token).safeTransfer(owner, amount);
        emit Swept(token, amount);
    }

    /// @dev Swap `amountIn` of `tokenIn` for `tokenOut`, exact input, through `route` (abi-encoded
    ///      `PoolKey[]`, or empty for the vault's own pool). Every hop must be a pool behind the
    ///      vault pool's hook or registered in {poolRegistry}, and the hops must chain from `tokenIn` to `tokenOut`.
    /// @param tokenIn  Token sold.
    /// @param tokenOut Token bought.
    /// @param amountIn Amount sold.
    /// @param route    The route.
    /// @return amountOut Amount bought, measured by the vault's balance change.
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata route
    ) private returns (uint256 amountOut) {
        PoolKey[] memory hops;
        if (route.length == 0) {
            hops = new PoolKey[](1);
            hops[0] = _key;
        } else {
            hops = abi.decode(route, (PoolKey[]));
        }
        if (amountIn == 0 || hops.length == 0 || hops.length > MAX_HOPS) revert InvalidRoute();
        address hook = _key.hooks;
        address token = tokenIn;
        for (uint256 i; i < hops.length; ++i) {
            PoolKey memory hop = hops[i];
            if (hop.hooks != hook && !_registered(hop)) revert InvalidRoute();
            if (token == hop.currency0) token = hop.currency1;
            else if (token == hop.currency1) token = hop.currency0;
            else revert InvalidRoute();
        }
        if (token != tokenOut) revert InvalidRoute();

        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IPoolManagerSwap(address(poolManager)).unlock(abi.encode(tokenIn, amountIn, hops));
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Whether `key` is a pool in the Fables registry.
    function _registered(
        PoolKey memory key
    ) private view returns (bool) {
        return address(poolRegistry) != address(0) && poolRegistry.isRegistered(keccak256(abi.encode(key)));
    }

    /// @dev Sell exactly `amount` of `token` in one pool during an unlock.
    /// @param pm     The PoolManager.
    /// @param hop    The pool.
    /// @param token  Token sold (one of the pool's currencies).
    /// @param amount Amount sold.
    /// @return tokenOut  Token bought.
    /// @return amountOut Amount bought.
    function _swapHop(
        IPoolManagerSwap pm,
        PoolKey memory hop,
        address token,
        uint256 amount
    ) private returns (address tokenOut, uint256 amountOut) {
        bool zeroForOne = token == hop.currency0;
        int256 delta = pm.swap(
            hop,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (int128 paid, int128 out) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        // A partial fill would leave part of the input unsettled; refuse it.
        if (int256(paid) != -SafeCast.toInt256(amount) || out < 0) revert InvalidRoute();
        return (zeroForOne ? hop.currency1 : hop.currency0, uint256(int256(out)));
    }

    /// @dev Deposit liquidity through the ledger, approving exactly the maximums for the call, and
    ///      stake it when the vault is staked.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param liquidity Liquidity to deposit.
    /// @param max0      Most currency0 to pay (raw units).
    /// @param max1      Most currency1 to pay (raw units).
    function _deposit(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 max0, uint256 max1) private {
        PoolKey memory key = _key;
        IERC20(key.currency0).forceApprove(key.hooks, max0);
        IERC20(key.currency1).forceApprove(key.hooks, max1);
        IFablesLedger(key.hooks).deposit(
            key, tickLower, tickUpper, liquidity, SafeCast.toUint128(max0), SafeCast.toUint128(max1), block.timestamp
        );
        IERC20(key.currency0).forceApprove(key.hooks, 0);
        IERC20(key.currency1).forceApprove(key.hooks, 0);
        if (staked) IFablesLedger(key.hooks).stake(key, tickLower, tickUpper, liquidity, 0);
    }

    /// @dev Withdraw liquidity from the ledger to this vault; the caller checks the amounts.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param liquidity Liquidity to withdraw.
    function _withdraw(int24 tickLower, int24 tickUpper, uint128 liquidity) private {
        IFablesLedger(_key.hooks).withdraw(_key, tickLower, tickUpper, liquidity, address(this), 0, 0, block.timestamp);
    }

    /// @dev Withdraw `part` / `whole` of the tight range (rounded up; all of it when equal).
    /// @param part  Main-range liquidity removed.
    /// @param whole Main-range liquidity held before.
    function _removeTight(uint128 part, uint128 whole) private {
        uint128 tight = _tightLiquidity;
        if (tight == 0) return;
        int24 tickLower = _tightLower;
        int24 tickUpper = _tightUpper;
        uint128 out = part == whole ? tight : uint128(Math.mulDiv(tight, part, whole, Math.Rounding.Ceil));
        _tightLiquidity = tight - out;
        if (out == tight) (_tightLower, _tightUpper) = (0, 0);
        _withdraw(tickLower, tickUpper, out);
    }

    /// @dev Stake or unstake a range's liquidity, if any.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param liquidity Liquidity in the range.
    /// @param staked_   Whether to stake.
    function _setRangeStaked(int24 tickLower, int24 tickUpper, uint128 liquidity, bool staked_) private {
        if (liquidity == 0) return;
        if (staked_) IFablesLedger(_key.hooks).stake(_key, tickLower, tickUpper, liquidity, 0);
        else IFablesLedger(_key.hooks).unstake(_key, tickLower, tickUpper, liquidity);
    }

    /// @dev Open the tight range with {tightShareBps} of the amounts. Skipped when that share funds
    ///      no liquidity.
    /// @param assetMax Asset available (asset units).
    /// @param eusdMax  eUSD available (18 decimals).
    /// @return Asset left for the main range.
    /// @return eUSD left for the main range.
    function _openTight(uint256 assetMax, uint256 eusdMax) private returns (uint256, uint256) {
        (int24 tickLower, int24 tickUpper) = _tightTicks();
        uint256 share = tightShareBps;
        (uint256 max0, uint256 max1) = _assetIsZero
            ? (assetMax * share / BPS, eusdMax * share / BPS)
            : (eusdMax * share / BPS, assetMax * share / BPS);
        uint128 liquidity = _liquidityFor(tickLower, tickUpper, max0, max1);
        if (liquidity == 0) return (assetMax, eusdMax);

        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 eusdBefore = IERC20(_eusd).balanceOf(address(this));
        _tightLower = tickLower;
        _tightUpper = tickUpper;
        _tightLiquidity = liquidity;
        _deposit(tickLower, tickUpper, liquidity, max0, max1);
        uint256 assetUsed = assetBefore - IERC20(asset).balanceOf(address(this));
        uint256 eusdUsed = eusdBefore - IERC20(_eusd).balanceOf(address(this));
        emit TightRangeOpened(tickLower, tickUpper, liquidity, assetUsed, eusdUsed);
        return (assetMax - assetUsed, eusdMax - eusdUsed);
    }

    /// @dev The tight range's ticks: {tightHalfWidth} either side of the pool tick rounded to the
    ///      nearest spacing.
    /// @return tickLower Lower tick.
    /// @return tickUpper Upper tick.
    function _tightTicks() private view returns (int24 tickLower, int24 tickUpper) {
        int24 spacing = _key.tickSpacing;
        int24 tick = _poolTick();
        int24 centre = tick / spacing * spacing;
        int24 rem = tick - centre;
        if (2 * rem >= spacing) centre += spacing;
        else if (2 * rem < -spacing) centre -= spacing;
        tickLower = centre - tightHalfWidth;
        tickUpper = centre + tightHalfWidth;
        _checkRange(tickLower, tickUpper);
    }

    /// @dev Token amounts a range holds at a sqrt price.
    /// @param sqrtPrice Sqrt price (Q64.96).
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param liquidity Liquidity.
    /// @return assetAmount Asset (asset units).
    /// @return eusdAmount  eUSD (18 decimals).
    function _rangeAmounts(
        uint256 sqrtPrice,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) private view returns (uint256 assetAmount, uint256 eusdAmount) {
        if (liquidity == 0) return (0, 0);
        (uint256 amount0, uint256 amount1) = LiquidityMath.getAmountsForLiquidity(
            sqrtPrice,
            LiquidityMath.getSqrtPriceAtTick(tickLower),
            LiquidityMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        (assetAmount, eusdAmount) = _assetIsZero ? (amount0, amount1) : (amount1, amount0);
    }

    /// @dev Liquidity the amounts fund at the pool price. Each amount is reduced by 2 wei first:
    ///      the pool rounds the principal it charges up, by at most 2 wei over the rounded-down
    ///      quote, so the deposit never asks for more than the amounts given.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param amount0   Currency0 available (raw units).
    /// @param amount1   Currency1 available (raw units).
    /// @return Liquidity.
    function _liquidityFor(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint128) {
        uint256 sqrtPrice = _sqrtPriceX96(_key);
        if (sqrtPrice == 0) revert PoolNotInitialized();
        return LiquidityMath.getLiquidityForAmounts(
            sqrtPrice,
            LiquidityMath.getSqrtPriceAtTick(tickLower),
            LiquidityMath.getSqrtPriceAtTick(tickUpper),
            amount0 > 2 ? amount0 - 2 : 0,
            amount1 > 2 ? amount1 - 2 : 0
        );
    }

    /// @dev Revert unless the range is ordered, within the tick bounds and on the tick spacing.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    function _checkRange(int24 tickLower, int24 tickUpper) private view {
        int24 spacing = _key.tickSpacing;
        if (
            tickLower >= tickUpper || tickLower < LiquidityMath.MIN_TICK || tickUpper > LiquidityMath.MAX_TICK
                || tickLower % spacing != 0 || tickUpper % spacing != 0
        ) revert InvalidRange(tickLower, tickUpper);
    }

    /// @dev The pool's sqrt price from the PoolManager's `pools[id].slot0` (low 160 bits).
    /// @param key Pool key.
    /// @return Sqrt price (Q64.96); zero for an uninitialized pool.
    function _sqrtPriceX96(
        PoolKey memory key
    ) private view returns (uint256) {
        return uint256(_slot0(key)) & type(uint160).max;
    }

    /// @dev The vault pool's current tick (slot0 bits 160-183).
    /// @return The tick.
    function _poolTick() private view returns (int24) {
        return int24(uint24(uint256(_slot0(_key)) >> 160));
    }

    /// @dev A pool's slot0 word from the PoolManager's `pools[id]`.
    /// @param key Pool key.
    /// @return The word.
    function _slot0(
        PoolKey memory key
    ) private view returns (bytes32) {
        return poolManager.extsload(keccak256(abi.encodePacked(keccak256(abi.encode(key)), POOLS_SLOT)));
    }

    /// @dev Decode and validate the pool data: an initialized, non-native asset/eUSD pool behind a hook.
    /// @param asset_   The pool's non-eUSD token.
    /// @param eusd_    The eUSD token.
    /// @param poolData abi-encoded {PoolKey}.
    /// @return key         The pool key.
    /// @return assetIsZero Whether the asset is currency0.
    function _decodePool(
        address asset_,
        address eusd_,
        bytes calldata poolData
    ) private view returns (PoolKey memory key, bool assetIsZero) {
        key = abi.decode(poolData, (PoolKey));
        if (
            asset_ == address(0) || eusd_ == address(0) || asset_ == eusd_ || key.hooks == address(0)
                || key.tickSpacing <= 0 || key.currency0 >= key.currency1
        ) revert InvalidPool();
        assetIsZero = key.currency0 == asset_;
        if (assetIsZero ? key.currency1 != eusd_ : (key.currency0 != eusd_ || key.currency1 != asset_)) {
            revert InvalidPool();
        }
        if (_sqrtPriceX96(key) == 0) revert PoolNotInitialized();
        if (_decimals(asset_) > 18) revert InvalidPool();
    }

    /// @dev Token decimals.
    /// @param token Token.
    /// @return Decimals.
    function _decimals(
        address token
    ) private view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }
}
