// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TransferAssetOwnership — Transfer AssetRegistry, ETokenFactory & OracleVerifier ownership
/// @notice Run by current admin (deployer) to transfer ownership of asset-related contracts
///         to the Asset Manager wallet (Turnkey-controlled).
///
/// Usage:
///   forge script script/TransferAssetOwnership.s.sol --rpc-url base_sepolia --broadcast
contract TransferAssetOwnership is Script {
    address constant NEW_OWNER = 0xd4729278Ad47413d796d78710DC3478BCD7BBCD1;

    address constant ASSET_REGISTRY = 0xe3D6a1F1D91d5B98F35a97D53126b1D5Ff81Cdab;
    address constant ETOKEN_FACTORY = 0x0d74D76274Aa2DF716A6bDDDE610656c6228fA60;
    address constant ORACLE_VERIFIER = 0x79Fa388ddB371f36D4394128647F67A43c57f6ac;

    function run() external {
        console.log("=== Transfer Asset Ownership ===");
        console.log("New owner:", NEW_OWNER);
        console.log("");

        console.log("AssetRegistry current owner:", Ownable(ASSET_REGISTRY).owner());
        console.log("ETokenFactory current owner:", Ownable(ETOKEN_FACTORY).owner());
        console.log("OracleVerifier current owner:", Ownable(ORACLE_VERIFIER).owner());

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        Ownable(ASSET_REGISTRY).transferOwnership(NEW_OWNER);
        Ownable(ETOKEN_FACTORY).transferOwnership(NEW_OWNER);
        Ownable(ORACLE_VERIFIER).transferOwnership(NEW_OWNER);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Ownership Transferred ===");
        console.log("AssetRegistry new owner:", Ownable(ASSET_REGISTRY).owner());
        console.log("ETokenFactory new owner:", Ownable(ETOKEN_FACTORY).owner());
        console.log("OracleVerifier new owner:", Ownable(ORACLE_VERIFIER).owner());
    }
}
