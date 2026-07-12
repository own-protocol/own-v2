// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBorrowManager} from "../interfaces/IBorrowManager.sol";
import {IOwnLendingPool} from "../interfaces/IOwnLendingPool.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultYieldManager} from "../interfaces/IVaultYieldManager.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VaultYieldManager — automated LP yield distribution shell
/// @notice Installed as an OwnVault's `manager` via `OwnVault.setManager`, so every
///         BorrowManager revenue flow (premium sweeps on repay, dividend sweeps,
///         mid-term interest claims) pays stablecoin to this contract. {distribute}
///         is a permissionless crank that splits the held balance: `treasuryCutBps`
///         to `ProtocolRegistry.treasury()`, remainder converted 1:1 into the
///         vault's aToken via `OwnLendingPool.supply` and pushed to LPs through
///         `OwnVault.shareYield`.
///
///         Holds no state between transactions except undistributed revenue.
///         Installation is reversible: `setManager` back to an EOA removes it.
contract VaultYieldManager is IVaultYieldManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @notice ProtocolRegistry used for roles and the treasury address.
    IProtocolRegistry public immutable registry;

    /// @inheritdoc IVaultYieldManager
    address public immutable override vault;

    /// @inheritdoc IVaultYieldManager
    address public immutable override pool;

    /// @inheritdoc IVaultYieldManager
    address public immutable override stablecoin;

    /// @dev The pool's aToken == the vault's ERC-4626 asset (asserted in the constructor).
    address private immutable _aToken;

    /// @inheritdoc IVaultYieldManager
    uint256 public override treasuryCutBps;

    /// @inheritdoc IVaultYieldManager
    address public override manager;

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    modifier onlyOperatorOrManager() {
        if (msg.sender != manager && !registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperatorOrManager();
        _;
    }

    /// @param registry_       ProtocolRegistry (roles + treasury).
    /// @param vault_          OwnVault this shell manages.
    /// @param pool_           OwnLendingPool for 1:1 stablecoin → aToken conversion.
    /// @param manager_        Shell manager (the VM entity driving the deposit queue).
    /// @param treasuryCutBps_ Treasury share of revenue (BPS, <= 10_000).
    constructor(address registry_, address vault_, address pool_, address manager_, uint256 treasuryCutBps_) {
        if (registry_ == address(0) || vault_ == address(0) || pool_ == address(0) || manager_ == address(0)) {
            revert ZeroAddress();
        }
        if (treasuryCutBps_ > BPS) revert InvalidTreasuryCut(treasuryCutBps_);

        address vaultAsset = IERC4626(vault_).asset();
        address poolAToken = IOwnLendingPool(pool_).aToken();
        if (vaultAsset != poolAToken) revert AssetMismatch(vaultAsset, poolAToken);

        registry = IProtocolRegistry(registry_);
        vault = vault_;
        pool = pool_;
        stablecoin = IOwnLendingPool(pool_).underlying();
        _aToken = poolAToken;
        manager = manager_;
        treasuryCutBps = treasuryCutBps_;

        // One-time approvals: the pool pulls stablecoin on supply; the vault pulls
        // the aToken on shareYield.
        IERC20(stablecoin).forceApprove(pool_, type(uint256).max);
        IERC20(poolAToken).forceApprove(vault_, type(uint256).max);

        emit TreasuryCutUpdated(0, treasuryCutBps_);
        emit ManagerUpdated(address(0), manager_);
    }

    // ──────────────────────────────────────────────────────────
    //  Distribution
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultYieldManager
    function distribute() external override nonReentrant {
        uint256 balance = IERC20(stablecoin).balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute();
        // Yield with no shares outstanding would accrue to the first depositor —
        // hold revenue until LPs exist (mirrors OwnVault.shareYield's own guard).
        if (IERC4626(vault).totalSupply() == 0) revert NoSharesOutstanding();

        address treasury = registry.treasury();
        if (treasury == address(0)) revert ZeroAddress();

        // Floor the treasury cut — split dust favors LPs.
        uint256 treasuryCut = balance * treasuryCutBps / BPS;
        uint256 lpYield = balance - treasuryCut;

        if (treasuryCut > 0) IERC20(stablecoin).safeTransfer(treasury, treasuryCut);
        if (lpYield > 0) {
            // Lossless 1:1 conversion: the pool mints its aToken 1:1 for the underlying.
            IOwnLendingPool(pool).supply(stablecoin, lpYield, address(this), 0);
            IOwnVault(vault).shareYield(lpYield);
        }

        emit YieldDistributed(msg.sender, treasuryCut, lpYield);
    }

    /// @inheritdoc IVaultYieldManager
    /// @dev Permissionless by design: the claim amount is capped and HF-gated by the
    ///      BorrowManager, and the proceeds land here where {distribute} is the only
    ///      exit — a caller can only accelerate yield realization.
    function claimEarnedInterest(
        uint256 amount
    ) external override nonReentrant {
        address borrowManager = IOwnVault(vault).borrowManager();
        if (borrowManager == address(0)) revert ZeroAddress();
        IBorrowManager(borrowManager).claimEarnedInterest(amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Manager passthroughs
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultYieldManager
    function acceptDeposit(
        uint256 requestId
    ) external override onlyManager {
        IOwnVault(vault).acceptDeposit(requestId);
    }

    /// @inheritdoc IVaultYieldManager
    function rejectDeposit(
        uint256 requestId
    ) external override onlyManager {
        IOwnVault(vault).rejectDeposit(requestId);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin / ops
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultYieldManager
    function setTreasuryCutBps(
        uint256 bps
    ) external override onlyAdmin {
        if (bps > BPS) revert InvalidTreasuryCut(bps);
        uint256 old = treasuryCutBps;
        treasuryCutBps = bps;
        emit TreasuryCutUpdated(old, bps);
    }

    /// @inheritdoc IVaultYieldManager
    function setManager(
        address newManager
    ) external override onlyAdmin {
        if (newManager == address(0)) revert ZeroAddress();
        address old = manager;
        manager = newManager;
        emit ManagerUpdated(old, newManager);
    }

    /// @inheritdoc IVaultYieldManager
    function rescueToken(address token, address to) external override onlyOperatorOrManager {
        if (to == address(0)) revert ZeroAddress();
        // Revenue exits only through distribute() — never via rescue.
        if (token == stablecoin) revert CannotRescueRevenue(token);
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultYieldManager
    function pendingYield() external view override returns (uint256) {
        return IERC20(stablecoin).balanceOf(address(this));
    }
}
