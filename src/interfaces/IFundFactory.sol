// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateFundParams, GovernanceConfig, LaunchConfig, PlatformMetadata} from "./types/FundTypes.sol";

/// @title IFundFactory — creates MONEY Market Funds and holds platform-wide settings
/// @notice Every fund is four beacon proxies (fund token + basket, launch, staking, governor)
///         sharing the platform's oracle, USDG and pool hook. The factory owner is the platform
///         admin: it sets the protocol fee, the launcher whitelist, rebalance routers, launch and
///         governance parameters, the staking yield cap and the platform metadata, and upgrades
///         every fund at once through the beacons.
interface IFundFactory {
    /// @notice Which beacon a call refers to.
    enum Module {
        Fund,
        Launch,
        Staking,
        Governor
    }

    /// @notice Emitted when a fund is created.
    /// @param fund     The fund token and basket.
    /// @param launch   Its launch contract.
    /// @param staking  Its staking vault.
    /// @param governor Its governor.
    /// @param launcher The whitelisted caller that created it.
    /// @param manager  The creator managing it.
    event FundCreated(
        address indexed fund,
        address launch,
        address staking,
        address governor,
        address indexed launcher,
        address indexed manager
    );

    /// @notice Emitted when the protocol fee changes.
    /// @param feeBps New fee, in basis points.
    event ProtocolFeeSet(uint16 feeBps);

    /// @notice Emitted when the protocol fee recipient changes.
    /// @param recipient New recipient.
    event ProtocolFeeRecipientSet(address recipient);

    /// @notice Emitted when the LP fee recipient changes.
    /// @param recipient New recipient.
    event LpFeeRecipientSet(address recipient);

    /// @notice Emitted when launch whitelisting is switched on or off.
    /// @param enabled Whether only whitelisted launchers may create funds.
    event WhitelistEnabledSet(bool enabled);

    /// @notice Emitted when a launcher is added to or removed from the whitelist.
    /// @param launcher The launcher.
    /// @param allowed  Whether it may create funds.
    event LauncherSet(address indexed launcher, bool allowed);

    /// @notice Emitted when a rebalance router is allowed or disallowed.
    /// @param router  The router.
    /// @param allowed Whether funds may rebalance through it.
    event RouterSet(address indexed router, bool allowed);

    /// @notice Emitted when the rebalance slippage bound changes.
    /// @param slippageBps New bound, in basis points of oracle value.
    event MaxRebalanceSlippageSet(uint16 slippageBps);

    /// @notice Emitted when the daily rebalance volume cap changes.
    /// @param capBps New cap, in basis points of basket value per day.
    event RebalanceVolumeCapSet(uint16 capBps);

    /// @notice Emitted when the launch parameters for new funds change.
    /// @param config New parameters.
    event LaunchConfigSet(LaunchConfig config);

    /// @notice Emitted when the staking yield cap changes.
    /// @param rateBpsPerDay New cap, in basis points of the staked balance per day.
    event MaxYieldRateSet(uint16 rateBpsPerDay);

    /// @notice Emitted when the governance parameters for new funds change.
    /// @param config New parameters.
    event GovernanceConfigSet(GovernanceConfig config);

    /// @notice Emitted when the platform metadata changes.
    /// @param metadata New metadata.
    event PlatformMetadataSet(PlatformMetadata metadata);

    /// @notice Emitted when a module beacon is pointed at a new implementation.
    /// @param module         The module.
    /// @param implementation The new implementation.
    event ModuleUpgraded(Module indexed module, address implementation);

    /// @notice Emitted when a two-step ownership transfer starts.
    /// @param newOwner The pending owner.
    event OwnershipTransferStarted(address indexed newOwner);

    /// @notice Emitted when ownership changes.
    /// @param previousOwner The previous owner.
    /// @param newOwner      The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Caller is not the owner.
    error NotOwner();

    /// @notice Caller is not the pending owner.
    error NotPendingOwner();

    /// @notice Caller is not a whitelisted launcher while whitelisting is on.
    error NotLauncher();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice A fee is above its cap.
    error FeeTooHigh();

    /// @notice A launch parameter is out of range.
    error InvalidLaunchConfig();

    /// @notice The slippage bound is out of range.
    error InvalidSlippage();

    /// @notice The yield cap is out of range.
    error InvalidYieldCap();

    /// @notice A governance parameter is out of range.
    error InvalidGovernanceConfig();

    /// @notice Create a fund with its launch, staking vault and governor. Whitelisted launchers
    ///         only while whitelisting is on. The launch window opens immediately.
    /// @param params Fund parameters.
    /// @return fund     The fund token and basket.
    /// @return launch   Its launch contract.
    /// @return staking  Its staking vault.
    /// @return governor Its governor.
    function createFund(
        CreateFundParams calldata params
    ) external returns (address fund, address launch, address staking, address governor);

    /// @notice Set the protocol fee charged on pool trades, mints and redeems. Owner only.
    /// @param feeBps Fee, in basis points (capped).
    function setProtocolFee(
        uint16 feeBps
    ) external;

    /// @notice Set the protocol fee recipient. Owner only.
    /// @param recipient The recipient.
    function setProtocolFeeRecipient(
        address recipient
    ) external;

    /// @notice Set the recipient of LP fees collected from locked pool positions. Owner only.
    /// @param recipient The recipient.
    function setLpFeeRecipient(
        address recipient
    ) external;

