// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDManager} from "../../../src/core/EUSDManager.sol";
import {IEUSDManager} from "../../../src/interfaces/IEUSDManager.sol";
import {BPS, PRECISION} from "../../../src/interfaces/types/Types.sol";
import {EUSD} from "../../../src/tokens/EUSD.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../../helpers/MockOracleVerifier.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title EUSDHandler — Stateful fuzz handler for EUSDManager invariants
/// @notice Exercises deposit, withdraw, mint, repay, close, liquidate, redeem, price moves and
///         time warps across multiple actors and two collaterals. Actions self-select valid
///         preconditions (bounded inputs, skip when impossible) so the campaign stays on
///         meaningful paths instead of reverting.
contract EUSDHandler is CommonBase, StdCheats, StdUtils {
    EUSDManager public immutable manager;
    EUSD public immutable eusd;
    MockOracleVerifier public immutable oracle;

    address[] internal _actors;
    MockERC20[2] internal _tokens;
    bytes32[2] internal _tickers;
    uint256[2] internal _prices;

    // Ghost accounting
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;

    constructor(
        EUSDManager manager_,
        EUSD eusd_,
        MockOracleVerifier oracle_,
        MockERC20[2] memory tokens_,
        bytes32[2] memory tickers_,
        uint256[2] memory startPrices_,
        address[] memory actors_
    ) {
        manager = manager_;
        eusd = eusd_;
        oracle = oracle_;
        _tokens = tokens_;
        _tickers = tickers_;
        _prices = startPrices_;
        _actors = actors_;

        for (uint256 i; i < actors_.length; i++) {
            for (uint256 j; j < 2; j++) {
                tokens_[j].mint(actors_[i], 1e27);
                vm.prank(actors_[i]);
                tokens_[j].approve(address(manager_), type(uint256).max);
            }
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Introspection for the invariant contract
    // ──────────────────────────────────────────────────────────

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function collaterals() external view returns (address[2] memory out) {
        out[0] = address(_tokens[0]);
        out[1] = address(_tokens[1]);
    }

    // ──────────────────────────────────────────────────────────
    //  Actions
    // ──────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 collSeed, uint256 amount) external {
        (address actor, MockERC20 token,) = _pick(actorSeed, collSeed);
        amount = bound(amount, 1, 1e22);
        vm.prank(actor);
        manager.deposit(address(token), amount, address(0));
    }

    function mint(uint256 actorSeed, uint256 collSeed, uint256 amount) external {
        (address actor, MockERC20 token, uint256 c) = _pick(actorSeed, collSeed);
        _pushFreshPrice(c);

        uint256 debt = manager.currentDebt(address(token), actor);
        uint256 coll = manager.getPosition(address(token), actor).collateral;
        uint256 collValue = Math.mulDiv(coll, _prices[c], PRECISION);
        uint256 maxTotalDebt = Math.mulDiv(collValue, BPS, manager.riskParams().mcrBps);
        if (maxTotalDebt <= debt) return;

        uint256 maxMint = maxTotalDebt - debt;
        uint256 minDebt = manager.riskParams().minDebt;
        uint256 needed = debt >= minDebt ? 1 : minDebt - debt;
        if (maxMint < needed) return;

        amount = bound(amount, needed, maxMint);
        vm.prank(actor);
        manager.mint(address(token), amount, address(0));
        ghost_totalMinted += amount;
    }

    function withdraw(uint256 actorSeed, uint256 collSeed, uint256 amount) external {
        (address actor, MockERC20 token, uint256 c) = _pick(actorSeed, collSeed);
        uint256 coll = manager.getPosition(address(token), actor).collateral;
        if (coll == 0) return;

        uint256 debt = manager.currentDebt(address(token), actor);
        uint256 maxOut;
        if (debt == 0) {
            maxOut = coll;
        } else {
            _pushFreshPrice(c);
            // Collateral needed to stay at MCR, rounded up (protocol-favorable).
            uint256 needValue = Math.mulDiv(debt, manager.riskParams().mcrBps, BPS, Math.Rounding.Ceil);
            uint256 needColl = Math.mulDiv(needValue, PRECISION, _prices[c], Math.Rounding.Ceil);
            if (coll <= needColl) return;
            maxOut = coll - needColl;
        }
        amount = bound(amount, 1, maxOut);
        vm.prank(actor);
        manager.withdrawCollateral(address(token), amount, address(0));
    }

    function repay(uint256 actorSeed, uint256 collSeed, uint256 amount) external {
        (address actor, MockERC20 token,) = _pick(actorSeed, collSeed);
        uint256 debt = manager.currentDebt(address(token), actor);
        if (debt == 0) return;

        uint256 balance = eusd.balanceOf(actor);
        if (balance == 0) return;
        uint256 minDebt = manager.riskParams().minDebt;

        uint256 repaid;
        if (balance >= debt && amount % 2 == 0) {
            repaid = debt; // full repay
        } else {
            if (debt <= minDebt) return; // partial would leave dust
            repaid = bound(amount, 1, Math.min(balance, debt - minDebt));
        }
        vm.prank(actor);
        manager.repay(address(token), actor, repaid, address(0));
        ghost_totalBurned += repaid;
    }

    function close(uint256 actorSeed, uint256 collSeed) external {
        (address actor, MockERC20 token,) = _pick(actorSeed, collSeed);
        IEUSDManager.Position memory p = manager.getPosition(address(token), actor);
        if (p.collateral == 0 && p.debt == 0) return;
        uint256 debt = manager.currentDebt(address(token), actor);
        if (eusd.balanceOf(actor) < debt) return;

        vm.prank(actor);
        manager.closePosition(address(token));
        ghost_totalBurned += debt;
    }

    function liquidate(uint256 actorSeed, uint256 collSeed, uint256 targetSeed) external {
        (, MockERC20 token,) = _pick(actorSeed, collSeed);
        address target = _actors[bound(targetSeed, 0, _actors.length - 1)];
        if (!manager.isLiquidatable(address(token), target)) return;

        uint256 debt = manager.currentDebt(address(token), target);
        // Find any actor able to fund the full repayment.
        for (uint256 i; i < _actors.length; i++) {
            address keeper = _actors[i];
            if (keeper != target && eusd.balanceOf(keeper) >= debt) {
                vm.prank(keeper);
                manager.liquidate(address(token), target);
                ghost_totalBurned += debt;
                return;
            }
        }
    }

    function redeem(uint256 actorSeed, uint256 collSeed, uint256 amount) external {
        (address actor, MockERC20 token,) = _pick(actorSeed, collSeed);
        if (manager.listHead(address(token)) == address(0)) return;
        uint256 balance = eusd.balanceOf(actor);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        vm.prank(actor);
        (, uint256 repaid) = manager.redeem(address(token), amount, 0, 0, address(0));
        ghost_totalBurned += repaid;
    }

    function movePrice(uint256 collSeed, uint256 factorSeed) external {
        uint256 c = bound(collSeed, 0, 1);
        uint256 factorBps = bound(factorSeed, 7000, 13_000);
        uint256 newPrice = _prices[c] * factorBps / BPS;
        if (newPrice < 50e18) newPrice = 50e18;
        if (newPrice > 5000e18) newPrice = 5000e18;
        _prices[c] = newPrice;
        oracle.setPrice(_tickers[c], newPrice);
    }

    function warp(
        uint256 secondsSeed
    ) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 3 days));
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    function _pick(
        uint256 actorSeed,
        uint256 collSeed
    ) private view returns (address actor, MockERC20 token, uint256 c) {
        actor = _actors[bound(actorSeed, 0, _actors.length - 1)];
        c = bound(collSeed, 0, 1);
        token = _tokens[c];
    }

    /// @dev Re-attest the current price at the current timestamp so mint-path freshness holds.
    function _pushFreshPrice(
        uint256 c
    ) private {
        oracle.setPrice(_tickers[c], _prices[c]);
    }
}
