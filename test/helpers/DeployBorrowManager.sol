// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Deploy a BorrowManager the way production does under UUPS: a fresh implementation behind
///      an ERC-1967 proxy, initialized atomically in the proxy constructor. Drop-in replacement
///      for the pre-UUPS `new BorrowManager(...)` call (same argument list).
function deployBorrowManager(
    address vault_,
    address stablecoin_,
    address debtToken_,
    address aavePool_,
    address registry_,
    uint256 targetLtvBps_,
    InterestRateModel.Params memory rateParams_
) returns (BorrowManager) {
    BorrowManager implementation = new BorrowManager();
    bytes memory initData = abi.encodeCall(
        BorrowManager.initialize, (vault_, stablecoin_, debtToken_, aavePool_, registry_, targetLtvBps_, rateParams_)
    );
    return BorrowManager(address(new ERC1967Proxy(address(implementation), initData)));
}
