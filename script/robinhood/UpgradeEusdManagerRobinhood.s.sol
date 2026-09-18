// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {EUSDManager} from "../../src/eusd/EUSDManager.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
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
///        3. Post-upgrade smoke test: totalDebt, stakeZap and the eTSLA head position must be
///           unchanged, with the appended feesAccrued field reading zero for live positions.
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
    address constant ETSLA = 0x82D2F4e0649Fc77C2dF7fcF3b6c7e50a1F2F50f4;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(PROTOCOL_REGISTRY);
        address proxy = EUSD_MANAGER_PROXY;
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // Pre-upgrade state to assert against after the switch. The live v2 Position struct has
        // three fields, so the head position is read raw — the new four-field ABI would revert.
        uint256 totalDebtBefore = EUSDManager(proxy).totalDebt();
        address stakeZapBefore = EUSDManager(proxy).stakeZap();
        address headBefore = EUSDManager(proxy).listHead(ETSLA);
        uint256 headCollBefore;
        uint256 headDebtBefore;
        if (headBefore != address(0)) {
            (bool ok, bytes memory raw) =
                proxy.staticcall(abi.encodeCall(IEUSDManager.getPosition, (ETSLA, headBefore)));
            require(ok, "pre-upgrade position read failed");
            (headCollBefore, headDebtBefore) = abi.decode(raw, (uint256, uint256));
        }

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

        // Sanity: proxy state intact, still bound to this registry, live positions untouched and
        // the appended feesAccrued field zero-initialized.
        if (registry.hasRole(ADMIN, deployer)) {
            require(address(EUSDManager(proxy).registry()) == address(registry), "registry mismatch after upgrade");
            require(EUSDManager(proxy).totalDebt() == totalDebtBefore, "totalDebt drift after upgrade");
            require(EUSDManager(proxy).stakeZap() == stakeZapBefore, "stakeZap drift after upgrade");
            require(EUSDManager(proxy).listHead(ETSLA) == headBefore, "eTSLA list head drift after upgrade");
            if (headBefore != address(0)) {
                IEUSDManager.Position memory head = EUSDManager(proxy).getPosition(ETSLA, headBefore);
                require(head.collateral == headCollBefore, "head collateral drift after upgrade");
                require(head.debt == headDebtBefore, "head debt drift after upgrade");
                require(head.feesAccrued == 0, "head feesAccrued not zero-initialized");
            }
            console.log("Upgraded EUSDManager proxy:", proxy);
        }
        console.log("New implementation:", address(newImpl));
    }
}
