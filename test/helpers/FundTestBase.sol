// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundHook} from "../../src/funds/FundHook.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundLaunch} from "../../src/interfaces/IFundLaunch.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {CreateFundParams, LockOption, YieldTier} from "../../src/interfaces/types/FundTypes.sol";
import {Actors} from "./Actors.sol";
import {MockAggregatorV3} from "./MockAggregatorV3.sol";
import {MockERC20} from "./MockERC20.sol";
import {PoolManagerBytecode} from "./v4/PoolManagerBytecode.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title FundTestBase — deploys the fund platform on a real Uniswap v4 PoolManager
abstract contract FundTestBase is Test {
    address internal admin = Actors.ADMIN;
    address internal protocolTreasury = Actors.FEE_RECIPIENT;
    address internal lpTreasury = makeAddr("lpTreasury");
    address internal creator = makeAddr("creator");
    address internal creatorTreasury = makeAddr("creatorTreasury");
    address internal launcher = makeAddr("launcher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = Actors.ATTACKER;

    IPoolManager internal poolManager;
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

    uint32 internal constant STALENESS = 1 days;

    function setUp() public virtual {
        vm.warp(1_000_000);

        poolManager = IPoolManager(PoolManagerBytecode.deploy(admin));
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
        bytes memory init = abi.encodeCall(
            FundFactory.initialize,
            (
                admin,
                address(oracle),
                address(usdg),
                protocolTreasury,
                lpTreasury,
                address(new Fund()),
                address(new FundLaunch()),
                address(new FundStaking()),
                address(new FundGovernor())
            )
        );
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

    // ──────────────────────────────────────────────────────────
    //  Builders
    // ──────────────────────────────────────────────────────────

    function _defaultParams() internal view returns (CreateFundParams memory p) {
        p.name = "MONEY Market Fund 1";
        p.symbol = "MF1";
        p.logoURI = "ipfs://mf1-logo";
        p.description = "Robinhood Chain ecosystem tokens and stocks.";
        p.assets = new address[](3);
        p.assets[0] = address(net);
        p.assets[1] = address(pons);
        p.assets[2] = address(tsla);
        p.weightsBps = new uint16[](3);
        p.weightsBps[0] = 4000;
        p.weightsBps[1] = 3000;
        p.weightsBps[2] = 3000;
        p.manager = creator;
        p.creatorFeeRecipient = creatorTreasury;
        p.creatorFeeBps = 100;
        p.minGraduationUsd = 10_000e18;
        p.lockOptions = new LockOption[](2);
        p.lockOptions[0] = LockOption({duration: 7 days, discountBps: 500});
        p.lockOptions[1] = LockOption({duration: 30 days, discountBps: 1000});
        p.yieldTiers = new YieldTier[](3);
        p.yieldTiers[0] = YieldTier({minPremiumBps: 1000, rateBpsPerDay: 10});
        p.yieldTiers[1] = YieldTier({minPremiumBps: 5000, rateBpsPerDay: 20});
        p.yieldTiers[2] = YieldTier({minPremiumBps: 10_000, rateBpsPerDay: 30});
    }

    function _createFund() internal {
        _createFund(_defaultParams());
    }

    function _createFund(
        CreateFundParams memory p
    ) internal {
        vm.prank(launcher);
        (address f, address l, address s, address g) = factory.createFund(p);
        fund = Fund(f);
        launch = FundLaunch(l);
        staking = FundStaking(s);
        governor = FundGovernor(g);
    }

    /// @dev Creates the fund, takes $36k NET + $30k PONS + $34k TSLA from alice and bob, and
    ///      finalizes. Basket $100k, USDG $30k: depositors get 100k MF1, the pool gets 30k MF1 and
    ///      opens at $1.00 with NAV at 100/130.
    function _launchDefault() internal {
        _createFund();
        _deposit(alice, address(net), 100e9); // $30k
        _deposit(alice, address(pons), 1_500_000e18); // $30k
        _deposit(bob, address(net), 20e9); // $6k
        _deposit(bob, address(tsla), 85e18); // $34k
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
        _setFeed(address(fund), 1e8);
    }

    function _deposit(
        address who,
        address asset,
        uint256 amount
    ) internal returns (uint256 usdgPaid) {
        MockERC20(asset).mint(who, amount);
        usdg.mint(who, 1e30);
        vm.startPrank(who);
        MockERC20(asset).approve(address(launch), amount);
        usdg.approve(address(launch), type(uint256).max);
        usdgPaid = launch.deposit(asset, amount);
        vm.stopPrank();
    }

    function _setFeed(
        address asset,
        int256 answer
    ) internal {
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

    function _mintAsset(
        address who,
        MockERC20 asset,
        uint256 amount
    ) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(fund), amount);
    }
}
