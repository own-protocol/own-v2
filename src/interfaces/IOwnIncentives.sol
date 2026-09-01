// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IOwnIncentives — on-chain OWN incentives for sEUSD holders (Aave-style)
/// @notice Distributes OWN to sEUSD holders **without staking**: sEUSD calls {handleAction} on every
///         balance change, and this controller accrues OWN pro-rata to each holder's balance at a
///         governance-set `emissionPerSecond`, until `distributionEnd`. Holders claim OWN here; base
///         eUSD yield stays in the sEUSD share price and is untouched.
/// @dev Single-reward variant of Aave's RewardsController: one global index over sEUSD's total
///      supply, per-holder index snapshots, funded from an OWN budget with no mint rights (claims
///      are capped at the budget, never insolvent). Because accrual keys off balances, a holder
///      earns whether sEUSD sits in their wallet — the hook checkpoints on transfer, mint, and burn.
interface IOwnIncentives {
    event Accrued(address indexed user, uint256 amount, uint256 index);
    event RewardsClaimed(address indexed user, address indexed to, uint256 amount);
    event DistributionSet(uint256 emissionPerSecond, uint256 distributionEnd);
    event ReserveFunded(address indexed funder, uint256 amount);
    event ReserveRecovered(address indexed to, uint256 amount);
    event RewardShortfall(address indexed user, uint256 owed, uint256 paid);
    event PartnerSet(address indexed account, address indexed destination);
    event PartnerSwept(address indexed account, address indexed destination, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error OnlyStakedToken();
    error OnlyAdmin();
    error InsufficientReserve(uint256 requested, uint256 available);
    error NotPartner();

    // ── Hook (called by sEUSD only) ───────────────────────────

    /// @notice Checkpoint a holder's accrual on a balance change. Callable only by the sEUSD token.
    /// @param user        The holder whose balance is changing.
    /// @param totalSupply sEUSD total supply *before* the change (the supply during the elapsed period).
    /// @param userBalance The holder's sEUSD balance *before* the change.
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external;

    // ── Views ─────────────────────────────────────────────────

    /// @notice The incentivized token (sEUSD).
    function sEusd() external view returns (address);

    /// @notice The OWN reward token.
    function own() external view returns (address);

    /// @notice OWN emitted per second, split pro-rata to sEUSD holders while the campaign is live.
    function emissionPerSecond() external view returns (uint256);

    /// @notice Timestamp after which no further OWN accrues.
    function distributionEnd() external view returns (uint256);

    /// @notice OWN available to pay rewards.
    function rewardReserve() external view returns (uint256);

    /// @notice A holder's claimable OWN (accrued to now, before reserve capping).
    function earned(
        address user
    ) external view returns (uint256);

    /// @notice Destination for a registered partner's swept OWN (address(0) = not a partner).
    /// @param account The pooled partner address (e.g. a money-market contract holding sEUSD).
    function partnerDestination(
        address account
    ) external view returns (address);

    // ── Claim ─────────────────────────────────────────────────

    /// @notice Claim accrued OWN to `to`. Pays `min(owed, reserve)`; any remainder stays owed.
    /// @param to Recipient of the OWN.
    /// @return paid OWN transferred this call.
    function claim(
        address to
    ) external returns (uint256 paid);

    /// @notice Push a registered partner's accrued OWN to its destination for onward distribution.
    ///         Permissionless: the destination is fixed by ADMIN via {setPartner}, so the caller
    ///         cannot redirect it. Use for pooled addresses (e.g. Morpho) that hold sEUSD on behalf
    ///         of many users and cannot self-claim; the destination distributes to those users.
    /// @param account The registered partner address.
    /// @return paid OWN transferred to the partner's destination this call.
    function sweepPartner(
        address account
    ) external returns (uint256 paid);

    // ── Funding & governance ──────────────────────────────────

    /// @notice Top up the OWN budget (permissionless). Fee-on-transfer safe.
    function fund(
        uint256 amount
    ) external;

    /// @notice Set the emission rate and campaign end. ADMIN. Settles at the old rate first.
    /// @param emissionPerSecond_ New OWN/sec (0 to stop).
    /// @param distributionEnd_   New campaign end timestamp.
    function setDistribution(uint256 emissionPerSecond_, uint256 distributionEnd_) external;

    /// @notice Recover unused OWN budget. ADMIN.
    function recoverReserve(uint256 amount, address to) external;

    /// @notice Register (or clear) a pooled partner address and where its swept OWN should go.
    ///         ADMIN only. Only addresses registered here can be swept via {sweepPartner}; set
    ///         `destination` to address(0) to de-register. Intended for money-market/pool contracts
    ///         that custody sEUSD for many users and cannot self-claim — never individual wallets.
    /// @param account     The pooled partner address.
    /// @param destination Where swept OWN is sent (the partner's own distributor), or address(0).
    function setPartner(address account, address destination) external;
}
