// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title UpgradeEusdManagerRobinhood — Deploy a new EUSDManager implementation and upgrade the proxy
/// @notice The single upgrade path for EUSDManager logic on Robinhood. If the broadcaster holds
///         the protocol ADMIN role the upgrade executes directly; otherwise the implementation is
///         still deployed and the exact upgrade calldata is printed for governance (Safe/timelock).
///
/// @dev PRE-UPGRADE CHECKLIST — do not skip:
///        1. Storage layout is append-only from the live baseline: diff
///           `forge inspect EUSDManager storageLayout` against the deployed implementation's
///           layout. Reordered/removed/retyped slots corrupt live positions.
///        2. `forge test` green, including the UUPS suite in test/unit/EUSDManager.t.sol.
///        3. Post-upgrade smoke test: read a known pre-upgrade position and totalDebt, verify
///           stakeZap() returns address(0) until setStakeZap wires the zap.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD. Registry and proxy addresses are pinned as constants
///      below (docs/contracts-robinhood.md is the source of truth).
///
/// Usage:
///   forge script script/robinhood/UpgradeEusdManagerRobinhood.s.sol --rpc-url robinhood \
///     --broadcast --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api/
contract UpgradeEusdManagerRobinhood is Script {
    bytes32 private constant ADMIN = keccak256("ADMIN");

    // ── Live Robinhood Chain (4663) addresses — docs/contracts-robinhood.md ──
    address constant PROTOCOL_REGISTRY = 0x93e08ca467046737F75AAD4C936356c196AaA36F;
    address constant EUSD_MANAGER_PROXY = 0x9748964d733Ff5d47F1d7E3fea620aF014dA5a9b;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(PROTOCOL_REGISTRY);
        address proxy = EUSD_MANAGER_PROXY;
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // Pre-upgrade state to assert against after the switch.
        uint256 totalDebtBefore = EUSDManager(proxy).totalDebt();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // 1. Fresh implementation.
        EUSDManager newImpl = new EUSDManager();

        // 2. Upgrade directly if the broadcaster holds ADMIN; otherwise hand the calldata to
        //    governance. The implementation deploy above is useful either way.
        if (registry.hasRole(ADMIN, deployer)) {
            UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");
        } else {
            console.log("Deployer lacks ADMIN - schedule via governance:");
            console.log("  target:", proxy);
            console.log("  calldata:");
            console.logBytes(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), bytes(""))));
        }

        vm.stopBroadcast();

        // Sanity: proxy state intact, still bound to this registry, new surface present and unset.
        if (registry.hasRole(ADMIN, deployer)) {
            require(address(EUSDManager(proxy).registry()) == address(registry), "registry mismatch after upgrade");
            require(EUSDManager(proxy).totalDebt() == totalDebtBefore, "totalDebt drift after upgrade");
            require(EUSDManager(proxy).stakeZap() == address(0), "stakeZap unexpectedly set");
            console.log("Upgraded EUSDManager proxy:", proxy);
        }
        console.log("New implementation:", address(newImpl));
    }
}
