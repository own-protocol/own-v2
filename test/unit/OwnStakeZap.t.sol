// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {OwnStakingV2} from "../../src/core/OwnStakingV2.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {IOwnStakeZap} from "../../src/interfaces/IOwnStakeZap.sol";
import {IOwnStakingV2} from "../../src/interfaces/IOwnStakingV2.sol";
import {OwnStakeZap} from "../../src/periphery/OwnStakeZap.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {deployEUSDManager, deployStakedEUSD} from "../helpers/DeployEusdModule.sol";
import {MockAssetRegistry} from "../helpers/MockAssetRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {MockPsmMarket} from "../helpers/MockPsmMarket.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {MockVaultManager} from "../helpers/MockVaultManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract OwnStakeZapTest is Test {
    ProtocolRegistry internal registry;
    MockOracleVerifier internal oracle;
    MockAssetRegistry internal assetRegistry;
    MockVaultManager internal vaultManager;
    EUSD internal eusd;
    MockERC20 internal eSPY;
    MockERC20 internal spy;
    MockERC20 internal money;
    EUSDManager internal manager;
    OwnStakingV2 internal staking;
    StakedEUSD internal sEusd;
    MockPsmMarket internal psm;
    MockSwapRouter internal router;
    OwnStakeZap internal zap;

    address internal admin = Actors.ADMIN;
    address internal operator = address(uint160(uint256(keccak256("operator"))));
    address internal safe = address(uint160(uint256(keccak256("safe"))));
    address internal treasury = address(uint160(uint256(keccak256("treasury"))));
    address internal alice = Actors.MINTER1;
    address internal attacker = Actors.ATTACKER;

    bytes32 internal constant SPY_TICKER = bytes32("SPY");
    bytes32 internal constant MONEY_TICKER = bytes32("MONEY");
    uint256 internal constant SPY_PRICE = 500e18;
    uint256 internal constant MONEY_PRICE = 0.002e18;

    function setUp() public {
        vm.warp(1_000_000);

        registry = new ProtocolRegistry(admin, 2 days, 300);
        oracle = new MockOracleVerifier();
        assetRegistry = new MockAssetRegistry();
        vaultManager = new MockVaultManager();

        vm.startPrank(admin);
        registry.setAddress(keccak256("INHOUSE_ORACLE"), address(oracle));
        registry.setAddress(keccak256("ASSET_REGISTRY"), address(assetRegistry));
        registry.setAddress(keccak256("VAULT_MANAGER"), address(vaultManager));
        registry.setAddress(keccak256("TREASURY"), treasury);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), operator);
        vm.stopPrank();

        eSPY = new MockERC20("eSPY", "eSPY", 18);
        spy = new MockERC20("Robinhood SPY", "R.SPY", 18);
        money = new MockERC20("Money", "MONEY", 18);
        assetRegistry.setOracleType(SPY_TICKER, 1);
        assetRegistry.setValidToken(SPY_TICKER, address(eSPY), true);
        oracle.setPrice(SPY_TICKER, SPY_PRICE);
        oracle.setPrice(MONEY_TICKER, MONEY_PRICE);

        eusd = new EUSD(admin);
        manager = deployEUSDManager(
            address(registry),
            address(eusd),
            IEUSDManager.RiskParams({
                mcrBps: 15_000,
                liquidationThresholdBps: 13_000,
                liquidationBonusBps: 500,
                stabilityFeeBps: 200,
                debtCeiling: 10_000_000e18,
                minDebt: 100e18,
                mintPriceMaxAge: 300
            })
        );

        IOwnStakingV2.Knot[] memory knots = new IOwnStakingV2.Knot[](4);
        knots[0] = IOwnStakingV2.Knot(0, 1000);
        knots[1] = IOwnStakingV2.Knot(10_000, 4000);
        knots[2] = IOwnStakingV2.Knot(20_000, 12_000);
        knots[3] = IOwnStakingV2.Knot(30_000, 36_000);
        OwnStakingV2 stakingImpl = new OwnStakingV2();
        staking = OwnStakingV2(
            address(
                new ERC1967Proxy(
                    address(stakingImpl),
                    abi.encodeCall(
                        OwnStakingV2.initialize,
                        (address(registry), address(eusd), address(money), address(spy), safe, knots)
                    )
                )
            )
        );

        sEusd = deployStakedEUSD(address(registry), address(eusd), 8 hours);
        psm = new MockPsmMarket(eSPY);
        router = new MockSwapRouter();
        money.mint(address(router), 1e12 * 1e18);

        OwnStakeZap zapImpl = new OwnStakeZap();
        zap = OwnStakeZap(
            address(new ERC1967Proxy(address(zapImpl), abi.encodeCall(OwnStakeZap.initialize, (_zapConfig()))))
        );

        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(manager));
        eusd.grantRole(eusd.MINTER_ROLE(), address(this));
        manager.addCollateral(address(eSPY), SPY_TICKER);
        manager.setStakeZap(address(zap));
        staking.setZap(address(zap));
        vm.stopPrank();

        // Seed sEUSD dead shares so migration tests can deposit.
        eusd.mint(address(this), 1e18);
        eusd.approve(address(sEusd), type(uint256).max);
        sEusd.deposit(1e18, address(0xdead));

        // Reward source for compound tests.
        spy.mint(safe, 1_000_000e18);
        vm.prank(safe);
        spy.approve(address(staking), type(uint256).max);

        spy.mint(alice, 1_000_000e18);
        money.mint(alice, 1e12 * 1e18);
        eusd.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        spy.approve(address(zap), type(uint256).max);
        money.approve(address(zap), type(uint256).max);
        eusd.approve(address(zap), type(uint256).max);
        eusd.approve(address(sEusd), type(uint256).max);
        sEusd.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev $MONEY units (18 dec) whose oracle value equals `usd` whole dollars.
    function _moneyFor(
        uint256 usd
    ) internal pure returns (uint256) {
        return usd * 1e18 * 1e18 / MONEY_PRICE;
    }

    function _zapConfig() internal view returns (IOwnStakeZap.InitConfig memory) {
        return IOwnStakeZap.InitConfig({
            registry: address(registry),
            eusdManager: address(manager),
            staking: address(staking),
            market: address(psm),
            sEusd: address(sEusd),
            eusd: address(eusd),
            money: address(money),
            spy: address(spy),
            collateral: address(eSPY),
            collateralTicker: SPY_TICKER,
            swapRouter: address(router)
        });
    }

    // ──────────────────────────────────────────────────────────
    //  SPY entries
    // ──────────────────────────────────────────────────────────

    function test_stakeFromSpyAndMoney_buildsFullBasket() public {
        // 10 SPY @ $500 → $5,000 collateral; mint 1,000 eUSD (ratio 500%); 1:1 $MONEY coverage.
        uint256 moneyAmt = _moneyFor(1000);
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(10e18, moneyAmt, 1000e18, address(0));

        IEUSDManager.Position memory cdp = manager.getPosition(address(eSPY), alice);
        assertEq(cdp.collateral, 10e18, "collateral deposited for alice");
        assertEq(cdp.debt, 1000e18, "debt on alice");

        IOwnStakingV2.Position memory pos = staking.position(alice);
        assertEq(pos.eusdStaked, 1000e18, "minted eUSD staked");
        assertEq(pos.moneyStaked, moneyAmt, "money staked");
        assertEq(staking.boostBps(alice), 4000, "1:1 coverage boost");

        // Zap is stateless: nothing stranded.
        assertEq(spy.balanceOf(address(zap)), 0);
        assertEq(eusd.balanceOf(address(zap)), 0);
        assertEq(money.balanceOf(address(zap)), 0);
        assertEq(eSPY.balanceOf(address(zap)), 0);
    }

    function test_stakeFromSpyAndMoney_depositOnly() public {
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(10e18, 0, 0, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 10e18);
        assertEq(staking.position(alice).eusdStaked, 0, "nothing staked without mint");
    }

    function test_stakeFromSpy_swapsSliceForMoney() public {
        uint256 moneyOut = _moneyFor(1500);
        bytes memory swapData = abi.encodeCall(MockSwapRouter.swap, (address(spy), 3e18, address(money), moneyOut));

        vm.prank(alice);
        zap.stakeFromSpy(10e18, 3e18, moneyOut, swapData, 1000e18, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).collateral, 7e18, "unswapped SPY became collateral");
        IOwnStakingV2.Position memory pos = staking.position(alice);
        assertEq(pos.moneyStaked, moneyOut, "swap output staked");
        assertEq(pos.eusdStaked, 1000e18);
        assertEq(spy.balanceOf(address(zap)), 0);
    }

    function test_stakeFromSpy_slippage_reverts() public {
        uint256 moneyOut = _moneyFor(1500);
        bytes memory swapData = abi.encodeCall(MockSwapRouter.swap, (address(spy), 3e18, address(money), moneyOut - 1));
        vm.expectRevert(abi.encodeWithSelector(IOwnStakeZap.InsufficientMoneyOut.selector, moneyOut - 1, moneyOut));
        vm.prank(alice);
        zap.stakeFromSpy(10e18, 3e18, moneyOut, swapData, 1000e18, address(0));
    }

    function test_stakeFromSpy_swapReverts_bubbles() public {
        bytes memory swapData = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.expectRevert(IOwnStakeZap.SwapFailed.selector);
        vm.prank(alice);
        zap.stakeFromSpy(10e18, 3e18, 1, swapData, 0, address(0));
    }

    function test_stakeFromSpy_zeroFloorWithSwap_reverts() public {
        vm.expectRevert(IOwnStakeZap.ZeroAmount.selector);
        vm.prank(alice);
        zap.stakeFromSpy(10e18, 3e18, 0, "", 0, address(0));
    }

    function test_stakeFromSpy_sliceOverTotal_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnStakeZap.InvalidSplit.selector, 11e18, 10e18));
        vm.prank(alice);
        zap.stakeFromSpy(10e18, 11e18, 1, "", 0, address(0));
    }

    function test_stakeFromSpy_routerCannotSpendOtherUsers() public {
        // The router only ever gets an allowance for the caller's own in-flight slice; calldata
        // trying to pull more than the slice fails on allowance.
        bytes memory swapData = abi.encodeCall(MockSwapRouter.swap, (address(spy), 5e18, address(money), _moneyFor(1)));
        vm.expectRevert(IOwnStakeZap.SwapFailed.selector);
        vm.prank(alice);
        zap.stakeFromSpy(10e18, 3e18, 1, swapData, 0, address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  eUSD / sEUSD entries
    // ──────────────────────────────────────────────────────────

    function test_stakeFromEusdAndMoney() public {
        uint256 moneyAmt = _moneyFor(3000);
        vm.prank(alice);
        zap.stakeFromEusdAndMoney(1000e18, moneyAmt);
        assertEq(staking.position(alice).eusdStaked, 1000e18);
        assertEq(staking.boostBps(alice), 36_000, "3:1 coverage");
    }

    function test_stakeFromEusdAndMoney_zeroBoth_reverts() public {
        vm.expectRevert(IOwnStakeZap.ZeroAmount.selector);
        vm.prank(alice);
        zap.stakeFromEusdAndMoney(0, 0);
    }

    function test_stakeFromSeusd_migrates() public {
        vm.prank(alice);
        uint256 shares = sEusd.deposit(500e18, alice);

        uint256 moneyAmt = _moneyFor(500);
        vm.prank(alice);
        zap.stakeFromSeusd(shares, moneyAmt);

        IOwnStakingV2.Position memory pos = staking.position(alice);
        assertApproxEqAbs(pos.eusdStaked, 500e18, 2, "redeemed eUSD staked");
        assertEq(pos.moneyStaked, moneyAmt);
        assertEq(sEusd.balanceOf(alice), 0, "shares fully migrated");
    }

    // ──────────────────────────────────────────────────────────
    //  Compound & rebalance
    // ──────────────────────────────────────────────────────────

    function test_compound_turnsRewardsIntoCollateral() public {
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(10e18, _moneyFor(1000), 1000e18, address(0));

        vm.prank(operator);
        staking.notifyRewardAmount(700e18);
        vm.warp(block.timestamp + 7 days);
        uint256 earned = staking.earned(alice);
        assertGt(earned, 0);

        uint256 collBefore = manager.getPosition(address(eSPY), alice).collateral;
        vm.prank(alice);
        zap.compound(address(0));

        assertEq(staking.earned(alice), 0, "rewards claimed");
        assertEq(
            manager.getPosition(address(eSPY), alice).collateral, collBefore + earned, "rewards became collateral 1:1"
        );
        assertEq(spy.balanceOf(address(zap)), 0);
    }

    function test_compound_nothingEarned_reverts() public {
        vm.expectRevert(IOwnStakeZap.NothingToCompound.selector);
        vm.prank(alice);
        zap.compound(address(0));
    }

    function test_rebalance_repaysDebt() public {
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(10e18, 0, 1000e18, address(0));

        vm.prank(alice);
        zap.rebalance(400e18, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).debt, 600e18, "debt repaid");
        assertEq(staking.position(alice).eusdStaked, 600e18, "staked eUSD unwound");
        assertEq(eusd.balanceOf(address(zap)), 0);
    }

    function test_rebalance_overshoot_returnsLeftover() public {
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(10e18, 0, 1000e18, address(0));

        // Pay the debt down to 150 out-of-band, then unwind more than remains.
        vm.startPrank(alice);
        eusd.approve(address(manager), type(uint256).max);
        manager.repay(address(eSPY), alice, 850e18, address(0));

        uint256 balBefore = eusd.balanceOf(alice);
        zap.rebalance(500e18, address(0));
        vm.stopPrank();

        assertEq(manager.getPosition(address(eSPY), alice).debt, 0, "debt cleared");
        assertEq(eusd.balanceOf(alice) - balBefore, 350e18, "excess returned to alice");
        assertEq(staking.position(alice).eusdStaked, 500e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Gating
    // ──────────────────────────────────────────────────────────

    function test_onBehalfSurfaces_rejectNonZap() public {
        vm.startPrank(attacker);
        vm.expectRevert(IEUSDManager.OnlyZap.selector);
        manager.depositFor(alice, address(eSPY), 1e18, address(0));
        vm.expectRevert(IEUSDManager.OnlyZap.selector);
        manager.mintFor(alice, address(eSPY), 100e18, address(0));
        vm.expectRevert(IOwnStakingV2.OnlyZap.selector);
        staking.unstakeFor(alice, 0, 1e18);
        vm.expectRevert(IOwnStakingV2.OnlyZap.selector);
        staking.claimFor(alice);
        vm.stopPrank();
    }

    function test_setStakeZap_adminGated() public {
        vm.expectRevert(IEUSDManager.OnlyAdmin.selector);
        vm.prank(attacker);
        manager.setStakeZap(attacker);

        vm.prank(admin);
        manager.setStakeZap(address(0));
        vm.expectRevert(IEUSDManager.OnlyZap.selector);
        vm.prank(address(zap));
        manager.depositFor(alice, address(eSPY), 1e18, address(0));
    }

    function test_mintFor_respectsMcr() public {
        // $5,000 collateral supports at most ~$3,333 debt at 150% MCR.
        vm.expectRevert();
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(10e18, 0, 3400e18, address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Upgradeability & admin
    // ──────────────────────────────────────────────────────────

    function test_initialize_twice_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        zap.initialize(_zapConfig());
    }

    function test_upgrade_adminGated() public {
        OwnStakeZap newImpl = new OwnStakeZap();
        vm.expectRevert(IOwnStakeZap.OnlyAdmin.selector);
        vm.prank(attacker);
        zap.upgradeToAndCall(address(newImpl), "");

        vm.prank(admin);
        zap.upgradeToAndCall(address(newImpl), "");

        // Approvals and wiring live in proxy storage: flows keep working after the upgrade.
        vm.prank(alice);
        zap.stakeFromSpyAndMoney(1e18, 0, 100e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 1e18);
    }

    function test_setSwapRouter_adminGatedAndRotates() public {
        vm.expectRevert(IOwnStakeZap.OnlyAdmin.selector);
        vm.prank(attacker);
        zap.setSwapRouter(attacker);

        MockSwapRouter newRouter = new MockSwapRouter();
        money.mint(address(newRouter), 1e12 * 1e18);
        vm.prank(admin);
        zap.setSwapRouter(address(newRouter));
        assertEq(zap.swapRouter(), address(newRouter));

        // Swaps route through the new router; the old one no longer gets an allowance.
        uint256 moneyOut = _moneyFor(1500);
        bytes memory swapData = abi.encodeCall(MockSwapRouter.swap, (address(spy), 3e18, address(money), moneyOut));
        vm.prank(alice);
        zap.stakeFromSpy(10e18, 3e18, moneyOut, swapData, 0, address(0));
        assertEq(spy.balanceOf(address(newRouter)), 3e18, "slice went to the new router");
    }
}
