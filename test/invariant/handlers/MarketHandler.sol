// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FeeCalculator} from "../../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../../src/core/OwnMarket.sol";
import {OwnVault} from "../../../src/core/OwnVault.sol";

import {BPS, Order, OrderStatus, OrderType, PRECISION} from "../../../src/interfaces/types/Types.sol";
import {EToken} from "../../../src/tokens/EToken.sol";

import {Actors} from "../../helpers/Actors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../../helpers/MockOracleVerifier.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title MarketHandler — Invariant test handler for OwnMarket
/// @notice Exercises the full order lifecycle with fuzzed inputs.
contract MarketHandler is CommonBase, StdCheats, StdUtils {
    OwnMarket public market;
    OwnVault public vault;
    FeeCalculator public feeCalc;
    MockERC20 public usdc;
    EToken public eTSLA;
    MockOracleVerifier public oracle;

    bytes32 public constant TSLA = bytes32("TSLA");
    bytes32 public constant ETH_ASSET = bytes32("ETH");
    uint256 public constant TSLA_PRICE = 250e18;

    address[] public minters;
    address public vmAddr;

    // ── Ghost variables ─────────────────────────────────────────

    uint256 public ghost_escrowedStablecoins;
    uint256 public ghost_escrowedMintFees;
    uint256 public ghost_escrowedETokens;

    uint256[] public ghost_openMintIds;
    uint256[] public ghost_openRedeemIds;
    uint256[] public ghost_claimedMintIds;
    uint256[] public ghost_claimedRedeemIds;

    mapping(uint256 => uint256) public ghost_orderAmount;
    mapping(uint256 => uint256) public ghost_orderFee;

    uint256 public ghost_callCount_placeMint;
    uint256 public ghost_callCount_placeRedeem;
    uint256 public ghost_callCount_claim;
    uint256 public ghost_callCount_confirm;

    // ── Constructor ─────────────────────────────────────────────

    constructor(address _market, address _vault, address _feeCalc, address _usdc, address _eTSLA, address _oracle) {
        market = OwnMarket(_market);
        vault = OwnVault(_vault);
        feeCalc = FeeCalculator(_feeCalc);
        usdc = MockERC20(_usdc);
        eTSLA = EToken(_eTSLA);
        oracle = MockOracleVerifier(_oracle);
        vmAddr = Actors.VM1;

        minters.push(Actors.MINTER1);
        minters.push(Actors.MINTER2);
    }

    // ── Order placement ─────────────────────────────────────────

    function placeMintOrder(uint256 actorSeed, uint256 amount, uint256 expirySeed) external {
        address minter = minters[bound(actorSeed, 0, minters.length - 1)];
        amount = bound(amount, 1e6, 100_000e6); // 1 to 100k USDC
        uint256 expiry = block.timestamp + bound(expirySeed, 1 hours, 7 days);

        // Refresh oracle so prices are fresh
        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);

        usdc.mint(minter, amount);

        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, amount, TSLA_PRICE, expiry);
        vm.stopPrank();

        ghost_escrowedStablecoins += amount;
        ghost_openMintIds.push(orderId);
        ghost_orderAmount[orderId] = amount;
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
        uint256 orderId = market.placeRedeemOrder(address(vault), TSLA, amount, TSLA_PRICE, expiry);
        vm.stopPrank();

        ghost_escrowedETokens += amount;
        ghost_openRedeemIds.push(orderId);
        ghost_orderAmount[orderId] = amount;
        ghost_callCount_placeRedeem++;
    }

    // ── VM claim ────────────────────────────────────────────────

    function claimMintOrder(
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
        if (block.timestamp > order.expiry) return;

        // Refresh oracle
        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);

        vm.prank(vmAddr);
        market.claimOrder(orderId);

        // Compute fee
        uint256 feeBps = feeCalc.getMintFee(TSLA, order.amount);
        uint256 feeAmount = Math.mulDiv(order.amount, feeBps, BPS, Math.Rounding.Ceil);

        // Stablecoins: full amount was escrowed at placement. Now (amount - fee) released to VM, fee stays.
        ghost_escrowedStablecoins -= order.amount;
        ghost_escrowedMintFees += feeAmount;
        ghost_orderFee[orderId] = feeAmount;

        _removeFromArray(ghost_openMintIds, idx);
        ghost_claimedMintIds.push(orderId);
        ghost_callCount_claim++;
    }

    function claimRedeemOrder(
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
        if (block.timestamp > order.expiry) return;

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);

        vm.prank(vmAddr);
        market.claimOrder(orderId);

        // eTokens stay in escrow — no ghost change
        _removeFromArray(ghost_openRedeemIds, idx);
        ghost_claimedRedeemIds.push(orderId);
        ghost_callCount_claim++;
    }

    // ── VM confirm ──────────────────────────────────────────────

    function confirmMintOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_claimedMintIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_claimedMintIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Claimed) {
            _removeFromArray(ghost_claimedMintIds, idx);
            return;
        }
        if (block.timestamp > order.expiry) return;

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);

        bytes memory proof = abi.encode(TSLA_PRICE, block.timestamp);
        bytes memory priceProofData = abi.encode(proof, proof, uint8(0));

        vm.prank(vmAddr);
        market.confirmOrder(orderId, priceProofData);

        // Fee moved from escrow to vault
        ghost_escrowedMintFees -= ghost_orderFee[orderId];

        _removeFromArray(ghost_claimedMintIds, idx);
        ghost_callCount_confirm++;
    }

    function confirmRedeemOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_claimedRedeemIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_claimedRedeemIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Claimed) {
            _removeFromArray(ghost_claimedRedeemIds, idx);
            return;
        }
        if (block.timestamp > order.expiry) return;

        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);

        // VM needs to pay gross payout to user + fee to vault
        uint256 decimals = IERC20Metadata(address(usdc)).decimals();
        uint256 precisionWithDecimals = PRECISION * 10 ** (18 - decimals);
        uint256 grossPayout = Math.mulDiv(order.amount, order.price, precisionWithDecimals);
        uint256 feeBps = feeCalc.getRedeemFee(TSLA, order.amount);
        uint256 feeAmount = Math.mulDiv(grossPayout, feeBps, BPS, Math.Rounding.Ceil);

        // Fund VM with stablecoins for payout
        usdc.mint(vmAddr, grossPayout);
        vm.startPrank(vmAddr);
        usdc.approve(address(market), grossPayout);
        bytes memory proof = abi.encode(TSLA_PRICE, block.timestamp);
        bytes memory redeemProofData = abi.encode(proof, proof, uint8(0));
        market.confirmOrder(orderId, redeemProofData);
        vm.stopPrank();

        // eTokens burned from market escrow
        ghost_escrowedETokens -= order.amount;

        _removeFromArray(ghost_claimedRedeemIds, idx);
        ghost_callCount_confirm++;
    }

    // ── Cancel / Expire / Close ─────────────────────────────────

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

        ghost_escrowedStablecoins -= order.amount;
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

        ghost_escrowedETokens -= order.amount;
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

        // Warp past expiry
        if (block.timestamp <= order.expiry) {
            vm.warp(order.expiry + 1);
            // Refresh oracle timestamps
            oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
            oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);
        }

        market.expireOrder(orderId);

        ghost_escrowedStablecoins -= order.amount;
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
            oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);
        }

        market.expireOrder(orderId);

        ghost_escrowedETokens -= order.amount;
        _removeFromArray(ghost_openRedeemIds, idx);
    }

    function closeMintOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_claimedMintIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_claimedMintIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Claimed) {
            _removeFromArray(ghost_claimedMintIds, idx);
            return;
        }

        // Warp past expiry
        if (block.timestamp <= order.expiry) {
            vm.warp(order.expiry + 1);
            oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
            oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);
        }

        uint256 feeAmount = ghost_orderFee[orderId];

        // VM must send back (amount - fee) to user via safeTransferFrom
        usdc.mint(vmAddr, order.amount - feeAmount);
        vm.startPrank(vmAddr);
        usdc.approve(address(market), order.amount - feeAmount);
        market.closeOrder(orderId);
        vm.stopPrank();

        // Fee returned to user from escrow
        ghost_escrowedMintFees -= feeAmount;

        _removeFromArray(ghost_claimedMintIds, idx);
    }

    function closeRedeemOrder(
        uint256 idSeed
    ) external {
        uint256 len = ghost_claimedRedeemIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 orderId = ghost_claimedRedeemIds[idx];

        Order memory order = market.getOrder(orderId);
        if (order.status != OrderStatus.Claimed) {
            _removeFromArray(ghost_claimedRedeemIds, idx);
            return;
        }

        if (block.timestamp <= order.expiry) {
            vm.warp(order.expiry + 1);
            oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
            oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);
        }

        vm.prank(vmAddr);
        market.closeOrder(orderId);

        // eTokens returned to user
        ghost_escrowedETokens -= order.amount;

        _removeFromArray(ghost_claimedRedeemIds, idx);
    }

    // ── Time & oracle management ────────────────────────────────

    function warpForward(
        uint256 seconds_
    ) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);

        // Keep oracle fresh
        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(ETH_ASSET, 3000e18, block.timestamp);
    }

    // ── View helpers ────────────────────────────────────────────

    function openMintCount() external view returns (uint256) {
        return ghost_openMintIds.length;
    }

    function openRedeemCount() external view returns (uint256) {
        return ghost_openRedeemIds.length;
    }

    function claimedMintCount() external view returns (uint256) {
        return ghost_claimedMintIds.length;
    }

    function claimedRedeemCount() external view returns (uint256) {
        return ghost_claimedRedeemIds.length;
    }

    // ── Internal helpers ────────────────────────────────────────

    function _removeFromArray(uint256[] storage arr, uint256 idx) private {
        uint256 len = arr.length;
        arr[idx] = arr[len - 1];
        arr.pop();
    }
}
