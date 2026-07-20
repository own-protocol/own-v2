// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ChainlinkOracleVerifier} from "../../src/core/ChainlinkOracleVerifier.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";

/// @title DeployChainlinkOracleRobinhood — Deploy + configure the Chainlink-primary oracle
/// @notice Step 1 of the oracle migration (see docs/chainlink-feeds-robinhood.md). Deploys
///         ChainlinkOracleVerifier, authorises the current KMS signer, and sets configs for all
///         15 tickers: 7 underlying + 7 R.* wrappers (same feed — multiplierToken deliberately
///         unset while every uiMultiplier is 1.0) + USDG (Chainlink-only, in-house disabled).
///         Does NOT touch the registry or asset routing — run SwitchOracleChainlinkRobinhood
///         afterwards to cut over. Ends with a read-only parity check vs the live in-house oracle.
///
/// NOTE: before the first corporate action / dividend that moves a token's uiMultiplier above 1.0
///       (MSFT, MU, GOOGL, SPY, QQQ pay distributions), the UNDERLYING ticker's config must be
///       re-set with multiplierToken = the Gen-2 token, or its price will drift above the bare
///       share price. Wrapper (R.*) tickers stay multiplier-inclusive forever — never set it there.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/DeployChainlinkOracleRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployChainlinkOracleRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // Current sole KMS oracle signer (docs/contracts-robinhood.md, rotated 2026-07-16).
    address constant KMS_SIGNER = 0xa7C894ff35407Ef4b7e699D1AfBf35487BbdFeBF;

    // Stock-ticker windows (docs/chainlink-feeds-robinhood.md).
    uint32 constant CL_SILENCE = 900; // 15 min feed silence before in-house quotes
    uint32 constant CL_FRESH_WINDOW = 4 hours; // reads report block.timestamp within this age
    uint32 constant MAX_ANCHOR_AGE = 5 days; // covers long weekends (~80h observed)
    uint32 constant INHOUSE_MAX_STALENESS = 1 hours; // matches old oracle / VaultManager maxMarkAge

    // USDG: 24/7 feed updating exactly every 24h; in-house permanently disabled (band 0).
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    uint32 constant USDG_FRESH_WINDOW = 25 hours;
    uint32 constant USDG_ANCHOR_AGE = 48 hours;

    // Off-hours bands (max in-house deviation from the Chainlink anchor). Sized to absorb
    // legitimate weekend gaps; PENDING final review — adjustable per asset via setChainlinkConfig.
    uint16 constant BAND_INDEX = 500; // 5% — SPY, QQQ
    uint16 constant BAND_SINGLE = 800; // 8% — single names + SPCX

    struct Asset {
        bytes32 underlying;
        bytes32 wrapper;
        address feed;
        uint16 bandBps;
    }

    function _assets() internal pure returns (Asset[] memory a) {
        a = new Asset[](7);
        // Feed proxies pinned by CheckChainlinkFeedsRobinhood.s.sol (descriptions asserted on-chain).
        a[0] = Asset("MU", "R.MU", 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596, BAND_SINGLE);
        a[1] = Asset("SPCX", "R.SPCX", 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb, BAND_SINGLE);
        a[2] = Asset("MSFT", "R.MSFT", 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E, BAND_SINGLE);
        a[3] = Asset("GOOGL", "R.GOOGL", 0xF6f373a037c30F0e5010d854385cA89185AE638b, BAND_SINGLE);
        a[4] = Asset("TSLA", "R.TSLA", 0x4A1166a659A55625345e9515b32adECea5547C38, BAND_SINGLE);
        a[5] = Asset("SPY", "R.SPY", 0x319724394D3A0e3669269846abE664Cd621f9f6A, BAND_INDEX);
        a[6] = Asset("QQQ", "R.QQQ", 0x80901d846d5D7B030F26B480776EE3b29374C2ae, BAND_INDEX);
    }

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        Asset[] memory assets = _assets();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        ChainlinkOracleVerifier verifier = new ChainlinkOracleVerifier(address(registry));
        verifier.addSigner(KMS_SIGNER);

        for (uint256 i = 0; i < assets.length; i++) {
            Asset memory a = assets[i];
            // Underlying and wrapper share one config today (all uiMultipliers are 1.0) — see NOTE.
            verifier.setChainlinkConfig(
                a.underlying,
                a.feed,
                address(0),
                CL_SILENCE,
                CL_FRESH_WINDOW,
                MAX_ANCHOR_AGE,
                INHOUSE_MAX_STALENESS,
                a.bandBps
            );
            verifier.setChainlinkConfig(
                a.wrapper,
                a.feed,
                address(0),
                CL_SILENCE,
                CL_FRESH_WINDOW,
                MAX_ANCHOR_AGE,
                INHOUSE_MAX_STALENESS,
                a.bandBps
            );
        }

        verifier.setChainlinkConfig(
            bytes32("USDG"), USDG_FEED, address(0), CL_SILENCE, USDG_FRESH_WINDOW, USDG_ANCHOR_AGE, 0, 0
        );

        vm.stopBroadcast();

        console.log("ChainlinkOracleVerifier:", address(verifier));
        console.log("Signer authorised:", KMS_SIGNER);
        console.log("Configs set: 7 underlying + 7 wrappers + USDG");

        // Read-only parity check vs the live in-house oracle (stale legs logged, not fatal —
        // the old oracle reverts once its 1h staleness lapses, e.g. on weekends).
        IOracleVerifier old = IOracleVerifier(registry.inhouseOracle());
        console.log("");
        console.log("Parity check (new vs old, 18 dec):");
        for (uint256 i = 0; i < assets.length; i++) {
            _logParity(verifier, old, assets[i].underlying);
            _logParity(verifier, old, assets[i].wrapper);
        }
        _logParity(verifier, old, bytes32("USDG"));
        console.log("");
        console.log("Next: SwitchOracleChainlinkRobinhood.s.sol with CHAINLINK_ORACLE_ROBINHOOD set");
    }

    function _logParity(ChainlinkOracleVerifier verifier, IOracleVerifier old, bytes32 ticker) internal view {
        string memory name = string(abi.encodePacked(ticker));
        try verifier.getPrice(ticker) returns (uint256 newPrice, uint256) {
            console.log(name, "new:", newPrice);
        } catch {
            console.log(name, "new: <unavailable>");
        }
        try old.getPrice(ticker) returns (uint256 oldPrice, uint256) {
            console.log(name, "old:", oldPrice);
        } catch {
            console.log(name, "old: <stale/unset>");
        }
    }
}
