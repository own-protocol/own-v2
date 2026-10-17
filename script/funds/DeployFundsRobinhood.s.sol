// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Fund} from "../../src/funds/Fund.sol";
import {FundAuctions} from "../../src/funds/FundAuctions.sol";
import {FundBribes} from "../../src/funds/FundBribes.sol";
import {FundCurators} from "../../src/funds/FundCurators.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";

import {FundMintZap} from "../../src/funds/FundMintZap.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundPriceHub} from "../../src/funds/FundPriceHub.sol";
import {FundRedeemZap} from "../../src/funds/FundRedeemZap.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {FundSwapAdapter} from "../../src/funds/FundSwapAdapter.sol";
import {FundVenue} from "../../src/funds/FundVenue.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/external/IHookr.sol";
import {PlatformMetadata} from "../../src/interfaces/types/FundTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployFundsRobinhood — Own Curated Funds platform on Robinhood Chain
/// @notice Deploys the oracle, the seven module implementations (the venue's against Hookr's live
///         contracts, so every fund pool opens on Hookr's allowlisted hook), the factory proxy, the
///         mint and redeem zaps, the Dutch auction house for rebalancing and the price hub for
///         assets without a Chainlink feed and for fund tokens. The factory, oracle, auction house
///         and hub are administered by the ProtocolRegistry's FUND_ADMIN role (day-to-day actions also by
///         FUND_OPERATOR).
///         It also deploys the swap adapter funds and zaps trade through Uniswap's Universal Router with.
///         Wiring the auction house, the platform metadata, the USDG (and MONEY, if given) bribe tokens and the
///         swap adapter as an allowed router needs
///         FUND_ADMIN: executed directly when the deployer holds it, otherwise printed as
///         ready-to-paste Safe calls.
///
/// @dev Post-deploy checklist:
///        1. If the deployer is not a FUND_ADMIN, a FUND_ADMIN executes the printed wiring calls in order.
///        2. Admin sets a price source for every basket asset. With a Chainlink feed: configure its
///           ticker on the ChainlinkOracleVerifier (setChainlinkConfig, and the signer quotes it
///           off-hours), then oracle.setVerifierFeed(asset, ticker, staleness). With no Chainlink
///           feed on this chain (e.g. LLY, SKHY): hub.createFeed(asset), then oracle.setFeed with the returned
///           feed; the keeper pushes its price to the hub (stock price, market price or pool TWAP, per asset).
///        3. The swap adapter is allowed as a router by the wiring. Allow any other rebalance / zap router with
///           factory.setRouter(router, true); never the Universal Router itself (funds can't pay it).
///        4. Admin fills the listing eligibility list: factory.setEligibleAsset(token, true).
///        5. Admin creates the fund (curators, fund fee, its pool's tax, Hookr share and LP fee,
///           minimum curator stake in USD at NAV, 0 for none, the Own keeper as manager). Before
///           the pool opens: hub.createFeed(fund), then oracle.setFeed(fund, feed, staleness); the
///           keeper pushes the fund pool's TWAP to the hub.
///        6. The keeper finalizes each launch at its close and seeds the pool, calls
///           governor.flip() every Thursday 00:00 UTC, opens auction lots to move the basket to its
///           new weights, calls venue.issue() after buys and venue.collectTax() daily.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, PROTOCOL_CURATOR,
///      PRICE_KEEPER (pushes hub prices), MONEY_TOKEN (optional, allowed as a bribe token)
///
/// Usage:
///   forge script script/funds/DeployFundsRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployFundsRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    // Hookr 1 on Robinhood Chain (github.com/Hookr-fun/hookr-contracts); HookrRoot is on Uniswap's
    // routing allowlist.
    address constant HOOKR_LAUNCHER = 0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4;
    address constant HOOKR_ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;
    address constant HOOKR_RULES = 0x4a71c270b1520F94064268102AebD744b0DE7942;
    address constant HOOKR_TAX = 0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F;

    // Uniswap's Universal Router on Robinhood Chain. Funds and zaps can't call it directly (it pulls only
    // through Permit2), so they trade through a FundSwapAdapter in front of it.
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    uint16 constant AUCTION_START_PREMIUM_BPS = 200;
    uint16 constant AUCTION_FLOOR_DISCOUNT_BPS = 300;
    uint32 constant AUCTION_DURATION = 4 hours;
    uint16 constant HUB_MAX_MOVE_BPS = 2600;

    // Set by _deployPeripherals for _wiring; a local would push run() past the stack limit.
    address internal _mintZap;
    address internal _swapAdapter;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        require(POOL_MANAGER.code.length > 0, "no v4 PoolManager");
        require(POSITION_MANAGER.code.length > 0, "no v4 PositionManager");
        require(HOOKR_LAUNCHER.code.length > 0, "no Hookr launcher");
        require(UNIVERSAL_ROUTER.code.length > 0, "no Universal Router");

        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        bool isAdmin = registry.hasRole(keccak256("FUND_ADMIN"), vm.addr(key));
        address protocolCurator = vm.envAddress("PROTOCOL_CURATOR");
        address money = vm.envOr("MONEY_TOKEN", address(0));

        vm.startBroadcast(key);

        FundOracle oracle = new FundOracle(address(registry));
        FundFactory factory = _deployFactory(address(registry), address(oracle), protocolCurator);

        (address auctions, address hub) = _deployPeripherals(address(factory), address(registry));

        bytes[] memory wiring = _wiring(auctions, money);
        for (uint256 i; i < wiring.length && isAdmin; ++i) {
            (bool ok,) = address(factory).call(wiring[i]);
            require(ok, "wiring call failed");
        }

        vm.stopBroadcast();

        console.log("FundOracle      ", address(oracle));
        console.log("FundFactory     ", address(factory));
        console.log("FundAuctions    ", auctions);
        console.log("FundPriceHub    ", hub);
        console.log("Fund beacon     ", factory.beacon(IFundFactory.Module.Fund));
        console.log("Launch beacon   ", factory.beacon(IFundFactory.Module.Launch));
        console.log("Staking beacon  ", factory.beacon(IFundFactory.Module.Staking));
        console.log("Governor beacon ", factory.beacon(IFundFactory.Module.Governor));
        console.log("Curators beacon ", factory.beacon(IFundFactory.Module.Curators));
        console.log("Bribes beacon   ", factory.beacon(IFundFactory.Module.Bribes));
        console.log("Venue beacon    ", factory.beacon(IFundFactory.Module.Venue));
        if (!isAdmin) {
            console.log("Deployer is not a FUND_ADMIN; a FUND_ADMIN must call, in order, on", address(factory));
            for (uint256 i; i < wiring.length; ++i) {
                console.logBytes(wiring[i]);
            }
        }
    }

    function _wiring(address auctions, address money) internal view returns (bytes[] memory calls) {
        calls = new bytes[](money == address(0) ? 5 : 6);
        calls[0] = abi.encodeCall(FundFactory.setAuctions, (auctions));
        calls[1] = abi.encodeCall(FundFactory.setPlatformMetadata, (_platformMetadata()));
        calls[2] = abi.encodeCall(FundFactory.setBribeToken, (USDG, true));
        calls[3] = abi.encodeCall(FundFactory.setMintZap, (_mintZap));
        calls[4] = abi.encodeCall(FundFactory.setRouter, (_swapAdapter, true));
        if (money != address(0)) calls[5] = abi.encodeCall(FundFactory.setBribeToken, (money, true));
    }

    function _deployPeripherals(address factory, address registry) internal returns (address, address) {
        console.log("FundRedeemZap   ", address(new FundRedeemZap(factory)));
        _mintZap = address(new FundMintZap(factory));
        console.log("FundMintZap     ", _mintZap);
        FundAuctions auctions =
            new FundAuctions(factory, AUCTION_START_PREMIUM_BPS, AUCTION_FLOOR_DISCOUNT_BPS, AUCTION_DURATION);
        FundPriceHub hub = new FundPriceHub(registry, vm.envAddress("PRICE_KEEPER"), HUB_MAX_MOVE_BPS);
        _swapAdapter = address(new FundSwapAdapter(UNIVERSAL_ROUTER));
        console.log("FundSwapAdapter ", _swapAdapter);
        return (address(auctions), address(hub));
    }

    function _deployFactory(address registry, address oracle, address protocolCurator) internal returns (FundFactory) {
        address[7] memory impls = [
            address(new Fund(USDG)),
            address(new FundLaunch()),
            address(new FundStaking(POSITION_MANAGER)),
            address(new FundGovernor()),
            address(new FundCurators()),
            address(new FundBribes()),
            address(new FundVenue(IHookrLauncher(HOOKR_LAUNCHER), HOOKR_ROOT, HOOKR_RULES, HOOKR_TAX, USDG))
        ];
        bytes memory init = abi.encodeCall(FundFactory.initialize, (registry, oracle, USDG, protocolCurator, impls));
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
