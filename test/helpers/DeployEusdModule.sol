// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDManager} from "../../src/eusd/EUSDManager.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Deploy an EUSDManager the way production does under UUPS: a fresh implementation behind
///      an ERC-1967 proxy, initialized atomically in the proxy constructor. Drop-in replacement
///      for the pre-UUPS `new EUSDManager(registry, eusd, params)` call (same argument list).
function deployEUSDManager(
    address registry_,
    address eusd_,
    IEUSDManager.RiskParams memory params
) returns (EUSDManager) {
    EUSDManager implementation = new EUSDManager();
    bytes memory initData = abi.encodeCall(EUSDManager.initialize, (registry_, eusd_, params));
    return EUSDManager(address(new ERC1967Proxy(address(implementation), initData)));
}
