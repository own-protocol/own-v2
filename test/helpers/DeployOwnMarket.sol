// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Deploy an OwnMarket the way production does under UUPS: a fresh implementation behind an
///      ERC-1967 proxy, initialized atomically in the proxy constructor. Drop-in replacement for
///      the pre-UUPS `new OwnMarket(registry)` call (same argument list).
function deployOwnMarket(
    address registry_
) returns (OwnMarket) {
    OwnMarket implementation = new OwnMarket();
    bytes memory initData = abi.encodeCall(OwnMarket.initialize, (registry_));
    return OwnMarket(address(new ERC1967Proxy(address(implementation), initData)));
}
