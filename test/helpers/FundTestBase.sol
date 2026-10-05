// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {FundBribes} from "../../src/funds/FundBribes.sol";
import {FundCurators} from "../../src/funds/FundCurators.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundHook} from "../../src/funds/FundHook.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {IFundLaunch} from "../../src/interfaces/IFundLaunch.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {CreateFundParams, LockOption, YieldPoint} from "../../src/interfaces/types/FundTypes.sol";
import {Actors} from "./Actors.sol";
import {MockAggregatorV3} from "./MockAggregatorV3.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {PoolManagerBytecode} from "./v4/PoolManagerBytecode.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundTestBase — deploys the fund platform on a real Uniswap v4 PoolManager
abstract contract FundTestBase is Test {
    address internal admin = Actors.ADMIN;
    address internal protocolTreasury = Actors.FEE_RECIPIENT;
    address internal keeper = makeAddr("keeper");
    address internal curatorA = makeAddr("curatorA");
    address internal curatorB = makeAddr("curatorB");
    address internal launcher = makeAddr("launcher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = Actors.ATTACKER;

    IPoolManager internal poolManager;
    address internal positionManager;
    FundOracle internal oracle;
    FundFactory internal factory;
    FundHook internal hook;

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
        oracle = new FundOracle(admin);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        net = new MockERC20("NetNet", "NET", 9);
        pons = new MockERC20("Pons", "PONS", 18);
        tsla = new MockERC20("Tesla", "TSLA", 18);
        spare = new MockERC20("Spare", "SPARE", 18);

        _setFeed(address(net), 300e8);
        _setFeed(address(pons), 0.02e8);
        _setFeed(address(tsla), 400e8);
        _setFeed(address(spare), 1e8);

        FundFactory factoryImpl = new FundFactory();
        address[6] memory impls = [
            address(new Fund()),
            address(new FundLaunch()),
            address(new FundStaking(positionManager)),
            address(new FundGovernor()),
            address(new FundCurators()),
            address(new FundBribes())
        ];
        bytes memory init =
            abi.encodeCall(FundFactory.initialize, (admin, address(oracle), address(usdg), protocolTreasury, impls));
        factory = FundFactory(address(new ERC1967Proxy(address(factoryImpl), init)));

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address hookAddr = address((uint160(0x4444) << 144) | flags);
        deployCodeTo("FundHook.sol:FundHook", abi.encode(poolManager, factory), hookAddr);
        hook = FundHook(hookAddr);

        vm.startPrank(admin);
        factory.setHook(hookAddr);
        factory.setLauncher(launcher, true);
        vm.stopPrank();
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
        p.logoURI = "ipfs://ocf1-logo";
        p.description = "Robinhood Chain ecosystem tokens and stocks.";
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
        p.curatorFeeBps = 100;
        p.minCuratorStakeBps = 50;
        p.minRaiseUsd = 10_000e18;
        p.launchSupply = 130_000e18;
        p.launchDuration = 7 days;
        p.poolUsdgBps = 2000;
        p.lockOptions = new LockOption[](2);
        p.lockOptions[0] = LockOption({duration: 7 days, discountBps: 500});
        p.lockOptions[1] = LockOption({duration: 30 days, discountBps: 1000});
        p.yieldCurve = new YieldPoint[](3);
        p.yieldCurve[0] = YieldPoint({premiumBps: 1000, rateBpsPerDay: 10});
        p.yieldCurve[1] = YieldPoint({premiumBps: 5000, rateBpsPerDay: 20});
        p.yieldCurve[2] = YieldPoint({premiumBps: 10_000, rateBpsPerDay: 30});
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
    }

    /// @dev Creates the fund, takes $36k NET + $30k PONS + $34k TSLA + $25k USDG from alice and bob
    ///      one second before the close (negligible early yield), finalizes and seeds the pool. Raise
    ///      V = $125k and the pool share is 20%, so the USDG deposited is exactly the pool's P = $25k
    ///      and no rebalance is needed. Basket targets are 80% of the weights: TSLA is $4k over its
    ///      $30k target, so bob's credit loses 5% of that. Supply S = 130k: the pool gets
    ///      M = P * S / (1.3 * V + P) = ~17 333 tokens, depositors share ~112 667, NAV is
    ///      $125k / 112.67k = ~$1.1095 and the pool opens at 1.3x that.
    function _launchDefault() internal {
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
        vm.prank(keeper);
        launch.seedPool();
        _setFeed(address(fund), _navPrice() * 13 / 10);
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

    function _setFeed(address asset, int256 answer) internal {
        MockAggregatorV3 feed = feeds[asset];
        if (address(feed) == address(0)) {
            feed = new MockAggregatorV3(8);
            feeds[asset] = feed;
            vm.prank(admin);
            oracle.setFeed(asset, address(feed), STALENESS);
        }
        feed.setAnswer(answer, block.timestamp);
    }

    function _refreshFeeds() internal {
        address[4] memory list = [address(net), address(pons), address(tsla), address(spare)];
        for (uint256 i; i < list.length; ++i) {
            _setFeed(list[i], feeds[list[i]].answer());
        }
        if (address(fund) != address(0) && address(feeds[address(fund)]) != address(0)) {
            _setFeed(address(fund), feeds[address(fund)].answer());
        }
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
        PoolKey memory key = hook.poolKeyOf(address(fund));
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

    function _mintAsset(address who, MockERC20 asset, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(fund), amount);
    }
}
