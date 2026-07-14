// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {OrderType, Quote} from "../../src/interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestRepayRedeemTslaRobinhood — Phase B: full repay + redeem (closes the TSLA E2E test)
/// @notice Operator approves the market (maker pays the redeem); VM full-repays the TSLA borrow
///         (releases all collateral), refreshes the TSLA mark, then redeems the full eTSLA back to
///         USDG (paid from the operator's mint proceeds). Leaves zero debt and zero eTSLA supply.
///
/// Env: VM_PRIVATE_KEY_ROBINHOOD (broadcast), OPERATOR_PRIVATE_KEY_ROBINHOOD (broadcast + signing)
///
/// Usage:
///   forge script script/robinhood/TestRepayRedeemTslaRobinhood.s.sol --rpc-url robinhood --broadcast
contract TestRepayRedeemTslaRobinhood is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant MARKET = 0xF17Ce62F389B5bAA9C24f448D329E898c8f8dEf7;
    address constant BORROW_MANAGER = 0xa58738135ce8D44E746B04967590A831C7E01bF1;
    address constant ETSLA = 0x82D2F4e0649Fc77C2dF7fcF3b6c7e50a1F2F50f4;
    address constant INHOUSE_ORACLE = 0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055;
    address constant VAULT_MANAGER = 0xfA2981bA6F5E955f3FF4c9DBd9a79Ff29015d352;

    bytes32 constant TSLA = bytes32("TSLA");
    uint256 constant TSLA_PRICE = 331e18; // must equal the live mark
    uint256 constant REPAY_APPROVE = 11_000_000; // $11 cap; repay pulls only the current debt
    uint256 constant PAYOUT_APPROVE = 25_000_000; // operator approves market for the redeem payout

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_ROBINHOOD");
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_ROBINHOOD");
        address vmAddr = vm.addr(vmPk);

        bytes memory freshPrice = _priceProof(operatorPk);

        // 1. Operator (maker) approves the market to pull the redeem payout.
        vm.startBroadcast(operatorPk);
        IERC20(USDG).approve(MARKET, PAYOUT_APPROVE);
        vm.stopBroadcast();

        // 2. VM: full repay -> refresh mark -> redeem the full post-repay eTSLA balance.
        vm.startBroadcast(vmPk);
        IERC20(USDG).approve(BORROW_MANAGER, REPAY_APPROVE);
        IBorrowManager(BORROW_MANAGER).repay(TSLA, type(uint256).max);
        OracleVerifier(INHOUSE_ORACLE).updatePrice(TSLA, freshPrice);
        VaultManager(VAULT_MANAGER).pullAssetPrice(TSLA);

        // Balance now includes the collateral released by the repay (simulation is sequential).
        uint256 etsla = IERC20(ETSLA).balanceOf(vmAddr);
        (Quote memory rq, bytes memory rqSig) = _redeemQuote(operatorPk, vmAddr, etsla);
        OwnMarket(MARKET).executeOrder(rq, rqSig);
        vm.stopBroadcast();

        console.log("VM debt after (6dec):", IBorrowManager(BORROW_MANAGER).debtOf(vmAddr, TSLA));
        console.log("VM eTSLA after (1e18):", IERC20(ETSLA).balanceOf(vmAddr));
        console.log("eTSLA totalSupply after:", IERC20(ETSLA).totalSupply());
        console.log("VM USDG after (6dec):", IERC20(USDG).balanceOf(vmAddr));
        console.log("Operator USDG after (6dec):", IERC20(USDG).balanceOf(vm.addr(operatorPk)));
    }

    /// @dev Build the market redeem quote (orderId 0, eTSLA in) and sign with the operator key.
    function _redeemQuote(
        uint256 operatorPk,
        address vmAddr,
        uint256 etslaAmount
    ) internal returns (Quote memory q, bytes memory sig) {
        q = Quote({
            orderId: 0,
            user: vmAddr,
            asset: TSLA,
            orderType: OrderType.Redeem,
            amount: etslaAmount,
            price: TSLA_PRICE,
            quoteId: block.timestamp,
            expiry: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, OwnMarket(MARKET).quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Fresh operator-signed TSLA price attestation for the mark refresh.
    function _priceProof(
        uint256 operatorPk
    ) internal returns (bytes memory priceData) {
        uint256 ts = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(operatorPk, OracleVerifier(INHOUSE_ORACLE).priceDigest(TSLA, TSLA_PRICE, ts));
        priceData = abi.encode(TSLA_PRICE, ts, v, r, s);
    }
}
