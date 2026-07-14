// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";

/// @title TestSetupTslaRobinhood — Prep for the TSLA mint/borrow E2E test (admin, deployer key)
/// @notice One-time setup, all broadcast by the deployer (ADMIN):
///           1. registerSigner(operator, operator)      — operator becomes an RFQ quote signer;
///              linked = operator, so mint proceeds land on it (and fund the later redeem)
///           2. setMakerAllowed(TSLA, operator)         — arm the maker grant for the test signer
///           3. updatePrice("TSLA", $331) + pullAssetPrice — attest a fresh TSLA mark
///
/// The TSLA price is a TEST placeholder ($331, ~the live quote). Operator signs via vm.sign.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (broadcast/admin), OPERATOR_PRIVATE_KEY_ROBINHOOD (signing)
///
/// Usage:
///   forge script script/robinhood/TestSetupTslaRobinhood.s.sol --rpc-url robinhood --broadcast
contract TestSetupTslaRobinhood is Script {
    address constant VAULT_MANAGER = 0xfA2981bA6F5E955f3FF4c9DBd9a79Ff29015d352;
    address constant ASSET_REGISTRY = 0xDfEFfe8C385A28351Cc07a249A3B2C15Fe7b928A;
    address constant INHOUSE_ORACLE = 0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055;

    bytes32 constant TSLA = bytes32("TSLA");
    uint256 constant TSLA_PRICE = 331e18; // TEST placeholder — keep in sync across test scripts

    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_ROBINHOOD");
        address operator = vm.addr(operatorPk);

        OracleVerifier oracle = OracleVerifier(INHOUSE_ORACLE);

        uint256 ts = block.timestamp;
        bytes32 digest = oracle.priceDigest(TSLA, TSLA_PRICE, ts);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        bytes memory priceData = abi.encode(TSLA_PRICE, ts, v, r, s);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        VaultManager(VAULT_MANAGER).registerSigner(operator, operator); // linked = operator
        AssetRegistry(ASSET_REGISTRY).setMakerAllowed(TSLA, operator, true);
        oracle.updatePrice(TSLA, priceData);
        VaultManager(VAULT_MANAGER).pullAssetPrice(TSLA);

        vm.stopBroadcast();

        console.log("Operator quote signer + linked + maker grant:", operator);
        console.log("TSLA mark (1e18):", VaultManager(VAULT_MANAGER).assetMark(TSLA));
    }
}
