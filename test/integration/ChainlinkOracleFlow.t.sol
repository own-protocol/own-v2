// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {ChainlinkOracleVerifier} from "../../src/core/ChainlinkOracleVerifier.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {EToken} from "../../src/tokens/EToken.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAggregatorV3} from "../helpers/MockAggregatorV3.sol";

/// @title ChainlinkOracleFlow — Integration test for the Chainlink oracle migration wiring
/// @notice Mirrors the production migration plan: ChainlinkOracleVerifier replaces the in-house
///         verifier in the registry's INHOUSE_ORACLE slot (assets stay oracleType 1), so
///         VaultManager's permissionless mark pulls resolve prices through the real verifier (not
///         a mock) — the Chainlink leg while the feed is live, the band-limited in-house leg while
///         it is silent.
contract ChainlinkOracleFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    ChainlinkOracleVerifier public clVerifier;
    MockAggregatorV3 public feed;
    EToken public eTSLA;

    uint256 internal constant SIGNER_PK = 0xBEEF;
    address internal signer;

    uint32 constant CL_SILENCE = 900;
    uint32 constant CL_FRESH_WINDOW = 4 hours;
    uint32 constant MAX_ANCHOR_AGE = 5 days;
    uint32 constant INHOUSE_MAX_STALENESS = 1 hours;
    uint16 constant BAND_BPS = 500;

    function setUp() public override {
        super.setUp();
        vm.warp(10_000_000);
        signer = vm.addr(SIGNER_PK);

        feed = new MockAggregatorV3(8);
        feed.setAnswer(380e8, block.timestamp);

        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        // Migration wiring: new verifier replaces the in-house oracle in the INHOUSE_ORACLE slot.
        clVerifier = new ChainlinkOracleVerifier(address(protocolRegistry));
        protocolRegistry.setAddress(keccak256("INHOUSE_ORACLE"), address(clVerifier));
        clVerifier.addSigner(signer);
        clVerifier.setChainlinkConfig(
            TSLA,
            address(feed),
            address(0),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        assetRegistry.addAsset(
            TSLA,
            address(eTSLA),
            AssetConfig({
                activeToken: address(eTSLA),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 1
            })
        );
        vm.stopPrank();

        _deployVaultManager();
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
    }

    function _signPrice(bytes32 asset, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, clVerifier.priceDigest(asset, price, timestamp));
        return abi.encode(price, timestamp, v, r, s);
    }

    function test_pullAssetPrice_resolvesThroughChainlinkLeg() public {
        _pullAssetPrice(TSLA);
        assertEq(vaultManager.assetMark(TSLA), 380e18);
        assertEq(vaultManager.assetMarkUpdatedAt(TSLA), block.timestamp);
    }

    function test_pullAssetPrice_inhouseOverridesSilentFeed() public {
        // Feed goes quiet (e.g. weekend); signer quotes within band; keeper pull picks it up.
        vm.warp(block.timestamp + CL_SILENCE + 1);
        uint256 quoted = 380e18 * 103 / 100;
        clVerifier.updatePrice(TSLA, _signPrice(TSLA, quoted, block.timestamp));

        _pullAssetPrice(TSLA);
        assertEq(vaultManager.assetMark(TSLA), quoted);
    }

    function test_pullAssetPrice_feedRecoveryOverridesInhouse() public {
        vm.warp(block.timestamp + CL_SILENCE + 1);
        clVerifier.updatePrice(TSLA, _signPrice(TSLA, 390e18, block.timestamp));
        _pullAssetPrice(TSLA);
        assertEq(vaultManager.assetMark(TSLA), 390e18);

        // Feed publishes again (Monday open) — Chainlink retakes precedence on the next pull.
        vm.warp(block.timestamp + 60);
        feed.setAnswer(392e8, block.timestamp);
        _pullAssetPrice(TSLA);
        assertEq(vaultManager.assetMark(TSLA), 392e18);
    }
}
