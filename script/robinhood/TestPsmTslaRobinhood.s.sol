// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestPsmTslaRobinhood — PSM smoke test: wrapper round-trip (VM key)
/// @notice Broadcast by the VM (holds Gen-2 TSLA). Attests fresh TSLA + R.TSLA marks (operator
///         signs; both at the same price so the PSM ratio is exactly 1.0), refreshes the asset
///         mark, then psmMints 0.05 Gen-2 TSLA → eTSLA and psmRedeems the full eTSLA straight
///         back. Round-trip should return the wrapper minus at most 1 wei of rounding dust and
///         leave zero eTSLA supply. First PSM op also arms the ratio-jump guard's baseline.
///
/// Env: VM_PRIVATE_KEY_ROBINHOOD (broadcast), OPERATOR_PRIVATE_KEY_ROBINHOOD (off-chain signing)
///
/// Usage:
///   forge script script/robinhood/TestPsmTslaRobinhood.s.sol --rpc-url robinhood --broadcast
contract TestPsmTslaRobinhood is Script {
    address constant MARKET = 0xF17Ce62F389B5bAA9C24f448D329E898c8f8dEf7;
    address constant ETSLA = 0x82D2F4e0649Fc77C2dF7fcF3b6c7e50a1F2F50f4;
    address constant INHOUSE_ORACLE = 0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055;
    address constant VAULT_MANAGER = 0xfA2981bA6F5E955f3FF4c9DBd9a79Ff29015d352;
    address constant WRAPPER = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d; // Gen-2 TSLA
    address constant RESERVE = 0xD3331E0D2b8D5D82932E2A9f4B98b1F2bDC11a39;

    bytes32 constant TSLA = bytes32("TSLA");
    bytes32 constant RTSLA = bytes32("R.TSLA");
    uint256 constant PRICE = 331e18; // same for both legs -> ratio 1.0 (uiMultiplier is 1.0)
    uint256 constant WRAPPER_IN = 0.05e18; // ~$16.55 of Gen-2 TSLA

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_ROBINHOOD");
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_ROBINHOOD");
        address vmAddr = vm.addr(vmPk);

        bytes memory tslaPrice = _priceProof(operatorPk, TSLA);
        bytes memory rtslaPrice = _priceProof(operatorPk, RTSLA);

        uint256 wrapperBefore = IERC20(WRAPPER).balanceOf(vmAddr);

        // One-time admin fix on the live deploy: R.TSLA was registered without an oracle config
        // (gap in the original DeployPsmRobinhood, since patched). Idempotent overwrite.
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        OracleVerifier(INHOUSE_ORACLE).setAssetOracleConfig(RTSLA, 3600, 2000);
        vm.stopBroadcast();

        vm.startBroadcast(vmPk);

        // Fresh marks: asset leg (exposure gate) + wrapper leg (psmMint requires fresh).
        OracleVerifier(INHOUSE_ORACLE).updatePrice(TSLA, tslaPrice);
        VaultManager(VAULT_MANAGER).pullAssetPrice(TSLA);
        OracleVerifier(INHOUSE_ORACLE).updatePrice(RTSLA, rtslaPrice);

        // Mint: wrapper -> reserve custody, eTSLA out at ratio 1.0.
        IERC20(WRAPPER).approve(MARKET, WRAPPER_IN);
        uint256 etslaOut = OwnMarket(MARKET).psmMint(TSLA, WRAPPER, WRAPPER_IN);

        // Redeem the full eTSLA straight back: burn -> reserve releases wrapper.
        uint256 wrapperOut = OwnMarket(MARKET).psmRedeem(TSLA, WRAPPER, etslaOut);

        vm.stopBroadcast();

        console.log("Wrapper in (1e18):", WRAPPER_IN);
        console.log("eTSLA minted (1e18):", etslaOut);
        console.log("Wrapper returned (1e18):", wrapperOut);
        console.log("VM wrapper delta (dust):", wrapperBefore - IERC20(WRAPPER).balanceOf(vmAddr));
        console.log("Reserve wrapper left:", IERC20(WRAPPER).balanceOf(RESERVE));
        console.log("eTSLA totalSupply after:", IERC20(ETSLA).totalSupply());
    }

    /// @dev Operator-signed price attestation for `ticker` at PRICE.
    function _priceProof(uint256 operatorPk, bytes32 ticker) internal returns (bytes memory priceData) {
        uint256 ts = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(operatorPk, OracleVerifier(INHOUSE_ORACLE).priceDigest(ticker, PRICE, ts));
        priceData = abi.encode(PRICE, ts, v, r, s);
    }
}
