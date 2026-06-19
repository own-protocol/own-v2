// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Payment token whose transfers deliver 1 wei less than requested (L-12 regression).
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("FoT USD", "fUSD", 6) {}

    function transferFrom(address from, address to, uint256 value) public override returns (bool ok) {
        ok = super.transferFrom(from, to, value);
        _burn(to, 1);
    }
}

/// @dev USDC-style token with an admin blocklist: transfers to a blocked address revert (L-13 regression).
contract BlocklistToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Blocklist USD", "bUSD", 6) {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        require(!blocked[to], "blocklisted");
        return super.transfer(to, value);
    }
}

contract OwnMarketTest is BaseTest {
    OwnMarket public market;
    AssetRegistry public assetReg;

    MockERC20 public eTSLAToken;

    address public mockVault = makeAddr("vault");
    address public mockVaultManager = makeAddr("vaultManager");
    address public haltFund = makeAddr("haltFund");

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
        assetReg = new AssetRegistry(address(protocolRegistry));
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

        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), mockVaultManager);
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

        // VaultManager registration mock: forceExecuteOrder checks isRegisteredVault on the manager.
        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.isRegisteredVault.selector, mockVault),
            abi.encode(true)
        );
        // Vault not excluded from the global pool by default (force-execute rejects excluded vaults).
        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.isVaultExcluded.selector, mockVault),
            abi.encode(false)
        );
        // Collateral token (18 decimals) — used by force-execution collateral conversion.
        vm.mockCall(mockVault, abi.encodeWithSignature("asset()"), abi.encode(address(weth)));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.releaseCollateral.selector), abi.encode());

        // VaultManager mocks: control surface + exposure accounting are centralised here.
        // Global payment token + claim threshold + halt fund.
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.paymentToken.selector), abi.encode(address(usdc))
        );
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.claimThreshold.selector), abi.encode(CLAIM_THRESHOLD)
        );
        // Force-execution collateral source: mockVault is the designated vault by default.
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.forceExecuteVault.selector), abi.encode(mockVault)
        );
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.haltRedeemAddress.selector), abi.encode(haltFund)
        );
        // Trading status: not paused, not halted by default.
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isTradingPaused.selector), abi.encode(false));
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(false));
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.assetHaltPrice.selector), abi.encode(uint256(0))
        );
        // Global signer registry: rfqVM signs; everyone else is rejected. Funds settle to rfqVM.
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isSigner.selector), abi.encode(false));
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isSigner.selector, rfqVM), abi.encode(true));
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.signerLinkedAddress.selector), abi.encode(rfqVM)
        );
        // Exposure accounting: open/close are no-ops here; vaultCollateralAsset feeds force-exec
        // collateral conversion.
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.openExposure.selector), abi.encode());
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.closeExposure.selector), abi.encode());
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.vaultCollateralAsset.selector), abi.encode(ETH_ASSET)
        );
        // Settle-price band guard (execute/fill): reads the asset mark and the band. Default mark =
        // current price, band = 100% (permissive) so existing flow tests are unaffected; the band
        // boundary tests below override these per-test.
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.assetMark.selector), abi.encode(TSLA_PRICE));
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.settleBandBps.selector), abi.encode(BPS));
        // Settle-band freshness: mark is fresh by default, maxMarkAge large so band tests never trip it.
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.maxMarkAge.selector), abi.encode(uint256(365 days))
        );
        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.assetMarkUpdatedAt.selector),
            abi.encode(block.timestamp)
        );

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
            asset: TSLA,
            orderType: orderType,
            amount: amount,
            price: price,
            quoteId: _quoteNonce++,
            expiry: _defaultExpiry()
        });
    }

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(uint256 orderId,address user,bytes32 asset,uint8 orderType,uint256 amount,uint256 price,uint256 quoteId,uint256 expiry)"
    );

    /// @dev Computes the EIP-712 digest locally (mirrors OwnMarket.quoteDigest) rather than calling
    ///      the contract, so inline use after vm.prank / vm.expectRevert does not consume the
    ///      cheatcode — and independently locks the domain/typehash encoding.
    function _quoteDigest(
        Quote memory q
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Own Protocol")),
                keccak256(bytes("1")),
                block.chainid,
                address(market)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(QUOTE_TYPEHASH, q.orderId, q.user, q.asset, q.orderType, q.amount, q.price, q.quoteId, q.expiry)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _quoteDigest(q));
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
        orderId = market.placeOrder(TSLA, OrderType.Mint, amount, limitPrice, _defaultExpiry());
        vm.stopPrank();
    }

    function _placeRedeem(address user, uint256 amount, uint256 limitPrice) internal returns (uint256 orderId) {
        eTSLAToken.mint(user, amount);
        vm.startPrank(user);
        eTSLAToken.approve(address(market), amount);
        orderId = market.placeOrder(TSLA, OrderType.Redeem, amount, limitPrice, _defaultExpiry());
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
        // A signer distinct from the settlement (linked) address can authorise quotes.
        (address altSigner, uint256 altPk) = makeAddrAndKey("altSigner");
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.isSigner.selector, altSigner), abi.encode(true)
        );
        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.signerLinkedAddress.selector, altSigner),
            abi.encode(rfqVM)
        );

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
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isTradingPaused.selector), abi.encode(true));
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.executeOrder(q, sig);
    }

    function test_executeOrder_mintDuringHalt_reverts() public {
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(true));
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _sign(q, rfqVMPk);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.executeOrder(q, sig);
    }

    function test_executeOrder_redeemDuringHalt_reverts() public {
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(true));
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
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Mint), TSLA, amount, TSLA_PRICE);

        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, amount, TSLA_PRICE, _defaultExpiry());
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

    /// @dev Escrow accounting trusts sent == received; a fee-on-transfer payment token
    ///      would desync the escrow pool and break the last cancels/settles.
    function test_placeOrder_feeOnTransferToken_reverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.paymentToken.selector), abi.encode(address(fot))
        );

        uint256 amount = 1000e6;
        fot.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        fot.approve(address(market), amount);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.FeeOnTransferNotSupported.selector, address(fot)));
        market.placeOrder(TSLA, OrderType.Mint, amount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();
    }

    /// @dev Dividends accruing on eTokens escrowed in resting redeem orders must be
    ///      sweepable to the treasury — previously they were permanently stranded.
    function test_sweepDividends_escrowedETokens_toTreasury() public {
        address treasury = makeAddr("treasury");
        _setTreasury(treasury);

        // A dividend-paying eToken registered as its own asset; usdc is the reward token.
        EToken divToken = new EToken("Own TLT", "eTLT", bytes32("TLT"), address(protocolRegistry), address(usdc));
        AssetConfig memory cfg = AssetConfig({
            activeToken: address(divToken),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetReg.addAsset(bytes32("TLT"), address(divToken), cfg);

        // User escrows eTokens in a resting redeem order.
        vm.prank(address(market));
        divToken.mint(Actors.MINTER1, 100e18);
        vm.startPrank(Actors.MINTER1);
        divToken.approve(address(market), 100e18);
        market.placeOrder(bytes32("TLT"), OrderType.Redeem, 100e18, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();

        // Dividends land while the order rests; the market is the sole holder.
        uint256 dividends = 1000e6;
        usdc.mint(address(this), dividends);
        usdc.approve(address(divToken), dividends);
        divToken.depositRewards(dividends);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.EscrowDividendsSwept(address(divToken), treasury, dividends);
        uint256 swept = market.sweepDividends(address(divToken));

        assertEq(swept, dividends);
        assertEq(usdc.balanceOf(treasury), dividends, "dividends swept to treasury");
    }

    function test_sweepDividends_invalidToken_reverts() public {
        EToken unregistered = new EToken("Fake", "eFAKE", bytes32("FAKE"), address(protocolRegistry), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidEToken.selector, address(unregistered)));
        market.sweepDividends(address(unregistered));
    }

    /// @dev L-13: a blocklist-frozen user must not brick cancel/expire — the escrow
    ///      sweeps to the protocol treasury for off-chain resolution instead.
    function test_cancelOrder_frozenUser_sweepsEscrowToTreasury() public {
        address treasury = makeAddr("treasury");
        _setTreasury(treasury);

        BlocklistToken blockToken = new BlocklistToken();
        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.paymentToken.selector),
            abi.encode(address(blockToken))
        );

        uint256 amount = 1000e6;
        blockToken.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        blockToken.approve(address(market), amount);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, amount, TSLA_PRICE, _defaultExpiry());

        // User gets frozen after placing; cancel must not brick.
        blockToken.setBlocked(Actors.MINTER1, true);

        vm.expectEmit(true, false, false, true);
        emit IOwnMarket.EscrowSweptToTreasury(Actors.MINTER1, address(blockToken), amount);
        market.cancelOrder(orderId);
        vm.stopPrank();

        assertEq(blockToken.balanceOf(treasury), amount, "escrow swept to treasury");
        assertEq(blockToken.balanceOf(address(market)), 0, "market holds nothing");
        assertEq(blockToken.balanceOf(Actors.MINTER1), 0, "frozen user received nothing");
    }

    function test_placeOrder_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.placeOrder(TSLA, OrderType.Mint, 0, TSLA_PRICE, _defaultExpiry());
    }

    function test_placeOrder_zeroLimitPrice_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidPrice.selector);
        market.placeOrder(TSLA, OrderType.Mint, 1000e6, 0, _defaultExpiry());
    }

    function test_placeOrder_pastExpiry_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidExpiry.selector);
        market.placeOrder(TSLA, OrderType.Mint, 1000e6, TSLA_PRICE, block.timestamp);
    }

    function test_placeOrder_mintDuringHalt_reverts() public {
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(true));
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.placeOrder(TSLA, OrderType.Mint, 1000e6, TSLA_PRICE, _defaultExpiry());
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

    // L-17: a Mint fill opens new exposure, so it must reject a deactivated asset (matching
    // executeOrder/placeOrder); previously fillOrder only checked pause/halt, not isActiveAsset.
    function test_fillOrder_mint_inactiveAsset_reverts() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE);

        vm.prank(Actors.ADMIN);
        assetReg.setAssetActive(TSLA, false);

        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        vm.prank(rfqVM);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetNotActive.selector, TSLA));
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    // L-17 scoping: deactivation must NOT block Redeem (wind-down) fills of existing positions.
    function test_fillOrder_redeem_inactiveAsset_succeeds() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        uint256 fill = 1e18;
        uint256 payout = _expectedRedeemOut(fill, TSLA_PRICE);
        _fundVMForRedeem(payout);

        vm.prank(Actors.ADMIN);
        assetReg.setAssetActive(TSLA, false);

        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Redeem, fill, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q, _sign(q, rfqVMPk));

        assertEq(usdc.balanceOf(Actors.MINTER1), payout, "redeem winds down while inactive");
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
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));

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
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    /// @dev A zero claim threshold (pre-deploy default) disables force-execution entirely, even
    ///      after the order has aged — recourse is unavailable until the threshold is configured.
    function test_forceExecuteOrder_zeroClaimThreshold_reverts() public {
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.claimThreshold.selector), abi.encode(uint256(0))
        );
        uint256 orderId = _placeRedeem(Actors.MINTER1, 4e18, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ForceNotEnabled.selector);
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    /// @dev No designated force-execute vault (the default) disables force-execution entirely.
    function test_forceExecuteOrder_noDesignatedVault_reverts() public {
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.forceExecuteVault.selector), abi.encode(address(0))
        );
        uint256 orderId = _placeRedeem(Actors.MINTER1, 4e18, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ForceExecuteVaultNotSet.selector);
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    /// @dev The redeemer cannot source collateral from a vault other than the protocol-designated one.
    function test_forceExecuteOrder_wrongVault_reverts() public {
        address otherVault = makeAddr("otherVault");
        uint256 orderId = _placeRedeem(Actors.MINTER1, 4e18, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.VaultNotDesignated.selector, otherVault, mockVault));
        market.forceExecuteOrder(orderId, otherVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_mintOrder_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, 1000e6, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ForceMintNotAllowed.selector, orderId));
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_notOwner_reverts() public {
        uint256 orderId = _placeRedeem(Actors.MINTER1, 4e18, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER2);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    function test_forceExecuteOrder_priceBelowLimit_reverts() public {
        uint256 amount = 4e18;
        // limit price higher than the oracle price at force time
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE + 1);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.PriceBelowMinimum.selector);
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
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
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));

        assertEq(eTSLAToken.balanceOf(address(market)), 0, "remaining escrow burned");
    }

    /// @dev Force execution is now disabled for a permanently halted asset; holders must use
    ///      {redeemHalted} instead. (Previously the force path settled at the halt price.)
    function test_forceExecuteOrder_duringHalt_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, 0 + 1); // tiny limit

        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(true));
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ForceDisabledDuringHalt.selector, TSLA));
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    /// @dev H-01 regression: a halted/excluded vault (collateral removed from the global pool and
    ///      winding down to its LPs) cannot be named as the force-execute collateral source.
    function test_forceExecuteOrder_excludedVault_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.isVaultExcluded.selector, mockVault),
            abi.encode(true)
        );

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.VaultExcludedFromPool.selector, mockVault));
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    /// @dev C-01 regression: settlement is valued at the user's limitPrice, NOT the submitted asset
    ///      proof. A redeemer who supplies an inflated (but limit-satisfying, in-window) asset price
    ///      cannot increase the collateral released.
    function test_forceExecuteOrder_settlesAtLimitNotProof() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE); // limit = TSLA_PRICE
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        // Payout is valued at the LIMIT, even though the proof carries 2× the price.
        uint256 grossUsdAtLimit = Math.mulDiv(amount, TSLA_PRICE, PRECISION);
        uint256 expectedCollateral = Math.mulDiv(grossUsdAtLimit, PRECISION, ETH_PRICE);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderForceExecuted(orderId, Actors.MINTER1, amount, expectedCollateral);

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE * 2), _assetPriceData(ETH_PRICE));
    }

    /// @dev Force-execute requires a fresh asset price, superseding the C-01 historical-touch window:
    ///      an asset proof timestamped at placement (which historically met the limit but is now
    ///      older than priceMaxAge) is rejected, blocking the "exercise a stale favorable print after
    ///      the market moved" collateral-drain vector.
    function test_forceExecuteOrder_staleFavorablePrint_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        uint256 createdAt = block.timestamp;
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        // Old print that historically met the limit; collateral proof is current.
        bytes memory assetData = abi.encode(uint256(TSLA_PRICE), createdAt);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.StaleAssetPrice.selector);
        market.forceExecuteOrder(orderId, mockVault, assetData, _assetPriceData(ETH_PRICE));
    }

    /// @dev An asset proof exactly at the priceMaxAge boundary is fresh enough (inclusive).
    function test_forceExecuteOrder_assetPriceAtMaxAgeBoundary_succeeds() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        uint256 maxAge = protocolRegistry.priceMaxAge();
        bytes memory assetData = abi.encode(uint256(TSLA_PRICE), block.timestamp - maxAge); // at the bound
        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, mockVault, assetData, _assetPriceData(ETH_PRICE));

        assertEq(uint256(market.getOrder(orderId).status), uint256(OrderStatus.ForceExecuted));
    }

    /// @dev An asset proof one second past priceMaxAge is rejected.
    function test_forceExecuteOrder_assetPriceJustPastMaxAge_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        uint256 maxAge = protocolRegistry.priceMaxAge();
        bytes memory assetData = abi.encode(uint256(TSLA_PRICE), block.timestamp - maxAge - 1); // 1s stale
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.StaleAssetPrice.selector);
        market.forceExecuteOrder(orderId, mockVault, assetData, _assetPriceData(ETH_PRICE));
    }

    /// @dev C-01 regression: the collateral leg must be current — a stale collateral proof reverts,
    ///      blocking the "supply an old low ETH price to over-release collateral" vector.
    function test_forceExecuteOrder_staleCollateralPrice_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        // Collateral proof older than the freshness window (15 min).
        bytes memory collatData = abi.encode(uint256(ETH_PRICE), block.timestamp - 16 minutes);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.StaleCollateralPrice.selector);
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), collatData);
    }

    // ══════════════════════════════════════════════════════════
    //  convertLegacy + migration (H-02)
    // ══════════════════════════════════════════════════════════

    /// @dev Migrate TSLA to a fresh active token at `ratio`; returns the new active token.
    function _migrate(
        uint256 ratio
    ) internal returns (MockERC20 v2) {
        v2 = new MockERC20("Own TSLA v2", "eTSLAv2", 18);
        vm.prank(Actors.ADMIN);
        assetReg.migrateToken(TSLA, address(v2), ratio);
    }

    function test_convertLegacy_forwardSplit_mintsActive() public {
        MockERC20 v2 = _migrate(3e18); // 3:1
        eTSLAToken.mint(Actors.MINTER1, 100e18); // legacy balance

        vm.prank(Actors.MINTER1);
        uint256 out = market.convertLegacy(TSLA, address(eTSLAToken), 100e18);

        assertEq(out, 300e18, "3x new tokens");
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 0, "legacy burned");
        assertEq(v2.balanceOf(Actors.MINTER1), 300e18, "active minted");
    }

    function test_convertLegacy_activeToken_reverts() public {
        // Before any migration eTSLAToken is the active token, not a legacy.
        eTSLAToken.mint(Actors.MINTER1, 1e18);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.NotLegacyToken.selector, address(eTSLAToken)));
        market.convertLegacy(TSLA, address(eTSLAToken), 1e18);
    }

    function test_convertLegacy_allowedDuringHalt() public {
        _migrate(2e18);
        eTSLAToken.mint(Actors.MINTER1, 50e18);
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(true));

        vm.prank(Actors.MINTER1);
        uint256 out = market.convertLegacy(TSLA, address(eTSLAToken), 50e18);
        assertEq(out, 100e18, "conversion works even while halted");
    }

    function test_cancelOrder_afterMigration_returnsOriginalToken() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE); // escrows eTSLAToken
        _migrate(3e18); // active token is now v2; eTSLAToken is legacy

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        // The ORIGINAL escrowed token is returned, not the new active token.
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), amount, "original token returned");
    }

    function test_fillOrder_afterMigration_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        _migrate(3e18);

        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Redeem, amount, TSLA_PRICE);
        vm.prank(rfqVM);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OrderTokenMigrated.selector, orderId));
        market.fillOrder(q, _sign(q, rfqVMPk));
    }

    function test_forceExecuteOrder_afterMigration_reverts() public {
        uint256 amount = 4e18;
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, TSLA_PRICE);
        _migrate(3e18);
        vm.warp(block.timestamp + CLAIM_THRESHOLD);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OrderTokenMigrated.selector, orderId));
        market.forceExecuteOrder(orderId, mockVault, _assetPriceData(TSLA_PRICE), _assetPriceData(ETH_PRICE));
    }

    /// @dev I-1 regression: a mint order filled after the global payment token changes settles in the
    ///      token escrowed at placement, not the new payment token.
    function test_fillMint_afterPaymentTokenChange_settlesInEscrowToken() public {
        uint256 amount = 1000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, amount, TSLA_PRICE); // escrows usdc

        MockERC20 usdc2 = new MockERC20("USD Coin 2", "USDC2", 6);
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.paymentToken.selector), abi.encode(address(usdc2))
        );

        uint256 makerBefore = usdc.balanceOf(rfqVM);
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        vm.prank(rfqVM);
        market.fillOrder(q, _sign(q, rfqVMPk));

        assertEq(usdc.balanceOf(rfqVM), makerBefore + amount, "maker paid in original escrow token");
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), _expectedMintOut(amount, TSLA_PRICE), "eTokens minted");
    }

    // ══════════════════════════════════════════════════════════
    //  redeemHalted — permanent halt settlement
    // ══════════════════════════════════════════════════════════

    function test_redeemHalted_succeeds() public {
        uint256 eTokenAmount = 4e18;
        uint256 haltPrice = 200e18;

        // Halt the asset at a fixed price and fund the halt redeem address.
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.isAssetHalted.selector), abi.encode(true));
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.assetHaltPrice.selector), abi.encode(haltPrice)
        );

        // Caller holds the eTokens to redeem.
        eTSLAToken.mint(Actors.MINTER1, eTokenAmount);

        // Halt fund holds stables and approves the market to pull them.
        // payout = eTokenAmount * haltPrice / (1e18 * 1e12)  (usdc has 6 decimals).
        uint256 payout = Math.mulDiv(eTokenAmount, haltPrice, PRECISION * 1e12);
        usdc.mint(haltFund, payout);
        vm.prank(haltFund);
        usdc.approve(address(market), payout);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderRedeemedHalted(Actors.MINTER1, TSLA, eTokenAmount, payout);

        vm.prank(Actors.MINTER1);
        uint256 got = market.redeemHalted(TSLA, eTokenAmount);

        assertEq(got, payout, "payout returned");
        assertEq(usdc.balanceOf(Actors.MINTER1), payout, "caller received stables");
        assertEq(usdc.balanceOf(haltFund), 0, "halt fund drained");
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 0, "eTokens burned");
    }

    function test_redeemHalted_notHalted_reverts() public {
        eTSLAToken.mint(Actors.MINTER1, 1e18);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetNotHalted.selector, TSLA));
        market.redeemHalted(TSLA, 1e18);
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

    // ══════════════════════════════════════════════════════════
    //  Settle-price band guard (execute / fill paths)
    // ══════════════════════════════════════════════════════════

    uint256 constant BAND_MARK = 250e18; // mocked VaultManager mark for TSLA
    uint256 constant BAND_BPS = 500; //     ±5% band → edges at 237.5e18 / 262.5e18

    /// @dev Override the mocked mark + band for band-boundary tests.
    function _setBandMocks(uint256 mark, uint256 band) internal {
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.assetMark.selector), abi.encode(mark));
        vm.mockCall(mockVaultManager, abi.encodeWithSelector(IVaultManager.settleBandBps.selector), abi.encode(band));
    }

    function test_executeOrder_mint_atUpperBandEdge_succeeds() public {
        _setBandMocks(BAND_MARK, BAND_BPS);
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        uint256 price = 262.5e18; // exactly +5% — boundary is inclusive
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), _expectedMintOut(amount, price), "mint at band edge");
    }

    function test_executeOrder_mint_aboveBand_reverts() public {
        _setBandMocks(BAND_MARK, BAND_BPS);
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        uint256 price = 262.5e18 + 1; // 1 wei past +5%
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PriceOutOfBand.selector, TSLA, price, BAND_MARK, BAND_BPS));
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_mint_belowBand_reverts() public {
        _setBandMocks(BAND_MARK, BAND_BPS);
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        uint256 price = 237.5e18 - 1; // 1 wei past -5%
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PriceOutOfBand.selector, TSLA, price, BAND_MARK, BAND_BPS));
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    /// @dev The maker-drain vector: a forged high redeem price is capped by the band.
    function test_executeOrder_redeem_aboveBand_reverts() public {
        _setBandMocks(BAND_MARK, BAND_BPS);
        uint256 eTokenAmount = 4e18;
        uint256 price = 262.5e18 + 1;
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, eTokenAmount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PriceOutOfBand.selector, TSLA, price, BAND_MARK, BAND_BPS));
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    function test_executeOrder_redeem_belowBand_reverts() public {
        _setBandMocks(BAND_MARK, BAND_BPS);
        uint256 eTokenAmount = 4e18;
        uint256 price = 237.5e18 - 1;
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, eTokenAmount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PriceOutOfBand.selector, TSLA, price, BAND_MARK, BAND_BPS));
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    /// @dev #3 (A2-M-01): the redeem settle band must reject a STALE mark (the mint leg already does
    ///      via openExposure), else a leaked signer key could settle a redeem against an outdated mark.
    function test_executeOrder_redeem_staleMark_reverts() public {
        vm.warp(block.timestamp + 10 days);
        _setBandMocks(BAND_MARK, BAND_BPS);
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.maxMarkAge.selector), abi.encode(uint256(1 hours))
        );
        vm.mockCall(
            mockVaultManager,
            abi.encodeWithSelector(IVaultManager.assetMarkUpdatedAt.selector),
            abi.encode(block.timestamp - 2 hours)
        );
        uint256 eTokenAmount = 4e18;
        uint256 price = BAND_MARK; // inside the band, but the mark is stale
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, eTokenAmount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.StaleSettleMark.selector, TSLA));
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    /// @dev The band also guards the resting-order fill path, not just market orders.
    function test_fillOrder_redeem_aboveBand_reverts() public {
        _setBandMocks(BAND_MARK, BAND_BPS);
        uint256 amount = 4e18;
        // limitPrice is the redeem minimum; set low so the band (not the limit) is what bites.
        uint256 orderId = _placeRedeem(Actors.MINTER1, amount, 100e18);
        uint256 price = 262.5e18 + 1;
        Quote memory q = _quote(orderId, Actors.MINTER1, OrderType.Redeem, amount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PriceOutOfBand.selector, TSLA, price, BAND_MARK, BAND_BPS));
        market.fillOrder(q, sig);
    }

    /// @dev With no mark, the band is skipped (open/closeExposure enforce mark presence in prod).
    function test_executeOrder_mint_zeroMark_skipsBand() public {
        _setBandMocks(0, BAND_BPS);
        uint256 amount = 1000e6;
        _fundUserForMint(Actors.MINTER1, amount);
        uint256 price = 1000e18; // wildly off; would breach the band if a mark were set
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, price);
        bytes memory sig = _sign(q, rfqVMPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), _expectedMintOut(amount, price), "minted (no mark to bound)");
    }
}
