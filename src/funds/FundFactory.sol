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
///      the six module beacons, so the factory owner upgrades every fund through
///      {upgradeModule}. The hook is wired once after deployment ({setHook}) because its address
///      must be mined against the factory address.
contract FundFactory is IFundFactory, Initializable, UUPSUpgradeable {
    /// @notice Hard cap on the protocol fee.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 500;

    /// @notice Hard cap on the rebalance slippage bound.
    uint16 public constant MAX_REBALANCE_SLIPPAGE_BPS = 1000;

    /// @notice Default staking yield cap: 3% a day.
    uint16 public constant DEFAULT_MAX_YIELD_RATE_BPS_PER_DAY = 300;

    /// @notice Hard cap on the bribe cut.
    uint16 public constant MAX_BRIBE_CUT_BPS = 1000;

    /// @notice Hard cap on the curator cap.
    uint8 public constant MAX_CURATOR_CAP = 50;

    /// @notice Launch supply used when a fund sets none.
    uint256 public constant DEFAULT_LAUNCH_SUPPLY = 100_000_000e18;

    /// @notice Launch window used when a fund sets none.
    uint32 public constant DEFAULT_LAUNCH_DURATION = 7 days;

    /// @inheritdoc IFundFactory
    address public override owner;

    /// @inheritdoc IFundFactory
    address public override pendingOwner;

    /// @inheritdoc IFundFactory
    address public override oracle;

    /// @inheritdoc IFundFactory
    address public override usdg;

    /// @inheritdoc IFundFactory
    address public override hook;

    /// @inheritdoc IFundFactory
    uint16 public override protocolFeeBps;

    /// @inheritdoc IFundFactory
    address public override protocolFeeRecipient;

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
    uint16 public override maxYieldRateBpsPerDay;

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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the factory proxy.
    /// @param owner_                 Platform admin.
    /// @param oracle_                Shared price oracle.
    /// @param usdg_                  USDG token.
    /// @param protocolFeeRecipient_  Protocol fee recipient (Own's treasury; also gets the bribe cut).
    /// @param impls                  Implementations, indexed by {Module}.
    function initialize(
        address owner_,
        address oracle_,
        address usdg_,
        address protocolFeeRecipient_,
        address[6] calldata impls
    ) external initializer {
        if (owner_ == address(0) || oracle_ == address(0) || usdg_ == address(0) || protocolFeeRecipient_ == address(0))
        {
            revert ZeroAddress();
        }
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        oracle = oracle_;
        usdg = usdg_;

        protocolFeeBps = 50;
        emit ProtocolFeeSet(50);
        protocolFeeRecipient = protocolFeeRecipient_;
        emit ProtocolFeeRecipientSet(protocolFeeRecipient_);
        whitelistEnabled = true;
        emit WhitelistEnabledSet(true);
        maxRebalanceSlippageBps = 200;
        emit MaxRebalanceSlippageSet(200);
        rebalanceVolumeCapBps = 1000;
        emit RebalanceVolumeCapSet(1000);

        LaunchConfig memory cfg = LaunchConfig({
            duration: DEFAULT_LAUNCH_DURATION,
            finalizeGrace: 7 days,
            usdgRatioBps: 3000,
            launchPremiumBps: 3000,
            earlyYieldBpsPerDay: 50,
            overweightHaircutBps: 500,
            withdrawCutoff: 1 days,
            depositorLock: 7 days
        });
        _launchConfig = cfg;
        emit LaunchConfigSet(cfg);

        maxYieldRateBpsPerDay = DEFAULT_MAX_YIELD_RATE_BPS_PER_DAY;
        emit MaxYieldRateSet(DEFAULT_MAX_YIELD_RATE_BPS_PER_DAY);

        GovernanceConfig memory gov = GovernanceConfig({
            curatorShareBps: 3000,
            minVoteBps: 200,
            maxWeightBps: 2500,
            maxWeeklyShiftBps: 500,
            dropAfterEpochs: 4,
            quorumBps: 2000,
            votingPeriod: 3 days,
            vetoPeriod: 1 days,
            executionWindow: 7 days,
            proposalThresholdUsd: 5000e18
        });
        _governanceConfig = gov;
        emit GovernanceConfigSet(gov);

        curatorCap = 10;
        emit CuratorCapSet(10);
        bribeCutBps = 500;
        emit BribeCutSet(500);

        for (uint256 i; i < 6; ++i) {
            _beacons[Module(i)] = address(new UpgradeableBeacon(impls[i], address(this)));
        }
    }

    /// @notice Wire the pool hook. Owner only, once.
    /// @param hook_ The hook (deployed against this factory).
    function setHook(
        address hook_
    ) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @inheritdoc IFundFactory
    function createFund(
        CreateFundParams calldata p
    ) external override returns (FundModules memory m) {
        if (msg.sender != owner && whitelistEnabled && !isLauncher[msg.sender]) revert NotLauncher();
        if (hook == address(0)) revert HookNotSet();
        LaunchConfig memory cfg = _launchConfig;
        if (p.launchDuration != 0) cfg.duration = p.launchDuration;
        if (cfg.duration < 1 days || cfg.duration > 30 days) revert InvalidLaunchConfig();
        uint256 supply = p.launchSupply == 0 ? DEFAULT_LAUNCH_SUPPLY : p.launchSupply;

        m.fund = _proxy(Module.Fund, abi.encodeCall(IFund.initialize, (p)));
        m.launch = _proxy(Module.Launch, abi.encodeCall(IFundLaunch.initialize, (m.fund, p.minRaiseUsd, supply, cfg)));
        m.staking = _proxy(Module.Staking, abi.encodeCall(IFundStaking.initialize, (m.fund, p.yieldTiers)));
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
    function setProtocolFee(
        uint16 feeBps
    ) external override onlyOwner {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        protocolFeeBps = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    /// @inheritdoc IFundFactory
    function setProtocolFeeRecipient(
        address recipient
    ) external override onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    /// @inheritdoc IFundFactory
    function setCuratorCap(
        uint8 cap
    ) external override onlyOwner {
        if (cap == 0 || cap > MAX_CURATOR_CAP) revert InvalidCuratorCap();
        curatorCap = cap;
        emit CuratorCapSet(cap);
    }

    /// @inheritdoc IFundFactory
    function setBribeCut(
        uint16 cutBps
    ) external override onlyOwner {
        if (cutBps > MAX_BRIBE_CUT_BPS) revert FeeTooHigh();
        bribeCutBps = cutBps;
        emit BribeCutSet(cutBps);
    }

    /// @inheritdoc IFundFactory
    function setBribeToken(address token, bool allowed) external override onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isBribeToken[token] = allowed;
        emit BribeTokenSet(token, allowed);
    }

    /// @inheritdoc IFundFactory
    function setEligibleAsset(address token, bool eligible) external override onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isEligibleAsset[token] = eligible;
        emit EligibleAssetSet(token, eligible);
    }

    /// @inheritdoc IFundFactory
    function setWhitelistEnabled(
        bool enabled
    ) external override onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistEnabledSet(enabled);
    }

    /// @inheritdoc IFundFactory
    function setLauncher(address launcher, bool allowed) external override onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    /// @inheritdoc IFundFactory
    function setRouter(address router, bool allowed) external override onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = allowed;
        emit RouterSet(router, allowed);
    }

    /// @inheritdoc IFundFactory
    function setMaxRebalanceSlippage(
        uint16 slippageBps
    ) external override onlyOwner {
        if (slippageBps > MAX_REBALANCE_SLIPPAGE_BPS) revert InvalidSlippage();
        maxRebalanceSlippageBps = slippageBps;
        emit MaxRebalanceSlippageSet(slippageBps);
    }

    /// @inheritdoc IFundFactory
    function setRebalanceVolumeCap(
        uint16 capBps
    ) external override onlyOwner {
        if (capBps > BPS) revert InvalidSlippage();
        rebalanceVolumeCapBps = capBps;
        emit RebalanceVolumeCapSet(capBps);
    }

    /// @inheritdoc IFundFactory
    function setLaunchConfig(
        LaunchConfig calldata config
    ) external override onlyOwner {
        if (
            config.duration < 1 days || config.duration > 30 days || config.finalizeGrace < 1 hours
                || config.finalizeGrace > 30 days || config.usdgRatioBps == 0 || config.usdgRatioBps > BPS
                || config.launchPremiumBps > BPS || config.earlyYieldBpsPerDay > 100 || config.overweightHaircutBps > 5000
                || config.withdrawCutoff > config.duration || config.depositorLock > 30 days
        ) revert InvalidLaunchConfig();
        _launchConfig = config;
        emit LaunchConfigSet(config);
    }

    /// @inheritdoc IFundFactory
    function setMaxYieldRate(
        uint16 rateBpsPerDay
    ) external override onlyOwner {
        if (rateBpsPerDay > BPS) revert InvalidYieldCap();
        maxYieldRateBpsPerDay = rateBpsPerDay;
        emit MaxYieldRateSet(rateBpsPerDay);
    }

    /// @inheritdoc IFundFactory
    function setGovernanceConfig(
        GovernanceConfig calldata config
    ) external override onlyOwner {
        if (!GovernanceConfigLib.isValid(config)) revert InvalidGovernanceConfig();
        _governanceConfig = config;
        emit GovernanceConfigSet(config);
    }

    /// @inheritdoc IFundFactory
    function setPlatformMetadata(
        PlatformMetadata calldata metadata
    ) external override onlyOwner {
        _platformMetadata = metadata;
        emit PlatformMetadataSet(metadata);
    }

    /// @inheritdoc IFundFactory
    function upgradeModule(Module module, address implementation) external override onlyOwner {
        UpgradeableBeacon(_beacons[module]).upgradeTo(implementation);
        emit ModuleUpgraded(module, implementation);
    }

    /// @inheritdoc IFundFactory
    function transferOwnership(
        address newOwner
    ) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    /// @inheritdoc IFundFactory
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
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
    ) internal view override onlyOwner {}
}
