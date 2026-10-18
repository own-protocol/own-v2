// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseGateway} from "../../src/bridge/BaseGateway.sol";
import {IBaseGateway} from "../../src/interfaces/IBaseGateway.sol";
import {CcipClient} from "../../src/interfaces/external/ICcip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Skipped unless `BASE_RPC` is set. Settles a sell order on Base through the live Across SpokePool:
///         the USDC is deposited for USDG on Robinhood Chain to the seller, who is also the refund address.
///         cbZEC and cbHYPE are B20 precompiles a fork can't execute, so the order here is already USDC;
///         the unwrap and the sale are covered by the unit tests and the live rZEC/rHYPE runs.
contract BaseGatewayBaseForkTest is Test {
    address constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address constant SPOKE_POOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint64 constant RH_SELECTOR = 6_180_753_054_346_818_345;
    uint256 constant RH_CHAIN_ID = 4663;

    BaseGateway internal gw;
    address internal safe = makeAddr("safe");
    address internal keeper = makeAddr("keeper");
    address internal exitGateway = makeAddr("rhExitGateway");
    address internal alice = makeAddr("alice");
    bool internal _forkActive;

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == 8453, "not Base");
        _forkActive = true;
        gw = new BaseGateway(safe, BASE_ROUTER, RH_SELECTOR, USDC, SPOKE_POOL, RH_CHAIN_ID, RH_USDG);
        vm.startPrank(safe);
        gw.setRemoteGateway(exitGateway);
        gw.setKeeper(keeper, true);
        vm.stopPrank();
    }

    function test_fork_settle_depositsIntoAcross() public requiresFork {
        bytes32 id = _deliver(250e6, 248e6);
        uint256 spokeBefore = IERC20(USDC).balanceOf(SPOKE_POOL);
        vm.prank(keeper);
        gw.settle(id, IBaseGateway.Swap(address(0), ""), 249e6, uint32(block.timestamp));
        assertEq(IERC20(USDC).balanceOf(SPOKE_POOL) - spokeBefore, 250e6, "Across deposit missing");
        assertEq(IERC20(USDC).balanceOf(address(gw)), 0);
        assertEq(uint8(gw.getOrder(id).status), uint8(IBaseGateway.Status.Settled));
    }

    function test_fork_settle_staleQuote_reverts() public requiresFork {
        bytes32 id = _deliver(250e6, 248e6);
        vm.prank(keeper);
        vm.expectRevert();
        gw.settle(id, IBaseGateway.Swap(address(0), ""), 249e6, uint32(block.timestamp - 2 hours));
    }

    function test_fork_restockGuard_keepsOrderUsdc() public requiresFork {
        _deliver(250e6, 248e6);
        assertEq(gw.freeUsdc(), 0);
    }

    function _deliver(uint256 amount, uint256 minOut) internal returns (bytes32) {
        deal(USDC, address(gw), IERC20(USDC).balanceOf(address(gw)) + amount);
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: USDC, amount: amount});
        bytes32 messageId = keccak256(abi.encode(amount, block.number));
        vm.prank(BASE_ROUTER);
        gw.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: RH_SELECTOR,
                sender: abi.encode(exitGateway),
                data: abi.encode(alice, minOut),
                destTokenAmounts: tokens
            })
        );
        return gw.orderId(messageId, 0);
    }
}
