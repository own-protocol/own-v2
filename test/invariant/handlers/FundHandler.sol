// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../../src/funds/Fund.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {IFundHook} from "../../../src/interfaces/IFundHook.sol";
import {IFundStaking} from "../../../src/interfaces/IFundStaking.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundHandler — random direct mints, pool buys (with issuance), redeems, unstakes, staked
///        redeems and boost settlements on one fund
contract FundHandler is Test {
    Fund internal fund;
    IFundStaking internal staking;
    MockERC20[3] internal assets;
    MockERC20 internal usdg;
    address[3] internal actors;
    PoolSwapTest internal router;
    PoolKey internal key;
    bool internal usdgIs0;

    uint256 public mints;
    uint256 public buys;
    uint256 public redeems;

    constructor(Fund fund_, MockERC20[3] memory assets_, address[3] memory actors_) {
        fund = fund_;
        staking = IFundStaking(fund_.staking());
        assets = assets_;
        usdg = MockERC20(IFundFactory(fund_.factory()).usdg());
        actors = actors_;
        IFundHook hook = IFundHook(IFundFactory(fund_.factory()).hook());
        key = hook.poolKeyOf(address(fund_));
        usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        router = new PoolSwapTest(hook.poolManager());
    }

    function buy(uint256 actorSeed, uint256 usdgIn, uint256 warpBy) external {
        vm.warp(block.timestamp + bound(warpBy, 0, 1 days));
        address actor = actors[actorSeed % 3];
        usdgIn = bound(usdgIn, 1e6, 20_000e6);
        usdg.mint(actor, usdgIn);
        vm.startPrank(actor);
        usdg.approve(address(router), usdgIn);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: usdgIs0,
                amountSpecified: -int256(usdgIn),
                sqrtPriceLimitX96: usdgIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        ++buys;
    }

    function mint(uint256 actorSeed, uint256 navShares) external {
        address actor = actors[actorSeed % 3];
        navShares = bound(navShares, 1e15, 10_000e18);
        (,, uint256[] memory amounts, uint256 usdgAmount) = fund.previewMint(navShares);
        vm.startPrank(actor);
        for (uint256 i; i < 3; ++i) {
            assets[i].mint(actor, amounts[i]);
            assets[i].approve(address(fund), amounts[i]);
        }
        usdg.mint(actor, usdgAmount);
        usdg.approve(address(fund), usdgAmount);
        fund.mint(navShares, 0, actor);
        vm.stopPrank();
        ++mints;
    }

    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = fund.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        fund.redeem(amount, actor, new uint256[](0), 0);
        ++redeems;
    }

    function redeemStaked(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (staking.convertToAssets(amount) == 0) return;
        vm.prank(actor);
        staking.redeem(amount, actor, new uint256[](0), 0);
        ++redeems;
    }

    function unstake(uint256 actorSeed, uint256 amount, uint256 warpBy) external {
        vm.warp(block.timestamp + bound(warpBy, 0, 10 days));
        address actor = actors[actorSeed % 3];
        IFundStaking.MintLock memory lock = staking.mintLockOf(actor);
        uint256 bal = staking.balanceOf(actor);
        uint256 locked = block.timestamp < lock.unlockAt ? lock.shares : 0;
        if (bal <= locked) return;
        amount = bound(amount, 1, bal - locked);
        if (staking.convertToAssets(amount) == 0) return;
        vm.prank(actor);
        staking.unstake(amount, actor);
    }

    function settle(uint256 actorSeed, uint256 warpBy) external {
        vm.warp(block.timestamp + bound(warpBy, 0, 30 days));
        staking.settleBoost(actors[actorSeed % 3]);
    }
}
