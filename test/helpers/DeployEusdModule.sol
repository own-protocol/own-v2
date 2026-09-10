// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";
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

/// @dev Deploy a StakedEUSD under UUPS. The eUSD asset is an implementation-constructor immutable;
///      registry and vesting window are proxy state. Drop-in replacement for the pre-UUPS
///      `new StakedEUSD(registry, eusd, vestingPeriod)` call (same argument list).
function deployStakedEUSD(address registry_, address eusd_, uint256 vestingPeriod_) returns (StakedEUSD) {
    StakedEUSD implementation = new StakedEUSD(eusd_);
    bytes memory initData = abi.encodeCall(StakedEUSD.initialize, (registry_, vestingPeriod_));
    return StakedEUSD(address(new ERC1967Proxy(address(implementation), initData)));
}