    /// @notice Switch launcher whitelisting on or off. Owner only.
    /// @param enabled Whether only whitelisted launchers may create funds.
    function setWhitelistEnabled(
        bool enabled
    ) external;

    /// @notice Add or remove a whitelisted launcher. Owner only.
    /// @param launcher The launcher.
    /// @param allowed  Whether it may create funds.
    function setLauncher(
        address launcher,
        bool allowed
    ) external;

    /// @notice Allow or disallow a rebalance router. Owner only.
    /// @param router  The router.
    /// @param allowed Whether funds may rebalance through it.
    function setRouter(
        address router,
        bool allowed
    ) external;

    /// @notice Set the maximum oracle-valued loss a rebalance may take. Owner only.
    /// @param slippageBps Bound, in basis points (capped).
    function setMaxRebalanceSlippage(
        uint16 slippageBps
    ) external;

    /// @notice Set how much of a fund's basket value its manager may rebalance per day. Owner only.
    /// @param capBps Cap, in basis points of basket value (at most 10 000).
    function setRebalanceVolumeCap(
        uint16 capBps
    ) external;

    /// @notice Set the launch parameters used by funds created from now on. Owner only.
    /// @param config New parameters.
    function setLaunchConfig(
        LaunchConfig calldata config
    ) external;

    /// @notice Set the highest daily rate any staking yield tier may pay. Owner only. Applies to
    ///         every fund at once: tiers above a lowered cap pay the cap.
    /// @param rateBpsPerDay Cap, in basis points of the staked balance per day (at most 10 000).
    function setMaxYieldRate(
        uint16 rateBpsPerDay
    ) external;

    /// @notice Set the governance parameters used by funds created from now on. Owner only.
    /// @param config New parameters.
    function setGovernanceConfig(
        GovernanceConfig calldata config
    ) external;

    /// @notice Set the platform metadata every fund shows. Owner only.
    /// @param metadata New metadata.
    function setPlatformMetadata(
        PlatformMetadata calldata metadata
    ) external;

    /// @notice Point a module beacon at a new implementation, upgrading every fund. Owner only.
    /// @param module         The module.
    /// @param implementation The new implementation.
    function upgradeModule(
        Module module,
        address implementation
    ) external;

    /// @notice Start a two-step ownership transfer. Owner only.
    /// @param newOwner The pending owner.
    function transferOwnership(
        address newOwner
    ) external;

    /// @notice Accept a pending ownership transfer. Pending owner only.
    function acceptOwnership() external;

    /// @notice Platform admin; also the admin of every fund, launch, staking vault, governor and
    ///         the hook.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice Pending owner of a two-step transfer.
    /// @return The pending owner.
    function pendingOwner() external view returns (address);

    /// @notice The shared price oracle.
    /// @return The oracle.
    function oracle() external view returns (address);

    /// @notice The USDG token every pool is paired with.
    /// @return USDG.
    function usdg() external view returns (address);

    /// @notice The Uniswap v4 hook every fund pool uses.
    /// @return The hook.
    function hook() external view returns (address);

    /// @notice Protocol fee, in basis points.
    /// @return The fee.
    function protocolFeeBps() external view returns (uint16);

    /// @notice Protocol fee recipient.
    /// @return The recipient.
    function protocolFeeRecipient() external view returns (address);

    /// @notice Recipient of LP fees collected from locked pool positions.
    /// @return The recipient.
    function lpFeeRecipient() external view returns (address);

    /// @notice Whether only whitelisted launchers may create funds.
    /// @return True while whitelisting is on.
    function whitelistEnabled() external view returns (bool);

    /// @notice Whether `launcher` is whitelisted.
    /// @param launcher The launcher.
    /// @return True if whitelisted.
    function isLauncher(
        address launcher
    ) external view returns (bool);

    /// @notice Whether funds may rebalance through `router`.
    /// @param router The router.
    /// @return True if allowed.
    function isRouter(
        address router
    ) external view returns (bool);

    /// @notice Maximum oracle-valued loss a rebalance may take, in basis points.
    /// @return The bound.
    function maxRebalanceSlippageBps() external view returns (uint16);

    /// @notice Share of basket value a manager may rebalance per day, in basis points.
    /// @return The cap.
    function rebalanceVolumeCapBps() external view returns (uint16);

    /// @notice Launch parameters used by funds created from now on.
    /// @return The parameters.
    function launchConfig() external view returns (LaunchConfig memory);

    /// @notice Highest daily rate a staking yield tier may pay, in basis points.
    /// @return The cap.
    function maxYieldRateBpsPerDay() external view returns (uint16);

    /// @notice Governance parameters used by funds created from now on.
    /// @return The parameters.
    function governanceConfig() external view returns (GovernanceConfig memory);

    /// @notice Platform metadata every fund shows.
    /// @return The metadata.
    function platformMetadata() external view returns (PlatformMetadata memory);

    /// @notice Whether `fund` was created by this factory.
    /// @param fund The address.
    /// @return True if it is a fund.
    function isFund(
        address fund
    ) external view returns (bool);

    /// @notice Number of funds created.
    /// @return The count.
    function fundCount() external view returns (uint256);

    /// @notice Fund at `index` in creation order.
    /// @param index The index.
    /// @return The fund.
    function fundAt(
        uint256 index
    ) external view returns (address);

    /// @notice Beacon for `module`.
    /// @param module The module.
    /// @return The beacon.
    function beacon(
        Module module
    ) external view returns (address);
}
