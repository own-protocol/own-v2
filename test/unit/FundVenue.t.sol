// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {IFundVenue} from "../../src/interfaces/IFundVenue.sol";
import {IssuanceConfig, PoolSettings} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockTaxQueue} from "../helpers/MockHookr.sol";
import {MockPositionManager} from "../helpers/MockPositionManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev The venue before its pool opens: settings, seeding and the launch fee.
contract FundVenueSeedTest is FundTestBase {
    function setUp() public override {
        super.setUp();
        _finalizeDefault();
    }

    function _settings() internal pure returns (PoolSettings memory) {
        return PoolSettings({buyTaxPips: 20_000, sellTaxPips: 0, hookrShareBps: 2000, lpFeePips: 500, tickSpacing: 10});
    }

    function test_setPoolSettings_adminOnlyAndBounded() public {
        PoolSettings memory s = _settings();
        vm.prank(attacker);
        vm.expectRevert(IFundVenue.NotAdmin.selector);
        venue.setPoolSettings(s);

        vm.startPrank(admin);
        s.hookrShareBps = 1999;
        vm.expectRevert(IFundVenue.InvalidSettings.selector);
        venue.setPoolSettings(s);
        s.hookrShareBps = 5001;
        vm.expectRevert(IFundVenue.InvalidSettings.selector);
        venue.setPoolSettings(s);
        s = _settings();
        s.buyTaxPips = 100_001;
        vm.expectRevert(IFundVenue.InvalidSettings.selector);
        venue.setPoolSettings(s);
        s = _settings();
        s.lpFeePips = 100_001;
        vm.expectRevert(IFundVenue.InvalidSettings.selector);
        venue.setPoolSettings(s);
        s = _settings();
        s.tickSpacing = TickMath.MAX_TICK_SPACING + 1;
        vm.expectRevert(IFundVenue.InvalidSettings.selector);
        venue.setPoolSettings(s);

        venue.setPoolSettings(_settings());
        vm.stopPrank();
        PoolSettings memory got = venue.poolSettings();
        assertEq(got.buyTaxPips, 20_000);
        assertEq(got.sellTaxPips, 0);
        assertEq(got.hookrShareBps, 2000);
        assertEq(got.lpFeePips, 500);
        assertEq(got.tickSpacing, 10);
    }

    function test_setPoolSettings_zeroTickSpacingDefaults() public {
        PoolSettings memory s = _settings();
        s.tickSpacing = 0;
        vm.prank(admin);
        venue.setPoolSettings(s);
        assertEq(venue.poolSettings().tickSpacing, 60);
    }

    function test_seed_opensPoolWithSettings() public {
        vm.prank(admin);
        venue.setPoolSettings(_settings());
        vm.prank(keeper);
        launch.seedPool();

        assertTrue(venue.isSeeded());
        PoolKey memory key = venue.poolKey();
        assertEq(key.fee, 500);
        assertEq(key.tickSpacing, 10);
        assertTrue(Currency.unwrap(key.currency0) == address(usdg) || Currency.unwrap(key.currency1) == address(usdg));
        assertTrue(Currency.unwrap(key.currency0) == address(fund) || Currency.unwrap(key.currency1) == address(fund));
        assertEq(hookr.familyOwner(venue.family()), address(venue));
        assertGt(venue.positionLiquidity(), 0);

        // A zero tax direction has no queue; the other pays the curators.
        (address buyQueue, address sellQueue) = venue.taxQueues();
        assertEq(sellQueue, address(0));
        assertEq(MockTaxQueue(buyQueue).recipient(), address(curators));

        assertEq(usdg.balanceOf(address(venue)), 0);
        assertEq(fund.balanceOf(address(venue)), 0);
    }

    function test_seed_paysLaunchFee() public {
        hookr.setLaunchFee(0.01 ether);
        vm.prank(keeper);
        vm.expectRevert();
        launch.seedPool();

        vm.deal(keeper, 0.01 ether);
        vm.prank(keeper);
        launch.seedPool{value: 0.01 ether}();
        assertTrue(venue.isSeeded());
        assertEq(address(hookr).balance, 0.01 ether);
    }

    function test_seedPool_onlyLaunch() public {
        vm.prank(attacker);
        vm.expectRevert(IFundVenue.NotLaunch.selector);
        venue.seedPool(1e6, 1e18);
    }

    function test_seedPool_emptyReverts() public {
        vm.startPrank(address(launch));
        vm.expectRevert(IFundVenue.InvalidSeed.selector);
        venue.seedPool(0, 1e18);
        vm.expectRevert(IFundVenue.InvalidSeed.selector);
        venue.seedPool(1e6, 0);
        vm.stopPrank();
    }

    function test_seedPool_twiceReverts() public {
        vm.prank(keeper);
        launch.seedPool();
        vm.prank(address(launch));
        vm.expectRevert(IFundVenue.AlreadySeeded.selector);
        venue.seedPool(1e6, 1e18);
    }

    function test_seeded_settingsFrozen() public {
        vm.prank(keeper);
        launch.seedPool();
        vm.prank(admin);
        vm.expectRevert(IFundVenue.AlreadySeeded.selector);
        venue.setPoolSettings(_settings());
    }

    function test_beforeSeed_poolCallsRevertOrReadZero() public {
        vm.expectRevert(IFundVenue.NotSeeded.selector);
        venue.issue();
        vm.expectRevert(IFundVenue.NotSeeded.selector);
        venue.collectLpFees();
        assertEq(venue.positionLiquidity(), 0);
        assertEq(venue.spotPrice(), 0);
        (uint256 u, uint256 t) = venue.positionAmounts();
        assertEq(u + t, 0);
        assertEq(venue.collectTax(), 0);
    }
}

