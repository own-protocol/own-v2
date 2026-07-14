// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";

/// @title BootstrapUsdgPriceRobinhood — Add the operator as an oracle signer and attest the USDG mark
/// @notice One-time bootstrap so the oUSDG vault's collateral can be priced without waiting on the
///         off-chain KMS signer service. Does, all broadcast by the deployer (ADMIN):
///           1. addSigner(operator)                          — authorise the operator key
///           2. setAssetOracleConfig("USDG", staleness, dev) — required before any updatePrice
///           3. updatePrice("USDG", $1) signed by operator   — EIP-712 attestation via vm.sign
///           4. pullCollateralPrice(vault)                   — refresh the vault's collateral mark
///
/// The operator address is derived from OPERATOR_PRIVATE_KEY_ROBINHOOD (no separate public-key env
/// needed). NOTE: an oracle signer is GLOBAL across all assets — removeSigner once KMS is sole signer.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (broadcast/admin), OPERATOR_PRIVATE_KEY_ROBINHOOD (signing key),
///      PROTOCOL_REGISTRY_ROBINHOOD, VAULT_ADDRESS_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/BootstrapUsdgPriceRobinhood.s.sol --rpc-url robinhood --broadcast
contract BootstrapUsdgPriceRobinhood is Script {
    bytes32 constant USDG_TICKER = bytes32("USDG");
    uint256 constant USDG_PRICE = 1e18; // $1.00 (18-decimal price convention)
    uint256 constant MAX_STALENESS = 1 days; // generous for a stablecoin collateral mark
    uint256 constant MAX_DEVIATION_BPS = 200; // 2%

    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_ROBINHOOD");
        address operator = vm.addr(operatorPk);

        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        OracleVerifier oracle = OracleVerifier(registry.inhouseOracle());
        VaultManager vaultManager = VaultManager(registry.vaultManager());
        address vault = vm.envAddress("VAULT_ADDRESS_ROBINHOOD");

        // Sign the EIP-712 PriceAttestation off-chain with the operator key (no broadcast).
        uint256 ts = block.timestamp;
        bytes32 digest = oracle.priceDigest(USDG_TICKER, USDG_PRICE, ts);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        bytes memory priceData = abi.encode(USDG_PRICE, ts, v, r, s);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        oracle.addSigner(operator); // idempotent
        oracle.setAssetOracleConfig(USDG_TICKER, MAX_STALENESS, MAX_DEVIATION_BPS);
        oracle.updatePrice(USDG_TICKER, priceData);
        vaultManager.pullCollateralPrice(vault);

        vm.stopBroadcast();

        console.log("USDG mark attested at $1 by operator:", operator);
        console.log("Vault collateral mark pulled:", vault);
    }
}
