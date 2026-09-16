// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {ChainlinkOracleVerifier} from "../../src/oracle/ChainlinkOracleVerifier.sol";
import {MoneyPriceFeed} from "../../src/oracle/MoneyPriceFeed.sol";

/// @title DeployMoneyFeedRobinhood — keeper-pushed $MONEY mark for OwnStakingV2 boost pricing
/// @notice Deploys MoneyPriceFeed and registers it as the MONEY aggregator on the live
///         ChainlinkOracleVerifier (resolved from the registry's INHOUSE_ORACLE slot) with
///         bandBps = 0 — the pushed mark is the only source; the in-house signer leg stays off.
///         The verifier config call needs the registry ADMIN role: executed directly when the
///         deployer holds it, otherwise printed as a ready-to-paste Safe call.
///
/// @dev clFreshWindow must stay close to the keeper push cadence (cadence + slack): while a mark
///      is younger than the window the verifier reports its timestamp as `now`, which hides true
///      age from OwnStakingV2's priceMaxAge gate.
///
/// @dev Post-deploy checklist:
///        1. Point the keeper service at the feed; push the first TWAP mark (18-dec USD).
///        2. Verify verifier.getPrice("MONEY") returns the pushed mark.
///        3. Confirm OwnStakingV2 picks it up: next boost-touching action snapshots a non-zero
///           $MONEY value (lastMoneyPrice caches on first use).
///        4. Monitor push cadence; alert if the feed goes silent beyond clFreshWindow.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/DeployMoneyFeedRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployMoneyFeedRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    /// @dev Keeper wallet allowed to push $MONEY marks (rotatable later via setKeeper).
    address constant KEEPER = 0xB1284eC8A142d71A3694b66e2fe9a8e0014de88e;
    bytes32 constant MONEY = bytes32("MONEY");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN");

    // TWAP marks are pushed continuously; the fresh window tracks the cadence, not market hours.
    uint32 constant CL_SILENCE = 900; // 15 min (floor required by the verifier; signer leg is off)
    uint32 constant CL_FRESH_WINDOW = 5400; // 90 min — hourly push cadence + slack for one late push
    uint32 constant MAX_ANCHOR_AGE = 86_400; // 1 day — beyond this the mark is unusable

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        ChainlinkOracleVerifier verifier = ChainlinkOracleVerifier(registry.inhouseOracle());
        require(address(verifier).code.length > 0, "INHOUSE_ORACLE is not a contract");
        require(address(verifier.registry()) == address(registry), "verifier registry mismatch");
        require(verifier.getChainlinkConfig(MONEY).aggregator == address(0), "MONEY already configured");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        MoneyPriceFeed feed = new MoneyPriceFeed(address(registry), KEEPER);

        // Register as the MONEY aggregator — ADMIN only; via the Safe when the deployer lacks it.
        bool needsSafe;
        if (registry.hasRole(ADMIN_ROLE, deployer)) {
            verifier.setChainlinkConfig(
                MONEY, address(feed), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, 0, 0
            );
            require(verifier.getChainlinkConfig(MONEY).aggregator == address(feed), "config not applied");
        } else {
            needsSafe = true;
        }

        vm.stopBroadcast();

        require(feed.keeper() == KEEPER, "keeper mismatch");
        require(feed.decimals() == 18, "decimals mismatch");

        if (needsSafe) {
            console.log("=== Safe call required ===");
            console.log("target:", address(verifier));
            console.log("  setChainlinkConfig(MONEY, feed, 0, 900, 5400, 86400, 0, 0) calldata:");
            console.logBytes(
                abi.encodeCall(
                    ChainlinkOracleVerifier.setChainlinkConfig,
                    (MONEY, address(feed), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, 0, 0)
                )
            );
        }

        console.log("MoneyPriceFeed:", address(feed));
        console.log("Verifier:      ", address(verifier));
        console.log("Keeper:        ", KEEPER);
    }
}
