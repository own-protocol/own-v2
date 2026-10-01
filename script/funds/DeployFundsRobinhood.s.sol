// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Fund} from "../../src/funds/Fund.sol";
import {FundBribes} from "../../src/funds/FundBribes.sol";
import {FundCurators} from "../../src/funds/FundCurators.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundHook} from "../../src/funds/FundHook.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundRedeemZap} from "../../src/funds/FundRedeemZap.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {PlatformMetadata} from "../../src/interfaces/types/FundTypes.sol";
import {HookMiner} from "./HookMiner.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title DeployFundsRobinhood — Own Curated Funds platform on Robinhood Chain
/// @notice Deploys the oracle, the six module implementations, the factory proxy, the Uniswap v4
///         hook at a mined CREATE2 address, and the redeem-to-USDG zap. Wires the hook, sets the
///         platform metadata, allows USDG (and MONEY, if given) as bribe tokens, then starts the
///         two-step ownership handover of the factory and oracle to FUNDS_ADMIN.
///
/// @dev Post-deploy checklist:
///        1. FUNDS_ADMIN calls acceptOwnership() on the factory and on the oracle.
///        2. Admin sets a feed for every basket asset: oracle.setFeed(asset, aggregator, staleness).
///        3. Admin allows rebalance / zap routers: factory.setRouter(router, true).
///        4. Admin fills the listing eligibility list: factory.setEligibleAsset(token, true).
///        5. Admin creates the fund (curators, curator fee, minimum curator stake of 0.5% = 50 bps,
///           the Own keeper as manager); after launch run AddFundTwapFeedRobinhood for its TWAP.
///        6. The keeper finalizes each launch at its close and calls governor.flip() every
///           Thursday 00:00 UTC.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, FUNDS_ADMIN, PROTOCOL_FEE_RECIPIENT,
///      MONEY_TOKEN (optional, allowed as a bribe token)
///
/// Usage:
///   forge script script/funds/DeployFundsRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployFundsRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint160 constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        require(POOL_MANAGER.code.length > 0, "no v4 PoolManager");
        require(CREATE2_FACTORY.code.length > 0, "no CREATE2 deployer");

        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        address deployer = vm.addr(key);
        address admin = vm.envAddress("FUNDS_ADMIN");
        address protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address money = vm.envOr("MONEY_TOKEN", address(0));

        vm.startBroadcast(key);

        FundOracle oracle = new FundOracle(deployer);
        FundFactory factory = _deployFactory(deployer, address(oracle), protocolFeeRecipient);

        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), IFundFactory(address(factory)));
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(FundHook).creationCode, args);
        FundHook hook = new FundHook{salt: salt}(IPoolManager(POOL_MANAGER), IFundFactory(address(factory)));
        require(address(hook) == mined, "hook address mismatch");

        factory.setHook(address(hook));
        factory.setPlatformMetadata(_platformMetadata());
        factory.setBribeToken(USDG, true);
        if (money != address(0)) factory.setBribeToken(money, true);

        FundRedeemZap zap = new FundRedeemZap(address(factory));

        if (admin != deployer) {
            factory.transferOwnership(admin);
            oracle.transferOwnership(admin);
        }

        vm.stopBroadcast();

        console.log("FundOracle      ", address(oracle));
        console.log("FundFactory     ", address(factory));
        console.log("FundHook        ", address(hook));
        console.log("FundRedeemZap   ", address(zap));
        console.log("Fund beacon     ", factory.beacon(IFundFactory.Module.Fund));
        console.log("Launch beacon   ", factory.beacon(IFundFactory.Module.Launch));
        console.log("Staking beacon  ", factory.beacon(IFundFactory.Module.Staking));
        console.log("Governor beacon ", factory.beacon(IFundFactory.Module.Governor));
        console.log("Curators beacon ", factory.beacon(IFundFactory.Module.Curators));
        console.log("Bribes beacon   ", factory.beacon(IFundFactory.Module.Bribes));
        if (admin != deployer) console.log("Pending owner (must accept on factory and oracle):", admin);
    }

    function _deployFactory(
        address owner,
        address oracle,
        address protocolFeeRecipient
    ) internal returns (FundFactory) {
        address[6] memory impls = [
            address(new Fund()),
            address(new FundLaunch()),
            address(new FundStaking()),
            address(new FundGovernor()),
            address(new FundCurators()),
            address(new FundBribes())
        ];
        bytes memory init = abi.encodeCall(FundFactory.initialize, (owner, oracle, USDG, protocolFeeRecipient, impls));
        return FundFactory(address(new ERC1967Proxy(address(new FundFactory()), init)));
    }

    function _platformMetadata() internal pure returns (PlatformMetadata memory) {
        return PlatformMetadata({
            name: "Own Curated Funds",
            description: "An Own Curated Fund is a token backed by a basket of Robinhood Chain tokens held onchain, "
            "plus the fund's own USDG pool position. Any holder can redeem it for their share of the backing at any "
            "time, and stakers earn new fund tokens while it trades above its net asset value. Curators and stakers "
            "set the basket weights in a weekly vote. "
            "Own is the DeFi protocol on Robinhood Chain behind eUSD and OwnX. $MONEY is Own's token, "
            "launched fair on Pons and paired with SPY.",
            url: "https://own.money"
        });
    }
}
