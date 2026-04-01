// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {IFeeCalculator} from "../../src/interfaces/IFeeCalculator.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @title FeeCalculator Unit Tests
/// @notice Tests fee lookup, admin setters, bounds validation, and volatility
///         level resolution via AssetRegistry.
contract FeeCalculatorTest is BaseTest {
    FeeCalculator public feeCalc;
    AssetRegistry public assetRegistry;

    address public eTSLA = makeAddr("eTSLA");
    address public eGOLD = makeAddr("eGOLD");
    address public eTLT = makeAddr("eTLT");

    function setUp() public override {
        super.setUp();

        // Deploy AssetRegistry and register it in ProtocolRegistry
        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(keccak256("ASSET_REGISTRY"), address(assetRegistry));

        // Deploy FeeCalculator
        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);

        // Register assets with different volatility levels
        assetRegistry.addAsset(
            TSLA,
            eTSLA,
            AssetConfig({
                activeToken: eTSLA,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 3,
                oracleType: 1
            })
        );
        assetRegistry.addAsset(
            GOLD,
            eGOLD,
            AssetConfig({
                activeToken: eGOLD,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 1
            })
        );
        assetRegistry.addAsset(
            TLT,
            eTLT,
            AssetConfig({
                activeToken: eTLT,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: 1
            })
        );

        // Set default fees: low=10bps, medium=20bps, high=30bps for mint
        //                    low=10bps, medium=25bps, high=40bps for redeem
        feeCalc.setMintFee(1, 10);
        feeCalc.setMintFee(2, 20);
        feeCalc.setMintFee(3, 30);
        feeCalc.setRedeemFee(1, 10);
        feeCalc.setRedeemFee(2, 25);
        feeCalc.setRedeemFee(3, 40);
        vm.stopPrank();

        vm.label(address(feeCalc), "FeeCalculator");
        vm.label(address(assetRegistry), "AssetRegistry");
    }

    // ──────────────────────────────────────────────────────────
    //  getMintFee
    // ──────────────────────────────────────────────────────────

    function test_getMintFee_highVolatility_returnsCorrectFee() public view {
        // TSLA has volatilityLevel 3 (high) → 30 bps
        uint256 fee = feeCalc.getMintFee(TSLA, 1000e6);
        assertEq(fee, 30);
    }

    function test_getMintFee_mediumVolatility_returnsCorrectFee() public view {
        // GOLD has volatilityLevel 2 (medium) → 20 bps
        uint256 fee = feeCalc.getMintFee(GOLD, 1000e6);
        assertEq(fee, 20);
    }

    function test_getMintFee_lowVolatility_returnsCorrectFee() public view {
        // TLT has volatilityLevel 1 (low) → 10 bps
        uint256 fee = feeCalc.getMintFee(TLT, 1000e6);
        assertEq(fee, 10);
    }

    function test_getMintFee_amountDoesNotAffectFee() public view {
        // Same asset, different amounts → same fee
        uint256 fee1 = feeCalc.getMintFee(TSLA, 1e6);
        uint256 fee2 = feeCalc.getMintFee(TSLA, 1_000_000e6);
        assertEq(fee1, fee2);
    }

    // ──────────────────────────────────────────────────────────
    //  getRedeemFee
    // ──────────────────────────────────────────────────────────

    function test_getRedeemFee_highVolatility_returnsCorrectFee() public view {
        uint256 fee = feeCalc.getRedeemFee(TSLA, 1e18);
        assertEq(fee, 40);
    }

    function test_getRedeemFee_mediumVolatility_returnsCorrectFee() public view {
        uint256 fee = feeCalc.getRedeemFee(GOLD, 1e18);
        assertEq(fee, 25);
    }

    function test_getRedeemFee_lowVolatility_returnsCorrectFee() public view {
        uint256 fee = feeCalc.getRedeemFee(TLT, 1e18);
        assertEq(fee, 10);
    }

    // ──────────────────────────────────────────────────────────
    //  setMintFee
    // ──────────────────────────────────────────────────────────

    function test_setMintFee_admin_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit IFeeCalculator.MintFeeUpdated(2, 50);

        vm.prank(Actors.ADMIN);
        feeCalc.setMintFee(2, 50);

        assertEq(feeCalc.getMintFee(GOLD, 0), 50);
    }

    function test_setMintFee_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        feeCalc.setMintFee(2, 50);
    }

    function test_setMintFee_invalidVolatilityLevel_zero_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFeeCalculator.InvalidVolatilityLevel.selector, 0));
        feeCalc.setMintFee(0, 10);
    }

    function test_setMintFee_invalidVolatilityLevel_tooHigh_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFeeCalculator.InvalidVolatilityLevel.selector, 4));
        feeCalc.setMintFee(4, 10);
    }

    function test_setMintFee_feeTooHigh_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFeeCalculator.FeeTooHigh.selector, 501, 500));
        feeCalc.setMintFee(1, 501);
    }

    function test_setMintFee_maxFee_succeeds() public {
        vm.prank(Actors.ADMIN);
        feeCalc.setMintFee(1, 500);
        assertEq(feeCalc.getMintFee(TLT, 0), 500);
    }

    function test_setMintFee_zeroFee_succeeds() public {
        vm.prank(Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        assertEq(feeCalc.getMintFee(TLT, 0), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  setRedeemFee
    // ──────────────────────────────────────────────────────────

    function test_setRedeemFee_admin_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit IFeeCalculator.RedeemFeeUpdated(3, 75);

        vm.prank(Actors.ADMIN);
        feeCalc.setRedeemFee(3, 75);

        assertEq(feeCalc.getRedeemFee(TSLA, 0), 75);
    }

    function test_setRedeemFee_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        feeCalc.setRedeemFee(2, 50);
    }

    function test_setRedeemFee_invalidVolatilityLevel_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFeeCalculator.InvalidVolatilityLevel.selector, 0));
        feeCalc.setRedeemFee(0, 10);
    }

    function test_setRedeemFee_feeTooHigh_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFeeCalculator.FeeTooHigh.selector, 501, 500));
        feeCalc.setRedeemFee(2, 501);
    }

    // ──────────────────────────────────────────────────────────
    //  Fee update reflects in lookup
    // ──────────────────────────────────────────────────────────

    function test_feeUpdate_reflectsInLookup() public {
        // Initial: TSLA (level 3) mint fee = 30
        assertEq(feeCalc.getMintFee(TSLA, 0), 30);

        // Update level 3 mint fee to 100
        vm.prank(Actors.ADMIN);
        feeCalc.setMintFee(3, 100);

        // TSLA should now return 100
        assertEq(feeCalc.getMintFee(TSLA, 0), 100);
    }

    function test_volatilityLevelChange_reflectsInFee() public {
        // TSLA starts at level 3 → mint fee 30
        assertEq(feeCalc.getMintFee(TSLA, 0), 30);

        // Change TSLA volatility level to 1 via AssetRegistry
        AssetConfig memory config = AssetConfig({
            activeToken: eTSLA,
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.updateAssetConfig(TSLA, config);

        // Now TSLA should use level 1 fee → 10
        assertEq(feeCalc.getMintFee(TSLA, 0), 10);
    }
}
