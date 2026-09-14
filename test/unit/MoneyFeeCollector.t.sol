// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMoneyFeeCollector} from "../../src/interfaces/IMoneyFeeCollector.sol";
import {MoneyFeeCollector} from "../../src/periphery/MoneyFeeCollector.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockMoney} from "../helpers/MockMoney.sol";
import {MockPonsFeeEscrow} from "../helpers/MockPonsFeeEscrow.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Native-rejecting payee for the NativeTransferFailed path.
contract RejectingPayee {}

contract MoneyFeeCollectorTest is Test {
    MockPonsFeeEscrow internal escrow;
    MockMoney internal money;
    MockERC20 internal usdg; // 6-decimals fee asset
    MockERC20 internal spy; // 18-decimals fee asset
    MockSwapRouter internal router;
    MoneyFeeCollector internal collector;

    address internal safe = Actors.ADMIN;
    address internal keeper = address(uint160(uint256(keccak256("keeper"))));
    address internal payeeA = address(uint160(uint256(keccak256("payeeA"))));
    address internal payeeB = address(uint160(uint256(keccak256("payeeB"))));
    address internal attacker = Actors.ATTACKER;

    uint256 internal constant BPS = 10_000;

    function setUp() public {
        vm.warp(1_000_000);

        escrow = new MockPonsFeeEscrow();
        money = new MockMoney();
        usdg = new MockERC20("USDG", "USDG", 6);
        spy = new MockERC20("SPY", "SPY", 18);
        router = new MockSwapRouter();
        money.mint(address(router), 1_000_000e18);

        collector = _deployCollector(safe, address(escrow), address(money), keeper, _defaultPayees());

        vm.prank(safe);
        collector.setSwapTarget(address(router), true);
    }

    // ── Helpers ───────────────────────────────────────────────

    function _defaultPayees() internal view returns (IMoneyFeeCollector.Payee[] memory p) {
        p = new IMoneyFeeCollector.Payee[](2);
        p[0] = IMoneyFeeCollector.Payee(payeeA, 6000);
        p[1] = IMoneyFeeCollector.Payee(payeeB, 4000);
    }

    function _deployCollector(
        address owner_,
        address escrow_,
        address money_,
        address keeper_,
        IMoneyFeeCollector.Payee[] memory payees_
    ) internal returns (MoneyFeeCollector) {
        MoneyFeeCollector impl = new MoneyFeeCollector();
        return MoneyFeeCollector(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(MoneyFeeCollector.initialize, (owner_, escrow_, money_, keeper_, payees_))
                    )
                )
            )
        );
    }

    function _creditToken(MockERC20 token, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(escrow), amount);
        escrow.creditToken(address(collector), address(token), amount);
    }

    function _creditNative(
        uint256 amount
    ) internal {
        vm.deal(address(this), amount);
        escrow.credit{value: amount}(address(collector));
    }

    function _tokens1(
        address t
    ) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = t;
    }

    // ── initialize ────────────────────────────────────────────

    function test_initialize_setsConfig() public view {
        assertEq(collector.owner(), safe);
        assertEq(collector.escrow(), address(escrow));
        assertEq(collector.money(), address(money));
        assertEq(collector.burnShareBps(), 3000);
        assertEq(collector.burnInterval(), 1 hours);
        assertEq(collector.lastBurnAt(), 0);
        assertTrue(collector.isKeeper(keeper));
        IMoneyFeeCollector.Payee[] memory p = collector.payees();
        assertEq(p.length, 2);
        assertEq(p[0].account, payeeA);
        assertEq(p[0].shareBps, 6000);
        assertEq(p[1].account, payeeB);
        assertEq(p[1].shareBps, 4000);
    }

    function test_initialize_zeroAddresses_revert() public {
        IMoneyFeeCollector.Payee[] memory none = new IMoneyFeeCollector.Payee[](0);
        MoneyFeeCollector impl = new MoneyFeeCollector();

        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(MoneyFeeCollector.initialize, (address(0), address(escrow), address(money), keeper, none))
        );
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(MoneyFeeCollector.initialize, (safe, address(0), address(money), keeper, none))
        );
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(MoneyFeeCollector.initialize, (safe, address(escrow), address(0), keeper, none))
        );
    }

    function test_initialize_zeroKeeperAndEmptyPayees_allowed() public {
        IMoneyFeeCollector.Payee[] memory none = new IMoneyFeeCollector.Payee[](0);
        MoneyFeeCollector c = _deployCollector(safe, address(escrow), address(money), address(0), none);
        assertFalse(c.isKeeper(address(0)));
        assertEq(c.payees().length, 0);
    }

    function test_initialize_twice_reverts() public {
        IMoneyFeeCollector.Payee[] memory none = new IMoneyFeeCollector.Payee[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collector.initialize(safe, address(escrow), address(money), keeper, none);
    }

    function test_implementation_initializersDisabled() public {
        MoneyFeeCollector impl = new MoneyFeeCollector();
        IMoneyFeeCollector.Payee[] memory none = new IMoneyFeeCollector.Payee[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(safe, address(escrow), address(money), keeper, none);
    }

    // ── collectFees ───────────────────────────────────────────

    function test_collectFees_erc20_splits30_70() public {
        _creditToken(usdg, 1000e6);

        address[] memory tokens = _tokens1(address(usdg));
        vm.expectEmit(true, false, false, true);
        emit IMoneyFeeCollector.FeesCollected(address(usdg), 1000e6, 300e6);
        vm.prank(attacker); // permissionless trigger
        collector.collectFees(tokens);

        assertEq(usdg.balanceOf(address(collector)), 300e6, "30% retained for burns");
        assertEq(usdg.balanceOf(payeeA), 420e6, "60% of the 70%");
        assertEq(usdg.balanceOf(payeeB), 280e6, "40% of the 70%");
        assertEq(collector.claimableFees(address(usdg)), 0);
    }

    function test_collectFees_native_splits30_70() public {
        _creditNative(10 ether);

        collector.collectFees(new address[](0));

        assertEq(address(collector).balance, 3 ether);
        assertEq(payeeA.balance, 4.2 ether);
        assertEq(payeeB.balance, 2.8 ether);
    }

    function test_collectFees_multipleAssetsInOneCall() public {
        _creditNative(1 ether);
        _creditToken(usdg, 100e6);
        _creditToken(spy, 50e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdg);
        tokens[1] = address(spy);
        collector.collectFees(tokens);

        assertEq(address(collector).balance, 0.3 ether);
        assertEq(usdg.balanceOf(address(collector)), 30e6);
        assertEq(spy.balanceOf(address(collector)), 15e18);
    }

    function test_collectFees_nothingAccrued_noop() public {
        collector.collectFees(_tokens1(address(usdg)));
        assertEq(usdg.balanceOf(payeeA), 0);
        assertEq(address(collector).balance, 0);
    }

    function test_collectFees_zeroTokenAddress_reverts() public {
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        collector.collectFees(_tokens1(address(0)));
    }

    function test_collectFees_duplicateTokenListed_claimsOnce() public {
        _creditToken(usdg, 100e6);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdg);
        tokens[1] = address(usdg);
        collector.collectFees(tokens);
        assertEq(usdg.balanceOf(address(collector)), 30e6);
        assertEq(usdg.balanceOf(payeeA), 42e6);
    }

    function test_collectFees_seedIsNeverSplit() public {
        // Direct transfers in (seeds) are burn reserve; only escrow claims are split.
        usdg.mint(address(collector), 500e6);
        vm.deal(address(collector), 5 ether);
        _creditToken(usdg, 100e6);
        _creditNative(1 ether);

        collector.collectFees(_tokens1(address(usdg)));

        assertEq(usdg.balanceOf(address(collector)), 500e6 + 30e6, "seed untouched");
        assertEq(address(collector).balance, 5 ether + 0.3 ether, "native seed untouched");
        assertEq(usdg.balanceOf(payeeA), 42e6);
        assertEq(payeeA.balance, 0.42 ether);
    }

    function test_collectFees_burnShareRoundsUp() public {
        // 101 wei: distributable = 101 * 7000 / 10000 = 70 (floor) -> burn share 31 (rounded up).
        _creditToken(usdg, 101);
        collector.collectFees(_tokens1(address(usdg)));
        assertEq(usdg.balanceOf(address(collector)), 31);
        // Last payee takes the remainder: A = 70*6000/10000 = 42, B = 70 - 42 = 28.
        assertEq(usdg.balanceOf(payeeA), 42);
        assertEq(usdg.balanceOf(payeeB), 28);
    }

    function test_collectFees_fullBurnShare_needsNoPayees() public {
        IMoneyFeeCollector.Payee[] memory none = new IMoneyFeeCollector.Payee[](0);
        MoneyFeeCollector c = _deployCollector(safe, address(escrow), address(money), keeper, none);
        vm.prank(safe);
        c.setBurnShareBps(BPS);

        usdg.mint(address(this), 100e6);
        usdg.approve(address(escrow), 100e6);
        escrow.creditToken(address(c), address(usdg), 100e6);
        c.collectFees(_tokens1(address(usdg)));

        assertEq(usdg.balanceOf(address(c)), 100e6, "everything retained");
    }

    function test_collectFees_payeesNotConfigured_reverts() public {
        IMoneyFeeCollector.Payee[] memory none = new IMoneyFeeCollector.Payee[](0);
        MoneyFeeCollector c = _deployCollector(safe, address(escrow), address(money), keeper, none);

        usdg.mint(address(this), 100e6);
        usdg.approve(address(escrow), 100e6);
        escrow.creditToken(address(c), address(usdg), 100e6);

        vm.expectRevert(IMoneyFeeCollector.PayeesNotConfigured.selector);
        c.collectFees(_tokens1(address(usdg)));
    }

    function test_collectFees_rejectingNativePayee_reverts() public {
        IMoneyFeeCollector.Payee[] memory p = new IMoneyFeeCollector.Payee[](1);
        address rejecting = address(new RejectingPayee());
        p[0] = IMoneyFeeCollector.Payee(rejecting, uint96(BPS));
        vm.prank(safe);
        collector.setPayees(p);

        _creditNative(1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMoneyFeeCollector.NativeTransferFailed.selector, rejecting));
        collector.collectFees(new address[](0));
    }

    function test_collectFees_distributesExactly() public {
        // Sum of payouts + burn reserve must equal the claimed amount to the wei.
        IMoneyFeeCollector.Payee[] memory p = new IMoneyFeeCollector.Payee[](3);
        p[0] = IMoneyFeeCollector.Payee(payeeA, 3333);
        p[1] = IMoneyFeeCollector.Payee(payeeB, 3333);
        address payeeC = address(uint160(uint256(keccak256("payeeC"))));
        p[2] = IMoneyFeeCollector.Payee(payeeC, 3334);
        vm.prank(safe);
        collector.setPayees(p);

        uint256 amount = 999_999_999_999_999_999;
        _creditToken(spy, amount);
        collector.collectFees(_tokens1(address(spy)));

        uint256 sum =
            spy.balanceOf(address(collector)) + spy.balanceOf(payeeA) + spy.balanceOf(payeeB) + spy.balanceOf(payeeC);
        assertEq(sum, amount, "no wei lost");
        assertEq(spy.balanceOf(address(escrow)), 0);
    }

    // ── buyAndBurn ────────────────────────────────────────────

    function test_buyAndBurn_erc20_swapsAndBurns() public {
        usdg.mint(address(collector), 300e6);
        uint256 supplyBefore = money.totalSupply();

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (address(usdg), 300e6, address(money), 1000e18));
        vm.expectEmit(true, false, false, true);
        emit IMoneyFeeCollector.MoneyBurned(address(usdg), 300e6, 1000e18);
        vm.prank(keeper);
        uint256 burned = collector.buyAndBurn(address(usdg), 300e6, address(router), data, 900e18);

        assertEq(burned, 1000e18);
        assertEq(money.totalSupply(), supplyBefore - 1000e18, "supply reduced");
        assertEq(money.balanceOf(address(collector)), 0);
        assertEq(usdg.balanceOf(address(collector)), 0);
        assertEq(usdg.allowance(address(collector), address(router)), 0, "no dangling allowance");
        assertEq(collector.lastBurnAt(), block.timestamp);
    }

    function test_buyAndBurn_native_swapsAndBurns() public {
        vm.deal(address(collector), 3 ether);
        uint256 supplyBefore = money.totalSupply();

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (address(0), 3 ether, address(money), 500e18));
        vm.prank(keeper);
        uint256 burned = collector.buyAndBurn(address(0), 3 ether, address(router), data, 500e18);

        assertEq(burned, 500e18);
        assertEq(money.totalSupply(), supplyBefore - 500e18);
        assertEq(address(collector).balance, 0);
    }

    function test_buyAndBurn_sweepsHeldMoneyDust() public {
        money.mint(address(collector), 7e18); // donation / prior swap dust
        usdg.mint(address(collector), 100e6);

        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (address(usdg), 100e6, address(money), 100e18));
        vm.prank(keeper);
        uint256 burned = collector.buyAndBurn(address(usdg), 100e6, address(router), data, 100e18);

        assertEq(burned, 107e18, "held dust burned too");
        assertEq(money.balanceOf(address(collector)), 0);
    }

    function test_buyAndBurn_directMoneyBurn() public {
        money.mint(address(collector), 50e18);
        uint256 supplyBefore = money.totalSupply();

        vm.prank(keeper);
        uint256 burned = collector.buyAndBurn(address(money), 50e18, address(0), "", 0);

        assertEq(burned, 50e18);
        assertEq(money.totalSupply(), supplyBefore - 50e18);
    }

    function test_buyAndBurn_directMoneyBurn_withSwapParams_reverts() public {
        money.mint(address(collector), 50e18);
        vm.startPrank(keeper);
        vm.expectRevert(IMoneyFeeCollector.InvalidSwapParams.selector);
        collector.buyAndBurn(address(money), 50e18, address(router), "", 0);
        vm.expectRevert(IMoneyFeeCollector.InvalidSwapParams.selector);
        collector.buyAndBurn(address(money), 50e18, address(0), hex"01", 0);
        vm.expectRevert(IMoneyFeeCollector.InvalidSwapParams.selector);
        collector.buyAndBurn(address(money), 50e18, address(0), "", 1);
        vm.stopPrank();
    }

    function test_buyAndBurn_notKeeper_reverts() public {
        vm.expectRevert(IMoneyFeeCollector.NotKeeper.selector);
        vm.prank(attacker);
        collector.buyAndBurn(address(usdg), 1, address(router), "", 1);
    }

    function test_buyAndBurn_intervalEnforced() public {
        money.mint(address(collector), 100e18);

        vm.prank(keeper);
        collector.buyAndBurn(address(money), 50e18, address(0), "", 0);

        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert(IMoneyFeeCollector.BurnIntervalNotElapsed.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(money), 50e18, address(0), "", 0);

        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        collector.buyAndBurn(address(money), 50e18, address(0), "", 0);
    }

    function test_buyAndBurn_zeroAmount_reverts() public {
        vm.expectRevert(IMoneyFeeCollector.ZeroAmount.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 0, address(router), "", 1);
    }

    function test_buyAndBurn_zeroMinOut_reverts() public {
        usdg.mint(address(collector), 100e6);
        vm.expectRevert(IMoneyFeeCollector.ZeroAmount.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 100e6, address(router), "", 0);
    }

    function test_buyAndBurn_unlistedTarget_reverts() public {
        MockSwapRouter rogue = new MockSwapRouter();
        vm.expectRevert(IMoneyFeeCollector.SwapTargetNotAllowed.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 1, address(rogue), "", 1);
    }

    function test_buyAndBurn_insufficientOut_reverts() public {
        usdg.mint(address(collector), 100e6);
        bytes memory data = abi.encodeCall(MockSwapRouter.swap, (address(usdg), 100e6, address(money), 10e18));
        vm.expectRevert(abi.encodeWithSelector(IMoneyFeeCollector.InsufficientMoneyOut.selector, 10e18, 11e18));
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 100e6, address(router), data, 11e18);
    }

    function test_buyAndBurn_totalLossFill_reverts() public {
        usdg.mint(address(collector), 100e6);
        bytes memory data = abi.encodeCall(MockSwapRouter.swapAndKeep, (address(usdg), 100e6));
        vm.expectRevert(abi.encodeWithSelector(IMoneyFeeCollector.InsufficientMoneyOut.selector, 0, 1));
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 100e6, address(router), data, 1);
    }

    function test_buyAndBurn_swapReverts_bubbles() public {
        usdg.mint(address(collector), 100e6);
        bytes memory data = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.expectRevert(IMoneyFeeCollector.SwapFailed.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 100e6, address(router), data, 1);
    }

    // ── owner configuration ───────────────────────────────────

    function test_setPayees_replacesSet() public {
        IMoneyFeeCollector.Payee[] memory p = new IMoneyFeeCollector.Payee[](1);
        p[0] = IMoneyFeeCollector.Payee(payeeB, uint96(BPS));
        vm.prank(safe);
        collector.setPayees(p);

        IMoneyFeeCollector.Payee[] memory got = collector.payees();
        assertEq(got.length, 1);
        assertEq(got[0].account, payeeB);
        assertEq(got[0].shareBps, BPS);
    }

    function test_setPayees_validation() public {
        vm.startPrank(safe);

        IMoneyFeeCollector.Payee[] memory bad = new IMoneyFeeCollector.Payee[](1);
        bad[0] = IMoneyFeeCollector.Payee(payeeA, 9999);
        vm.expectRevert(IMoneyFeeCollector.InvalidBps.selector);
        collector.setPayees(bad);

        bad[0] = IMoneyFeeCollector.Payee(address(0), uint96(BPS));
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        collector.setPayees(bad);

        IMoneyFeeCollector.Payee[] memory zeroShare = new IMoneyFeeCollector.Payee[](2);
        zeroShare[0] = IMoneyFeeCollector.Payee(payeeA, uint96(BPS));
        zeroShare[1] = IMoneyFeeCollector.Payee(payeeB, 0);
        vm.expectRevert(IMoneyFeeCollector.ZeroAmount.selector);
        collector.setPayees(zeroShare);

        // Empty set is allowed (burn-only mode); collections with a distribution share revert.
        collector.setPayees(new IMoneyFeeCollector.Payee[](0));
        assertEq(collector.payees().length, 0);

        vm.stopPrank();
    }

    function test_setBurnShareBps() public {
        vm.prank(safe);
        collector.setBurnShareBps(5000);
        assertEq(collector.burnShareBps(), 5000);

        _creditToken(usdg, 100e6);
        collector.collectFees(_tokens1(address(usdg)));
        assertEq(usdg.balanceOf(address(collector)), 50e6);

        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.InvalidBps.selector);
        collector.setBurnShareBps(BPS + 1);
    }

    function test_setBurnInterval() public {
        vm.prank(safe);
        collector.setBurnInterval(2 hours);
        assertEq(collector.burnInterval(), 2 hours);
    }

    function test_setKeeper_toggle() public {
        vm.prank(safe);
        collector.setKeeper(keeper, false);
        assertFalse(collector.isKeeper(keeper));

        vm.expectRevert(IMoneyFeeCollector.NotKeeper.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 1, address(router), "", 1);

        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        collector.setKeeper(address(0), true);
    }

    function test_setSwapTarget_toggle() public {
        vm.prank(safe);
        collector.setSwapTarget(address(router), false);
        assertFalse(collector.isSwapTarget(address(router)));

        usdg.mint(address(collector), 100e6);
        vm.expectRevert(IMoneyFeeCollector.SwapTargetNotAllowed.selector);
        vm.prank(keeper);
        collector.buyAndBurn(address(usdg), 100e6, address(router), "", 1);

        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        collector.setSwapTarget(address(0), true);
    }

    function test_setEscrow() public {
        MockPonsFeeEscrow next = new MockPonsFeeEscrow();
        vm.prank(safe);
        collector.setEscrow(address(next));
        assertEq(collector.escrow(), address(next));

        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        collector.setEscrow(address(0));
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setPayees(_defaultPayees());
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setBurnShareBps(0);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setBurnInterval(0);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setKeeper(attacker, true);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setSwapTarget(attacker, true);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setEscrow(attacker);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.execute(address(usdg), 0, "");
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.transferOwnership(attacker);
        vm.stopPrank();
    }

    // ── execute ───────────────────────────────────────────────

    function test_execute_rescuesTokens() public {
        usdg.mint(address(collector), 100e6);
        vm.prank(safe);
        collector.execute(address(usdg), 0, abi.encodeCall(usdg.transfer, (safe, 100e6)));
        assertEq(usdg.balanceOf(safe), 100e6);
    }

    function test_execute_forwardsValue() public {
        vm.deal(address(collector), 1 ether);
        vm.prank(safe);
        collector.execute(payeeA, 1 ether, "");
        assertEq(payeeA.balance, 1 ether);
    }

    function test_execute_revert_bubbles() public {
        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.ExecuteFailed.selector);
        collector.execute(address(usdg), 0, abi.encodeCall(usdg.transfer, (safe, 1)));
    }

    // ── ownership ─────────────────────────────────────────────

    function test_ownership_twoStepTransfer() public {
        address newOwner = address(uint160(uint256(keccak256("newSafe"))));

        vm.prank(safe);
        collector.transferOwnership(newOwner);
        assertEq(collector.owner(), safe, "unchanged until accepted");
        assertEq(collector.pendingOwner(), newOwner);

        vm.expectRevert(IMoneyFeeCollector.NotPendingOwner.selector);
        vm.prank(attacker);
        collector.acceptOwnership();

        vm.prank(newOwner);
        collector.acceptOwnership();
        assertEq(collector.owner(), newOwner);
        assertEq(collector.pendingOwner(), address(0));

        // Old owner is fully locked out.
        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        collector.setBurnShareBps(0);
    }

    function test_transferOwnership_zeroAddress_reverts() public {
        vm.prank(safe);
        vm.expectRevert(IMoneyFeeCollector.ZeroAddress.selector);
        collector.transferOwnership(address(0));
    }

    // ── upgrade ───────────────────────────────────────────────

    function test_upgrade_ownerOnly() public {
        MoneyFeeCollector newImpl = new MoneyFeeCollector();

        vm.expectRevert(IMoneyFeeCollector.NotOwner.selector);
        vm.prank(attacker);
        collector.upgradeToAndCall(address(newImpl), "");

        vm.prank(safe);
        collector.upgradeToAndCall(address(newImpl), "");
        assertEq(collector.owner(), safe, "state survives upgrade");
        assertEq(collector.burnShareBps(), 3000);
    }

    // ── views ─────────────────────────────────────────────────

    function test_claimableFees_views() public {
        _creditNative(2 ether);
        _creditToken(usdg, 100e6);
        assertEq(collector.claimableFees(address(0)), 2 ether);
        assertEq(collector.claimableFees(address(usdg)), 100e6);
        assertEq(collector.claimableFees(address(spy)), 0);
    }
}
