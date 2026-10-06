// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundBribes} from "../interfaces/IFundBribes.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundLaunch} from "../interfaces/IFundLaunch.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {
    CreateFundParams,
    GovernanceConfig,
    GovernanceConfigLib,
    LaunchConfig,
    PlatformMetadata
} from "../interfaces/types/FundTypes.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title FundFactory — Own Curated Funds platform hub
/// @notice See {IFundFactory}.
/// @dev Runs behind an ERC-1967 proxy (UUPS); storage is append-only across upgrades. It owns
///      the six module beacons, so the registry ADMIN upgrades every fund through
///      {upgradeModule}. The hook is wired once after deployment ({setHook}) because its address
///      must be mined against the factory address.
contract FundFactory is IFundFactory, Initializable, UUPSUpgradeable {
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Hard cap on the protocol curator's share.
    uint16 public constant MAX_PROTOCOL_CURATOR_SHARE_BPS = 5000;

    /// @notice Hard cap on the rebalance slippage bound.
    uint16 public constant MAX_REBALANCE_SLIPPAGE_BPS = 1000;

    /// @notice Default staking yield cap: 109 500 bps a year (3% a day).
    uint32 public constant DEFAULT_MAX_YIELD_RATE_BPS_PER_YEAR = 300 * 365;

    /// @notice Hard cap on the staking yield cap: 3 650 000 bps a year (100% a day).
    uint32 public constant MAX_YIELD_RATE_BPS_PER_YEAR = 10_000 * 365;

    /// @notice Hard cap on the bribe cut.
    uint16 public constant MAX_BRIBE_CUT_BPS = 2500;

    /// @notice Hard cap on the curator cap.
    uint8 public constant MAX_CURATOR_CAP = 50;

    /// @notice Launch supply used when a fund sets none.
    uint256 public constant DEFAULT_LAUNCH_SUPPLY = 100_000_000e18;

    /// @notice Launch window used when a fund sets none.
    uint32 public constant DEFAULT_LAUNCH_DURATION = 7 days;

    /// @notice Hard cap on the share of a raise that seeds the pool.
    uint16 public constant MAX_POOL_USDG_BPS = 5000;

    /// @inheritdoc IFundFactory
    address public override registry;

    /// @inheritdoc IFundFactory
    address public override oracle;

    /// @inheritdoc IFundFactory
    address public override usdg;

    /// @inheritdoc IFundFactory
    address public override hook;

    /// @inheritdoc IFundFactory
    uint16 public override protocolCuratorShareBps;

    /// @inheritdoc IFundFactory
    address public override protocolCurator;

    /// @inheritdoc IFundFactory
    bool public override whitelistEnabled;

    /// @inheritdoc IFundFactory
    uint16 public override maxRebalanceSlippageBps;

    /// @inheritdoc IFundFactory
    mapping(address launcher => bool) public override isLauncher;

    /// @inheritdoc IFundFactory
    mapping(address router => bool) public override isRouter;

    /// @inheritdoc IFundFactory
    mapping(address fund => bool) public override isFund;

    /// @inheritdoc IFundFactory
    uint16 public override rebalanceVolumeCapBps;

    LaunchConfig private _launchConfig;
    address[] private _funds;
    mapping(Module module => address) private _beacons;

    /// @inheritdoc IFundFactory
    uint32 public override maxYieldRateBpsPerYear;

    GovernanceConfig private _governanceConfig;
    PlatformMetadata private _platformMetadata;

    /// @inheritdoc IFundFactory
    uint8 public override curatorCap;

    /// @inheritdoc IFundFactory
    uint16 public override bribeCutBps;

    /// @inheritdoc IFundFactory
    mapping(address token => bool) public override isBribeToken;

    /// @inheritdoc IFundFactory
    mapping(address token => bool) public override isEligibleAsset;

    mapping(address fund => FundModules) private _modules;

    /// @notice Emitted once, when the hook is wired.
    /// @param hook The hook.
    event HookSet(address hook);

    /// @notice The hook is already wired.
    error HookAlreadySet();

    /// @notice The hook is not wired yet.
    error HookNotSet();

    modifier onlyAdmin() {
        if (!isAdmin(msg.sender)) revert NotAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the factory proxy.
    /// @param registry_              Protocol registry; its ADMIN and OPERATOR roles run the platform.
    /// @param oracle_                Shared price oracle.
    /// @param usdg_                  USDG token.
    /// @param protocolCurator_       Protocol curator: Own's seat among every fund's curators.
    /// @param impls                  Implementations, indexed by {Module}.
    function initialize(
        address registry_,
        address oracle_,
        address usdg_,
        address protocolCurator_,
        address[6] calldata impls
    ) external initializer {
        if (registry_ == address(0) || oracle_ == address(0) || usdg_ == address(0) || protocolCurator_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        oracle = oracle_;
        emit OracleSet(oracle_);
        usdg = usdg_;

        protocolCurator = protocolCurator_;
        emit ProtocolCuratorSet(protocolCurator_);
        protocolCuratorShareBps = 3333;
        emit ProtocolCuratorShareSet(3333);
        whitelistEnabled = true;
        emit WhitelistEnabledSet(true);
        maxRebalanceSlippageBps = 200;
        emit MaxRebalanceSlippageSet(200);
        rebalanceVolumeCapBps = 1000;
        emit RebalanceVolumeCapSet(1000);

        LaunchConfig memory cfg = LaunchConfig({
            duration: DEFAULT_LAUNCH_DURATION,
            finalizeGrace: 7 days,
            poolUsdgBps: 1000,
            launchPremiumBps: 0,
            earlyYieldBpsPerDay: 50,
            overweightHaircutBps: 500,
            depositorLock: 7 days
        });
        _launchConfig = cfg;
        emit LaunchConfigSet(cfg);

        maxYieldRateBpsPerYear = DEFAULT_MAX_YIELD_RATE_BPS_PER_YEAR;
        emit MaxYieldRateSet(DEFAULT_MAX_YIELD_RATE_BPS_PER_YEAR);

        GovernanceConfig memory gov = GovernanceConfig({
            curatorShareBps: 3000,
            minVoteBps: 200,
            maxWeightBps: 2500,
            maxWeeklyShiftBps: 500,
            dropAfterEpochs: 4,
            quorumBps: 2000,
            curatorQuorumBps: 2000,
            votingPeriod: 3 days,
            vetoPeriod: 1 days,
            executionWindow: 7 days,
            bribeLock: 28 days,
            proposalThresholdUsd: 5000e18
        });
        _governanceConfig = gov;
        emit GovernanceConfigSet(gov);

        curatorCap = 10;
        emit CuratorCapSet(10);
        bribeCutBps = 1500;
        emit BribeCutSet(1500);

        for (uint256 i; i < 6; ++i) {
            _beacons[Module(i)] = address(new UpgradeableBeacon(impls[i], address(this)));
        }
    }

    /// @notice Wire the pool hook. Admin only, once.
    /// @param hook_ The hook (deployed against this factory).
    function setHook(
        address hook_
    ) external onlyAdmin {
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @inheritdoc IFundFactory
    function createFund(
        CreateFundParams calldata p
    ) external override returns (FundModules memory m) {
        if (!isAdmin(msg.sender) && whitelistEnabled && !isLauncher[msg.sender]) revert NotLauncher();
        if (hook == address(0)) revert HookNotSet();
        LaunchConfig memory cfg = _launchConfig;
        if (p.launchDuration != 0) cfg.duration = p.launchDuration;
        if (p.poolUsdgBps != 0) cfg.poolUsdgBps = p.poolUsdgBps;
        if (
            cfg.duration < 1 days || cfg.duration > 30 days || cfg.poolUsdgBps > MAX_POOL_USDG_BPS
                || (p.targetRaiseUsd != 0 && p.targetRaiseUsd < p.minRaiseUsd)
        ) revert InvalidLaunchConfig();
        uint256 supply = p.launchSupply == 0 ? DEFAULT_LAUNCH_SUPPLY : p.launchSupply;

        m.fund = _proxy(Module.Fund, abi.encodeCall(IFund.initialize, (p)));
        m.launch = _proxy(
            Module.Launch,
            abi.encodeCall(IFundLaunch.initialize, (m.fund, p.minRaiseUsd, p.targetRaiseUsd, supply, cfg))
        );
        m.staking = _proxy(Module.Staking, abi.encodeCall(IFundStaking.initialize, (m.fund, p.yieldCurve)));
        m.governor = _proxy(Module.Governor, abi.encodeCall(IFundGovernor.initialize, (m.fund, _governanceConfig)));
        m.curators = _proxy(
            Module.Curators, abi.encodeCall(IFundCurators.initialize, (m.fund, p.curators, p.minCuratorStakeBps))
        );
        m.bribes = _proxy(Module.Bribes, abi.encodeCall(IFundBribes.initialize, (m.fund)));

        IFund(m.fund).setModules(m.launch, m.staking, m.governor, m.curators);
        IFundHook(hook).registerFund(m.fund);
        isFund[m.fund] = true;
        _modules[m.fund] = m;
        _funds.push(m.fund);

        emit FundCreated(m.fund, m, msg.sender);
    }

    /// @inheritdoc IFundFactory
    function setOracle(
        address oracle_
    ) external override onlyAdmin {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    /// @inheritdoc IFundFactory
    function setProtocolCurator(
        address curator
    ) external override onlyAdmin {
        if (curator == address(0)) revert ZeroAddress();
        protocolCurator = curator;
        emit ProtocolCuratorSet(curator);
    }

    /// @inheritdoc IFundFactory
    function setProtocolCuratorShare(
        uint16 shareBps
    ) external override onlyAdmin {
        if (shareBps > MAX_PROTOCOL_CURATOR_SHARE_BPS) revert FeeTooHigh();
        protocolCuratorShareBps = shareBps;
        emit ProtocolCuratorShareSet(shareBps);
    }

    /// @inheritdoc IFundFactory
    function setCuratorCap(
        uint8 cap
    ) external override onlyAdmin {
        if (cap == 0 || cap > MAX_CURATOR_CAP) revert InvalidCuratorCap();
        curatorCap = cap;
        emit CuratorCapSet(cap);
    }

    /// @inheritdoc IFundFactory
    function setBribeCut(
        uint16 cutBps
    ) external override onlyAdmin {
        if (cutBps > MAX_BRIBE_CUT_BPS) revert FeeTooHigh();
        bribeCutBps = cutBps;
        emit BribeCutSet(cutBps);
    }

    /// @inheritdoc IFundFactory
    function setBribeToken(address token, bool allowed) external override onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        isBribeToken[token] = allowed;
        emit BribeTokenSet(token, allowed);
    }

    /// @inheritdoc IFundFactory
    function setEligibleAsset(address token, bool eligible) external override onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        isEligibleAsset[token] = eligible;
        emit EligibleAssetSet(token, eligible);
    }

    /// @inheritdoc IFundFactory
    function setWhitelistEnabled(
        bool enabled
    ) external override onlyAdmin {
        whitelistEnabled = enabled;
        emit WhitelistEnabledSet(enabled);
    }

    /// @inheritdoc IFundFactory
    function setLauncher(address launcher, bool allowed) external override onlyAdmin {
        if (launcher == address(0)) revert ZeroAddress();
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    /// @inheritdoc IFundFactory
    function setRouter(address router, bool allowed) external override onlyAdmin {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = allowed;
        emit RouterSet(router, allowed);
    }

    /// @inheritdoc IFundFactory
    function setMaxRebalanceSlippage(
        uint16 slippageBps
    ) external override onlyAdmin {
        if (slippageBps > MAX_REBALANCE_SLIPPAGE_BPS) revert InvalidSlippage();
        maxRebalanceSlippageBps = slippageBps;
        emit MaxRebalanceSlippageSet(slippageBps);
    }

    /// @inheritdoc IFundFactory
    function setRebalanceVolumeCap(
        uint16 capBps
    ) external override onlyAdmin {
        if (capBps > BPS) revert InvalidSlippage();
        rebalanceVolumeCapBps = capBps;
        emit RebalanceVolumeCapSet(capBps);
    }

    /// @inheritdoc IFundFactory
    function setLaunchConfig(
        LaunchConfig calldata config
    ) external override onlyAdmin {
        if (
            config.duration < 1 days || config.duration > 30 days || config.finalizeGrace < 1 hours
                || config.finalizeGrace > 30 days || config.poolUsdgBps == 0 || config.poolUsdgBps > MAX_POOL_USDG_BPS
                || config.launchPremiumBps > BPS || config.earlyYieldBpsPerDay > 100 || config.overweightHaircutBps > 5000
                || config.depositorLock > 30 days
        ) revert InvalidLaunchConfig();
        _launchConfig = config;
        emit LaunchConfigSet(config);
    }

    /// @inheritdoc IFundFactory
    function setMaxYieldRate(
        uint32 rateBpsPerYear
    ) external override onlyAdmin {
        if (rateBpsPerYear > MAX_YIELD_RATE_BPS_PER_YEAR) revert InvalidYieldCap();
        maxYieldRateBpsPerYear = rateBpsPerYear;
        emit MaxYieldRateSet(rateBpsPerYear);
    }

    /// @inheritdoc IFundFactory
    function setGovernanceConfig(
        GovernanceConfig calldata config
    ) external override onlyAdmin {
        if (!GovernanceConfigLib.isValid(config)) revert InvalidGovernanceConfig();
        _governanceConfig = config;
        emit GovernanceConfigSet(config);
    }

    /// @inheritdoc IFundFactory
    function setPlatformMetadata(
        PlatformMetadata calldata metadata
    ) external override onlyAdmin {
        _platformMetadata = metadata;
        emit PlatformMetadataSet(metadata);
    }

    /// @inheritdoc IFundFactory
    function upgradeModule(Module module, address implementation) external override onlyAdmin {
        UpgradeableBeacon(_beacons[module]).upgradeTo(implementation);
        emit ModuleUpgraded(module, implementation);
    }

    /// @inheritdoc IFundFactory
    function isAdmin(
        address account
    ) public view override returns (bool) {
        return IProtocolRegistry(registry).hasRole(ADMIN_ROLE, account);
    }

    /// @inheritdoc IFundFactory
    function isOperator(
        address account
    ) external view override returns (bool) {
        return IProtocolRegistry(registry).hasRole(OPERATOR_ROLE, account) || isAdmin(account);
    }

    /// @inheritdoc IFundFactory
    function launchConfig() external view override returns (LaunchConfig memory) {
        return _launchConfig;
    }

    /// @inheritdoc IFundFactory
    function governanceConfig() external view override returns (GovernanceConfig memory) {
        return _governanceConfig;
    }

    /// @inheritdoc IFundFactory
    function platformMetadata() external view override returns (PlatformMetadata memory) {
        return _platformMetadata;
    }

    /// @inheritdoc IFundFactory
    function fundCount() external view override returns (uint256) {
        return _funds.length;
    }

    /// @inheritdoc IFundFactory
    function fundAt(
        uint256 index
    ) external view override returns (address) {
        return _funds[index];
    }

    /// @inheritdoc IFundFactory
    function modulesOf(
        address fund
    ) external view override returns (FundModules memory) {
        return _modules[fund];
    }

    /// @inheritdoc IFundFactory
    function beacon(
        Module module
    ) external view override returns (address) {
        return _beacons[module];
    }

    function _proxy(Module module, bytes memory init) internal returns (address) {
        return address(new BeaconProxy(_beacons[module], init));
    }

    /// @dev UUPS upgrade gate.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}
}
