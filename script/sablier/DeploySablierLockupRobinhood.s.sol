// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin-v5.3.0/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SablierComptroller} from "@sablier/evm-utils/src/SablierComptroller.sol";
import {ISablierComptroller} from "@sablier/evm-utils/src/interfaces/ISablierComptroller.sol";
import {LockupNFTDescriptor} from "@sablier/lockup/src/LockupNFTDescriptor.sol";
import {SablierLockup} from "@sablier/lockup/src/SablierLockup.sol";

/// @title DeploySablierLockupRobinhood — Self-hosted Sablier Lockup v4.0.1 on Robinhood Chain
/// @notice Sablier has no Robinhood Chain (4663) deployment, so this deploys the unmodified,
///         Cantina-audited Sablier Lockup v4.0.1 sources vendored under lib/sablier-evm-monorepo:
///           1. SablierComptroller (UUPS implementation + ERC-1967 proxy, initialised atomically in
///              the proxy constructor so nobody can front-run `initialize`). All protocol fees are
///              set to 0 and no price oracle is configured, so withdrawals are free forever unless
///              the admin later opts in.
///           2. LockupNFTDescriptor (on-chain SVG metadata for the stream NFTs).
///           3. SablierLockup (the singleton that holds every stream).
///         Streams are then created by script/sablier/CreateTeamVestingRobinhood.s.sol.
///
/// @dev The comptroller admin is the protocol's only privileged role: it can upgrade the
///      comptroller, set fees, swap the NFT descriptor and sweep *surplus* tokens (never stream
///      deposits) from the Lockup. Point it at the Safe once governance has migrated.
///
/// @dev Post-deploy checklist:
///        1. Record the three addresses in docs/contracts-robinhood.md.
///        2. Verify on Blockscout: `lockup.comptroller()` is the proxy, `comptroller.admin()` is the
///           intended admin, `comptroller.getMinFeeUSD(Lockup) == 0`, `comptroller.oracle() == 0`.
///        3. Export SABLIER_LOCKUP_ROBINHOOD=<lockup> and run CreateTeamVestingRobinhood.s.sol.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD
///      SABLIER_ADMIN_ROBINHOOD (optional) — comptroller admin; defaults to the deployer EOA
///
/// Usage:
///   FOUNDRY_PROFILE=sablier forge script script/sablier/DeploySablierLockupRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeploySablierLockupRobinhood is Script {
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;

    /// @notice Addresses created by the last `run()` (readable by tests and ops tooling).
    SablierComptroller public comptrollerImpl;
    SablierComptroller public comptroller;
    LockupNFTDescriptor public nftDescriptor;
    SablierLockup public lockup;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        runWith(deployerKey, vm.envOr("SABLIER_ADMIN_ROBINHOOD", vm.addr(deployerKey)));
    }

    /// @notice Deploys the protocol from `deployerKey` with `admin` as the comptroller admin.
    function runWith(
        uint256 deployerKey,
        address admin
    ) public {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        require(admin != address(0), "admin is zero");

        vm.startBroadcast(deployerKey);

        // 1. Comptroller: implementation (initialisers disabled) behind a proxy that is initialised
        //    in the same transaction. No fees, no oracle.
        comptrollerImpl = new SablierComptroller(admin);
        comptroller = SablierComptroller(
            payable(address(
                    new ERC1967Proxy(
                        address(comptrollerImpl),
                        abi.encodeCall(SablierComptroller.initialize, (admin, 0, 0, 0, 0, address(0)))
                    )
                ))
        );

        // 2. NFT descriptor, 3. Lockup singleton.
        nftDescriptor = new LockupNFTDescriptor();
        lockup = new SablierLockup(address(comptroller), address(nftDescriptor));

        vm.stopBroadcast();

        // Read-only sanity asserts.
        require(comptroller.admin() == admin, "comptroller admin mismatch");
        require(comptroller.oracle() == address(0), "oracle must be unset");
        require(comptroller.getMinFeeUSD(ISablierComptroller.Protocol.Lockup) == 0, "lockup fee must be 0");
        require(comptroller.calculateMinFeeWei(ISablierComptroller.Protocol.Lockup) == 0, "lockup fee wei must be 0");
        require(address(lockup.comptroller()) == address(comptroller), "lockup comptroller mismatch");
        require(address(lockup.nftDescriptor()) == address(nftDescriptor), "lockup descriptor mismatch");
        require(lockup.nextStreamId() == 1, "stream ids must start at 1");

        console.log("SablierComptroller (proxy): ", address(comptroller));
        console.log("SablierComptroller (impl):  ", address(comptrollerImpl));
        console.log("LockupNFTDescriptor:        ", address(nftDescriptor));
        console.log("SablierLockup:              ", address(lockup));
        console.log("Admin:                      ", admin);
    }
}
