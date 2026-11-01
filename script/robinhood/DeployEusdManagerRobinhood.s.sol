// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {EUSDManager} from "../../src/eusd/EUSDManager.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DeployEusdManagerRobinhood — one EUSDManager proxy for a collateral risk group
/// @notice Deploys an EUSDManager proxy minting the existing eUSD, with risk params read from env.
///         Reuses EUSD_MANAGER_IMPL when set, otherwise deploys a fresh implementation. The proxy is
///         inert until the Safe grants it eUSD MINTER_ROLE and adds collateral. The registry's
///         oracle and treasury must be set before that: fees mint to the treasury on every touch.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ROBINHOOD,
///      EUSD_MANAGER_IMPL (optional), MCR_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, STABILITY_FEE_BPS,
///      DEBT_CEILING (18 dec), MIN_DEBT (18 dec), MINT_PRICE_MAX_AGE (seconds)
///
/// Usage:
///   forge script script/robinhood/DeployEusdManagerRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployEusdManagerRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external returns (address manager, address implementation) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        address eusd = vm.envAddress("EUSD_ROBINHOOD");

        IEUSDManager.RiskParams memory params = IEUSDManager.RiskParams({
            mcrBps: SafeCast.toUint16(vm.envUint("MCR_BPS")),
            liquidationThresholdBps: SafeCast.toUint16(vm.envUint("LIQ_THRESHOLD_BPS")),
            liquidationBonusBps: SafeCast.toUint16(vm.envUint("LIQ_BONUS_BPS")),
            stabilityFeeBps: SafeCast.toUint16(vm.envUint("STABILITY_FEE_BPS")),
            debtCeiling: vm.envUint("DEBT_CEILING"),
            minDebt: vm.envUint("MIN_DEBT"),
            mintPriceMaxAge: vm.envUint("MINT_PRICE_MAX_AGE")
        });
        // Typo guards: ratios within 100%..500%, bonus and fee at most 20%.
        require(params.mcrBps <= 50_000 && params.liquidationThresholdBps >= 10_000, "ratio out of range");
        require(params.liquidationBonusBps <= 2000 && params.stabilityFeeBps <= 2000, "bonus/fee out of range");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        implementation = vm.envOr("EUSD_MANAGER_IMPL", address(0));
        if (implementation == address(0)) implementation = address(new EUSDManager());
        manager = address(
            new ERC1967Proxy(implementation, abi.encodeCall(EUSDManager.initialize, (address(registry), eusd, params)))
        );
        vm.stopBroadcast();

        console.log("EUSDManager impl: ", implementation);
        console.log("EUSDManager proxy:", manager);
    }
}
