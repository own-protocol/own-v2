// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IEToken — Synthetic asset token with dividends and admin-updatable metadata
/// @notice Each tradeable asset (eTSLA, eGOLD, eTLT, …) has one active IEToken.
///         Extends ERC-20 + ERC-2612 Permit with:
///         - Restricted mint/burn (only the order system can call).
///         - Admin-updatable name/symbol (for stock-split token renaming).
///         - Rewards-per-share dividend accumulator for dividend-paying assets.
///
/// @dev The implementation MUST auto-settle pending rewards on every transfer
///      (both sender and receiver) so that rewards accounting stays consistent
///      without requiring holders to manually claim before transferring.
interface IEToken is IERC20, IERC20Permit {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when the admin updates the token name.
    /// @param oldName Previous name.
    /// @param newName New name.
    event NameUpdated(string oldName, string newName);

    /// @notice Emitted when the admin updates the token symbol.
    /// @param oldSymbol Previous symbol.
    /// @param newSymbol New symbol.
    event SymbolUpdated(string oldSymbol, string newSymbol);

    /// @notice Emitted when dividend rewards are deposited into the accumulator.
    /// @param amount           Reward amount deposited (in reward token decimals).
    /// @param newRewardsPerShare Updated cumulative rewards-per-share (PRECISION-based).
    event RewardsDeposited(uint256 amount, uint256 newRewardsPerShare);

    /// @notice Emitted when a holder claims accrued dividend rewards.
    /// @param user   The claiming holder.
    /// @param amount Amount of reward tokens claimed.
    event RewardsClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when eTokens are minted by the order system.
    /// @param to     Recipient.
    /// @param amount Amount minted.
    event Minted(address indexed to, uint256 amount);

    /// @notice Emitted when eTokens are burned by the order system.
    /// @param from   Holder whose tokens are burned.
    /// @param amount Amount burned.
    event Burned(address indexed from, uint256 amount);

    /// @notice Emitted when an admin adds or removes a pass-through holder.
    /// @param holder  Address whose holdings are treated as a custodian pool.
    /// @param enabled True if the address is now a pass-through holder.
    event PassThroughHolderUpdated(address indexed holder, bool enabled);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller is not authorised for this action.
    error Unauthorized();

    /// @notice A zero amount was provided where a positive value is required.
    error ZeroAmount();

    /// @notice A zero address was provided.
    error ZeroAddress();

    /// @notice The caller has no rewards to claim.
    error NoRewardsToClaim();

    // ──────────────────────────────────────────────────────────
    //  Restricted functions (order system only)
    // ──────────────────────────────────────────────────────────

    /// @notice Mint eTokens to a recipient. Restricted to the order system.
    /// @param to     Recipient address.
    /// @param amount Amount to mint (18 decimals).
    function mint(address to, uint256 amount) external;

    /// @notice Burn eTokens from a holder. Restricted to the order system.
    /// @param from   Holder address.
    /// @param amount Amount to burn (18 decimals).
    function burn(address from, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @notice Update the token name. Used during stock-split renaming.
    /// @param newName The new name string.
    function updateName(
        string calldata newName
    ) external;

    /// @notice Update the token symbol. Used during stock-split renaming.
    /// @param newSymbol The new symbol string.
    function updateSymbol(
        string calldata newSymbol
    ) external;

    /// @notice Mark `holder` as a pass-through (custodian) holder for dividends.
    /// @dev    When a registered holder transfers eTokens to a non-registered
    ///         recipient, a pro-rata slice of the holder's pre-transfer accrued
    ///         rewards is redirected to the recipient — preserving the
    ///         dividends earned by the underlying owner while their tokens
    ///         were held in custody (e.g. by the lending contract).
    /// @param holder  Address to mark / unmark.
    /// @param enabled True to register, false to remove.
    function setPassThroughHolder(address holder, bool enabled) external;

    /// @notice Whether an address is registered as a pass-through holder.
    function isPassThroughHolder(
        address holder
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Dividend / rewards functions
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit dividend rewards into the accumulator.
    /// @dev The caller must have approved this contract to spend `amount` of
    ///      the reward token. Updates `rewardsPerShare` proportionally.
    /// @param amount Amount of reward tokens to deposit.
    function depositRewards(
        uint256 amount
    ) external;

    /// @notice Claim all accrued dividend rewards for the caller.
    /// @return amount The amount of reward tokens transferred to the caller.
    function claimRewards() external returns (uint256 amount);

    /// @notice Return the amount of reward tokens claimable by an account.
    /// @param account Holder address.
    /// @return amount Claimable reward tokens.
    function claimableRewards(
        address account
    ) external view returns (uint256 amount);

    /// @notice Return the current cumulative rewards-per-share value.
    /// @return The accumulator value (PRECISION-scaled).
    function rewardsPerShare() external view returns (uint256);

    /// @notice Return the ERC-20 token used for dividend payouts.
    /// @return The reward token address.
    function rewardToken() external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the asset ticker this eToken represents.
    /// @return The ticker as bytes32 (e.g. bytes32("TSLA")).
    function ticker() external view returns (bytes32);
}
