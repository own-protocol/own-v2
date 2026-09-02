// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployEusdRobinhood — eUSD CDP module for the Robinhood Chain launch
/// @notice Standalone module: deploys the EUSD token and EUSDManager, wires eSPY as the launch
///         collateral, and registers both addresses in the ProtocolRegistry. Touches no existing
///         contract beyond the registry slots. Run after AddAssetsRobinhood.s.sol (SPY must be a
///         registered asset with a live oracle feed).
///
/// @dev Post-deploy checklist:
///        1. Verify eusd.hasRole(MINTER_ROLE, manager) and that the deployer no longer holds
///           DEFAULT_ADMIN_ROLE on the token (handed to EUSD_ADMIN_ROBINHOOD below).
///        2. If the registry's PROTOCOL_ADMIN has already moved to the timelock, the setAddress
///           registrations are skipped here — schedule them through the timelock instead.
///        3. Smoke-test in session: deposit eSPY, mint ≥ MIN_DEBT eUSD, repay, close.
///        4. Off-hours check: mint must revert StaleMintPrice; closePosition must succeed.
///        5. Bridging launches disabled by construction: no bridge has limits, and
///           maxNetBridgedIn defaults to 0 (fail-closed). Enabling a lane is a later Safe action —
///           setBridgeLimits(pool, mint, burn) AND setMaxNetBridgedIn(cap) — once a transport is
///           chosen. The home/CDP chain can keep maxNetBridgedIn at 0 (stays fully locally backed;
///           re-importing exported eUSD is still allowed); destination chains set a positive cap.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (deployer must hold ADMIN for addCollateral),
///      PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ADMIN_ROBINHOOD (final token admin, e.g. the Safe)
///
/// Usage:
///   forge script script/robinhood/DeployEusdRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployEusdRobinhood is Script {
    /// @dev Launch collateral asset (eSPY resolved from the AssetRegistry).
    bytes32 constant COLLATERAL_TICKER = bytes32("SPY");

    /// @dev Registry slots for the new module.
    bytes32 constant EUSD_KEY = keccak256("EUSD");
    bytes32 constant EUSD_MANAGER_KEY = keccak256("EUSD_MANAGER");

    /// @dev Launch risk parameters. MCR 150% / liquidation 130% are sized for closed-market
    ///      gaps — eSPY cannot be liquidated while US markets are closed, so the buffer must
    ///      absorb an overnight/weekend move. Fee 2%/yr simple; ceiling starts conservative.
    uint16 constant MCR_BPS = 15_000;
    uint16 constant LIQ_THRESHOLD_BPS = 13_000;
    uint16 constant LIQ_BONUS_BPS = 500;
    uint16 constant STABILITY_FEE_BPS = 200;
    uint256 constant DEBT_CEILING = 250_000e18;
    uint256 constant MIN_DEBT = 100e18;
    uint256 constant MINT_PRICE_MAX_AGE = 900; // 15 min — in-session marks report block.timestamp

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        address eusdAdmin = vm.envAddress("EUSD_ADMIN_ROBINHOOD");
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        address eSpy = AssetRegistry(registry.assetRegistry()).getActiveToken(COLLATERAL_TICKER);
        require(eSpy != address(0), "SPY not registered");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // 1. Token — deployer is temporary admin so it can wire the minter role.
        EUSD eusd = new EUSD(deployer);

        // 2. Manager — UUPS implementation behind an ERC-1967 proxy, initialized atomically.
        EUSDManager managerImpl = new EUSDManager();
        EUSDManager manager = EUSDManager(
            address(
                new ERC1967Proxy(
                    address(managerImpl),
                    abi.encodeCall(
                        EUSDManager.initialize,
                        (
                            address(registry),
                            address(eusd),
                            IEUSDManager.RiskParams({
                                mcrBps: MCR_BPS,
                                liquidationThresholdBps: LIQ_THRESHOLD_BPS,
                                liquidationBonusBps: LIQ_BONUS_BPS,
                                stabilityFeeBps: STABILITY_FEE_BPS,
                                debtCeiling: DEBT_CEILING,
                                minDebt: MIN_DEBT,
                                mintPriceMaxAge: MINT_PRICE_MAX_AGE
                            })
                        )
                    )
                )
            )
        );

        // 3. Sole minter = the manager; hand token admin to the Safe and drop the deployer.
        eusd.grantRole(eusd.MINTER_ROLE(), address(manager));
        eusd.grantRole(eusd.DEFAULT_ADMIN_ROLE(), eusdAdmin);
        eusd.renounceRole(eusd.DEFAULT_ADMIN_ROLE(), deployer);
        // A4-L-07: the supply == totalDebt invariant needs the manager to be the only minter. The
        // token is fresh, so the only addresses that could have been granted here are checked.
        require(eusd.hasRole(eusd.MINTER_ROLE(), address(manager)), "manager not minter");
        require(!eusd.hasRole(eusd.MINTER_ROLE(), deployer), "deployer is minter");
        require(!eusd.hasRole(eusd.MINTER_ROLE(), eusdAdmin), "admin is minter");
        require(!eusd.hasRole(eusd.DEFAULT_ADMIN_ROLE(), deployer), "deployer still token admin");

        // 4. Launch collateral (deployer must hold the protocol ADMIN role).
        manager.addCollateral(eSpy, COLLATERAL_TICKER);

        // 5. Registry slots — only possible while the deployer still holds PROTOCOL_ADMIN;
        //    otherwise schedule these two setAddress calls through the timelock.
        if (registry.hasRole(0x00, deployer)) {
            registry.setAddress(EUSD_KEY, address(eusd));
            registry.setAddress(EUSD_MANAGER_KEY, address(manager));
        } else {
            console.log("PROTOCOL_ADMIN not held by deployer - register via timelock:");
            console.logBytes32(EUSD_KEY);
            console.logBytes32(EUSD_MANAGER_KEY);
        }

        vm.stopBroadcast();

        console.log("EUSD:        ", address(eusd));
        console.log("EUSDManager: ", address(manager));
        console.log("Collateral:  ", eSpy);
    }
}
