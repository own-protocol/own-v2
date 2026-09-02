// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnIncentives} from "../interfaces/IOwnIncentives.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakedEUSD (sEUSD) — yield-bearing ERC-4626 wrapper for eUSD
/// @notice Deposit eUSD, receive sEUSD shares whose price appreciates as protocol revenue is
///         streamed in. Modeled on Ethena's sUSDe: rewards are transferred in and vested linearly,
///         so the share price rises smoothly and can never be sandwiched. Standard ERC-4626 +
///         ERC-2612 permit, so it plugs directly into money markets, Pendle, and leverage loops.
/// @dev Solvency & loop properties, by construction:
///      - `totalAssets() = eusd.balanceOf(this) − getUnvestedAmount() ≤ eusd.balanceOf(this)`, so
///        every redemption is payable from eUSD the vault already holds — instant redemption is
///        always solvent WITHOUT minting (the vault never holds eUSD `MINTER_ROLE`).
///      - Yield accrues into the share price, so looped sEUSD held by a money market keeps earning
///        with no per-user claim.
///      - No unstake cooldown: `redeem`/`withdraw` are immediate, so leverage can be unwound
///        atomically.
///      Rewards can be topped up mid-vest: a new stream folds any still-unvested remainder into the
///      new batch and re-vests the combined amount over a fresh window, so `totalAssets` is
///      continuous across the top-up (no jump, no gap) — the lever to hold APY as TVL changes.
///      Deploy note: seed a small first deposit (dead shares) to harden the first-depositor
///      inflation vector — the OZ v5 virtual-shares defense is active but a seed is
///      belt-and-suspenders for a money vault.
///      Runs behind an ERC-1967 proxy (UUPS) so the sEUSD address — and every downstream
///      integration holding its shares — survives upgrades to the vesting/yield mechanics.
///      Upgrades are ADMIN-gated ({_authorizeUpgrade}); ossification is a final upgrade to an
///      implementation whose {_authorizeUpgrade} always reverts. The eUSD asset is an
///      implementation immutable (baked in each build; {_authorizeUpgrade} pins it), while the
///      ERC-20 name/symbol are hard-coded overrides — constructor-set token metadata lives in
///      implementation storage a proxy never sees.
contract StakedEUSD is Initializable, UUPSUpgradeable, ERC4626, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @notice ProtocolRegistry used to resolve the ADMIN/OPERATOR roles.
    /// @dev Initializer-set, fixed thereafter (storage, not immutable, so an upgraded
    ///      implementation can never silently rebind it).
    IProtocolRegistry public registry;

    /// @notice Linear vesting window applied to each streamed reward batch (ADMIN-updatable).
    uint256 public vestingPeriod;

    /// @notice Size of the currently-vesting reward batch.
    uint256 public vestingAmount;

    /// @notice Timestamp the current batch began vesting.
    uint256 public lastDistributionTimestamp;

    /// @notice OWN incentives controller notified on every balance change (address(0) = none).
    /// @dev Distributes the OWN "boosted yield" to sEUSD holders without staking (Aave-style hook).
    IOwnIncentives public incentivesController;

    /// @notice Emitted when a reward batch is streamed in.
    /// @param streamer Address that supplied the eUSD (an OPERATOR).
    /// @param amount   eUSD added and now vesting.
    event RewardsStreamed(address indexed streamer, uint256 amount);

    /// @notice Emitted when the OWN incentives controller is set.
    /// @param controller New controller (address(0) disables the hook).
    event IncentivesControllerSet(address indexed controller);

    /// @notice Emitted when the vesting window is updated.
    /// @param oldPeriod Previous window (seconds).
    /// @param newPeriod New window (seconds).
    event VestingPeriodSet(uint256 oldPeriod, uint256 newPeriod);

    error ZeroAddress();
    error ZeroAmount();
    error OnlyOperator();
    error OnlyAdmin();
    error UpgradeAssetMismatch();

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev The implementation is only ever used behind an ERC-1967 proxy; lock its own
    ///      initializers so the bare implementation can never be initialized or taken over.
    ///      `eusd_` is baked into the implementation as the ERC-4626 asset and the ERC-2612
    ///      domain — every upgrade implementation must be built with the same token
    ///      ({_authorizeUpgrade} enforces this).
    /// @param eusd_ eUSD token — the vault asset.
    constructor(
        address eusd_
    ) ERC20("Own Staked eUSD", "sEUSD") ERC4626(IERC20(eusd_)) ERC20Permit("Own Staked eUSD") {
        if (eusd_ == address(0)) revert ZeroAddress();
        _disableInitializers();
    }

    /// @notice Initialize the vault proxy (runs once, in the proxy's constructor call).
    /// @param registry_       ProtocolRegistry address (role authority).
    /// @param vestingPeriod_  Linear vesting window per reward batch (e.g. 8 hours). Keep the
    ///                        streaming cadence ≤ this for continuous accrual.
    function initialize(address registry_, uint256 vestingPeriod_) external initializer {
        if (registry_ == address(0)) revert ZeroAddress();
        if (vestingPeriod_ == 0) revert ZeroAmount();
        registry = IProtocolRegistry(registry_);
        vestingPeriod = vestingPeriod_;
        lastDistributionTimestamp = block.timestamp;
    }

    /// @dev UUPS upgrade gate: ADMIN only, and the new implementation must be built with the same
    ///      eUSD asset — it is an implementation immutable, so a mismatched build would silently
    ///      corrupt the vault's accounting.
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        if (StakedEUSD(newImplementation).asset() != asset()) revert UpgradeAssetMismatch();
    }

    // ──────────────────────────────────────────────────────────
    //  Rewards streaming
    // ──────────────────────────────────────────────────────────

    /// @notice Stream eUSD yield into the vault to accrue into the share price over `vestingPeriod`.
    ///         Callable any time, including mid-vest as a top-up: any still-unvested remainder is
    ///         folded into the new batch and the combined amount re-vests over a fresh window.
    ///         OPERATOR only.
    /// @param amount eUSD to stream in.
    function transferInRewards(
        uint256 amount
    ) external nonReentrant {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        if (amount == 0) revert ZeroAmount();

        // Roll the unvested remainder into the new batch and re-vest from now. The freshly
        // transferred `amount` exactly matches the increase in `vestingAmount`, so `totalAssets`
        // (and the share price) is unchanged at this instant — no jump, no sandwich surface, no gap.
        vestingAmount = getUnvestedAmount() + amount;
        lastDistributionTimestamp = block.timestamp;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsStreamed(msg.sender, amount);
    }

    /// @notice Set (or clear) the OWN incentives controller. ADMIN only.
    /// @param controller New controller, or address(0) to disable the hook.
    function setIncentivesController(
        address controller
    ) external {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        incentivesController = IOwnIncentives(controller);
        emit IncentivesControllerSet(controller);
    }

    /// @notice Update the vesting window. ADMIN only. Re-anchors any in-flight batch so `totalAssets`
    ///         is continuous across the change (no share-price jump): the still-unvested remainder
    ///         becomes a fresh batch vesting over `newPeriod` from now.
    /// @param newPeriod New linear vesting window in seconds (non-zero).
    function setVestingPeriod(
        uint256 newPeriod
    ) external {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        if (newPeriod == 0) revert ZeroAmount();
        // Crystallize progress under the old window, then re-vest the remainder over the new one.
        vestingAmount = getUnvestedAmount();
        lastDistributionTimestamp = block.timestamp;
        emit VestingPeriodSet(vestingPeriod, newPeriod);
        vestingPeriod = newPeriod;
    }

    /// @notice Portion of the current reward batch not yet vested into `totalAssets`.
    function getUnvestedAmount() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastDistributionTimestamp;
        if (elapsed >= vestingPeriod) return 0;
        // Linear: full batch at t=0, zero at t=vestingPeriod.
        return vestingAmount - (vestingAmount * elapsed / vestingPeriod);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ERC4626
    /// @dev Excludes the unvested reward batch, so the share price rises smoothly as it vests and
    ///      redemptions never exceed the vault's eUSD balance.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - getUnvestedAmount();
    }

    /// @inheritdoc ERC4626
    function decimals() public view override(ERC4626, ERC20) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @dev Constructor-set ERC-20 metadata lives in implementation storage, which a proxy never
    ///      sees — pin it here instead.
    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Own Staked eUSD";
    }

    /// @dev See {name}.
    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "sEUSD";
    }

    /// @dev Notify the OWN incentives controller of each affected holder's *pre-change* balance and
    ///      the *pre-change* total supply before applying the transfer/mint/burn, so OWN accrues to
    ///      sEUSD holders without staking. The hook is wrapped so a controller fault can never block
    ///      sEUSD transfers — the token must stay composable even if incentives are misconfigured.
    function _update(address from, address to, uint256 value) internal override {
        IOwnIncentives ic = incentivesController;
        if (address(ic) != address(0)) {
            uint256 ts = totalSupply();
            if (from != address(0)) {
                try ic.handleAction(from, ts, balanceOf(from)) {} catch {}
            }
            if (to != address(0) && to != from) {
                try ic.handleAction(to, ts, balanceOf(to)) {} catch {}
            }
        }
        super._update(from, to, value);
    }
}