/// @dev The venue after its pool opens: tax, valuation, redeems and migration.
contract FundVenueTest is FundTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal carol = makeAddr("carol");

    PoolSettings internal moved =
        PoolSettings({buyTaxPips: 5000, sellTaxPips: 5000, hookrShareBps: 2000, lpFeePips: 3000, tickSpacing: 200});

    function setUp() public override {
        super.setUp();
        _launchDefault();
    }

    // ── Tax ───────────────────────────────────────────────────

    function test_collectTax_paysCuratorsFromBothQueues() public {
        (address buyQueue, address sellQueue) = venue.taxQueues();
        usdg.mint(buyQueue, 70e6);
        usdg.mint(sellQueue, 30e6);
        uint256 before = usdg.balanceOf(address(curators));
        assertEq(venue.collectTax(), 100e6);
        assertEq(usdg.balanceOf(address(curators)) - before, 100e6);
    }

    function test_collectTax_nothingDueSkipsQueue() public {
        (address buyQueue,) = venue.taxQueues();
        assertEq(venue.collectTax(), 0);
        usdg.mint(buyQueue, 5e6);
        assertEq(venue.collectTax(), 5e6);
    }

    // ── Valuation ─────────────────────────────────────────────

    /// @dev The position is valued at the fund token's oracle price, so moving spot moves nothing.
    function test_position_valuedAtOraclePrice() public {
        (uint256 usdg0, uint256 tokens0) = venue.positionAmounts();
        _poolSwap(carol, true, -int256(20_000e6));
        (uint256 usdg1, uint256 tokens1) = venue.positionAmounts();
        assertEq(usdg1, usdg0);
        assertEq(tokens1, tokens0);

        _setFundPrice(venue.spotPrice());
        (usdg1, tokens1) = venue.positionAmounts();
        assertGt(usdg1, usdg0);
        assertLt(tokens1, tokens0);
    }

    function test_position_fallsBackToOpeningPrice() public {
        (uint256 usdg0, uint256 tokens0) = venue.positionAmounts();
        _poolSwap(carol, true, -int256(20_000e6));
        _setFundPrice(0); // no oracle price
        (uint256 usdg1, uint256 tokens1) = venue.positionAmounts();
        assertApproxEqRel(usdg1, usdg0, 1e12);
        assertApproxEqRel(tokens1, tokens0, 1e12);
    }

    function test_redeemPosition_paysAtMostOracleValue() public {
        _poolSwap(carol, true, -int256(20_000e6)); // spot above the oracle price
        address receiver = makeAddr("receiver");
        uint128 removed = venue.positionLiquidity() / 10;
        (uint256 cap,) = venue.liquidityAmounts(removed);
        uint256 idle = fund.idleUsdg();
        vm.prank(address(fund));
        uint256 paid = venue.redeemPosition(1, 10, receiver);
        assertEq(paid, cap);
        assertEq(usdg.balanceOf(receiver), paid);
        // The rest of what came out, and the fees, go to the fund.
        assertGt(fund.idleUsdg(), idle);
        assertEq(usdg.balanceOf(address(venue)), 0);
        assertEq(fund.balanceOf(address(venue)), 0);
    }

    // ── Migration ─────────────────────────────────────────────

    function test_migrate_movesPositionAtSamePrice() public {
        PoolKey memory oldKey = venue.poolKey();
        bytes32 oldFamily = venue.family();
        uint256 price = venue.spotPrice();
        uint256 nav = fund.navPerShare();

        vm.expectEmit(true, true, true, false, address(staking));
        emit IFundStaking.LpPoolMoved(1);
        vm.prank(admin);
        venue.migrate(moved);

        PoolKey memory key = venue.poolKey();
        assertTrue(PoolId.unwrap(key.toId()) != PoolId.unwrap(oldKey.toId()));
        assertEq(key.tickSpacing, 200);
        assertEq(key.fee, 3000);
        assertTrue(venue.family() != oldFamily);
        assertEq(hookr.position(oldFamily, 0).liquidity, 0);
        assertEq(poolManager.getLiquidity(oldKey.toId()), 0);
        assertGt(venue.positionLiquidity(), 0);
        assertApproxEqRel(venue.spotPrice(), price, 1e12);
        assertApproxEqRel(fund.navPerShare(), nav, 1e14);
        assertEq(staking.lpEpoch(), 1);
        assertEq(venue.poolSettings().tickSpacing, 200);
        (address buyQueue,) = venue.taxQueues();
        assertEq(MockTaxQueue(buyQueue).recipient(), address(curators));
        assertEq(usdg.balanceOf(address(venue)), 0);
        assertEq(fund.balanceOf(address(venue)), 0);

        // Trading and issuance carry on in the new pool.
        _poolSwap(carol, true, -int256(5000e6));
        (uint256 issued,) = venue.issue();
        assertGt(issued, 0);
    }

    function test_migrate_samePool_reverts() public {
        PoolSettings memory same = venue.poolSettings();
        vm.prank(admin);
        vm.expectRevert();
        venue.migrate(same);
    }

    function test_migrate_adminOnly() public {
        vm.prank(attacker);
        vm.expectRevert(IFundVenue.NotAdmin.selector);
        venue.migrate(moved);
    }

    function test_migrate_spotOffOracle_reverts() public {
        _poolSwap(carol, true, -int256(5000e6));
        vm.prank(admin);
        vm.expectRevert(IFundVenue.PriceOffReference.selector);
        venue.migrate(moved);
    }

    function test_poolMoved_onlyVenue() public {
        vm.prank(attacker);
        vm.expectRevert(IFundStaking.NotVenue.selector);
        staking.poolMoved();
    }

    /// @dev Staked positions in the old pool keep what they earned but earn nothing more; positions
    ///      in the new pool can be staked.
    function test_migrate_stakedLpStopsEarning() public {
        vm.prank(alice);
        launch.claim(true);
        MockPositionManager posm = MockPositionManager(positionManager);
        PoolKey memory key = venue.poolKey();
        uint128 liquidity = venue.positionLiquidity();
        uint256 id = posm.mint(
            carol, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), liquidity
        );
        vm.startPrank(carol);
        posm.approve(address(staking), id);
        staking.stakePosition(id);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        staking.accrue();
        uint256 earned = staking.pendingPositionYield(id);
        assertGt(earned, 0);

        vm.prank(admin);
        venue.migrate(moved);
        assertEq(staking.lpLiquidity(), 0);

        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        staking.accrue();
        assertEq(staking.pendingPositionYield(id), earned);

        vm.prank(carol);
        assertEq(staking.unstakePosition(id, carol), earned);
        assertEq(posm.ownerOf(id), carol);
        assertEq(staking.lpLiquidity(), 0);

        // An old-pool position can no longer be staked; a new-pool one can.
        vm.startPrank(carol);
        posm.approve(address(staking), id);
        vm.expectRevert();
        staking.stakePosition(id);
        vm.stopPrank();
        PoolKey memory newKey = venue.poolKey();
        uint256 newId = posm.mint(
            carol,
            newKey,
            TickMath.minUsableTick(newKey.tickSpacing),
            TickMath.maxUsableTick(newKey.tickSpacing),
            liquidity
        );
        vm.startPrank(carol);
        posm.approve(address(staking), newId);
        staking.stakePosition(newId);
        vm.stopPrank();
        assertEq(staking.lpLiquidity(), liquidity);
    }

    function test_increasePosition_zeroReverts() public {
        vm.prank(address(fund));
        vm.expectRevert(IFundVenue.InvalidSeed.selector);
        venue.increasePosition(0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.prank(attacker);
        vm.expectRevert(IFundVenue.NotPoolManager.selector);
        venue.unlockCallback(abi.encode(uint256(1), uint160(1), uint256(1)));
    }

    // ── Issuance settings ─────────────────────────────────────

    function test_setIssuance_capBounded() public {
        IssuanceConfig memory c = venue.issuanceOf();
        assertEq(c.hourlyCapBps, 500);
        c.hourlyCapBps = 10_001;
        vm.prank(admin);
        vm.expectRevert(IFundVenue.InvalidIssuance.selector);
        venue.setIssuance(c);
    }
}
