// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDLiquidityManager} from "../../src/eusd/EUSDLiquidityManager.sol";
import {AerodromeAdapter} from "../../src/eusd/adapters/AerodromeAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {ICLPool, INonfungiblePositionManager} from "../../src/interfaces/external/IAerodrome.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {deployEUSDLiquidityManager} from "../helpers/LiquidityManagerSetup.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";

interface ICLFactoryCreate {
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address pool);
}

interface IGaugeManager {
    struct GaugeCreationRequest {
        address creator;
        address gaugeFactory;
        address target;
        bytes factoryData;
        bool activate;
    }

    function createGauge(
        GaugeCreationRequest calldata request
    ) external returns (address gauge);
}

interface ICLPoolSwap {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @dev Swaps on a Slipstream pool, paying from its own balance.
contract PoolSwapper {
    function swap(ICLPool pool, bool zeroForOne, int256 amount, uint160 limit) external {
        ICLPoolSwap(address(pool)).swap(address(this), zeroForOne, amount, limit, "");
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        if (amount0 > 0) IERC20(ICLPool(msg.sender).token0()).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IERC20(ICLPool(msg.sender).token1()).transfer(msg.sender, uint256(amount1));
    }
}

/// @title AerodromeAdapterRobinhoodFork — the manager against live Aero Slipstream contracts
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Creates an SPY/eUSD Slipstream pool on the live
///         factory (pool creation is permissionless), creates its gauge through a registered
///         gauge-creation module, and runs the manager and AerodromeAdapter against the live
///         position manager and gauge, with a mock oracle pinned to the pool price.
contract AerodromeAdapterRobinhoodFork is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    address internal constant EUSD = 0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7;
    address internal constant GOV_SAFE = 0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant CL_FACTORY = 0xc63d7338c178e805c544B8f897066bD3BBcBE136;
    address internal constant POSITION_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address internal constant CL_GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address internal constant GAUGE_MANAGER = 0xbF234b32c5e58868243A4a14831626f3EdE7b183;
    address internal constant GAUGE_MODULE = 0xeBb15A0a3c75B7e495a682aA63C6c9351EB8F364;

    address internal constant ARB_SYS = address(0x64);

    bytes32 internal constant SPY_TICKER = bytes32("R.SPY");
    uint256 internal constant SPY_PRICE = 700e18;
    int24 internal constant SPACING = 10;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    EUSDLiquidityManager internal manager;
    MockOracleVerifier internal oracle;
    ICLPool internal pool;
    address internal gauge;
    bool internal _forkActive;

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain");
        _forkActive = true;
        // Robinhood Chain is an Arbitrum Orbit chain: Aero's gauges read ArbSys.arbBlockNumber(),
        // a precompile the forked EVM lacks.
        vm.etch(ARB_SYS, hex"00");
        _mockArbBlock();

        uint160 sqrtPrice = uint160(LiquidityMath.sqrtPriceFromOracle(SPY_PRICE, 1e18, SPY < EUSD));
        pool = ICLPool(ICLFactoryCreate(CL_FACTORY).createPool(SPY, EUSD, SPACING, sqrtPrice));
        vm.prank(GAUGE_MODULE);
        gauge = IGaugeManager(GAUGE_MANAGER).createGauge(
            IGaugeManager.GaugeCreationRequest({
                creator: address(this),
                gaugeFactory: CL_GAUGE_FACTORY,
                target: address(pool),
                factoryData: "",
                activate: false
            })
        );

        oracle = new MockOracleVerifier();
        oracle.setPrice(SPY_TICKER, SPY_PRICE);

        vm.startPrank(admin);
        ProtocolRegistry registry = new ProtocolRegistry(admin, 2 days);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.setOracle(address(oracle));
        registry.setTreasury(treasury);
        vm.stopPrank();

        manager = deployEUSDLiquidityManager(
            address(registry),
            EUSD,
            IEUSDLiquidityManager.RiskParams({
                mcrBps: 19_000,
                liquidationThresholdBps: 12_500,
                liquidationBonusBps: 500,
                stakedFeeBps: 700,
                unstakedFeeBps: 200,
                poolPriceBandBps: 250,
                redeemMinAssetShareBps: 7500,
                redeemFeeBps: 50,
                debtCeiling: 1_000_000e18,
                minDebt: 10e18,
                mintPriceMaxAge: 1 days
            })
        );
        vm.prank(GOV_SAFE);
        IAccessControl(EUSD).grantRole(keccak256("MINTER_ROLE"), address(manager));

