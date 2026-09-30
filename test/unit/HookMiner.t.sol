// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HookMiner} from "../../script/funds/HookMiner.sol";
import {FundHook} from "../../src/funds/FundHook.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract CREATE2Deployer {
    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        bytes32 salt = bytes32(data[:32]);
        bytes memory code = data[32:];
        address deployed;
        assembly {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
        return abi.encodePacked(deployed);
    }
}

contract HookMinerTest is FundTestBase {
    function test_minedSaltDeploysHookWithExactFlags() public {
        CREATE2Deployer deployer = new CREATE2Deployer();
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(poolManager, IFundFactory(address(factory)));
        (address mined, bytes32 salt) = HookMiner.find(address(deployer), flags, type(FundHook).creationCode, args);

        (bool ok, bytes memory ret) = address(deployer).call(abi.encodePacked(salt, type(FundHook).creationCode, args));
        assertTrue(ok);
        assertEq(address(bytes20(ret)), mined);
        assertEq(uint160(mined) & Hooks.ALL_HOOK_MASK, flags);
        assertEq(address(FundHook(mined).poolManager()), address(poolManager));
    }
}
