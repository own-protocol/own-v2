// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {LiquidityManagerSetup} from "../helpers/LiquidityManagerSetup.sol";
import {LiquidityManagerHandler} from "./handlers/LiquidityManagerHandler.sol";

/// @title EUSDLiquidityManagerInvariantTest — stateful fuzz invariants for the liquidity manager
/// @notice After any sequence of operations:
///         1. eUSD supply == manager.totalDebt + eUSD minted outside the manager by the handler
///         2. manager.totalDebt == Σ position debt
///         3. every debt is zero or at least minDebt
///         4. each vault's ledger shares equal its liquidity, staked in full or not at all as the
///            position says
///         5. the manager itself holds no tokens
contract EUSDLiquidityManagerInvariantTest is LiquidityManagerSetup {
    LiquidityManagerHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = attacker;
        handler = new LiquidityManagerHandler(
            manager, eusd, oracle, ledger, spy, SPY, SPY_POOL, spyKey, SPY_PRICE, actors, keeper
        );
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(handler));
        vm.stopPrank();
        handler.fundPool();

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.addLiquidity.selector;
        selectors[1] = handler.removeLiquidity.selector;
        selectors[2] = handler.rebalance.selector;
        selectors[3] = handler.setStaked.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.repay.selector;
        selectors[6] = handler.close.selector;
        selectors[7] = handler.liquidate.selector;
        selectors[8] = handler.movePrice.selector;
        selectors[9] = handler.warp.selector;
        selectors[10] = handler.fundPool.selector;
        selectors[11] = handler.closePrincipalOnly.selector;
        selectors[12] = handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyMatchesDebt() public view {
        assertEq(eusd.totalSupply(), manager.totalDebt() + handler.ghost_outsideMinted());
    }

    function invariant_totalDebtIsSumOfPositions() public view {
        address[] memory actors = handler.actors();
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            sum += manager.getPosition(SPY_POOL, actors[i]).debt;
        }
        assertEq(manager.totalDebt(), sum);
    }

    function invariant_debtZeroOrAboveMin() public view {
        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; i++) {
            uint256 debt = manager.getPosition(SPY_POOL, actors[i]).debt;
            assertTrue(debt == 0 || debt >= MIN_DEBT);
        }
    }

    function invariant_vaultSharesMatchLedger() public view {
        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; i++) {
            IEUSDLiquidityManager.Position memory p = manager.getPosition(SPY_POOL, actors[i]);
            if (p.vault == address(0)) continue;
            FablesAdapter v = FablesAdapter(p.vault);
            (int24 lower, int24 upper, uint128 liquidity) = v.range();
            uint256 id = ledger.rangeId(spyKey, lower, upper);
            assertEq(v.staked(), p.staked);
            if (liquidity == 0) continue;
            assertEq(ledger.balanceOf(p.vault, id), liquidity);
            assertEq(ledger.stakedOf(p.vault, id), p.staked ? liquidity : 0);
        }
    }

    function invariant_managerHoldsNothing() public view {
        assertEq(eusd.balanceOf(address(manager)), 0);
        assertEq(spy.balanceOf(address(manager)), 0);
    }
}
