// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";
import {BPS} from "../interfaces/types/Types.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StakingVault — fixed-APR staking vault (seUSD, sMONEY)
/// @notice One deployment per staked asset. Stakers deposit the asset for shares; rewards in the
///         same asset drip from a pre-funded reserve into staked assets, so the share price rises
///         and there is nothing to claim. See {IStakingVault} for the drip rule.
/// @dev Staked assets are tracked in `_staked`, not read from the balance, so the reserve and any
///      direct transfers never count toward the share price. Accrual is simple interest on
///      `_staked` between touches, and every state change accrues first, so a new rate only ever
///      applies from the moment it is set. Not upgradeable: a changed design is a new vault.
contract StakingVault is IStakingVault, ERC4626 {
    using SafeERC20 for IERC20;

    uint256 private constant YEAR = 365 days;
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @notice ProtocolRegistry used to resolve the ADMIN role.
    IProtocolRegistry public immutable registry;

    /// @inheritdoc IStakingVault
    uint256 public override aprBps;

    /// @inheritdoc IStakingVault
    uint256 public override cap;

    /// @dev Assets owned by shareholders: deposits plus accrued rewards, minus withdrawals.
    uint256 private _staked;

    /// @dev Unspent reward reserve as of `_lastAccrual`.
    uint256 private _reserve;

    uint256 private _lastAccrual;

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @param asset_    Staked and reward asset (eUSD or $MONEY).
    /// @param name_     Share token name.
    /// @param symbol_   Share token symbol.
    /// @param registry_ ProtocolRegistry holding the ADMIN role.
    /// @param aprBps_   Target APR in BPS.
    /// @param cap_      Staked amount that earns the full APR (asset units).
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address registry_,
        uint256 aprBps_,
        uint256 cap_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (address(asset_) == address(0) || registry_ == address(0)) revert ZeroAddress();
        if (aprBps_ > BPS) revert InvalidApr();
        registry = IProtocolRegistry(registry_);
        aprBps = aprBps_;
        cap = cap_;
        _lastAccrual = block.timestamp;
        emit AprSet(aprBps_);
        emit CapSet(cap_);
    }

    // ──────────────────────────────────────────────────────────
    //  Reserve
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IStakingVault
    function fund(
        uint256 amount
    ) external override {
        if (amount == 0) revert ZeroAmount();
        // Accrue first so an empty reserve never back-pays the time it was empty.
        _accrue();
        _reserve += amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    /// @inheritdoc IStakingVault
    function withdrawReserve(address to, uint256 amount) external override onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        _accrue();
        if (amount > _reserve) revert InsufficientReserve(amount, _reserve);
        _reserve -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IStakingVault
    function setApr(
        uint256 aprBps_
    ) external override onlyAdmin {
        if (aprBps_ > BPS) revert InvalidApr();
        _accrue();
        aprBps = aprBps_;
        emit AprSet(aprBps_);
    }

    /// @inheritdoc IStakingVault
    function setCap(
        uint256 cap_
    ) external override onlyAdmin {
        _accrue();
        cap = cap_;
        emit CapSet(cap_);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626
    // ──────────────────────────────────────────────────────────

    /// @dev Includes rewards dripped since the last touch, so previews match execution.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return _staked + _pending();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _accrue();
        _staked += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _accrue();
        _staked -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IStakingVault
    function rewardReserve() external view override returns (uint256) {
        return _reserve - _pending();
    }

    /// @inheritdoc IStakingVault
    function rewardRate() external view override returns (uint256) {
        if (_reserve == _pending()) return 0;
        return Math.mulDiv(Math.min(_staked, cap), aprBps, BPS * YEAR);
    }

    /// @inheritdoc IStakingVault
    function currentAprBps() external view override returns (uint256) {
        if (_reserve == _pending()) return 0;
        if (_staked <= cap) return aprBps;
        return Math.mulDiv(aprBps, cap, _staked);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Move rewards dripped since the last touch from the reserve into staked assets.
    function _accrue() private {
        uint256 earned = _pending();
        _lastAccrual = block.timestamp;
        if (earned == 0) return;
        _reserve -= earned;
        _staked += earned;
        emit RewardsAccrued(earned);
    }

    /// @dev Rewards owed since the last touch at the rate set then, capped by the reserve. Nothing
    ///      accrues while no shares exist.
    function _pending() private view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 owed = Math.mulDiv(Math.min(_staked, cap) * aprBps, block.timestamp - _lastAccrual, BPS * YEAR);
        return Math.min(owed, _reserve);
    }
}
