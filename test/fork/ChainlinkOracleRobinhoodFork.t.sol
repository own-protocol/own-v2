// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainlinkOracleVerifier} from "../../src/core/ChainlinkOracleVerifier.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {Test} from "forge-std/Test.sol";

interface IAggV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IUiMult {
    function uiMultiplier() external view returns (uint256);
}

/// @title ChainlinkOracleRobinhoodFork — Fork tests against live Chainlink feeds on Robinhood Chain
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Verifies ChainlinkOracleVerifier against the real
///         RHTSLA / USD feed, the real TSLA Gen-2 token's uiMultiplier, and the real USDG / USD feed:
///         decimal normalization, multiplier division, in-house gating vs the live anchor, and the
///         Chainlink-disabled (band = 0) path.
contract ChainlinkOracleRobinhoodForkTest is Test {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    // docs/chainlink-feeds-robinhood.md
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant TSLA_TOKEN = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    bytes32 constant TSLA = bytes32("TSLA");
    bytes32 constant RTSLA = bytes32("rTSLA");
    bytes32 constant USDG = bytes32("USDG");

    uint32 constant CL_SILENCE = 900;
    uint32 constant CL_FRESH_WINDOW = 4 hours;
    uint32 constant MAX_ANCHOR_AGE = 5 days;
    uint32 constant INHOUSE_MAX_STALENESS = 1 hours;
    uint16 constant BAND_BPS = 500;

    address public admin = makeAddr("admin");
    ChainlinkOracleVerifier public verifier;

    uint256 internal signerPk;
    address internal signer;

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

        (signer, signerPk) = makeAddrAndKey("forkSigner");

        vm.startPrank(admin);
        ProtocolRegistry registry = new ProtocolRegistry(admin, 2 days, 2 minutes);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);

        verifier = new ChainlinkOracleVerifier(address(registry));
        verifier.addSigner(signer);
        // Underlying ticker: divide by the token's live uiMultiplier.
        verifier.setChainlinkConfig(
            TSLA, TSLA_FEED, TSLA_TOKEN, CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, INHOUSE_MAX_STALENESS, BAND_BPS
        );
        // Wrapper ticker: feed as-is.
        verifier.setChainlinkConfig(
            RTSLA, TSLA_FEED, address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, INHOUSE_MAX_STALENESS, BAND_BPS
        );
        // USDG: 24/7 feed, in-house disabled.
        verifier.setChainlinkConfig(USDG, USDG_FEED, address(0), CL_SILENCE, 25 hours, 26 hours, 0, 0);
        vm.stopPrank();
    }

    /// @dev Live feed answer normalized to 18 decimals.
    function _liveFeed18(
        address feedAddr
    ) internal view returns (uint256 price18, uint256 updatedAt) {
        (, int256 answer,, uint256 updated,) = IAggV3(feedAddr).latestRoundData();
        return (uint256(answer) * 10 ** (18 - IAggV3(feedAddr).decimals()), updated);
    }

    function _signPrice(bytes32 asset, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, verifier.priceDigest(asset, price, timestamp));
        return abi.encode(price, timestamp, v, r, s);
    }

    function test_fork_wrapperTicker_matchesRawFeed() public requiresFork {
        (uint256 expected,) = _liveFeed18(TSLA_FEED);
        (uint256 price,) = verifier.getPrice(RTSLA);
        assertEq(price, expected);
        assertGt(price, 1e18); // sanity: a share token is worth more than $1
    }

    function test_fork_underlyingTicker_dividesByLiveMultiplier() public requiresFork {
        (uint256 feedPrice,) = _liveFeed18(TSLA_FEED);
        uint256 mult = IUiMult(TSLA_TOKEN).uiMultiplier();
        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, feedPrice * 1e18 / mult);
    }

    function test_fork_timestampSemantics_matchLiveAge() public requiresFork {
        (, uint256 updated) = _liveFeed18(TSLA_FEED);
        uint256 age = block.timestamp - updated;
        vm.assume(age <= MAX_ANCHOR_AGE); // live feed dead beyond anchor age would invalidate the test
        (, uint256 ts) = verifier.getPrice(RTSLA);
        assertEq(ts, age <= CL_FRESH_WINDOW ? block.timestamp : updated);
    }

    function test_fork_inhousePush_gatedByLiveAnchor() public requiresFork {
        (uint256 anchor, uint256 updated) = _liveFeed18(TSLA_FEED);
        uint256 mult = IUiMult(TSLA_TOKEN).uiMultiplier();
        uint256 adjAnchor = anchor * 1e18 / mult;

        // Force feed silence past the gate (warp is local to the fork).
        if (block.timestamp - updated <= CL_SILENCE) {
            vm.warp(updated + CL_SILENCE + 1);
        }

        // Out-of-band push rejected against the live anchor.
        uint256 bad = adjAnchor * (10_000 + BAND_BPS + 100) / 10_000;
        bytes memory badData = _signPrice(TSLA, bad, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.PriceDeviationExceeded.selector, TSLA, bad, adjAnchor, uint256(BAND_BPS)
            )
        );
        verifier.updatePrice(TSLA, badData);

        // Within-band push accepted and served.
        uint256 good = adjAnchor * (10_000 + BAND_BPS / 2) / 10_000;
        verifier.updatePrice(TSLA, _signPrice(TSLA, good, block.timestamp));
        (uint256 price, uint256 ts) = verifier.getPrice(TSLA);
        assertEq(price, good);
        assertEq(ts, block.timestamp);
    }

    function test_fork_usdg_chainlinkOnly() public requiresFork {
        (uint256 expected, uint256 updated) = _liveFeed18(USDG_FEED);
        (uint256 price,) = verifier.getPrice(USDG);
        assertEq(price, expected);
        assertApproxEqRel(price, 1e18, 0.02e18); // a stablecoin near $1

        // In-house pushes always rejected for USDG.
        vm.warp(updated + 25 hours + 1);
        bytes memory data = _signPrice(USDG, 1e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleVerifier.InhouseDisabled.selector, USDG));
        verifier.updatePrice(USDG, data);
    }
}