        AerodromeAdapter impl = new AerodromeAdapter(POSITION_MANAGER, CL_FACTORY);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);
        vm.prank(admin);
        manager.addPool(address(beacon), SPY, SPY_TICKER, abi.encode(address(pool)));

        deal(SPY, alice, 100e18);
        vm.prank(alice);
        IERC20(SPY).approve(address(manager), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _mockArbBlock() internal {
        vm.mockCall(ARB_SYS, abi.encodeWithSignature("arbBlockNumber()"), abi.encode(block.number));
    }

    function _vault() internal view returns (AerodromeAdapter) {
        return AerodromeAdapter(manager.getPosition(0, alice).vault);
    }

    function _tickAt(
        uint256 price
    ) internal pure returns (int24) {
        uint256 target = LiquidityMath.sqrtPriceFromOracle(price, 1e18, true);
        int24 lo = LiquidityMath.MIN_TICK;
        int24 hi = LiquidityMath.MAX_TICK;
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (LiquidityMath.getSqrtPriceAtTick(mid) <= target) lo = mid;
            else hi = mid;
        }
        int24 r = lo % SPACING;
        if (r < 0) r += SPACING;
        return lo - r;
    }

    function _open(
        bool staked
    ) internal returns (uint128 liquidity) {
        vm.prank(alice);
        liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: 0,
                tickLower: _tickAt(630e18),
                tickUpper: _tickAt(770e18),
                assetDeposit: 10e18,
                assetMax: 5e18,
                eusdMax: 5 * SPY_PRICE,
                staked: staked
            })
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Tests
    // ──────────────────────────────────────────────────────────

    function test_fork_aero_poolAndGaugeLive() public requiresFork {
        assertEq(pool.gauge(), gauge);
        assertEq(pool.tickSpacing(), SPACING);
        assertApproxEqRel(_vault0PoolPrice(), SPY_PRICE, 1e12);
    }

    function test_fork_aero_openUnstaked_valuationMatchesWithdrawal() public requiresFork {
        uint256 supplyBefore = IERC20(EUSD).totalSupply();
        uint128 liquidity = _open(false);
        AerodromeAdapter v = _vault();
        assertEq(IERC721(POSITION_MANAGER).ownerOf(v.tokenId()), address(v));
        uint256 debt = manager.getPosition(0, alice).debt;
        assertEq(IERC20(EUSD).totalSupply() - supplyBefore, debt, "supply grows by the debt");
        assertGe(manager.collateralRatioBps(0, alice), manager.riskParams().mcrBps);

        uint256 idle = IERC20(SPY).balanceOf(address(v));
        (uint256 assetHeld, uint256 eusdHeld) = v.holdings(SPY_PRICE);
        vm.prank(address(manager));
        (uint256 assetOut, uint256 eusdOut) = v.removeLiquidity(liquidity, 0, 0);
        assertApproxEqAbs(assetOut, assetHeld - idle, 1e6, "asset");
        assertApproxEqAbs(eusdOut, eusdHeld - 0, 1e6, "eUSD");
        assertEq(v.tokenId(), 0, "NFT burned");
    }

    function test_fork_aero_stakedLifecycle() public requiresFork {
        uint128 liquidity = _open(true);
        AerodromeAdapter v = _vault();
        uint256 id = v.tokenId();
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), gauge, "staked in the live gauge");
        assertEq(address(v.gauge()), gauge);

        // Add more while staked, then remove half: the NFT goes back to the gauge each time.
        vm.roll(block.number + 200);
        _mockArbBlock();
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: 0,
                tickLower: _tickAt(630e18),
                tickUpper: _tickAt(770e18),
                assetDeposit: 0,
                assetMax: 2e18,
                eusdMax: 2 * SPY_PRICE,
                staked: true
            })
        );
        (,, uint128 held) = v.range();
        assertGt(held, liquidity);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), gauge);

        vm.prank(alice);
        manager.removeLiquidity(0, held / 2, 0, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), gauge);

        vm.prank(alice);
        manager.setStaked(0, false);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), address(v));

        deal(EUSD, alice, 100e18);
        uint256 spyBefore = IERC20(SPY).balanceOf(alice);
        vm.prank(alice);
        manager.close(0, 0, 0);
        assertEq(manager.totalDebt(), 0);
        assertApproxEqRel(IERC20(SPY).balanceOf(alice) - spyBefore, 10e18, 0.01e18);
        assertEq(v.tokenId(), 0);
    }

    function test_fork_aero_repositionStaked() public requiresFork {
        _open(true);
        vm.prank(alice);
        manager.reposition(
            IEUSDLiquidityManager.RepositionParams({
                poolId: 0,
                tickLower: _tickAt(660e18),
                tickUpper: _tickAt(740e18),
                assetMax: 3e18,
                eusdMax: 3 * SPY_PRICE,
                assetMin: 0,
                eusdMin: 0
            })
        );
        AerodromeAdapter v = _vault();
        assertEq(IERC721(POSITION_MANAGER).ownerOf(v.tokenId()), gauge);
        assertGe(manager.collateralRatioBps(0, alice), manager.riskParams().mcrBps);
    }

    function test_fork_aero_liquidateStaked() public requiresFork {
        _open(true);
        AerodromeAdapter v = _vault();

        // The oracle drops while the pool lags: a partial then a full liquidation unwind the gauge.
        oracle.setPrice(SPY_TICKER, (SPY_PRICE * 38) / 100);
        assertTrue(manager.isLiquidatable(0, alice));
        uint256 debt = manager.getPosition(0, alice).debt;
        deal(EUSD, keeper, debt);
        vm.prank(keeper);
        manager.liquidate(0, alice, debt / 2);
        (,, uint128 left) = v.range();
        assertGt(left, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(v.tokenId()), gauge, "rest stays staked");

        oracle.setPrice(SPY_TICKER, SPY_PRICE / 5);
        vm.prank(keeper);
        manager.liquidate(0, alice, type(uint256).max);
        assertEq(manager.getPosition(0, alice).debt, 0);
        assertEq(v.tokenId(), 0);
        assertEq(IERC20(SPY).balanceOf(address(v)), 0);
    }

    /// @dev Audit attack on the live position manager: the owner cuts the vault's liquidity to 1 and
    ///      anyone adds dust to the unstaked NFT. Liquidations must still clear the whole debt.
    function test_fork_aero_donatedLiquidity_liquidationsWork() public requiresFork {
        require(SPY < EUSD, "SPY is token0");
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: 0,
                tickLower: _tickAt(600e18),
                tickUpper: _tickAt(680e18),
                assetDeposit: 10e18,
                assetMax: 0,
                eusdMax: 3000e18,
                staked: false
            })
        );
        AerodromeAdapter v = _vault();
        uint256 id = v.tokenId();
        uint256 debt = manager.getPosition(0, alice).debt;

        // The eUSD-only range fills as SPY is sold through it.
        PoolSwapper swapper = new PoolSwapper();
        deal(SPY, address(swapper), 100e18);
        swapper.swap(pool, true, 100e18, uint160(LiquidityMath.sqrtPriceFromOracle(590e18, 1e18, true)));

        (,, uint128 held) = v.range();
        vm.prank(alice);
        manager.removeLiquidity(0, held - 1, 0, 0);
        assertEq(manager.getPosition(0, alice).debt, debt, "all-asset range: debt unchanged");

        address bob = makeAddr("bob");
        deal(SPY, bob, 1e15);
        vm.startPrank(bob);
        IERC20(SPY).approve(POSITION_MANAGER, type(uint256).max);
        INonfungiblePositionManager(POSITION_MANAGER).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: id,
                amount0Desired: 1e12,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        oracle.setPrice(SPY_TICKER, 100e18);
        assertTrue(manager.isLiquidatable(0, alice));
        deal(EUSD, keeper, debt);
        vm.startPrank(keeper);
        manager.liquidate(0, alice, debt / 2);
        assertEq(v.tokenId(), 0, "share rounds up to the whole range, NFT burned");
        manager.liquidate(0, alice, type(uint256).max);
        vm.stopPrank();
        assertEq(manager.getPosition(0, alice).debt, 0);
    }

    function _vault0PoolPrice() internal returns (uint256) {
        _open(false);
        return _vault().poolPrice();
    }
}
