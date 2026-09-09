// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title RedeployMarket3Robinhood — gen-3 OwnMarket (UUPS) deploy + Safe cutover calldata
/// @notice Deploys ForceExecuteLib (auto-linked by forge), the OwnMarket implementation and its
///         ERC-1967 proxy, initialized against the live registry. The market goes live only when
///         the Safe executes the printed `setAddress(MARKET, proxy)` — that one write atomically
///         moves every permission (eToken mint/burn, PSM reserve custody, vault hooks) from the
///         gen-2 market to this proxy; all consumers resolve `registry.market()` dynamically and
///         the gen-2 book is empty (zero orders ever), so nothing migrates.
///
/// @dev Cutover choreography (off-chain): the maker/RFQ quote service must re-point its EIP-712
///      `verifyingContract` to the new proxy at cutover — quotes signed for the old market are
///      invalid on the new one. Deploy first, flip the service with the Safe execution, then
///      smoke-test (TestMintBorrowTslaRobinhood / TestPsmTslaRobinhood round-trips).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD
///
/// Usage (verify separately — the explorer API sits behind Cloudflare bot protection):
///   forge script script/robinhood/RedeployMarket3Robinhood.s.sol --rpc-url robinhood --broadcast
contract RedeployMarket3Robinhood is Script {
    bytes32 constant MARKET_KEY = keccak256("MARKET");

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        address oldMarket = registry.market();
        require(oldMarket != address(0), "no live market");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // Implementation (ForceExecuteLib deployed + linked by forge in this broadcast) behind a
        // proxy, initialized atomically in the proxy constructor.
        OwnMarket impl = new OwnMarket();
        OwnMarket market = OwnMarket(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(OwnMarket.initialize, (address(registry)))))
        );

        // Registry cutover — direct if the deployer holds PROTOCOL_ADMIN, otherwise via the Safe.
        bool needsSafe;
        if (registry.hasRole(0x00, deployer)) {
            registry.setAddress(MARKET_KEY, address(market));
        } else {
            needsSafe = true;
        }

        vm.stopBroadcast();

        require(address(market.registry()) == address(registry), "registry not wired");
        // Bare implementation must be un-initializable (initializer disabled in the constructor).
        (bool ok,) = address(impl).call(abi.encodeCall(OwnMarket.initialize, (address(registry))));
        require(!ok, "implementation left initializable");

        if (needsSafe) {
            console.log("=== Safe call required for cutover ===");
            console.log("target:", address(registry));
            console.log("  setAddress(MARKET, proxy) calldata:");
            console.logBytes(abi.encodeCall(IProtocolRegistry.setAddress, (MARKET_KEY, address(market))));
        }

        console.log("Old market (gen-2):  ", oldMarket);
        console.log("OwnMarket proxy:     ", address(market));
        console.log("OwnMarket impl:      ", address(impl));
    }
}
