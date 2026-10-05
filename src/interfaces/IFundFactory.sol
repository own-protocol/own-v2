// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateFundParams, GovernanceConfig, LaunchConfig, PlatformMetadata} from "./types/FundTypes.sol";

/// @title IFundFactory — creates Own Curated Funds and holds platform-wide settings
/// @notice Every fund is six beacon proxies (fund token + basket, launch, staking, governor,
///         curators, bribes) sharing the platform's oracle, USDG and pool hook. The factory owner
///         is the platform admin (Own): it launches funds (the launcher whitelist stays in the code,
///         empty by default, so launches can be opened up later), and sets the protocol curator
///         (Own's seat among every fund's curators) and its share, rebalance routers, launch and governance defaults, the curator cap, the bribe cut and
///         bribe tokens, the list of tokens eligible for listing, the staking yield cap and the
///         platform metadata. It upgrades every fund at once through the beacons.
interface IFundFactory {
    /// @notice Which beacon a call refers to.
    enum Module {
        Fund,
        Launch,
        Staking,
        Governor,
        Curators,
        Bribes
    }

    /// @notice The contracts that make up one fund.
    /// @param fund     The fund token and basket.
    /// @param launch   Its launch.
    /// @param staking  Its staking vault.
    /// @param governor Its governor.
    /// @param curators Its curators module.
    /// @param bribes   Its bribes module.
    struct FundModules {
        address fund;
        address launch;
        address staking;
        address governor;
        address curators;
        address bribes;
    }

    /// @notice Emitted when a fund is created.
    /// @param fund     The fund token and basket.
    /// @param modules  All of its contracts.
    /// @param launcher The caller that created it.
    event FundCreated(address indexed fund, FundModules modules, address indexed launcher);

    /// @notice Emitted when the protocol curator changes.
    /// @param curator New protocol curator.
    event ProtocolCuratorSet(address curator);

    /// @notice Emitted when the protocol curator's share changes.
    /// @param shareBps New share of the curators' votes and income, in basis points.
    event ProtocolCuratorShareSet(uint16 shareBps);

    /// @notice Emitted when the curator cap changes.
    /// @param cap New cap per fund.
    event CuratorCapSet(uint8 cap);

    /// @notice Emitted when the bribe cut changes.
    /// @param cutBps New cut, in basis points.
    event BribeCutSet(uint16 cutBps);

    /// @notice Emitted when a bribe token is allowed or disallowed.
    /// @param token   The token.
    /// @param allowed Whether bribes may be paid in it.
    event BribeTokenSet(address indexed token, bool allowed);

    /// @notice Emitted when a token is added to or removed from the listing eligibility list.
    /// @param token    The token.
    /// @param eligible Whether funds may list it.
    event EligibleAssetSet(address indexed token, bool eligible);

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
    /// @param rateBpsPerYear New cap, in basis points of the staked balance per year.
    event MaxYieldRateSet(uint32 rateBpsPerYear);

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

    /// @notice Caller is neither the owner nor a whitelisted launcher while whitelisting is on.
    error NotLauncher();

    /// @notice The curator cap is out of range.
    error InvalidCuratorCap();

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

    /// @notice Create a fund with all its modules. The owner, or (while whitelisting is on) a
    ///         whitelisted launcher; anyone once whitelisting is off. The launch window opens
    ///         immediately. A zero launch supply, duration or fee takes the default (100M tokens,
    ///         7 days, 1%).
    /// @param params Fund parameters.
    /// @return modules The fund's contracts.
    function createFund(
        CreateFundParams calldata params
    ) external returns (FundModules memory modules);

    /// @notice Set the protocol curator, Own's seat among every fund's curators. Owner only. It
    ///         cannot be removed from a fund, needs no stake and takes its share of the curators'
    ///         votes and income in every fund.
    /// @param curator The protocol curator.
    function setProtocolCurator(
        address curator
    ) external;

    /// @notice Set the protocol curator's share of the curators' votes and income in every fund.
    ///         Owner only.
    /// @param shareBps Share, in basis points (at most 50%).
    function setProtocolCuratorShare(
        uint16 shareBps
    ) external;

    /// @notice Set the maximum number of curators per fund. Owner only.
    /// @param cap Cap (1 to 50).
    function setCuratorCap(
        uint8 cap
    ) external;

    /// @notice Set the curators' cut of every bribe. Owner only.
    /// @param cutBps Cut, in basis points (at most 25%).
    function setBribeCut(
        uint16 cutBps
    ) external;

    /// @notice Allow or disallow a token for paying bribes. Owner only.
    /// @param token   The token.
    /// @param allowed Whether allowed.
    function setBribeToken(address token, bool allowed) external;

    /// @notice Add or remove a token from the list funds may list. Owner only.
    /// @param token    The token.
    /// @param eligible Whether eligible.
    function setEligibleAsset(address token, bool eligible) external;

    /// @notice Switch launcher whitelisting on or off. Owner only.
    /// @param enabled Whether only whitelisted launchers may create funds.
    function setWhitelistEnabled(
        bool enabled
    ) external;

    /// @notice Add or remove a whitelisted launcher. Owner only.
    /// @param launcher The launcher.
    /// @param allowed  Whether it may create funds.
    function setLauncher(address launcher, bool allowed) external;

    /// @notice Allow or disallow a rebalance router. Owner only.
    /// @param router  The router.
    /// @param allowed Whether funds may rebalance through it.
    function setRouter(address router, bool allowed) external;

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

    /// @notice Set the launch defaults used by funds created from now on. Owner only. The duration
    ///         here is the default window; each fund may set its own.
    /// @param config New parameters.
    function setLaunchConfig(
        LaunchConfig calldata config
    ) external;

    /// @notice Set the highest yearly rate any staking yield point may pay. Owner only. Applies to
    ///         every fund at once: points above a lowered cap pay the cap.
    /// @param rateBpsPerYear Cap, in basis points of the staked balance per year (at most 36 500 000,
    ///                       100% a day).
    function setMaxYieldRate(
        uint32 rateBpsPerYear
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
    function upgradeModule(Module module, address implementation) external;

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

    /// @notice The protocol curator, Own's seat among every fund's curators.
    /// @return The protocol curator.
    function protocolCurator() external view returns (address);

    /// @notice The protocol curator's share of the curators' votes and income, in basis points.
    /// @return The share.
    function protocolCuratorShareBps() external view returns (uint16);

    /// @notice Maximum number of curators per fund.
    /// @return The cap.
    function curatorCap() external view returns (uint8);

    /// @notice The curators' cut of every bribe, in basis points.
    /// @return The cut.
    function bribeCutBps() external view returns (uint16);

    /// @notice Whether bribes may be paid in `token`.
    /// @param token The token.
    /// @return True if allowed.
    function isBribeToken(
        address token
    ) external view returns (bool);

    /// @notice Whether funds may list `token`.
    /// @param token The token.
    /// @return True if eligible.
    function isEligibleAsset(
        address token
    ) external view returns (bool);

    /// @notice A fund's contracts.
    /// @param fund The fund.
    /// @return The modules.
    function modulesOf(
        address fund
    ) external view returns (FundModules memory);

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

    /// @notice Highest yearly rate a staking yield point may pay, in basis points.
    /// @return The cap.
    function maxYieldRateBpsPerYear() external view returns (uint32);

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
