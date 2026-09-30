// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {FundMetadata, LockOption, PlatformMetadata} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Stands in as the fund's governor and tries to change the basket when it is paid mid-swap.
contract BasketSwapper is ERC20 {
    Fund internal immutable fund;
    address internal immutable replacement;

    constructor(
        Fund fund_,
        address replacement_
    ) ERC20("Hop", "HOP") {
        fund = fund_;
        replacement = replacement_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);
        if (to == address(fund)) {
            address[] memory a = fund.assets();
            a[2] = replacement;
            uint16[] memory w = new uint16[](3);
            w[0] = 4000;
            w[1] = 3000;
            w[2] = 3000;
            fund.setTargetWeights(a, w);
            // Refill the reused slot so the old per-slot balance check would pass.
            IERC20(replacement).transfer(address(fund), IERC20(replacement).balanceOf(address(this)));
        }
    }
}

contract FundTest is FundTestBase {
    MockSwapRouter internal router;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        launch.claim(false); // 60k MF1
        vm.prank(bob);
        launch.claim(false); // 40k MF1

        router = new MockSwapRouter();
        vm.prank(admin);
        factory.setRouter(address(router), true);
    }

    // ──────────────────────────────────────────────────────────
    //  NAV and premium
    // ──────────────────────────────────────────────────────────

    function test_nav_countsEveryToken() public view {
        assertApproxEqRel(fund.totalValue(), 100_000e18, 1e9);
        assertApproxEqRel(fund.navPerShare(), uint256(1e18) * 100_000 / 130_000, 1e9);
    }

    function test_premium_thirtyPercentAtLaunch() public view {
        (bool ok, int256 premium) = fund.premiumBps();
        assertTrue(ok);
        assertApproxEqAbs(premium, 3000, 1);
    }

    function test_premium_staleMarketPrice_notOk() public {
        vm.warp(block.timestamp + STALENESS + 1);
        (bool ok,) = fund.premiumBps();
        assertFalse(ok);
    }

    // ──────────────────────────────────────────────────────────
    //  mint
    // ──────────────────────────────────────────────────────────

    function test_mint_noLock_atMarketPrice() public {
        _mintAsset(alice, pons, 50_000e18); // $1,000
        uint256 navBefore = fund.navPerShare();

        vm.prank(alice);
        uint256 shares = fund.mint(address(pons), 50_000e18, 0, 0, alice);

        // $1,000 at $1.00 = 1,000 MF1 gross; 0.5% protocol and 1% creator fees.
        assertEq(shares, 985e18);
        assertEq(fund.balanceOf(alice), 60_000e18 + 985e18);
        assertEq(fund.balanceOf(protocolTreasury), 5e18);
        assertEq(fund.balanceOf(creatorTreasury), 10e18);
        assertGt(fund.navPerShare(), navBefore); // minting above NAV adds backing for everyone
    }

    function test_mint_withLock_discountedAndLocked() public {
        _mintAsset(alice, pons, 50_000e18);
        vm.prank(alice);
        uint256 shares = fund.mint(address(pons), 50_000e18, 1, 0, alice); // 7 days, 5% off

        // $1,000 at $0.95 = 1,052.63 gross, less 1.5% fees.
        uint256 gross = uint256(1000e18) * 1e18 / 0.95e18;
        assertApproxEqAbs(shares, gross - gross * 50 / 10_000 - gross * 100 / 10_000, 2);
        assertEq(fund.balanceOf(alice), 60_000e18);

        IFund.Lock[] memory locks = fund.locksOf(alice);
        assertEq(locks.length, 1);
        assertEq(locks[0].amount, shares);
        assertEq(locks[0].unlockAt, block.timestamp + 7 days);

        uint256[] memory ids = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFund.LockNotClaimable.selector, 0));
        fund.claimLocks(ids);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(fund.claimLocks(ids), shares);
        assertEq(fund.balanceOf(alice), 60_000e18 + shares);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFund.LockNotClaimable.selector, 0));
        fund.claimLocks(ids);
    }

    function test_mint_marketBelowNav_pricedAtNav() public {
        _setFeed(address(fund), 0.5e8);
        uint256 nav = fund.navPerShare();
        _mintAsset(alice, pons, 50_000e18);
        (, uint256 mintPrice) = fund.previewMint(address(pons), 50_000e18, 0);
        assertApproxEqAbs(mintPrice, nav, 1);

        vm.prank(alice);
        fund.mint(address(pons), 50_000e18, 0, 0, alice);
        assertGe(fund.navPerShare(), nav); // never dilutive
    }

    function test_mint_matchesPreview() public {
        _mintAsset(alice, tsla, 3e18);
        (uint256 quoted,) = fund.previewMint(address(tsla), 3e18, 2);
        vm.prank(alice);
        assertEq(fund.mint(address(tsla), 3e18, 2, quoted, alice), quoted);
    }

    function test_mint_notLaunched_reverts() public {
        _createFund();
        _mintAsset(alice, pons, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFund.NotLaunched.selector);
        fund.mint(address(pons), 1e18, 0, 0, alice);
    }

    function test_mint_paused_reverts() public {
        vm.prank(admin);
        fund.setMintPaused(true);
        vm.prank(alice);
        vm.expectRevert(IFund.MintPaused.selector);
        fund.mint(address(pons), 1e18, 0, 0, alice);
    }

    function test_mint_assetNotInBasket_reverts() public {
        _mintAsset(alice, spare, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFund.AssetNotMintable.selector, address(spare)));
        fund.mint(address(spare), 1e18, 0, 0, alice);
    }

    function test_mint_staleMarketPrice_reverts() public {
        vm.warp(block.timestamp + STALENESS + 1);
        _setFeed(address(pons), 0.02e8);
        _setFeed(address(net), 300e8);
        _setFeed(address(tsla), 400e8);
        _mintAsset(alice, pons, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFund.NoMarketPrice.selector);
        fund.mint(address(pons), 1e18, 0, 0, alice);
    }

    function test_mint_slippage_reverts() public {
        _mintAsset(alice, pons, 50_000e18);
        vm.prank(alice);
        vm.expectRevert(IFund.Slippage.selector);
        fund.mint(address(pons), 50_000e18, 0, 986e18, alice);
    }

    function test_mint_invalidLockOption_reverts() public {
        _mintAsset(alice, pons, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFund.InvalidLockOption.selector);
        fund.mint(address(pons), 1e18, 3, 0, alice);
    }

    function test_mint_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFund.ZeroAmount.selector);
        fund.mint(address(pons), 0, 0, 0, alice);
    }

    function test_mint_zeroReceiver_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFund.ZeroAddress.selector);
        fund.mint(address(pons), 1e18, 0, 0, address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  redeem
    // ──────────────────────────────────────────────────────────

    function test_redeem_wholeBasketProRata() public {
        uint256 supply = fund.totalSupply();
        uint256 navBefore = fund.navPerShare();
        uint256 netBal = net.balanceOf(address(fund));
        uint256 ponsBal = pons.balanceOf(address(fund));
        uint256 tslaBal = tsla.balanceOf(address(fund));

        vm.prank(alice);
        uint256[] memory out = fund.redeem(10_000e18, alice, new uint256[](0));

        uint256 net_ = 10_000e18 - 50e18 - 100e18;
        assertEq(out[0], netBal * net_ / supply);
        assertEq(out[1], ponsBal * net_ / supply);
        assertEq(out[2], tslaBal * net_ / supply);
        assertEq(net.balanceOf(alice), out[0]);
        assertEq(pons.balanceOf(alice), out[1]);
        assertEq(tsla.balanceOf(alice), out[2]);
        assertEq(fund.balanceOf(protocolTreasury), 50e18);
        assertEq(fund.balanceOf(creatorTreasury), 100e18);
        assertEq(fund.totalSupply(), supply - net_);
        assertGe(fund.navPerShare(), navBefore);
    }

    function test_redeem_worksWithStaleOracleAndMintPaused() public {
        vm.prank(admin);
        fund.setMintPaused(true);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        uint256[] memory out = fund.redeem(1000e18, alice, new uint256[](0));
        assertGt(out[0], 0);
    }

    function test_redeem_matchesPreview() public {
        uint256[] memory quoted = fund.previewRedeem(5000e18);
        vm.prank(bob);
        uint256[] memory out = fund.redeem(5000e18, bob, quoted);
        for (uint256 i; i < out.length; ++i) {
            assertEq(out[i], quoted[i]);
        }
    }

    function test_redeem_belowMinimum_reverts() public {
        uint256[] memory mins = fund.previewRedeem(5000e18);
        mins[1] += 1;
        vm.prank(bob);
        vm.expectRevert(IFund.Slippage.selector);
        fund.redeem(5000e18, bob, mins);
    }

    function test_redeem_lengthMismatch_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFund.LengthMismatch.selector);
        fund.redeem(5000e18, bob, new uint256[](2));
    }

    function test_redeem_zero_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFund.ZeroAmount.selector);
        fund.redeem(0, bob, new uint256[](0));
    }

    function test_burn_raisesNav() public {
        uint256 navBefore = fund.navPerShare();
        vm.prank(alice);
        fund.burn(10_000e18);
        assertGt(fund.navPerShare(), navBefore);
    }

    // ──────────────────────────────────────────────────────────
    //  rebalance
    // ──────────────────────────────────────────────────────────

    function test_rebalance_swapsWithinOracleBound() public {
        tsla.mint(address(router), 100e18);
        uint256 netBefore = net.balanceOf(address(fund));
        uint256 tslaBefore = tsla.balanceOf(address(fund));

        // Sell 10 NET ($3,000) for 7.4 TSLA ($2,960): 1.33% below oracle value, inside the 2% bound.
        vm.prank(creator);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));

        assertEq(net.balanceOf(address(fund)), netBefore - 10e9);
        assertEq(tsla.balanceOf(address(fund)), tslaBefore + 7.4e18);
        assertEq(net.allowance(address(fund), address(router)), 0);
    }

    function test_rebalance_dailyVolumeCapped() public {
        tsla.mint(address(router), 100e18);
        // 3 x $3,000 = $9,000 fits under 10% of the ~$100k basket; a fourth does not.
        vm.startPrank(creator);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.expectRevert(IFund.RebalanceVolumeExceeded.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        vm.prank(creator);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
    }

    function test_rebalance_allowanceRefillsLinearly() public {
        tsla.mint(address(router), 100e18);
        vm.startPrank(creator);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.stopPrank();

        // Half a day drains ~$5k of the ~$9k used: one more $3k sale fits, a second does not.
        vm.warp(block.timestamp + 12 hours);
        _refreshFeeds();
        vm.startPrank(creator);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.expectRevert(IFund.RebalanceVolumeExceeded.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.stopPrank();
    }

    function test_rebalance_basketChangeMidSwap_reverts() public {
        BasketSwapper hop = new BasketSwapper(fund, address(spare));
        vm.prank(admin);
        fund.setGovernor(address(hop));
        hop.mint(address(router), 1);
        spare.mint(address(hop), tsla.balanceOf(address(fund))); // 85 SPARE ($85) for $34k of TSLA

        // Sells all TSLA; the payout swaps TSLA's slot for SPARE so the balance checks would skip it.
        uint256 tslaHeld = tsla.balanceOf(address(fund));
        IFund.RebalanceParams memory p = IFund.RebalanceParams({
            sellAsset: address(tsla),
            sellAmount: tslaHeld,
            buyAsset: address(pons),
            minBuyAmount: 0,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(tsla), tslaHeld, address(hop), 1))
        });
        vm.prank(creator);
        vm.expectRevert(IFund.RebalanceCallFailed.selector);
        fund.rebalance(p);
    }

    function test_rebalance_tooMuchValueLost_reverts() public {
        tsla.mint(address(router), 100e18);
        // 7 TSLA = $2,800, 6.7% below the $3,000 sold.
        vm.prank(creator);
        vm.expectRevert(IFund.RebalanceInvalid.selector);
        fund.rebalance(_swap(10e9, 7e18, 7e18));
    }

    function test_rebalance_belowMinBuy_reverts() public {
        tsla.mint(address(router), 100e18);
        vm.prank(creator);
        vm.expectRevert(IFund.RebalanceInvalid.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.5e18));
    }

    function test_rebalance_routerNotAllowed_reverts() public {
        vm.prank(admin);
        factory.setRouter(address(router), false);
        vm.prank(creator);
        vm.expectRevert(IFund.RouterNotAllowed.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
    }

    function test_rebalance_notManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotManager.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
    }

    function test_rebalance_routerCallFails_reverts() public {
        IFund.RebalanceParams memory p = _swap(10e9, 7.4e18, 7.4e18);
        p.data = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.prank(creator);
        vm.expectRevert(IFund.RebalanceCallFailed.selector);
        fund.rebalance(p);
    }

    function _swap(
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 minBuy
    ) internal view returns (IFund.RebalanceParams memory) {
        return IFund.RebalanceParams({
            sellAsset: address(net),
            sellAmount: sellAmount,
            buyAsset: address(tsla),
            minBuyAmount: minBuy,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(net), sellAmount, address(tsla), buyAmount))
        });
    }

    // ──────────────────────────────────────────────────────────
    //  basket and admin settings
    // ──────────────────────────────────────────────────────────

    function test_setTargetWeights_addsAsset() public {
        address[] memory a = new address[](4);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        a[3] = address(spare);
        uint16[] memory w = new uint16[](4);
        w[0] = 4000;
        w[1] = 2000;
        w[2] = 3000;
        w[3] = 1000;
        vm.prank(address(governor));
        fund.setTargetWeights(a, w);
        assertTrue(fund.isAsset(address(spare)));
        assertEq(fund.targetWeightBps(address(pons)), 2000);
        assertEq(fund.assets().length, 4);
    }

    function test_setTargetWeights_dropHeldAsset_reverts() public {
        address[] memory a = new address[](2);
        a[0] = address(net);
        a[1] = address(tsla);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 5000;
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(IFund.AssetHasBalance.selector, address(pons)));
        fund.setTargetWeights(a, w);
    }

    function test_setTargetWeights_dustDoesNotBlockDrop() public {
        (address[] memory withSpare, uint16[] memory w4) = _basketWithSpare();
        vm.prank(address(governor));
        fund.setTargetWeights(withSpare, w4);

        spare.mint(address(fund), 1); // a griefer's 1 wei
        address[] memory a = new address[](3);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        vm.prank(address(governor));
        fund.setTargetWeights(a, w);
        assertFalse(fund.isAsset(address(spare)));
    }

    function test_setTargetWeights_moreThanDust_reverts() public {
        (address[] memory withSpare, uint16[] memory w4) = _basketWithSpare();
        vm.prank(address(governor));
        fund.setTargetWeights(withSpare, w4);

        spare.mint(address(fund), 101e18); // $101, over 0.1% of the ~$100k basket
        address[] memory a = new address[](3);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(IFund.AssetHasBalance.selector, address(spare)));
        fund.setTargetWeights(a, w);
    }

    function _basketWithSpare() internal view returns (address[] memory a, uint16[] memory w) {
        a = new address[](4);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        a[3] = address(spare);
        w = new uint16[](4);
        w[0] = 4000;
        w[1] = 2000;
        w[2] = 3000;
        w[3] = 1000;
    }

    function test_setTargetWeights_badSum_reverts() public {
        address[] memory a = fund.assets();
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 2000;
        vm.prank(address(governor));
        vm.expectRevert(IFund.InvalidBasket.selector);
        fund.setTargetWeights(a, w);
    }

    function test_setTargetWeights_notGovernor_reverts() public {
        address[] memory a = fund.assets();
        uint16[] memory w = new uint16[](3);
        vm.prank(creator);
        vm.expectRevert(IFund.NotGovernor.selector);
        fund.setTargetWeights(a, w);
    }

    function test_setCreatorFee_creatorCannot() public {
        vm.prank(creator);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setCreatorFee(1000, creator);
    }

    function test_setCreatorFee_adminCapped() public {
        vm.startPrank(admin);
        fund.setCreatorFee(1000, creatorTreasury);
        assertEq(fund.creatorFeeBps(), 1000);
        vm.expectRevert(IFund.FeeTooHigh.selector);
        fund.setCreatorFee(1001, creatorTreasury);
        vm.stopPrank();
    }

    function test_setLockOptions_invalid_reverts() public {
        LockOption[] memory opts = new LockOption[](1);
        opts[0] = LockOption({duration: 1 days, discountBps: 5001});
        vm.prank(admin);
        vm.expectRevert(IFund.InvalidLockOptions.selector);
        fund.setLockOptions(opts);
    }

    function test_setManager_adminOnly() public {
        vm.prank(creator);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setManager(attacker);
        vm.prank(admin);
        fund.setManager(bob);
        assertEq(fund.manager(), bob);
    }

    function test_moduleMint_notModule_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotModule.selector);
        fund.moduleMint(attacker, 1e18);
    }

    function test_markLaunched_notLaunch_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotLaunch.selector);
        fund.markLaunched();
    }

    function test_setModules_twice_reverts() public {
        vm.prank(address(factory));
        vm.expectRevert(IFund.ModulesAlreadySet.selector);
        fund.setModules(alice, bob, bob);
    }

    function test_implementation_cannotBeInitialized() public {
        Fund impl = new Fund();
        vm.expectRevert();
        impl.initialize(_defaultParams());
    }

    function test_metadata() public view {
        assertEq(fund.name(), "MONEY Market Fund 1");
        assertEq(fund.symbol(), "MF1");
        assertEq(fund.decimals(), 18);
        assertEq(staking.symbol(), "sMF1");
    }

    // ──────────────────────────────────────────────────────────
    //  metadata and governor
    // ──────────────────────────────────────────────────────────

    function test_metadata_creatorFieldsPlusPlatform() public {
        vm.prank(admin);
        factory.setPlatformMetadata(
            PlatformMetadata({
                name: "MONEY Market Funds by Own", description: "Basket-backed funds on Own.", url: "https://own.money"
            })
        );
        FundMetadata memory m = fund.metadata();
        assertEq(m.name, "MONEY Market Fund 1");
        assertEq(m.symbol, "MF1");
        assertEq(m.logoURI, "ipfs://mf1-logo");
        assertEq(m.description, "Robinhood Chain ecosystem tokens and stocks.");
        assertEq(m.platform.name, "MONEY Market Funds by Own");
        assertEq(m.platform.url, "https://own.money");
    }

    function test_setMetadata_creatorAndAdmin() public {
        vm.prank(creator);
        fund.setMetadata("Robin Fund", "ROBIN", "ipfs://robin", "New description");
        assertEq(fund.name(), "Robin Fund");
        assertEq(fund.symbol(), "ROBIN");
        assertEq(fund.logoURI(), "ipfs://robin");
        assertEq(fund.description(), "New description");

        vm.prank(admin);
        fund.setMetadata("MF1", "MF1", "", "");
        assertEq(fund.name(), "MF1");
        assertEq(fund.logoURI(), "");
    }

    function test_setMetadata_stranger_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotManagerOrAdmin.selector);
        fund.setMetadata("X", "X", "", "");
    }

    function test_setMetadata_emptyName_reverts() public {
        vm.prank(creator);
        vm.expectRevert(IFund.InvalidMetadata.selector);
        fund.setMetadata("", "MF1", "", "");
    }

    function test_setMetadata_longSymbol_reverts() public {
        vm.prank(creator);
        vm.expectRevert(IFund.InvalidMetadata.selector);
        fund.setMetadata("MF1", "SEVENTEEN_CHARSXX", "", "");
    }

    function test_setGovernor_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFund.ZeroAddress.selector);
        fund.setGovernor(address(0));
    }
}
