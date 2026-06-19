// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IETokenFactory} from "../../src/interfaces/IETokenFactory.sol";

import {EToken} from "../../src/tokens/EToken.sol";
import {ETokenFactory} from "../../src/tokens/ETokenFactory.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title ETokenFactory Unit Tests
/// @notice Tests admin-gated eToken deployment: access control, deployed-token wiring
///         (metadata, ticker, registry, reward token), and the ETokenCreated event.
contract ETokenFactoryTest is BaseTest {
    ETokenFactory public factory;
    MockERC20 public rewardToken;

    bytes32 constant TICKER = bytes32("TSLA");
    string constant NAME = "Own TSLA";
    string constant SYMBOL = "eTSLA";

    function setUp() public override {
        super.setUp();

        rewardToken = new MockERC20("Reward USDC", "rUSDC", 6);
        vm.label(address(rewardToken), "rewardToken");

        factory = new ETokenFactory(address(protocolRegistry));
        vm.label(address(factory), "ETokenFactory");
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsRegistry() public view {
        assertEq(address(factory.registry()), address(protocolRegistry));
    }

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(bytes("zero registry"));
        new ETokenFactory(address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  createEToken — access control
    // ──────────────────────────────────────────────────────────

    function test_createEToken_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IETokenFactory.OnlyAdmin.selector);
        factory.createEToken(NAME, SYMBOL, TICKER, address(rewardToken));
    }

    function test_createEToken_byAdmin_returnsNonZeroAddress() public {
        vm.prank(Actors.ADMIN);
        address token = factory.createEToken(NAME, SYMBOL, TICKER, address(rewardToken));
        assertTrue(token != address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  createEToken — deployed-token state
    // ──────────────────────────────────────────────────────────

    function test_createEToken_deploysTokenWithCorrectState() public {
        vm.prank(Actors.ADMIN);
        address token = factory.createEToken(NAME, SYMBOL, TICKER, address(rewardToken));

        EToken et = EToken(token);
        assertEq(et.name(), NAME);
        assertEq(et.symbol(), SYMBOL);
        assertEq(et.ticker(), TICKER);
        assertEq(et.decimals(), 18);
        assertEq(et.rewardToken(), address(rewardToken));
        assertEq(address(et.registry()), address(protocolRegistry));
        assertEq(et.totalSupply(), 0);
    }

    /// @dev Non-dividend assets (eTSLA, eGOLD, …) carry no reward token; address(0) is allowed.
    function test_createEToken_zeroRewardToken_succeeds() public {
        vm.prank(Actors.ADMIN);
        address token = factory.createEToken(NAME, SYMBOL, TICKER, address(0));
        assertEq(EToken(token).rewardToken(), address(0));
    }

    function test_createEToken_multipleCalls_returnDistinctAddresses() public {
        vm.startPrank(Actors.ADMIN);
        address t1 = factory.createEToken("Own TSLA", "eTSLA", bytes32("TSLA"), address(rewardToken));
        address t2 = factory.createEToken("Own GOLD", "eGOLD", bytes32("GOLD"), address(rewardToken));
        vm.stopPrank();

        assertTrue(t1 != t2, "each deployment must be a distinct contract");
        assertTrue(t1 != address(0) && t2 != address(0));
        assertEq(EToken(t1).ticker(), bytes32("TSLA"));
        assertEq(EToken(t2).ticker(), bytes32("GOLD"));
    }

    // ──────────────────────────────────────────────────────────
    //  createEToken — event
    // ──────────────────────────────────────────────────────────

    function test_createEToken_emitsETokenCreated() public {
        // The eToken is the factory's next CREATE, so its address is deterministic.
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IETokenFactory.ETokenCreated(predicted, TICKER, SYMBOL);

        vm.prank(Actors.ADMIN);
        address token = factory.createEToken(NAME, SYMBOL, TICKER, address(rewardToken));

        assertEq(token, predicted, "returned address must match the emitted (deployed) address");
    }

    // ──────────────────────────────────────────────────────────
    //  createEToken — registry wiring (functional)
    // ──────────────────────────────────────────────────────────

    /// @dev The factory's core responsibility is wiring each eToken to the registry. Prove it end-to-end
    ///      by exercising a registry-gated path on the deployed token: only registry.market() may mint.
    function test_createEToken_deployedTokenIsWiredToRegistry() public {
        vm.prank(Actors.ADMIN);
        address token = factory.createEToken(NAME, SYMBOL, TICKER, address(rewardToken));

        // Register this test contract as the MARKET (order system) so it can mint.
        // startPrank (not prank): the nested protocolRegistry.MARKET() argument is itself an
        // external call that would otherwise consume a single-shot prank.
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(this));
        vm.stopPrank();

        EToken(token).mint(Actors.MINTER1, 100e18);
        assertEq(EToken(token).balanceOf(Actors.MINTER1), 100e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_createEToken_setsTicker(
        bytes32 ticker_
    ) public {
        vm.prank(Actors.ADMIN);
        address token = factory.createEToken(NAME, SYMBOL, ticker_, address(rewardToken));
        assertEq(EToken(token).ticker(), ticker_);
    }
}
