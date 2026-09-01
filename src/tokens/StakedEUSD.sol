// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnIncentives} from "../interfaces/IOwnIncentives.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
///      Only the just-streamed batch vests; a new stream is rejected until the previous one has
///      fully vested (mirrors sUSDe), keeping the drip rate well-defined. Deploy note: seed a small
///      first deposit (dead shares) to harden the first-depositor inflation vector — the OZ v5
///      virtual-shares defense is active but a seed is belt-and-suspenders for a money vault.
contract StakedEUSD is ERC4626, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Linear vesting window applied to each streamed reward batch.
    uint256 public immutable VESTING_PERIOD;

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @notice ProtocolRegistry used to resolve the ADMIN/OPERATOR roles.
    IProtocolRegistry public immutable registry;

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

    error ZeroAddress();
    error ZeroAmount();
    error StillVesting(uint256 unvested);
    error OnlyOperator();
    error OnlyAdmin();

    /// @param registry_       ProtocolRegistry address (role authority).
    /// @param eusd_           eUSD token — the vault asset.
    /// @param vestingPeriod_  Linear vesting window per reward batch (e.g. 8 hours). Keep the
    ///                        streaming cadence ≤ this for continuous accrual.
    constructor(
        address registry_,
        address eusd_,
        uint256 vestingPeriod_
    ) ERC20("Staked eUSD", "sEUSD") ERC4626(IERC20(eusd_)) ERC20Permit("Staked eUSD") {
        if (registry_ == address(0) || eusd_ == address(0)) revert ZeroAddress();
        if (vestingPeriod_ == 0) revert ZeroAmount();
        registry = IProtocolRegistry(registry_);
        VESTING_PERIOD = vestingPeriod_;
        lastDistributionTimestamp = block.timestamp;
    }

    // ──────────────────────────────────────────────────────────
    //  Rewards streaming
    // ──────────────────────────────────────────────────────────

    /// @notice Stream a reward batch into the vault to accrue into the share price over
    ///         `VESTING_PERIOD`. Rejected until the previous batch has fully vested. OPERATOR only.
    /// @param amount eUSD to stream in.
    function transferInRewards(
        uint256 amount
    ) external nonReentrant {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        if (amount == 0) revert ZeroAmount();
        uint256 unvested = getUnvestedAmount();
        if (unvested != 0) revert StillVesting(unvested);

        vestingAmount = amount;
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

    /// @notice Portion of the current reward batch not yet vested into `totalAssets`.
    function getUnvestedAmount() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastDistributionTimestamp;
        if (elapsed >= VESTING_PERIOD) return 0;
        // Linear: full batch at t=0, zero at t=VESTING_PERIOD.
        return vestingAmount - (vestingAmount * elapsed / VESTING_PERIOD);
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
