// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnMarket} from "../../../src/core/OwnMarket.sol";
import {ReserveVault} from "../../../src/core/ReserveVault.sol";
import {VaultManager} from "../../../src/core/VaultManager.sol";
import {OrderType, Quote} from "../../../src/interfaces/types/Types.sol";
import {EToken} from "../../../src/tokens/EToken.sol";

import {Actors} from "../../helpers/Actors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../../helpers/MockOracleVerifier.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title PsmHandler — invariant driver mixing the PSM and RFQ mint/burn channels
/// @notice Exercises psmMint / psmRedeem / reserve deposits alongside RFQ market mints and redeems
///         (signed quotes) with drifting asset and wrapper prices, so the one-set-of-books
///         property (supply == units) and the netting identities are checked across BOTH
///         channels interleaving arbitrarily.
contract PsmHandler is CommonBase, StdCheats, StdUtils {
    OwnMarket public market;
    VaultManager public manager;
    EToken public eTSLA;
    MockERC20 public usdc;
    MockERC20 public ondo;
    ReserveVault public reserve;
    MockOracleVerifier public oracle;
    uint256 public vmPk;

    bytes32 public constant TSLA = bytes32("TSLA");
    bytes32 public constant ONDO_TSLA = bytes32("ONDO.TSLA");

    address[] public actors;
    uint256 private _quoteNonce = 1;

    constructor(
        address market_,
        address manager_,
        address eTSLA_,
        address usdc_,
        address ondo_,
        address reserve_,
        address oracle_,
        uint256 vmPk_
    ) {
        market = OwnMarket(market_);
        manager = VaultManager(manager_);
        eTSLA = EToken(eTSLA_);
        usdc = MockERC20(usdc_);
        ondo = MockERC20(ondo_);
        reserve = ReserveVault(reserve_);
        oracle = MockOracleVerifier(oracle_);
        vmPk = vmPk_;
        actors.push(Actors.MINTER1);
        actors.push(Actors.MINTER2);
    }

    // ── PSM channel ─────────────────────────────────────────────

    function psmMint(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e15, 1000e18);
        ondo.mint(actor, amount);
        vm.startPrank(actor);
        ondo.approve(address(market), amount);
        try market.psmMint(TSLA, address(ondo), amount) {} catch {}
        vm.stopPrank();
    }

    function psmRedeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = eTSLA.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        try market.psmRedeem(TSLA, address(ondo), amount) {} catch {}
    }

    function depositReserve(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e15, 100e18);
        ondo.mint(actor, amount);
        vm.startPrank(actor);
        ondo.approve(address(reserve), amount);
        try reserve.deposit(amount) {} catch {}
        vm.stopPrank();
    }

    function withdraw(
        uint256 amount
    ) external {
        uint256 ta = reserve.totalAssets();
        if (ta == 0) return;
        amount = bound(amount, 1, ta);
        address signer = vm.addr(vmPk);
        vm.prank(signer);
        try reserve.withdraw(amount) {} catch {}
    }

    // ── RFQ channel ─────────────────────────────────────────────

    function rfqMint(uint256 actorSeed, uint256 usdcAmount) external {
        address actor = actors[actorSeed % actors.length];
        usdcAmount = bound(usdcAmount, 1e6, 100_000e6);
        uint256 price = manager.assetMark(TSLA);
        if (price == 0) return;

        usdc.mint(actor, usdcAmount);
        vm.prank(actor);
        usdc.approve(address(market), usdcAmount);

        (Quote memory q, bytes memory sig) = _signedQuote(actor, OrderType.Mint, usdcAmount, price);
        vm.prank(actor);
        try market.executeOrder(q, sig) {} catch {}
    }

    function rfqRedeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = eTSLA.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 price = manager.assetMark(TSLA);
        if (price == 0) return;

        // The maker (VM1) funds the payout.
        uint256 payout = (amount * price) / (1e18 * 1e12) + 1;
        usdc.mint(Actors.VM1, payout);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), payout);

        (Quote memory q, bytes memory sig) = _signedQuote(actor, OrderType.Redeem, amount, price);
        vm.prank(actor);
        try market.executeOrder(q, sig) {} catch {}
    }

    // ── Price drift ─────────────────────────────────────────────

    function driftAssetPrice(
        uint256 priceSeed
    ) external {
        uint256 price = bound(priceSeed, 200e18, 300e18);
        oracle.setPrice(TSLA, price, block.timestamp);
        manager.pullAssetPrice(TSLA);
    }

    function driftWrapperPrice(
        uint256 priceSeed
    ) external {
        uint256 price = bound(priceSeed, 200e18, 300e18);
        oracle.setPrice(ONDO_TSLA, price, block.timestamp);
        manager.pullCollateralPrice(address(reserve));
    }

    /// @dev Re-stamp the wrapper price at its CURRENT value and re-pull the reserve mark:
    ///      keeps PSM ops fresh across warpForward without moving any price (fixed-mark
    ///      campaigns exclude the drift actions but still need live timestamps).
    function refreshWrapperPrice() external {
        (uint256 price,) = oracle.getPrice(ONDO_TSLA);
        oracle.setPrice(ONDO_TSLA, price, block.timestamp);
        manager.pullCollateralPrice(address(reserve));
    }

    // ── Internal ────────────────────────────────────────────────

    function _signedQuote(
        address user,
        OrderType orderType,
        uint256 amount,
        uint256 price
    ) private returns (Quote memory q, bytes memory sig) {
        q = Quote({
            orderId: 0,
            user: user,
            asset: TSLA,
            orderType: orderType,
            amount: amount,
            price: price,
            quoteId: _quoteNonce++,
            expiry: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vmPk, market.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }
}
