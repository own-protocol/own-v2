// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title CheckChainRobinhood — Read-only preflight for the Robinhood Chain deploy
/// @notice No broadcast. Asserts the RPC points at Robinhood Chain (4663), verifies USDG
///         metadata (Global Dollar, 6 decimals), and reads symbol/decimals + the ERC-8056
///         `uiMultiplier()` of each Gen-2 Stock Token the launch plan references. Run this
///         before any deploy script; a revert here means an address or the RPC is wrong.
///
/// Env: ROBINHOOD_RPC (via foundry.toml rpc_endpoints)
///
/// Usage:
///   forge script script/robinhood/CheckChainRobinhood.s.sol --rpc-url robinhood
contract CheckChainRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // Paxos Global Dollar — native issuance on Robinhood Chain (docs.paxos.com + docs.robinhood.com/chain/contracts).
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external view {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        console.log("Chain ID OK:", block.chainid);

        IERC20Metadata usdg = IERC20Metadata(USDG);
        require(usdg.decimals() == 6, "USDG decimals != 6");
        console.log("USDG:", USDG);
        console.log("  name/symbol/decimals:", usdg.name(), usdg.symbol(), usdg.decimals());

        // Gen-2 Stock Tokens (Robinhood Assets (Jersey) Ltd) — docs.robinhood.com/chain/contracts.
        uint256 n = 7;
        string[] memory labels = new string[](n);
        address[] memory tokens = new address[](n);
        (labels[0], tokens[0]) = ("MU", 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD);
        (labels[1], tokens[1]) = ("SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa);
        (labels[2], tokens[2]) = ("MSFT", 0xe93237C50D904957Cf27E7B1133b510C669c2e74);
        (labels[3], tokens[3]) = ("GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3);
        (labels[4], tokens[4]) = ("TSLA", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d);
        (labels[5], tokens[5]) = ("SPY", 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C);
        (labels[6], tokens[6]) = ("QQQ", 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68);

        console.log("");
        console.log("Gen-2 Stock Tokens:");
        for (uint256 i = 0; i < n; i++) {
            IERC20Metadata t = IERC20Metadata(tokens[i]);
            string memory sym = t.symbol();
            uint8 dec = t.decimals();
            require(keccak256(bytes(sym)) == keccak256(bytes(labels[i])), "symbol mismatch");
            require(dec == 18, "stock token decimals != 18");
            console.log(sym, tokens[i], dec);

            // ERC-8056 dividend/split multiplier — informational (oracle marks must include it).
            (bool ok, bytes memory ret) = tokens[i].staticcall(abi.encodeWithSignature("uiMultiplier()"));
            if (ok && ret.length == 32) {
                console.log("  uiMultiplier:", abi.decode(ret, (uint256)));
            } else {
                console.log("  uiMultiplier: <not exposed>");
            }
        }

        console.log("");
        console.log("Preflight OK. Next: DeployRobinhood.s.sol");
    }
}
