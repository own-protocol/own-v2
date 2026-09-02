// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainlinkOracleVerifier} from "../../src/core/ChainlinkOracleVerifier.sol";
import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {deployEUSDManager} from "../helpers/DeployEusdModule.sol";
import {deployOwnMarket} from "../helpers/DeployOwnMarket.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

interface IAggV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title EusdRobinhoodFork — eUSD module + UUPS market against live Robinhood Chain state
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Deploys the eUSD CDP stack on a fork wired to
///         the LIVE ProtocolRegistry, AssetRegistry, eSPY token and Chainlink SPY feed, and
///         verifies the mint-freshness asymmetry against real oracle data: mint needs an
///         in-session price, exits work off-hours at the anchor. Also deploys the UUPS OwnMarket
///         (linking ForceExecuteLib on the fork) against the live registry and exercises the
///         upgrade path. Time is pinned relative to the feed's real `updatedAt`, so the tests are
///         deterministic whether they run during or outside US market hours.
contract EusdRobinhoodForkTest is Test {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // docs/contracts-robinhood.md
    ProtocolRegistry constant REGISTRY = ProtocolRegistry(0x93e08ca467046737F75AAD4C936356c196AaA36F);

    bytes32 constant SPY = bytes32("SPY");
    uint16 constant MCR = 15_000;
    uint256 constant MINT_PRICE_MAX_AGE = 900;

    EUSD internal eusd;
    EUSDManager internal manager;
    address internal eSPY;
    ChainlinkOracleVerifier internal verifier;

    address internal admin = makeAddr("eusdForkAdmin");
    address internal alice = makeAddr("alice");

    /// @dev Timestamp at which the live SPY price counts as freshly observed (feed updatedAt or a
    ///      newer in-house quote, whichever is later). Tests warp relative to this.
    uint256 internal freshTs;

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

        eSPY = IAssetRegistry(REGISTRY.assetRegistry()).getActiveToken(SPY);
        verifier = ChainlinkOracleVerifier(REGISTRY.inhouseOracle());

        // Pin time just after the freshest real observation (CL updatedAt vs in-house quote), so
        // the feed reads as live regardless of when the fork block was mined.
        (,,, uint256 clUpdated,) = IAggV3(verifier.getChainlinkConfig(SPY).aggregator).latestRoundData();
        (, uint256 ihTs) = verifier.getInhousePrice(SPY);
        freshTs = (clUpdated > ihTs ? clUpdated : ihTs) + 60;
        vm.warp(freshTs);

        // Deploy the eUSD stack against the LIVE registry.
        eusd = new EUSD(admin);
        manager = deployEUSDManager(
            address(REGISTRY),
            address(eusd),
            IEUSDManager.RiskParams({
                mcrBps: MCR,
                liquidationThresholdBps: 13_000,
                liquidationBonusBps: 500,
                stabilityFeeBps: 200,
                debtCeiling: 1_000_000e18,
                minDebt: 100e18,
                mintPriceMaxAge: MINT_PRICE_MAX_AGE
            })
        );
        bytes32 minterRole = eusd.MINTER_ROLE();
        vm.prank(admin);
        eusd.grantRole(minterRole, address(manager));

        // The live PROTOCOL_ADMIN grants our test admin the protocol ADMIN role.
        vm.prank(REGISTRY.defaultAdmin());
        REGISTRY.grantRole(keccak256("ADMIN"), admin);
        vm.prank(admin);
        manager.addCollateral(eSPY, SPY);

        // Fund alice with live eSPY and approve the manager.
        deal(eSPY, alice, 100e18);
        vm.prank(alice);
        IERC20(eSPY).approve(address(manager), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Live wiring sanity
    // ──────────────────────────────────────────────────────────

    function test_fork_liveWiring() public requiresFork {
        assertTrue(eSPY != address(0), "eSPY not listed");
        // Fee accrual mints to the treasury — a deployment precondition of the module.
        assertTrue(REGISTRY.treasury() != address(0), "treasury unset");
        (uint256 price, uint256 ts) = verifier.getPrice(SPY);
        assertGt(price, 0, "no live SPY price");
        assertLe(block.timestamp - ts, MINT_PRICE_MAX_AGE, "pinned time not fresh");
    }

    // ──────────────────────────────────────────────────────────
    //  CDP lifecycle at the live oracle price
    // ──────────────────────────────────────────────────────────

    function test_fork_depositMintRepayClose_liveOracle() public requiresFork {
        (uint256 price,) = verifier.getPrice(SPY);
        uint256 collValue = 10e18 * price / 1e18;
        uint256 mintAmount = collValue * 10_000 / MCR / 2; // half the max — comfortably healthy

        vm.startPrank(alice);
        manager.deposit(eSPY, 10e18, address(0));
        manager.mint(eSPY, mintAmount, address(0));
        vm.stopPrank();

        assertEq(eusd.balanceOf(alice), mintAmount);
        assertEq(eusd.totalSupply(), manager.totalDebt());
        assertGe(manager.collateralRatioBps(eSPY, alice), 2 * MCR - 10); // ~2x MCR, floor rounding

        vm.prank(alice);
        manager.repay(eSPY, alice, mintAmount / 2, address(0));
        vm.prank(alice);
        manager.closePosition(eSPY);

        assertEq(IERC20(eSPY).balanceOf(alice), 100e18, "collateral not fully returned");
        assertEq(manager.totalDebt(), 0);
        assertEq(eusd.totalSupply(), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Freshness asymmetry against the real feed
    // ──────────────────────────────────────────────────────────

    function test_fork_mint_offHours_reverts() public requiresFork {
        vm.prank(alice);
        manager.deposit(eSPY, 10e18, address(0));

        // 5h past the last observation: beyond clFreshWindow (4h) and inhouseMaxStaleness (1h),
        // so getPrice reports the raw feed timestamp — the market is closed as far as the
        // protocol is concerned, and risk-increasing actions must be blocked.
        vm.warp(freshTs + 5 hours);
        vm.expectPartialRevert(IEUSDManager.StaleMintPrice.selector);
        vm.prank(alice);
        manager.mint(eSPY, 1000e18, address(0));
    }

    function test_fork_exitAndRedeem_offHours_liveAnchor() public requiresFork {
        (uint256 price,) = verifier.getPrice(SPY);
        uint256 mintAmount = (10e18 * price / 1e18) * 10_000 / MCR / 2;
        vm.startPrank(alice);
        manager.deposit(eSPY, 10e18, address(0));
        manager.mint(eSPY, mintAmount, address(0));
        vm.stopPrank();

        // Market closes; the anchor (raw CL answer, valid up to maxAnchorAge) still serves exits.
        vm.warp(freshTs + 5 hours);

        uint256 redeemAmount = 200e18;
        vm.prank(alice);
        (uint256 collateralOut, uint256 debtRepaid) = manager.redeem(eSPY, redeemAmount, 0, 0, address(0));
        assertEq(debtRepaid, redeemAmount);
        (uint256 anchorPrice,) = verifier.getPrice(SPY);
        assertEq(collateralOut, redeemAmount * 1e18 / anchorPrice);

        // Full close (repay-side exit) needs no price at all. Five hours of stability fee
        // accrued during the warp, so top up the shortfall the way any closer would acquire it.
        uint256 debt = manager.currentDebt(eSPY, alice);
        uint256 balance = eusd.balanceOf(alice);
        if (debt > balance) {
            vm.prank(address(manager));
            eusd.mint(alice, debt - balance);
        }
        vm.prank(alice);
        manager.closePosition(eSPY);
        assertEq(manager.totalDebt(), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  UUPS market against the live registry
    // ──────────────────────────────────────────────────────────

    function test_fork_marketUupsDeployAndUpgrade() public requiresFork {
        // Deploys implementation + proxy and links ForceExecuteLib on the fork.
        OwnMarket market = deployOwnMarket(address(REGISTRY));
        assertEq(address(market.registry()), address(REGISTRY));

        // Upgrade to a fresh implementation via the live-registry ADMIN role.
        OwnMarket newImpl = new OwnMarket();
        vm.prank(admin);
        UUPSUpgradeable(address(market)).upgradeToAndCall(address(newImpl), "");
        assertEq(address(market.registry()), address(REGISTRY), "state lost across upgrade");

        // Unauthorized upgrades stay locked out under the live role wiring.
        vm.expectRevert(IOwnMarket.OnlyAdmin.selector);
        vm.prank(alice);
        UUPSUpgradeable(address(market)).upgradeToAndCall(address(newImpl), "");
    }
}
