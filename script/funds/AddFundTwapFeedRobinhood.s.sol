// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundTwapFeed} from "../../src/funds/FundTwapFeed.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {IFundHook} from "../../src/interfaces/IFundHook.sol";

/// @title AddFundTwapFeedRobinhood — price a fund token off its own pool TWAP
/// @notice Deploys a FundTwapFeed for FUND and registers it in the FundOracle, which mint pricing
///         and the staking premium read. The oracle call needs the oracle owner: executed directly
///         when the deployer owns it, otherwise printed as a ready-to-paste Safe call. No keeper is
///         needed; swaps update the TWAP, and anyone may call hook.poke(fund) while trading is quiet.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, FUND_FACTORY, FUND,
///      TWAP_WINDOW (optional seconds, default 1800), TWAP_STALENESS (optional seconds, default 3600)
///
/// Usage:
///   forge script script/funds/AddFundTwapFeedRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract AddFundTwapFeedRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        IFundFactory factory = IFundFactory(vm.envAddress("FUND_FACTORY"));
        address fund = vm.envAddress("FUND");
        uint32 window = uint32(vm.envOr("TWAP_WINDOW", uint256(30 minutes)));
        uint32 staleness = uint32(vm.envOr("TWAP_STALENESS", uint256(1 hours)));
        require(factory.isFund(fund), "not a fund");

        FundOracle oracle = FundOracle(factory.oracle());
        bool ownsOracle = oracle.owner() == vm.addr(key);

        vm.startBroadcast(key);
        FundTwapFeed feed = new FundTwapFeed(IFundHook(factory.hook()), fund, window);
        if (ownsOracle) oracle.setFeed(fund, address(feed), staleness);
        vm.stopBroadcast();

        console.log("FundTwapFeed", address(feed));
        if (!ownsOracle) {
            console.log("Oracle owner must call on", address(oracle));
            console.logBytes(abi.encodeCall(FundOracle.setFeed, (fund, address(feed), staleness)));
        }
    }
}
