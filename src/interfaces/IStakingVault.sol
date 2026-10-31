// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IStakingVault — Fixed-APR staking vault (seUSD, sMONEY)
/// @notice ERC-4626 vault paying a fixed APR in its own asset. Rewards drip from a pre-funded
///         reserve held by the vault into staked assets, raising the share price. The drip rate is
///         `aprBps × min(totalStaked, cap)` per year and is re-set on every deposit, withdrawal and
///         admin change, so every staker earns exactly `aprBps` while total staked is at or below
///         `cap`. Above the cap the drip stays at `aprBps × cap` and the effective APR falls as TVL
///         grows. When the reserve runs out the drip stops until it is refunded.
interface IStakingVault is IERC4626 {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when reserve rewards move into staked assets.
    /// @param amount Asset units added to staked assets.
    event RewardsAccrued(uint256 amount);

    /// @notice Emitted when the reward reserve is topped up.
    /// @param from   Account that supplied the assets.
    /// @param amount Asset units added to the reserve.
    event ReserveFunded(address indexed from, uint256 amount);

    /// @notice Emitted when the admin takes unspent reserve back out.
    /// @param to     Recipient.
    /// @param amount Asset units removed from the reserve.
    event ReserveWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when the target APR changes.
    /// @param aprBps New APR (BPS).
    event AprSet(uint256 aprBps);

    /// @notice Emitted when the staked amount that earns the full APR changes.
    /// @param cap New cap (asset units).
    event CapSet(uint256 cap);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();
    /// @notice APR above the allowed maximum (100%).
    error InvalidApr();
    /// @notice Withdrawal exceeds the unspent reserve.
    /// @param requested Requested amount.
    /// @param available Unspent reserve after accrual.
    error InsufficientReserve(uint256 requested, uint256 available);

    // ──────────────────────────────────────────────────────────
    //  Reserve
    // ──────────────────────────────────────────────────────────

    /// @notice Add `amount` of the asset to the reward reserve, pulled from the caller.
    ///         Permissionless: funding can only ever pay stakers.
    /// @param amount Asset units to add.
    function fund(
        uint256 amount
    ) external;

    /// @notice Pull `amount` of the asset from the registry treasury into the reward reserve
    ///         (OPERATOR). The treasury approves the vault once; the keeper tops up weekly.
    /// @param amount Asset units to add.
    function pullFromTreasury(
        uint256 amount
    ) external;

    /// @notice Take unspent reserve back out (ADMIN). Never touches staked assets.
    /// @param to     Recipient.
    /// @param amount Asset units to remove.
    function withdrawReserve(address to, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Set the target APR (ADMIN). Rewards up to now accrue at the old rate first.
    /// @param aprBps New APR in BPS (at most 10 000).
    function setApr(
        uint256 aprBps
    ) external;

    /// @notice Set the staked amount that earns the full APR (ADMIN). Rewards up to now accrue at
    ///         the old cap first.
    /// @param cap New cap (asset units).
    function setCap(
        uint256 cap
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Target APR in BPS.
    function aprBps() external view returns (uint256);

    /// @notice Staked amount (asset units) that earns the full APR.
    function cap() external view returns (uint256);

    /// @notice Unspent reward reserve, net of rewards accrued since the last update.
    function rewardReserve() external view returns (uint256);

    /// @notice Current drip in asset units per second.
    function rewardRate() external view returns (uint256);

    /// @notice APR stakers currently earn in BPS: `aprBps` up to the cap, lower above it, 0 when
    ///         the reserve is empty.
    function currentAprBps() external view returns (uint256);
}
