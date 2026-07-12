// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal asset registry surface for the fork custody test: in-house oracle for every
///      ticker, single allowlisted maker.
contract ForkStubAssetRegistry {
    address public allowedMaker;

    constructor(
        address maker
    ) {
        allowedMaker = maker;
    }

    function getOracleType(
        bytes32
    ) external pure returns (uint8) {
        return 1;
    }

    function isMakerAllowed(bytes32, address signer) external view returns (bool) {
        return signer == allowedMaker;
    }
}

/// @title WrapperBaseFork — live-wrapper due diligence on Base (design §8.1 / Phase 5)
/// @notice Runs against the REAL candidate wrapper token on a Base fork. Both env vars must be
///         set or every test skips:
///           BASE_RPC           — Base RPC endpoint
///           WRAPPER_TOKEN_BASE — the candidate wrapper token address (e.g. Dinari dTSLA)
///         Verifies, against the real token: metadata (≤18 decimals), unrestricted transfers to
///         fresh EOAs and to protocol custody (also catches fee-on-transfer), and the full
///         ReserveVault custody round-trip (deposit → mark sync → maker withdraw to linked
///         settlement address).
contract WrapperBaseForkTest is Test {
    bytes32 internal constant ASSET = bytes32("ASSET");
    bytes32 internal constant WRAPPER_TICKER = bytes32("WRAPPER");

    address internal admin = makeAddr("admin");
    address internal signer = makeAddr("signer");
    address internal linked = makeAddr("linked");

    ProtocolRegistry internal registry;
    VaultManager internal manager;
    MockOracleVerifier internal oracle;
    ReserveVault internal reserve;

    IERC20 internal wrapper;
    uint256 internal unit;

    bool internal _forkActive;

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        address wrapperAddr = vm.envOr("WRAPPER_TOKEN_BASE", address(0));
        if (bytes(rpc).length == 0 || wrapperAddr == address(0)) {
            return; // not configured — every test skips
        }

        vm.createSelectFork(rpc);
        _forkActive = true;
        wrapper = IERC20(wrapperAddr);
        unit = 10 ** IERC20Metadata(wrapperAddr).decimals();

        // Minimal protocol stack around the real token.
        registry = new ProtocolRegistry(admin, 0, 2 minutes);
        oracle = new MockOracleVerifier();
        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.setAddress(registry.MARKET(), makeAddr("market"));
        registry.setAddress(registry.ASSET_REGISTRY(), address(new ForkStubAssetRegistry(signer)));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        registry.setAddress(registry.PYTH_ORACLE(), address(oracle));
        vm.stopPrank();

        manager = new VaultManager(IProtocolRegistry(address(registry)));
        vm.startPrank(admin);
        registry.setAddress(registry.VAULT_MANAGER(), address(manager));
        manager.setGlobalMaxUtilizationBps(8000);
        manager.setMaxMarkAge(365 days);
        manager.registerSigner(signer, linked);
        vm.stopPrank();

        // Prices are irrelevant to custody (no exposure is opened); $1 keeps the marks sane.
        oracle.setPrice(ASSET, 1e18);
        oracle.setPrice(WRAPPER_TICKER, 1e18);

        reserve = new ReserveVault(wrapperAddr, address(registry), linked);
        vm.prank(admin);
        manager.registerVault(address(reserve), WRAPPER_TICKER, ASSET);
    }

    /// @dev §8.1: token metadata sanity — the ReserveVault constructor enforces ≤18 decimals;
    ///      surface the live values for the deploy checklist.
    function test_fork_wrapperMetadata() public requiresFork {
        uint8 dec = IERC20Metadata(address(wrapper)).decimals();
        assertLe(dec, 18, "wrapper decimals must fit ReserveVault");
        emit log_named_string("wrapper name", IERC20Metadata(address(wrapper)).name());
        emit log_named_string("wrapper symbol", IERC20Metadata(address(wrapper)).symbol());
        emit log_named_uint("wrapper decimals", dec);
        emit log_named_uint("wrapper totalSupply", wrapper.totalSupply());
    }

    /// @dev §8.1: transfers to arbitrary fresh EOAs and to protocol custody must move the exact
    ///      amount (no allowlist gate, no fee-on-transfer). If the issuer uses a restrictor,
    ///      this is the test that catches it before deployment.
    function test_fork_wrapperTransfer_noRestrictions() public requiresFork {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 amount = 5 * unit;
        deal(address(wrapper), alice, amount);
        assertEq(wrapper.balanceOf(alice), amount, "deal failed (non-standard balance storage?)");

        // EOA → EOA.
        vm.prank(alice);
        wrapper.transfer(bob, 2 * unit);
        assertEq(wrapper.balanceOf(bob), 2 * unit, "EOA transfer restricted or taxed");

        // EOA → protocol custody (the ReserveVault contract).
        vm.prank(alice);
        wrapper.transfer(address(reserve), 3 * unit);
        assertEq(wrapper.balanceOf(address(reserve)), 3 * unit, "custody transfer restricted or taxed");
    }

    /// @dev Full custody round-trip against the real token: maker backfills via deposit (mark
    ///      syncs at the wrapper's real decimals), then recovers the surplus via the maker
    ///      withdraw path — funds land at the linked settlement address, never the hot key.
    function test_fork_reserveVaultCustodyRoundTrip() public requiresFork {
        uint256 amount = 10 * unit;
        deal(address(wrapper), signer, amount);

        vm.startPrank(signer);
        wrapper.approve(address(reserve), amount);
        reserve.deposit(amount);
        vm.stopPrank();

        assertEq(reserve.totalAssets(), amount, "custody balance");
        assertGt(manager.collateralMark(address(reserve)), 0, "mark synced from real decimals");

        // No exposure was opened, so the whole reserve is recoverable surplus.
        vm.prank(signer);
        reserve.withdraw(amount);

        assertEq(wrapper.balanceOf(linked), amount, "round-trip pays the linked address");
        assertEq(wrapper.balanceOf(signer), 0, "hot key receives nothing");
        assertEq(reserve.totalAssets(), 0, "reserve fully drained");
        assertEq(manager.collateralMark(address(reserve)), 0, "mark fully released");
    }
}
