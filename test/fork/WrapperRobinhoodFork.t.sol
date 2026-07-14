// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WrapperBaseForkTest} from "./WrapperBaseFork.t.sol";

/// @title WrapperRobinhoodFork — live-wrapper due diligence on Robinhood Chain
/// @notice Same suite as WrapperBaseFork (metadata, transfer restrictions, custody round-trip)
///         run against a Gen-2 Robinhood Stock Token on a Robinhood Chain fork. Both env vars
///         must be set or every test skips:
///           ROBINHOOD_RPC            — Robinhood Chain RPC endpoint
///           WRAPPER_TOKEN_ROBINHOOD  — the candidate Gen-2 token address (e.g. TSLA
///                                      0x322F0929c4625eD5bAd873c95208D54E1c003b2d)
///         Run before DeployPsmRobinhood.s.sol for every backing token. NOTE: passing custody
///         tests does not clear the issuer-admin-powers review (pause/freeze/upgrade) — read the
///         verified source on Blockscout separately.
contract WrapperRobinhoodForkTest is WrapperBaseForkTest {
    function _rpcEnvVar() internal pure override returns (string memory) {
        return "ROBINHOOD_RPC";
    }

    function _wrapperEnvVar() internal pure override returns (string memory) {
        return "WRAPPER_TOKEN_ROBINHOOD";
    }
}
