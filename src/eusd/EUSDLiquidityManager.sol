// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSD} from "../interfaces/IEUSD.sol";
import {IEUSDLiquidityManager} from "../interfaces/IEUSDLiquidityManager.sol";
import {ILiquidityVault} from "../interfaces/ILiquidityVault.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EUSDLiquidityManager — eUSD minted into DEX liquidity
/// @notice See {IEUSDLiquidityManager}. Resolves the oracle, treasury and roles through the
///         ProtocolRegistry.
/// @dev Each position's tokens sit in its own vault (a BeaconProxy of the pool's DEX adapter), so
///      the manager stores only debt and reads collateral from the vault. Assets must not charge
///      transfer fees. Runs behind an ERC-1967 proxy (UUPS); upgrades are ADMIN-gated.
contract EUSDLiquidityManager is IEUSDLiquidityManager, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @dev Oracle price and position health before a liquidity change.
    /// @param price       Oracle price (18 decimals).
    /// @param timestamp   Oracle price timestamp.
    /// @param debt        Debt before the change (18 decimals).
    /// @param ratioBps    Ratio before the change at `price` (BPS).
    struct HealthSnapshot {
        uint256 price;
        uint256 timestamp;
        uint256 debt;
        uint256 ratioBps;
    }

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Stability-fee year basis (simple interest).
    uint256 private constant YEAR = 365 days;

    /// @dev ProtocolRegistry role for configuration and upgrades.
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @dev ProtocolRegistry role for the mint pause.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve the oracle, treasury and roles. Set once at
    ///         initialization.
    IProtocolRegistry public registry;

    /// @dev The eUSD token minted and burned by this manager. Set once at initialization.
    IEUSD private _eusd;

    /// @dev Current risk parameters (see {riskParams}).
    RiskParams private _riskParams;

    /// @inheritdoc IEUSDLiquidityManager
    bool public override mintPaused;

    /// @inheritdoc IEUSDLiquidityManager
    uint256 public override totalDebt;

    /// @inheritdoc IEUSDLiquidityManager
    uint256 public override poolCount;

    /// @dev Pool id => configuration.
    mapping(uint256 => PoolConfig) private _pools;

    /// @dev Pool id => owner => position.
    mapping(uint256 => mapping(address => Position)) private _positions;

    /// @dev Pool id => owners in vault-creation order.
    mapping(uint256 => address[]) private _owners;

    /// @dev Fee index of the staked rate: cumulative `stakedFeeBps` × elapsed seconds.
    uint256 private _stakedFeeIndex;

    /// @dev Fee index of the unstaked rate: cumulative `unstakedFeeBps` × elapsed seconds.
    uint256 private _unstakedFeeIndex;

    /// @dev Timestamp both fee indexes were last settled.
    uint256 private _feeIndexUpdated;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev Reverts unless the caller holds ADMIN in the registry.
    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @dev Reverts unless the caller holds OPERATOR in the registry.
    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev Locks the implementation's initializers; it is only used behind a proxy.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy (called once, in the proxy's constructor).
    /// @param registry_ ProtocolRegistry contract address.
    /// @param eusd_     EUSD token address (this manager must hold its MINTER_ROLE).
    /// @param params    Initial risk parameters (validated as in the setters).
    function initialize(address registry_, address eusd_, RiskParams calldata params) external initializer {
        if (registry_ == address(0) || eusd_ == address(0)) revert ZeroAddress();
        _validateRatios(params.mcrBps, params.liquidationThresholdBps, params.liquidationBonusBps);
        if (
            params.stakedFeeBps > BPS || params.unstakedFeeBps > BPS || params.poolPriceBandBps == 0
                || params.poolPriceBandBps > BPS || params.mintPriceMaxAge == 0
        ) revert InvalidRiskParams();
        registry = IProtocolRegistry(registry_);
        _eusd = IEUSD(eusd_);
        _riskParams = params;
        _feeIndexUpdated = block.timestamp;
    }

    /// @dev UUPS upgrade gate: ADMIN only.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

    // ──────────────────────────────────────────────────────────
    //  External — position management
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDLiquidityManager
    function deposit(uint256 poolId, uint256 amount) external override nonReentrant {
        PoolConfig storage cfg = _requirePool(poolId);
        if (amount == 0) revert ZeroAmount();
        Position storage p = _accrue(poolId, msg.sender);
        // A disabled pool takes no new exposure, but an existing debtor may still top up.
        if (!cfg.enabled && p.debt == 0) revert PoolDisabled(poolId);
        address vault = _vaultFor(poolId, cfg, p);
        IERC20(cfg.asset).safeTransferFrom(msg.sender, vault, amount);
        emit AssetDeposited(poolId, msg.sender, amount);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function withdraw(uint256 poolId, uint256 amount) external override nonReentrant {
        PoolConfig storage cfg = _requirePool(poolId);
        if (amount == 0) revert ZeroAmount();
        Position storage p = _accrue(poolId, msg.sender);
        address vault = _requireVault(poolId, msg.sender, p);
        uint256 idle = IERC20(cfg.asset).balanceOf(vault);
        if (amount > idle) revert InsufficientIdleAsset(amount, idle);

        uint256 debt = p.debt;
        if (debt > 0) {
            if (mintPaused) revert MintingPaused();
            uint256 price = _freshPrice(cfg.ticker);
            uint256 ratio = _ratioBps(_value(cfg, vault, price) - _assetValue(cfg, amount, price), debt);
            if (ratio < _riskParams.mcrBps) revert CollateralRatioTooLow(ratio, _riskParams.mcrBps);
        }

        ILiquidityVault(vault).transferToken(cfg.asset, msg.sender, amount);
        emit AssetWithdrawn(poolId, msg.sender, amount);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function addLiquidity(
        AddLiquidityParams calldata params
    ) external override nonReentrant returns (uint128 liquidity) {
        uint256 poolId = params.poolId;
        PoolConfig storage cfg = _requireEnabledPool(poolId);
        Position storage p = _accrue(poolId, msg.sender);
        address vault = _vaultFor(poolId, cfg, p);
        if (params.assetDeposit > 0) {
            IERC20(cfg.asset).safeTransferFrom(msg.sender, vault, params.assetDeposit);
            emit AssetDeposited(poolId, msg.sender, params.assetDeposit);
        }

        HealthSnapshot memory before = _snapshot(cfg, p, vault);
        liquidity = _add(poolId, p, vault, params.tickLower, params.tickUpper, params.assetMax, params.eusdMax);
        _checkHealth(cfg, p, vault, before);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function removeLiquidity(
        uint256 poolId,
        uint128 liquidity,
        uint256 assetMin,
        uint256 eusdMin
    ) external override nonReentrant {
        _requirePool(poolId);
        if (liquidity == 0) revert ZeroAmount();
        Position storage p = _accrue(poolId, msg.sender);
        address vault = _requireVault(poolId, msg.sender, p);
        _remove(poolId, msg.sender, vault, liquidity, assetMin, eusdMin);
        // Only eUSD leaves the vault, burned 1:1 against the debt, so no health check is needed.
        _burnIdle(poolId, msg.sender, p, vault);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function reposition(
        RepositionParams calldata params
    ) external override nonReentrant returns (uint128 liquidity) {
        uint256 poolId = params.poolId;
        PoolConfig storage cfg = _requireEnabledPool(poolId);
        Position storage p = _accrue(poolId, msg.sender);
        address vault = _requireVault(poolId, msg.sender, p);

        HealthSnapshot memory before = _snapshot(cfg, p, vault);
        (,, uint128 held) = ILiquidityVault(vault).range();
        if (held > 0) _remove(poolId, msg.sender, vault, held, params.assetMin, params.eusdMin);
        liquidity = _add(poolId, p, vault, params.tickLower, params.tickUpper, params.assetMax, params.eusdMax);
        _checkHealth(cfg, p, vault, before);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setStaked(uint256 poolId, bool staked) external override nonReentrant {
        _requirePool(poolId);
        Position storage p = _accrue(poolId, msg.sender);
        address vault = _requireVault(poolId, msg.sender, p);
        p.staked = staked;
        p.feeIndexSnapshot = staked ? _stakedFeeIndex : _unstakedFeeIndex;
        ILiquidityVault(vault).setStaked(staked);
        emit StakedSet(poolId, msg.sender, staked);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function repay(uint256 poolId, address owner, uint256 amount) external override nonReentrant {
        _requirePool(poolId);
        if (owner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        Position storage p = _accrue(poolId, owner);
        if (p.debt == 0) revert NoDebt(poolId, owner);

        uint256 repaid = amount > p.debt ? p.debt : amount;
        uint256 remaining = p.debt - repaid;
        if (remaining != 0 && remaining < _riskParams.minDebt) {
            revert BelowMinimumDebt(remaining, _riskParams.minDebt);
        }
        _reduceDebt(p, repaid);
        _eusd.burn(msg.sender, repaid);
        emit DebtRepaid(poolId, owner, msg.sender, repaid, remaining);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function close(uint256 poolId, uint256 assetMin, uint256 eusdMin) external override nonReentrant {
        PoolConfig storage cfg = _requirePool(poolId);
        Position storage p = _accrue(poolId, msg.sender);
        address vault = _requireVault(poolId, msg.sender, p);
        (,, uint128 held) = ILiquidityVault(vault).range();
        if (held > 0) _remove(poolId, msg.sender, vault, held, assetMin, eusdMin);

        uint256 debt = p.debt;
        uint256 vaultEusd = _eusd.balanceOf(vault);
        uint256 assetOut = IERC20(cfg.asset).balanceOf(vault);
        if (debt == 0 && held == 0 && vaultEusd == 0 && assetOut == 0) revert EmptyPosition(poolId, msg.sender);
        uint256 fromVault = Math.min(vaultEusd, debt);
        uint256 paidByUser = debt - fromVault;
        _reduceDebt(p, debt);

        if (fromVault > 0) _eusd.burn(vault, fromVault);
        if (paidByUser > 0) _eusd.burn(msg.sender, paidByUser);
        if (assetOut > 0) ILiquidityVault(vault).transferToken(cfg.asset, msg.sender, assetOut);
        if (vaultEusd > fromVault) {
            ILiquidityVault(vault).transferToken(address(_eusd), msg.sender, vaultEusd - fromVault);
        }
        emit PositionClosed(poolId, msg.sender, debt, paidByUser, assetOut, vaultEusd - fromVault);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function accrue(uint256 poolId, address owner) external override nonReentrant {
        _requirePool(poolId);
        if (_accrue(poolId, owner).debt == 0) revert NoDebt(poolId, owner);
    }

    /// @inheritdoc IEUSDLiquidityManager
    /// @dev No pool price band: the valuation is a lower bound wherever the pool trades, and a lagging
    ///      pool must not hold up a liquidation.
    function liquidate(uint256 poolId, address owner) external override nonReentrant {
        PoolConfig storage cfg = _requirePool(poolId);
        Position storage p = _accrue(poolId, owner);
        uint256 debt = p.debt;
        if (debt == 0) revert NoDebt(poolId, owner);
        address vault = p.vault;

        (uint256 price,) = _oracle().getPrice(cfg.ticker);
        {
            uint256 ratio = _ratioBps(_value(cfg, vault, price), debt);
            uint16 threshold = _riskParams.liquidationThresholdBps;
            if (ratio >= threshold) revert PositionNotLiquidatable(ratio, threshold);
        }

        (,, uint128 held) = ILiquidityVault(vault).range();
        if (held > 0) _remove(poolId, owner, vault, held, 0, 0);

        uint256 vaultEusd = _eusd.balanceOf(vault);
        uint256 vaultAsset = IERC20(cfg.asset).balanceOf(vault);
        uint256 fromVault = Math.min(vaultEusd, debt);
        uint256 repaid = debt - fromVault;
        // Rounded down: the liquidator gets at most repaid × (1 + bonus) at the oracle price.
        uint256 seized =
            Math.mulDiv(repaid * (BPS + _riskParams.liquidationBonusBps), 10 ** cfg.assetDecimals, price * BPS);
        if (seized > vaultAsset) seized = vaultAsset;
        _reduceDebt(p, debt);

        if (fromVault > 0) _eusd.burn(vault, fromVault);
        if (repaid > 0) _eusd.burn(msg.sender, repaid);
        if (seized > 0) ILiquidityVault(vault).transferToken(cfg.asset, msg.sender, seized);
        if (vaultAsset > seized) ILiquidityVault(vault).transferToken(cfg.asset, owner, vaultAsset - seized);
        if (vaultEusd > fromVault) ILiquidityVault(vault).transferToken(address(_eusd), owner, vaultEusd - fromVault);
        emit PositionLiquidated(
            poolId, owner, msg.sender, debt, repaid, seized, vaultAsset - seized, vaultEusd - fromVault
        );
    }

    // ──────────────────────────────────────────────────────────
    //  External — admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDLiquidityManager
    function addPool(
        address beacon,
        address asset,
        bytes32 ticker,
        bytes calldata poolData
    ) external override onlyAdmin returns (uint256 poolId) {
        if (beacon == address(0) || asset == address(0)) revert ZeroAddress();
        uint8 dec = IERC20Metadata(asset).decimals();
        if (dec > 18) revert InvalidAssetDecimals(dec);
        // Reverts unless the ticker is priced and the DEX adapter accepts the pool.
        _oracle().getPrice(ticker);
        ILiquidityVault(IBeacon(beacon).implementation()).checkPool(asset, address(_eusd), poolData);

        poolId = poolCount++;
        _pools[poolId] = PoolConfig({
            beacon: beacon,
            asset: asset,
            ticker: ticker,
            assetDecimals: dec,
            enabled: true,
            exists: true,
            poolData: poolData
        });
        emit PoolAdded(poolId, beacon, asset, ticker);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setPoolEnabled(uint256 poolId, bool enabled) external override onlyAdmin {
        _requirePool(poolId).enabled = enabled;
        emit PoolEnabledSet(poolId, enabled);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setRiskParams(
        uint16 mcrBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps
    ) external override onlyAdmin {
        _validateRatios(mcrBps, liquidationThresholdBps, liquidationBonusBps);
        _riskParams.mcrBps = mcrBps;
        _riskParams.liquidationThresholdBps = liquidationThresholdBps;
        _riskParams.liquidationBonusBps = liquidationBonusBps;
        emit RiskParamsSet(mcrBps, liquidationThresholdBps, liquidationBonusBps);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setStabilityFees(uint16 stakedFeeBps, uint16 unstakedFeeBps) external override onlyAdmin {
        if (stakedFeeBps > BPS || unstakedFeeBps > BPS) revert InvalidRiskParams();
        // Settle the indexes at the old rates so the new rates apply only prospectively.
        _settleFeeIndexes();
        _riskParams.stakedFeeBps = stakedFeeBps;
        _riskParams.unstakedFeeBps = unstakedFeeBps;
        emit StabilityFeesSet(stakedFeeBps, unstakedFeeBps);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setPoolPriceBand(
        uint16 poolPriceBandBps
    ) external override onlyAdmin {
        if (poolPriceBandBps == 0 || poolPriceBandBps > BPS) revert InvalidRiskParams();
        _riskParams.poolPriceBandBps = poolPriceBandBps;
        emit PoolPriceBandSet(poolPriceBandBps);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setDebtCeiling(
        uint256 debtCeiling
    ) external override onlyAdmin {
        _riskParams.debtCeiling = debtCeiling;
        emit DebtCeilingSet(debtCeiling);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setMinDebt(
        uint256 minDebt
    ) external override onlyAdmin {
        _riskParams.minDebt = minDebt;
        emit MinDebtSet(minDebt);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setMintPriceMaxAge(
        uint256 mintPriceMaxAge
    ) external override onlyAdmin {
        if (mintPriceMaxAge == 0) revert InvalidRiskParams();
        _riskParams.mintPriceMaxAge = mintPriceMaxAge;
        emit MintPriceMaxAgeSet(mintPriceMaxAge);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function setMintPaused(
        bool paused
    ) external override onlyOperator {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — positions
    // ──────────────────────────────────────────────────────────

    /// @dev Revert unless the pool has been added. Does not check `enabled`.
    /// @param poolId Pool id.
    /// @return cfg The pool's configuration.
    function _requirePool(
        uint256 poolId
    ) private view returns (PoolConfig storage cfg) {
        cfg = _pools[poolId];
        if (!cfg.exists) revert PoolNotSupported(poolId);
    }

    /// @dev Revert unless the pool has been added and is enabled.
    /// @param poolId Pool id.
    /// @return cfg The pool's configuration.
    function _requireEnabledPool(
        uint256 poolId
    ) private view returns (PoolConfig storage cfg) {
        cfg = _requirePool(poolId);
        if (!cfg.enabled) revert PoolDisabled(poolId);
    }

    /// @dev The position's vault, or revert when it has none.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param p      The position.
    /// @return vault The vault.
    function _requireVault(uint256 poolId, address owner, Position storage p) private view returns (address vault) {
        vault = p.vault;
        if (vault == address(0)) revert NoVault(poolId, owner);
    }

    /// @dev The caller's vault, created on first use. A new position starts staked.
    /// @param poolId Pool id.
    /// @param cfg    The pool's configuration.
    /// @param p      The caller's position (accrued).
    /// @return vault The vault.
    function _vaultFor(uint256 poolId, PoolConfig storage cfg, Position storage p) private returns (address vault) {
        vault = p.vault;
        if (vault != address(0)) return vault;
        vault = address(
            new BeaconProxy(
                cfg.beacon,
                abi.encodeCall(ILiquidityVault.initialize, (msg.sender, cfg.asset, address(_eusd), cfg.poolData))
            )
        );
        p.vault = vault;
        p.staked = true;
        p.feeIndexSnapshot = _stakedFeeIndex;
        _owners[poolId].push(msg.sender);
        emit VaultCreated(poolId, msg.sender, vault);
    }

    /// @dev Put liquidity into the caller's range: mint the eUSD the vault lacks for `eusdMax`, add,
    ///      then burn the vault's leftover eUSD against the debt.
    /// @param poolId    Pool id.
    /// @param p         The caller's position (accrued).
    /// @param vault     The caller's vault.
    /// @param tickLower Lower tick.
    /// @param tickUpper Upper tick.
    /// @param assetMax  Most idle asset to use (asset units).
    /// @param eusdMax   Most eUSD to use (18 decimals).
    /// @return liquidity Liquidity added.
    function _add(
        uint256 poolId,
        Position storage p,
        address vault,
        int24 tickLower,
        int24 tickUpper,
        uint256 assetMax,
        uint256 eusdMax
    ) private returns (uint128 liquidity) {
        uint256 idleEusd = _eusd.balanceOf(vault);
        if (eusdMax > idleEusd) {
            uint256 minted = eusdMax - idleEusd;
            p.debt += minted;
            totalDebt += minted;
            _eusd.mint(vault, minted);
            emit EUSDMinted(poolId, msg.sender, minted, p.debt);
        }
        uint256 assetUsed;
        uint256 eusdUsed;
        (liquidity, assetUsed, eusdUsed) = ILiquidityVault(vault).addLiquidity(tickLower, tickUpper, assetMax, eusdMax);
        emit LiquidityAdded(poolId, msg.sender, tickLower, tickUpper, liquidity, assetUsed, eusdUsed);
        _burnIdle(poolId, msg.sender, p, vault);
    }

    /// @dev Remove liquidity into the vault.
    /// @param poolId    Pool id.
    /// @param owner     Position owner.
    /// @param vault     The position's vault.
    /// @param liquidity Liquidity to remove.
    /// @param assetMin  Least asset to receive (asset units).
    /// @param eusdMin   Least eUSD to receive (18 decimals).
    function _remove(
        uint256 poolId,
        address owner,
        address vault,
        uint128 liquidity,
        uint256 assetMin,
        uint256 eusdMin
    ) private {
        (uint256 assetOut, uint256 eusdOut) = ILiquidityVault(vault).removeLiquidity(liquidity, assetMin, eusdMin);
        emit LiquidityRemoved(poolId, owner, liquidity, assetOut, eusdOut);
    }

    /// @dev Burn the vault's eUSD against the debt, leaving the debt at zero or at least `minDebt`
    ///      (eUSD that cannot be burned stays in the vault, where it counts as collateral). Once
    ///      the debt is zero, any eUSD left goes to the owner.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param p      The position (accrued).
    /// @param vault  The position's vault.
    function _burnIdle(uint256 poolId, address owner, Position storage p, address vault) private {
        uint256 balance = _eusd.balanceOf(vault);
        if (balance == 0) return;
        uint256 debt = p.debt;
        uint256 burned = Math.min(balance, debt);
        uint256 minDebt = _riskParams.minDebt;
        if (debt - burned != 0 && debt - burned < minDebt) burned = debt > minDebt ? debt - minDebt : 0;
        if (burned > 0) {
            _reduceDebt(p, burned);
            _eusd.burn(vault, burned);
            emit DebtRepaid(poolId, owner, vault, burned, debt - burned);
        }
        if (p.debt == 0 && balance > burned) {
            ILiquidityVault(vault).transferToken(address(_eusd), owner, balance - burned);
        }
    }

    /// @dev Retire `amount` of a position's debt, fees first.
    /// @param p      The position.
    /// @param amount Debt retired (18 decimals, at most the debt).
    function _reduceDebt(Position storage p, uint256 amount) private {
        p.debt -= amount;
        p.feesAccrued -= Math.min(amount, p.feesAccrued);
        totalDebt -= amount;
    }

    /// @dev Oracle price (with the pool price inside the band) and health before a liquidity change.
    /// @param cfg   The pool's configuration.
    /// @param p     The position (accrued).
    /// @param vault The position's vault.
    /// @return snap The snapshot.
    function _snapshot(
        PoolConfig storage cfg,
        Position storage p,
        address vault
    ) private view returns (HealthSnapshot memory snap) {
        (snap.price, snap.timestamp) = _oracle().getPrice(cfg.ticker);
        uint256 pool = ILiquidityVault(vault).poolPrice();
        uint256 gap = pool > snap.price ? pool - snap.price : snap.price - pool;
        if (gap * BPS > snap.price * _riskParams.poolPriceBandBps) revert PoolPriceOutOfBand(pool, snap.price);
        snap.debt = p.debt;
        snap.ratioBps = _ratioBps(_value(cfg, vault, snap.price), snap.debt);
    }

    /// @dev Health rule after a liquidity change (see {IEUSDLiquidityManager}), at the snapshot price.
    /// @param cfg    The pool's configuration.
    /// @param p      The position after the change.
    /// @param vault  The position's vault.
    /// @param before Snapshot taken before the change.
    function _checkHealth(
        PoolConfig storage cfg,
        Position storage p,
        address vault,
        HealthSnapshot memory before
    ) private view {
        uint256 debt = p.debt;
        uint256 mcr = _riskParams.mcrBps;
        uint256 ratio = _ratioBps(_value(cfg, vault, before.price), debt);
        if (debt > before.debt) {
            if (mintPaused) revert MintingPaused();
            uint256 maxAge = _riskParams.mintPriceMaxAge;
            if (block.timestamp > before.timestamp + maxAge) revert StaleMintPrice(before.timestamp, maxAge);
            if (debt < _riskParams.minDebt) revert BelowMinimumDebt(debt, _riskParams.minDebt);
            if (totalDebt > _riskParams.debtCeiling) revert DebtCeilingExceeded(totalDebt, _riskParams.debtCeiling);
            if (ratio < mcr) revert CollateralRatioTooLow(ratio, mcr);
        } else if (ratio < mcr && ratio < before.ratioBps) {
            revert CollateralRatioTooLow(ratio, Math.min(mcr, before.ratioBps));
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — fees
    // ──────────────────────────────────────────────────────────

    /// @dev Settle both fee indexes up to now at the current rates.
    function _settleFeeIndexes() private {
        uint256 elapsed = block.timestamp - _feeIndexUpdated;
        if (elapsed > 0) {
            _stakedFeeIndex += uint256(_riskParams.stakedFeeBps) * elapsed;
            _unstakedFeeIndex += uint256(_riskParams.unstakedFeeBps) * elapsed;
            _feeIndexUpdated = block.timestamp;
        }
    }

    /// @dev Fold a position's pending stability fee into its debt and mint it to the treasury.
    ///      EUSD has no transfer hooks, and every caller holds the reentrancy guard.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @return p The position, with its debt brought up to date.
    function _accrue(uint256 poolId, address owner) private returns (Position storage p) {
        _settleFeeIndexes();
        p = _positions[poolId][owner];
        uint256 index = p.staked ? _stakedFeeIndex : _unstakedFeeIndex;
        if (p.debt > 0 && index > p.feeIndexSnapshot) {
            // Charged on principal only, so the fee is simple interest however often it accrues.
            uint256 fee = Math.mulDiv(p.debt - p.feesAccrued, index - p.feeIndexSnapshot, BPS * YEAR);
            if (fee > 0) {
                p.debt += fee;
                p.feesAccrued += fee;
                totalDebt += fee;
                _eusd.mint(registry.treasury(), fee);
                emit StabilityFeeAccrued(poolId, owner, fee);
            }
        }
        p.feeIndexSnapshot = index;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — pricing
    // ──────────────────────────────────────────────────────────

    /// @dev The oracle, resolved through the registry.
    /// @return The current oracle.
    function _oracle() private view returns (IOracleVerifier) {
        return IOracleVerifier(registry.oracle());
    }

    /// @dev Oracle price no older than `mintPriceMaxAge`. A future timestamp counts as current.
    /// @param ticker Oracle ticker.
    /// @return price Price (18 decimals).
    function _freshPrice(
        bytes32 ticker
    ) private view returns (uint256 price) {
        uint256 ts;
        (price, ts) = _oracle().getPrice(ticker);
        uint256 maxAge = _riskParams.mintPriceMaxAge;
        if (block.timestamp > ts + maxAge) revert StaleMintPrice(ts, maxAge);
    }

    /// @dev Value of a vault at `price`: asset at the price plus eUSD at $1 (18 decimals).
    /// @param cfg   The pool's configuration.
    /// @param vault The vault.
    /// @param price Asset price (18 decimals).
    /// @return Value (18 decimals).
    function _value(PoolConfig storage cfg, address vault, uint256 price) private view returns (uint256) {
        (uint256 assetAmount, uint256 eusdAmount) = ILiquidityVault(vault).holdings(price);
        return _assetValue(cfg, assetAmount, price) + eusdAmount;
    }

    /// @dev Value of an asset amount at `price`. Rounds down.
    /// @param cfg    The pool's configuration.
    /// @param amount Asset amount (asset units).
    /// @param price  Asset price (18 decimals).
    /// @return Value (18 decimals).
    function _assetValue(PoolConfig storage cfg, uint256 amount, uint256 price) private view returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** cfg.assetDecimals);
    }

    /// @dev Collateral ratio in BPS. Floor rounding: measured ratios err against the debtor.
    /// @param value Collateral value (18 decimals).
    /// @param debt  Debt (18 decimals).
    /// @return Ratio in BPS (type(uint256).max when debt is 0).
    function _ratioBps(uint256 value, uint256 debt) private pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(value, BPS, debt);
    }

    /// @dev Require mcr ≥ threshold (a fresh mint is never liquidatable) and threshold ≥ 1 + bonus
    ///      (a liquidation at the threshold is solvent).
    /// @param mcrBps                  Min collateral ratio (BPS).
    /// @param liquidationThresholdBps Liquidation threshold (BPS).
    /// @param liquidationBonusBps     Liquidation bonus (BPS).
    function _validateRatios(uint16 mcrBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps) private pure {
        if (mcrBps < liquidationThresholdBps || uint256(liquidationThresholdBps) < BPS + liquidationBonusBps) {
            revert InvalidRiskParams();
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDLiquidityManager
    function eusd() external view override returns (address) {
        return address(_eusd);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function riskParams() external view override returns (RiskParams memory) {
        return _riskParams;
    }

    /// @inheritdoc IEUSDLiquidityManager
    function poolConfig(
        uint256 poolId
    ) external view override returns (PoolConfig memory) {
        return _pools[poolId];
    }

    /// @inheritdoc IEUSDLiquidityManager
    function getPosition(uint256 poolId, address owner) external view override returns (Position memory) {
        return _positions[poolId][owner];
    }

    /// @inheritdoc IEUSDLiquidityManager
    function positionCount(
        uint256 poolId
    ) external view override returns (uint256) {
        return _owners[poolId].length;
    }

    /// @inheritdoc IEUSDLiquidityManager
    function positionOwnerAt(uint256 poolId, uint256 index) external view override returns (address) {
        return _owners[poolId][index];
    }

    /// @inheritdoc IEUSDLiquidityManager
    function currentDebt(uint256 poolId, address owner) public view override returns (uint256) {
        Position storage p = _positions[poolId][owner];
        if (p.debt == 0) return 0;
        return p.debt + Math.mulDiv(p.debt - p.feesAccrued, globalFeeIndex(p.staked) - p.feeIndexSnapshot, BPS * YEAR);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function collateralValue(uint256 poolId, address owner) public view override returns (uint256) {
        address vault = _positions[poolId][owner].vault;
        if (vault == address(0)) return 0;
        PoolConfig storage cfg = _pools[poolId];
        (uint256 price,) = _oracle().getPrice(cfg.ticker);
        return _value(cfg, vault, price);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function collateralRatioBps(uint256 poolId, address owner) public view override returns (uint256) {
        uint256 debt = currentDebt(poolId, owner);
        if (debt == 0) return type(uint256).max;
        return _ratioBps(collateralValue(poolId, owner), debt);
    }

    /// @inheritdoc IEUSDLiquidityManager
    function isLiquidatable(uint256 poolId, address owner) external view override returns (bool) {
        return collateralRatioBps(poolId, owner) < _riskParams.liquidationThresholdBps;
    }

    /// @inheritdoc IEUSDLiquidityManager
    function globalFeeIndex(
        bool staked
    ) public view override returns (uint256) {
        uint256 elapsed = block.timestamp - _feeIndexUpdated;
        if (staked) return _stakedFeeIndex + uint256(_riskParams.stakedFeeBps) * elapsed;
        return _unstakedFeeIndex + uint256(_riskParams.unstakedFeeBps) * elapsed;
    }
}
