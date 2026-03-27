// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFeeAccrual} from "../interfaces/IFeeAccrual.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeAccrual — Protocol fee collection and three-way distribution
/// @notice Collects fees from OwnMarket, splits them between protocol treasury,
///         LPs (per vault), and VMs. Each party claims their accrued balance.
contract FeeAccrual is IFeeAccrual, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol's share of all fees in BPS.
    uint256 private _protocolShareBps;

    /// @notice VM's share of the LP+VM remainder, per vault, in BPS.
    mapping(address => uint256) private _vmShareBps;

    /// @notice Accrued unclaimed protocol fees per token.
    mapping(address => uint256) private _protocolFees;

    /// @notice Accrued unclaimed VM fees per (vm, token).
    mapping(address => mapping(address => uint256)) private _vmFees;

    /// @notice Accrued unclaimed LP fees per (vault, token).
    mapping(address => mapping(address => uint256)) private _lpFees;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin_    Initial owner / admin address.
    /// @param registry_ ProtocolRegistry contract address.
    /// @param protocolShareBps_ Initial protocol share in BPS.
    constructor(address admin_, address registry_, uint256 protocolShareBps_) Ownable(admin_) {
        if (registry_ == address(0)) revert ZeroAddress();
        if (protocolShareBps_ > BPS) revert ShareTooHigh(protocolShareBps_, BPS);
        registry = IProtocolRegistry(registry_);
        _protocolShareBps = protocolShareBps_;
    }

    // ──────────────────────────────────────────────────────────
    //  Fee accrual
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAccrual
    function accrueFee(address vault, address vm, uint256 amount, address token) external onlyMarket {
        if (amount == 0) return;

        // Protocol takes its cut first (round up — protocol-favorable)
        uint256 protocolAmount = Math.mulDiv(amount, _protocolShareBps, BPS, Math.Rounding.Ceil);
        uint256 remainder = amount - protocolAmount;

        // VM takes its share of the remainder (round down — LP-favorable)
        uint256 vmAmount = Math.mulDiv(remainder, _vmShareBps[vault], BPS);
        uint256 lpAmount = remainder - vmAmount;

        // Accrue balances
        _protocolFees[token] += protocolAmount;
        _vmFees[vm][token] += vmAmount;
        _lpFees[vault][token] += lpAmount;

        emit FeeAccrued(vault, vm, token, amount, protocolAmount, lpAmount, vmAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  Claims
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAccrual
    function claimProtocolFees(
        address token
    ) external nonReentrant {
        uint256 amount = _protocolFees[token];
        if (amount == 0) revert NoFeesToClaim();

        _protocolFees[token] = 0;
        IERC20(token).safeTransfer(registry.treasury(), amount);

        emit ProtocolFeesClaimed(token, amount);
    }

    /// @inheritdoc IFeeAccrual
    function claimLPFees(address vault, address token) external nonReentrant {
        uint256 amount = _lpFees[vault][token];
        if (amount == 0) revert NoFeesToClaim();

        _lpFees[vault][token] = 0;

        // Transfer to vault — increases totalAssets(), share price goes up
        IERC20(token).safeTransfer(vault, amount);

        emit LPFeesClaimed(vault, token, amount);
    }

    /// @inheritdoc IFeeAccrual
    function claimVMFees(
        address token
    ) external nonReentrant {
        uint256 amount = _vmFees[msg.sender][token];
        if (amount == 0) revert NoFeesToClaim();

        _vmFees[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit VMFeesClaimed(msg.sender, token, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin configuration
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAccrual
    function setProtocolShareBps(
        uint256 shareBps
    ) external onlyOwner {
        if (shareBps > BPS) revert ShareTooHigh(shareBps, BPS);

        uint256 oldShare = _protocolShareBps;
        _protocolShareBps = shareBps;

        emit ProtocolShareUpdated(oldShare, shareBps);
    }

    /// @inheritdoc IFeeAccrual
    function setVMShareBps(address vault, uint256 shareBps) external {
        // Only the vault's VM can set their share
        address vaultVM = IVaultManager(registry.vaultManager()).getVaultVM(vault);
        if (msg.sender != vaultVM) revert OnlyVaultVM(vault);
        if (shareBps > BPS) revert ShareTooHigh(shareBps, BPS);

        uint256 oldShare = _vmShareBps[vault];
        _vmShareBps[vault] = shareBps;

        emit VMShareUpdated(vault, oldShare, shareBps);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAccrual
    function protocolShareBps() external view returns (uint256) {
        return _protocolShareBps;
    }

    /// @inheritdoc IFeeAccrual
    function vmShareBps(
        address vault
    ) external view returns (uint256) {
        return _vmShareBps[vault];
    }

    /// @inheritdoc IFeeAccrual
    function accruedProtocolFees(
        address token
    ) external view returns (uint256) {
        return _protocolFees[token];
    }

    /// @inheritdoc IFeeAccrual
    function accruedLPFees(address vault, address token) external view returns (uint256) {
        return _lpFees[vault][token];
    }

    /// @inheritdoc IFeeAccrual
    function accruedVMFees(address vm, address token) external view returns (uint256) {
        return _vmFees[vm][token];
    }
}
