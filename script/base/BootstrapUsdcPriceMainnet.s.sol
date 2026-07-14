// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";

/// @title BootstrapUsdcPriceMainnet — Add the operator as an oracle signer and attest the USDC mark
/// @notice One-time bootstrap so the aUSDC vault's collateral can be priced without waiting on the
///         off-chain KMS signer service. Does, all broadcast by the deployer (ADMIN):
///           1. addSigner(operator)                          — authorise the operator key
///           2. setAssetOracleConfig("USDC", staleness, dev) — required before any updatePrice
///           3. updatePrice("USDC", $1) signed by operator   — EIP-712 attestation via vm.sign
///           4. pullCollateralPrice(vault)                   — refresh the vault's collateral mark
///
/// The operator address is derived from OPERATOR_PRIVATE_KEY_MAINNET (no separate public-key env
/// needed). NOTE: an oracle signer is GLOBAL across all assets — removeSigner once KMS is sole signer.
///
/// Env: DEPLOYER_PRIVATE_KEY_MAINNET (broadcast/admin), OPERATOR_PRIVATE_KEY_MAINNET (signing key)
///
/// Usage:
///   forge script script/mainnet/BootstrapUsdcPriceMainnet.s.sol --rpc-url base --broadcast
contract BootstrapUsdcPriceMainnet is Script {
    // Base mainnet deploy (see docs/contracts-mainnet.md).
    address constant INHOUSE_ORACLE = 0xc82f5835Fe132D34A7491961e2875941CF37aE03;
    address constant VAULT_MANAGER = 0x4A3c284f3293250C84899A220Cf4Cb6dFCd317ba;
    address constant VAULT = 0xfF8d4d4D139716d32d3A3C0bD7a2cE55a916E91A;

    bytes32 constant USDC_TICKER = bytes32("USDC");
    uint256 constant USDC_PRICE = 1e18; // $1.00 (18-decimal price convention)
    uint256 constant MAX_STALENESS = 1 days; // generous for a stablecoin collateral mark
    uint256 constant MAX_DEVIATION_BPS = 200; // 2%

    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_MAINNET");
        address operator = vm.addr(operatorPk);

        OracleVerifier oracle = OracleVerifier(INHOUSE_ORACLE);
        VaultManager vaultManager = VaultManager(VAULT_MANAGER);

        // Sign the EIP-712 PriceAttestation off-chain with the operator key (no broadcast).
        uint256 ts = block.timestamp;
        bytes32 digest = oracle.priceDigest(USDC_TICKER, USDC_PRICE, ts);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        bytes memory priceData = abi.encode(USDC_PRICE, ts, v, r, s);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));

        oracle.addSigner(operator); // idempotent
        oracle.setAssetOracleConfig(USDC_TICKER, MAX_STALENESS, MAX_DEVIATION_BPS);
        oracle.updatePrice(USDC_TICKER, priceData);
        vaultManager.pullCollateralPrice(VAULT);

        vm.stopBroadcast();

        (uint256 stored, uint256 storedTs) = oracle.getPrice(USDC_TICKER);
        console.log("Operator signer:", operator);
        console.log("USDC price stored (1e18):", stored);
        console.log("USDC price timestamp:", storedTs);
        console.log("Collateral mark pulled (0 until first deposit; re-pull after seed deposit).");
    }
}
