// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OwnMarketTest is BaseTest {
    OwnMarket public market;
    AssetRegistry public assetReg;

    MockERC20 public eTSLAToken;

    address public mockVault = makeAddr("vault");
    address public mockFactory = makeAddr("factory");

    address public rfqVM;
    uint256 public rfqVMPk;

    uint256 constant DEFAULT_EXPIRY_OFFSET = 1 days;
    uint256 constant CLAIM_THRESHOLD = 6 hours;
    bytes32 constant ETH_ASSET = bytes32("ETH");

    uint256 private _quoteNonce = 1;

    function setUp() public override {
        super.setUp();

        (rfqVM, rfqVMPk) = makeAddrAndKey("rfqVM");

        eTSLAToken = new MockERC20("Own TSLA", "eTSLA", 18);
        vm.label(address(eTSLAToken), "eTSLA");

        vm.startPrank(Actors.ADMIN);
        assetReg = new AssetRegistry(Actors.ADMIN);
        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLAToken),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetReg.addAsset(TSLA, address(eTSLAToken), config);
        vm.stopPrank();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetReg));

        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), mockFactory);
        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        // Configure ETH oracle for force execution collateral conversion
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(0),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetReg.addAsset(ETH_ASSET, address(weth), ethConfig);

        vm.stopPrank();
        vm.label(address(market), "OwnMarket");

        // Factory + vault mocks
        vm.mockCall(
            mockFactory, abi.encodeWithSelector(IVaultFactory.isRegisteredVault.selector, mockVault), abi.encode(true)
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.paymentToken.selector), abi.encode(address(usdc)));
        // Collateral token (18 decimals) — used by force-execution collateral conversion.
        vm.mockCall(mockVault, abi.encodeWithSignature("asset()"), abi.encode(address(weth)));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.releaseCollateral.selector), abi.encode());
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.claimThreshold.selector), abi.encode(CLAIM_THRESHOLD));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.collateralOracleAsset.selector), abi.encode(ETH_ASSET));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isAssetSupported.selector), abi.encode(true));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyPaused.selector), abi.encode(false));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyHalted.selector), abi.encode(false));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.getAssetHaltPrice.selector), abi.encode(uint256(0)));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.vm.selector), abi.encode(rfqVM));
        // Authorised quote signers: rfqVM signs; everyone else is rejected.
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isQuoteSigner.selector), abi.encode(false));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isQuoteSigner.selector, rfqVM), abi.encode(true));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.updateExposure.selector), abi.encode());
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IOwnVault.projectedExposureUtilization.selector), abi.encode(uint256(0))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.maxUtilization.selector), abi.encode(uint256(BPS)));

        _setOraclePrice(TSLA, TSLA_PRICE);
        _setOraclePrice(ETH_ASSET, ETH_PRICE);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultExpiry() internal view returns (uint256) {
        return block.timestamp + DEFAULT_EXPIRY_OFFSET;
    }

    function _quote(
        uint256 orderId,
        address user,
        OrderType orderType,
        uint256 amount,
        uint256 price
    ) internal returns (Quote memory q) {
        q = Quote({
            orderId: orderId,
            user: user,
            vault: mockVault,
            asset: TSLA,
            orderType: orderType,
            amount: amount,
            price: price,
            quoteId: _quoteNonce++,
            expiry: _defaultExpiry()
        });
    }

    /// @dev Computes the digest locally (mirrors OwnMarket.quoteDigest) rather than calling the
    ///      contract, so inline use after vm.prank / vm.expectRevert does not consume the cheatcode.
    function _sign(Quote memory q, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                q.orderId,
                q.user,
                q.vault,
                q.asset,
                q.orderType,
                q.amount,
                q.price,
                q.quoteId,
                q.expiry,
                block.chainid,
                address(market)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Expected eTokens minted for a stablecoin amount at a price (zero fee path).
    function _expectedMintOut(uint256 stableAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(stableAmount * 1e12, PRECISION, price);
    }

    /// @dev Expected stablecoin payout for an eToken amount at a price (zero fee path).
    function _expectedRedeemOut(uint256 eTokenAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(eTokenAmount, price, PRECISION * 1e12);
    }

    function _fundUserForMint(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(market), amount);
    }

    function _fundUserForRedeem(address user, uint256 eTokenAmount) internal {
        eTSLAToken.mint(user, eTokenAmount);
        vm.prank(user);
        eTSLAToken.approve(address(market), eTokenAmount);
    }

    function _fundVMForRedeem(
        uint256 amount
    ) internal {
        usdc.mint(rfqVM, amount);
        vm.prank(rfqVM);
        usdc.approve(address(market), amount);
    }

    function _placeMint(address user, uint256 amount, uint256 limitPrice) internal returns (uint256 orderId) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(market), amount);
        orderId = market.placeOrder(mockVault, TSLA, OrderType.Mint, amount, limitPrice, _defaultExpiry());
        vm.stopPrank();
    }

    function _placeRedeem(address user, uint256 amount, uint256 limitPrice) internal returns (uint256 orderId) {
        eTSLAToken.mint(user, amount);
        vm.startPrank(user);
        eTSLAToken.approve(address(market), amount);
        orderId = market.placeOrder(mockVault, TSLA, OrderType.Redeem, amount, limitPrice, _defaultExpiry());
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  executeOrder — market mint
    // ══════════════════════════════════════════════════════════

    function test_executeOrder_marketMint_succeeds() public {
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);

        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);

        uint256 expectedOut = _expectedMintOut(amount, TSLA_PRICE);

        vm.expectEmit(true, true, true, true);
        emit IOwnMarket.OrderExecuted(
            q.quoteId, Actors.MINTER1, rfqVM, TSLA, uint8(OrderType.Mint), amount, expectedOut
        );

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(usdc.balanceOf(Actors.MINTER1), 0, "minter usdc spent");
        assertEq(usdc.balanceOf(rfqVM), amount, "vm received stablecoins");
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), expectedOut, "minter received eTokens");
        assertTrue(market.isQuoteUsed(market.quoteDigest(q)), "quote marked used");
    }

    function test_executeOrder_marketRedeem_succeeds() public {
        uint256 eTokenAmount = 4e18;
        uint256 payout = _expectedRedeemOut(eTokenAmount, TSLA_PRICE);
        _fundUserForRedeem(Actors.MINTER1, eTokenAmount);
        _fundVMForRedeem(payout);

        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, eTokenAmount, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 0, "eTokens burned");
        assertEq(usdc.balanceOf(Actors.MINTER1), payout, "minter received stablecoins");
        assertEq(usdc.balanceOf(rfqVM), 0, "vm paid out");
    }

    function test_executeOrder_nonZeroOrderId_reverts() public {
        Quote memory q = _quote(1, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.QuoteOrderMismatch.selector);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_notQuoteUser_reverts() public {
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER2);
        vm.expectRevert(IOwnMarket.NotQuoteUser.selector);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_wrongSigner_reverts() public {
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        (, uint256 wrongPk) = makeAddrAndKey("attacker");
        bytes memory sig = _sign(q, wrongPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidQuoteSigner.selector);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_separateAuthorisedSigner_succeeds() public {
        // A signer distinct from the operational vm address can authorise quotes.
        (address altSigner, uint256 altPk) = makeAddrAndKey("altSigner");
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isQuoteSigner.selector, altSigner), abi.encode(true));

        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _sign(q, altPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), _expectedMintOut(amount, TSLA_PRICE));
        assertEq(usdc.balanceOf(rfqVM), amount, "funds still flow to operational vm");
    }

    function test_executeOrder_expiredQuote_reverts() public {
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.warp(q.expiry + 1);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.QuoteExpired.selector);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_replay_reverts() public {
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount * 2);
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.QuoteAlreadyUsed.selector);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_paused_reverts() public {
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyPaused.selector), abi.encode(true));
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.executeOrder(q, sig);
    }

    function test_executeOrder_mintDuringHalt_reverts() public {
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyHalted.selector), abi.encode(true));
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.executeOrder(q, sig);
    }

    function test_executeOrder_redeemDuringHalt_reverts() public {
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyHalted.selector), abi.encode(true));
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, 4e18, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.TradingHalted.selector, TSLA));
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  placeOrder
    // ══════════════════════════════════════════════════════════

    function test_placeOrder_mint_escrowsAndStores() public {
        uint256 amount = 1000e6;
        usdc.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        vm.expectEmit(true, true, true, true);
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Mint), TSLA, mockVault, amount, TSLA_PRICE);

        uint256 orderId = market.placeOrder(mockVault, TSLA, OrderType.Mint, amount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();

        assertEq(orderId, 1);
        assertEq(usdc.balanceOf(address(market)), amount, "escrowed");
        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint256(order.orderType), uint256(OrderType.Mint));
        assertEq(order.amount, amount);
        assertEq(order.filledAmount, 0);
        assertEq(order.limitPrice, TSLA_PRICE);
        assertEq(uint256(order.status), uint256(OrderStatus.Open));
    }

    function test_placeOrder_redeem_escrowsETokens() public {
        uint256 amount = 4e18;
        _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        assertEq(eTSLAToken.balanceOf(address(market)), amount, "eTokens escrowed");
    }

    function test_placeOrder_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.placeOrder(mockVault, TSLA, OrderType.Mint, 0, TSLA_PRICE, _defaultExpiry());
    }

    function test_placeOrder_zeroLimitPrice_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidPrice.selector);
        market.placeOrder(mockVault, TSLA, OrderType.Mint, 1000e6, 0, _defaultExpiry());
    }

    function test_placeOrder_pastExpiry_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidExpiry.selector);
        market.placeOrder(mockVault, TSLA, OrderType.Mint, 1000e6, TSLA_PRICE, block.timestamp);
    }

    function test_placeOrder_mintDuringHalt_reverts() public {
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyHalted.selector), abi.encode(true));
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.placeOrder(mockVault, TSLA, OrderType.Mint, 1000e6, TSLA_PRICE, _defaultExpiry());
    }

    // ══════════════════════════════════════════════════════════
    //  fillOrder — mint
    // ══════════════════════════════════════════════════════════

    function test_fillOrder_mint_fullFill() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);

        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.prank(rfqVM);
        market.fillOrder(q, sig);

        assertEq(usdc.balanceOf(rfqVM), amount, "vm received escrowed stablecoins");
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), _expectedMintOut(amount, TSLA_PRICE), "minted");
        Order memory order = market.getOrder(orderId);
        assertEq(order.filledAmount, amount);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_fillOrder_mint_partialThenComplete() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);

        // First partial fill: 600
        Quote memory q1 = _quote(orderId, Actors.MINTER1, OrderType.Mint, 600e6, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q1, _sign(q1, rfqVMPk));

        Order memory o1 = market.getOrder(orderId);
        assertEq(o1.filledAmount, 600e6);
        assertEq(uint256(o1.status), uint256(OrderStatus.Open), "still open");
        assertEq(usdc.balanceOf(rfqVM), 600e6);
        assertEq(usdc.balanceOf(address(market)), 400e6, "remaining escrow");

        // Second fill: remaining 400
        Quote memory q2 = _quote(orderId, Actors.MINTER1, OrderType.Mint, 400e6, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q2, _sign(q2, rfqVMPk));

        Order memory o2 = market.getOrder(orderId);
        assertEq(o2.filledAmount, amount);
        assertEq(uint256(o2.status), uint256(OrderStatus.Filled));
        assertEq(usdc.balanceOf(rfqVM), amount);
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), _expectedMintOut(amount, TSLA_PRICE));
    }

    function test_fillOrder_redeem_partial() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        uint256 fill = 1e18;
        uint256 payout = _expectedRedeemOut(fill, TSLA_PRICE);
        _fundVMForRedeem(payout);

        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Redeem, fill, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q, _sign(q, rfqVMPk));

        assertEq(usdc.balanceOf(Actors.MINTER1), payout, "minter paid");
        assertEq(eTSLAToken.balanceOf(address(market)), amount - fill, "escrow burned by fill amount");
        Order memory order = market.getOrder(orderId);
        assertEq(order.filledAmount, fill);
        assertEq(uint256(order.status), uint256(OrderStatus.Open));
    }

    function test_fillOrder_mintLimitViolated_reverts() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        // Quote price above the mint limit price
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE + 1);
        vm.prank(rfqVM);
        vm.expectRevert(IOwnMarket.LimitNotSatisfied.selector);
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    function test_fillOrder_redeemLimitViolated_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        // Quote price below the redeem limit price
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Redeem, amount, TSLA_PRICE - 1);
        vm.prank(rfqVM);
        vm.expectRevert(IOwnMarket.LimitNotSatisfied.selector);
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    function test_fillOrder_exceedsRemaining_reverts() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount + 1, TSLA_PRICE);
        vm.prank(rfqVM);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.FillExceedsRemaining.selector, orderId));
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    function test_fillOrder_termsMismatch_reverts() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        // Wrong user in the quote
        Quote memory q = _quote(orderId, Actors.MINTER2, OrderType.Mint, amount, TSLA_PRICE);
        vm.prank(rfqVM);
        vm.expectRevert(IOwnMarket.QuoteTermsMismatch.selector);
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    function test_fillOrder_zeroOrderId_reverts() public {
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        vm.prank(rfqVM);
        vm.expectRevert(IOwnMarket.QuoteOrderMismatch.selector);
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    function test_fillOrder_alreadyFilled_reverts() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q, _sign(q, rfqVMPk));

        Quote memory q2 = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        vm.prank(rfqVM);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId));
        market.fillOrder(q2, _sign(q2, rfqVMPk));
    }

    function test_fillOrder_wrongSigner_reverts() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        (, uint256 wrongPk) = makeAddrAndKey("attacker");
        vm.prank(rfqVM);
        vm.expectRevert(IOwnMarket.InvalidQuoteSigner.selector);
        market.fillOrder(q, _sign(q, wrongPk));
    }

    // ══════════════════════════════════════════════════════════
    //  forceExecuteOrder — redeem
    // ══════════════════════════════════════════════════════════

    function _assetPriceData(
        uint256 price
    ) internal view returns (bytes memory) {
        return abi.encode(price, block.timestamp);
    }

    function test_forceExecuteOrder_redeem_succeeds() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);

        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        uint256 grossUsd = Math.mulDiv(amount, TSLA_PRICE, PRECISION);
        uint256 expectedCollateral = Math.mulDiv(grossUsd, PRECISION, ETH_PRICE);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderForceExecuted(orderId, Actors.MINTER1, amount, expectedCollateral);

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));

        assertEq(eTSLAToken.balanceOf(address(market)), 0, "escrowed eTokens burned");
        Order memory order = market.getOrder(orderId);
        assertEq(order.filledAmount, amount);
        assertEq(uint256(order.status), uint256(OrderStatus.ForceExecuted));
    }

    function test_forceExecuteOrder_beforeWindow_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ForceWindowNotElapsed.selector, orderId));
        market.forceExecuteOrder(orderId, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_mintOrder_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, 1000e6, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ForceMintNotAllowed.selector, orderId));
        market.forceExecuteOrder(orderId, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_notOwner_reverts() public {
        uint256 orderId = _placeRedeem(Actors.MINTER1, 4e18, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER2);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.forceExecuteOrder(orderId, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_priceBelowLimit_reverts() public {
        uint256 amount = 4e18;
        // limit price higher than the oracle price at force time
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE + 1);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.PriceBelowMinimum.selector);
        market.forceExecuteOrder(orderId, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_partiallyFilled_forcesRemaining() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);

        // VM partially fills 1e18
        uint256 fill = 1e18;
        _fundVMForRedeem(_expectedRedeemOut(fill, TSLA_PRICE));
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Redeem, fill, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q, _sign(q, rfqVMPk));

        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        uint256 remaining = amount - fill;
        uint256 grossUsd = Math.mulDiv(remaining, TSLA_PRICE, PRECISION);
        uint256 expectedCollateral = Math.mulDiv(grossUsd, PRECISION, ETH_PRICE);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderForceExecuted(orderId, Actors.MINTER1, remaining, expectedCollateral);

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));

        assertEq(eTSLAToken.balanceOf(address(market)), 0, "remaining escrow burned");
    }

    function test_forceExecuteOrder_duringHalt_usesHaltPrice() public {
        uint256 amount = 4e18;
        uint256 haltPrice = 200e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, 0 + 1); // tiny limit so halt price passes

        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyHalted.selector), abi.encode(true));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.getAssetHaltPrice.selector), abi.encode(haltPrice));
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        uint256 grossUsd = Math.mulDiv(amount, haltPrice, PRECISION);
        uint256 expectedCollateral = Math.mulDiv(grossUsd, PRECISION, ETH_PRICE);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderForceExecuted(orderId, Actors.MINTER1, amount, expectedCollateral);

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, "", _assetPriceData(ETH_PRICE));
    }

    // ══════════════════════════════════════════════════════════
    //  cancelOrder / expireOrder
    // ══════════════════════════════════════════════════════════

    function test_cancelOrder_mint_returnsEscrow() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);
        assertEq(usdc.balanceOf(Actors.MINTER1), amount, "escrow returned");
        assertEq(uint256(market.getOrder(orderId).status), uint256(OrderStatus.Cancelled));
    }

    function test_cancelOrder_partiallyFilled_returnsRemaining() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, 600e6, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q, _sign(q, rfqVMPk));

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);
        assertEq(usdc.balanceOf(Actors.MINTER1), 400e6, "remaining escrow returned");
    }

    function test_cancelOrder_notOwner_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, 1000e6, TSLA_PRICE);
        vm.prank(Actors.MINTER2);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.cancelOrder(orderId);
    }

    function test_expireOrder_returnsEscrowAfterExpiry() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        Order memory order = market.getOrder(orderId);
        vm.warp(order.expiry + 1);
        market.expireOrder(orderId);
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), amount, "eTokens returned");
        assertEq(uint256(market.getOrder(orderId).status), uint256(OrderStatus.Expired));
    }

    function test_expireOrder_beforeExpiry_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, 1000e6, TSLA_PRICE);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ExpiryNotReached.selector, orderId));
        market.expireOrder(orderId);
    }
}
