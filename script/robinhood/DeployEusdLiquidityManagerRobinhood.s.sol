// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {EUSDLiquidityManager} from "../../src/eusd/EUSDLiquidityManager.sol";
import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DeployEusdLiquidityManagerRobinhood — one EUSDLiquidityManager proxy for a volatility group
/// @notice Deploys an EUSDLiquidityManager proxy minting the existing eUSD, with risk params read
///         from env. Reuses EUSD_LIQ_MANAGER_IMPL when set, otherwise deploys a fresh implementation.
///         Reuses FABLES_VAULT_BEACON when set, otherwise deploys the FablesAdapter implementation
///         and its UpgradeableBeacon owned by the governance Safe (one beacon serves every manager).
///         The proxy is inert until the Safe grants it eUSD MINTER_ROLE and adds pools with
///         `addPool(beacon, asset, ticker, abi.encode(poolKey))`.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ROBINHOOD, GOV_SAFE_ROBINHOOD,
///      FABLES_POOL_MANAGER, FABLES_EMISSION_STREAM, EUSD_LIQ_MANAGER_IMPL (optional),
///      FABLES_VAULT_BEACON (optional), MCR_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, STAKED_FEE_BPS,
///      UNSTAKED_FEE_BPS, POOL_PRICE_BAND_BPS, DEBT_CEILING (18 dec), MIN_DEBT (18 dec),
///      MINT_PRICE_MAX_AGE (seconds)
///
/// Usage:
///   forge script script/robinhood/DeployEusdLiquidityManagerRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployEusdLiquidityManagerRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external returns (address manager, address implementation, address beacon) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        address registry = vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD");
        address eusd = vm.envAddress("EUSD_ROBINHOOD");
        IEUSDLiquidityManager.RiskParams memory params = _params();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        beacon = vm.envOr("FABLES_VAULT_BEACON", address(0));
        if (beacon == address(0)) {
            address vaultImpl = address(
                new FablesAdapter(vm.envAddress("FABLES_POOL_MANAGER"), vm.envAddress("FABLES_EMISSION_STREAM"))
            );
            beacon = address(new UpgradeableBeacon(vaultImpl, vm.envAddress("GOV_SAFE_ROBINHOOD")));
        }
        implementation = vm.envOr("EUSD_LIQ_MANAGER_IMPL", address(0));
        if (implementation == address(0)) implementation = address(new EUSDLiquidityManager());
        manager = address(
            new ERC1967Proxy(implementation, abi.encodeCall(EUSDLiquidityManager.initialize, (registry, eusd, params)))
        );
        vm.stopBroadcast();

        console.log("EUSDLiquidityManager impl: ", implementation);
        console.log("EUSDLiquidityManager proxy:", manager);
        console.log("Fables vault beacon:       ", beacon);
    }

    function _params() internal view returns (IEUSDLiquidityManager.RiskParams memory params) {
        params = IEUSDLiquidityManager.RiskParams({
            mcrBps: SafeCast.toUint16(vm.envUint("MCR_BPS")),
            liquidationThresholdBps: SafeCast.toUint16(vm.envUint("LIQ_THRESHOLD_BPS")),
            liquidationBonusBps: SafeCast.toUint16(vm.envUint("LIQ_BONUS_BPS")),
            stakedFeeBps: SafeCast.toUint16(vm.envUint("STAKED_FEE_BPS")),
            unstakedFeeBps: SafeCast.toUint16(vm.envUint("UNSTAKED_FEE_BPS")),
            poolPriceBandBps: SafeCast.toUint16(vm.envUint("POOL_PRICE_BAND_BPS")),
            debtCeiling: vm.envUint("DEBT_CEILING"),
            minDebt: vm.envUint("MIN_DEBT"),
            mintPriceMaxAge: vm.envUint("MINT_PRICE_MAX_AGE")
        });
        // Typo guards: ratios within 100%..500%, bonus and fees at most 20%, band at most 10%.
        require(params.mcrBps <= 50_000 && params.liquidationThresholdBps >= 10_000, "ratio out of range");
        require(
            params.liquidationBonusBps <= 2000 && params.stakedFeeBps <= 2000 && params.unstakedFeeBps <= 2000,
            "bonus/fee out of range"
        );
        require(params.poolPriceBandBps <= 1000, "band out of range");
        // Unit guards: amounts are 18-dec (1 to 1B eUSD), price age is seconds (at most 1h).
        require(params.minDebt >= 1e18 && params.minDebt <= params.debtCeiling, "minDebt out of range");
        require(params.debtCeiling <= 1e27, "debtCeiling out of range");
        require(params.mintPriceMaxAge <= 1 hours, "mintPriceMaxAge out of range");
    }
}
