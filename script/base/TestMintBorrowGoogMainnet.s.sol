// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {OrderType, Quote} from "../../src/interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestMintBorrowGoogMainnet — Phase A of the GOOG E2E test (VM key)
/// @notice Broadcast by the VM. Mints $20 of eGOOG via a market order (operator-signed quote, proceeds
///         → operator), then borrows $10 USDC against the eGOOG via the BorrowManager (operator-signed
///         inline price proof). Stop here and verify manually before Phase B (repay + redeem).
///
/// Env: VM_PRIVATE_KEY_MAINNET (broadcast), OPERATOR_PRIVATE_KEY_MAINNET (off-chain signing)
///
/// Usage:
///   forge script script/mainnet/TestMintBorrowGoogMainnet.s.sol --rpc-url base --broadcast
contract TestMintBorrowGoogMainnet is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MARKET = 0x736e913a1eD16994b3f9d2BE17Cc57564188f781;
    address constant BORROW_MANAGER = 0xfc9BBa82bC0cc8E9B5A1847847A2F89D5458443f;
    address constant EGOOG = 0x46E9257BD72012F7814Ae67D95095342d5439C7A;
    address constant INHOUSE_ORACLE = 0xc82f5835Fe132D34A7491961e2875941CF37aE03;

    bytes32 constant GOOG = bytes32("GOOG");
    uint256 constant GOOG_PRICE = 340e18; // must equal the mark set in TestSetupGoogMainnet
    uint256 constant MINT_USDC = 20_000_000; // $20 (6 dec)
    uint256 constant BORROW_USDC = 10_000_000; // $10 (6 dec)

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_MAINNET");
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_MAINNET");
        address vmAddr = vm.addr(vmPk);

        (Quote memory q, bytes memory quoteSig) = _mintQuote(operatorPk, vmAddr);
        bytes memory priceData = _priceProof(operatorPk);

        vm.startBroadcast(vmPk);

        IERC20(USDC).approve(MARKET, MINT_USDC);
        OwnMarket(MARKET).executeOrder(q, quoteSig);
        uint256 egoog = IERC20(EGOOG).balanceOf(vmAddr);

        IERC20(EGOOG).approve(BORROW_MANAGER, egoog);
        IBorrowManager(BORROW_MANAGER).borrow(GOOG, egoog, BORROW_USDC, priceData);

        vm.stopBroadcast();

        console.log("eGOOG minted (1e18):", egoog);
        console.log("VM USDC balance now :", IERC20(USDC).balanceOf(vmAddr));
        console.log("Operator USDC (mint proceeds):", IERC20(USDC).balanceOf(vm.addr(operatorPk)));
    }

    /// @dev Build the market mint quote (orderId 0) and sign it with the operator key.
    function _mintQuote(uint256 operatorPk, address vmAddr) internal returns (Quote memory q, bytes memory sig) {
        q = Quote({
            orderId: 0,
            user: vmAddr,
            asset: GOOG,
            orderType: OrderType.Mint,
            amount: MINT_USDC,
            price: GOOG_PRICE,
            quoteId: block.timestamp,
            expiry: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, OwnMarket(MARKET).quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Build the inline GOOG price proof (abi.encode(price, ts, v, r, s)) signed by the operator.
    function _priceProof(
        uint256 operatorPk
    ) internal returns (bytes memory priceData) {
        uint256 ts = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(operatorPk, OracleVerifier(INHOUSE_ORACLE).priceDigest(GOOG, GOOG_PRICE, ts));
        priceData = abi.encode(GOOG_PRICE, ts, v, r, s);
    }
}
