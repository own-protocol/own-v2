// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployFundsRobinhood} from "../../script/funds/DeployFundsRobinhood.s.sol";
import {FrontierFundBatches} from "../../script/funds/FrontierFundBatches.s.sol";
import {Fund} from "../../src/funds/Fund.sol";

import {FundAuctions} from "../../src/funds/FundAuctions.sol";
import {FundExitGateway} from "../../src/funds/FundExitGateway.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundMintGateway} from "../../src/funds/FundMintGateway.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundPriceHub} from "../../src/funds/FundPriceHub.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {FundSwapAdapter} from "../../src/funds/FundSwapAdapter.sol";
import {FundVenue} from "../../src/funds/FundVenue.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundAuctions} from "../../src/interfaces/IFundAuctions.sol";
import {IFundExitGateway} from "../../src/interfaces/IFundExitGateway.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {IFundMintGateway} from "../../src/interfaces/IFundMintGateway.sol";
import {CcipClient} from "../../src/interfaces/external/ICcip.sol";
import {CreateFundParams, PoolSettings, YieldPoint} from "../../src/interfaces/types/FundTypes.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IUniversalRouterFL {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2FL {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IAggregatorFL {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IV3PoolFL {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function token0() external view returns (address);
}

interface IAccessFL {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function inhouseOracle() external view returns (address);
}

/// @dev The live ChainlinkOracleVerifier's AssetConfig, field for field.
struct VerifierConfigFL {
    address aggregator;
    uint32 clSilence;
    uint32 clFreshWindow;
    uint16 bandBps;
    uint8 clDecimals;
    address multiplierToken;
    uint32 maxAnchorAge;
    uint32 inhouseMaxStaleness;
}

interface IVerifierFL {
    function setChainlinkConfig(
        bytes32 asset,
        address aggregator,
        address multiplierToken,
        uint32 clSilence,
        uint32 clFreshWindow,
        uint32 maxAnchorAge,
        uint32 inhouseMaxStaleness,
        uint16 bandBps
    ) external;
    function getChainlinkConfig(
        bytes32 asset
    ) external view returns (VerifierConfigFL memory);
    function getPrice(
        bytes32 asset
    ) external view returns (uint256, uint256);
}

/// @dev Exposes the deploy script's wiring so the test replays exactly what it prints for the Safe.
contract DeployFundsHarness is DeployFundsRobinhood {
    function mintZap() external view returns (address) {
        return _mintZap;
    }

    function swapAdapter() external view returns (address) {
        return _swapAdapter;
    }
}

/// @dev Exposes the Safe batches FrontierFundBatches writes, so the test executes exactly those calls.
contract FrontierBatchesHarness is FrontierFundBatches {
    function setupCalls(
        Deployment memory d
    ) external returns (Call[] memory) {
        return _setupCalls(d);
    }

    function createFundCalls(
        Deployment memory d
    ) external pure returns (Call[] memory) {
        return _createFundCalls(d);
    }

    function beforeCloseCalls(Deployment memory d, address fund) external view returns (Call[] memory) {
        return _beforeCloseCalls(d, fund);
    }

    function afterLaunchWeekCalls(
        Deployment memory d
    ) external pure returns (Call[] memory) {
        return _afterLaunchWeekCalls(d);
    }

    function checkDeployment(
        Deployment memory d
    ) external view {
        _checkDeployment(d);
    }

    function checkSetup(
        Deployment memory d
    ) external view {
        _checkSetup(d);
    }
}

/// @dev Counts any call it receives, to catch transfer hooks or callbacks.
contract TransferProbe {
    uint256 public calls;

    function pull(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
    }

    fallback() external payable {
        ++calls;
    }

    receive() external payable {
        ++calls;
    }
}

