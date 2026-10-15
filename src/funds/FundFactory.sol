// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundBribes} from "../interfaces/IFundBribes.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundLaunch} from "../interfaces/IFundLaunch.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {IFundVenue} from "../interfaces/IFundVenue.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {
    CreateFundParams,
    GovernanceConfig,
    GovernanceConfigLib,
    IssuanceStep,
    LaunchConfig,
    PlatformMetadata,
    PremiumConfig,
    PremiumConfigLib,
    YieldPoint
} from "../interfaces/types/FundTypes.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title FundFactory — Own Curated Funds platform hub
/// @notice See {IFundFactory}.
/// @dev Runs behind an ERC-1967 proxy (UUPS); storage is append-only across upgrades. It owns
///      the seven module beacons, so the registry FUND_ADMIN upgrades every fund through
///      {upgradeModule}.
contract FundFactory is IFundFactory, Initializable, UUPSUpgradeable {
    bytes32 private constant ADMIN_ROLE = keccak256("FUND_ADMIN");
    bytes32 private constant OPERATOR_ROLE = keccak256("FUND_OPERATOR");

    // Hard cap on the protocol curator's share.
    uint16 private constant MAX_PROTOCOL_CURATOR_SHARE_BPS = 5000;

    // Hard cap on the rebalance slippage bound.
    uint16 private constant MAX_REBALANCE_SLIPPAGE_BPS = 1000;

    // Default staking yield cap: 109 500 bps a year (3% a day).
    uint32 private constant DEFAULT_MAX_YIELD_RATE_BPS_PER_YEAR = 300 * 365;

    // Hard cap on the staking yield cap: 3 650 000 bps a year (100% a day).
    uint32 private constant MAX_YIELD_RATE_BPS_PER_YEAR = 10_000 * 365;

    // Hard cap on the bribe cut.
    uint16 private constant MAX_BRIBE_CUT_BPS = 2500;

    // Hard cap on the curator cap.
    uint8 private constant MAX_CURATOR_CAP = 50;

    // Launch supply used when a fund sets none.
    uint256 private constant DEFAULT_LAUNCH_SUPPLY = 100_000_000e18;

    // Launch window used when a fund sets none.
    uint32 private constant DEFAULT_LAUNCH_DURATION = 7 days;

    // Hard cap on the share of a raise that seeds the pool.
    uint16 private constant MAX_POOL_USDG_BPS = 5000;

    /// @inheritdoc IFundFactory
    address public override registry;

    /// @inheritdoc IFundFactory
    address public override oracle;

    /// @inheritdoc IFundFactory
    address public override usdg;

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

    /// @inheritdoc IFundFactory
    address public override auctions;

    address private _sweepRecipient;

    PremiumConfig private _premiumConfig;
    IssuanceStep[] private _issuanceSteps;
    YieldPoint[] private _yieldCurve;

    /// @inheritdoc IFundFactory
    address public override mintZap;

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the factory proxy.
    /// @param registry_              Protocol registry; its FUND_ADMIN and FUND_OPERATOR roles run the platform.
    /// @param oracle_                Shared price oracle.
    /// @param usdg_                  USDG token.
    /// @param protocolCurator_       Protocol curator: Own's seat among every fund's curators.
    /// @param impls                  Implementations, indexed by {Module}.
    function initialize(
        address registry_,
        address oracle_,
        address usdg_,
        address protocolCurator_,
        address[7] calldata impls
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

        for (uint256 i; i < 7; ++i) {
            _beacons[Module(i)] = address(new UpgradeableBeacon(impls[i], address(this)));
        }

        _setPremiumConfig(
            PremiumConfig({
                mintLock: 15 days,
                mintAdjustmentBps: 0,
                maxPremiumBps: 0,
                boostShareBps: 7500,
                boostSpeedBpsPerYear: 7500,
                potDripPeriod: 7 days,
                issuanceStartBps: 100,
                potShareBps: 7500
            })
        );
        IssuanceStep[] memory steps = new IssuanceStep[](3);
        steps[0] = IssuanceStep({premiumBps: 0, densityBps: 100});
        steps[1] = IssuanceStep({premiumBps: 10_000, densityBps: 200});
        steps[2] = IssuanceStep({premiumBps: 40_000, densityBps: 300});
        _setIssuanceSteps(steps);
        YieldPoint[] memory curve = new YieldPoint[](3);
        curve[0] = YieldPoint({premiumBps: 0, rateBpsPerYear: 1200});
        curve[1] = YieldPoint({premiumBps: 2500, rateBpsPerYear: 2400});
        curve[2] = YieldPoint({premiumBps: 10_000, rateBpsPerYear: 4800});
        _setYieldCurve(curve);
    }

    /// @inheritdoc IFundFactory
    function createFund(
        CreateFundParams calldata p
    ) external override returns (FundModules memory m) {
        if (!isAdmin(msg.sender) && whitelistEnabled && !isLauncher[msg.sender]) revert NotLauncher();
        LaunchConfig memory cfg = _launchConfig;
        if (p.launchDuration != 0) cfg.duration = p.launchDuration;
        if (p.poolUsdgBps != 0) cfg.poolUsdgBps = p.poolUsdgBps;
        if (
            cfg.duration < 1 days || cfg.duration > 30 days || cfg.poolUsdgBps > MAX_POOL_USDG_BPS
                || (p.targetRaiseUsd != 0 && p.targetRaiseUsd < p.minRaiseUsd)
        ) revert InvalidLaunchConfig();
        uint256 supply = p.launchSupply == 0 ? DEFAULT_LAUNCH_SUPPLY : p.launchSupply;

        // initialize takes the same single argument, so createFund's calldata is forwarded as is.
        m.fund = _proxy(Module.Fund, bytes.concat(IFund.initialize.selector, msg.data[4:]));
        m.launch = _proxy(
            Module.Launch,
            abi.encodeCall(IFundLaunch.initialize, (m.fund, p.minRaiseUsd, p.targetRaiseUsd, supply, cfg))
        );
        m.staking = _proxy(Module.Staking, abi.encodeCall(IFundStaking.initialize, (m.fund, p.yieldCurve)));
        m.governor = _proxy(Module.Governor, abi.encodeCall(IFundGovernor.initialize, (m.fund, _governanceConfig)));
        m.curators = _proxy(
            Module.Curators, abi.encodeCall(IFundCurators.initialize, (m.fund, p.curators, p.minCuratorStakeUsd))
        );
        m.bribes = _proxy(Module.Bribes, abi.encodeCall(IFundBribes.initialize, (m.fund)));
        m.venue = _proxy(Module.Venue, abi.encodeCall(IFundVenue.initialize, (m.fund, p.pool)));

        IFund(m.fund).setModules(m.launch, m.staking, m.governor, m.curators, m.venue);
        isFund[m.fund] = true;
        _modules[m.fund] = m;
        _funds.push(m.fund);

        emit FundCreated(m.fund, m, msg.sender);
    }

    /// @inheritdoc IFundFactory
    function setOracle(
        address oracle_
    ) external override onlyAdmin {
        _nonZero(oracle_);
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    /// @inheritdoc IFundFactory
    function setAuctions(
        address auctions_
    ) external override onlyAdmin {
        _nonZero(auctions_);
        auctions = auctions_;
        emit AuctionsSet(auctions_);
    }

    /// @inheritdoc IFundFactory
    function setSweepRecipient(
        address recipient
    ) external override onlyAdmin {
        _sweepRecipient = recipient;
        emit SweepRecipientSet(recipient);
    }

    /// @inheritdoc IFundFactory
    function setMintZap(
        address zap
    ) external override onlyAdmin {
        mintZap = zap;
        emit MintZapSet(zap);
    }

    /// @inheritdoc IFundFactory
    function setProtocolCurator(
        address curator
    ) external override onlyAdmin {
        _nonZero(curator);
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
        _nonZero(token);
        isBribeToken[token] = allowed;
        emit BribeTokenSet(token, allowed);
    }

    /// @inheritdoc IFundFactory
    function setEligibleAsset(address token, bool eligible) external override onlyAdmin {
        _nonZero(token);
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
        _nonZero(launcher);
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    /// @inheritdoc IFundFactory
    function setRouter(address router, bool allowed) external override onlyAdmin {
        _nonZero(router);
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
        PlatformMetadata storage pm = _platformMetadata;
        pm.name = metadata.name;
        pm.description = metadata.description;
        pm.url = metadata.url;
        emit PlatformMetadataSet(metadata);
    }

    /// @inheritdoc IFundFactory
    function setPremiumConfig(
        PremiumConfig calldata config
    ) external override onlyAdmin {
        _setPremiumConfig(config);
    }

    /// @inheritdoc IFundFactory
    function setDefaultIssuanceSteps(
        IssuanceStep[] calldata steps
    ) external override onlyAdmin {
        _setIssuanceSteps(steps);
    }

    /// @inheritdoc IFundFactory
    function setDefaultYieldCurve(
        YieldPoint[] calldata curve
    ) external override onlyAdmin {
        _setYieldCurve(curve);
    }

    /// @inheritdoc IFundFactory
    function upgradeModule(Module module, address implementation) external override onlyAdmin {
        UpgradeableBeacon(_beacons[module]).upgradeTo(implementation);
        emit ModuleUpgraded(module, implementation);
    }

    /// @inheritdoc IFundFactory
    function sweepRecipient() external view override returns (address) {
        address recipient = _sweepRecipient;
        return recipient != address(0) ? recipient : IProtocolRegistry(registry).treasury();
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
    function premiumConfig() external view override returns (PremiumConfig memory) {
        return _premiumConfig;
    }

    /// @inheritdoc IFundFactory
    function defaultIssuanceSteps() external view override returns (IssuanceStep[] memory) {
        return _issuanceSteps;
    }

    /// @inheritdoc IFundFactory
    function defaultYieldCurve() external view override returns (YieldPoint[] memory) {
        return _yieldCurve;
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

    function _setPremiumConfig(
        PremiumConfig memory config
    ) internal {
        if (!PremiumConfigLib.isValid(config)) revert InvalidPremiumConfig();
        _premiumConfig = config;
        emit PremiumConfigSet(config);
    }

    function _setIssuanceSteps(
        IssuanceStep[] memory steps
    ) internal {
        if (!PremiumConfigLib.stepsValid(steps)) revert InvalidPremiumConfig();
        delete _issuanceSteps;
        for (uint256 i; i < steps.length; ++i) {
            _issuanceSteps.push(steps[i]);
        }
        emit DefaultIssuanceStepsSet(steps);
    }

    /// @dev Bounds match the staking module's, which checks the yield cap again at creation.
    function _setYieldCurve(
        YieldPoint[] memory curve
    ) internal {
        if (curve.length > 8) revert InvalidPremiumConfig();
        delete _yieldCurve;
        for (uint256 i; i < curve.length; ++i) {
            if (i != 0 && curve[i].premiumBps <= curve[i - 1].premiumBps) revert InvalidPremiumConfig();
            _yieldCurve.push(curve[i]);
        }
        emit DefaultYieldCurveSet(curve);
    }

    function _proxy(Module module, bytes memory init) internal returns (address) {
        return address(new BeaconProxy(_beacons[module], init));
    }

    /// @dev UUPS upgrade gate.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

    function _onlyAdmin() private view {
        if (!isAdmin(msg.sender)) revert NotAdmin();
    }

    function _nonZero(
        address account
    ) private pure {
        if (account == address(0)) revert ZeroAddress();
    }
}
