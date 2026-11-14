// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSD} from "../../src/eusd/EUSD.sol";
import {EUSDPsm} from "../../src/eusd/EUSDPsm.sol";
import {IEUSDPsm} from "../../src/interfaces/IEUSDPsm.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Charges 1% on every transfer.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract EUSDPsmTest is BaseTest {
    EUSD internal eusd;
    EUSDPsm internal psm;
    MockERC20 internal usdg; // 6 decimals
    MockERC20 internal frx; // 18 decimals

    address internal admin = Actors.ADMIN;
    address internal alice = address(uint160(uint256(keccak256("alice"))));
    address internal treasury = address(uint160(uint256(keccak256("treasury"))));
    address internal attacker = Actors.ATTACKER;

    uint256 internal constant USDG_CEILING = 1_000_000e18;
    uint256 internal constant FRX_CEILING = 100_000e18;

    function setUp() public override {
        super.setUp();
        eusd = new EUSD(admin);
        psm = _deployPsm();
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(psm));
        usdg = new MockERC20("USDG", "USDG", 6);
        frx = new MockERC20("frxUSD", "frxUSD", 18);
        psm.addAsset(address(usdg), USDG_CEILING, 0, 0);
        psm.addAsset(address(frx), FRX_CEILING, 0, 0);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────

    function _deployPsm() internal returns (EUSDPsm) {
        EUSDPsm impl = new EUSDPsm();
        bytes memory init = abi.encodeCall(EUSDPsm.initialize, (address(protocolRegistry), address(eusd)));
        return EUSDPsm(address(new ERC1967Proxy(address(impl), init)));
    }

    function _mint(address who, MockERC20 asset, uint256 assetIn) internal returns (uint256 out) {
        asset.mint(who, assetIn);
        vm.startPrank(who);
        asset.approve(address(psm), assetIn);
        out = psm.mint(address(asset), assetIn, 0);
        vm.stopPrank();
    }

    function _setFees(address asset, uint16 mintFee, uint16 redeemFee) internal {
        vm.prank(admin);
        psm.setFees(asset, mintFee, redeemFee);
    }

    // ── Initialization and upgrades ───────────────────────────

    function test_initialize_setsState() public view {
        assertEq(address(psm.registry()), address(protocolRegistry));
        assertEq(psm.eusd(), address(eusd));
        assertEq(psm.totalDebt(), 0);
        assertEq(psm.MAX_FEE_BPS(), 100);
    }

    function test_initialize_zeroAddress_reverts() public {
        EUSDPsm impl = new EUSDPsm();
        vm.expectRevert(IEUSDPsm.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(EUSDPsm.initialize, (address(0), address(eusd))));
        vm.expectRevert(IEUSDPsm.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(EUSDPsm.initialize, (address(protocolRegistry), address(0))));
    }

    function test_initialize_twice_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        psm.initialize(address(protocolRegistry), address(eusd));
    }

    function test_initialize_implementation_reverts() public {
        EUSDPsm impl = new EUSDPsm();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(protocolRegistry), address(eusd));
    }

    function test_upgrade_admin_keepsState() public {
        _mint(alice, usdg, 1000e6);
        EUSDPsm next = new EUSDPsm();
        vm.prank(admin);
        psm.upgradeToAndCall(address(next), "");
        assertEq(psm.totalDebt(), 1000e18);
        assertEq(psm.assetConfig(address(usdg)).debt, 1000e18);
    }

    function test_upgrade_notAdmin_reverts() public {
        EUSDPsm next = new EUSDPsm();
        vm.prank(attacker);
        vm.expectRevert(IEUSDPsm.OnlyAdmin.selector);
        psm.upgradeToAndCall(address(next), "");
    }

    // ── addAsset ──────────────────────────────────────────────

    function test_addAsset_listsAsset() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        vm.expectEmit(true, false, false, true, address(psm));
        emit IEUSDPsm.AssetAdded(address(dai), 18, 5e18, 10, 20);
        vm.prank(admin);
        psm.addAsset(address(dai), 5e18, 10, 20);

        IEUSDPsm.AssetConfig memory cfg = psm.assetConfig(address(dai));
        assertTrue(cfg.listed);
        assertFalse(cfg.mintPaused);
        assertEq(cfg.decimals, 18);
        assertEq(cfg.mintFeeBps, 10);
        assertEq(cfg.redeemFeeBps, 20);
        assertEq(cfg.debtCeiling, 5e18);
        assertEq(cfg.debt, 0);
        assertEq(psm.assetCount(), 3);
        assertEq(psm.assetAt(0), address(usdg));
        assertEq(psm.assetAt(1), address(frx));
        assertEq(psm.assetAt(2), address(dai));
    }

    function test_addAsset_notAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IEUSDPsm.OnlyAdmin.selector);
        psm.addAsset(address(1), 0, 0, 0);
    }

    function test_addAsset_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IEUSDPsm.ZeroAddress.selector);
        psm.addAsset(address(0), 0, 0, 0);
    }

    function test_addAsset_eusd_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.UnsupportedAsset.selector, address(eusd)));
        psm.addAsset(address(eusd), 0, 0, 0);
    }

    function test_addAsset_alreadyListed_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetAlreadyListed.selector, address(usdg)));
        psm.addAsset(address(usdg), 0, 0, 0);
    }

    function test_addAsset_feeTooHigh_reverts() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.FeeTooHigh.selector, uint16(101)));
        psm.addAsset(address(dai), 0, 101, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.FeeTooHigh.selector, uint16(101)));
        psm.addAsset(address(dai), 0, 0, 101);
        vm.stopPrank();
    }

    function test_addAsset_tooManyDecimals_reverts() public {
        MockERC20 odd = new MockERC20("ODD", "ODD", 19);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.UnsupportedDecimals.selector, uint8(19)));
        psm.addAsset(address(odd), 0, 0, 0);
    }

    // ── mint ──────────────────────────────────────────────────

    function test_mint_sixDecimals_mintsOneToOne() public {
        usdg.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), 1000e6);
        vm.expectEmit(true, true, false, true, address(psm));
        emit IEUSDPsm.Minted(address(usdg), alice, 1000e6, 1000e18, 0);
        uint256 out = psm.mint(address(usdg), 1000e6, 1000e18);
        vm.stopPrank();

        assertEq(out, 1000e18);
        assertEq(eusd.balanceOf(alice), 1000e18);
        assertEq(usdg.balanceOf(address(psm)), 1000e6);
        assertEq(psm.assetConfig(address(usdg)).debt, 1000e18);
        assertEq(psm.totalDebt(), 1000e18);
    }

    function test_mint_eighteenDecimals_mintsOneToOne() public {
        assertEq(_mint(alice, frx, 5e18), 5e18);
        assertEq(psm.assetConfig(address(frx)).debt, 5e18);
        assertEq(psm.totalDebt(), 5e18);
    }

    function test_mint_withFee_feeStaysAsSurplus() public {
        _setFees(address(usdg), 10, 0); // 0.1%
        uint256 out = _mint(alice, usdg, 1000e6);
        assertEq(out, 999e18);
        assertEq(psm.assetConfig(address(usdg)).debt, 999e18);
        assertEq(psm.surplus(address(usdg)), 1e6);
    }

    function test_mint_feeRoundsUp() public {
        _setFees(address(usdg), 1, 0); // 0.01%
        (uint256 out, uint256 fee) = psm.previewMint(address(usdg), 1);
        assertEq(fee, 1e8);
        assertEq(out, 1e12 - 1e8);
        (, fee) = psm.previewMint(address(frx), 1);
        assertEq(fee, 0);
        _setFees(address(frx), 1, 0);
        (out, fee) = psm.previewMint(address(frx), 1);
        assertEq(fee, 1); // ceil(1 / 10 000)
        assertEq(out, 0);
    }

    function test_mint_belowMinOut_reverts() public {
        usdg.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.InsufficientOutput.selector, 1000e18, 1000e18 + 1));
        psm.mint(address(usdg), 1000e6, 1000e18 + 1);
        vm.stopPrank();
    }

    function test_mint_paused_reverts() public {
        vm.prank(admin);
        psm.setMintPaused(address(usdg), true);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.MintingPaused.selector, address(usdg)));
        psm.mint(address(usdg), 1e6, 0);
    }

    function test_mint_otherAssetPaused_stillMints() public {
        vm.prank(admin);
        psm.setMintPaused(address(frx), true);
        assertEq(_mint(alice, usdg, 1e6), 1e18);
    }

    function test_mint_upToCeiling_succeeds() public {
        assertEq(_mint(alice, frx, FRX_CEILING), FRX_CEILING);
    }

    function test_mint_aboveCeiling_reverts() public {
        _mint(alice, frx, FRX_CEILING);
        frx.mint(alice, 1);
        vm.startPrank(alice);
        frx.approve(address(psm), 1);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.DebtCeilingExceeded.selector, FRX_CEILING + 1, FRX_CEILING));
        psm.mint(address(frx), 1, 0);
        vm.stopPrank();
    }

    function test_mint_ceilingsArePerAsset() public {
        _mint(alice, frx, FRX_CEILING);
        assertEq(_mint(alice, usdg, 200_000e6), 200_000e18);
    }

    function test_mint_notListed_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.mint(address(1), 1, 0);
    }

    function test_mint_zero_reverts() public {
        vm.expectRevert(IEUSDPsm.ZeroAmount.selector);
        psm.mint(address(usdg), 0, 0);
    }

    function test_mint_feeOnTransfer_reverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        vm.prank(admin);
        psm.addAsset(address(fot), USDG_CEILING, 0, 0);
        fot.mint(alice, 100e6);
        vm.startPrank(alice);
        fot.approve(address(psm), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.TransferAmountMismatch.selector, 100e6, 99e6));
        psm.mint(address(fot), 100e6, 0);
        vm.stopPrank();
    }

    function test_mint_withoutMinterRole_reverts() public {
        vm.startPrank(admin);
        eusd.revokeRole(eusd.MINTER_ROLE(), address(psm));
        vm.stopPrank();
        usdg.mint(alice, 1e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), 1e6);
        vm.expectRevert();
        psm.mint(address(usdg), 1e6, 0);
        vm.stopPrank();
    }

    // ── redeem ────────────────────────────────────────────────

    function test_redeem_paysOneToOne() public {
        _mint(alice, usdg, 1000e6);
        vm.expectEmit(true, true, false, true, address(psm));
        emit IEUSDPsm.Redeemed(address(usdg), alice, 400e18, 400e6, 0);
        vm.prank(alice);
        uint256 out = psm.redeem(address(usdg), 400e18, 400e6);

        assertEq(out, 400e6);
        assertEq(usdg.balanceOf(alice), 400e6);
        assertEq(eusd.balanceOf(alice), 600e18);
        assertEq(psm.assetConfig(address(usdg)).debt, 600e18);
        assertEq(psm.totalDebt(), 600e18);
        assertEq(eusd.totalSupply(), 600e18);
    }

    function test_redeem_withFee_feeStaysAsSurplus() public {
        _mint(alice, usdg, 1000e6);
        _setFees(address(usdg), 0, 50); // 0.5%
        vm.prank(alice);
        uint256 out = psm.redeem(address(usdg), 1000e18, 0);
        assertEq(out, 995e6);
        assertEq(psm.assetConfig(address(usdg)).debt, 0);
        assertEq(psm.surplus(address(usdg)), 5e6);
    }

    function test_redeem_dustBelowAssetUnit_keptAsFee() public {
        _mint(alice, usdg, 10e6);
        (uint256 out, uint256 fee) = psm.previewRedeem(address(usdg), 1e18 + 5e11);
        assertEq(out, 1e6);
        assertEq(fee, 5e11);
        vm.prank(alice);
        psm.redeem(address(usdg), 1e18 + 5e11, 0);
        // The half-unit stays in the reserve: debt 8.9999995e18 needs 9e6 rounded up.
        assertEq(usdg.balanceOf(address(psm)), 9e6);
        assertEq(psm.surplus(address(usdg)), 0);
    }

    function test_redeem_aboveAssetDebt_reverts() public {
        _mint(alice, usdg, 1000e6);
        // eUSD minted against USDG cannot drain the frxUSD reserve.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.InsufficientDebt.selector, 1000e18, 0));
        psm.redeem(address(frx), 1000e18, 0);
    }

    function test_redeem_crossAsset_upToThatAssetsDebt() public {
        _mint(alice, frx, 100e18);
        address bob = address(0xb0b);
        _mint(bob, usdg, 300e6);
        // Alice's eUSD (from frxUSD) can take USDG, but only up to USDG's debt.
        vm.prank(alice);
        assertEq(psm.redeem(address(usdg), 100e18, 0), 100e6);
        assertEq(psm.assetConfig(address(usdg)).debt, 200e18);
        assertEq(psm.assetConfig(address(frx)).debt, 100e18);
        assertEq(psm.totalDebt(), 300e18);
    }

    function test_redeem_belowOneUnit_reverts() public {
        _mint(alice, usdg, 1e6);
        vm.prank(alice);
        vm.expectRevert(IEUSDPsm.ZeroAmount.selector);
        psm.redeem(address(usdg), 1e12 - 1, 0);
    }

    function test_redeem_zero_reverts() public {
        vm.expectRevert(IEUSDPsm.ZeroAmount.selector);
        psm.redeem(address(usdg), 0, 0);
    }

    function test_redeem_belowMinOut_reverts() public {
        _mint(alice, usdg, 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.InsufficientOutput.selector, 1e6, 1e6 + 1));
        psm.redeem(address(usdg), 1e18, 1e6 + 1);
    }

    function test_redeem_whileMintPaused_succeeds() public {
        _mint(alice, usdg, 1e6);
        vm.prank(admin);
        psm.setMintPaused(address(usdg), true);
        vm.prank(alice);
        assertEq(psm.redeem(address(usdg), 1e18, 0), 1e6);
    }

    function test_redeem_notListed_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.redeem(address(1), 1, 0);
    }

    function test_redeem_withoutEusd_reverts() public {
        _mint(alice, usdg, 10e6);
        vm.prank(attacker);
        vm.expectRevert();
        psm.redeem(address(usdg), 1e18, 0);
    }

    // ── Admin ─────────────────────────────────────────────────

    function test_setDebtCeiling_updates() public {
        vm.expectEmit(true, false, false, true, address(psm));
        emit IEUSDPsm.DebtCeilingSet(address(frx), 7e18);
        vm.prank(admin);
        psm.setDebtCeiling(address(frx), 7e18);
        assertEq(psm.assetConfig(address(frx)).debtCeiling, 7e18);
    }

    function test_setDebtCeiling_belowDebt_onlyBlocksMints() public {
        _mint(alice, frx, 10e18);
        vm.prank(admin);
        psm.setDebtCeiling(address(frx), 1e18);
        vm.prank(alice);
        assertEq(psm.redeem(address(frx), 5e18, 0), 5e18);
        frx.mint(alice, 1e18);
        vm.startPrank(alice);
        frx.approve(address(psm), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.DebtCeilingExceeded.selector, 6e18, 1e18));
        psm.mint(address(frx), 1e18, 0);
        vm.stopPrank();
    }

    function test_setDebtCeiling_notAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IEUSDPsm.OnlyAdmin.selector);
        psm.setDebtCeiling(address(frx), 1);
    }

    function test_setDebtCeiling_notListed_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.setDebtCeiling(address(1), 1);
    }

    function test_setFees_updates() public {
        vm.expectEmit(true, false, false, true, address(psm));
        emit IEUSDPsm.FeesSet(address(usdg), 100, 7);
        _setFees(address(usdg), 100, 7);
        assertEq(psm.assetConfig(address(usdg)).mintFeeBps, 100);
        assertEq(psm.assetConfig(address(usdg)).redeemFeeBps, 7);
    }

    function test_setFees_tooHigh_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.FeeTooHigh.selector, uint16(101)));
        psm.setFees(address(usdg), 101, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.FeeTooHigh.selector, uint16(101)));
        psm.setFees(address(usdg), 0, 101);
        vm.stopPrank();
    }

    function test_setFees_notAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IEUSDPsm.OnlyAdmin.selector);
        psm.setFees(address(usdg), 0, 0);
    }

    function test_setFees_notListed_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.setFees(address(1), 0, 0);
    }

    function test_setMintPaused_toggles() public {
        vm.expectEmit(true, false, false, true, address(psm));
        emit IEUSDPsm.MintPausedSet(address(usdg), true);
        vm.prank(admin);
        psm.setMintPaused(address(usdg), true);
        assertTrue(psm.assetConfig(address(usdg)).mintPaused);
        vm.prank(admin);
        psm.setMintPaused(address(usdg), false);
        assertEq(_mint(alice, usdg, 1e6), 1e18);
    }

    function test_setMintPaused_notOperator_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IEUSDPsm.OnlyOperator.selector);
        psm.setMintPaused(address(usdg), true);
    }

    function test_setMintPaused_notListed_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.setMintPaused(address(1), true);
    }

    function test_withdrawSurplus_sendsToTreasury() public {
        vm.prank(admin);
        protocolRegistry.setTreasury(treasury);
        _setFees(address(usdg), 100, 0);
        _mint(alice, usdg, 1000e6); // 10 USDG fee
        usdg.mint(address(psm), 5e6); // a donation is surplus too
        assertEq(psm.surplus(address(usdg)), 15e6);

        vm.expectEmit(true, true, false, true, address(psm));
        emit IEUSDPsm.SurplusWithdrawn(address(usdg), treasury, 15e6);
        vm.prank(admin);
        psm.withdrawSurplus(address(usdg), 15e6);
        assertEq(usdg.balanceOf(treasury), 15e6);
        assertEq(usdg.balanceOf(address(psm)) * 1e12, psm.assetConfig(address(usdg)).debt);
    }

    function test_withdrawSurplus_aboveSurplus_reverts() public {
        vm.prank(admin);
        protocolRegistry.setTreasury(treasury);
        _mint(alice, usdg, 1000e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.InsufficientSurplus.selector, 1, 0));
        psm.withdrawSurplus(address(usdg), 1);
    }

    function test_withdrawSurplus_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IEUSDPsm.ZeroAmount.selector);
        psm.withdrawSurplus(address(usdg), 0);
    }

    function test_withdrawSurplus_noTreasury_reverts() public {
        usdg.mint(address(psm), 1e6);
        vm.prank(admin);
        vm.expectRevert(IEUSDPsm.ZeroAddress.selector);
        psm.withdrawSurplus(address(usdg), 1e6);
    }

    function test_withdrawSurplus_notAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IEUSDPsm.OnlyAdmin.selector);
        psm.withdrawSurplus(address(usdg), 1);
    }

    function test_withdrawSurplus_notListed_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.withdrawSurplus(address(1), 1);
    }

    // ── Views ─────────────────────────────────────────────────

    function test_views_notListed_revert() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.surplus(address(1));
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.previewMint(address(1), 1);
        vm.expectRevert(abi.encodeWithSelector(IEUSDPsm.AssetNotListed.selector, address(1)));
        psm.previewRedeem(address(1), 1);
    }

    function test_assetConfig_notListed_isZero() public view {
        IEUSDPsm.AssetConfig memory cfg = psm.assetConfig(address(1));
        assertFalse(cfg.listed);
        assertEq(cfg.debt, 0);
    }

    // ── Fuzz ──────────────────────────────────────────────────

    function testFuzz_mintRedeem_neverReturnsMore(
        uint256 assetIn,
        uint256 redeemPart,
        uint16 mintFee,
        uint16 redeemFee
    ) public {
        assetIn = bound(assetIn, 1, 1_000_000e6);
        mintFee = uint16(bound(mintFee, 0, 100));
        redeemFee = uint16(bound(redeemFee, 0, 100));
        _setFees(address(usdg), mintFee, redeemFee);
        (uint256 expected,) = psm.previewMint(address(usdg), assetIn);
        vm.assume(expected > 0);
        uint256 out = _mint(alice, usdg, assetIn);
        redeemPart = bound(redeemPart, 1, out);
        (uint256 assetOut,) = psm.previewRedeem(address(usdg), redeemPart);
        vm.assume(assetOut > 0);
        vm.prank(alice);
        psm.redeem(address(usdg), redeemPart, 0);

        assertLe(usdg.balanceOf(alice), assetIn);
        uint256 debt = psm.assetConfig(address(usdg)).debt;
        assertGe(usdg.balanceOf(address(psm)) * 1e12, debt);
        assertEq(eusd.totalSupply(), psm.totalDebt());
    }
}
