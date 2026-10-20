// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    Ccip,
    CcipWrapperSetup,
    ICrossChainToken,
    ITokenAdminRegistry,
    ITokenPool
} from "../../script/ccip/CcipWrapperSetup.sol";
import {CcipWrapRouter} from "../../src/bridge/CcipWrapRouter.sol";
import {CcipWrappedToken} from "../../src/bridge/CcipWrappedToken.sol";
import {CcipClient, ICcipRouter} from "../../src/interfaces/external/ICcip.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

struct ReleaseOrMintInV1 {
    bytes originalSender;
    uint64 remoteChainSelector;
    address receiver;
    uint256 sourceDenominatedAmount;
    address localToken;
    bytes sourcePoolAddress;
    bytes sourcePoolData;
    bytes offchainTokenData;
}

interface IPoolRelease {
    function releaseOrMint(
        ReleaseOrMintInV1 calldata releaseOrMintIn
    ) external returns (uint256 destinationAmount);
}

interface IRouterRamps {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOffRamps() external view returns (OffRamp[] memory);
}

interface IAcceptDefaultAdmin {
    function acceptDefaultAdminTransfer() external;
    function totalSupply() external view returns (uint256);
}

/// @notice Skipped unless `BASE_RPC` and `ROBINHOOD_RPC` are set and `tools/fetch-ccip-bytecode.sh` has run.
///         Runs the rZEC setup on Base and Robinhood forks against Chainlink's live factories, registries and
///         routers, then moves tokens both ways: a real `ccipSend` through each chain's OnRamp, and the delivery
///         replayed as that chain's OffRamp. cbZEC is a Base B20 precompile that forks can't execute, so a plain
///         8-decimal ERC-20 stands in for it here; the live test covers the real token.
contract CcipWrapperForkTest is Test, CcipWrapperSetup {
    uint256 internal baseFork;
    uint256 internal rhFork;
    bool internal _forkActive;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal safe = makeAddr("safe");

    WrapperSpec internal spec;
    MockERC20 internal cbZec;
    address internal wrapper;
    address internal basePool;
    address internal lockBox;
    address internal rhToken;
    address internal rhPool;
    CcipWrapRouter internal wrapRouter;

    Ccip.RateLimitConfig internal limit = Ccip.RateLimitConfig({isEnabled: true, capacity: 100e8, rate: 1e8});

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory baseRpc = vm.envOr("BASE_RPC", string(""));
        string memory rhRpc = vm.envOr("ROBINHOOD_RPC", string(""));
        string memory bin = string.concat(vm.projectRoot(), "/", BYTECODE_DIR, "burn_mint_token_pool.bin");
        if (bytes(baseRpc).length == 0 || bytes(rhRpc).length == 0 || !vm.exists(bin)) return;
        _forkActive = true;
        baseFork = vm.createFork(baseRpc);
        rhFork = vm.createFork(rhRpc);

        vm.selectFork(baseFork);
        cbZec = new MockERC20("Coinbase Wrapped ZEC", "cbZEC", 8);
        vm.makePersistent(address(cbZec));
        spec = _spec("ZEC");
        spec.underlying = address(cbZec);
        (wrapper, basePool, lockBox) = _setupBase(spec, address(this));
        wrapRouter = new CcipWrapRouter(BASE_ROUTER, RH_SELECTOR);

        vm.selectFork(rhFork);
        (rhToken, rhPool) = _setupRobinhood(spec, address(this), wrapper, basePool, limit);

        vm.selectFork(baseFork);
        _linkBase(basePool, rhToken, rhPool, limit);
    }

    function test_setup_registeredOnBothChains() public requiresFork {
        vm.selectFork(baseFork);
        assertEq(ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).getPool(wrapper), basePool);
        assertEq(ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).getTokenConfig(wrapper).administrator, address(this));
        assertEq(ITokenPool(basePool).owner(), address(this));
        assertEq(ITokenPool(lockBox).owner(), address(this));
        assertEq(ITokenPool(basePool).typeAndVersion(), "LockReleaseTokenPool 2.0.0");
        assertTrue(ITokenPool(basePool).isSupportedChain(RH_SELECTOR));
        assertEq(ITokenPool(basePool).getRemoteToken(RH_SELECTOR), abi.encode(rhToken));
        assertEq(ITokenPool(basePool).getRemotePools(RH_SELECTOR)[0], abi.encode(rhPool));
        assertEq(CcipWrappedToken(wrapper).symbol(), "rZEC");
        assertEq(CcipWrappedToken(wrapper).decimals(), 8);

        vm.selectFork(rhFork);
        assertEq(ITokenAdminRegistry(RH_TOKEN_ADMIN_REGISTRY).getPool(rhToken), rhPool);
        assertEq(ITokenAdminRegistry(RH_TOKEN_ADMIN_REGISTRY).getTokenConfig(rhToken).administrator, address(this));
        assertEq(ITokenPool(rhPool).owner(), address(this));
        assertEq(ITokenPool(rhPool).typeAndVersion(), "BurnMintTokenPool 2.0.0");
        assertEq(ICrossChainToken(rhToken).owner(), address(this));
        assertTrue(ICrossChainToken(rhToken).hasRole(keccak256("MINTER_ROLE"), rhPool));
        assertTrue(ICrossChainToken(rhToken).hasRole(keccak256("BURNER_ROLE"), rhPool));
        assertFalse(ICrossChainToken(rhToken).hasRole(keccak256("BURN_MINT_ADMIN_ROLE"), RH_POOL_FACTORY));
        assertEq(ITokenPool(rhPool).getRemoteToken(BASE_SELECTOR), abi.encode(wrapper));
        assertEq(ITokenPool(rhPool).getRemotePools(BASE_SELECTOR)[0], abi.encode(basePool));
        assertEq(CcipWrappedToken(rhToken).symbol(), "rZEC");
        assertEq(CcipWrappedToken(rhToken).decimals(), 8);
    }

    function test_roundTrip_baseToRobinhoodAndBack() public requiresFork {
        uint256 amt = 2e8;

        // Base: wrap and send through the live Router and OnRamp; the pool locks the wrapper in its lockbox.
        vm.selectFork(baseFork);
        cbZec.mint(alice, amt);
        vm.deal(alice, 1 ether);
        uint256 fee = wrapRouter.quote(wrapper, amt, bob);
        assertGt(fee, 0);
        vm.startPrank(alice);
        cbZec.approve(address(wrapRouter), amt);
        wrapRouter.wrapAndSend{value: fee}(wrapper, amt, bob);
        vm.stopPrank();
        assertEq(IERC20(wrapper).balanceOf(lockBox), amt);
        assertEq(cbZec.balanceOf(wrapper), amt);

        // Robinhood: the OffRamp delivery mints to bob.
        vm.selectFork(rhFork);
        vm.prank(_offRamp(RH_ROUTER, BASE_SELECTOR));
        IPoolRelease(rhPool).releaseOrMint(_inbound(alice, BASE_SELECTOR, bob, amt, rhToken, basePool));
        assertEq(IERC20(rhToken).balanceOf(bob), amt);

        // Robinhood: bob sends back to the wrap router on Base with carol as recipient; the pool burns.
        vm.deal(bob, 1 ether);
        CcipClient.EVM2AnyMessage memory m = _backMessage(rhToken, amt, address(wrapRouter), carol);
        uint256 backFee = ICcipRouter(RH_ROUTER).getFee(BASE_SELECTOR, m);
        vm.startPrank(bob);
        IERC20(rhToken).approve(RH_ROUTER, amt);
        ICcipRouter(RH_ROUTER).ccipSend{value: backFee}(BASE_SELECTOR, m);
        vm.stopPrank();
        assertEq(IAcceptDefaultAdmin(rhToken).totalSupply(), 0);

        // Base: the OffRamp releases the wrapper to the wrap router, which unwraps to carol.
        vm.selectFork(baseFork);
        vm.prank(_offRamp(BASE_ROUTER, RH_SELECTOR));
        IPoolRelease(basePool).releaseOrMint(_inbound(bob, RH_SELECTOR, address(wrapRouter), amt, wrapper, rhPool));
        CcipClient.EVMTokenAmount[] memory got = new CcipClient.EVMTokenAmount[](1);
        got[0] = CcipClient.EVMTokenAmount({token: wrapper, amount: amt});
        vm.prank(BASE_ROUTER);
        wrapRouter.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: bytes32(uint256(1)),
                sourceChainSelector: RH_SELECTOR,
                sender: abi.encode(bob),
                data: abi.encode(carol),
                destTokenAmounts: got
            })
        );
        assertEq(cbZec.balanceOf(carol), amt);
        assertEq(IERC20(wrapper).totalSupply(), 0);
        assertEq(cbZec.balanceOf(wrapper), 0);
    }

    function test_inbound_aboveRateLimit_reverts() public requiresFork {
        vm.selectFork(rhFork);
        address offRamp = _offRamp(RH_ROUTER, BASE_SELECTOR);
        vm.prank(offRamp);
        vm.expectRevert();
        IPoolRelease(rhPool).releaseOrMint(_inbound(alice, BASE_SELECTOR, bob, limit.capacity + 1, rhToken, basePool));
    }

    function test_inbound_unknownSourcePool_reverts() public requiresFork {
        vm.selectFork(rhFork);
        address offRamp = _offRamp(RH_ROUTER, BASE_SELECTOR);
        vm.prank(offRamp);
        vm.expectRevert();
        IPoolRelease(rhPool).releaseOrMint(_inbound(alice, BASE_SELECTOR, bob, 1e8, rhToken, address(0xbad)));
    }

    function test_inbound_notOffRamp_reverts() public requiresFork {
        vm.selectFork(rhFork);
        vm.prank(alice);
        vm.expectRevert();
        IPoolRelease(rhPool).releaseOrMint(_inbound(alice, BASE_SELECTOR, bob, 1e8, rhToken, basePool));
    }

    function test_handOff_safeAcceptsEverything() public requiresFork {
        vm.selectFork(baseFork);
        _handOffBase(wrapper, basePool, safe);
        vm.startPrank(safe);
        ITokenPool(basePool).acceptOwnership();
        ITokenPool(lockBox).acceptOwnership();
        ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).acceptAdminRole(wrapper);
        vm.stopPrank();
        assertEq(ITokenPool(basePool).owner(), safe);
        assertEq(ITokenPool(lockBox).owner(), safe);
        assertEq(ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).getTokenConfig(wrapper).administrator, safe);

        vm.selectFork(rhFork);
        _handOffRobinhood(rhToken, rhPool, safe);
        // The token's admin transfer has a zero delay but can only be accepted after the block it was started in.
        vm.warp(block.timestamp + 1);
        vm.startPrank(safe);
        ITokenPool(rhPool).acceptOwnership();
        ITokenAdminRegistry(RH_TOKEN_ADMIN_REGISTRY).acceptAdminRole(rhToken);
        IAcceptDefaultAdmin(rhToken).acceptDefaultAdminTransfer();
        vm.stopPrank();
        assertEq(ITokenPool(rhPool).owner(), safe);
        assertEq(ITokenAdminRegistry(RH_TOKEN_ADMIN_REGISTRY).getTokenConfig(rhToken).administrator, safe);
        assertEq(ICrossChainToken(rhToken).owner(), safe);
    }

    /// @notice The fetched LockRelease bytecode builds the same runtime code as a LockReleaseTokenPool 2.0.0
    ///         Chainlink's factory users already run on Robinhood Chain.
    function test_bytecode_matchesLivePool() public requiresFork {
        vm.selectFork(rhFork);
        address live = 0xef8D599A18C13d24F6269375859Fd2b0d27D1947;
        bytes memory init = abi.encodePacked(
            _bin("lock_release_token_pool"),
            abi.encode(
                ITokenPool(live).getToken(),
                uint8(8),
                address(0),
                0xe8464c353210Cc398A45dB2454FBc5BCd25fFf20,
                RH_ROUTER,
                ITokenPool(live).getLockBox()
            )
        );
        address deployed;
        assembly {
            deployed := create(0, add(init, 0x20), mload(init))
        }
        assertTrue(deployed != address(0));
        assertEq(keccak256(deployed.code), keccak256(live.code));
    }

    function _offRamp(address router, uint64 source) internal view returns (address) {
        IRouterRamps.OffRamp[] memory ramps = IRouterRamps(router).getOffRamps();
        for (uint256 i; i < ramps.length; ++i) {
            if (ramps[i].sourceChainSelector == source) return ramps[i].offRamp;
        }
        revert("no offRamp");
    }

    function _inbound(
        address sender,
        uint64 source,
        address receiver,
        uint256 amount,
        address localToken,
        address sourcePool
    ) internal pure returns (ReleaseOrMintInV1 memory) {
        return ReleaseOrMintInV1({
            originalSender: abi.encode(sender),
            remoteChainSelector: source,
            receiver: receiver,
            sourceDenominatedAmount: amount,
            localToken: localToken,
            sourcePoolAddress: abi.encode(sourcePool),
            sourcePoolData: abi.encode(uint256(8)),
            offchainTokenData: ""
        });
    }

    function _backMessage(
        address token,
        uint256 amount,
        address receiver,
        address recipient
    ) internal pure returns (CcipClient.EVM2AnyMessage memory) {
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: token, amount: amount});
        return CcipClient.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: abi.encode(recipient),
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: CcipClient.encodeExtraArgs(
                CcipClient.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})
            )
        });
    }
}
