// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {OrderType, Quote} from "../../src/interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestRepayRedeemGoogMainnet — Phase B: full repay + redeem (closes the GOOG E2E test)
/// @notice Operator approves the market (maker pays the redeem); VM full-repays the GOOG borrow
///         (releases all collateral), refreshes the GOOG mark, then redeems the full eGOOG back to
///         USDC (paid from the operator's mint proceeds). Leaves zero debt and zero eGOOG supply.
///
/// Env: VM_PRIVATE_KEY_MAINNET (broadcast), OPERATOR_PRIVATE_KEY_MAINNET (broadcast + signing)
///
/// Usage:
///   forge script script/mainnet/TestRepayRedeemGoogMainnet.s.sol --rpc-url base --broadcast
contract TestRepayRedeemGoogMainnet is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MARKET = 0x736e913a1eD16994b3f9d2BE17Cc57564188f781;
    address constant BORROW_MANAGER = 0xfc9BBa82bC0cc8E9B5A1847847A2F89D5458443f;
    address constant EGOOG = 0x46E9257BD72012F7814Ae67D95095342d5439C7A;
    address constant INHOUSE_ORACLE = 0xc82f5835Fe132D34A7491961e2875941CF37aE03;
    address constant VAULT_MANAGER = 0x4A3c284f3293250C84899A220Cf4Cb6dFCd317ba;

    bytes32 constant GOOG = bytes32("GOOG");
    uint256 constant GOOG_PRICE = 340e18; // must equal the live mark
    uint256 constant REDEEM_EGOOG = 58_823_529_411_764_705; // full position (free + released collateral)
    uint256 constant REPAY_APPROVE = 6_000_000; // $6 cap; repay pulls only the current debt
    uint256 constant PAYOUT_APPROVE = 20_000_000; // operator approves market for the redeem payout

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_MAINNET");
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY_MAINNET");
        address vmAddr = vm.addr(vmPk);

        (Quote memory rq, bytes memory rqSig) = _redeemQuote(operatorPk, vmAddr);
        bytes memory freshPrice = _priceProof(operatorPk);

        // 1. Operator (maker) approves the market to pull the redeem payout.
        vm.startBroadcast(operatorPk);
        IERC20(USDC).approve(MARKET, PAYOUT_APPROVE);
        vm.stopBroadcast();

        // 2. VM: full repay -> refresh mark -> redeem.
        vm.startBroadcast(vmPk);
        IERC20(USDC).approve(BORROW_MANAGER, REPAY_APPROVE);
        IBorrowManager(BORROW_MANAGER).repay(GOOG, type(uint256).max);
        OracleVerifier(INHOUSE_ORACLE).updatePrice(GOOG, freshPrice);
        VaultManager(VAULT_MANAGER).pullAssetPrice(GOOG);
        OwnMarket(MARKET).executeOrder(rq, rqSig);
        vm.stopBroadcast();

        console.log("VM debt after (6dec):", IBorrowManager(BORROW_MANAGER).debtOf(vmAddr, GOOG));
        console.log("VM eGOOG after (1e18):", IERC20(EGOOG).balanceOf(vmAddr));
        console.log("eGOOG totalSupply after:", IERC20(EGOOG).totalSupply());
        console.log("VM USDC after (6dec):", IERC20(USDC).balanceOf(vmAddr));
        console.log("Operator USDC after (6dec):", IERC20(USDC).balanceOf(vm.addr(operatorPk)));
    }

    /// @dev Build the market redeem quote (orderId 0, eGOOG in) and sign with the operator key.
    function _redeemQuote(uint256 operatorPk, address vmAddr) internal returns (Quote memory q, bytes memory sig) {
        q = Quote({
            orderId: 0,
            user: vmAddr,
            asset: GOOG,
            orderType: OrderType.Redeem,
            amount: REDEEM_EGOOG,
            price: GOOG_PRICE,
            quoteId: block.timestamp,
            expiry: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, OwnMarket(MARKET).quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Fresh operator-signed GOOG price attestation for the mark refresh.
    function _priceProof(
        uint256 operatorPk
    ) internal returns (bytes memory priceData) {
        uint256 ts = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(operatorPk, OracleVerifier(INHOUSE_ORACLE).priceDigest(GOOG, GOOG_PRICE, ts));
        priceData = abi.encode(GOOG_PRICE, ts, v, r, s);
    }
}
