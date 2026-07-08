// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IReserveVault} from "../interfaces/IReserveVault.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ReserveVault — Share-less RWA reserve pool (1:1 wrapper backing for one asset)
/// @notice Protocol-owned custody of a single wrapper token, registered on the VaultManager as
///         an RWA vault so its balance nets against the backed asset's exposure. No LP shares,
///         no queues, no lending. Reserve enters via the OwnMarket PSM paths and exits via
///         {releaseCollateral}, {withdraw}, or {skimExcess}.
contract ReserveVault is IReserveVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    /// @dev The wrapper token held as reserve.
    IERC20 private immutable _wrapper;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param wrapper_  Wrapper token held as reserve (e.g. ondoTSLA).
    /// @param registry_ ProtocolRegistry contract address.
    constructor(address wrapper_, address registry_) {
        if (wrapper_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        uint8 dec = IERC20Metadata(wrapper_).decimals();
        if (dec > 18) revert DecimalsTooHigh(dec);
        _wrapper = IERC20(wrapper_);
        registry = IProtocolRegistry(registry_);
    }

    // ──────────────────────────────────────────────────────────
    //  External functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IReserveVault
    function deposit(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 balBefore = totalAssets();
        _wrapper.safeTransferFrom(msg.sender, address(this), amount);
        if (totalAssets() - balBefore != amount) revert FeeOnTransferNotSupported();
        // Mark the enlarged reserve so it nets against outstanding exposure immediately.
        IVaultManager(registry.vaultManager()).pullCollateralPrice(address(this));
        emit ReserveDeposited(msg.sender, amount);
    }

    /// @inheritdoc IReserveVault
    function releaseCollateral(address to, uint256 amount) external onlyMarket nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalAssets()) revert AmountExceedsReserve();
        // Sync the mark before assets leave (mirrors OwnVault.releaseCollateral).
        IVaultManager(registry.vaultManager()).onCollateralReleased(amount);
        _wrapper.safeTransfer(to, amount);
        emit CollateralReleased(to, amount);
    }

    /// @inheritdoc IReserveVault
    function skimExcess(
        uint256 amount
    ) external onlyOperator nonReentrant {
        address to = registry.treasury();
        if (to == address(0)) revert TreasuryNotSet();
        _releaseCollateral(to, amount);
        emit ExcessSkimmed(to, amount);
    }

    /// @inheritdoc IReserveVault
    function withdraw(
        uint256 amount
    ) external nonReentrant {
        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (!vmgr.isSigner(msg.sender)) revert OnlyMaker();
        // Payout goes to the signer's linked settlement address, never the hot key.
        address to = vmgr.signerLinkedAddress(msg.sender);
        _releaseCollateral(to, amount);
        emit SurplusWithdrawn(msg.sender, to, amount);
    }

    /// @dev Shared surplus release: re-mark, reduce, and require the remaining reserve to still
    ///      cover the asset's gross exposure — only the clamped surplus is spendable.
    function _releaseCollateral(address to, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (amount > totalAssets()) revert AmountExceedsReserve();

        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        bytes32 backed = vmgr.vaultBackedAsset(address(this));
        if (backed == bytes32(0)) revert VaultNotRwaRegistered();
        // Re-mark at the current price and balance so the surplus guard reads honestly.
        vmgr.pullCollateralPrice(address(this));
        vmgr.onCollateralReleased(amount);
        if (vmgr.assetRwaCollateralUSD(backed) < vmgr.assetExposureUSD(backed)) {
            revert SkimExceedsSurplus();
        }

        _wrapper.safeTransfer(to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IReserveVault
    function asset() external view returns (address) {
        return address(_wrapper);
    }

    /// @inheritdoc IReserveVault
    function totalAssets() public view returns (uint256) {
        return _wrapper.balanceOf(address(this));
    }
}
