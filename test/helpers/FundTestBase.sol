// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {FundBribes} from "../../src/funds/FundBribes.sol";
import {FundCurators} from "../../src/funds/FundCurators.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {FundVenue} from "../../src/funds/FundVenue.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {IFundLaunch} from "../../src/interfaces/IFundLaunch.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {IHookrLauncher} from "../../src/interfaces/external/IHookr.sol";

import {
    CreateFundParams,
    IssuanceConfig,
    IssuanceStep,
    LaunchConfig,
    PoolSettings,
    YieldPoint
} from "../../src/interfaces/types/FundTypes.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {Actors} from "./Actors.sol";
import {MockAggregatorV3} from "./MockAggregatorV3.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockHookr} from "./MockHookr.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {PoolManagerBytecode} from "./v4/PoolManagerBytecode.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundTestBase — deploys the fund platform on a real Uniswap v4 PoolManager
abstract contract FundTestBase is Test {
    address internal admin = Actors.ADMIN;
    address internal operator = makeAddr("operator");
    address internal protocolCurator = Actors.FEE_RECIPIENT;
    address internal keeper = makeAddr("keeper");
    address internal curatorA = makeAddr("curatorA");
    address internal curatorB = makeAddr("curatorB");
    address internal launcher = makeAddr("launcher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = Actors.ATTACKER;

    IPoolManager internal poolManager;
    address internal positionManager;
    ProtocolRegistry internal registry;
    FundOracle internal oracle;
    FundFactory internal factory;
    MockHookr internal hookr;
    FundVenue internal venue;

    MockERC20 internal usdg;
    MockERC20 internal net; // 9 decimals, $300
    MockERC20 internal pons; // 18 decimals, $0.02
    MockERC20 internal tsla; // 18 decimals, $400
    MockERC20 internal spare; // 18 decimals, $1, not in the basket

    mapping(address => MockAggregatorV3) internal feeds;

    Fund internal fund;
    FundLaunch internal launch;
    FundStaking internal staking;
    FundGovernor internal governor;
    FundCurators internal curators;
    FundBribes internal bribes;

    uint32 internal constant STALENESS = 1 days;

    function setUp() public virtual {
        vm.warp(1_000_000);

        poolManager = _deployPoolManager();
        positionManager = _deployPositionManager();
        registry = new ProtocolRegistry(admin, 2 days, 2 minutes);
        vm.startPrank(admin);
        registry.grantRole(keccak256("FUND_ADMIN"), admin);
        registry.grantRole(keccak256("FUND_OPERATOR"), operator);
        vm.stopPrank();
        oracle = new FundOracle(address(registry));

        usdg = _deployUsdg();
        net = new MockERC20("NetNet", "NET", 9);
        pons = new MockERC20("Pons", "PONS", 18);
        tsla = new MockERC20("Tesla", "TSLA", 18);
        spare = new MockERC20("Spare", "SPARE", 18);

        _setFeed(address(net), 300e8);
        _setFeed(address(pons), 0.02e8);
        _setFeed(address(tsla), 400e8);
        _setFeed(address(spare), 1e8);

        FundFactory factoryImpl = new FundFactory();
        address[7] memory impls = [
            address(new Fund(address(usdg))),
            address(new FundLaunch()),
            address(new FundStaking(positionManager)),
            address(new FundGovernor()),
            address(new FundCurators()),
            address(new FundBribes()),
            _deployVenue()
        ];
        bytes memory init = abi.encodeCall(
            FundFactory.initialize, (address(registry), address(oracle), address(usdg), protocolCurator, impls)
        );
        factory = FundFactory(address(new ERC1967Proxy(address(factoryImpl), init)));

        vm.startPrank(admin);
        factory.setLauncher(launcher, true);
        // Most tests use a 1.3x opening premium; launches open at NAV by default.
        LaunchConfig memory lc = factory.launchConfig();
        lc.launchPremiumBps = 3000;
        factory.setLaunchConfig(lc);
        vm.stopPrank();
    }

    function _deployUsdg() internal virtual returns (MockERC20) {
        return new MockERC20("Global Dollar", "USDG", 6);
    }

    /// @dev The venue implementation; by default on {MockHookr} over the test's pool manager.
    function _deployVenue() internal virtual returns (address) {
        hookr = new MockHookr(poolManager);
        return address(
            new FundVenue(
                IHookrLauncher(address(hookr)),
                makeAddr("hookrRoot"),
                makeAddr("hookrRules"),
                address(hookr),
                address(usdg)
            )
        );
    }

    function _deployPoolManager() internal virtual returns (IPoolManager) {
        return IPoolManager(PoolManagerBytecode.deploy(admin));
    }

    function _deployPositionManager() internal virtual returns (address) {
        return address(new MockPositionManager());
    }

    // ──────────────────────────────────────────────────────────
    //  Builders
    // ──────────────────────────────────────────────────────────

    function _defaultParams() internal view returns (CreateFundParams memory p) {
        p.name = "Own Curated Fund 1";
        p.symbol = "OCF1";
        p.info.logo = "ipfs://ocf1-logo";
        p.info.description = "Robinhood Chain ecosystem tokens and stocks.";
        p.info.x = "https://x.com/owndotmoney";
        p.info.telegram = "https://t.me/owndotmoney";
        p.assets = new address[](3);
        p.assets[0] = address(net);
        p.assets[1] = address(pons);
        p.assets[2] = address(tsla);
        p.weightsBps = new uint16[](3);
        p.weightsBps[0] = 4000;
        p.weightsBps[1] = 3000;
        p.weightsBps[2] = 3000;
        p.manager = keeper;
        p.curators = new address[](2);
        p.curators[0] = curatorA;
        p.curators[1] = curatorB;
        p.feeBps = 100;
        p.minCuratorStakeUsd = 1000e18;
        p.minRaiseUsd = 10_000e18;
        p.launchSupply = 130_000e18;
        p.launchDuration = 7 days;
        p.poolUsdgBps = 2000;
        p.yieldCurve = new YieldPoint[](3);
        p.yieldCurve[0] = YieldPoint({premiumBps: 1000, rateBpsPerYear: 3650});
        p.yieldCurve[1] = YieldPoint({premiumBps: 5000, rateBpsPerYear: 7300});
        p.yieldCurve[2] = YieldPoint({premiumBps: 10_000, rateBpsPerYear: 10_950});
        p.pool = PoolSettings({
            buyTaxPips: 10_500,
            sellTaxPips: 10_500,
            hookrShareBps: 2381,
            lpFeePips: 2000,
            tickSpacing: 60
        });
    }

    function _createFund() internal {
        _createFund(_defaultParams());
    }

    function _createFund(
        CreateFundParams memory p
    ) internal {
        vm.prank(admin);
        IFundFactory.FundModules memory m = factory.createFund(p);
        fund = Fund(m.fund);
        launch = FundLaunch(m.launch);
        staking = FundStaking(m.staking);
        governor = FundGovernor(m.governor);
        curators = FundCurators(m.curators);
        bribes = FundBribes(m.bribes);
        venue = FundVenue(m.venue);
        vm.prank(admin);
        governor.setPublicCuration(true);
    }

    /// @dev Creates the fund, takes $36k NET + $30k PONS + $34k TSLA + $25k USDG from alice and bob
    ///      one second before the close (negligible early yield), finalizes and seeds the pool. Raise
    ///      V = $125k and the pool share is 20%, so the USDG deposited is exactly the pool's P = $25k
    ///      and no rebalance is needed. Basket targets are 80% of the weights: TSLA is $4k over its
    ///      $30k target, so bob's credit loses 5% of that. Supply S = 130k: the pool gets
    ///      M = P * S / (1.3 * V + P) = ~17 333 tokens, depositors share ~112 667, NAV is
    ///      $125k / 112.67k = ~$1.1095 and the pool opens at 1.3x that.
    function _launchDefault() internal {
        _finalizeDefault();
        vm.prank(keeper);
        launch.seedPool();
        // The hub's first signed TWAP: the opening price.
        _setFundPrice(venue.spotPrice());
    }

    /// @dev {_launchDefault} up to the close, before the pool is seeded.
    function _finalizeDefault() internal {
        _createFund();
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(alice, address(net), 100e9); // $30k
        _deposit(alice, address(pons), 1_500_000e18); // $30k
        _deposit(alice, address(usdg), 15_000e6);
        _deposit(bob, address(net), 20e9); // $6k
        _deposit(bob, address(tsla), 85e18); // $34k
        _deposit(bob, address(usdg), 10_000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
    }

    /// @dev NAV in 8-decimal feed units.
    function _navPrice() internal view returns (int256) {
        return int256(fund.navPerShare() / 1e10);
    }

    function _deposit(address who, address asset, uint256 amount) internal returns (uint256 received) {
        MockERC20(asset).mint(who, amount);
        vm.startPrank(who);
        MockERC20(asset).approve(address(launch), amount);
        received = launch.deposit(asset, amount);
        vm.stopPrank();
    }

    /// @dev `answer` has 8 decimals. The fund token's feed has 18, like the price hub's, so it can
    ///      carry the pool price exactly.
    function _setFeed(address asset, int256 answer) internal {
        bool isFund = asset == address(fund);
        _feed(asset, isFund ? 18 : 8).setAnswer(isFund ? answer * 1e10 : answer, block.timestamp);
    }

    /// @dev Sets the fund token's oracle price, 18 decimals.
    function _setFundPrice(
        uint256 price
    ) internal {
        _feed(address(fund), 18).setAnswer(int256(price), block.timestamp);
    }

    /// @dev The fund token's oracle price, 18 decimals.
    function _fundPrice() internal view returns (uint256) {
        return uint256(feeds[address(fund)].answer());
    }

    function _feed(address asset, uint8 decimals) private returns (MockAggregatorV3 feed) {
        feed = feeds[asset];
        if (address(feed) == address(0)) {
            feed = new MockAggregatorV3(decimals);
            feeds[asset] = feed;
            vm.prank(admin);
            oracle.setFeed(asset, address(feed), STALENESS);
        }
    }

    function _refreshFeeds() internal {
        address[5] memory list = [address(net), address(pons), address(tsla), address(spare), address(fund)];
        for (uint256 i; i < list.length; ++i) {
            MockAggregatorV3 feed = feeds[list[i]];
            if (list[i] != address(0) && address(feed) != address(0)) feed.setAnswer(feed.answer(), block.timestamp);
        }
    }

    /// @dev Turns pool issuance off, for tests of the pool's own fees and liquidity.
    function _noIssuance() internal {
        vm.prank(admin);
        venue.setIssuance(
            IssuanceConfig({startBps: 100, potShareBps: 7500, hourlyCapBps: 500, steps: new IssuanceStep[](0)})
        );
    }

    /// @dev Moves past the depositor lock and refreshes every feed.
    function _passDepositorLock() internal {
        vm.warp(fund.depositorUnlockAt());
        _refreshFeeds();
    }

    PoolSwapTest private _swapRouter;

    /// @dev Swaps in the fund's pool as `who`, minting whatever it pays.
    /// @param buy             True to swap USDG for fund tokens.
    /// @param amountSpecified Negative for exact input, positive for exact output (v4 convention).
    function _poolSwap(address who, bool buy, int256 amountSpecified) internal returns (BalanceDelta delta) {
        if (address(_swapRouter) == address(0)) _swapRouter = new PoolSwapTest(poolManager);
        PoolKey memory key = venue.poolKey();
        bool usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        bool zeroForOne = buy == usdgIs0;
        usdg.mint(who, 1e30);
        vm.startPrank(who);
        usdg.approve(address(_swapRouter), type(uint256).max);
        fund.approve(address(_swapRouter), type(uint256).max);
        delta = _swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        int128 usdgDelta = usdgIs0 ? delta.amount0() : delta.amount1();
        _bookTax(buy, uint256(int256(usdgDelta < 0 ? -usdgDelta : usdgDelta)));
    }

    /// @dev Stands in for Hookr's Directional Tax on a swap moving `usdgAmount`: books the creator
    ///      share of the tax in that direction's queue, and has the venue pay it out.
    function _bookTax(bool buy, uint256 usdgAmount) internal {
        // Hookr's live pools take the tax themselves.
        if (address(hookr) == address(0)) return;
        PoolSettings memory s = venue.poolSettings();
        (address buyQueue, address sellQueue) = venue.taxQueues();
        address queue = buy ? buyQueue : sellQueue;
        if (queue == address(0)) return;
        uint256 tax = usdgAmount * (buy ? s.buyTaxPips : s.sellTaxPips) / 1e6;
        usdg.mint(queue, tax - tax * s.hookrShareBps / 10_000);
        venue.collectTax();
    }

    // ──────────────────────────────────────────────────────────
    //  Governance
    // ──────────────────────────────────────────────────────────

    function _escrow(address who, uint256 shares) internal {
        vm.startPrank(who);
        staking.approve(address(governor), shares);
        governor.deposit(address(staking), shares);
        vm.stopPrank();
    }

    /// @dev Buys fund tokens in the pool with `usdgIn`, stakes them and escrows the shares.
    function _stakeAndEscrow(address who, uint256 usdgIn) internal {
        _poolSwap(who, true, -int256(usdgIn));
        uint256 bal = fund.balanceOf(who);
        vm.startPrank(who);
        fund.approve(address(staking), bal);
        uint256 shares = staking.stake(bal, who);
        staking.approve(address(governor), shares);
        governor.deposit(address(staking), shares);
        vm.stopPrank();
    }

    function _voteAll(address who, address token) internal {
        address[] memory t = new address[](1);
        uint16[] memory w = new uint16[](1);
        t[0] = token;
        w[0] = 10_000;
        vm.prank(who);
        governor.vote(t, w);
    }

    function _toNextEpoch() internal {
        vm.warp((governor.currentEpoch() + 1) * 1 weeks);
        _refreshFeeds();
    }

    /// @dev Gives `who` the slice a mint of `navShares` needs and approves the fund for it.
    function _fundSlice(address who, uint256 navShares) internal returns (uint256[] memory amounts) {
        uint256 usdgAmount;
        (,, amounts, usdgAmount,) = fund.previewMint(navShares, false);
        address[] memory a = fund.assets();
        for (uint256 i; i < a.length; ++i) {
            _mintAsset(who, MockERC20(a[i]), amounts[i]);
        }
        _mintAsset(who, usdg, usdgAmount);
    }

    /// @dev Direct mint as `who`; returns the fund tokens staked for it.
    function _mintAs(address who, uint256 navShares) internal returns (uint256 shares) {
        _fundSlice(who, navShares);
        vm.prank(who);
        shares = fund.mint(navShares, 0, who, false);
    }

    function _mintAsset(address who, MockERC20 asset, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(fund), amount);
    }
}
