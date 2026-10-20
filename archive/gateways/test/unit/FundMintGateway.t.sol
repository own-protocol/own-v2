// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundMintGateway} from "../../src/funds/FundMintGateway.sol";
import {FundMintZap} from "../../src/funds/FundMintZap.sol";
import {IFundMintGateway} from "../../src/interfaces/IFundMintGateway.sol";
import {IFundMintZap} from "../../src/interfaces/IFundMintZap.sol";
import {CcipClient, IAny2EVMMessageReceiver} from "../../src/interfaces/external/ICcip.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {GatewayProxies} from "../helpers/GatewayProxies.sol";
import {MockAcrossSpokePool} from "../helpers/MockAcrossSpokePool.sol";
import {MockCcipRouter} from "../helpers/MockCcipRouter.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev TSLA plays the Base-sourced asset the gateway stocks; NET and PONS are bought on Robinhood.
contract FundMintGatewayTest is FundTestBase {
    uint64 internal constant BASE = 15_971_525_489_660_198_786;
    uint256 internal constant NAV_SHARES = 1000e18;
    uint256 internal constant PAY = 5000e6;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    FundMintGateway internal gw;
    FundMintZap internal zap;
    MockCcipRouter internal ccip;
    MockAcrossSpokePool internal spoke;
    MockSwapRouter internal router;
    address internal safe = makeAddr("safe");
    address internal baseGateway = makeAddr("baseGateway");
    address internal baseFloat = makeAddr("baseFloat");
    address internal baseUsdc = makeAddr("baseUsdc");

    uint256 internal tslaNeed;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        zap = new FundMintZap(address(factory));
        router = new MockSwapRouter();
        ccip = new MockCcipRouter();
        spoke = new MockAcrossSpokePool();
        vm.startPrank(admin);
        factory.setMintZap(address(zap));
        factory.setRouter(address(router), true);
        vm.stopPrank();

        gw = GatewayProxies.mint(
            safe,
            new FundMintGateway(
                address(factory),
                address(zap),
                address(ccip),
                BASE,
                baseGateway,
                baseFloat,
                address(spoke),
                baseUsdc,
                8453
            )
        );
        vm.prank(admin);
        registry.grantRole(keccak256("FUND_GATEWAY"), address(gw));
        vm.startPrank(safe);
        gw.setBaseAsset(address(tsla), true);
        gw.setKeeper(keeper, true);
        vm.stopPrank();

        net.mint(address(router), 1000e9);
        pons.mint(address(router), 10_000_000e18);
        tsla.mint(address(ccip), 1000e18);
        usdg.mint(alice, 100_000e6);
        vm.prank(alice);
        usdg.approve(address(gw), type(uint256).max);

        (,, uint256[] memory amounts,,) = fund.previewMint(NAV_SHARES, false);
        tslaNeed = amounts[2];
    }

    // ---------------------------------------------------------------- instant

    function test_mint_stockCovers_mintsNow() public {
        _stock(10e18);
        (uint256 quoted,,, uint256 usdgSlice,) = fund.previewMint(NAV_SHARES, false);
        uint256 cost = gw.stockCost(address(tsla), tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);

        vm.prank(alice);
        (uint256 shares, uint256 id) = gw.mint(address(fund), PAY, sw, NAV_SHARES, quoted, false);

        assertEq(id, 0);
        assertEq(shares, quoted);
        assertApproxEqAbs(staking.convertToAssets(staking.balanceOf(alice)), shares, 1);
        assertEq(gw.stock(address(tsla)), 10e18 - tslaNeed);
        assertEq(gw.revenue(), cost);
        assertEq(usdg.balanceOf(alice), 100_000e6 - 2000e6 - usdgSlice - cost, "rest refunded");
        assertEq(usdg.balanceOf(address(gw)), cost);
        assertEq(tsla.balanceOf(address(gw)), 10e18 - tslaNeed);
        assertEq(net.balanceOf(address(gw)), 0);
        assertEq(pons.balanceOf(address(gw)), 0);
    }

    function test_mint_leftoverStockGoesBack_boughtLeftoverRefunded() public {
        _stock(10e18);
        IFundMintGateway.Swap[] memory sw = _swaps(7);
        vm.prank(alice);
        gw.mint(address(fund), PAY, sw, NAV_SHARES, 0, false);
        assertEq(net.balanceOf(alice), 7);
        assertEq(pons.balanceOf(alice), 7);
        assertEq(tsla.balanceOf(address(gw)), gw.stock(address(tsla)));
    }

    function test_mint_insufficientUsdg_reverts() public {
        _stock(10e18);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.InsufficientUsdg.selector);
        gw.mint(address(fund), 100e6, sw, NAV_SHARES, 0, false);
    }

    function test_mint_swapsOverBudget_reverts() public {
        _stock(10e18);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.InsufficientUsdg.selector);
        gw.mint(address(fund), 2100e6, sw, NAV_SHARES, 0, false);
    }

    function test_mint_swapNotUsdg_reverts() public {
        _stock(10e18);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        sw[0].tokenIn = address(tsla);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.RouterNotAllowed.selector);
        gw.mint(address(fund), PAY, sw, NAV_SHARES, 0, false);
    }

    function test_mint_notFund_reverts() public {
        IFundMintGateway.Swap[] memory sw;
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.NotFund.selector);
        gw.mint(address(spare), PAY, sw, NAV_SHARES, 0, false);
    }

    function test_zapMintFor_withoutRole_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFundMintZap.NotGateway.selector);
        zap.zapMintFor(address(fund), NAV_SHARES, 0, alice, false);
    }

    // ---------------------------------------------------------------- queued

    function test_mint_stockShort_queues() public {
        uint256 cost = gw.stockCost(address(tsla), tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        (uint256 shares, uint256 id) = gw.mint(address(fund), PAY, sw, NAV_SHARES, 1, false);

        assertEq(shares, 0);
        assertEq(id, 1);
        IFundMintGateway.Order memory o = gw.getOrder(1);
        assertEq(o.receiver, alice);
        assertEq(uint8(o.status), uint8(IFundMintGateway.Status.Queued));
        assertEq(o.fund, address(fund));
        assertEq(o.navShares, NAV_SHARES);
        assertEq(o.usdg, PAY - cost);
        assertEq(o.prepaid, cost);
        assertEq(o.assets.length, 1);
        assertEq(o.assets[0], address(tsla));
        assertEq(o.owed[0], tslaNeed);
        assertEq(gw.revenue(), cost);
        assertEq(gw.queuedUsdg(), PAY - cost);
    }

    function test_fill_afterRestock_mintsForReceiver() public {
        _queue();
        _restock(tslaNeed);
        assertEq(gw.stock(address(tsla)), tslaNeed);
        (uint256 quoted,,, uint256 usdgSlice,) = fund.previewMint(NAV_SHARES, false);
        uint256 cost = gw.stockCost(address(tsla), tslaNeed);
        uint256 before = usdg.balanceOf(alice);

        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(keeper);
        uint256 shares = gw.fill(1, sw, NAV_SHARES);

        assertEq(shares, quoted);
        assertApproxEqAbs(staking.convertToAssets(staking.balanceOf(alice)), shares, 1);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Filled));
        assertEq(gw.queuedUsdg(), 0);
        assertEq(gw.stock(address(tsla)), 0);
        assertEq(usdg.balanceOf(alice) - before, PAY - cost - 2000e6 - usdgSlice);
        assertEq(usdg.balanceOf(address(gw)), gw.revenue());
    }

    function test_fill_smallerSlice_refundsOwedInKind() public {
        _queue();
        _restock(tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(keeper);
        gw.fill(1, sw, NAV_SHARES / 2);
        assertApproxEqAbs(tsla.balanceOf(alice), tslaNeed - tslaNeed / 2, 1);
        assertGt(net.balanceOf(alice), 0);
    }

    function test_fill_byReceiver() public {
        _queue();
        _restock(tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        gw.fill(1, sw, NAV_SHARES);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Filled));
    }

    function test_fill_guards() public {
        _queue();
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(keeper);
        vm.expectRevert(IFundMintGateway.InsufficientStock.selector);
        gw.fill(1, sw, NAV_SHARES);
        _restock(tslaNeed);
        vm.prank(bob);
        vm.expectRevert(IFundMintGateway.NotKeeper.selector);
        gw.fill(1, sw, NAV_SHARES);
        vm.prank(keeper);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.fill(1, sw, NAV_SHARES + 1);
        vm.prank(keeper);
        vm.expectRevert(IFundMintGateway.NotQueued.selector);
        gw.fill(2, sw, NAV_SHARES);
    }

    function test_cancel_afterMaxWait_refundsAll() public {
        _queue();
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.TooEarly.selector);
        gw.cancel(1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert(IFundMintGateway.NotReceiver.selector);
        gw.cancel(1);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        gw.cancel(1);
        assertEq(usdg.balanceOf(alice) - before, PAY);
        assertEq(gw.revenue(), 0);
        assertEq(gw.queuedUsdg(), 0);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Cancelled));
    }

    function test_cancel_revenueBridged_releasesUsdg_thenInKind() public {
        _queue();
        uint256 rev = gw.revenue();
        vm.prank(keeper);
        gw.bridgeRevenue(rev, rev - 1e6, uint32(block.timestamp));
        vm.warp(block.timestamp + 1 days);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        gw.cancel(1);
        assertEq(usdg.balanceOf(alice) - before, PAY - rev, "order USDG back");
        assertEq(gw.queuedUsdg(), 0);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Queued), "prepaid part still open");
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.InsufficientRevenue.selector);
        gw.cancel(1);

        _restock(tslaNeed);
        vm.prank(alice);
        gw.cancel(1);
        assertEq(tsla.balanceOf(alice), tslaNeed, "prepaid stock in kind");
        assertEq(gw.stock(address(tsla)), 0);
        assertEq(gw.reserved(address(tsla)), 0);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Cancelled));
    }

    function test_cancel_stockCovers_paysInKind() public {
        _queue();
        _restock(tslaNeed);
        uint256 rev = gw.revenue();
        vm.warp(block.timestamp + 1 days);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        gw.cancel(1);
        assertEq(usdg.balanceOf(alice) - before, PAY - rev, "only the order USDG");
        assertEq(tsla.balanceOf(alice), tslaNeed, "owed stock in kind");
        assertEq(gw.revenue(), rev, "Own keeps the prepaid");
        assertEq(gw.reserved(address(tsla)), 0);
    }

    function test_mint_queuedMinAboveQuote_reverts() public {
        (uint256 quoted,,,,) = fund.previewMint(NAV_SHARES, false);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.Slippage.selector);
        gw.mint(address(fund), PAY, sw, NAV_SHARES, quoted + 1, false);
    }

    function test_fill_receiverPartial_reverts() public {
        _queue();
        _restock(tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.fill(1, sw, 1);
    }

    function test_queuedStock_reservedFromNewMints() public {
        _queue();
        assertEq(gw.reserved(address(tsla)), tslaNeed);
        _restock(tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        (, uint256 id) = gw.mint(address(fund), PAY, sw, NAV_SHARES, 1, false);
        assertEq(id, 2, "second mint queues instead of taking the first order's stock");
        assertEq(gw.reserved(address(tsla)), 2 * tslaNeed);
        vm.prank(keeper);
        gw.fill(1, sw, NAV_SHARES);
        assertEq(gw.reserved(address(tsla)), tslaNeed);

        vm.startPrank(safe);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setBaseAsset(address(tsla), false);
        vm.stopPrank();
    }

    function test_removeStock_keepsReserved() public {
        _queue();
        _stock(tslaNeed);
        vm.prank(safe);
        vm.expectRevert(IFundMintGateway.InsufficientStock.selector);
        gw.removeStock(address(tsla), 1, bob);
        _stock(5);
        vm.prank(safe);
        gw.removeStock(address(tsla), 5, bob);
    }

    function test_zapDonation_doesNotBlockMint() public {
        _stock(10e18);
        (,, uint256[] memory amounts,,) = fund.previewMint(NAV_SHARES, false);
        net.mint(address(zap), amounts[0] * 2);
        usdg.mint(address(zap), 10_000e6);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        (uint256 shares,) = gw.mint(address(fund), PAY, sw, NAV_SHARES, 1, false);
        assertGt(shares, 0);
        assertEq(net.balanceOf(alice), amounts[0] * 2, "donation passed on");
        assertEq(net.balanceOf(address(zap)), 0);
    }

    function test_ccipReceive_insideSwap_reverts() public {
        _stock(10e18);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        bytes memory deliver = abi.encodeCall(
            MockCcipRouter.deliverFrom,
            (keccak256("mid"), BASE, address(gw), address(tsla), 1e18, abi.encode(baseGateway), bytes(""))
        );
        IFundMintGateway.Swap[] memory all = new IFundMintGateway.Swap[](3);
        all[0] = sw[0];
        all[1] = sw[1];
        all[2] = IFundMintGateway.Swap({
            router: address(router),
            tokenIn: address(usdg),
            amountIn: 0,
            data: abi.encodeCall(MockSwapRouter.callThenPull, (address(ccip), deliver, address(tsla), alice))
        });
        vm.prank(alice);
        gw.mint(address(fund), PAY, all, NAV_SHARES, 1, false);
        assertGt(router.lastCallError().length, 0, "restock re-entry refused");
        assertEq(gw.stock(address(tsla)), 10e18 - tslaNeed);
        assertEq(tsla.balanceOf(address(gw)), gw.stock(address(tsla)));
    }

    // ---------------------------------------------------------------- restock and revenue

    function test_ccipReceive_onlyFromBaseGateway() public {
        ccip.deliverFrom(keccak256("a"), BASE, address(gw), address(tsla), 1e18, abi.encode(bob), "");
        assertEq(gw.stock(address(tsla)), 0, "wrong sender ignored");
        ccip.deliverFrom(keccak256("b"), 1, address(gw), address(tsla), 1e18, abi.encode(baseGateway), "");
        assertEq(gw.stock(address(tsla)), 0, "wrong chain ignored");
        _restock(2e18);
        assertEq(gw.stock(address(tsla)), 2e18);
    }

    function test_ccipReceive_nonStockAsset_ignored() public {
        pons.mint(address(ccip), 1e18);
        ccip.deliverFrom(keccak256("a"), BASE, address(gw), address(pons), 1e18, abi.encode(baseGateway), "");
        assertEq(gw.stock(address(pons)), 0);
        vm.prank(safe);
        gw.sweep(address(pons), safe);
        assertEq(pons.balanceOf(safe), 1e18);
    }

    function test_ccipReceive_notRouter_reverts() public {
        CcipClient.Any2EVMMessage memory m;
        vm.expectRevert(IFundMintGateway.NotRouter.selector);
        gw.ccipReceive(m);
    }

    function test_bridgeRevenue_depositsToBaseGateway() public {
        _queue();
        uint256 rev = gw.revenue();
        vm.warp(5000);
        vm.prank(keeper);
        gw.bridgeRevenue(rev, rev - 1e6, 4990);
        MockAcrossSpokePool.Deposit memory d = spoke.lastDeposit();
        assertEq(d.depositor, safe, "an unfilled bridge refunds the owner");
        assertEq(d.recipient, baseFloat);
        assertEq(d.inputToken, address(usdg));
        assertEq(d.outputToken, baseUsdc);
        assertEq(d.inputAmount, rev);
        assertEq(d.outputAmount, rev - 1e6);
        assertEq(d.destinationChainId, 8453);
        assertEq(d.fillDeadline, 5000 + 4 hours);
        assertEq(gw.revenue(), 0);
        assertEq(usdg.balanceOf(address(gw)), gw.queuedUsdg());
    }

    function test_bridgeRevenue_guards() public {
        _queue();
        uint256 rev = gw.revenue();
        vm.prank(bob);
        vm.expectRevert(IFundMintGateway.NotKeeper.selector);
        gw.bridgeRevenue(rev, rev, 0);
        vm.startPrank(keeper);
        vm.expectRevert(IFundMintGateway.InsufficientRevenue.selector);
        gw.bridgeRevenue(rev + 1, rev, 0);
        vm.expectRevert(IFundMintGateway.BridgeFeeTooHigh.selector);
        gw.bridgeRevenue(rev, rev + 1, 0);
        vm.expectRevert(IFundMintGateway.BridgeFeeTooHigh.selector);
        gw.bridgeRevenue(rev, rev - 3e6, 0);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.bridgeRevenue(2e6, 0, 0);
        vm.stopPrank();
    }

    function test_syncRevenue_countsRefunds() public {
        _queue();
        uint256 rev = gw.revenue();
        usdg.mint(address(gw), 10e6);
        vm.prank(keeper);
        gw.syncRevenue();
        assertEq(gw.revenue(), rev + 10e6);
        vm.prank(bob);
        vm.expectRevert(IFundMintGateway.NotKeeper.selector);
        gw.syncRevenue();
    }

    // ---------------------------------------------------------------- owner

    function test_owner_stockAndRevenue() public {
        _stock(5e18);
        vm.startPrank(safe);
        gw.removeStock(address(tsla), 2e18, bob);
        vm.expectRevert(IFundMintGateway.InsufficientStock.selector);
        gw.removeStock(address(tsla), 4e18, bob);
        vm.stopPrank();
        assertEq(tsla.balanceOf(bob), 2e18);
        assertEq(gw.stock(address(tsla)), 3e18);

        _queue2();
        uint256 rev = gw.revenue();
        vm.prank(safe);
        gw.withdrawRevenue(rev, bob);
        assertEq(usdg.balanceOf(bob), rev);
        vm.prank(safe);
        vm.expectRevert(IFundMintGateway.InsufficientRevenue.selector);
        gw.withdrawRevenue(1, bob);
    }

    function test_owner_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        gw.addStock(address(tsla), 1);
        vm.expectRevert(err);
        gw.removeStock(address(tsla), 1, alice);
        vm.expectRevert(err);
        gw.withdrawRevenue(1, alice);
        vm.expectRevert(err);
        gw.sweep(address(tsla), alice);
        vm.expectRevert(err);
        gw.setKeeper(alice, true);
        vm.expectRevert(err);
        gw.setBaseAsset(address(net), true);
        vm.expectRevert(err);
        gw.setSettings(0, 1 days, 0, 0, 1 hours);
        vm.stopPrank();
    }

    function test_owner_settingsBounds() public {
        vm.startPrank(safe);
        gw.setSettings(100, 2 hours, 20, 1e6, 1 hours);
        assertEq(gw.markupBps(), 100);
        assertEq(gw.maxWait(), 2 hours);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setSettings(501, 2 hours, 20, 1e6, 1 hours);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setSettings(100, 59 minutes, 20, 1e6, 1 hours);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setSettings(100, 8 days, 20, 1e6, 1 hours);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setSettings(100, 2 hours, 1001, 1e6, 1 hours);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setSettings(100, 2 hours, 20, 1e6, 9 minutes);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setSettings(100, 2 hours, 20, 1e6, 7 hours);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setBaseAsset(address(usdg), true);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.addStock(address(net), 1);
        vm.stopPrank();
        _stock(1e18);
        vm.prank(safe);
        vm.expectRevert(IFundMintGateway.InvalidParam.selector);
        gw.setBaseAsset(address(tsla), false);
    }

    function test_stockCost_oraclePlusMarkup() public view {
        assertEq(gw.stockCost(address(tsla), 1e18), 401.2e6); // $400 + 0.3%
    }

    function test_constructor_zero_reverts() public {
        vm.expectRevert(IFundMintGateway.ZeroAddress.selector);
        new FundMintGateway(
            address(0), address(zap), address(ccip), BASE, baseGateway, baseFloat, address(spoke), baseUsdc, 8453
        );
    }

    function test_supportsInterface() public view {
        assertTrue(gw.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(gw.supportsInterface(type(IERC165).interfaceId));
        assertFalse(gw.supportsInterface(0xdeadbeef));
    }

    // ---------------------------------------------------------------- pass 3 fixes

    function test_cancel_byKeeper_anyTime_refundsReceiver() public {
        _queue();
        uint256 before = usdg.balanceOf(alice);
        vm.prank(keeper);
        gw.cancel(1);
        assertEq(usdg.balanceOf(alice) - before, PAY);
        assertEq(gw.revenue(), 0);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Cancelled));
    }

    function test_cancel_zeroUsdgOrder_byKeeper() public {
        uint256 cost = gw.stockCost(address(tsla), tslaNeed);
        IFundMintGateway.Swap[] memory sw;
        vm.prank(alice);
        (, uint256 id) = gw.mint(address(fund), cost, sw, NAV_SHARES, 1, false);
        assertEq(gw.getOrder(id).usdg, 0);
        assertEq(gw.reserved(address(tsla)), tslaNeed);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(keeper);
        gw.cancel(id);
        assertEq(usdg.balanceOf(alice) - before, cost);
        assertEq(gw.reserved(address(tsla)), 0);
        vm.prank(safe);
        gw.setBaseAsset(address(tsla), false);
    }

    function test_cancel_refundCappedAtTodaysPrice() public {
        _queue();
        uint256 prepaid = gw.getOrder(1).prepaid;
        _setFeed(address(tsla), 200e8);
        uint256 worth = gw.stockCost(address(tsla), tslaNeed);
        assertLt(worth, prepaid);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(keeper);
        gw.cancel(1);
        assertEq(usdg.balanceOf(alice) - before, PAY - prepaid + worth);
        assertEq(gw.revenue(), prepaid - worth, "Own keeps the price drop");
    }

    function test_fill_byReceiver_needsStockForEveryReservation() public {
        _queue();
        _queue();
        assertEq(gw.reserved(address(tsla)), 2 * tslaNeed);
        _restock(tslaNeed);
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.InsufficientStock.selector);
        gw.fill(2, sw, NAV_SHARES);
        vm.prank(keeper);
        gw.fill(1, sw, NAV_SHARES);
        assertEq(uint8(gw.getOrder(1).status), uint8(IFundMintGateway.Status.Filled));
    }

    function test_fill_keeperPartial_spendsOnlyItsShare() public {
        _queue();
        _restock(tslaNeed);
        uint256 budget = gw.getOrder(1).usdg / 2;
        (,, uint256[] memory amounts,,) = fund.previewMint(NAV_SHARES / 2, false);
        IFundMintGateway.Swap[] memory sw = new IFundMintGateway.Swap[](1);
        sw[0] = IFundMintGateway.Swap({
            router: address(router),
            tokenIn: address(usdg),
            amountIn: budget + 1,
            data: abi.encodeCall(MockSwapRouter.swap, (address(usdg), budget + 1, address(net), amounts[0]))
        });
        vm.prank(keeper);
        vm.expectRevert(IFundMintGateway.InsufficientUsdg.selector);
        gw.fill(1, sw, NAV_SHARES / 2);

        uint256 before = usdg.balanceOf(alice);
        sw = _swaps(0);
        vm.prank(keeper);
        gw.fill(1, sw, NAV_SHARES / 2);
        assertGe(usdg.balanceOf(alice) - before, gw.getOrder(1).usdg - budget);
        assertEq(gw.queuedUsdg(), 0);
    }

    function test_bridgeRevenue_maxBridgesAll() public {
        _queue();
        uint256 rev = gw.revenue();
        vm.prank(keeper);
        gw.bridgeRevenue(type(uint256).max, rev - 1e6, uint32(block.timestamp));
        assertEq(spoke.lastDeposit().inputAmount, rev);
        assertEq(gw.revenue(), 0);
    }

    function test_mint_usdgOrBaseAssetAsRouter_reverts() public {
        _stock(10e18);
        vm.startPrank(admin);
        factory.setRouter(address(usdg), true);
        factory.setRouter(address(tsla), true);
        vm.stopPrank();
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        sw[0].router = address(usdg);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.RouterNotAllowed.selector);
        gw.mint(address(fund), PAY, sw, NAV_SHARES, 0, false);
        sw[0].router = address(tsla);
        vm.prank(alice);
        vm.expectRevert(IFundMintGateway.RouterNotAllowed.selector);
        gw.mint(address(fund), PAY, sw, NAV_SHARES, 0, false);
    }

    // ---------------------------------------------------------------- upgrades

    function test_initialize_once() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gw.initialize(alice);
        FundMintGateway impl = new FundMintGateway(
            address(factory), address(zap), address(ccip), BASE, baseGateway, baseFloat, address(spoke), baseUsdc, 8453
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(alice);
        assertEq(gw.owner(), safe);
        assertEq(gw.markupBps(), 30);
        assertEq(gw.maxWait(), 1 days);
    }

    function test_upgrade_onlyOwner_keepsState() public {
        _queue();
        FundMintGateway impl = new FundMintGateway(
            address(factory), address(zap), address(ccip), BASE, baseGateway, baseFloat, address(spoke), baseUsdc, 8453
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gw.upgradeToAndCall(address(impl), "");
        uint256 rev = gw.revenue();
        vm.prank(safe);
        gw.upgradeToAndCall(address(impl), "");
        assertEq(address(uint160(uint256(vm.load(address(gw), IMPL_SLOT)))), address(impl));
        assertEq(gw.revenue(), rev);
        assertEq(gw.getOrder(1).receiver, alice);
        assertEq(gw.reserved(address(tsla)), tslaNeed);
        assertEq(gw.owner(), safe);
    }

    // ---------------------------------------------------------------- helpers

    function _stock(
        uint256 amount
    ) internal {
        tsla.mint(safe, amount);
        vm.startPrank(safe);
        tsla.approve(address(gw), amount);
        gw.addStock(address(tsla), amount);
        vm.stopPrank();
    }

    function _restock(
        uint256 amount
    ) internal {
        ccip.deliverFrom(
            keccak256(abi.encode(amount)), BASE, address(gw), address(tsla), amount, abi.encode(baseGateway), ""
        );
    }

    function _queue() internal {
        IFundMintGateway.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        gw.mint(address(fund), PAY, sw, NAV_SHARES, 1, false);
    }

    function _queue2() internal {
        // Stock is 3e18 here, so this needs more than the stock to queue.
        IFundMintGateway.Swap[] memory sw;
        vm.prank(alice);
        gw.mint(address(fund), 50_000e6, sw, NAV_SHARES * 10, 1, false);
    }

    /// @dev USDG -> NET and PONS, `extra` on top of what the slice needs, 1000 USDG per swap.
    function _swaps(
        uint256 extra
    ) internal view returns (IFundMintGateway.Swap[] memory swaps) {
        (,, uint256[] memory amounts,,) = fund.previewMint(NAV_SHARES, false);
        address[] memory a = fund.assets();
        swaps = new IFundMintGateway.Swap[](2);
        for (uint256 i; i < 2; ++i) {
            swaps[i] = IFundMintGateway.Swap({
                router: address(router),
                tokenIn: address(usdg),
                amountIn: 1000e6,
                data: abi.encodeCall(MockSwapRouter.swap, (address(usdg), 1000e6, a[i], amounts[i] + extra))
            });
        }
    }
}
