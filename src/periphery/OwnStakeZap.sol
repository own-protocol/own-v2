// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSDManager} from "../interfaces/IEUSDManager.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnStakeZap} from "../interfaces/IOwnStakeZap.sol";
import {IOwnStakingV2} from "../interfaces/IOwnStakingV2.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OwnStakeZap — one-transaction routes into OwnStakingV2
/// @notice Collapses the basket flows (swap, PSM-mint, CDP deposit, eUSD mint, dual-asset stake)
///         into single transactions. Holds standing user approvals but never funds between
///         transactions. Every entry runs on real amounts inside one transaction and reverts
///         whole if any leg fails, so nothing is ever quoted or stranded.
/// @dev Runs behind an ERC-1967 proxy (UUPS) so the zap address — and every user approval
///      granted to it — survives upgrades; upgrades are ADMIN-gated via ProtocolRegistry roles
///      and storage is append-only across upgrades. Trust model: the swap leg is the only
///      dangerous surface. It is confined to the ADMIN-set `swapRouter` with an exact
///      just-in-time allowance that is reset after the call — user-supplied `swapData` can
///      therefore spend at most the caller's own in-flight SPY slice, never another user's
///      approval. On-behalf CDP surfaces ({IEUSDManager.depositFor}/{mintFor}) and staking
///      surfaces ({IOwnStakingV2.unstakeFor}/{claimFor}) only accept this contract, and every
///      entry passes `msg.sender` as the owner, so the zap can only ever act on the caller's own
///      position.
contract OwnStakeZap is IOwnStakeZap, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    bytes32 private constant ADMIN = keccak256("ADMIN");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve the ADMIN role.
    /// @dev Initializer-set, fixed thereafter (storage, not immutable, so an upgraded
    ///      implementation can never silently rebind it).
    IProtocolRegistry public registry;

    /// @dev Protocol wiring. Initializer-set; only the swap router is ADMIN-rotatable.
    IEUSDManager private _eusdManager;
    IOwnStakingV2 private _staking;
    IOwnMarket private _market;
    IERC4626 private _sEusd;
    IERC20 private _eusd;
    IERC20 private _money;
    IERC20 private _spy;
    IERC20 private _collateral;
    bytes32 private _collateralTicker;
    address private _swapRouter;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev The implementation is only ever used behind an ERC-1967 proxy; lock its own
    ///      initializers so the bare implementation can never be initialized or taken over.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the zap proxy (runs once, in the proxy's constructor call).
    /// @param cfg Full protocol wiring — see {IOwnStakeZap.InitConfig}.
    function initialize(
        InitConfig calldata cfg
    ) external initializer {
        if (
            cfg.registry == address(0) || cfg.eusdManager == address(0) || cfg.staking == address(0)
                || cfg.market == address(0) || cfg.sEusd == address(0) || cfg.eusd == address(0) || cfg.money == address(0)
                || cfg.spy == address(0) || cfg.collateral == address(0) || cfg.swapRouter == address(0)
        ) revert ZeroAddress();
        registry = IProtocolRegistry(cfg.registry);
        _eusdManager = IEUSDManager(cfg.eusdManager);
        _staking = IOwnStakingV2(cfg.staking);
        _market = IOwnMarket(cfg.market);
        _sEusd = IERC4626(cfg.sEusd);
        _eusd = IERC20(cfg.eusd);
        _money = IERC20(cfg.money);
        _spy = IERC20(cfg.spy);
        _collateral = IERC20(cfg.collateral);
        _collateralTicker = cfg.collateralTicker;
        _swapRouter = cfg.swapRouter;
        emit SwapRouterSet(cfg.swapRouter);

        // Standing approvals to the fixed protocol contracts the zap routes through. The router
        // deliberately gets none — its allowance is exact and per-swap.
        IERC20(cfg.spy).forceApprove(cfg.market, type(uint256).max);
        IERC20(cfg.collateral).forceApprove(cfg.eusdManager, type(uint256).max);
        IERC20(cfg.money).forceApprove(cfg.staking, type(uint256).max);
        IERC20(cfg.eusd).forceApprove(cfg.staking, type(uint256).max);
    }

    /// @dev UUPS upgrade gate: ADMIN (via ProtocolRegistry) only.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

    // ──────────────────────────────────────────────────────────
    //  Entries
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakeZap
    function stakeFromSpy(
        uint256 spyAmount,
        uint256 spyForMoney,
        uint256 minMoneyOut,
        bytes calldata swapData,
        uint256 eusdToMint,
        address hint
    ) external override nonReentrant {
        if (spyAmount == 0) revert ZeroAmount();
        if (spyForMoney > spyAmount) revert InvalidSplit(spyForMoney, spyAmount);
        _spy.safeTransferFrom(msg.sender, address(this), spyAmount);

        uint256 moneyOut;
        if (spyForMoney != 0) {
            // A zero floor would let a sandwich take the whole slice; force the caller (the app)
            // to state one.
            if (minMoneyOut == 0) revert ZeroAmount();
            uint256 moneyBefore = _money.balanceOf(address(this));
            _spy.forceApprove(_swapRouter, spyForMoney);
            (bool ok,) = _swapRouter.call(swapData);
            if (!ok) revert SwapFailed();
            // The router may legitimately pull less than the slice; never leave an allowance.
            _spy.forceApprove(_swapRouter, 0);
            moneyOut = _money.balanceOf(address(this)) - moneyBefore;
            if (moneyOut < minMoneyOut) revert InsufficientMoneyOut(moneyOut, minMoneyOut);
        }

        // PSM-mint the full remaining SPY balance: a partial router pull becomes extra
        // collateral for the caller rather than dust stranded on the zap.
        _buildCdpAndStake(spyAmount, _spy.balanceOf(address(this)), moneyOut, eusdToMint, hint);
    }

    /// @inheritdoc IOwnStakeZap
    function stakeFromSpyAndMoney(
        uint256 spyAmount,
        uint256 moneyAmount,
        uint256 eusdToMint,
        address hint
    ) external override nonReentrant {
        if (spyAmount == 0) revert ZeroAmount();
        _spy.safeTransferFrom(msg.sender, address(this), spyAmount);
        if (moneyAmount != 0) _money.safeTransferFrom(msg.sender, address(this), moneyAmount);
        _buildCdpAndStake(spyAmount, spyAmount, moneyAmount, eusdToMint, hint);
    }

    /// @inheritdoc IOwnStakeZap
    function stakeFromEusdAndMoney(uint256 eusdAmount, uint256 moneyAmount) external override nonReentrant {
        if (eusdAmount == 0 && moneyAmount == 0) revert ZeroAmount();
        if (eusdAmount != 0) _eusd.safeTransferFrom(msg.sender, address(this), eusdAmount);
        if (moneyAmount != 0) _money.safeTransferFrom(msg.sender, address(this), moneyAmount);
        _staking.stakeFor(msg.sender, moneyAmount, eusdAmount);
        emit ZapStaked(msg.sender, 0, moneyAmount, eusdAmount);
    }

    /// @inheritdoc IOwnStakeZap
    function stakeFromSeusd(uint256 shares, uint256 moneyAmount) external override nonReentrant {
        if (shares == 0) revert ZeroAmount();
        // Instant ERC-4626 exit; requires the caller's sEUSD approval to the zap.
        uint256 eusdOut = _sEusd.redeem(shares, address(this), msg.sender);
        if (moneyAmount != 0) _money.safeTransferFrom(msg.sender, address(this), moneyAmount);
        _staking.stakeFor(msg.sender, moneyAmount, eusdOut);
        emit Migrated(msg.sender, shares, eusdOut, moneyAmount);
    }

    /// @inheritdoc IOwnStakeZap
    function compound(
        address hint
    ) external override nonReentrant {
        uint256 spyOut = _staking.claimFor(msg.sender);
        if (spyOut == 0) revert NothingToCompound();
        uint256 minted = _market.psmMint(_collateralTicker, address(_spy), spyOut);
        _eusdManager.depositFor(msg.sender, address(_collateral), minted, hint);
        emit Compounded(msg.sender, spyOut, minted);
    }

    /// @inheritdoc IOwnStakeZap
    function rebalance(uint256 eusdAmount, address hint) external override nonReentrant {
        if (eusdAmount == 0) revert ZeroAmount();
        _staking.unstakeFor(msg.sender, 0, eusdAmount);
        // Repay burns from this contract's balance, capped at the position's debt.
        _eusdManager.repay(address(_collateral), msg.sender, eusdAmount, hint);
        uint256 leftover = _eusd.balanceOf(address(this));
        if (leftover != 0) _eusd.safeTransfer(msg.sender, leftover);
        emit Rebalanced(msg.sender, eusdAmount, eusdAmount - leftover, leftover);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakeZap
    function setSwapRouter(
        address swapRouter_
    ) external override onlyAdmin {
        if (swapRouter_ == address(0)) revert ZeroAddress();
        _swapRouter = swapRouter_;
        emit SwapRouterSet(swapRouter_);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Shared tail of the SPY entries: PSM-mint `spyToPsm` into collateral, deposit it into
    ///      the caller's CDP, mint `eusdToMint` against it (paid to the zap) and stake both legs
    ///      for the caller.
    function _buildCdpAndStake(
        uint256 spyIn,
        uint256 spyToPsm,
        uint256 moneyAmount,
        uint256 eusdToMint,
        address hint
    ) private {
        uint256 minted = _market.psmMint(_collateralTicker, address(_spy), spyToPsm);
        _eusdManager.depositFor(msg.sender, address(_collateral), minted, hint);
        if (eusdToMint != 0) {
            _eusdManager.mintFor(msg.sender, address(_collateral), eusdToMint, hint);
        }
        if (moneyAmount != 0 || eusdToMint != 0) {
            _staking.stakeFor(msg.sender, moneyAmount, eusdToMint);
        }
        emit ZapStaked(msg.sender, spyIn, moneyAmount, eusdToMint);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakeZap
    function eusdManager() external view override returns (address) {
        return address(_eusdManager);
    }

    /// @inheritdoc IOwnStakeZap
    function staking() external view override returns (address) {
        return address(_staking);
    }

    /// @inheritdoc IOwnStakeZap
    function market() external view override returns (address) {
        return address(_market);
    }

    /// @inheritdoc IOwnStakeZap
    function sEusd() external view override returns (address) {
        return address(_sEusd);
    }

    /// @inheritdoc IOwnStakeZap
    function collateral() external view override returns (address) {
        return address(_collateral);
    }

    /// @inheritdoc IOwnStakeZap
    function collateralTicker() external view override returns (bytes32) {
        return _collateralTicker;
    }

    /// @inheritdoc IOwnStakeZap
    function swapRouter() external view override returns (address) {
        return _swapRouter;
    }
}
