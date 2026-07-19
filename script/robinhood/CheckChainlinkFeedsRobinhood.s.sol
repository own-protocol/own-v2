// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function aggregator() external view returns (address);
}

interface IScaledUiToken {
    function uiMultiplier() external view returns (uint256);
}

/// @title CheckChainlinkFeedsRobinhood — Read-only preflight for the Chainlink oracle migration
/// @notice No broadcast. Asserts the RPC points at Robinhood Chain (4663) and, for every asset the
///         protocol supports, verifies the Chainlink proxy's description/decimals and reads the
///         latest round. Stock-token feeds return the TOKEN price (underlying share price x the
///         ERC-8056 uiMultiplier) — the script also reads each token's uiMultiplier() and prints
///         the implied bare share price (feed / multiplier) so both can be cross-checked.
///
/// Feed behavior measured 2026-07 (see docs): 0.5% deviation-triggered updates, 24h heartbeat that
/// does NOT fire outside market sessions (feeds fully silent Fri 20:00 UTC -> Mon 00:00 UTC and on
/// US market holidays). USDG/USD is a 24/7 feed updating exactly every 24h.
///
/// Env: ROBINHOOD_RPC (via foundry.toml rpc_endpoints)
///
/// Usage:
///   forge script script/robinhood/CheckChainlinkFeedsRobinhood.s.sol --rpc-url robinhood
contract CheckChainlinkFeedsRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // Feed proxies from Chainlink's reference data directory (feeds-robinhood-mainnet), 2026-07-19.
    // Descriptions are not uniform ("RH<SYM> / USD" vs "Robinhood <SYM> / USD") — each entry pins
    // the exact on-chain string. Token addresses are the Gen-2 Stock Tokens (CheckChainRobinhood.s.sol).
    struct FeedCheck {
        string desc;
        address proxy;
        address token; // address(0) for non-equity feeds (no uiMultiplier)
    }

    function run() external view {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        console.log("Chain ID OK:", block.chainid);

        uint256 n = 8;
        FeedCheck[] memory feeds = new FeedCheck[](n);
        feeds[0] = FeedCheck(
            "RHMU / USD", 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596, 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD
        );
        feeds[1] = FeedCheck(
            "Robinhood SPCX / USD", 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb, 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa
        );
        feeds[2] = FeedCheck(
            "RHMSFT / USD", 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E, 0xe93237C50D904957Cf27E7B1133b510C669c2e74
        );
        feeds[3] = FeedCheck(
            "Robinhood GOOGL / USD",
            0xF6f373a037c30F0e5010d854385cA89185AE638b,
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3
        );
        feeds[4] = FeedCheck(
            "RHTSLA / USD", 0x4A1166a659A55625345e9515b32adECea5547C38, 0x322F0929c4625eD5bAd873c95208D54E1c003b2d
        );
        feeds[5] = FeedCheck(
            "RHSPY / USD", 0x319724394D3A0e3669269846abE664Cd621f9f6A, 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
        );
        feeds[6] = FeedCheck(
            "Robinhood QQQ / USD", 0x80901d846d5D7B030F26B480776EE3b29374C2ae, 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68
        );
        feeds[7] = FeedCheck("USDG / USD", 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, address(0));

        for (uint256 i = 0; i < n; i++) {
            FeedCheck memory f = feeds[i];
            IAggregatorV3 feed = IAggregatorV3(f.proxy);

            // Pinned description guards against address mixups.
            string memory desc = feed.description();
            require(keccak256(bytes(desc)) == keccak256(bytes(f.desc)), string.concat("description mismatch: ", f.desc));
            require(feed.decimals() == 8, string.concat("decimals != 8: ", f.desc));

            (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
            require(answer > 0, string.concat("non-positive answer: ", f.desc));
            require(updatedAt > 0 && updatedAt <= block.timestamp, string.concat("bad updatedAt: ", f.desc));
            // Widest legitimate silence = long weekend (~79h observed over July 4). 5 days flags a dead feed.
            require(block.timestamp - updatedAt < 5 days, string.concat("feed appears dead: ", f.desc));

            console.log("");
            console.log(desc, f.proxy);
            console.log("  aggregator:", feed.aggregator());
            console.log("  token price (8 dec):", uint256(answer));
            console.log("  age (s):", block.timestamp - updatedAt);

            if (f.token != address(0)) {
                uint256 mult = IScaledUiToken(f.token).uiMultiplier();
                require(mult > 0, string.concat("zero uiMultiplier: ", f.desc));
                console.log("  uiMultiplier (1e18):", mult);
                console.log("  implied share price (8 dec):", uint256(answer) * 1e18 / mult);
            }
        }

        console.log("");
        console.log("Chainlink feed preflight OK.");
    }
}
