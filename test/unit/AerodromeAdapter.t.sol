// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AerodromeAdapter} from "../../src/eusd/adapters/AerodromeAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {ILiquidityVault} from "../../src/interfaces/ILiquidityVault.sol";
import {LiquidityManagerSetup} from "../helpers/LiquidityManagerSetup.sol";
import {MockCLFactory, MockCLGauge, MockCLPool, MockPositionManager} from "../helpers/MockAero.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev An unrelated NFT, to check the vault refuses it.
contract OtherNFT is ERC721("Other", "OTH") {
    function mint(
        address to
    ) external {
        _mint(to, 1);
    }
}

/// @notice AerodromeAdapter on mock Slipstream contracts, driven through the manager. Adds an
///         SPY/eUSD (asset token0) and an eUSD/USDG (asset token1) Aero pool next to the Fables ones.
contract AerodromeAdapterTest is LiquidityManagerSetup {
    uint256 internal constant AERO_SPY = 2;
    uint256 internal constant AERO_USD = 3;

    MockCLFactory internal clFactory;
    MockPositionManager internal npm;
    MockCLPool internal spyPool;
    MockCLPool internal usdPool;
    MockCLGauge internal spyGauge;
    AerodromeAdapter internal aeroImpl;
    UpgradeableBeacon internal aeroBeacon;

    function setUp() public override {
        super.setUp();
        clFactory = new MockCLFactory();
        npm = new MockPositionManager(clFactory);
        spyPool = clFactory.createPool(address(spy), address(eusd), 10);
        usdPool = clFactory.createPool(address(usdg), address(eusd), 1);
        spyPool.setPrice(address(spy), SPY_PRICE);
        usdPool.setPrice(address(usdg), 1e18);
        spyGauge = new MockCLGauge(npm);
        spyPool.setGauge(address(spyGauge));

        aeroImpl = new AerodromeAdapter(address(npm), address(clFactory));
        aeroBeacon = new UpgradeableBeacon(address(aeroImpl), admin);
        vm.startPrank(admin);
        manager.addPool(address(aeroBeacon), address(spy), SPY, abi.encode(address(spyPool)));
        manager.addPool(address(aeroBeacon), address(usdg), USDG, abi.encode(address(usdPool)));
        vm.stopPrank();

        spy.mint(address(npm), 1_000_000e18);
        usdg.mint(address(npm), 1_000_000_000e6);
        giveEusd(address(npm), 1_000_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _open(address user, uint256 assetIn, uint256 eusdMax, bool staked_) internal returns (uint128) {
        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        vm.prank(user);
        return manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: AERO_SPY,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: assetIn,
                assetMax: assetIn,
                eusdMax: eusdMax,
                staked: staked_
            })
        );
    }

    function _vaultOf(
        address user
    ) internal view returns (AerodromeAdapter) {
        return AerodromeAdapter(manager.getPosition(AERO_SPY, user).vault);
    }

    function _held(
        AerodromeAdapter v
    ) internal view returns (uint128 liquidity) {
        (,, liquidity) = v.range();
    }

    function _nftLiquidity(
        uint256 id
    ) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = npm.positions(id);
    }

    function _moveAeroSpy(
        uint256 price
    ) internal {
        oracle.setPrice(SPY, price);
        spyPool.setPrice(address(spy), price);
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / pool checks
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        new AerodromeAdapter(address(0), address(clFactory));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        new AerodromeAdapter(address(npm), address(0));
    }

    function test_initialize_setsState() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        assertEq(v.manager(), address(manager));
        assertEq(v.owner(), alice);
        assertEq(v.asset(), address(spy));
        assertEq(address(v.pool()), address(spyPool));
        assertEq(address(v.positionManager()), address(npm));
        assertEq(address(v.factory()), address(clFactory));
    }

    function test_initialize_twice_reverts() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v.initialize(attacker, address(spy), address(eusd), abi.encode(address(spyPool)));
    }

    function test_initialize_implementation_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        aeroImpl.initialize(attacker, address(spy), address(eusd), abi.encode(address(spyPool)));
    }

    function test_checkPool_rejectsBadPools() public {
        // Wrong asset for the pool.
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        aeroImpl.checkPool(address(usdg), address(eusd), abi.encode(address(spyPool)));
        // Same token twice, zero addresses, no code.
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        aeroImpl.checkPool(address(spy), address(spy), abi.encode(address(spyPool)));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        aeroImpl.checkPool(address(0), address(eusd), abi.encode(address(spyPool)));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        aeroImpl.checkPool(address(spy), address(eusd), abi.encode(address(0xdead)));
    }

    function test_checkPool_rejectsPoolNotFromFactory() public {
        MockCLPool fake = new MockCLPool(address(spy), address(eusd), 10);
        fake.setPrice(address(spy), SPY_PRICE);
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        aeroImpl.checkPool(address(spy), address(eusd), abi.encode(address(fake)));
    }

    function test_checkPool_rejectsUninitialized() public {
        MockCLPool fresh = clFactory.createPool(address(spy), address(eusd), 50);
        vm.expectRevert(ILiquidityVault.PoolNotInitialized.selector);
        aeroImpl.checkPool(address(spy), address(eusd), abi.encode(address(fresh)));
    }

    function test_checkPool_rejectsTooManyDecimals() public {
        address odd = address(0x2000);
        deployCodeTo("test/helpers/MockERC20.sol:MockERC20", abi.encode("ODD", "ODD", uint8(24)), odd);
        MockCLPool p = clFactory.createPool(odd, address(eusd), 10);
        p.setSqrtPrice(uint160(1 << 96));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        aeroImpl.checkPool(odd, address(eusd), abi.encode(address(p)));
    }

    // ──────────────────────────────────────────────────────────
    //  Access control
    // ──────────────────────────────────────────────────────────

    function test_managerAndOwnerFunctions_restricted() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        v.addLiquidity(0, 10, 1, 1);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        v.removeLiquidity(1, 0, 0);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        v.setStaked(true);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        v.transferToken(address(spy), alice, 1);
        vm.stopPrank();
        vm.startPrank(attacker);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        v.sweep(address(1));
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        v.claimEmissions();
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        v.claimFees();
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Opening and staking
    // ──────────────────────────────────────────────────────────

    function test_open_unstaked_vaultHoldsNft() public {
        uint128 liquidity = _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        assertGt(id, 0);
        assertEq(npm.ownerOf(id), address(v));
        assertEq(_nftLiquidity(id), liquidity);
        assertEq(_held(v), liquidity);
        assertFalse(v.staked());
        assertEq(address(v.gauge()), address(0));
        assertEq(spy.allowance(address(v), address(npm)), 0, "no approval left");
        assertEq(eusd.allowance(address(v), address(npm)), 0, "no approval left");
    }

    function test_open_staked_nftInGauge() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        assertEq(npm.ownerOf(id), address(spyGauge));
        assertEq(spyGauge.stakerOf(id), address(v));
        assertEq(address(v.gauge()), address(spyGauge));
        assertTrue(manager.getPosition(AERO_SPY, alice).staked);
    }

    function test_open_staked_noGauge_reverts() public {
        spyPool.setGauge(address(0));
        vm.expectRevert(AerodromeAdapter.NoGauge.selector);
        _open(alice, 10e18, 3500e18, true);
    }

    function test_open_assetToken1Pool() public {
        (int24 lower, int24 upper) = usdRange(0.99e18, 1.01e18);
        vm.prank(alice);
        uint128 liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: AERO_USD,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 2000e6,
                assetMax: 2000e6,
                eusdMax: 1000e18,
                staked: false
            })
        );
        AerodromeAdapter v = AerodromeAdapter(manager.getPosition(AERO_USD, alice).vault);
        assertEq(_nftLiquidity(v.tokenId()), liquidity);
        assertApproxEqRel(v.poolPrice(), 1e18, 1e12);
    }

    function test_setStaked_movesNftBothWays() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        vm.prank(alice);
        manager.setStaked(AERO_SPY, true);
        assertEq(npm.ownerOf(id), address(spyGauge));
        vm.prank(alice);
        manager.setStaked(AERO_SPY, false);
        assertEq(npm.ownerOf(id), address(v));
        assertFalse(v.staked());
    }

    function test_unstake_usesGaugeStakedIn_afterGaugeReplaced() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        spyPool.setGauge(address(new MockCLGauge(npm)));
        vm.prank(alice);
        manager.setStaked(AERO_SPY, false);
        assertEq(npm.ownerOf(v.tokenId()), address(v));
    }

    function test_addMore_whileStaked_restakesSameNft() public {
        uint128 first = _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        uint128 second = _open(alice, 5e18, 1750e18, true);
        assertEq(v.tokenId(), id, "same NFT");
        assertEq(npm.ownerOf(id), address(spyGauge));
        assertEq(_nftLiquidity(id), first + second);
        assertEq(_held(v), first + second);
    }

    // ──────────────────────────────────────────────────────────
    //  Removing
    // ──────────────────────────────────────────────────────────

    function test_removePartial_staked_keepsNftStaked() public {
        uint128 liquidity = _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        vm.prank(alice);
        manager.removeLiquidity(AERO_SPY, liquidity / 2, 0, 0);
        assertEq(v.tokenId(), id);
        assertEq(npm.ownerOf(id), address(spyGauge));
        assertEq(_nftLiquidity(id), liquidity - liquidity / 2);
    }

    function test_removeAll_burnsNftAndClearsRange() public {
        uint128 liquidity = _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        npm.setFeesOwed(id, 0, 0);
        vm.prank(address(manager));
        (uint256 assetOut, uint256 eusdOut) = v.removeLiquidity(liquidity, 0, 0);
        assertGt(assetOut + eusdOut, 0);
        assertEq(v.tokenId(), 0);
        (int24 lower, int24 upper, uint128 left) = v.range();
        assertEq(lower, 0);
        assertEq(upper, 0);
        assertEq(left, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        npm.ownerOf(id);
    }

    function test_removeAll_collectsUnclaimedFeesIntoVault() public {
        uint128 liquidity = _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        npm.setFeesOwed(v.tokenId(), 1e18, 0);
        uint256 idle = spy.balanceOf(address(v));
        vm.prank(address(manager));
        (uint256 assetOut,) = v.removeLiquidity(liquidity, 0, 0);
        assertEq(spy.balanceOf(address(v)), idle + assetOut);
        assertGe(assetOut, 1e18, "fees came with the principal");
    }

    function test_reposition_staked_newNftStaked() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 oldId = v.tokenId();
        (int24 lower, int24 upper) = spyRange(650e18, 750e18);
        vm.prank(alice);
        uint128 liquidity = manager.reposition(
            IEUSDLiquidityManager.RepositionParams({
                poolId: AERO_SPY,
                tickLower: lower,
                tickUpper: upper,
                assetMax: 3e18,
                eusdMax: 2000e18,
                assetMin: 0,
                eusdMin: 0
            })
        );
        uint256 newId = v.tokenId();
        assertTrue(newId != oldId);
        assertEq(npm.ownerOf(newId), address(spyGauge));
        assertEq(_nftLiquidity(newId), liquidity);
        assertEq(eusd.totalSupply(), manager.totalDebt() + 1_000_000e18, "supply == debt + npm reserve");
    }

    function test_close_returnsEverything() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 debt = manager.getPosition(AERO_SPY, alice).debt;
        giveEusd(alice, debt);
        vm.startPrank(alice);
        eusd.approve(address(manager), type(uint256).max);
        manager.close(AERO_SPY, 0, 0);
        vm.stopPrank();
        assertEq(v.tokenId(), 0);
        assertEq(spy.balanceOf(address(v)), 0);
        assertEq(eusd.balanceOf(address(v)), 0);
        assertEq(manager.getPosition(AERO_SPY, alice).debt, 0);
    }

    function test_liquidate_partial_staked_restOfRangeStaysStaked() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        uint128 held = _held(v);
        _moveAeroSpy(250e18);
        assertTrue(manager.isLiquidatable(AERO_SPY, alice));
        uint256 debt = manager.getPosition(AERO_SPY, alice).debt;
        giveEusd(keeper, debt);
        vm.startPrank(keeper);
        eusd.approve(address(manager), type(uint256).max);
        manager.liquidate(AERO_SPY, alice, debt / 2);
        vm.stopPrank();
        assertLt(_held(v), held);
        assertGt(_held(v), 0);
        assertEq(npm.ownerOf(id), address(spyGauge), "rest stays staked");
        assertEq(_nftLiquidity(id), _held(v));
    }

    function test_liquidate_full_staked() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        _moveAeroSpy(250e18);
        uint256 debt = manager.getPosition(AERO_SPY, alice).debt;
        giveEusd(keeper, debt);
        vm.startPrank(keeper);
        eusd.approve(address(manager), type(uint256).max);
        manager.liquidate(AERO_SPY, alice, type(uint256).max);
        vm.stopPrank();
        assertEq(v.tokenId(), 0);
        assertEq(manager.getPosition(AERO_SPY, alice).debt, 0);
    }

    /// @dev Slipstream lets anyone add liquidity to an unstaked NFT.
    function _donate(uint256 id, bytes4 expectedError) internal {
        address bob = makeAddr("bob");
        spy.mint(bob, 1e18);
        giveEusd(bob, 1000e18);
        vm.startPrank(bob);
        spy.approve(address(npm), type(uint256).max);
        eusd.approve(address(npm), type(uint256).max);
        if (expectedError != bytes4(0)) vm.expectRevert(expectedError);
        npm.increaseLiquidity(
            MockPositionManager.IncreaseLiquidityParams({
                tokenId: id,
                amount0Desired: 1e15,
                amount1Desired: 1e15,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_donatedLiquidity_closeStillBurns() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        _donate(id, bytes4(0));
        assertGt(_nftLiquidity(id), _held(v));
        uint256 debt = manager.getPosition(AERO_SPY, alice).debt;
        giveEusd(alice, debt);
        vm.startPrank(alice);
        eusd.approve(address(manager), type(uint256).max);
        manager.close(AERO_SPY, 0, 0);
        vm.stopPrank();
        assertEq(v.tokenId(), 0);
        assertEq(spy.balanceOf(address(v)), 0);
        assertEq(eusd.balanceOf(address(v)), 0);
    }

    /// @dev The audit attack: the owner cuts the vault's liquidity to 1 and a donation keeps the NFT
    ///      from burning. Every liquidation then takes the full-removal path, which must still work.
    function test_donatedLiquidity_heldOne_liquidationsWork() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        uint256 id = v.tokenId();
        _moveAeroSpy(250e18);
        uint256 debt = manager.getPosition(AERO_SPY, alice).debt;
        uint128 cut = _held(v) - 1;
        vm.prank(alice);
        manager.removeLiquidity(AERO_SPY, cut, 0, 0);
        assertEq(_held(v), 1);
        assertEq(manager.getPosition(AERO_SPY, alice).debt, debt, "all-asset range: debt unchanged");
        _donate(id, bytes4(0));
        assertTrue(manager.isLiquidatable(AERO_SPY, alice));

        giveEusd(keeper, debt);
        vm.startPrank(keeper);
        eusd.approve(address(manager), type(uint256).max);
        manager.liquidate(AERO_SPY, alice, debt / 2);
        assertEq(v.tokenId(), 0, "share rounds up to the whole range, NFT burned");
        manager.liquidate(AERO_SPY, alice, type(uint256).max);
        vm.stopPrank();
        assertEq(manager.getPosition(AERO_SPY, alice).debt, 0);
    }

    function test_increaseLiquidity_stakedNft_onlyGauge() public {
        _open(alice, 10e18, 3500e18, true);
        uint256 id = _vaultOf(alice).tokenId();
        _donate(id, MockPositionManager.NotApproved.selector);
    }

    // ──────────────────────────────────────────────────────────
    //  Owner claims
    // ──────────────────────────────────────────────────────────

    function test_claimFees_unstaked_paysOwner() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        npm.setFeesOwed(v.tokenId(), 1e18, 50e18);
        uint256 spyBefore = spy.balanceOf(alice);
        uint256 eusdBefore = eusd.balanceOf(alice);
        vm.prank(alice);
        v.claimFees();
        assertEq(spy.balanceOf(alice), spyBefore + 1e18);
        assertEq(eusd.balanceOf(alice), eusdBefore + 50e18);
    }

    function test_claimFees_staked_reverts() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        vm.expectRevert(MockPositionManager.NotApproved.selector);
        vm.prank(alice);
        v.claimFees();
    }

    function test_claimEmissions_paysOwner() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        spyGauge.setEarned(address(v), 42e18);
        vm.prank(alice);
        v.claimEmissions();
        assertEq(spyGauge.rewardToken().balanceOf(alice), 42e18);
    }

    function test_unstakeEmissions_landInVault_thenSweep() public {
        _open(alice, 10e18, 3500e18, true);
        AerodromeAdapter v = _vaultOf(alice);
        spyGauge.setEarned(address(v), 7e18);
        vm.prank(alice);
        manager.setStaked(AERO_SPY, false);
        MockERC20 xaero = spyGauge.rewardToken();
        assertEq(xaero.balanceOf(address(v)), 7e18);
        vm.prank(alice);
        v.sweep(address(xaero));
        assertEq(xaero.balanceOf(alice), 7e18);
    }

    function test_sweep_protectedTokens_revert() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.ProtectedToken.selector, address(spy)));
        v.sweep(address(spy));
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.ProtectedToken.selector, address(eusd)));
        v.sweep(address(eusd));
        vm.stopPrank();
    }

    function test_onERC721Received_otherNft_reverts() public {
        _open(alice, 10e18, 3500e18, false);
        address v = address(_vaultOf(alice));
        OtherNFT other = new OtherNFT();
        other.mint(address(this));
        vm.expectRevert(AerodromeAdapter.UnexpectedNFT.selector);
        other.safeTransferFrom(address(this), v, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    function test_holdings_matchesNftAmountsAtPoolPrice() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        (uint256 assetAmount, uint256 eusdAmount) = v.holdings(SPY_PRICE);
        // Value at the oracle is close to what went in (10 SPY + 3,500 eUSD at most).
        assertApproxEqRel(assetAmount * 700 + eusdAmount, 10e18 * 700 + 3500e18, 0.4e18);
        assertApproxEqRel(v.poolPrice(), SPY_PRICE, 1e9);
    }

    function test_holdings_isLowerBoundWhenPoolIsOff() public {
        uint128 liquidity = _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        (uint256 aFair, uint256 eFair) = v.holdings(SPY_PRICE);
        uint256 fair = aFair * 700 + eFair;
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            spyPool.setPrice(address(spy), i == 0 ? 640e18 : 760e18);
            uint256 idle = spy.balanceOf(address(v));
            vm.prank(address(manager));
            (uint256 aOut, uint256 eOut) = v.removeLiquidity(liquidity, 0, 0);
            assertGe((aOut + idle) * 700 + eOut, fair);
            vm.revertToState(snap);
        }
    }

    function test_addLiquidity_poolUninitialized_reverts() public {
        _open(alice, 10e18, 3500e18, false);
        AerodromeAdapter v = _vaultOf(alice);
        (int24 lower, int24 upper,) = v.range();
        spyPool.setSqrtPrice(0);
        vm.expectRevert(ILiquidityVault.PoolNotInitialized.selector);
        vm.prank(address(manager));
        v.addLiquidity(lower, upper, 1e18, 0);
    }

    function test_addLiquidity_offSpacing_reverts() public {
        vm.prank(alice);
        manager.deposit(AERO_SPY, 1e18);
        AerodromeAdapter v = _vaultOf(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InvalidRange.selector, int24(5), int24(20)));
        vm.prank(address(manager));
        v.addLiquidity(5, 20, 1e18, 0);
    }
}