/// @title FrontierLaunchRobinhoodForkTest — the Frontier Fund 1 launch rehearsed on Robinhood Chain
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Runs the deploy script, the governance Safe's role
///         grants and wiring, the price feeds for all 18 basket tokens, `createFund`, the deposit
///         window, the keeper's manual close, the launch rebalance through Uniswap's Universal
///         Router on the live pools, pool seeding on Hookr, the auctions for the cbBTC / rZEC /
///         rHYPE share, distribution, trading, issuance, tax, accrual, a mint and a redeem, then the
///         USDG gateways (an exit with live CCIP sends of rZEC/rHYPE, a mint from stock, a queued mint
///         filled after a restock), against live tokens, pools, Hookr, Chainlink, CCIP and Across. Numbers are emitted as logs (run with -vv).
/// @dev Fork-only workarounds, each marked where it is used:
///      - Chainlink answers are re-stamped (`vm.mockCall`, same answer) after every warp: a fork's
///        feeds never update, and warping 15+ days would make every one stale.
///      - rZEC and rHYPE are the live Robinhood tokens, minted with `deal` (their CCIP pools mint
///        only on a Base delivery); a restock's CCIP arrival is replayed as the Router.
///      The launch rebalance goes through {FundSwapAdapter}, the router a fund trades through on Robinhood Chain:
///      the fund can't call Uniswap's Universal Router directly (`_checkUniversalRouterDirect`).
contract FrontierLaunchRobinhoodForkTest is Test {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // Live CCIP and Across.
    address constant RZEC = 0xaB100cbD80441499A4cBEe4927B1F2424B09a5fC;
    address constant RHYPE = 0x133b1D01554B5665cf93358959857BDf063a26aF;
    address constant RH_CCIP_ROUTER = 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9;
    uint64 constant BASE_SELECTOR = 15_971_525_489_660_198_786;
    address constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Live Robinhood Chain contracts.
    address constant REGISTRY = 0x93e08ca467046737F75AAD4C936356c196AaA36F;
    address constant SAFE = 0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2;
    address constant KEEPER = 0xB1284eC8A142d71A3694b66e2fe9a8e0014de88e;
    address constant TREASURY = 0x8f974d82EEaa9725ecC40600f12093B14080dA54;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant HOOKR_TAX = 0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F;

    // Basket tokens (portfolios/frontier-fund-ai-space-onchain-money.csv).
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant LLY = 0x8005d266423c7ea827372c9c864491e5786600ea;
    address constant SKHY = 0x84CAb63bc87912E71ad199ff14A0bA45de68FeF8;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant CBBTC = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4;
    address constant UNI = 0xF177d86a28b520e3E396E4F3B96cd8e72D7dabd8;
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    address constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    address constant WSNET = 0x63C12667638f2Ae6fC6ae09B43D98Ec84a8586eA;
    address constant HOOKR = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;

    // Chainlink proxies on Robinhood Chain (Chainlink's data feeds directory, robinhood mainnet).
    address constant FEED_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant FEED_SPCX = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    address constant FEED_META = 0x7C38C00C30BEe9378381E7B6135d7283356D71b1;
    address constant FEED_TSLA = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant FEED_GOOGL = 0xF6f373a037c30F0e5010d854385cA89185AE638b;
    address constant FEED_PLTR = 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c;
    address constant FEED_ETH = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant FEED_CBBTC = 0x0009cD492adf8167f9eEBf1293556A673530a21a;

    // Pools used for routes and hub prices.
    address constant V3_USDG_WETH_001 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant POONS_HOOK = 0x08E52564Bad99E05a694b4809F397edcA417A080;
    address constant SKHY_HOOK = 0xC15b155a3094934171A15625d1a80Aba267B6080;

    bytes32 constant FUND_ADMIN = keccak256("FUND_ADMIN");
    bytes32 constant FUND_OPERATOR = keccak256("FUND_OPERATOR");

    // Rehearsal choices for the FundOracle staleness bounds (not fixed anywhere yet).
    uint32 constant HUB_STALENESS = 2 hours;

    // Stand-in prices (GeckoTerminal 2026-10-17: cbZEC/USDC on Base, WHYPE on HyperEVM).
    uint256 constant RZEC_PRICE = 1150e18;
    uint256 constant RHYPE_PRICE = 78.75e18;

    // Universal Router.
    address constant MSG_SENDER = address(1);
    address constant ADDRESS_THIS = address(2);
    uint256 constant CONTRACT_BALANCE = 1 << 255;

    uint8 constant K_V3 = 0;
    uint8 constant K_V4 = 1;
    uint8 constant K_V3_ETH_V4 = 2;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct Route {
        string label;
        uint8 kind;
        bytes path;
        PoolKey key;
        address pricePool;
        bool quoteIsEth;
    }

    struct Fill {
        uint256 swaps;
        uint256 sold;
        uint256 soldValue;
        uint256 boughtValue;
        uint256 gas;
        uint256 chunk;
    }

    bool internal _forkActive;

    // Deployment.
    DeployFundsHarness internal harness;
    FrontierBatchesHarness internal batches;
    FrontierFundBatches.Deployment internal deployment;
    address internal deployer;
    FundOracle internal oracle;
    FundFactory internal factory;
    FundAuctions internal auctions;
    FundPriceHub internal hub;
    FundSwapAdapter internal adapter;

    // The fund.
    Fund internal fund;
    FundLaunch internal launch;
    FundStaking internal staking;
    FundVenue internal venue;
    address internal curators;
    MockERC20 internal rzec;
    MockERC20 internal rhype;

    address[] internal basket;
    uint16[] internal weights;
    address[] internal hubAssets;
    mapping(address => uint256) internal hubPrice;
    address[] internal clFeeds;
    mapping(address => int256) internal clAnswer;
    mapping(address => Route[]) internal candidates;
    mapping(address => Route) internal chosen;
    mapping(address => Fill) internal fills;
    mapping(address => string) internal routeUsed;
    mapping(address => uint256) internal routeTries;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal relay = makeAddr("relay");
    address internal trader = makeAddr("trader");
    address internal prober = makeAddr("prober");

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain");
        _forkActive = true;
    }

    // ──────────────────────────────────────────────────────────
    //  The launch, in order
    // ──────────────────────────────────────────────────────────

    function test_fork_frontierLaunch() public requiresFork {
        _step1Deploy();
        _step2Feeds();
        _step3CreateFund();
        _step4Deposits();
        _step5Finalize();
        _step6LaunchRebalance();
        _step7SeedPool();
        _step8Auctions();
        _step9Live();
        _step10Gateways();
    }

    function _step1Deploy() internal {
        // The Safe batch (safe-txns/grant-fund-admin-operator-2026-10-17.json).
        vm.startPrank(SAFE);
        IAccessFL(REGISTRY).grantRole(FUND_ADMIN, SAFE);
        IAccessFL(REGISTRY).grantRole(FUND_OPERATOR, KEEPER);
        vm.stopPrank();
        assertTrue(IAccessFL(REGISTRY).hasRole(FUND_ADMIN, SAFE));
        assertTrue(IAccessFL(REGISTRY).hasRole(FUND_OPERATOR, KEEPER));

        uint256 key;
        (deployer, key) = makeAddrAndKey("deployer");
        vm.setEnv("DEPLOYER_PRIVATE_KEY_ROBINHOOD", vm.toString(bytes32(key)));
        vm.setEnv("PROTOCOL_REGISTRY_ROBINHOOD", vm.toString(REGISTRY));
        vm.setEnv("PROTOCOL_CURATOR", vm.toString(TREASURY));
        vm.setEnv("PRICE_KEEPER", vm.toString(KEEPER));
        uint64 nonce = vm.getNonce(deployer);
        harness = new DeployFundsHarness();
        harness.run();

        // run() returns nothing; the deployer's nonces give the addresses, checked against each other.
        oracle = FundOracle(vm.computeCreateAddress(deployer, nonce));
        factory = FundFactory(vm.computeCreateAddress(deployer, nonce + 9));
        auctions = FundAuctions(vm.computeCreateAddress(deployer, nonce + 12));
        hub = FundPriceHub(vm.computeCreateAddress(deployer, nonce + 13));
        adapter = FundSwapAdapter(vm.computeCreateAddress(deployer, nonce + 14));
        assertEq(address(adapter), harness.swapAdapter());
        assertEq(adapter.universalRouter(), UNIVERSAL_ROUTER);
        assertEq(factory.oracle(), address(oracle));
        assertEq(auctions.factory(), address(factory));
        assertEq(hub.registry(), REGISTRY);
        assertEq(hub.keeper(), KEEPER);
        assertEq(factory.protocolCurator(), TREASURY);
        assertEq(factory.usdg(), USDG);
        assertEq(auctions.startPremiumBps(), 200);
        assertEq(auctions.floorDiscountBps(), 300);
        assertEq(auctions.duration(), 4 hours);

        rzec = MockERC20(RZEC);
        rhype = MockERC20(RHYPE);
        _defineBasket();

        batches = new FrontierBatchesHarness();
        deployment = FrontierFundBatches.Deployment({
            oracle: address(oracle),
            factory: address(factory),
            auctions: address(auctions),
            hub: address(hub),
            mintZap: harness.mintZap(),
            swapAdapter: address(adapter),
            money: address(0),
            rzec: address(rzec),
            rhype: address(rhype)
        });
        batches.checkDeployment(deployment);
    }

    /// @dev Executes a Safe batch as the Safe, in order, like the Safe's MultiSend; returns the last result.
    function _execBatch(
        FrontierFundBatches.Call[] memory calls
    ) internal returns (bytes memory ret) {
        bool ok;
        vm.startPrank(SAFE);
        for (uint256 i; i < calls.length; ++i) {
            (ok, ret) = calls[i].to.call(calls[i].data);
            assertTrue(ok, string.concat("Safe batch call failed: ", calls[i].label));
        }
        vm.stopPrank();
    }

    function _step2Feeds() internal {
        _recordChainlink();
        IVerifierFL verifier = IVerifierFL(IAccessFL(REGISTRY).inhouseOracle());

        // Safe batch 1 (FrontierFundBatches.setupBatch): the deploy script's wiring, the R.PLTR ticker,
        // a price source and eligibility for every basket token.
        uint256 g = gasleft();
        _execBatch(batches.setupCalls(deployment));
        emit log_named_uint("gas Safe batch 1 (setup)", g - gasleft());
        batches.checkSetup(deployment);
        assertEq(factory.auctions(), address(auctions));
        assertEq(factory.mintZap(), harness.mintZap());
        assertTrue(factory.isRouter(address(adapter)));
        assertEq(hub.maxMoveBps(), 2600);
        assertTrue(factory.isBribeToken(USDG));
        assertEq(factory.rebalanceVolumeCapBps(), 1000);
        assertEq(factory.maxRebalanceSlippageBps(), 200);

        // The batch gives R.PLTR the live R.NVDA settings.
        VerifierConfigFL memory c = verifier.getChainlinkConfig(bytes32("R.NVDA"));
        VerifierConfigFL memory pltrCfg = verifier.getChainlinkConfig(bytes32("R.PLTR"));
        assertEq(pltrCfg.aggregator, FEED_PLTR);
        assertEq(
            abi.encode(
                pltrCfg.clSilence,
                pltrCfg.clFreshWindow,
                pltrCfg.maxAnchorAge,
                pltrCfg.inhouseMaxStaleness,
                pltrCfg.bandBps
            ),
            abi.encode(c.clSilence, c.clFreshWindow, c.maxAnchorAge, c.inhouseMaxStaleness, c.bandBps)
        );
        assertEq(pltrCfg.multiplierToken, c.multiplierToken);

        // ETH and CBBTC take the same settings, with an anchor at most 26h old.
        address[2] memory cryptoFeeds = [FEED_ETH, FEED_CBBTC];
        bytes32[2] memory cryptoTickers = [bytes32("ETH"), bytes32("CBBTC")];
        for (uint256 i; i < 2; ++i) {
            VerifierConfigFL memory k = verifier.getChainlinkConfig(cryptoTickers[i]);
            assertEq(k.aggregator, cryptoFeeds[i]);
            assertEq(k.multiplierToken, address(0));
            assertEq(
                abi.encode(k.clSilence, k.clFreshWindow, k.maxAnchorAge, k.inhouseMaxStaleness, k.bandBps),
                abi.encode(c.clSilence, c.clFreshWindow, uint32(26 hours), c.inhouseMaxStaleness, c.bandBps)
            );
        }

        hubAssets = [LLY, SKHY, address(rzec), address(rhype), UNI, PONS, AI, CASHCAT, WSNET, HOOKR];
        for (uint256 i; i < hubAssets.length; ++i) {
            assertEq(oracle.feedOf(hubAssets[i]).aggregator, hub.feedOf(hubAssets[i]));
            assertEq(oracle.feedOf(hubAssets[i]).maxStaleness, HUB_STALENESS);
        }

        // Hub prices: the stand-ins at their home-market price, the rest at the mid of the pool the
        // launch rebalance buys through (chosen here, by output, at the planned $100k raise).
        hubPrice[address(rzec)] = RZEC_PRICE;
        hubPrice[address(rhype)] = RHYPE_PRICE;
        _defineRoutes();
        for (uint256 i; i < basket.length; ++i) {
            address a = basket[i];
            if (candidates[a].length != 0) _chooseRoute(a, _plannedBuy(a));
        }
        for (uint256 i; i < hubAssets.length; ++i) {
            address a = hubAssets[i];
            if (hubPrice[a] == 0) hubPrice[a] = _routeMid(chosen[a], a);
            emit log_named_decimal_uint(string.concat("hub price ", _sym(a)), hubPrice[a], 18);
        }
        _refreshPrices();

        for (uint256 i; i < basket.length; ++i) {
            (bool ok, uint256 p) = oracle.tryPrice(basket[i]);
            assertTrue(ok, string.concat("no price for ", _sym(basket[i])));
            emit log_named_decimal_uint(string.concat("oracle ", _sym(basket[i])), p, 18);
        }
        (uint256 pltr,) = verifier.getPrice(bytes32("R.PLTR"));
        assertEq(pltr, uint256(clAnswer[FEED_PLTR]) * 1e10);
        (uint256 eth,) = verifier.getPrice(bytes32("ETH"));
        assertEq(eth, uint256(clAnswer[FEED_ETH]) * 1e10);
        (uint256 cbbtc,) = verifier.getPrice(bytes32("CBBTC"));
        assertEq(cbbtc, uint256(clAnswer[FEED_CBBTC]) * 1e10);
        assertEq(oracle.feedOf(WETH).ticker, bytes32("ETH"));
        assertEq(oracle.feedOf(CBBTC).ticker, bytes32("CBBTC"));
    }

    function _step3CreateFund() internal {
        CreateFundParams memory p;
        p.name = "Frontier Fund 1";
        p.symbol = "Fund1";
        p.info.description =
            "AI, space, longevity and onchain money in one token. Curated by Own, always redeemable for what's inside.";
        p.info.website = "https://own.money";
        p.info.x = "https://x.com/owndotmoney";
        p.info.telegram = "https://t.me/owndotmoney";
        p.assets = basket;
        p.weightsBps = weights;
        p.manager = KEEPER;
        p.feeBps = 100;
        p.minRaiseUsd = 50_000e18;
        p.targetRaiseUsd = 100_000e18;
        p.launchDuration = 15 days;
        p.yieldCurve = new YieldPoint[](3);
        p.yieldCurve[0] = YieldPoint({premiumBps: 0, rateBpsPerYear: 2400});
        p.yieldCurve[1] = YieldPoint({premiumBps: 2500, rateBpsPerYear: 3600});
        p.yieldCurve[2] = YieldPoint({premiumBps: 10_000, rateBpsPerYear: 7200});
        p.pool =
            PoolSettings({buyTaxPips: 9500, sellTaxPips: 9500, hookrShareBps: 2000, lpFeePips: 1500, tickSpacing: 0});

        // Safe batch 2 (FrontierFundBatches.createFundBatch) must be these confirmed parameters.
        FrontierFundBatches.Call[] memory calls = batches.createFundCalls(deployment);
        assertEq(calls.length, 1);
        assertEq(calls[0].data, abi.encodeCall(FundFactory.createFund, (p)), "batch 2 params differ");
        uint256 g = gasleft();
        IFundFactory.FundModules memory m = abi.decode(_execBatch(calls), (IFundFactory.FundModules));
        emit log_named_uint("gas createFund", g - gasleft());
        fund = Fund(m.fund);
        launch = FundLaunch(m.launch);
        staking = FundStaking(m.staking);
        venue = FundVenue(m.venue);
        curators = m.curators;
        assertEq(fund.feeBps(), 100);
        assertEq(fund.manager(), KEEPER);
        assertEq(launch.launchSupply(), 100_000_000e18);
        assertEq(launch.endTime(), block.timestamp + 15 days);
        assertEq(launch.config().poolUsdgBps, 1000);
        assertEq(fund.assets().length, 18);
        assertEq(venue.poolSettings().tickSpacing, 60);
    }

    function _step4Deposits() internal {
        uint256 start = block.timestamp;
        _depositUsdg(alice, 40_000e6);

        _warpTo(start + 2 days);
        _depositUsdg(bob, 30_000e6);

        // In kind: about $5k of NVDA, under its target share of the raise (no haircut).
        _warpTo(start + 4 days);
        uint256 nvdaAmount = 5000e18 * 1e18 / oracle.price(NVDA);
        _give(NVDA, carol, nvdaAmount);
        vm.startPrank(carol);
        IERC20(NVDA).approve(address(launch), nvdaAmount);
        uint256 received = launch.deposit(NVDA, nvdaAmount);
        vm.stopPrank();
        assertEq(received, nvdaAmount, "NVDA deposit lost value in transfer");

        _warpTo(start + 5 days);
        _depositUsdg(dave, 26_000e6);
        uint256 raised = launch.raisedValue();
        emit log_named_decimal_uint("raised after the last deposit (USD)", raised, 18);
        assertGe(raised, 100_000e18, "target not reached");
    }

    function _step5Finalize() internal {
        // Safe batch 3 (FrontierFundBatches.beforeCloseBatch), signed during the window: the fund token's
        // hub feed and the launch-week cap.
        _execBatch(batches.beforeCloseCalls(deployment, address(fund)));
        assertEq(oracle.feedOf(address(fund)).aggregator, hub.feedOf(address(fund)));
        assertEq(factory.rebalanceVolumeCapBps(), 5000);

        // The keeper closes by hand a couple of days after the target, still inside the window.
        _warpTo(launch.startTime() + 7 days);
        assertLt(block.timestamp, launch.endTime());
        vm.prank(KEEPER);
        uint256 g = gasleft();
        launch.finalize();
        emit log_named_uint("gas finalize", g - gasleft());
        assertEq(uint8(launch.status()), 1);
        emit log_named_decimal_uint("pool USDG P", launch.poolUsdg(), 6);
        emit log_named_decimal_uint("pool shares M", launch.poolShares(), 18);
        emit log_named_decimal_uint("depositor supply C", launch.depositorSupply(), 18);
        (, uint256 nav,) = fund.tryNav();
        emit log_named_decimal_uint("NAV at close (USD)", nav, 18);

        // Early deposits earn more points per dollar.
        uint256 perDollarAlice = launch.claimable(alice) * 1e6 / 40_000e6;
        uint256 perDollarDave = launch.claimable(dave) * 1e6 / 26_000e6;
        emit log_named_decimal_uint("alice (day 0) tokens per $", perDollarAlice, 18);
        emit log_named_decimal_uint("bob   (day 2) tokens per $", launch.claimable(bob) * 1e6 / 30_000e6, 18);
        emit log_named_decimal_uint("dave  (day 5) tokens per $", perDollarDave, 18);
        uint256 carolUsd = IERC20(NVDA).balanceOf(address(fund)) * launch.closePrice(NVDA) / 1e18;
        emit log_named_decimal_uint(
            "carol (day 4, NVDA in kind) tokens per $", launch.claimable(carol) * 1e18 / carolUsd, 18
        );
        assertGt(perDollarAlice, perDollarDave, "no early-deposit bonus");
    }

    function _step6LaunchRebalance() internal {
        _checkUniversalRouterDirect();

        for (uint256 i; i < basket.length; ++i) {
            address a = basket[i];
            if (candidates[a].length == 0) continue;
            uint256 need = _launchBuy(a);
            if (need == 0) continue;
            _buy(a, need);
        }

        uint256 idle = IERC20(USDG).balanceOf(address(fund));
        emit log_named_decimal_uint("idle USDG after the launch rebalance", idle, 6);
        assertGe(idle, launch.poolUsdg(), "spent the pool's USDG");
        for (uint256 i; i < basket.length; ++i) {
            address a = basket[i];
            if (candidates[a].length == 0) continue;
            Fill memory f = fills[a];
            emit log_named_string(string.concat("route ", _sym(a)), routeUsed[a]);
            emit log_named_decimal_uint(string.concat("  chunk USDG ", _sym(a)), f.chunk, 6);
            emit log_named_uint(string.concat("  swaps ", _sym(a)), f.swaps);
            emit log_named_decimal_uint(string.concat("  spent USDG ", _sym(a)), f.sold, 6);
            emit log_named_int(
                string.concat("  cost vs oracle bps ", _sym(a)),
                f.soldValue == 0 ? int256(0) : int256(BPS_SCALE) - int256(f.boughtValue * BPS_SCALE / f.soldValue)
            );
            emit log_named_uint(string.concat("  gas per swap ", _sym(a)), f.swaps == 0 ? 0 : f.gas / f.swaps);
        }
    }

    function _step7SeedPool() internal {
        (bool ok, uint256 nav,) = fund.tryNav();
        assertTrue(ok);
        hubAssets.push(address(fund));
        hubPrice[address(fund)] = nav;
        _refreshPrices();

        vm.prank(KEEPER);
        uint256 g = gasleft();
        launch.seedPool{value: 0}();
        emit log_named_uint("gas seedPool", g - gasleft());
        (, uint256 navAfter,) = fund.tryNav();
        uint256 spot = venue.spotPrice();
        emit log_named_decimal_uint("NAV before seed", nav, 18);
        emit log_named_decimal_uint("NAV after seed", navAfter, 18);
        emit log_named_decimal_uint("pool opening price", spot, 18);
        assertApproxEqRel(spot, navAfter, 0.002e18, "pool did not open at NAV");
        assertEq(address(venue.poolKey().hooks), 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc);
    }

    function _step8Auctions() internal {
        _give(CBBTC, relay, 1e8);
        _give(address(rzec), relay, 100e8);
        _give(address(rhype), relay, 1000e18);
        vm.startPrank(relay);
        IERC20(CBBTC).approve(address(auctions), type(uint256).max);
        rzec.approve(address(auctions), type(uint256).max);
        rhype.approve(address(auctions), type(uint256).max);
        vm.stopPrank();

        uint256 lotCbbtc = _auctionTarget(CBBTC);
        uint256 lotZec = _auctionTarget(address(rzec));
        emit log_named_decimal_uint("auction lot cbBTC (USDG)", lotCbbtc, 6);
        emit log_named_decimal_uint("auction lot rZEC (USDG)", lotZec, 6);

        uint256 id = _openLot(CBBTC, lotCbbtc);
        // A fill at a price the oracle no longer supports is refused.
        _expectFillBelowOracleBound(id, CBBTC);
        _fillLot(id, 3.5 hours);

        id = _openLot(address(rzec), lotZec);
        _fillLot(id, 3 hours);

        // Launch week ends, Safe batch 4 (FrontierFundBatches.afterLaunchWeekBatch): back to 10% a day.
        // The auction volume already sold counts against it.
        _execBatch(batches.afterLaunchWeekCalls(deployment));
        assertEq(factory.rebalanceVolumeCapBps(), 1000);
        uint256 lotHype = _auctionTarget(address(rhype));
        emit log_named_decimal_uint("auction lot rHYPE (USDG)", lotHype, 6);
        id = _openLot(address(rhype), lotHype);
        _warpTo(block.timestamp + 3 hours);
        uint256 cost = auctions.quote(id, lotHype);
        vm.prank(relay);
        vm.expectRevert(IFundAuctions.VolumeExceeded.selector);
        auctions.fill(id, lotHype, cost);
        emit log_named_decimal_uint("auction volume counted (USD)", auctions.volumeOf(address(fund)), 18);
        emit log("rHYPE lot refused at the 10% cap; reopened the next day");
        vm.prank(KEEPER);
        auctions.cancelLot(id);
        _warpTo(block.timestamp + 1 days);
        id = _openLot(address(rhype), lotHype);
        _fillLot(id, 3 hours);
    }

    function _step9Live() internal {
        address[] memory accounts = new address[](4);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (alice, bob, carol, dave);
        vm.prank(KEEPER);
        uint256 g = gasleft();
        launch.distribute(accounts);
        emit log_named_uint("gas distribute (4 accounts)", g - gasleft());
        assertGt(staking.balanceOf(alice), 0);

        _trade();
        _accrue();
        _mint();
        _redeem();
    }

    // ──────────────────────────────────────────────────────────
    //  Step 9 parts
    // ──────────────────────────────────────────────────────────

    function _trade() internal {
        uint256 curatorsBefore = IERC20(USDG).balanceOf(curators);
        uint256 fundUsdgBefore = IERC20(USDG).balanceOf(address(fund));
        uint256 spotBefore = venue.spotPrice();
        uint256 g = gasleft();
        uint256 bought = _urTrade(USDG, 2000e6);
        emit log_named_uint("gas UR buy", g - gasleft());
        emit log_named_decimal_uint("UR buy: 2000 USDG -> fund tokens", bought, 18);
        emit log_named_decimal_uint("spot before buy", spotBefore, 18);
        emit log_named_decimal_uint("spot after buy", venue.spotPrice(), 18);

        uint256 paid = venue.collectTax();
        emit log_named_decimal_uint("buy tax paid to curators (USDG)", paid, 6);
        assertEq(IERC20(USDG).balanceOf(curators) - curatorsBefore, paid);
        // 0.95% of the USDG paid, 80% of it to the curators: 0.76%.
        assertApproxEqRel(paid, 2000e6 * 9500 * 8000 / 1e6 / 1e4, 0.01e18, "buy tax split");

        (uint256 issued, uint256 usdgIn) = venue.issue();
        emit log_named_decimal_uint("issue(): fund tokens sold", issued, 18);
        emit log_named_decimal_uint("issue(): USDG to fund", usdgIn, 6);
        emit log_named_decimal_uint("spot after issue", venue.spotPrice(), 18);
        assertGt(issued, 0, "nothing issued after a premium buy");
        // issue() sells through the taxed pool too, so the fund pays the sell tax on its own issuance.
        uint256 issuePaid = venue.collectTax();
        emit log_named_decimal_uint("sell tax paid on the fund's own issue() (USDG)", issuePaid, 6);
        assertApproxEqRel(issuePaid, usdgIn * 1e6 / (1e6 - 9500) * 9500 * 8000 / 1e6 / 1e4, 0.01e18, "issue tax");

        uint256 got = _urTrade(address(fund), uint128(bought / 2));
        emit log_named_decimal_uint("UR sell: half the tokens -> USDG", got, 6);
        uint256 sellPaid = venue.collectTax();
        emit log_named_decimal_uint("sell tax paid to curators (USDG)", sellPaid, 6);
        uint256 grossOut = got * 1e6 / (1e6 - 9500);
        assertApproxEqRel(sellPaid, grossOut * 9500 * 8000 / 1e6 / 1e4, 0.01e18, "sell tax split");

        (uint256 lpUsdg, uint256 lpBurned) = venue.collectLpFees();
        emit log_named_decimal_uint("LP fees collected: USDG to fund", lpUsdg, 6);
        emit log_named_decimal_uint("LP fees collected: fund tokens burned", lpBurned, 18);
        // 0.15% of the USDG leg of the buy (net of the tax), to the fund's own position.
        assertApproxEqRel(lpUsdg, (2000e6 - 2000e6 * 9500 / 1e6) * 1500 / 1e6, 0.05e18, "LP fee");
        emit log_named_decimal_uint(
            "fund idle USDG change over the trades", IERC20(USDG).balanceOf(address(fund)) - fundUsdgBefore, 6
        );
    }

    function _accrue() internal {
        hubPrice[address(fund)] = venue.spotPrice();
        uint256 lastAccrual = staking.lastAccrual();
        _warpTo(block.timestamp + 6 hours);
        (bool ok, int256 premium) = fund.premiumBps();
        emit log_named_int("premium over NAV (bps) before accrue", ok ? premium : int256(0));
        uint256 g = gasleft();
        uint256 minted = staking.accrue();
        emit log_named_uint("gas staking.accrue", g - gasleft());
        emit log_named_decimal_uint(
            string.concat("staking.accrue minted over (s) ", vm.toString(block.timestamp - lastAccrual)), minted, 18
        );
        assertGt(minted, 0);
    }

    function _mint() internal {
        (, uint256 nav,) = fund.tryNav();
        uint256 navShares = 1000e18 * 1e18 / nav;
        (uint256 shares,, uint256[] memory amounts, uint256 usdgAmount,) = fund.previewMint(navShares, false);
        address[] memory a = fund.assets();
        vm.startPrank(erin);
        for (uint256 i; i < a.length; ++i) {
            if (amounts[i] == 0) continue;
            vm.stopPrank();
            _give(a[i], erin, amounts[i]);
            vm.startPrank(erin);
            IERC20(a[i]).approve(address(fund), amounts[i]);
        }
        vm.stopPrank();
        _give(USDG, erin, usdgAmount);
        vm.startPrank(erin);
        IERC20(USDG).approve(address(fund), usdgAmount);
        uint256 g = gasleft();
        uint256 got = fund.mint(navShares, 0, erin, false);
        emit log_named_uint("gas mint (18 assets, locked direct mint)", g - gasleft());
        vm.stopPrank();
        assertEq(got, shares);
        emit log_named_decimal_uint("mint at pool price: $1k NAV slice -> fund tokens (staked, locked)", got, 18);
    }

    function _redeem() internal {
        uint256 shares = staking.balanceOf(alice) / 10;
        address[] memory a = fund.assets();
        uint256[] memory before = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) {
            before[i] = IERC20(a[i]).balanceOf(alice);
        }
        uint256 usdgBefore = IERC20(USDG).balanceOf(alice);
        uint256 tokens = staking.convertToAssets(shares);
        (, uint256 nav,) = fund.tryNav();
        vm.prank(alice);
        uint256 g = gasleft();
        (uint256[] memory amounts, uint256 usdgOut) =
            staking.redeem(shares, alice, new uint256[](0), 0, new address[](0));
        emit log_named_uint("gas redeem (18 assets, via staking, launch-locked)", g - gasleft());
        uint256 value = usdgOut * 1e12;
        for (uint256 i; i < a.length; ++i) {
            assertEq(IERC20(a[i]).balanceOf(alice) - before[i], amounts[i], "redeem transfer short");
            assertGt(amounts[i], 0, string.concat("redeem paid no ", _sym(a[i])));
            value += amounts[i] * oracle.price(a[i]) / 10 ** IERC20Metadata(a[i]).decimals();
        }
        assertEq(IERC20(USDG).balanceOf(alice) - usdgBefore, usdgOut);
        uint256 atNav = tokens * nav / 1e18;
        emit log_named_decimal_uint("redeem: value received (USD)", value, 18);
        emit log_named_decimal_uint("redeem: tokens x NAV (USD)", atNav, 18);
        // The 1% fund fee, nothing else.
        assertApproxEqRel(value, atNav * 99 / 100, 0.003e18, "redeem not at NAV");
    }

    // ──────────────────────────────────────────────────────────
    //  Step 10: the USDG gateways
    // ──────────────────────────────────────────────────────────

    address internal baseGatewayStandIn = makeAddr("baseGateway");

    function _step10Gateways() internal {
        _refreshPrices();
        // cbBTC has no launch route (it comes by auction); the gateways buy and sell it through WETH.
        PoolKey memory none;
        chosen[CBBTC] = Route(
            "v3 USDG-WETH-cbBTC",
            K_V3,
            abi.encodePacked(USDG, uint24(100), WETH, uint24(3000), CBBTC),
            none,
            0xD30e44aaE604B42a63f6F9A8109FD0408F35b9fb,
            true
        );
        _exitWithUsdg();
        _mintWithUsdg();
    }

    /// @dev Trader exits at NAV: WETH and cbBTC sold for USDG, rZEC and rHYPE sent to Base over live CCIP,
    ///      the rest in kind.
    function _exitWithUsdg() internal {
        FundExitGateway gw = new FundExitGateway(address(factory), RH_CCIP_ROUTER, BASE_SELECTOR, baseGatewayStandIn);
        uint256 shares = IERC20(address(fund)).balanceOf(trader);
        assertGt(shares, 0);
        (IFundExitGateway.Route[] memory routes, uint256 fees) = _exitRoutes(gw, shares);
        emit log_named_decimal_uint("exit: CCIP fees for rZEC + rHYPE (ETH)", fees, 18);

        uint256 zecSupply = rzec.totalSupply();
        uint256 hypeSupply = rhype.totalSupply();
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        IERC20(address(fund)).approve(address(gw), shares);
        uint256 g = gasleft();
        uint256 usdgOut = gw.exit{value: 1 ether}(address(fund), shares, routes, 1, trader);
        emit log_named_uint("gas exit (2 sells, 2 CCIP sends, 14 in kind)", g - gasleft());
        vm.stopPrank();

        emit log_named_decimal_uint("exit: USDG paid at once", usdgOut, 6);
        assertEq(IERC20(USDG).balanceOf(trader) - usdgBefore, usdgOut);
        assertEq(trader.balance, 1 ether - fees, "unused fee refunded");
        assertEq(rzec.totalSupply(), zecSupply - _exitZec, "rZEC not burned by the CCIP pool");
        assertEq(rhype.totalSupply(), hypeSupply - _exitHype, "rHYPE not burned by the CCIP pool");
        assertEq(IERC20(WETH).balanceOf(trader), 0);
        assertGt(IERC20(NVDA).balanceOf(trader), 0, "in-kind leg missing");
        address[] memory a = fund.assets();
        for (uint256 i; i < a.length; ++i) {
            assertEq(IERC20(a[i]).balanceOf(address(gw)), 0, "exit gateway kept a token");
        }
    }

    uint256 internal _exitZec;
    uint256 internal _exitHype;

    function _exitRoutes(
        FundExitGateway gw,
        uint256 shares
    ) internal returns (IFundExitGateway.Route[] memory routes, uint256 fees) {
        address[] memory a = fund.assets();
        (uint256[] memory amounts,) = fund.previewRedeem(shares);
        routes = new IFundExitGateway.Route[](a.length);
        for (uint256 i; i < a.length; ++i) {
            if (amounts[i] == 0) continue;
            if (a[i] == WETH || a[i] == CBBTC) {
                bytes memory path = a[i] == WETH
                    ? abi.encodePacked(WETH, uint24(100), USDG)
                    : abi.encodePacked(CBBTC, uint24(3000), WETH, uint24(100), USDG);
                bytes[] memory inputs = new bytes[](1);
                inputs[0] = abi.encode(MSG_SENDER, amounts[i], uint256(0), path, false, new uint256[](0));
                routes[i].router = address(adapter);
                routes[i].data = abi.encodeCall(FundSwapAdapter.swap, (a[i], amounts[i], USDG, hex"00", inputs));
            } else if (a[i] == address(rzec) || a[i] == address(rhype)) {
                routes[i].bridge = true;
                routes[i].minOut = 1;
                fees += gw.quoteBridge(a[i], amounts[i], trader, 1);
                if (a[i] == address(rzec)) _exitZec = amounts[i];
                else _exitHype = amounts[i];
            }
        }
        assertGt(_exitZec, 0);
        assertGt(_exitHype, 0);
    }

    /// @dev Erin mints a $1k slice with USDG from stock in one transaction, then a second one that the
    ///      stock can't cover: queued, revenue bridged to Base through live Across, restocked over CCIP
    ///      (replayed), and filled by the keeper.
    function _mintWithUsdg() internal {
        FundMintGateway gw = new FundMintGateway(
            SAFE,
            address(factory),
            factory.mintZap(),
            RH_CCIP_ROUTER,
            BASE_SELECTOR,
            baseGatewayStandIn,
            makeAddr("baseFloat"),
            RH_SPOKE_POOL,
            BASE_USDC,
            8453
        );
        (, uint256 nav,) = fund.tryNav();
        uint256 navShares = 1000e18 * 1e18 / nav;
        (,, uint256[] memory amounts,,) = fund.previewMint(navShares, false);
        uint256 zecNeed = _amountOf(address(rzec), amounts);
        uint256 hypeNeed = _amountOf(address(rhype), amounts);

        vm.startPrank(SAFE);
        IAccessFL(REGISTRY).grantRole(keccak256("FUND_GATEWAY"), address(gw));
        gw.setBaseAsset(address(rzec), true);
        gw.setBaseAsset(address(rhype), true);
        gw.setKeeper(KEEPER, true);
        vm.stopPrank();
        // Own's float: stock for one and a half slices.
        _addStock(gw, address(rzec), zecNeed * 3 / 2);
        _addStock(gw, address(rhype), hypeNeed * 3 / 2);
        _pickGatewayRoutes(gw, navShares);

        uint256 stakedBefore = staking.balanceOf(erin);
        (uint256 shares, uint256 id) = _gatewayMint(gw, navShares);
        assertEq(id, 0, "first mint should come from stock");
        assertGt(shares, 0);
        assertGt(staking.balanceOf(erin), stakedBefore);
        emit log_named_decimal_uint("gateway mint from stock: $1k slice -> fund tokens", shares, 18);
        assertEq(IERC20(USDG).balanceOf(address(gw)), gw.revenue(), "gateway kept user USDG");

        _queuedMint(gw, navShares, zecNeed, hypeNeed);
    }

    function _queuedMint(FundMintGateway gw, uint256 navShares, uint256 zecNeed, uint256 hypeNeed) internal {
        (uint256 shares, uint256 id) = _gatewayMint(gw, navShares);
        assertEq(shares, 0);
        assertEq(id, 1, "second mint should queue");
        IFundMintGateway.Order memory o = gw.getOrder(1);
        emit log_named_decimal_uint("queued: USDG prepaid for rZEC + rHYPE", o.prepaid, 6);
        emit log_named_decimal_uint("queued: USDG held for the Robinhood part", o.usdg, 6);

        // Keeper bridges the float's USDG to the Base gateway through the live SpokePool.
        uint256 rev = gw.revenue();
        uint256 spokeBefore = IERC20(USDG).balanceOf(RH_SPOKE_POOL);
        vm.prank(KEEPER);
        gw.bridgeRevenue(rev, rev - 1.5e6, uint32(block.timestamp));
        assertEq(IERC20(USDG).balanceOf(RH_SPOKE_POOL) - spokeBefore, rev, "Across deposit missing");
        emit log_named_decimal_uint("revenue bridged to Base (USDG)", rev, 6);

        // The Base gateway buys, wraps and sends one CCIP message per asset; replayed as the Router.
        _arrive(gw, address(rzec), zecNeed, keccak256("restock-zec"));
        _arrive(gw, address(rhype), hypeNeed, keccak256("restock-hype"));

        _warpTo(block.timestamp + 30 minutes);
        uint256 before = staking.balanceOf(erin);
        IFundMintGateway.Swap[] memory swaps = _gatewaySwaps(gw, navShares);
        vm.prank(KEEPER);
        uint256 g = gasleft();
        shares = gw.fill(1, swaps, navShares);
        emit log_named_uint("gas fill (16 swaps, 18 assets)", g - gasleft());
        assertGt(shares, 0);
        assertGt(staking.balanceOf(erin), before);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Filled));
        assertEq(IERC20(USDG).balanceOf(address(gw)), gw.revenue(), "gateway kept user USDG after fill");
        emit log_named_decimal_uint("queued mint filled after restock -> fund tokens", shares, 18);
    }

    function _gatewayMint(FundMintGateway gw, uint256 navShares) internal returns (uint256 shares, uint256 id) {
        IFundMintGateway.Swap[] memory swaps = _gatewaySwaps(gw, navShares);
        uint256 pay = _stockPay(gw, navShares);
        for (uint256 i; i < swaps.length; ++i) {
            pay += swaps[i].amountIn;
        }
        _give(USDG, erin, pay);
        uint256 before = IERC20(USDG).balanceOf(erin);
        vm.startPrank(erin);
        IERC20(USDG).approve(address(gw), pay);
        uint256 g = gasleft();
        (shares, id) = gw.mint(address(fund), pay, swaps, navShares, 0, false);
        emit log_named_uint(id == 0 ? "gas gateway mint (16 swaps)" : "gas gateway mint (queued)", g - gasleft());
        vm.stopPrank();
        emit log_named_decimal_uint("  USDG paid", before - IERC20(USDG).balanceOf(erin), 6);
    }

    mapping(address => Route) internal gwRoute;

    /// @dev The route the gateway buys each Robinhood asset through: the launch's choice or another candidate
    ///      that fills the slice. Fork-only: with no arbitrage after the launch rebalance some pools stay drained
    ///      (and WETH unwraps fail on a fork), so an asset no route can fill is stocked like rZEC and rHYPE.
    function _pickGatewayRoutes(FundMintGateway gw, uint256 navShares) internal {
        (,, uint256[] memory amounts,,) = fund.previewMint(navShares, false);
        address[] memory a = fund.assets();
        for (uint256 i; i < a.length; ++i) {
            if (amounts[i] == 0 || gw.isBaseAsset(a[i])) continue;
            uint256 usdgIn = _swapBudget(a[i], amounts[i]);
            bool found;
            (bool ok, uint256 out) = _probe(chosen[a[i]], a[i], usdgIn);
            if (ok && out >= amounts[i]) (gwRoute[a[i]], found) = (chosen[a[i]], true);
            Route[] storage list = candidates[a[i]];
            for (uint256 j; j < list.length && !found; ++j) {
                (ok, out) = _probe(list[j], a[i], usdgIn);
                if (ok && out >= amounts[i]) (gwRoute[a[i]], found) = (list[j], true);
            }
            if (found) {
                emit log_named_string(string.concat("gateway route ", _sym(a[i])), gwRoute[a[i]].label);
                continue;
            }
            emit log_named_string("no fork route fills the slice; stocked in the gateway", _sym(a[i]));
            vm.prank(SAFE);
            gw.setBaseAsset(a[i], true);
            _addStock(gw, a[i], amounts[i] * 3);
        }
    }

    function _swapBudget(address asset, uint256 amount) internal view returns (uint256) {
        return _value(asset, amount) * 130 / 100 / 1e12 + 1e6;
    }

    /// @dev USDG -> every asset of the slice the gateway doesn't stock, 30% over the oracle value (the excess
    ///      comes back to the minter).
    function _gatewaySwaps(
        FundMintGateway gw,
        uint256 navShares
    ) internal view returns (IFundMintGateway.Swap[] memory swaps) {
        (,, uint256[] memory amounts,,) = fund.previewMint(navShares, false);
        address[] memory a = fund.assets();
        uint256 n;
        for (uint256 i; i < a.length; ++i) {
            if (amounts[i] != 0 && !gw.isBaseAsset(a[i])) ++n;
        }
        swaps = new IFundMintGateway.Swap[](n);
        uint256 k;
        for (uint256 i; i < a.length; ++i) {
            if (amounts[i] == 0 || gw.isBaseAsset(a[i])) continue;
            uint256 usdgIn = _swapBudget(a[i], amounts[i]);
            (bytes memory commands, bytes[] memory inputs) = _urCalldata(gwRoute[a[i]], a[i], usdgIn);
            swaps[k++] = IFundMintGateway.Swap({
                router: address(adapter),
                tokenIn: USDG,
                amountIn: usdgIn,
                data: abi.encodeCall(FundSwapAdapter.swap, (USDG, usdgIn, a[i], commands, inputs))
            });
        }
    }

    /// @dev The fund's USDG slice plus the stock's cost, plus a margin the gateway refunds.
    function _stockPay(FundMintGateway gw, uint256 navShares) internal view returns (uint256 pay) {
        (,, uint256[] memory amounts, uint256 usdgSlice,) = fund.previewMint(navShares, false);
        address[] memory a = fund.assets();
        pay = usdgSlice + 5e6;
        for (uint256 i; i < a.length; ++i) {
            if (amounts[i] != 0 && gw.isBaseAsset(a[i])) pay += gw.stockCost(a[i], amounts[i]);
        }
    }

    function _addStock(FundMintGateway gw, address asset, uint256 amount) internal {
        _give(asset, SAFE, amount);
        vm.startPrank(SAFE);
        IERC20(asset).approve(address(gw), amount);
        gw.addStock(asset, amount);
        vm.stopPrank();
    }

    function _arrive(FundMintGateway gw, address asset, uint256 amount, bytes32 messageId) internal {
        _give(asset, address(gw), amount);
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: asset, amount: amount});
        uint256 before = gw.stock(asset);
        vm.prank(RH_CCIP_ROUTER);
        gw.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: BASE_SELECTOR,
                sender: abi.encode(baseGatewayStandIn),
                data: "",
                destTokenAmounts: tokens
            })
        );
        assertEq(gw.stock(asset) - before, amount);
    }

    function _amountOf(address asset, uint256[] memory amounts) internal view returns (uint256) {
        address[] memory a = fund.assets();
        for (uint256 i; i < a.length; ++i) {
            if (a[i] == asset) return amounts[i];
        }
        return 0;
    }

    // ──────────────────────────────────────────────────────────
    //  Launch rebalance
    // ──────────────────────────────────────────────────────────

    uint256 constant BPS_SCALE = 10_000;

    /// @dev The fund's own call straight into the Universal Router (payer = the fund, through
    ///      Permit2), which is what `setRouter(UniversalRouter)` would allow.
    function _checkUniversalRouterDirect() internal {
        vm.prank(SAFE);
        factory.setRouter(UNIVERSAL_ROUTER, true);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(fund), uint256(100e6), uint256(0), abi.encodePacked(USDG, uint24(100), WETH), true, new uint256[](0)
        );
        IFund.RebalanceParams memory p = IFund.RebalanceParams({
            sellAsset: USDG,
            sellAmount: 100e6,
            buyAsset: WETH,
            minBuyAmount: 0,
            router: UNIVERSAL_ROUTER,
            data: abi.encodeCall(IUniversalRouterFL.execute, (hex"00", inputs, block.timestamp))
        });
        vm.prank(KEEPER);
        vm.expectRevert(IFund.RebalanceCallFailed.selector);
        fund.rebalance(p);
        vm.prank(SAFE);
        factory.setRouter(UNIVERSAL_ROUTER, false);
        emit log(
            "fund.rebalance straight into the Universal Router reverts (it pulls via Permit2 only); trading via FundSwapAdapter"
        );
    }

    /// @dev Buys `need` USDG worth of `asset` in chunks under the slippage bound, waiting out the
    ///      daily volume cap when it binds.
    function _buy(address asset, uint256 need) internal {
        uint256 chunk = _chunkFor(asset, need);
        fills[asset].chunk = chunk;
        uint256 left = need;
        uint256 waits;
        while (left != 0) {
            uint256 amount = Math.min(left, chunk);
            if (left - amount < chunk / 10) amount = left;
            bytes4 err = _rebalanceOnce(asset, amount);
            if (err == bytes4(0)) {
                left -= amount;
            } else if (err == IFund.RebalanceVolumeExceeded.selector && waits < 4) {
                emit log_named_decimal_uint(
                    string.concat("volume cap hit buying ", _sym(asset), "; volume USD"), fund.rebalanceVolume(), 18
                );
                _warpTo(block.timestamp + 6 hours);
                ++waits;
            } else if (err == IFund.RebalanceInvalid.selector && chunk > need / 16) {
                chunk /= 2;
                fills[asset].chunk = chunk;
            } else if (err == IFund.RebalanceInvalid.selector && _nextRoute(asset)) {
                // On a fork nobody arbitrages the pool back to the oracle, so move to the next pool.
                emit log_named_decimal_uint(
                    string.concat("route exhausted under 2% for ", _sym(asset), "; switching, USDG left"), left, 6
                );
                chunk = left;
            } else {
                emit log_named_bytes(string.concat("PROBLEM: cannot buy ", _sym(asset)), abi.encodePacked(err));
                emit log_named_decimal_uint(string.concat("  USDG left unspent for ", _sym(asset)), left, 6);
                return;
            }
        }
    }

    function _nextRoute(
        address asset
    ) internal returns (bool) {
        Route[] storage list = candidates[asset];
        uint256 n = ++routeTries[asset];
        if (n >= list.length) return false;
        uint256 at;
        for (uint256 i; i < list.length; ++i) {
            if (keccak256(bytes(list[i].label)) == keccak256(bytes(chosen[asset].label))) at = i;
        }
        chosen[asset] = list[(at + 1) % list.length];
        routeUsed[asset] = string.concat(routeUsed[asset], " + ", chosen[asset].label);
        return true;
    }

    function _rebalanceOnce(address asset, uint256 amount) internal returns (bytes4 err) {
        Route storage r = chosen[asset];
        (bytes memory commands, bytes[] memory inputs) = _urCalldata(r, asset, amount);
        IFund.RebalanceParams memory p = IFund.RebalanceParams({
            sellAsset: USDG,
            sellAmount: amount,
            buyAsset: asset,
            minBuyAmount: 1,
            router: address(adapter),
            data: abi.encodeCall(FundSwapAdapter.swap, (USDG, amount, asset, commands, inputs))
        });
        uint256 before = IERC20(asset).balanceOf(address(fund));
        vm.prank(KEEPER);
        uint256 g = gasleft();
        try fund.rebalance(p) {
            Fill storage f = fills[asset];
            f.gas += g - gasleft();
            ++f.swaps;
            f.sold += amount;
            f.soldValue += amount * 1e12;
            f.boughtValue += _value(asset, IERC20(asset).balanceOf(address(fund)) - before);
        } catch (bytes memory reason) {
            err = bytes4(reason);
            if (err == bytes4(0)) err = 0xffffffff;
        }
    }

    /// @dev Largest chunk (halving from `need`) whose cost against the oracle stays under 1.8%,
    ///      probed on a snapshot. Also logs the largest swap that fits under 2% (doubling).
    function _chunkFor(address asset, uint256 need) internal returns (uint256 chunk) {
        chunk = need;
        for (uint256 i; i < 6 && _probeCostBps(asset, chunk) > 180; ++i) {
            chunk /= 2;
        }
        uint256 max = chunk;
        for (uint256 i; i < 8 && _probeCostBps(asset, max * 2) <= 200; ++i) {
            max *= 2;
        }
        emit log_named_decimal_uint(
            string.concat("probe cost bps at full size ", _sym(asset)), _probeCostBps(asset, need), 0
        );
        emit log_named_decimal_uint(
            string.concat("probe one swap under 2% fits at least (USDG, x2 steps from chunk) ", _sym(asset)), max, 6
        );
    }

    function _probeCostBps(address asset, uint256 usdgIn) internal returns (uint256) {
        (bool ok, uint256 out) = _probe(chosen[asset], asset, usdgIn);
        if (!ok) return type(uint128).max;
        uint256 v = _value(asset, out);
        uint256 sold = usdgIn * 1e12;
        return v >= sold ? 0 : (sold - v) * BPS_SCALE / sold;
    }

    function _probe(Route memory r, address asset, uint256 usdgIn) internal returns (bool ok, uint256 out) {
        uint256 snap = vm.snapshotState();
        _give(USDG, prober, usdgIn);
        (bytes memory commands, bytes[] memory inputs) = _urCalldata(r, asset, usdgIn);
        vm.startPrank(prober);
        IERC20(USDG).approve(address(adapter), usdgIn);
        try adapter.swap(USDG, usdgIn, asset, commands, inputs) returns (uint256 o) {
            (ok, out) = (true, o);
        } catch {}
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _chooseRoute(address asset, uint256 usdgIn) internal {
        Route[] storage list = candidates[asset];
        uint256 best;
        uint256 bestOut;
        for (uint256 i; i < list.length; ++i) {
            (bool ok, uint256 out) = _probe(list[i], asset, usdgIn);
            emit log_named_decimal_uint(
                string.concat("  candidate ", list[i].label, " out"), ok ? out : 0, IERC20Metadata(asset).decimals()
            );
            if (ok && out > bestOut) (best, bestOut) = (i, out);
        }
        assertGt(bestOut, 0, string.concat("no route for ", _sym(asset)));
        chosen[asset] = list[best];
        routeUsed[asset] = list[best].label;
    }

    function _urCalldata(
        Route memory r,
        address asset,
        uint256 amount
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        if (r.kind == K_V3) {
            commands = hex"00";
            inputs = new bytes[](1);
            inputs[0] = abi.encode(MSG_SENDER, amount, uint256(0), r.path, false, new uint256[](0));
        } else if (r.kind == K_V4) {
            commands = hex"10";
            inputs = new bytes[](1);
            inputs[0] = _v4Input(r.key, USDG, asset);
        } else {
            commands = hex"000c10";
            inputs = new bytes[](3);
            inputs[0] = abi.encode(ADDRESS_THIS, amount, uint256(0), r.path, false, new uint256[](0));
            inputs[1] = abi.encode(ADDRESS_THIS, uint256(0));
            inputs[2] = _v4Input(r.key, address(0), asset);
        }
    }

    /// @dev SETTLE the router's whole balance of `tokenIn`, swap all of it, TAKE_ALL to the caller.
    function _v4Input(PoolKey memory key, address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(Currency.wrap(tokenIn), CONTRACT_BALANCE, false);
        params[1] =
            abi.encode(ExactInputSingleParams(key, Currency.unwrap(key.currency0) == tokenIn, 0, 0, 0, bytes("")));
        params[2] = abi.encode(Currency.wrap(tokenOut), uint256(0));
        return abi.encode(abi.encodePacked(uint8(0x0b), uint8(0x06), uint8(0x0f)), params);
    }

    /// @dev Mid price of `asset` in USD (18 decimals) from the route's last pool.
    function _routeMid(Route storage r, address asset) internal view returns (uint256) {
        uint160 sqrtP;
        address t0;
        if (r.kind == K_V3) {
            (sqrtP,,,,,,) = IV3PoolFL(r.pricePool).slot0();
            t0 = IV3PoolFL(r.pricePool).token0();
        } else {
            (sqrtP,,,) = IPoolManager(POOL_MANAGER).getSlot0(r.key.toId());
            t0 = Currency.unwrap(r.key.currency0);
        }
        uint256 r36 = Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 96), 1e36, 1 << 96);
        uint256 perToken = asset == t0 ? r36 : 1e72 / r36;
        uint256 quoteUsd = r.quoteIsEth ? uint256(clAnswer[FEED_ETH]) * 1e10 : 1e18;
        uint256 quoteDecimals = r.quoteIsEth ? 18 : 6;
        return Math.mulDiv(perToken, 10 ** IERC20Metadata(asset).decimals() * quoteUsd, 10 ** quoteDecimals * 1e36);
    }

    function _launchBuy(
        address asset
    ) internal view returns (uint256) {
        uint256 target = fund.totalValue() * (BPS_SCALE - launch.config().poolUsdgBps) / BPS_SCALE
            * fund.targetWeightBps(asset) / BPS_SCALE;
        uint256 held = _value(asset, IERC20(asset).balanceOf(address(fund)));
        return target > held ? (target - held) / 1e12 : 0;
    }

    function _plannedBuy(
        address asset
    ) internal view returns (uint256) {
        for (uint256 i; i < basket.length; ++i) {
            if (basket[i] == asset) return uint256(101_000e6) * 9 / 10 * weights[i] / BPS_SCALE;
        }
        return 0;
    }

    // ──────────────────────────────────────────────────────────
    //  Auctions
    // ──────────────────────────────────────────────────────────

    function _auctionTarget(
        address asset
    ) internal view returns (uint256 usdgAmount) {
        usdgAmount = _launchBuy(asset);
        // One lot is at most the relay's float.
        if (usdgAmount > 7500e6) usdgAmount = 7500e6;
    }

    function _openLot(address asset, uint256 usdgAmount) internal returns (uint256 id) {
        vm.prank(KEEPER);
        uint256 g = gasleft();
        id = auctions.openLot(address(fund), USDG, asset, usdgAmount);
        emit log_named_uint(string.concat("gas openLot ", _sym(asset)), g - gasleft());
    }

    function _fillLot(uint256 id, uint256 after_) internal {
        IFundAuctions.Lot memory l = auctions.lot(id);
        _warpTo(l.startTime + after_);
        uint256 payment = auctions.quote(id, l.remaining);
        uint256 soldValue = uint256(l.remaining) * 1e12;
        uint256 paidValue = _value(l.buyAsset, payment);
        uint256 before = IERC20(l.buyAsset).balanceOf(address(fund));
        vm.prank(relay);
        uint256 g = gasleft();
        auctions.fill(id, l.remaining, payment);
        emit log_named_uint(string.concat("gas fill ", _sym(l.buyAsset)), g - gasleft());
        assertEq(IERC20(l.buyAsset).balanceOf(address(fund)) - before, payment, "auction payment short");
        emit log_named_int(
            string.concat("fill ", _sym(l.buyAsset), " paid vs oracle bps"),
            int256(paidValue * BPS_SCALE / soldValue) - int256(BPS_SCALE)
        );
    }

    /// @dev On a snapshot: near the floor, a 1.5% fall in the bought asset's oracle price makes the
    ///      fill worth less than the floor bound, and it reverts.
    function _expectFillBelowOracleBound(uint256 id, address asset) internal {
        uint256 snap = vm.snapshotState();
        IFundAuctions.Lot memory l = auctions.lot(id);
        _warpTo(l.endTime - 1);
        int256 a = clAnswer[FEED_CBBTC];
        clAnswer[FEED_CBBTC] = a * 985 / 1000;
        _refreshPrices();
        uint256 payment = auctions.quote(id, l.remaining);
        vm.prank(relay);
        vm.expectRevert(IFundAuctions.BelowOracleBound.selector);
        auctions.fill(id, l.remaining, payment);
        clAnswer[FEED_CBBTC] = a;
        vm.revertToState(snap);
        emit log(string.concat("fill of ", _sym(asset), " below the oracle floor refused (BelowOracleBound)"));
    }

    // ──────────────────────────────────────────────────────────
    //  Trading the fund token (what the Uniswap app sends)
    // ──────────────────────────────────────────────────────────

    function _urTrade(address tokenIn, uint128 amountIn) internal returns (uint256 out) {
        PoolKey memory key = venue.poolKey();
        address tokenOut = tokenIn == USDG ? address(fund) : USDG;
        if (tokenIn == USDG) _give(USDG, trader, amountIn);
        vm.startPrank(trader);
        IERC20(tokenIn).approve(PERMIT2, type(uint256).max);
        IPermit2FL(PERMIT2).approve(tokenIn, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, 0, 0, bytes("")));
        params[1] = abi.encode(Currency.wrap(tokenIn), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(tokenOut), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        uint256 before = IERC20(tokenOut).balanceOf(trader);
        IUniversalRouterFL(UNIVERSAL_ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        vm.stopPrank();
        out = IERC20(tokenOut).balanceOf(trader) - before;
    }

    // ──────────────────────────────────────────────────────────
    //  Token transfer quirks (step 10)
    // ──────────────────────────────────────────────────────────

    function test_fork_basketTokenTransferQuirks() public requiresFork {
        address[17] memory tokens =
            [NVDA, SPCX, PLTR, META, TSLA, GOOGL, LLY, SKHY, WETH, CBBTC, UNI, PONS, AI, CASHCAT, WSNET, HOOKR, USDG];
        address a = makeAddr("holderA");
        address b = makeAddr("holderB");
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            uint256 unit = 10 ** IERC20Metadata(t).decimals();
            _give(t, a, 10 * unit);
            TransferProbe probe = new TransferProbe();

            vm.prank(a);
            IERC20(t).transfer(b, unit);
            assertEq(IERC20(t).balanceOf(b), unit, string.concat(_sym(t), ": fee on transfer"));
            assertEq(IERC20(t).balanceOf(a), 9 * unit, string.concat(_sym(t), ": sender debited more"));

            vm.prank(a);
            IERC20(t).transfer(address(probe), unit);
            vm.prank(a);
            IERC20(t).approve(address(probe), unit);
            probe.pull(t, a, unit);
            assertEq(IERC20(t).balanceOf(address(probe)), 2 * unit, string.concat(_sym(t), ": contract got less"));
            assertEq(probe.calls(), 0, string.concat(_sym(t), ": calls the receiver"));

            (bool hasPaused, bytes memory ret) = t.staticcall(abi.encodeWithSignature("paused()"));
            bool pausable = hasPaused && ret.length == 32;
            emit log_named_string(
                _sym(t),
                string.concat(
                    "transfer exact, no receiver callback",
                    pausable ? (abi.decode(ret, (bool)) ? "; PAUSED" : "; pausable (not paused)") : ""
                )
            );
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Setup helpers
    // ──────────────────────────────────────────────────────────

    function _defineBasket() internal {
        basket = [
            NVDA,
            SPCX,
            PLTR,
            META,
            TSLA,
            GOOGL,
            LLY,
            SKHY,
            WETH,
            CBBTC,
            address(rhype),
            address(rzec),
            UNI,
            PONS,
            AI,
            CASHCAT,
            WSNET,
            HOOKR
        ];
        weights = [900, 800, 700, 600, 600, 500, 500, 400, 900, 800, 600, 400, 300, 600, 400, 400, 300, 300];
    }

    function _defineRoutes() internal {
        address e = address(0);
        _v3(
            NVDA,
            "v3 NVDA/USDG 0.05%",
            abi.encodePacked(USDG, uint24(500), NVDA),
            0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3,
            false
        );
        _v4(NVDA, "v4 NVDA/USDG 0.01%", _key(USDG, NVDA, 100, 1, e));
        _v3(
            SPCX,
            "v3 SPCX/USDG 0.05%",
            abi.encodePacked(USDG, uint24(500), SPCX),
            0xc61284332117c3FB23A2A56cceFFD07F7aF60029,
            false
        );
        _v3(
            SPCX,
            "v3 USDG>WETH 0.01% > SPCX 0.05%",
            abi.encodePacked(USDG, uint24(100), WETH, uint24(500), SPCX),
            0xC3c9F0171490Ef0F4536fe493F3b0EbB5ee0CB5e,
            true
        );
        _v4(PLTR, "v4 PLTR/USDG 1%", _key(USDG, PLTR, 10_000, 200, e));
        _v4(PLTR, "v4 PLTR/USDG 0.15%", _key(USDG, PLTR, 1500, 15, e));
        _v3(
            PLTR,
            "v3 PLTR/USDG 0.3%",
            abi.encodePacked(USDG, uint24(3000), PLTR),
            0x851680416A4f4E1c463d45171d61ACDdBc8554c0,
            false
        );
        _v4(META, "v4 META/USDG 0.3%", _key(USDG, META, 3000, 60, e));
        _v3(
            META,
            "v3 META/USDG 0.3%",
            abi.encodePacked(USDG, uint24(3000), META),
            0x107a7Cb40d8665360ba10E59471Af06150A50922,
            false
        );
        _v4(TSLA, "v4 TSLA/USDG 0.3%", _key(TSLA, USDG, 3000, 60, e));
        _v3(
            TSLA,
            "v3 TSLA/USDG 0.3%",
            abi.encodePacked(USDG, uint24(3000), TSLA),
            0xf4ACdAEEB7022862A763C9B1B885e11191c889E3,
            false
        );
        _v3(
            GOOGL,
            "v3 GOOGL/USDG 0.05%",
            abi.encodePacked(USDG, uint24(500), GOOGL),
            0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7,
            false
        );
        _v4(GOOGL, "v4 GOOGL/USDG 0.3%", _key(GOOGL, USDG, 3000, 60, e));
        _v3(
            LLY,
            "v3 LLY/USDG 0.05%",
            abi.encodePacked(USDG, uint24(500), LLY),
            0xF212D02146a897F5F686E9d629F6A73da534324a,
            false
        );
        _v3(
            LLY,
            "v3 USDG>WETH 0.01% > LLY 0.3%",
            abi.encodePacked(USDG, uint24(100), WETH, uint24(3000), LLY),
            0x666bA98aB094793e276215448F2485FD8e3c3CE5,
            true
        );
        _v4(SKHY, "v4 SKHY/USDG dynamic (hook 0xc15b)", _key(USDG, SKHY, 0x800000, 60, SKHY_HOOK));
        _v4(SKHY, "v4 SKHY/USDG 0.888%", _key(USDG, SKHY, 8880, 89, e));
        _v3(
            SKHY,
            "v3 SKHY/USDG 0.3%",
            abi.encodePacked(USDG, uint24(3000), SKHY),
            0x5F2a5025feb93a4C44DA4E3B37e4fD3Fb0ab5171,
            false
        );
        _v3(WETH, "v3 USDG/WETH 0.01%", abi.encodePacked(USDG, uint24(100), WETH), V3_USDG_WETH_001, false);
        _v3eth(UNI, "v3 USDG>WETH 0.01%, unwrap, v4 ETH/UNI 1%", _key(e, UNI, 10_000, 100, e));
        _v4(UNI, "v4 UNI/USDG 0.35%", _key(USDG, UNI, 3500, 35, e));
        _v4(PONS, "v4 PONS/USDG 0.3%", _key(PONS, USDG, 3000, 60, e));
        _v4(PONS, "v4 PONS/USDG dynamic (Pons hook)", _key(PONS, USDG, 0x800000, 60, POONS_HOOK));
        _v3(
            PONS,
            "v3 USDG>WETH 0.01% > PONS 0.3%",
            abi.encodePacked(USDG, uint24(100), WETH, uint24(3000), PONS),
            0xEd50bDeeA8aDC232f159486192a4157281D722ff,
            true
        );
        _v3(
            AI,
            "v3 USDG>WETH 0.01% > AI 1%",
            abi.encodePacked(USDG, uint24(100), WETH, uint24(10_000), AI),
            0xc4a21f9d6485FC5893DD4A491B320a83DAF4Da1D,
            true
        );
        _v4(AI, "v4 AI/USDG 1%", _key(AI, USDG, 10_000, 200, e));
        _v4(AI, "v4 AI/USDG dynamic (Pons hook)", _key(AI, USDG, 0x800000, 60, POONS_HOOK));
        _v4(CASHCAT, "v4 CASHCAT/USDG 0.269%", _key(CASHCAT, USDG, 2690, 54, e));
        _v3(
            CASHCAT,
            "v3 USDG>WETH 0.01% > CASHCAT 0.3%",
            abi.encodePacked(USDG, uint24(100), WETH, uint24(3000), CASHCAT),
            0xd42A491087a15E5afd51FEb3606066Cc152d2b09,
            true
        );
        _v4(CASHCAT, "v4 CASHCAT/USDG dynamic (Pons hook)", _key(CASHCAT, USDG, 0x800000, 60, POONS_HOOK));
        _v3(
            WSNET,
            "v3 wsNET/USDG 1%",
            abi.encodePacked(USDG, uint24(10_000), WSNET),
            0x8315627976cab8bd937eB53D44D009e265D0e4DC,
            false
        );
        _v4(WSNET, "v4 wsNET/USDG 1.25%", _key(USDG, WSNET, 12_500, 125, e));
        _v3eth(HOOKR, "v3 USDG>WETH 0.01%, unwrap, v4 ETH/HOOKR 0.25%", _key(e, HOOKR, 2500, 25, e));
        _v4(HOOKR, "v4 HOOKR/USDG 1%", _key(HOOKR, USDG, 10_000, 100, e));
        _v3(
            HOOKR,
            "v3 USDG>WETH 0.01% > HOOKR 1%",
            abi.encodePacked(USDG, uint24(100), WETH, uint24(10_000), HOOKR),
            0x42b19e5e3F28C4148C518444546f102F6ba87aB1,
            true
        );
    }

    function _key(
        address c0,
        address c1,
        uint24 fee,
        int24 spacing,
        address hooks
    ) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hooks));
    }

    function _v3(address asset, string memory label, bytes memory path, address pool, bool viaEth) internal {
        PoolKey memory none;
        candidates[asset].push(Route(label, K_V3, path, none, pool, viaEth));
    }

    function _v4(address asset, string memory label, PoolKey memory key) internal {
        candidates[asset].push(Route(label, K_V4, "", key, address(0), false));
    }

    function _v3eth(address asset, string memory label, PoolKey memory key) internal {
        candidates[asset].push(
            Route(label, K_V3_ETH_V4, abi.encodePacked(USDG, uint24(100), WETH), key, address(0), true)
        );
    }

    function _recordChainlink() internal {
        clFeeds = [FEED_NVDA, FEED_SPCX, FEED_META, FEED_TSLA, FEED_GOOGL, FEED_PLTR, FEED_ETH, FEED_CBBTC];
        for (uint256 i; i < clFeeds.length; ++i) {
            (, int256 answer,, uint256 updatedAt,) = IAggregatorFL(clFeeds[i]).latestRoundData();
            clAnswer[clFeeds[i]] = answer;
            emit log_named_uint(
                string.concat("chainlink age at fork (s) ", vm.toString(clFeeds[i])), block.timestamp - updatedAt
            );
        }
    }

    /// @dev FORK WORKAROUND: re-stamps every Chainlink answer at the current time (the fork's feeds
    ///      never update), and has the keeper push the hub prices.
    function _refreshPrices() internal {
        for (uint256 i; i < clFeeds.length; ++i) {
            address f = clFeeds[i];
            uint80 round = uint80(block.timestamp);
            vm.mockCall(
                f,
                abi.encodeWithSelector(IAggregatorFL.latestRoundData.selector),
                abi.encode(round, clAnswer[f], block.timestamp, block.timestamp, round)
            );
        }
        uint256[] memory prices = new uint256[](hubAssets.length);
        for (uint256 i; i < hubAssets.length; ++i) {
            prices[i] = hubPrice[hubAssets[i]];
        }
        vm.prank(KEEPER);
        hub.pushPrices(hubAssets, prices);
    }

    function _warpTo(
        uint256 t
    ) internal {
        vm.warp(t);
        vm.roll(block.number + 1);
        _refreshPrices();
    }

    function _depositUsdg(address who, uint256 amount) internal {
        _give(USDG, who, amount);
        vm.startPrank(who);
        IERC20(USDG).approve(address(launch), amount);
        uint256 received = launch.deposit(USDG, amount);
        vm.stopPrank();
        assertEq(received, amount);
    }

    /// @dev `deal` adjusts the balance slot (and leaves supply alone); the stand-ins are minted.
    function _give(address token, address to, uint256 amount) internal {
        if (token == address(rzec) || token == address(rhype)) {
            // Supply moves too, so a CCIP pool burn on the way out doesn't underflow it.
            deal(token, to, IERC20(token).balanceOf(to) + amount, true);
            return;
        }
        deal(token, to, IERC20(token).balanceOf(to) + amount);
    }

    function _value(address asset, uint256 amount) internal view returns (uint256) {
        if (asset == USDG) return amount * 1e12;
        return amount * oracle.price(asset) / 10 ** IERC20Metadata(asset).decimals();
    }

    function _sym(
        address token
    ) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }
}
