// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILiquidityVault} from "../../interfaces/ILiquidityVault.sol";
import {ICLFactory, ICLGauge, ICLPool, INonfungiblePositionManager} from "../../interfaces/external/IAerodrome.sol";
import {LiquidityMath} from "../../libraries/LiquidityMath.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AerodromeAdapter — liquidity vault for Aero Slipstream pools
/// @notice See {ILiquidityVault}. Holds one owner's range in one Aero Slipstream (concentrated
///         liquidity) asset/eUSD pool as a single position NFT. Staking moves the NFT into the
///         pool's gauge, where its liquidity gives up swap fees and earns emissions while in
///         range, claimable by the owner. Unstaked, the position earns swap fees, also claimable
///         by the owner. Fees the DEX pays out while liquidity moves (staking, unstaking,
///         removing) land in the vault as idle asset and eUSD.
/// @dev Each vault is a BeaconProxy; this is the implementation behind the Aero beacon. The
///      position manager and pool factory are DEX-wide, so they are immutables of the
///      implementation; the pool is per vault. The gauge the NFT was last staked in is kept, so
///      a gauge replaced by Aero still releases the NFT and its emissions. Tokens must not
///      charge transfer fees.
contract AerodromeAdapter is ILiquidityVault, IERC721Receiver, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when staking a pool that has no gauge.
    error NoGauge();

    /// @notice Thrown when an NFT arrives from a contract other than the position manager.
    error UnexpectedNFT();

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    /// @notice Aero Slipstream position manager (the position NFT).
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Aero Slipstream pool factory; vault pools must be its canonical pools.
    ICLFactory public immutable factory;

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

    /// @notice The vault's pool.
    ICLPool public pool;

    /// @dev Whether the asset is token0.
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

    /// @notice The open range's position NFT; zero when the vault holds no liquidity.
    uint256 public tokenId;

    /// @notice The gauge the NFT was last staked in; zero if never staked.
    ICLGauge public gauge;

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

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization
    // ──────────────────────────────────────────────────────────

    /// @notice Deploy the implementation. Locks its initializers; it is only used behind beacon proxies.
    /// @param positionManager_ Aero Slipstream position manager.
    /// @param factory_         Aero Slipstream pool factory.
    constructor(address positionManager_, address factory_) {
        if (positionManager_ == address(0) || factory_ == address(0)) revert InvalidPool();
        positionManager = INonfungiblePositionManager(positionManager_);
        factory = ICLFactory(factory_);
        _disableInitializers();
    }

    /// @inheritdoc ILiquidityVault
    /// @dev `poolData` is the abi-encoded pool address.
    function initialize(
        address owner_,
        address asset_,
        address eusd_,
        bytes calldata poolData
    ) external override initializer {
        (ICLPool pool_, bool assetIsZero) = _decodePool(asset_, eusd_, poolData);
        manager = msg.sender;
        owner = owner_;
        asset = asset_;
        _eusd = eusd_;
        pool = pool_;
        _assetIsZero = assetIsZero;
        _assetScale = 10 ** _decimals(asset_);
    }

    // ──────────────────────────────────────────────────────────
    //  Manager
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidityVault
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
        (uint256 max0, uint256 max1) = _assetIsZero ? (assetMax, eusdMax) : (eusdMax, assetMax);
        // Headroom for the pool rounding the principal it charges up.
        max0 = max0 > 2 ? max0 - 2 : 0;
        max1 = max1 > 2 ? max1 - 2 : 0;
        if (_liquidityFor(tickLower, tickUpper, max0, max1) == 0) revert ZeroLiquidity();

        liquidity = _deposit(tickLower, tickUpper, max0, max1);
        _tickLower = tickLower;
        _tickUpper = tickUpper;
        _liquidity += liquidity;

        assetUsed = assetBefore - IERC20(asset).balanceOf(address(this));
        eusdUsed = eusdBefore - IERC20(_eusd).balanceOf(address(this));
        emit LiquidityAdded(tickLower, tickUpper, liquidity, assetUsed, eusdUsed);
    }

    /// @inheritdoc ILiquidityVault
    /// @dev Unstakes first when staked; the gauge's unstake path never reverts on Aero's emission
    ///      accounting. Collects everything the position is owed into the vault, so swap fees not
    ///      yet claimed by the owner become idle balances.
    function removeLiquidity(
        uint128 liquidity,
        uint256 assetMin,
        uint256 eusdMin
    ) external override onlyManager nonReentrant returns (uint256 assetOut, uint256 eusdOut) {
        uint128 held = _liquidity;
        if (liquidity == 0 || liquidity > held) revert InsufficientLiquidity(liquidity, held);
        uint256 id = tokenId;
        _liquidity = held - liquidity;

        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 eusdBefore = IERC20(_eusd).balanceOf(address(this));
        if (staked) gauge.withdraw(id);
        (uint256 min0, uint256 min1) = _assetIsZero ? (assetMin, eusdMin) : (eusdMin, assetMin);
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id,
                liquidity: liquidity,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp
            })
        );
        _collect(id, address(this));
        if (held == liquidity) {
            positionManager.burn(id);
            tokenId = 0;
            (_tickLower, _tickUpper) = (0, 0);
        } else if (staked) {
            _stake(id);
        }
        assetOut = IERC20(asset).balanceOf(address(this)) - assetBefore;
        eusdOut = IERC20(_eusd).balanceOf(address(this)) - eusdBefore;
        emit LiquidityRemoved(liquidity, assetOut, eusdOut);
    }

    /// @inheritdoc ILiquidityVault
    /// @dev Staking needs the pool to have a gauge; unstaking always works.
    function setStaked(
        bool staked_
    ) external override onlyManager nonReentrant {
        if (staked_ == staked) return;
        staked = staked_;
        uint256 id = tokenId;
        if (id != 0) {
            if (staked_) _stake(id);
            else gauge.withdraw(id);
        }
        emit StakedSet(staked_);
    }

    /// @inheritdoc ILiquidityVault
    function transferToken(address token, address to, uint256 amount) external override onlyManager nonReentrant {
        IERC20(token).safeTransfer(to, amount);
        emit TokenTransferred(token, to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidityVault
    function sweep(
        address token
    ) external override onlyOwner nonReentrant {
        _sweep(token);
    }

    /// @notice Claim the vault's emissions from the gauge it last staked in, straight to the owner.
    ///         Emissions paid to the vault when it unstakes are taken with {sweep}.
    function claimEmissions() external onlyOwner nonReentrant {
        gauge.claimEmissions(address(this), owner);
    }

    /// @notice Send the open position's swap fees to the owner. Only an unstaked position earns them.
    function claimFees() external onlyOwner nonReentrant {
        _collect(tokenId, owner);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-721
    // ──────────────────────────────────────────────────────────

    /// @notice Accept position NFTs coming back from a gauge.
    /// @dev Only the position manager's NFTs are accepted.
    /// @return The ERC-721 receiver selector.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(positionManager)) revert UnexpectedNFT();
        return IERC721Receiver.onERC721Received.selector;
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
        uint128 liquidity = _liquidity;
        if (liquidity > 0) {
            bool assetIsZero = _assetIsZero;
            (uint256 amount0, uint256 amount1) = LiquidityMath.getAmountsForLiquidity(
                LiquidityMath.sqrtPriceFromOracle(price, _assetScale, assetIsZero),
                LiquidityMath.getSqrtPriceAtTick(_tickLower),
                LiquidityMath.getSqrtPriceAtTick(_tickUpper),
                liquidity
            );
            (assetAmount, eusdAmount) = assetIsZero ? (amount0, amount1) : (amount1, amount0);
        }
        assetAmount += IERC20(asset).balanceOf(address(this));
        eusdAmount += IERC20(_eusd).balanceOf(address(this));
    }

    /// @inheritdoc ILiquidityVault
    function poolPrice() external view override returns (uint256) {
        return LiquidityMath.priceFromSqrtPrice(_sqrtPriceX96(pool), _assetScale, _assetIsZero);
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

    /// @dev Add liquidity to the open position, or mint it, approving exactly the maximums for
    ///      the call. A staked position is unstaked around the change, as gauges hold the NFT.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param max0      Most token0 to pay (raw units).
    /// @param max1      Most token1 to pay (raw units).
    /// @return liquidity Liquidity added.
    function _deposit(
        int24 tickLower,
        int24 tickUpper,
        uint256 max0,
        uint256 max1
    ) private returns (uint128 liquidity) {
        ICLPool pool_ = pool;
        address token0 = pool_.token0();
        address token1 = pool_.token1();
        IERC20(token0).forceApprove(address(positionManager), max0);
        IERC20(token1).forceApprove(address(positionManager), max1);
        uint256 id = tokenId;
        if (id == 0) {
            (id, liquidity,,) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    tickSpacing: pool_.tickSpacing(),
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: max0,
                    amount1Desired: max1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp,
                    sqrtPriceX96: 0
                })
            );
            tokenId = id;
        } else {
            if (staked) gauge.withdraw(id);
            (liquidity,,) = positionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: id,
                    amount0Desired: max0,
                    amount1Desired: max1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        IERC20(token0).forceApprove(address(positionManager), 0);
        IERC20(token1).forceApprove(address(positionManager), 0);
        if (staked) _stake(id);
    }

    /// @dev Stake the NFT in the pool's current gauge and remember that gauge.
    /// @param id Position.
    function _stake(
        uint256 id
    ) private {
        address gauge_ = pool.gauge();
        if (gauge_ == address(0)) revert NoGauge();
        gauge = ICLGauge(gauge_);
        positionManager.approve(gauge_, id);
        ICLGauge(gauge_).deposit(id);
    }

    /// @dev Collect everything a position is owed.
    /// @param id Position.
    /// @param to Recipient.
    function _collect(uint256 id, address to) private {
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id,
                recipient: to,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// @dev Liquidity the amounts fund at the pool price.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param amount0   Token0 available (raw units).
    /// @param amount1   Token1 available (raw units).
    /// @return Liquidity.
    function _liquidityFor(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint128) {
        uint256 sqrtPrice = _sqrtPriceX96(pool);
        if (sqrtPrice == 0) revert PoolNotInitialized();
        return LiquidityMath.getLiquidityForAmounts(
            sqrtPrice,
            LiquidityMath.getSqrtPriceAtTick(tickLower),
            LiquidityMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @dev Revert unless the range is ordered, within the tick bounds and on the tick spacing.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    function _checkRange(int24 tickLower, int24 tickUpper) private view {
        int24 spacing = pool.tickSpacing();
        if (
            tickLower >= tickUpper || tickLower < LiquidityMath.MIN_TICK || tickUpper > LiquidityMath.MAX_TICK
                || tickLower % spacing != 0 || tickUpper % spacing != 0
        ) revert InvalidRange(tickLower, tickUpper);
    }

    /// @dev The pool's sqrt price.
    /// @param pool_ Pool.
    /// @return Sqrt price (Q64.96); zero for an uninitialized pool.
    function _sqrtPriceX96(
        ICLPool pool_
    ) private view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,) = pool_.slot0();
        return sqrtPriceX96;
    }

    /// @dev Decode and validate the pool data: an initialized asset/eUSD pool of the factory.
    /// @param asset_   The pool's non-eUSD token.
    /// @param eusd_    The eUSD token.
    /// @param poolData abi-encoded pool address.
    /// @return pool_       The pool.
    /// @return assetIsZero Whether the asset is token0.
    function _decodePool(
        address asset_,
        address eusd_,
        bytes calldata poolData
    ) private view returns (ICLPool pool_, bool assetIsZero) {
        pool_ = ICLPool(abi.decode(poolData, (address)));
        if (asset_ == address(0) || eusd_ == address(0) || asset_ == eusd_ || address(pool_).code.length == 0) {
            revert InvalidPool();
        }
        address token0 = pool_.token0();
        assetIsZero = token0 == asset_;
        if (assetIsZero ? pool_.token1() != eusd_ : (token0 != eusd_ || pool_.token1() != asset_)) {
            revert InvalidPool();
        }
        if (factory.getPool(asset_, eusd_, pool_.tickSpacing()) != address(pool_)) revert InvalidPool();
        if (_sqrtPriceX96(pool_) == 0) revert PoolNotInitialized();
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
