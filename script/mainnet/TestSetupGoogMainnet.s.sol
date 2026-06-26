// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";

/// @title TestSetupGoogMainnet — Prep for the GOOG mint/borrow E2E test (admin, deployer key)
/// @notice One-time setup, all broadcast by the deployer (ADMIN):
///           1. setWithdrawalWaitPeriod(72h)            — vault LP-exit delay (was 0)
///           2. registerSigner(operator, operator)      — operator becomes an RFQ quote signer;
///              linked = operator, so mint proceeds land on it (and fund the later redeem)
///           3. updatePrice("GOOG", $340) + pullAssetPrice — attest a fresh GOOG mark
///
/// The GOOG price is a TEST placeholder ($340). Operator signs the attestation via vm.sign.
///
/// Env: DEPLOYER_PRIVATE_KEY_MAINNET (broadcast/admin), OPERATOR_PRIVATE_KEY_MAINNET (signing key)
///
/// Usage:
///   forge script script/mainnet/TestSetupGoogMainnet.s.sol --rpc-url base --broadcast
contract TestSetupGoogMainnet is Script {
    address payable constant VAULT = payable(0xfF8d4d4D139716d32d3A3C0bD7a2cE55a916E91A);
    address constant VAULT_MANAGER = 0x4A3c284f3293250C84899A220Cf4Cb6dFCd317ba;
    address constant INHOUSE_ORACLE = 0xc82f5835Fe132D34A7491961e2875941CF37aE03;

    bytes32 constant GOOG = bytes32("GOOG");
    uint256 constant GOOG_PRICE = 340e18; // TEST placeholder — adjust to a realistic mark if needed
    uint256 constant WITHDRAWAL_DELAY = 72 hours;

    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_MAINNET");
        address operator = vm.addr(operatorPk);

        OracleVerifier oracle = OracleVerifier(INHOUSE_ORACLE);

        // Sign the GOOG price attestation off-chain with the operator key.
        uint256 ts = block.timestamp;
        bytes32 digest = oracle.priceDigest(GOOG, GOOG_PRICE, ts);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        bytes memory priceData = abi.encode(GOOG_PRICE, ts, v, r, s);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));

        OwnVault(VAULT).setWithdrawalWaitPeriod(WITHDRAWAL_DELAY);
        VaultManager(VAULT_MANAGER).registerSigner(operator, operator); // linked = operator
        oracle.updatePrice(GOOG, priceData);
        VaultManager(VAULT_MANAGER).pullAssetPrice(GOOG);

        vm.stopBroadcast();

        console.log("Withdrawal delay (s):", OwnVault(VAULT).withdrawalWaitPeriod());
        console.log("Operator quote signer + linked:", operator);
        console.log("GOOG mark (1e18):", VaultManager(VAULT_MANAGER).assetMark(GOOG));
    }
}
