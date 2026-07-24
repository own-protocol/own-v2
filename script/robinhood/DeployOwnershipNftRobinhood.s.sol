// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnershipNFT} from "../../src/tokens/OwnershipNFT.sol";

/// @title DeployOwnershipNftRobinhood — Deploy the soulbound points-program NFT
/// @notice Deploys OwnershipNFT (see docs/points-program.md). Standalone — no registry wiring;
///         the points-service only needs the deployed address via env to enable its minter loop.
///         Admin defaults to the deployer EOA (current PROTOCOL_ADMIN on Robinhood; rotate to the
///         Safe via grantRole/revokeRole after the governance migration). Ends with read-only
///         sanity asserts on roles, URI, and soulbound state.
///
/// Post-deploy checklist:
///   1. Record the address in docs/contracts-robinhood.md.
///   2. Set NFT_ADDRESS + MINTER_KEY in the points-service Railway env (activates the minter
///      loop + backfill for wallets qualifying since launch 2026-07-14).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD
///      POINTS_MINTER_ROBINHOOD          — points-service hot wallet (MINTER_ROLE)
///      NFT_ADMIN_ROBINHOOD (optional)   — DEFAULT_ADMIN_ROLE holder; defaults to deployer EOA
///
/// Usage:
///   forge script script/robinhood/DeployOwnershipNftRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployOwnershipNftRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    string constant NAME = "Ownership NFT";
    string constant SYMBOL = "OwnNFT";

    // Points-service metadata endpoint (docs/points-program.md). tokenURI = BASE_URI + tokenId.
    string constant BASE_URI = "https://points.ownfinance.org/metadata/";
    string constant CONTRACT_URI = "https://points.ownfinance.org/collection.json";

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        address deployer = vm.addr(deployerKey);
        address minter = vm.envAddress("POINTS_MINTER_ROBINHOOD");
        address admin = vm.envOr("NFT_ADMIN_ROBINHOOD", deployer);
        require(minter != admin, "minter must not be the admin (hot wallet is mint-only)");

        vm.startBroadcast(deployerKey);

        OwnershipNFT nft = new OwnershipNFT(NAME, SYMBOL, admin, minter, BASE_URI);
        if (admin == deployer) {
            nft.setContractURI(CONTRACT_URI);
        }

        vm.stopBroadcast();

        // Read-only sanity asserts.
        require(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin), "admin role not set");
        require(nft.hasRole(nft.MINTER_ROLE(), minter), "minter role not set");
        require(!nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), minter), "minter must not hold admin");
        require(!nft.transfersEnabled(), "must deploy soulbound");
        require(nft.nextTokenId() == 1, "ids must start at 1");
        require(keccak256(bytes(nft.baseURI())) == keccak256(bytes(BASE_URI)), "baseURI mismatch");

        console.log("OwnershipNFT:", address(nft));
        console.log("  name / symbol:", nft.name(), "/", nft.symbol());
        console.log("  admin:", admin);
        console.log("  minter (points-service):", minter);
        console.log("  baseURI:", nft.baseURI());
        console.log("  contractURI:", nft.contractURI());
        console.log("");
        console.log("Next: record in docs/contracts-robinhood.md; set NFT_ADDRESS + MINTER_KEY in Railway");
    }
}
