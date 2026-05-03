// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBorrowDebt} from "../interfaces/IBorrowDebt.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultBorrowCoordinator} from "../interfaces/IVaultBorrowCoordinator.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";

import {BPS} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultBorrowCoordinator — Shared debt + utilization + rate oracle
/// @notice One per vault. Sums outstanding debt across all registered borrow
///         managers, exposes a unified `utilizationBps` derived from the
///         vault's collateral (× `targetLtvBps`), and serves the live Aave
///         rate. Borrow managers consult it on every state-changing call.
contract VaultBorrowCoordinator is IVaultBorrowCoordinator {
    using Math for uint256;

    /// @dev Aave V3 uses RAY (1e27) for rate scaling.
    uint256 internal constant RAY = 1e27;

    address public immutable override vault;
    address public immutable override aavePool;
    IProtocolRegistry public immutable registry;

    address public override stablecoin;
    uint256 public override targetLtvBps;

    address[] internal _managers;
    mapping(address => bool) internal _isManager;

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    constructor(address vault_, address aavePool_, address registry_, address stablecoin_, uint256 targetLtvBps_) {
        if (vault_ == address(0) || aavePool_ == address(0) || registry_ == address(0) || stablecoin_ == address(0)) {
            revert ZeroAddress();
        }
        if (targetLtvBps_ == 0 || targetLtvBps_ >= BPS) revert InvalidLtv();
        vault = vault_;
        aavePool = aavePool_;
        registry = IProtocolRegistry(registry_);
        stablecoin = stablecoin_;
        targetLtvBps = targetLtvBps_;
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultBorrowCoordinator
    function registerManager(
        address manager
    ) external onlyAdmin {
        if (manager == address(0)) revert ZeroAddress();
        if (_isManager[manager]) revert ManagerAlreadyRegistered(manager);
        _isManager[manager] = true;
        _managers.push(manager);
        emit ManagerRegistered(manager);
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function deregisterManager(
        address manager
    ) external onlyAdmin {
        if (!_isManager[manager]) revert ManagerNotRegistered(manager);
        _isManager[manager] = false;
        // Swap-and-pop. Order is unimportant.
        uint256 len = _managers.length;
        for (uint256 i; i < len;) {
            if (_managers[i] == manager) {
                _managers[i] = _managers[len - 1];
                _managers.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        emit ManagerDeregistered(manager);
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function setTargetLtvBps(
        uint256 ltvBps
    ) external onlyAdmin {
        if (ltvBps == 0 || ltvBps >= BPS) revert InvalidLtv();
        emit TargetLtvBpsUpdated(targetLtvBps, ltvBps);
        targetLtvBps = ltvBps;
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function setStablecoin(
        address stablecoin_
    ) external onlyAdmin {
        if (stablecoin_ == address(0)) revert ZeroAddress();
        emit StablecoinUpdated(stablecoin, stablecoin_);
        stablecoin = stablecoin_;
    }

    // ──────────────────────────────────────────────────────────
    //  Hard cap
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultBorrowCoordinator
    function preBorrowCheck(
        uint256 additionalUSD
    ) external view {
        uint256 cap = maxDebtUSD();
        uint256 projected = totalDebtUSD() + additionalUSD;
        if (projected > cap) revert BorrowExceedsCap(projected, cap);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultBorrowCoordinator
    function totalDebtUSD() public view returns (uint256 total) {
        uint256 len = _managers.length;
        for (uint256 i; i < len;) {
            total += IBorrowDebt(_managers[i]).totalDebtUSD();
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function maxDebtUSD() public view returns (uint256) {
        return IOwnVault(vault).collateralValueUSD().mulDiv(targetLtvBps, BPS);
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function utilizationBps() external view returns (uint256) {
        uint256 cap = maxDebtUSD();
        if (cap == 0) return 0;
        uint256 util = totalDebtUSD().mulDiv(BPS, cap);
        return util > BPS ? BPS : util;
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function liveAaveRateBps() external view returns (uint256) {
        IAaveV3Pool.ReserveDataLegacy memory data = IAaveV3Pool(aavePool).getReserveData(stablecoin);
        return uint256(data.currentVariableBorrowRate).mulDiv(BPS, RAY);
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function isManager(
        address manager
    ) external view returns (bool) {
        return _isManager[manager];
    }

    /// @inheritdoc IVaultBorrowCoordinator
    function managers() external view returns (address[] memory) {
        return _managers;
    }
}
