// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundLaunch} from "../interfaces/IFundLaunch.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {CreateFundParams, LaunchConfig} from "../interfaces/types/FundTypes.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title FundFactory — MONEY Market Fund platform hub
/// @notice See {IFundFactory}.
/// @dev Runs behind an ERC-1967 proxy (UUPS); storage is append-only across upgrades. It owns
///      the three module beacons, so the factory owner upgrades every fund through
///      {upgradeModule}. The hook is wired once after deployment ({setHook}) because its address
///      must be mined against the factory address.
contract FundFactory is IFundFactory, Initializable, UUPSUpgradeable {
    /// @notice Hard cap on the protocol fee.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 500;

    /// @notice Hard cap on the rebalance slippage bound.
    uint16 public constant MAX_REBALANCE_SLIPPAGE_BPS = 1000;

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
    address public override lpFeeRecipient;

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
    /// @param protocolFeeRecipient_  Protocol fee recipient.
    /// @param lpFeeRecipient_        LP fee recipient.
    /// @param fundImpl               Fund implementation.
    /// @param launchImpl             Launch implementation.
    /// @param stakingImpl            Staking implementation.
    function initialize(
        address owner_,
        address oracle_,
        address usdg_,
        address protocolFeeRecipient_,
        address lpFeeRecipient_,
        address fundImpl,
        address launchImpl,
        address stakingImpl
    ) external initializer {
        if (
            owner_ == address(0) || oracle_ == address(0) || usdg_ == address(0) || protocolFeeRecipient_ == address(0)
                || lpFeeRecipient_ == address(0)
        ) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        oracle = oracle_;
        usdg = usdg_;

        protocolFeeBps = 50;
        emit ProtocolFeeSet(50);
        protocolFeeRecipient = protocolFeeRecipient_;
        emit ProtocolFeeRecipientSet(protocolFeeRecipient_);
        lpFeeRecipient = lpFeeRecipient_;
        emit LpFeeRecipientSet(lpFeeRecipient_);
        whitelistEnabled = true;
        emit WhitelistEnabledSet(true);
        maxRebalanceSlippageBps = 200;
        emit MaxRebalanceSlippageSet(200);
        rebalanceVolumeCapBps = 1000;
        emit RebalanceVolumeCapSet(1000);

        LaunchConfig memory cfg =
            LaunchConfig({duration: 36 hours, finalizeGrace: 7 days, usdgRatioBps: 3000, launchPremiumBps: 3000});
        _launchConfig = cfg;
        emit LaunchConfigSet(cfg);

        _beacons[Module.Fund] = address(new UpgradeableBeacon(fundImpl, address(this)));
        _beacons[Module.Launch] = address(new UpgradeableBeacon(launchImpl, address(this)));
        _beacons[Module.Staking] = address(new UpgradeableBeacon(stakingImpl, address(this)));
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
    ) external override returns (address fund, address launch, address staking) {
        if (whitelistEnabled && !isLauncher[msg.sender]) revert NotLauncher();
        if (hook == address(0)) revert HookNotSet();

        fund = address(new BeaconProxy(_beacons[Module.Fund], abi.encodeCall(IFund.initialize, (p))));
        launch = address(
            new BeaconProxy(
                _beacons[Module.Launch],
                abi.encodeCall(IFundLaunch.initialize, (fund, p.minGraduationUsd, _launchConfig))
            )
        );
        staking = address(
            new BeaconProxy(_beacons[Module.Staking], abi.encodeCall(IFundStaking.initialize, (fund, p.yieldTiers)))
        );

        IFund(fund).setModules(launch, staking);
        IFundHook(hook).registerFund(fund);
        isFund[fund] = true;
        _funds.push(fund);

        emit FundCreated(fund, launch, staking, msg.sender, p.manager);
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
    function setLpFeeRecipient(
        address recipient
    ) external override onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        lpFeeRecipient = recipient;
        emit LpFeeRecipientSet(recipient);
    }

    /// @inheritdoc IFundFactory
    function setWhitelistEnabled(
        bool enabled
    ) external override onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistEnabledSet(enabled);
    }

    /// @inheritdoc IFundFactory
    function setLauncher(
        address launcher,
        bool allowed
    ) external override onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    /// @inheritdoc IFundFactory
    function setRouter(
        address router,
        bool allowed
    ) external override onlyOwner {
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
            config.duration < 1 hours || config.duration > 30 days || config.finalizeGrace < 1 hours
                || config.finalizeGrace > 30 days || config.usdgRatioBps == 0 || config.usdgRatioBps > BPS
                || config.launchPremiumBps > BPS
        ) revert InvalidLaunchConfig();
        _launchConfig = config;
        emit LaunchConfigSet(config);
    }

    /// @inheritdoc IFundFactory
    function upgradeModule(
        Module module,
        address implementation
    ) external override onlyOwner {
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
    function beacon(
        Module module
    ) external view override returns (address) {
        return _beacons[module];
    }

    /// @dev UUPS upgrade gate.
    function _authorizeUpgrade(
        address
    ) internal view override onlyOwner {}
}
