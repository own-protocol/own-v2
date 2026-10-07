// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPositionManager} from "../../src/interfaces/external/IPositionManager.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManagerFull is IPositionManager {
    function nextTokenId() external view returns (uint256);
}

/// @title FundLpStakingRobinhoodForkTest — LP position staking against the live Uniswap v4
///        PoolManager and PositionManager on Robinhood Chain
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Launches a fund on the live PoolManager, mints a
///         full-range position in its pool through the live PositionManager, stakes the NFT, trades
///         against it, collects its swap fees while staked, claims yield and unstakes.
contract FundLpStakingRobinhoodForkTest is FundTestBase {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // docs/own-curated-funds.md; developers.uniswap.org v4 deployments
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

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
        vm.prank(admin);
        hook.setLpFee(address(fund), 3000);
    }

    function _deployPoolManager() internal pure override returns (IPoolManager) {
        return IPoolManager(POOL_MANAGER);
    }

    function _deployPositionManager() internal pure override returns (address) {
        return POSITION_MANAGER;
    }

    /// @dev Buys fund tokens in the pool and mints a full-range position with them through the
    ///      live PositionManager (MINT_POSITION + SETTLE_PAIR, paid through Permit2).
    function _mintPosition(address who, uint128 liquidity) internal returns (uint256 tokenId) {
        _poolSwap(who, true, -int256(20_000e6));
        PoolKey memory key = hook.poolKeyOf(address(fund));
        IPositionManagerFull pm = IPositionManagerFull(POSITION_MANAGER);
        tokenId = pm.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            uint256(liquidity),
            type(uint128).max,
            type(uint128).max,
            who,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.startPrank(who);
        usdg.approve(PERMIT2, type(uint256).max);
        fund.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(usdg), POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(address(fund), POSITION_MANAGER, type(uint160).max, type(uint48).max);
        pm.modifyLiquidities(abi.encode(hex"020d", params), block.timestamp);
        vm.stopPrank();
        assertEq(pm.ownerOf(tokenId), who);
        assertEq(pm.getPositionLiquidity(tokenId), liquidity);
    }

    function test_fork_stakeTradeCollectClaimUnstake() public requiresFork {
        uint128 liq = hook.positionLiquidity(address(fund)) / 10;
        uint256 id = _mintPosition(carol, liq);

        vm.prank(carol);
        IPositionManager(POSITION_MANAGER).safeTransferFrom(carol, address(staking), id);
        (address owner, uint128 stakedLiq) = staking.positionOf(id);
        assertEq(owner, carol);
        assertEq(stakedLiq, liq);

        // Trade both ways so the position earns fees in both currencies.
        _poolSwap(dave, true, -int256(5000e6));
        _poolSwap(dave, false, -int256(fund.balanceOf(dave) / 2));

        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();

        uint256 usdgBefore = usdg.balanceOf(bob);
        uint256 fundBefore = fund.balanceOf(bob);
        vm.prank(carol);
        staking.collectPositionFees(id, bob);
        assertGt(usdg.balanceOf(bob), usdgBefore);
        assertGt(fund.balanceOf(bob), fundBefore);
        assertEq(IPositionManager(POSITION_MANAGER).getPositionLiquidity(id), liq);

        uint256 carolFund = fund.balanceOf(carol);
        vm.prank(carol);
        uint256 paid = staking.unstakePosition(id, carol);
        assertGt(paid, 0);
        assertEq(fund.balanceOf(carol), carolFund + paid);
        assertEq(IPositionManager(POSITION_MANAGER).ownerOf(id), carol);
        assertEq(staking.lpLiquidity(), 0);
    }
}
