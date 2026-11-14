// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PegArbitrage} from "../../misc/PegArbitrage.sol";
import {IPoolManagerSwap, PoolKey, SwapParams} from "../../misc/interfaces/IPoolManagerSwap.sol";
import {EUSDPsm} from "../../src/eusd/EUSDPsm.sol";
import {IEUSD} from "../../src/interfaces/IEUSD.sol";
import {IExtsload} from "../../src/interfaces/external/IFables.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Exact-input swapper standing in for outside traders.
contract ForkSwapper {
    IPoolManagerSwap internal immutable pm;

    constructor(
        address pm_
    ) {
        pm = IPoolManagerSwap(pm_);
    }

    function swap(PoolKey calldata key, address tokenIn, uint256 amountIn) external {
        pm.unlock(abi.encode(key, tokenIn, amountIn));
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        (PoolKey memory key, address tokenIn, uint256 amountIn) = abi.decode(data, (PoolKey, address, uint256));
        bool zeroForOne = tokenIn == key.currency0;
        int256 d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? 4_295_128_740
                    : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341
            }),
            ""
        );
        int128 a0 = int128(d >> 128);
        int128 a1 = int128(d);
        (int128 paid, int128 got) = zeroForOne ? (a0, a1) : (a1, a0);
        pm.sync(tokenIn);
        IERC20(tokenIn).transfer(address(pm), uint256(uint128(-paid)));
        pm.settle();
        pm.take(zeroForOne ? key.currency1 : key.currency0, address(this), uint256(uint128(got)));
        return "";
    }
}

interface ICLFactory {
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address pool);
}

interface ICLPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);
}

/// @dev Robinhood Chain is an Arbitrum chain; Slipstream reads ArbSys, which a local fork lacks.
contract ForkArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}

/// @dev Adds liquidity to an Aero Slipstream pool, paying in the mint callback.
contract ForkClMinter {
    function mint(address pool, int24 lower, int24 upper, uint128 amount) external {
        ICLPool(pool).mint(address(this), lower, upper, amount, abi.encode(pool));
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        if (amount0 > 0) IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7).transfer(msg.sender, amount1);
    }
}

