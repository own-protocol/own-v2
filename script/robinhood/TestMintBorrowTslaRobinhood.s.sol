// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {OrderType, Quote} from "../../src/interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestMintBorrowTslaRobinhood — Phase A of the TSLA E2E test (VM key)
/// @notice Broadcast by the VM. Mints $20 of eTSLA via a market order (operator-signed quote,
///         proceeds → operator), then borrows $10 USDG against the eTSLA via the BorrowManager
///         (operator-signed inline price proof). Stop and verify before Phase B (repay + redeem).
///
/// Env: VM_PRIVATE_KEY_ROBINHOOD (broadcast), OPERATOR_PRIVATE_KEY_ROBINHOOD (off-chain signing)
///
/// Usage:
///   forge script script/robinhood/TestMintBorrowTslaRobinhood.s.sol --rpc-url robinhood --broadcast
contract TestMintBorrowTslaRobinhood is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant MARKET = 0xF17Ce62F389B5bAA9C24f448D329E898c8f8dEf7;
    address constant BORROW_MANAGER = 0xa58738135ce8D44E746B04967590A831C7E01bF1;
    address constant ETSLA = 0x82D2F4e0649Fc77C2dF7fcF3b6c7e50a1F2F50f4;
    address constant INHOUSE_ORACLE = 0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055;

    bytes32 constant TSLA = bytes32("TSLA");
    uint256 constant TSLA_PRICE = 331e18; // must equal the mark set in TestSetupTslaRobinhood
    uint256 constant MINT_USDG = 20_000_000; // $20 (6 dec)
    uint256 constant BORROW_USDG = 10_000_000; // $10 (6 dec)

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_ROBINHOOD");
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_ROBINHOOD");
        address vmAddr = vm.addr(vmPk);

        (Quote memory q, bytes memory quoteSig) = _mintQuote(operatorPk, vmAddr);
        bytes memory priceData = _priceProof(operatorPk);

        vm.startBroadcast(vmPk);

        IERC20(USDG).approve(MARKET, MINT_USDG);
        OwnMarket(MARKET).executeOrder(q, quoteSig);
        uint256 etsla = IERC20(ETSLA).balanceOf(vmAddr);

        IERC20(ETSLA).approve(BORROW_MANAGER, etsla);
        IBorrowManager(BORROW_MANAGER).borrow(TSLA, etsla, BORROW_USDG, priceData);

        vm.stopBroadcast();

        console.log("eTSLA minted (1e18):", etsla);
        console.log("VM USDG balance now :", IERC20(USDG).balanceOf(vmAddr));
        console.log("Operator USDG (mint proceeds):", IERC20(USDG).balanceOf(vm.addr(operatorPk)));
    }

    /// @dev Build the market mint quote (orderId 0) and sign it with the operator key.
    function _mintQuote(uint256 operatorPk, address vmAddr) internal returns (Quote memory q, bytes memory sig) {
        q = Quote({
            orderId: 0,
            user: vmAddr,
            asset: TSLA,
            orderType: OrderType.Mint,
            amount: MINT_USDG,
            price: TSLA_PRICE,
            quoteId: block.timestamp,
            expiry: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, OwnMarket(MARKET).quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Build the inline TSLA price proof (abi.encode(price, ts, v, r, s)) signed by the operator.
    function _priceProof(
        uint256 operatorPk
    ) internal returns (bytes memory priceData) {
        uint256 ts = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(operatorPk, OracleVerifier(INHOUSE_ORACLE).priceDigest(TSLA, TSLA_PRICE, ts));
        priceData = abi.encode(TSLA_PRICE, ts, v, r, s);
    }
}
