// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundVenue} from "../../src/funds/FundVenue.sol";
import {IHookrDirectionalTax, IHookrLauncher} from "../../src/interfaces/external/IHookr.sol";
import {PoolSettings} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IHookrFamily {
    function familyOwner(
        bytes32 familyId
    ) external view returns (address);
}

/// @title FundHookrRobinhoodForkTest — a fund's pool on Hookr's live contracts on Robinhood Chain
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Launches a fund whose venue opens its pool through
///         Hookr's live launcher on the allowlisted root, trades it through Uniswap's Universal
///         Router (what the Uniswap app sends), pays the tax out to the curators, issues, redeems a
///         slice of the position and migrates to a second Hookr pool. USDG is replaced with a
///         mintable token at its live address so the pools quote the real USDG.
contract FundHookrRobinhoodForkTest is FundTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant LAUNCHER = 0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4;
    address constant ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;
    address constant RULES = 0x4a71c270b1520F94064268102AebD744b0DE7942;
    address constant TAX = 0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F;

    address internal trader = makeAddr("trader");

    bool internal _forkActive;

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain");
        _forkActive = true;
        super.setUp();
        _launchDefault();
        vm.roll(block.number + 1);
    }

    function _deployPoolManager() internal pure override returns (IPoolManager) {
        return IPoolManager(POOL_MANAGER);
    }

    function _deployPositionManager() internal pure override returns (address) {
        return POSITION_MANAGER;
    }

    function _deployUsdg() internal override returns (MockERC20) {
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Global Dollar", "USDG", uint8(6)), USDG);
        return MockERC20(USDG);
    }

    function _deployVenue() internal override returns (address) {
        return address(new FundVenue(IHookrLauncher(LAUNCHER), ROOT, RULES, TAX, address(usdg)));
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev V4_SWAP with SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL: the shape the Uniswap app sends.
    function _urSwap(address tokenIn, uint128 amountIn) internal returns (uint256 out) {
        PoolKey memory key = venue.poolKey();
        address tokenOut = tokenIn == address(usdg) ? address(fund) : address(usdg);
        if (tokenIn == address(usdg)) usdg.mint(trader, amountIn);
        vm.startPrank(trader);
        IERC20(tokenIn).approve(PERMIT2, type(uint256).max);
        IPermit2Approve(PERMIT2).approve(tokenIn, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, 0, 0, bytes("")));
        params[1] = abi.encode(Currency.wrap(tokenIn), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(tokenOut), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        uint256 before = IERC20(tokenOut).balanceOf(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        vm.stopPrank();
        out = IERC20(tokenOut).balanceOf(trader) - before;
    }

    function test_fork_launchOpensHookrPool() public requiresFork {
        PoolKey memory key = venue.poolKey();
        assertEq(address(key.hooks), ROOT);
        assertEq(key.tickSpacing, 60);
        assertEq(IHookrFamily(LAUNCHER).familyOwner(venue.family()), address(venue));
        assertGt(venue.positionLiquidity(), 0);
        IHookrDirectionalTax.Terms memory t = IHookrDirectionalTax(TAX).terms(ROOT, key.toId());
        assertTrue(t.bound);
        assertEq(t.buyTaxPips, 10_500);
        assertEq(t.sellTaxPips, 10_500);
        (address buyQueue, address sellQueue) = venue.taxQueues();
        assertEq(buyQueue, t.buyQueue);
        assertEq(sellQueue, t.sellQueue);
        assertEq(usdg.balanceOf(address(venue)), 0);
        assertEq(fund.balanceOf(address(venue)), 0);
    }

    /// @dev Router trades pay the tax; the venue pays our share to the curators.
    function test_fork_routerTradesTaxToCurators() public requiresFork {
        uint256 got = _urSwap(address(usdg), 1000e6);
        assertGt(got, 0);
        uint256 out = _urSwap(address(fund), uint128(got / 2));
        assertGt(out, 0);

        uint256 before = usdg.balanceOf(address(curators));
        uint256 paid = venue.collectTax();
        assertEq(usdg.balanceOf(address(curators)) - before, paid);
        // Buy: 1.05% of 1000 USDG, and the sell's tax on its USDG out; 76.19% of each to us.
        uint256 buyTax = 1000e6 * 10_500 / 1e6;
        uint256 sellTax = (out * 1e6 / (1e6 - 10_500)) * 10_500 / 1e6;
        assertApproxEqRel(paid, (buyTax + sellTax) * (10_000 - 2381) / 10_000, 0.001e18);
        assertEq(venue.collectTax(), 0);
    }

    function test_fork_issueAfterBuy() public requiresFork {
        _urSwap(address(usdg), 5000e6);
        uint256 idle = fund.idleUsdg();
        (uint256 issued, uint256 usdgIn) = venue.issue();
        assertGt(issued, 0);
        assertGt(usdgIn, 0);
        assertEq(fund.idleUsdg() - idle, usdgIn);
        assertEq(usdg.balanceOf(address(venue)), 0);
        assertEq(fund.balanceOf(address(venue)), 0);
    }

    function test_fork_collectLpFees() public requiresFork {
        _urSwap(address(usdg), 2000e6);
        uint256 got = _urSwap(address(usdg), 2000e6);
        _urSwap(address(fund), uint128(got));
        (uint256 usdgAmount, uint256 burned) = venue.collectLpFees();
        assertGt(usdgAmount, 0);
        assertGt(burned, 0);
    }

    function test_fork_redeemTakesPositionSlice() public requiresFork {
        _passDepositorLock();
        vm.prank(alice);
        launch.claim(false);
        uint128 liquidity = venue.positionLiquidity();
        vm.prank(alice);
        (, uint256 usdgOut) = fund.redeem(10_000e18, alice, new uint256[](0), 0);
        assertGt(usdgOut, 0);
        assertLt(venue.positionLiquidity(), liquidity);
    }

    function test_fork_migrateToNewHookrPool() public requiresFork {
        PoolKey memory oldKey = venue.poolKey();
        bytes32 oldFamily = venue.family();
        uint256 price = venue.spotPrice();
        vm.prank(admin);
        venue.migrate(
            PoolSettings({
                buyTaxPips: 20_000,
                sellTaxPips: 20_000,
                hookrShareBps: 2000,
                lpFeePips: 3000,
                tickSpacing: 120
            })
        );
        PoolKey memory key = venue.poolKey();
        assertEq(address(key.hooks), ROOT);
        assertEq(key.tickSpacing, 120);
        assertEq(IHookrLauncher(LAUNCHER).position(oldFamily, 0).liquidity, 0);
        assertEq(poolManager.getLiquidity(oldKey.toId()), 0);
        assertApproxEqRel(venue.spotPrice(), price, 1e12);
        assertEq(staking.lpEpoch(), 1);
        IHookrDirectionalTax.Terms memory t = IHookrDirectionalTax(TAX).terms(ROOT, key.toId());
        assertEq(t.buyTaxPips, 20_000);

        vm.roll(block.number + 1);
        assertGt(_urSwap(address(usdg), 1000e6), 0);
        assertGt(venue.collectTax(), 0);
    }
}