/// @title EUSDPsmRobinhoodFork — PSM + PegArbitrage against the live Fables eUSD/USDG pool
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Deploys the PSM and the arbitrage helper on a fork,
///         grants them their roles as the governance Safe, and checks that the keeper call moves
///         the live pool to 1 eUSD = 1 USDG and puts it back there after outside buys and sells.
contract EUSDPsmRobinhoodForkTest is Test {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    address constant SAFE = 0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2;
    address constant REGISTRY = 0x348C42672FEf9dEcd678B631bf1D3BaEf5fD0085;
    address constant KEEPER = 0xA0B5e7E6070E021884263d8ABe6AA2223a7FFA7B; // holds OPERATOR
    address constant EUSD = 0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOOK = 0x08E52564Bad99E05a694b4809F397edcA417A080;
    bytes32 constant POOLS_SLOT = bytes32(uint256(6));
    address constant CL_FACTORY = 0xc63d7338c178e805c544B8f897066bD3BBcBE136; // Aero Slipstream

    /// @dev 1 eUSD = 1 USDG in raw units (eUSD per USDG unit = 1e12) sits inside tick 276324.
    int24 constant PEG_TICK = 276_324;

    EUSDPsm internal psm;
    PegArbitrage internal arb;
    ForkSwapper internal trader;
    PoolKey internal key;
    uint160 internal target;
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

        EUSDPsm impl = new EUSDPsm();
        psm = EUSDPsm(address(new ERC1967Proxy(address(impl), abi.encodeCall(EUSDPsm.initialize, (REGISTRY, EUSD)))));
        arb = new PegArbitrage(REGISTRY, POOL_MANAGER, address(psm));
        trader = new ForkSwapper(POOL_MANAGER);

        vm.startPrank(SAFE);
        IAccessControl(EUSD).grantRole(IEUSD(EUSD).MINTER_ROLE(), address(psm));
        psm.addAsset(USDG, 500_000e18, 0, 0);
        vm.stopPrank();

        key = PoolKey(USDG, EUSD, 0x800000, 1, HOOK);
        target = LiquidityMath.getSqrtPriceAtTick(PEG_TICK);
    }

    function _sqrtPrice() internal view returns (uint160) {
        bytes32 slot = keccak256(abi.encodePacked(keccak256(abi.encode(key)), POOLS_SLOT));
        return uint160(uint256(IExtsload(POOL_MANAGER).extsload(slot)));
    }

    /// @dev What the keeper does: move the pool to the peg price through the PSM.
    function _keeper() internal returns (int256 profit) {
        uint160 p = _sqrtPrice();
        if (p == target) return 0;
        // Lower sqrt price = fewer eUSD per USDG = eUSD above $1, so sell eUSD.
        bool sellEusd = p < target;
        uint256 maxIn = sellEusd ? 400_000e18 : IERC20(USDG).balanceOf(address(psm)) * 99 / 100;
        vm.prank(KEEPER);
        profit = arb.arbitrage(key, sellEusd, target, maxIn, -10e6);
    }

    function _trade(address tokenIn, uint256 amount) internal {
        deal(tokenIn, address(trader), amount);
        trader.swap(key, tokenIn, amount);
    }

    function test_fork_keeperPegsPoolAtOne() public requiresFork {
        uint256 supplyBefore = IERC20(EUSD).totalSupply();
        _keeper();
        assertEq(_sqrtPrice(), target, "pool not at the peg");
        uint256 issued = psm.totalDebt();
        assertEq(IERC20(EUSD).totalSupply(), supplyBefore + issued);
        assertGe(IERC20(USDG).balanceOf(address(psm)) * 1e12, issued);
    }

    function test_fork_buyThenSell_keeperRestoresPeg() public requiresFork {
        _keeper();
        uint256 debtAtPeg = psm.totalDebt();

        _trade(USDG, 25_000e6);
        assertLt(_sqrtPrice(), target);
        int256 profit = _keeper();
        assertEq(_sqrtPrice(), target);
        assertGt(psm.totalDebt(), debtAtPeg + 24_000e18);
        assertGt(profit, -5e6);

        // The live LP ranges hold little eUSD-side depth just above $1 until the agent re-centres
        // them, so the seller stays small.
        uint256 debtBeforeSell = psm.totalDebt();
        _trade(EUSD, 5000e18);
        assertGt(_sqrtPrice(), target);
        profit = _keeper();
        assertEq(_sqrtPrice(), target);
        assertLt(psm.totalDebt(), debtBeforeSell);
        assertGt(psm.totalDebt(), debtAtPeg);
        assertGt(profit, -5e6);
        assertGe(IERC20(USDG).balanceOf(address(psm)) * 1e12, psm.totalDebt());
    }

    /// @dev A new Aero Slipstream eUSD/USDG pool at `usdPerEusdE6`, with liquidity about ±1%
    ///      around $1.
    function _slipstreamPool(uint256 usdPerEusdE6, int24 spacing) internal returns (address pool) {
        vm.etch(address(0x64), address(new ForkArbSys()).code);
        uint160 start = uint160(uint256(target) * 1e6 / _sqrtE6(usdPerEusdE6));
        pool = ICLFactory(CL_FACTORY).createPool(USDG, EUSD, spacing, start);
        ForkClMinter minter = new ForkClMinter();
        deal(USDG, address(minter), 200_000e6);
        bytes32 role = IEUSD(EUSD).MINTER_ROLE();
        vm.prank(SAFE);
        IAccessControl(EUSD).grantRole(role, address(this));
        IEUSD(EUSD).mint(address(minter), 200_000e18);
        int24 lower = (PEG_TICK - 100) / spacing * spacing;
        minter.mint(pool, lower, lower + 200 / spacing * spacing + spacing, 5e17);
    }

    /// @dev sqrt(x / 1e6) * 1e6, for x around 1e6.
    function _sqrtE6(
        uint256 x
    ) internal pure returns (uint256 r) {
        r = x;
        for (uint256 i; i < 40; ++i) {
            r = (r + x * 1e6 / r) / 2;
        }
    }

    function test_fork_slipstream_keeperPegsPoolAtOne() public requiresFork {
        address pool = _slipstreamPool(1_004_900, 1);
        (uint160 before,,,,,) = ICLPool(pool).slot0();
        assertLt(before, target);
        uint256 supplyBefore = IERC20(EUSD).totalSupply();

        vm.prank(KEEPER);
        int256 profit = arb.arbitrageV3(pool, true, target, 400_000e18, 0);
        (uint160 afterSell,,,,,) = ICLPool(pool).slot0();
        assertEq(afterSell, target);
        assertGt(profit, 0);
        assertGt(psm.totalDebt(), 0);
        assertEq(IERC20(EUSD).totalSupply(), supplyBefore + psm.totalDebt());

        // A second pool with eUSD below $1: the keeper buys it and redeems what holders minted.
        deal(USDG, address(this), 100_000e6);
        IERC20(USDG).approve(address(psm), 100_000e6);
        psm.mint(USDG, 100_000e6, 0);
        address pool2 = _slipstreamPool(995_000, 10);
        uint256 debt = psm.totalDebt();
        vm.prank(KEEPER);
        profit = arb.arbitrageV3(pool2, false, target, debt / 1e12 * 99 / 100, 0);
        (uint160 afterBuy,,,,,) = ICLPool(pool2).slot0();
        assertEq(afterBuy, target);
        assertGt(profit, 0);
        assertLt(psm.totalDebt(), debt);
        assertGe(IERC20(USDG).balanceOf(address(psm)) * 1e12, psm.totalDebt());
    }

    function test_fork_pausedMint_keeperCannotIssue() public requiresFork {
        vm.prank(KEEPER);
        psm.setMintPaused(USDG, true);
        if (_sqrtPrice() >= target) return;
        vm.prank(KEEPER);
        vm.expectRevert();
        arb.arbitrage(key, true, target, 100_000e18, -10e6);
    }
}
