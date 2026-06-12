// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAaveRouter} from "../interfaces/IAaveRouter.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AaveRouter — Multi-reserve periphery router for Aave V3 ↔ OwnVault
/// @notice Single router instance that handles any number of Aave V3 reserves
///         (wstETH, WETH, wBTC, …). Reserves are registered by the protocol
///         admin; once registered, the `(underlying, aToken)` pair is
///         immutable. Admin can toggle a reserve's `enabled` flag to pause or
///         resume routing without changing the mapping.
///
///         The router holds no state other than the reserve registry and no
///         tokens between transactions.
contract AaveRouter is IAaveRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IAaveRouter
    address public immutable override pool;

    /// @notice ProtocolRegistry used to resolve the admin (its owner).
    IProtocolRegistry public immutable registry;

    /// @dev Per-underlying reserve metadata.
    mapping(address => ReserveInfo) private _reserves;

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    constructor(address pool_, address registry_) {
        if (pool_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        pool = pool_;
        registry = IProtocolRegistry(registry_);
    }

    // ──────────────────────────────────────────────────────────
    //  Reserve management
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveRouter
    function registerReserve(address underlying, address aToken) external onlyAdmin {
        if (underlying == address(0) || aToken == address(0)) revert ZeroAddress();
        if (_reserves[underlying].aToken != address(0)) revert ReserveAlreadyRegistered(underlying);

        _reserves[underlying] = ReserveInfo({aToken: aToken, enabled: true});

        // Pre-approve the pool to pull the underlying on supply.
        IERC20(underlying).forceApprove(pool, type(uint256).max);

        emit ReserveRegistered(underlying, aToken);
        emit ReserveEnabledChanged(underlying, true);
    }

    /// @inheritdoc IAaveRouter
    function setReserveEnabled(address underlying, bool enabled) external onlyAdmin {
        ReserveInfo storage info = _reserves[underlying];
        if (info.aToken == address(0)) revert ReserveNotRegistered(underlying);
        info.enabled = enabled;
        emit ReserveEnabledChanged(underlying, enabled);
    }

    /// @inheritdoc IAaveRouter
    function reserves(
        address underlying
    ) external view returns (address aToken, bool enabled) {
        ReserveInfo memory info = _reserves[underlying];
        return (info.aToken, info.enabled);
    }

    // ──────────────────────────────────────────────────────────
    //  Deposit / withdraw
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveRouter
    function deposit(
        address underlying,
        IERC4626 vault,
        uint256 underlyingAmount,
        address receiver,
        uint256 minSharesOut
    ) external nonReentrant returns (uint256 shares) {
        if (underlyingAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        address aToken = _requireEnabled(underlying);
        if (vault.asset() != aToken) revert VaultAssetMismatch(aToken, vault.asset());

        // Pull underlying from caller.
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        // Supply to Aave on the router's behalf — aToken lands here 1:1.
        uint256 aTokenBefore = IERC20(aToken).balanceOf(address(this));
        IAaveV3Pool(pool).supply(underlying, underlyingAmount, address(this), 0);
        uint256 aTokenReceived = IERC20(aToken).balanceOf(address(this)) - aTokenBefore;

        // Approve vault and deposit via standard ERC-4626 path.
        IERC20(aToken).forceApprove(address(vault), aTokenReceived);
        shares = vault.deposit(aTokenReceived, receiver);

        if (shares < minSharesOut) revert MinSharesError(shares, minSharesOut);

        emit Deposit(address(vault), msg.sender, receiver, underlying, aTokenReceived, shares);
    }

    /// @inheritdoc IAaveRouter
    function withdraw(
        address underlying,
        uint256 aTokenAmount,
        address receiver
    ) external nonReentrant returns (uint256 underlyingAmount) {
        if (aTokenAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        address aToken = _requireEnabled(underlying);

        // Pull aToken from caller.
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), aTokenAmount);

        // Aave burns the aToken and sends the underlying directly to `receiver`.
        underlyingAmount = IAaveV3Pool(pool).withdraw(underlying, aTokenAmount, receiver);

        emit Withdraw(msg.sender, receiver, underlying, aTokenAmount, underlyingAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Resolve the reserve's aToken and assert the reserve is enabled.
    function _requireEnabled(
        address underlying
    ) private view returns (address aToken) {
        ReserveInfo memory info = _reserves[underlying];
        if (info.aToken == address(0)) revert ReserveNotRegistered(underlying);
        if (!info.enabled) revert ReserveDisabled(underlying);
        return info.aToken;
    }
}
