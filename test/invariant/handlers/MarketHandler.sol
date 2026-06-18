// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnMarket} from "../../../src/core/OwnMarket.sol";
import {OwnVault} from "../../../src/core/OwnVault.sol";

import {IOwnMarket} from "../../../src/interfaces/IOwnMarket.sol";
import {IVaultManager} from "../../../src/interfaces/IVaultManager.sol";
import {BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../../../src/interfaces/types/Types.sol";
import {EToken} from "../../../src/tokens/EToken.sol";

import {Actors} from "../../helpers/Actors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../../helpers/MockOracleVerifier.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title MarketHandler — Invariant test handler for the RFQ OwnMarket
/// @notice Exercises the resting-order lifecycle (place → fill / cancel / expire / force) with
///         fuzzed inputs. Fills are settled against quotes signed by the vault's VM key.
contract MarketHandler is CommonBase, StdCheats, StdUtils {
    OwnMarket public market;
    OwnVault public vault;
    MockERC20 public usdc;
    EToken public eTSLA;
    MockOracleVerifier public oracle;

    bytes32 public constant TSLA = bytes32("TSLA");
    bytes32 public constant ETH_ASSET = bytes32("ETH");
    uint256 public constant TSLA_PRICE = 250e18;
    uint256 public constant ETH_PRICE = 3000e18;

    address[] public minters;
    /// @dev The global signer's linked settlement address: mint proceeds flow to it,
    ///      redeem payouts are funded from it.
    address public linkedAddr;
    uint256 public vmPk;

    // ── Ghost variables ─────────────────────────────────────────

    /// @dev Sum over OPEN mint orders of (amount - filledAmount). Should match market USDC escrow.
    uint256 public ghost_escrowedStablecoins;
    /// @dev Sum over OPEN redeem orders of (amount - filledAmount). Should match market eToken escrow.
    uint256 public ghost_escrowedETokens;

    uint256[] public ghost_openMintIds;
    uint256[] public ghost_openRedeemIds;

    uint256 public ghost_callCount_placeMint;
    uint256 public ghost_callCount_placeRedeem;
    uint256 public ghost_callCount_fill;

    uint256 private _quoteNonce = 1;

    // ── Constructor ─────────────────────────────────────────────

    constructor(address _market, address _vault, address _usdc, address _eTSLA, address _oracle, uint256 _vmPk) {
        market = OwnMarket(_market);
        vault = OwnVault(_vault);
        usdc = MockERC20(_usdc);
        eTSLA = EToken(_eTSLA);
        oracle = MockOracleVerifier(_oracle);
        vmPk = _vmPk;
        // The keyed signer (vmPk -> vm1Signer) is registered globally with Actors.VM1 as its
        // linked settlement address, so mint proceeds and redeem payouts settle through VM1.
        linkedAddr = Actors.VM1;

        minters.push(Actors.MINTER1);
        minters.push(Actors.MINTER2);
    }

    // ── Order placement ─────────────────────────────────────────

    function placeMintOrder(uint256 actorSeed, uint256 amount, uint256 expirySeed) external {
        address minter = minters[bound(actorSeed, 0, minters.length - 1)];
        amount = bound(amount, 1e6, 100_000e6); // 1 to 100k USDC
        uint256 expiry = block.timestamp + bound(expirySeed, 1 hours, 7 days);

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);

        usdc.mint(minter, amount);

        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, amount, TSLA_PRICE, expiry);
        vm.stopPrank();

        ghost_escrowedStablecoins += amount;
        ghost_openMintIds.push(orderId);
        ghost_callCount_placeMint++;
    }

    function placeRedeemOrder(uint256 actorSeed, uint256 amount, uint256 expirySeed) external {
        address minter = minters[bound(actorSeed, 0, minters.length - 1)];
        uint256 bal = eTSLA.balanceOf(minter);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);
        uint256 expiry = block.timestamp + bound(expirySeed, 1 hours, 7 days);

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);

        vm.startPrank(minter);
        eTSLA.approve(address(market), amount);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, amount, TSLA_PRICE, expiry);
        vm.stopPrank();

        ghost_escrowedETokens += amount;
        ghost_openRedeemIds.push(orderId);
        ghost_callCount_placeRedeem++;
    }

    // ── VM fill (full or partial) ───────────────────────────────

    function fillMintOrder(uint256 idSeed, uint256 fillSeed) external {
        uint256 len = ghost_openMintIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openMintIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openMintIds, idx);
            return;
        }
        if (block.timestamp > order.expiry) return;

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, ETH_PRICE, block.timestamp);
        // Keeper refreshes the VaultManager mark so the openExposure freshness gate stays satisfied
        // after time warps; otherwise the fill would silently revert into the catch below.
        IVaultManager(market.registry().vaultManager()).pullAssetPrice(TSLA);

        uint256 remaining = order.amount - order.filledAmount;
        uint256 fill = bound(fillSeed, 1, remaining);

        Quote memory q = _quote(orderId, order.user, OrderType.Mint, fill, TSLA_PRICE);
        try market.fillOrder(q, _sign(q)) {
            ghost_escrowedStablecoins -= fill;
            ghost_callCount_fill++;
            if (fill == remaining) _removeFromArray(ghost_openMintIds, idx);
        } catch {
            // Utilization breach or transient failure — leave state unchanged.
        }
    }

    function fillRedeemOrder(uint256 idSeed, uint256 fillSeed) external {
        uint256 len = ghost_openRedeemIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openRedeemIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openRedeemIds, idx);
            return;
        }
        if (block.timestamp > order.expiry) return;

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, ETH_PRICE, block.timestamp);

        uint256 remaining = order.amount - order.filledAmount;
        uint256 fill = bound(fillSeed, 1, remaining);

        // The signer's linked address funds the gross payout (net to user + fee to vault).
        uint256 decimals = IERC20Metadata(address(usdc)).decimals();
        uint256 grossPayout = Math.mulDiv(fill, TSLA_PRICE, PRECISION * 10 ** (18 - decimals));
        usdc.mint(linkedAddr, grossPayout);
        vm.prank(linkedAddr);
        usdc.approve(address(market), grossPayout);

        Quote memory q = _quote(orderId, order.user, OrderType.Redeem, fill, TSLA_PRICE);
        try market.fillOrder(q, _sign(q)) {
            ghost_escrowedETokens -= fill;
            ghost_callCount_fill++;
            if (fill == remaining) _removeFromArray(ghost_openRedeemIds, idx);
        } catch {
            // Leave state unchanged on failure.
        }
    }

    // ── Cancel / Expire ─────────────────────────────────────────

    function cancelMintOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_openMintIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openMintIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openMintIds, idx);
            return;
        }

        vm.prank(order.user);
        market.cancelOrder(orderId);

        ghost_escrowedStablecoins -= (order.amount - order.filledAmount);
        _removeFromArray(ghost_openMintIds, idx);
    }

    function cancelRedeemOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_openRedeemIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openRedeemIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openRedeemIds, idx);
            return;
        }

        vm.prank(order.user);
        market.cancelOrder(orderId);

        ghost_escrowedETokens -= (order.amount - order.filledAmount);
        _removeFromArray(ghost_openRedeemIds, idx);
    }

    function expireMintOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_openMintIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openMintIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openMintIds, idx);
            return;
        }

        if (block.timestamp <= order.expiry) {
            vm.warp(order.expiry + 1);
            oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
            oracle.setPrice(ETH_ASSET, ETH_PRICE, block.timestamp);
        }

        market.expireOrder(orderId);

        ghost_escrowedStablecoins -= (order.amount - order.filledAmount);
        _removeFromArray(ghost_openMintIds, idx);
    }

    function expireRedeemOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_openRedeemIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openRedeemIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openRedeemIds, idx);
            return;
        }

        if (block.timestamp <= order.expiry) {
            vm.warp(order.expiry + 1);
            oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
            oracle.setPrice(ETH_ASSET, ETH_PRICE, block.timestamp);
        }

        market.expireOrder(orderId);

        ghost_escrowedETokens -= (order.amount - order.filledAmount);
        _removeFromArray(ghost_openRedeemIds, idx);
    }

    // ── Redeem force execution (user recourse) ──────────────────

    function forceExecuteRedeemOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_openRedeemIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_openRedeemIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Open) {
            _removeFromArray(ghost_openRedeemIds, idx);
            return;
        }

        // Warp past the (now global) claim threshold so force execution is allowed.
        uint256 claimThreshold = IVaultManager(market.registry().vaultManager()).claimThreshold();
        uint256 forceTime = order.createdAt + claimThreshold + 1;
        if (block.timestamp < forceTime) {
            vm.warp(forceTime);
        }
        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, ETH_PRICE, block.timestamp);

        bytes memory assetPriceData = abi.encode(TSLA_PRICE, block.timestamp);
        bytes memory collateralPriceData = abi.encode(ETH_PRICE, block.timestamp);

        uint256 remaining = order.amount - order.filledAmount;
        vm.prank(order.user);
        try market.forceExecuteOrder(orderId, address(vault), assetPriceData, collateralPriceData) {
            ghost_escrowedETokens -= remaining;
            _removeFromArray(ghost_openRedeemIds, idx);
        } catch {
            // Price-below-minimum or other failure — leave state unchanged.
        }
    }

    // ── Time & oracle management ────────────────────────────────

    function warpForward(
        uint256 seconds_
    ) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, ETH_PRICE, block.timestamp);
    }

    // ── View helpers ────────────────────────────────────────────

    function openMintCount() external view returns (uint256) {
        return ghost_openMintIds.length;
    }

    function openRedeemCount() external view returns (uint256) {
        return ghost_openRedeemIds.length;
    }

    // ── Internal helpers ────────────────────────────────────────

    function _quote(
        uint256 orderId,
        address user,
        OrderType orderType,
        uint256 amount,
        uint256 price
    ) private returns (Quote memory q) {
        q = Quote({
            orderId: orderId,
            user: user,
            asset: TSLA,
            orderType: orderType,
            amount: amount,
            price: price,
            quoteId: _quoteNonce++,
            expiry: block.timestamp + 1 days
        });
    }

    function _sign(
        Quote memory q
    ) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vmPk, market.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _removeFromArray(uint256[] storage arr, uint256 idx) private {
        uint256 len = arr.length;
        arr[idx] = arr[len - 1];
        arr.pop();
    }
}
