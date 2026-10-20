// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployFundsRobinhood} from "./DeployFundsRobinhood.s.sol";
import {console} from "forge-std/Script.sol";

import {FundAuctions} from "../../src/funds/FundAuctions.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundPriceHub} from "../../src/funds/FundPriceHub.sol";
import {FundSwapAdapter} from "../../src/funds/FundSwapAdapter.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {CreateFundParams, PoolSettings, YieldPoint} from "../../src/interfaces/types/FundTypes.sol";
import {ChainlinkOracleVerifier} from "../../src/oracle/ChainlinkOracleVerifier.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title FrontierFundBatches — the governance Safe's batches that set up and launch Frontier Fund 1
/// @notice Builds each batch from the deployed addresses, runs it as the Safe on the RPC's chain state
///         (nothing is broadcast), checks the result and writes it to `safe-batches/<name>.json` for the
///         Safe Transaction Builder, with `<name>.md` listing every call for the signers. In order:
///
///         1. `setupBatch()` after `DeployFundsRobinhood` and once rZEC / rHYPE exist on Robinhood Chain:
///            the deploy script's wiring, the R.PLTR, ETH and CBBTC verifier tickers, a price source for all 18 basket
///            tokens and their listing eligibility. The keeper then pushes hub prices.
///         2. `createFundBatch()`: Frontier Fund 1 with the confirmed parameters
///            (/mnt/project-files/plans/frontier-fund-params.md). Its 15-day deposit window starts here.
///         3. `beforeCloseBatch(fund)` any time during the window: the fund token's hub feed (needed before
///            `seedPool`) and the 50% daily rebalance cap for the launch rebalance.
///         4. `afterLaunchWeekBatch()` once the launch rebalance and auctions are done: the cap back to 10%.
///
///         Needs FUND_ADMIN (the Safe holds it after safe-txns/grant-fund-admin-operator-2026-10-17.json);
///         the verifier tickers need the registry ADMIN, which the Safe also holds.
///
/// Env: FUND_ORACLE, FUND_FACTORY, FUND_AUCTIONS, FUND_PRICE_HUB, FUND_MINT_ZAP, FUND_SWAP_ADAPTER (the
///      addresses DeployFundsRobinhood prints), RZEC, RHYPE (the CrossChainTokens on Robinhood Chain),
///      MONEY_TOKEN (optional, as in the deploy script).
///
/// Usage:
///   forge script script/funds/FrontierFundBatches.s.sol --rpc-url robinhood --sig "setupBatch()"
///   forge script script/funds/FrontierFundBatches.s.sol --rpc-url robinhood --sig "beforeCloseBatch(address)" <fund>
contract FrontierFundBatches is DeployFundsRobinhood {
    struct Call {
        address to;
        bytes data;
        string label;
    }

    struct Deployment {
        address oracle;
        address factory;
        address auctions;
        address hub;
        address mintZap;
        address swapAdapter;
        address money;
        address rzec;
        address rhype;
    }

    address constant REGISTRY = 0x93e08ca467046737F75AAD4C936356c196AaA36F;
    address constant SAFE = 0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2;
    address constant KEEPER = 0xB1284eC8A142d71A3694b66e2fe9a8e0014de88e;

    // Basket (portfolios/frontier-fund-ai-space-onchain-money.csv, ZEC and HYPE as rZEC and rHYPE).
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

    // Chainlink proxies on Robinhood Chain.
    address constant FEED_PLTR = 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c;
    address constant FEED_ETH = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant FEED_CBBTC = 0x0009cD492adf8167f9eEBf1293556A673530a21a;

    // R.PLTR gets the live R.NVDA / R.TSLA ticker settings.
    uint32 constant PLTR_CL_SILENCE = 15 minutes;
    uint32 constant PLTR_CL_FRESH_WINDOW = 4 hours;
    uint32 constant PLTR_MAX_ANCHOR_AGE = 5 days;
    uint32 constant PLTR_INHOUSE_MAX_STALENESS = 1 hours;
    uint16 constant PLTR_BAND_BPS = 300;

    // ETH and CBBTC tickers: the stock settings, but a 24/7 feed (0.5% deviation, 24h heartbeat) never
    // goes quiet for days, so the anchor may not be older than one heartbeat plus slack.
    uint32 constant CRYPTO_MAX_ANCHOR_AGE = 26 hours;

    // FundOracle staleness: verifier tickers (the signer quotes while the feed is quiet), hub feeds
    // (the keeper pushes at least every 2 hours).
    uint32 constant STOCK_STALENESS = 6 hours;
    uint32 constant HUB_STALENESS = 2 hours;

    uint16 constant LAUNCH_WEEK_CAP_BPS = 5000;
    uint16 constant NORMAL_CAP_BPS = 1000;

    string constant OUT_DIR = "safe-batches/";

    /// @dev Not the deploy: this script only builds batches. Same as `setupBatch()`.
    function run() external override {
        setupBatch();
    }

    /// @notice Batch 1: wiring, R.PLTR / ETH / CBBTC tickers, 18 price sources, 18 eligible assets.
    function setupBatch() public {
        Deployment memory d = _deploymentFromEnv();
        Call[] memory calls = _setupCalls(d);
        _simulate(calls);
        _checkSetup(d);
        _write(
            "frontier-1-setup",
            "Frontier Fund 1, batch 1 of 4: platform wiring, R.PLTR / ETH / CBBTC verifier tickers, price sources and eligibility for the 18 basket tokens",
            calls
        );
    }

    /// @notice Batch 2: `createFund` for Frontier Fund 1. Starts the 15-day deposit window.
    function createFundBatch() external {
        Deployment memory d = _deploymentFromEnv();
        Call[] memory calls = _createFundCalls(d);
        _simulate(calls);
        _write(
            "frontier-1-create-fund",
            "Frontier Fund 1, batch 2 of 4: create the fund; its 15-day deposit window starts when this executes",
            calls
        );
    }

    /// @notice Batch 3: the fund token's hub feed and the launch-week rebalance cap.
    /// @param fund The fund `createFund` returned.
    function beforeCloseBatch(
        address fund
    ) external {
        Deployment memory d = _deploymentFromEnv();
        Call[] memory calls = _beforeCloseCalls(d, fund);
        _simulate(calls);
        require(FundOracle(d.oracle).feedOf(fund).aggregator == FundPriceHub(d.hub).feedOf(fund), "fund feed");
        _write(
            "frontier-1-before-close",
            "Frontier Fund 1, batch 3 of 4: the fund token's price feed (needed before seedPool) and a 50% daily rebalance cap for the launch rebalance",
            calls
        );
    }

    /// @notice Batch 4: the daily rebalance cap back to 10%.
    function afterLaunchWeekBatch() external {
        Deployment memory d = _deploymentFromEnv();
        Call[] memory calls = _afterLaunchWeekCalls(d);
        _simulate(calls);
        _write(
            "frontier-1-after-launch-week",
            "Frontier Fund 1, batch 4 of 4: daily rebalance cap back to 10% after the launch rebalance",
            calls
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Batches
    // ──────────────────────────────────────────────────────────

    function _basket(
        Deployment memory d
    ) internal pure returns (address[] memory assets, uint16[] memory weights) {
        assets = new address[](18);
        weights = new uint16[](18);
        (assets[0], weights[0]) = (NVDA, 900);
        (assets[1], weights[1]) = (SPCX, 800);
        (assets[2], weights[2]) = (PLTR, 700);
        (assets[3], weights[3]) = (META, 600);
        (assets[4], weights[4]) = (TSLA, 600);
        (assets[5], weights[5]) = (GOOGL, 500);
        (assets[6], weights[6]) = (LLY, 500);
        (assets[7], weights[7]) = (SKHY, 400);
        (assets[8], weights[8]) = (WETH, 900);
        (assets[9], weights[9]) = (CBBTC, 800);
        (assets[10], weights[10]) = (d.rhype, 600);
        (assets[11], weights[11]) = (d.rzec, 400);
        (assets[12], weights[12]) = (UNI, 300);
        (assets[13], weights[13]) = (PONS, 600);
        (assets[14], weights[14]) = (AI, 400);
        (assets[15], weights[15]) = (CASHCAT, 400);
        (assets[16], weights[16]) = (WSNET, 300);
        (assets[17], weights[17]) = (HOOKR, 300);
    }

    /// @dev Priced by the keeper through the hub: no Chainlink feed on Robinhood Chain (LLY, SKHY,
    ///      rZEC, rHYPE, UNI) or priced where they trade (the native tokens).
    function _hubAssets(
        Deployment memory d
    ) internal pure returns (address[] memory a) {
        a = new address[](10);
        (a[0], a[1], a[2], a[3], a[4]) = (LLY, SKHY, d.rzec, d.rhype, UNI);
        (a[5], a[6], a[7], a[8], a[9]) = (PONS, AI, CASHCAT, WSNET, HOOKR);
    }

    function _setupCalls(
        Deployment memory d
    ) internal returns (Call[] memory calls) {
        _mintZap = d.mintZap;
        _swapAdapter = d.swapAdapter;
        bytes[] memory wiring = _wiring(d.auctions, d.money);
        address[] memory hubAssets = _hubAssets(d);
        (address[] memory basket,) = _basket(d);

        calls = new Call[](wiring.length + 3 + 8 + 2 * hubAssets.length + basket.length);
        uint256 n;
        string[6] memory wiringLabels = [
            "factory.setAuctions(FundAuctions)",
            "factory.setPlatformMetadata(Own Curated Funds)",
            "factory.setBribeToken(USDG, true)",
            "factory.setMintZap(FundMintZap)",
            "factory.setRouter(FundSwapAdapter, true)",
            "factory.setBribeToken(MONEY, true)"
        ];
        for (uint256 i; i < wiring.length; ++i) {
            calls[n++] = Call(d.factory, wiring[i], wiringLabels[i]);
        }

        calls[n++] = _verifierConfig(
            "R.PLTR",
            FEED_PLTR,
            PLTR_MAX_ANCHOR_AGE,
            "verifier.setChainlinkConfig(R.PLTR, Chainlink PLTR/USD, same settings as R.NVDA)"
        );
        calls[n++] = _verifierConfig(
            "ETH",
            FEED_ETH,
            CRYPTO_MAX_ANCHOR_AGE,
            "verifier.setChainlinkConfig(ETH, Chainlink ETH/USD, R.NVDA settings, anchor at most 26h old)"
        );
        calls[n++] = _verifierConfig(
            "CBBTC",
            FEED_CBBTC,
            CRYPTO_MAX_ANCHOR_AGE,
            "verifier.setChainlinkConfig(CBBTC, Chainlink CBBTC/USD, R.NVDA settings, anchor at most 26h old)"
        );

        calls[n++] = _verifierFeed(d, NVDA, "R.NVDA");
        calls[n++] = _verifierFeed(d, SPCX, "R.SPCX");
        calls[n++] = _verifierFeed(d, PLTR, "R.PLTR");
        calls[n++] = _verifierFeed(d, META, "R.META");
        calls[n++] = _verifierFeed(d, TSLA, "R.TSLA");
        calls[n++] = _verifierFeed(d, GOOGL, "R.GOOGL");
        calls[n++] = _verifierFeed(d, WETH, "ETH");
        calls[n++] = _verifierFeed(d, CBBTC, "CBBTC");

        // A hub feed is a CREATE from the hub, so its address follows the hub's nonce; setFeed reads the
        // feed's decimals() and reverts the batch if a predicted address is wrong.
        uint64 hubNonce = vm.getNonce(d.hub);
        for (uint256 i; i < hubAssets.length; ++i) {
            address asset = hubAssets[i];
            require(FundPriceHub(d.hub).feedOf(asset) == address(0), "hub feed exists");
            address feed = vm.computeCreateAddress(d.hub, hubNonce + i);
            calls[n++] = Call(
                d.hub,
                abi.encodeCall(FundPriceHub.createFeed, (asset)),
                string.concat("hub.createFeed(", _sym(asset), ")")
            );
            calls[n++] = Call(
                d.oracle,
                abi.encodeCall(FundOracle.setFeed, (asset, feed, HUB_STALENESS)),
                string.concat("oracle.setFeed(", _sym(asset), ", hub feed ", vm.toString(feed), ", 2h)")
            );
        }

        for (uint256 i; i < basket.length; ++i) {
            calls[n++] = Call(
                d.factory,
                abi.encodeCall(FundFactory.setEligibleAsset, (basket[i], true)),
                string.concat("factory.setEligibleAsset(", _sym(basket[i]), ", true)")
            );
        }
        assert(n == calls.length);
    }

    function _createFundCalls(
        Deployment memory d
    ) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(
            d.factory,
            abi.encodeCall(FundFactory.createFund, (_fundParams(d))),
            "factory.createFund(Frontier Fund 1 / Fund1: 18 tokens, 15 days, $50k min, $100k target, 24/36/72% yield, 0.95% tax, Hookr 20%, LP 0.15%)"
        );
    }

    function _fundParams(
        Deployment memory d
    ) internal pure returns (CreateFundParams memory p) {
        p.name = "Frontier Fund 1";
        p.symbol = "Fund1";
        p.info.description =
            "AI, space, longevity and onchain money in one token. Curated by Own, always redeemable for what's inside.";
        p.info.website = "https://own.money";
        p.info.x = "https://x.com/owndotmoney";
        p.info.telegram = "https://t.me/owndotmoney";
        (p.assets, p.weightsBps) = _basket(d);
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
    }

    function _beforeCloseCalls(Deployment memory d, address fund) internal view returns (Call[] memory calls) {
        require(FundFactory(d.factory).isFund(fund), "not a fund");
        require(FundPriceHub(d.hub).feedOf(fund) == address(0), "hub feed exists");
        address feed = vm.computeCreateAddress(d.hub, vm.getNonce(d.hub));
        calls = new Call[](3);
        calls[0] = Call(d.hub, abi.encodeCall(FundPriceHub.createFeed, (fund)), "hub.createFeed(Fund1)");
        calls[1] = Call(
            d.oracle,
            abi.encodeCall(FundOracle.setFeed, (fund, feed, HUB_STALENESS)),
            string.concat("oracle.setFeed(Fund1, hub feed ", vm.toString(feed), ", 2h)")
        );
        calls[2] = Call(
            d.factory,
            abi.encodeCall(FundFactory.setRebalanceVolumeCap, (LAUNCH_WEEK_CAP_BPS)),
            "factory.setRebalanceVolumeCap(5000): 50% a day for the launch rebalance"
        );
    }

    function _afterLaunchWeekCalls(
        Deployment memory d
    ) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(
            d.factory,
            abi.encodeCall(FundFactory.setRebalanceVolumeCap, (NORMAL_CAP_BPS)),
            "factory.setRebalanceVolumeCap(1000): back to 10% a day"
        );
    }

    function _verifierConfig(
        string memory ticker,
        address feed,
        uint32 maxAnchorAge,
        string memory label
    ) internal view returns (Call memory) {
        return Call(
            IProtocolRegistry(REGISTRY).inhouseOracle(),
            abi.encodeCall(
                ChainlinkOracleVerifier.setChainlinkConfig,
                (
                    bytes32(bytes(ticker)),
                    feed,
                    address(0),
                    PLTR_CL_SILENCE,
                    PLTR_CL_FRESH_WINDOW,
                    maxAnchorAge,
                    PLTR_INHOUSE_MAX_STALENESS,
                    PLTR_BAND_BPS
                )
            ),
            label
        );
    }

    function _verifierFeed(
        Deployment memory d,
        address asset,
        string memory ticker
    ) internal pure returns (Call memory) {
        return Call(
            d.oracle,
            abi.encodeCall(FundOracle.setVerifierFeed, (asset, bytes32(bytes(ticker)), STOCK_STALENESS)),
            string.concat("oracle.setVerifierFeed(", ticker, ", 6h)")
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Checks, simulation, output
    // ──────────────────────────────────────────────────────────

    function _deploymentFromEnv() internal view returns (Deployment memory d) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        d = Deployment({
            oracle: vm.envAddress("FUND_ORACLE"),
            factory: vm.envAddress("FUND_FACTORY"),
            auctions: vm.envAddress("FUND_AUCTIONS"),
            hub: vm.envAddress("FUND_PRICE_HUB"),
            mintZap: vm.envAddress("FUND_MINT_ZAP"),
            swapAdapter: vm.envAddress("FUND_SWAP_ADAPTER"),
            money: vm.envOr("MONEY_TOKEN", address(0)),
            rzec: vm.envAddress("RZEC"),
            rhype: vm.envAddress("RHYPE")
        });
        _checkDeployment(d);
    }

    function _checkDeployment(
        Deployment memory d
    ) internal view {
        require(FundFactory(d.factory).oracle() == d.oracle, "factory oracle");
        require(FundFactory(d.factory).usdg() == USDG, "factory usdg");
        require(FundAuctions(d.auctions).factory() == d.factory, "auctions factory");
        require(FundPriceHub(d.hub).registry() == REGISTRY, "hub registry");
        require(FundPriceHub(d.hub).keeper() == KEEPER, "hub keeper");
        require(FundSwapAdapter(d.swapAdapter).universalRouter() == UNIVERSAL_ROUTER, "adapter router");
        require(d.mintZap.code.length > 0, "no mint zap");
        require(IERC20Metadata(d.rzec).decimals() == 8, "rZEC decimals");
        require(IERC20Metadata(d.rhype).decimals() == 18, "rHYPE decimals");
        require(IProtocolRegistry(REGISTRY).hasRole(keccak256("FUND_ADMIN"), SAFE), "Safe is not FUND_ADMIN");
    }

    function _checkSetup(
        Deployment memory d
    ) internal view {
        FundFactory factory = FundFactory(d.factory);
        require(factory.auctions() == d.auctions, "auctions");
        require(factory.mintZap() == d.mintZap, "mint zap");
        require(factory.isRouter(d.swapAdapter), "router");
        (address[] memory basket,) = _basket(d);
        for (uint256 i; i < basket.length; ++i) {
            require(factory.isEligibleAsset(basket[i]), "eligible");
            require(FundOracle(d.oracle).hasFeed(basket[i]), "feed");
        }
        // Hub feeds have no price until the keeper's first push. The rest should price now, but a
        // weekend's quiet stock feeds can be staler than 6h until the in-house signer quotes them.
        address[8] memory direct = [NVDA, SPCX, PLTR, META, TSLA, GOOGL, WETH, CBBTC];
        for (uint256 i; i < direct.length; ++i) {
            (bool ok,) = FundOracle(d.oracle).tryPrice(direct[i]);
            if (!ok) console.log("WARNING: no price yet for", _sym(direct[i]));
        }
    }

    function _simulate(
        Call[] memory calls
    ) internal {
        vm.startPrank(SAFE);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                vm.stopPrank();
                revert(string.concat("call ", vm.toString(i + 1), " failed: ", calls[i].label, " ", vm.toString(ret)));
            }
        }
        vm.stopPrank();
    }

    function _write(string memory name, string memory description, Call[] memory calls) internal {
        string memory txs;
        string memory list;
        for (uint256 i; i < calls.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '\n    {"to": "',
                vm.toString(calls[i].to),
                '", "value": "0", "data": "',
                vm.toString(calls[i].data),
                '"}'
            );
            list =
                string.concat(list, vm.toString(i + 1), ". `", calls[i].label, "` on ", vm.toString(calls[i].to), "\n");
        }
        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "4663",\n  "createdAt": ',
            vm.toString(vm.unixTime()),
            ',\n  "meta": {"name": "',
            name,
            '", "description": "',
            description,
            '", "createdFromSafeAddress": "',
            vm.toString(SAFE),
            '"},\n  "transactions": [',
            txs,
            "\n  ]\n}\n"
        );
        string memory md = string.concat(
            "# ",
            name,
            "\n\n",
            description,
            ".\n\nSafe ",
            vm.toString(SAFE),
            " on Robinhood Chain (4663). Simulated as the Safe at block ",
            vm.toString(block.number),
            ".\n\n",
            list
        );
        vm.createDir(OUT_DIR, true);
        vm.writeFile(string.concat(OUT_DIR, name, ".json"), json);
        vm.writeFile(string.concat(OUT_DIR, name, ".md"), md);
    }

    function _sym(
        address token
    ) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }
}
