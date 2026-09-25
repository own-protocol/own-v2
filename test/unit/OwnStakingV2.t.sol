// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnStakingV2} from "../../src/interfaces/IOwnStakingV2.sol";
import {ITieredBoostCalculator} from "../../src/interfaces/ITieredBoostCalculator.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {LinearBoostCalculator} from "../../src/staking/LinearBoostCalculator.sol";
import {OwnStakingV2} from "../../src/staking/OwnStakingV2.sol";
import {TieredBoostCalculator} from "../../src/staking/TieredBoostCalculator.sol";

import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract RevertingCalculator {
    function boostBps(uint256, uint256) external pure returns (uint256) {
        revert("broken");
    }
}

contract OwnStakingV2Test is Test {
    ProtocolRegistry internal registry;
    MockOracleVerifier internal oracle;
    OwnStakingV2 internal staking;
    MockERC20 internal eusd;
    MockERC20 internal money;
    MockERC20 internal spy;

    address internal admin = Actors.ADMIN;
    address internal operator = address(uint160(uint256(keccak256("operator"))));
    address internal safe = address(uint160(uint256(keccak256("safe"))));
    address internal alice = Actors.MINTER1;
    address internal bob = Actors.MINTER2;
    address internal attacker = Actors.ATTACKER;

    bytes32 internal constant MONEY_TICKER = bytes32("MONEY");
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant MONEY_PRICE = 0.002e18; // $0.002 per $MONEY
    uint256 internal constant PRICE_SCALE = 1e18;

    function setUp() public {
        vm.warp(1_000_000);

        registry = new ProtocolRegistry(admin, 2 days, 300);
        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), operator);
        vm.stopPrank();

        oracle = new MockOracleVerifier();
        vm.prank(admin);
        registry.setAddress(keccak256("INHOUSE_ORACLE"), address(oracle));
        oracle.setPrice(MONEY_TICKER, MONEY_PRICE);

        eusd = new MockERC20("Own eUSD", "eUSD", 18);
        money = new MockERC20("Money", "MONEY", 18);
        spy = new MockERC20("Robinhood SPY", "R.SPY", 18);

        staking = _deploy(_defaultCalc());

        // Reward source: the Safe holds SPY and grants the weekly allowance.
        spy.mint(safe, 1_000_000e18);
        vm.prank(safe);
        spy.approve(address(staking), type(uint256).max);

        address[3] memory users = [alice, bob, attacker];
        for (uint256 i; i < users.length; i++) {
            eusd.mint(users[i], 10_000_000e18);
            money.mint(users[i], 1e12 * 1e18);
            vm.startPrank(users[i]);
            eusd.approve(address(staking), type(uint256).max);
            money.approve(address(staking), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Launch calculator: 0.1x floor rising linearly to 3.6x at 3:1 coverage.
    function _defaultCalc() internal returns (address) {
        return address(new LinearBoostCalculator(1000, 36_000, 30_000));
    }

    function _deploy(
        address calc
    ) internal returns (OwnStakingV2) {
        OwnStakingV2 impl = new OwnStakingV2();
        return OwnStakingV2(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        OwnStakingV2.initialize,
                        (address(registry), address(eusd), address(money), address(spy), safe, calc)
                    )
                )
            )
        );
    }

    /// @dev $MONEY units (18 dec) whose oracle value equals `usd` whole dollars of eUSD.
    function _moneyFor(
        uint256 usd
    ) internal pure returns (uint256) {
        return usd * 1e18 * PRICE_SCALE / MONEY_PRICE;
    }

    function _stake(address user, uint256 moneyAmt, uint256 eusdAmt) internal {
        vm.prank(user);
        staking.stake(moneyAmt, eusdAmt);
    }

    function _notify(
        uint256 amount
    ) internal {
        vm.prank(operator);
        staking.notifyRewardAmount(amount);
    }

    /// @dev Register a zap address holding approved eUSD/$MONEY for the on-behalf surfaces.
    function _fundedZap() internal returns (address zapAddr) {
        zapAddr = address(uint160(uint256(keccak256("zap"))));
        vm.prank(admin);
        staking.setZap(zapAddr);
        eusd.mint(zapAddr, 1_000_000e18);
        money.mint(zapAddr, 1_000_000_000e18);
        vm.startPrank(zapAddr);
        eusd.approve(address(staking), type(uint256).max);
        money.approve(address(staking), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────────────────

    function test_initialize_state() public view {
        assertEq(address(staking.registry()), address(registry));
        assertEq(staking.rewardSource(), safe);
        assertEq(staking.rewardsDuration(), 7 days);
        assertEq(staking.priceMaxAge(), 24 hours);
        assertEq(staking.maxBoostBps(), 36_000);
        assertEq(staking.stakeCap(), 0);
        assertTrue(address(staking.boostCalculator()) != address(0));
        assertEq(staking.totalWeight(), 0);
    }

    function test_initialize_zeroAddress_reverts() public {
        OwnStakingV2 impl = new OwnStakingV2();
        address calc = _defaultCalc();
        vm.expectRevert(IOwnStakingV2.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                OwnStakingV2.initialize, (address(0), address(eusd), address(money), address(spy), safe, calc)
            )
        );
    }

    function test_initialize_zeroCalculator_reverts() public {
        OwnStakingV2 impl = new OwnStakingV2();
        vm.expectRevert(IOwnStakingV2.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                OwnStakingV2.initialize,
                (address(registry), address(eusd), address(money), address(spy), safe, address(0))
            )
        );
    }

    function test_initialize_twice_reverts() public {
        address calc = _defaultCalc();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        staking.initialize(address(registry), address(eusd), address(money), address(spy), safe, calc);
    }

    // ──────────────────────────────────────────────────────────
    //  Boost calculator
    // ──────────────────────────────────────────────────────────

    function test_boost_eusdOnly_floor() public {
        _stake(alice, 0, 1000e18);
        assertEq(staking.boostBps(alice), 1000);
        assertEq(staking.totalWeight(), 100e18); // 1000 x 0.1
    }

    function test_boost_alongLine() public {
        _stake(alice, _moneyFor(1000), 1000e18); // 1:1
        assertEq(staking.boostBps(alice), 12_666);

        _stake(bob, _moneyFor(3000), 1000e18); // 3:1
        assertEq(staking.boostBps(bob), 36_000);
        assertEq(staking.totalWeight(), 1266.6e18 + 3600e18);
    }

    function test_boost_interpolates() public {
        // 0.5:1: 0.1x + 3.5x/6 = 0.6833x.
        _stake(alice, _moneyFor(500), 1000e18);
        assertEq(staking.boostBps(alice), 6833);

        // 1.5:1: 0.1x + 3.5x/2 = 1.85x.
        _stake(bob, _moneyFor(1500), 1000e18);
        assertEq(staking.boostBps(bob), 18_500);
    }

    function test_boost_beyondMaxCoverage_clamps() public {
        _stake(alice, _moneyFor(6000), 1000e18); // 6:1
        assertEq(staking.boostBps(alice), 36_000);
    }

    function test_boost_moneyOnly_zeroWeight() public {
        _stake(alice, _moneyFor(1000), 0);
        assertEq(staking.boostBps(alice), 0);
        assertEq(staking.totalWeight(), 0);
    }

    // Regression (A5-M-03): new $MONEY is never valued at a dead mark — the stake reverts;
    // eUSD-only stakes need no price and still work.

    function test_stakeMoney_staleOracle_reverts() public {
        oracle.setForceStale(true);
        vm.expectRevert(IOwnStakingV2.StaleMoneyPrice.selector);
        vm.prank(alice);
        staking.stake(_moneyFor(3000), 1000e18);

        _stake(alice, 0, 1000e18); // eUSD-only entry stays open
        assertEq(staking.boostBps(alice), 1000);
        assertEq(staking.moneyPrice(), 0);
    }

    function test_stakeMoney_zeroPrice_reverts() public {
        oracle.setForceZeroPrice(true);
        vm.expectRevert(IOwnStakingV2.StaleMoneyPrice.selector);
        vm.prank(alice);
        staking.stake(_moneyFor(3000), 1000e18);
    }

    function test_stakeMoney_agedPrice_reverts() public {
        oracle.setPrice(MONEY_TICKER, MONEY_PRICE, block.timestamp - 25 hours);
        vm.expectRevert(IOwnStakingV2.StaleMoneyPrice.selector);
        vm.prank(alice);
        staking.stake(_moneyFor(3000), 1000e18);
    }

    function test_stakeMoney_outage_cachedMarkNeverPricesEntry() public {
        // The cached mark keeps serving existing positions, yet cannot price new $MONEY.
        _stake(alice, _moneyFor(3000), 1000e18); // caches the live mark
        oracle.setForceStale(true);
        assertEq(staking.moneyPrice(), MONEY_PRICE, "cache serves views");
        vm.expectRevert(IOwnStakingV2.StaleMoneyPrice.selector);
        vm.prank(bob);
        staking.stake(_moneyFor(3000), 1000e18);
    }

    // Regression (A5-M-03 residual): eUSD onto a $MONEY-holding position is price-gated like
    // new $MONEY; money-free additions and every exit stay price-free.

    function test_stakeEusd_onMoneyPosition_staleOracle_reverts() public {
        _stake(alice, _moneyFor(3000), 1000e18);
        oracle.setForceStale(true);
        vm.expectRevert(IOwnStakingV2.StaleMoneyPrice.selector);
        vm.prank(alice);
        staking.stake(0, 500e18);

        oracle.setForceStale(false);
        _stake(alice, 0, 500e18); // live mark again — addition reprices normally
        assertEq(staking.boostBps(alice), 24_333); // 3000:1500 = 2:1 -> 2.4333x
    }

    function test_stakeEusd_moneyFreePosition_outage_staysOpen() public {
        _stake(bob, 0, 1000e18);
        oracle.setForceStale(true);
        _stake(bob, 0, 500e18); // no $MONEY leg — nothing to misprice
        assertEq(staking.boostBps(bob), 1000);
    }

    function test_outage_exitsNeverGated() public {
        _stake(alice, _moneyFor(3000), 1000e18);
        oracle.setForceStale(true);
        vm.prank(alice);
        staking.unstake(_moneyFor(1000), 400e18); // partial exit reprices at the cached mark
        vm.prank(alice);
        staking.exit(); // full exit reads no price
        assertEq(staking.totalWeight(), 0);
    }

    function test_previewBoost_matchesStake() public {
        assertEq(staking.previewBoost(_moneyFor(1500), 1000e18), 18_500);
        _stake(alice, _moneyFor(1500), 1000e18);
        assertEq(staking.boostBps(alice), staking.previewBoost(_moneyFor(1500), 1000e18));
    }

    // ──────────────────────────────────────────────────────────
    //  Weight monotonicity (A5-H-01 regressions)
    // ──────────────────────────────────────────────────────────

    function test_moreEusd_neverWeighsLess() public {
        _stake(alice, _moneyFor(3000), 1000e18); // 3:1 -> 3.6x -> weight 3600
        uint256 aliceWeight = staking.totalWeight();
        _stake(bob, _moneyFor(3000), 1500e18); // 2:1 -> 2.4x -> weight 3600
        assertGe(staking.totalWeight() - aliceWeight, aliceWeight, "more eUSD weighed less");
    }

    function test_unstakeEusd_neverRaisesWeight() public {
        _stake(alice, _moneyFor(3000), 1500e18);
        uint256 before = staking.totalWeight();
        vm.prank(alice);
        staking.unstake(0, 500e18); // coverage rises 2:1 -> 3:1, weight must not
        assertLe(staking.totalWeight(), before, "withdrawing principal raised weight");
    }

    function test_stakeForGift_neverLowersVictimWeight() public {
        address zapAddr = _fundedZap();
        _stake(alice, _moneyFor(3000), 1000e18);
        uint256 before = staking.totalWeight();
        vm.prank(zapAddr);
        staking.stakeFor(alice, 0, 500e18); // dilutes alice's coverage 3:1 -> 2:1
        assertGe(staking.totalWeight(), before, "gift cut the victim's weight");
    }

    // ──────────────────────────────────────────────────────────
    //  Stake / unstake
    // ──────────────────────────────────────────────────────────

    function test_stake_pullsBothLegs() public {
        uint256 m = _moneyFor(1000);
        vm.expectEmit(true, false, false, true);
        emit IOwnStakingV2.Staked(alice, m, 1000e18, 12_666);
        _stake(alice, m, 1000e18);

        assertEq(money.balanceOf(address(staking)), m);
        assertEq(eusd.balanceOf(address(staking)), 1000e18);
        assertEq(staking.totalMoneyStaked(), m);
        assertEq(staking.totalEusdStaked(), 1000e18);
    }

    function test_stake_zeroBoth_reverts() public {
        vm.expectRevert(IOwnStakingV2.ZeroAmount.selector);
        vm.prank(alice);
        staking.stake(0, 0);
    }

    function test_stake_capExceeded_reverts() public {
        vm.prank(admin);
        staking.setStakeCap(1000e18);

        _stake(alice, 0, 600e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnStakingV2.StakeCapExceeded.selector, 1100e18, 1000e18));
        vm.prank(bob);
        staking.stake(0, 500e18);

        // Money leg is never capped.
        _stake(bob, _moneyFor(1000), 400e18);
    }

    function test_unstake_partial_resnapshotsBoost() public {
        _stake(alice, _moneyFor(1000), 1000e18); // 1:1 -> 1.2666x
        vm.prank(alice);
        staking.unstake(0, 500e18); // now 2:1 -> 2.4333x
        assertEq(staking.boostBps(alice), 24_333);
        assertEq(staking.totalWeight(), 1216.65e18);
    }

    function test_unstake_insufficient_reverts() public {
        _stake(alice, 0, 100e18);
        vm.expectRevert(IOwnStakingV2.InsufficientStake.selector);
        vm.prank(alice);
        staking.unstake(0, 101e18);
    }

    function test_unstake_zeroBoth_reverts() public {
        _stake(alice, 0, 100e18);
        vm.expectRevert(IOwnStakingV2.ZeroAmount.selector);
        vm.prank(alice);
        staking.unstake(0, 0);
    }

    function test_fullExit_worksWithDeadOracle() public {
        _stake(alice, _moneyFor(3000), 1000e18);
        _notify(700e18);
        vm.warp(block.timestamp + 1 days);

        oracle.setForceStale(true);
        uint256 mBefore = money.balanceOf(alice);
        uint256 eBefore = eusd.balanceOf(alice);
        vm.prank(alice);
        staking.exit();

        assertEq(money.balanceOf(alice) - mBefore, _moneyFor(3000));
        assertEq(eusd.balanceOf(alice) - eBefore, 1000e18);
        assertGt(spy.balanceOf(alice), 0, "rewards paid on exit");
        assertEq(staking.totalWeight(), 0);
        assertEq(staking.earned(alice), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Reward stream
    // ──────────────────────────────────────────────────────────

    function test_notify_pullsFromRewardSource() public {
        _stake(alice, 0, 1000e18);
        uint256 safeBefore = spy.balanceOf(safe);
        _notify(700e18);
        assertEq(safeBefore - spy.balanceOf(safe), 700e18);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
    }

    function test_notify_boundedByAllowance() public {
        vm.prank(safe);
        spy.approve(address(staking), 100e18);
        vm.expectRevert();
        vm.prank(operator);
        staking.notifyRewardAmount(101e18);
    }

    function test_notify_zero_reverts() public {
        vm.expectRevert(IOwnStakingV2.ZeroAmount.selector);
        vm.prank(operator);
        staking.notifyRewardAmount(0);
    }

    function test_rewards_streamLinearly() public {
        _stake(alice, 0, 1000e18);
        _notify(700e18);

        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(staking.earned(alice), 100e18, 1e12, "1/7 after one day");

        vm.warp(block.timestamp + 6 days);
        assertApproxEqRel(staking.earned(alice), 700e18, 1e12, "all after seven days");

        // Stream ended: nothing more accrues.
        vm.warp(block.timestamp + 3 days);
        assertApproxEqRel(staking.earned(alice), 700e18, 1e12, "flat after finish");
    }

    function test_rewards_splitByWeight() public {
        _stake(alice, 0, 1000e18); // 0.1x -> weight 100
        _stake(bob, _moneyFor(3000), 1000e18); // 3.6x -> weight 3600
        _notify(370e18);
        vm.warp(block.timestamp + DURATION);

        // 36:1 split of the whole stream.
        assertApproxEqRel(staking.earned(alice), 10e18, 1e12);
        assertApproxEqRel(staking.earned(bob), 360e18, 1e12);
    }

    function test_notify_midStream_foldsRemainder() public {
        _stake(alice, 0, 1000e18);
        _notify(700e18);
        vm.warp(block.timestamp + 3.5 days); // half streamed

        _notify(350e18); // remainder 350 + 350 re-vest over a fresh window
        uint256 expectedRate = 700e18 * 1e18 / DURATION;
        assertApproxEqRel(staking.rewardRate(), expectedRate, 1e12, "rate holds");

        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(staking.earned(alice), 1050e18, 1e12, "nothing lost in the fold");
    }

    function test_claim_paysAndResets() public {
        _stake(alice, 0, 1000e18);
        _notify(700e18);
        vm.warp(block.timestamp + DURATION);

        uint256 owed = staking.earned(alice);
        vm.prank(alice);
        uint256 paid = staking.claim(alice);
        assertEq(paid, owed);
        assertEq(spy.balanceOf(alice), owed);
        assertEq(staking.earned(alice), 0);

        vm.prank(alice);
        assertEq(staking.claim(alice), 0, "second claim pays nothing");
    }

    function test_claim_zeroRecipient_reverts() public {
        vm.expectRevert(IOwnStakingV2.ZeroAddress.selector);
        vm.prank(alice);
        staking.claim(address(0));
    }

    function test_zeroWeightStretch_accruesUndistributed() public {
        _notify(700e18); // nobody staked
        vm.warp(block.timestamp + 1 days);
        _stake(alice, 0, 1000e18); // settles the zero-weight day into the bucket

        vm.warp(block.timestamp + 6 days);
        assertApproxEqRel(staking.earned(alice), 600e18, 1e12, "only the staked stretch");
        assertApproxEqRel(staking.undistributed(), 100e18, 1e12, "day one banked");

        vm.prank(operator);
        uint256 amount = staking.renotifyUndistributed();
        assertApproxEqRel(amount, 100e18, 1e12);
        assertEq(staking.undistributed(), 0);

        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(staking.earned(alice), 700e18, 1e12, "bucket re-streamed");
    }

    function test_renotify_empty_reverts() public {
        vm.expectRevert(IOwnStakingV2.NoUndistributed.selector);
        vm.prank(operator);
        staking.renotifyUndistributed();
    }

    function test_syncRewards_booksDonationsToUndistributed() public {
        _stake(alice, 0, 1000e18);
        spy.mint(address(staking), 70e18); // direct transfer, e.g. rerouted fees

        uint256 synced = staking.syncRewards();
        assertEq(synced, 70e18);
        assertEq(staking.undistributed(), 70e18, "booked, not streamed");
        assertEq(staking.rewardRate(), 0, "sync alone starts no stream");

        vm.prank(operator);
        staking.renotifyUndistributed();
        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(staking.earned(alice), 70e18, 1e12);
    }

    function test_syncRewards_dustCannotResetStreamWindow() public {
        // Regression (A5-M-01): a 1-wei donation + sync must not touch the live schedule.
        _stake(alice, 0, 1000e18);
        _notify(700e18);
        uint256 rateBefore = staking.rewardRate();
        uint256 finishBefore = staking.periodFinish();

        vm.warp(block.timestamp + 6 days);
        spy.mint(address(staking), 1);
        staking.syncRewards();

        assertEq(staking.rewardRate(), rateBefore, "rate untouched");
        assertEq(staking.periodFinish(), finishBefore, "finish untouched");
        assertEq(staking.undistributed(), 1, "dust parked in bucket");

        vm.warp(finishBefore);
        assertApproxEqRel(staking.earned(alice), 700e18, 1e12, "full batch on schedule");
    }

    function test_syncRewards_nothing_reverts() public {
        _stake(alice, 0, 1000e18);
        _notify(700e18);
        vm.expectRevert(IOwnStakingV2.NothingToSync.selector);
        staking.syncRewards();
    }

    function test_syncRewards_ignoresAccountedStream() public {
        // Mid-stream and with unclaimed rewards, the accounted balance is not a surplus.
        _stake(alice, 0, 1000e18);
        _notify(700e18);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(IOwnStakingV2.NothingToSync.selector);
        staking.syncRewards();
    }

    // ──────────────────────────────────────────────────────────
    //  Boost refresh
    // ──────────────────────────────────────────────────────────

    function test_refreshBoost_priceDrop_settlesOldWeightFirst() public {
        _stake(alice, _moneyFor(3000), 1000e18); // 3.6x
        _notify(700e18);
        vm.warp(block.timestamp + 1 days);

        // Price halves: coverage 3:1 -> 1.5:1, boost 3.6x -> 1.85x after refresh.
        oracle.setPrice(MONEY_TICKER, MONEY_PRICE / 2);
        uint256 earnedAtOldWeight = staking.earned(alice);

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(attacker); // permissionless
        staking.refreshBoost(users);

        assertEq(staking.boostBps(alice), 18_500);
        assertApproxEqRel(staking.earned(alice), earnedAtOldWeight, 1e12, "day one earned at old weight");
        assertEq(staking.totalWeight(), 1850e18);
    }

    function test_refreshBoost_oracleOutage_keepsLastMark() public {
        // Regression (A5-L-01): an outage repricing uses the last usable mark, never the floor.
        _stake(alice, _moneyFor(3000), 1000e18); // 3.6x, caches the mark
        assertEq(staking.lastMoneyPrice(), MONEY_PRICE);

        oracle.setForceStale(true);
        assertEq(staking.moneyPrice(), MONEY_PRICE, "view falls back to cache");

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(attacker); // permissionless
        staking.refreshBoost(users);

        assertEq(staking.boostBps(alice), 36_000, "outage cannot floor an existing snapshot");
        assertEq(staking.totalWeight(), 3600e18);
    }

    function test_lastMark_tracksLatestUsablePrice() public {
        _stake(alice, _moneyFor(3000), 1000e18);
        oracle.setPrice(MONEY_TICKER, MONEY_PRICE / 2);
        _stake(bob, 0, 1e18); // any touch refreshes the cache
        assertEq(staking.lastMoneyPrice(), MONEY_PRICE / 2);

        // Outage: alice reprices at the halved cached mark (coverage 1.5:1 -> 1.85x), not the floor.
        oracle.setForceStale(true);
        address[] memory users = new address[](1);
        users[0] = alice;
        staking.refreshBoost(users);
        assertEq(staking.boostBps(alice), 18_500);
    }

    function test_refreshBoost_priceRecovery_raisesBoost() public {
        _stake(alice, _moneyFor(3000), 1000e18); // 3:1 -> 3.6x at the live mark
        oracle.setPrice(MONEY_TICKER, MONEY_PRICE / 2);

        address[] memory users = new address[](1);
        users[0] = alice;
        staking.refreshBoost(users);
        assertEq(staking.boostBps(alice), 18_500, "repriced down at the halved mark");

        oracle.setPrice(MONEY_TICKER, MONEY_PRICE);
        staking.refreshBoost(users);
        assertEq(staking.boostBps(alice), 36_000, "repriced back up on recovery");
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_setBoostCalculator_replacesAndReprices() public {
        _stake(alice, _moneyFor(1000), 1000e18); // 1:1 -> 12_666 on the launch calculator
        assertEq(staking.boostBps(alice), 12_666);

        // Steeper line: max boost already at 1:1 coverage.
        address calc = address(new LinearBoostCalculator(1000, 30_000, 10_000));
        vm.prank(admin);
        staking.setBoostCalculator(calc);

        assertEq(address(staking.boostCalculator()), calc);
        assertEq(staking.previewBoost(_moneyFor(1000), 1000e18), 30_000);
        // Snapshots are not retro-touched; refresh reprices under the new calculator.
        assertEq(staking.boostBps(alice), 12_666);
        address[] memory users = new address[](1);
        users[0] = alice;
        staking.refreshBoost(users);
        assertEq(staking.boostBps(alice), 30_000);
    }

    function test_setBoostCalculator_tiered_repricesBySize() public {
        _stake(alice, _moneyFor(10_000), 100_000e18); // 0.1:1 -> 2166 on the launch line
        _stake(bob, _moneyFor(1000), 1000e18); // 1:1 -> 12_666
        assertEq(staking.boostBps(alice), 2166);

        ITieredBoostCalculator.Tier[] memory t = new ITieredBoostCalculator.Tier[](5);
        t[0] = ITieredBoostCalculator.Tier(0, 30_000);
        t[1] = ITieredBoostCalculator.Tier(10_000e18, 20_000);
        t[2] = ITieredBoostCalculator.Tier(25_000e18, 10_000);
        t[3] = ITieredBoostCalculator.Tier(50_000e18, 2000);
        t[4] = ITieredBoostCalculator.Tier(100_000e18, 1000);
        address calc = address(new TieredBoostCalculator(1000, 36_000, t));
        vm.prank(admin);
        staking.setBoostCalculator(calc);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        staking.refreshBoost(users);
        assertEq(staking.boostBps(alice), 36_000);
        assertEq(staking.boostBps(bob), 12_666);
        assertEq(staking.totalWeight(), 100_000e18 * 36_000 / 10_000 + 1000e18 * 12_666 / 10_000);

        // Dropping below $100k re-snapshots at the $50k tier: 0.1 + 3.5 × 10k / 19,999.8 -> 1.85x.
        vm.prank(alice);
        staking.unstake(0, 1e18);
        assertEq(staking.boostBps(alice), 18_500);
    }

    function test_setBoostCalculator_zeroOrNonAdmin_reverts() public {
        vm.expectRevert(IOwnStakingV2.ZeroAddress.selector);
        vm.prank(admin);
        staking.setBoostCalculator(address(0));

        address calc = _defaultCalc();
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        vm.prank(alice);
        staking.setBoostCalculator(calc);
    }

    function test_brokenCalculator_neverGatesFunds() public {
        _stake(alice, _moneyFor(3000), 1000e18);
        assertEq(staking.boostBps(alice), 36_000);

        address broken = address(new RevertingCalculator());
        vm.prank(admin);
        staking.setBoostCalculator(broken);

        // Touches keep the last snapshot; previews surface the failure; exits work.
        address[] memory users = new address[](1);
        users[0] = alice;
        staking.refreshBoost(users);
        assertEq(staking.boostBps(alice), 36_000);

        vm.expectRevert(IOwnStakingV2.BoostCalculatorFailed.selector);
        staking.previewBoost(_moneyFor(1000), 1000e18);

        vm.prank(alice);
        staking.unstake(_moneyFor(1000), 400e18);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.totalWeight(), 0);
    }

    function test_setRewardsDuration_reanchorsMidStream() public {
        _stake(alice, 0, 1000e18);
        _notify(700e18);
        vm.warp(block.timestamp + 3.5 days);

        vm.prank(admin);
        staking.setRewardsDuration(14 days);

        // Remaining 350 re-streams over 14 days; total payout is unchanged.
        vm.warp(block.timestamp + 14 days);
        assertApproxEqRel(staking.earned(alice), 700e18, 1e12);
    }

    function test_adminSetters_gated() public {
        address calc = _defaultCalc();
        vm.startPrank(attacker);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.setBoostCalculator(calc);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.setStakeCap(1);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.setMaxBoost(1);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.setRewardsDuration(1 days);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.setPriceMaxAge(1 hours);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.setRewardSource(attacker);
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        staking.rescueToken(address(0xBEEF), attacker, 1);
        vm.stopPrank();
    }

    function test_operatorFunctions_gated() public {
        vm.startPrank(attacker);
        vm.expectRevert(IOwnStakingV2.OnlyOperator.selector);
        staking.notifyRewardAmount(1e18);
        vm.expectRevert(IOwnStakingV2.OnlyOperator.selector);
        staking.renotifyUndistributed();
        vm.stopPrank();
    }

    function test_rescue_protectsCoreAssets() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IOwnStakingV2.ProtectedToken.selector, address(spy)));
        staking.rescueToken(address(spy), admin, 1);
        vm.expectRevert(abi.encodeWithSelector(IOwnStakingV2.ProtectedToken.selector, address(eusd)));
        staking.rescueToken(address(eusd), admin, 1);
        vm.expectRevert(abi.encodeWithSelector(IOwnStakingV2.ProtectedToken.selector, address(money)));
        staking.rescueToken(address(money), admin, 1);
        vm.stopPrank();

        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(staking), 5e18);
        vm.prank(admin);
        staking.rescueToken(address(stray), admin, 5e18);
        assertEq(stray.balanceOf(admin), 5e18);
    }

    function test_upgrade_adminGated() public {
        OwnStakingV2 newImpl = new OwnStakingV2();
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        vm.prank(attacker);
        staking.upgradeToAndCall(address(newImpl), "");

        vm.prank(admin);
        staking.upgradeToAndCall(address(newImpl), "");
    }

    // ──────────────────────────────────────────────────────────
    //  Zap surface
    // ──────────────────────────────────────────────────────────

    function test_stakeFor_onlyZap() public {
        vm.expectRevert(IOwnStakingV2.OnlyZap.selector);
        vm.prank(attacker);
        staking.stakeFor(alice, 0, 1000e18);
    }

    function test_stakeFor_creditsOwnerPullsFromCaller() public {
        address zapAddr = _fundedZap();
        uint256 m = _moneyFor(1000);
        uint256 zapMoneyBefore = money.balanceOf(zapAddr);
        vm.prank(zapAddr);
        staking.stakeFor(alice, m, 1000e18);

        assertEq(staking.position(alice).eusdStaked, 1000e18, "position credited to alice");
        assertEq(staking.boostBps(alice), 12_666);
        assertEq(staking.position(zapAddr).eusdStaked, 0, "zap holds no position");
        assertEq(zapMoneyBefore - money.balanceOf(zapAddr), m, "tokens pulled from the zap");
    }

    function test_stakeFor_zeroOwner_reverts() public {
        address zapAddr = _fundedZap();
        vm.expectRevert(IOwnStakingV2.ZeroAddress.selector);
        vm.prank(zapAddr);
        staking.stakeFor(address(0), 0, 1e18);
    }

    function test_stakeFor_respectsCap() public {
        address zapAddr = _fundedZap();
        vm.prank(admin);
        staking.setStakeCap(500e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnStakingV2.StakeCapExceeded.selector, 501e18, 500e18));
        vm.prank(zapAddr);
        staking.stakeFor(alice, 0, 501e18);
    }

    function test_unstakeFor_onlyZap() public {
        _stake(alice, 0, 1000e18);
        vm.expectRevert(IOwnStakingV2.OnlyZap.selector);
        vm.prank(attacker);
        staking.unstakeFor(alice, 0, 1000e18);
    }

    function test_unstakeFor_paysZap() public {
        address zapAddr = address(uint160(uint256(keccak256("zap"))));
        vm.prank(admin);
        staking.setZap(zapAddr);

        _stake(alice, _moneyFor(1000), 1000e18);
        vm.prank(zapAddr);
        staking.unstakeFor(alice, 0, 400e18);

        assertEq(eusd.balanceOf(zapAddr), 400e18, "eUSD paid to the zap");
        assertEq(staking.position(alice).eusdStaked, 600e18, "alice's position reduced");
    }

    function test_claimFor_onlyZapAndPaysZap() public {
        address zapAddr = address(uint160(uint256(keccak256("zap"))));
        vm.prank(admin);
        staking.setZap(zapAddr);

        _stake(alice, 0, 1000e18);
        _notify(700e18);
        vm.warp(block.timestamp + DURATION);
        uint256 owed = staking.earned(alice);

        vm.expectRevert(IOwnStakingV2.OnlyZap.selector);
        vm.prank(attacker);
        staking.claimFor(alice);

        vm.prank(zapAddr);
        uint256 paid = staking.claimFor(alice);
        assertEq(paid, owed);
        assertEq(spy.balanceOf(zapAddr), owed, "SPY paid to the zap");
        assertEq(staking.earned(alice), 0);
    }

    function test_setZap_adminGated() public {
        vm.expectRevert(IOwnStakingV2.OnlyAdmin.selector);
        vm.prank(attacker);
        staking.setZap(attacker);
    }

    // ──────────────────────────────────────────────────────────
    //  Solvency sanity
    // ──────────────────────────────────────────────────────────

    function test_spyPaid_neverExceedsSpyNotified() public {
        _stake(alice, 0, 600e18);
        _stake(bob, _moneyFor(1200), 400e18);
        _notify(700e18);
        vm.warp(block.timestamp + 2 days);
        _notify(300e18);
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        staking.claim(alice);
        vm.prank(bob);
        staking.claim(bob);

        uint256 paid = spy.balanceOf(alice) + spy.balanceOf(bob);
        assertLe(paid, 1000e18, "paid <= notified");
        assertApproxEqRel(paid, 1000e18, 1e12, "nearly all distributed");
        assertLe(1000e18 - paid, 1e6, "only rounding dust retained");
    }
}
