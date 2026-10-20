// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CcipWrapRouter} from "../../src/bridge/CcipWrapRouter.sol";
import {Ccip, CcipWrapperSetup} from "./CcipWrapperSetup.sol";
import {Script, console} from "forge-std/Script.sol";

/// @title SetupCcipWrapper — deploy and register rZEC or rHYPE on Base and Robinhood Chain
/// @notice Runs the steps in {CcipWrapperSetup} one chain at a time, from the same deployer key (Chainlink's
///         factory salts addresses by sender). `key` is "ZEC" or "HYPE".
///
/// Env: DEPLOYER_PRIVATE_KEY (same key on both chains); RL_CAPACITY and RL_RATE for steps 2 and 3: the CCIP rate
///      limit each way, in raw token units (capacity = largest burst, rate = refill per second; start small).
///
/// Usage (bytecode first: tools/fetch-ccip-bytecode.sh):
///   1. forge script script/ccip/SetupCcipWrapper.s.sol --rpc-url base --broadcast --verify \
///        --sig "base(string)" ZEC
///      On mainnet, where forge can't simulate cbZEC / cbHYPE, deploy the wrapper with `cast send --create`
///      instead and run --sig "basePool(string,address)" ZEC <wrapper>.
///   2. forge script script/ccip/SetupCcipWrapper.s.sol --rpc-url robinhood --broadcast \
///        --sig "robinhood(string,address,address)" ZEC <baseWrapper> <basePool>
///   3. forge script script/ccip/SetupCcipWrapper.s.sol --rpc-url base --broadcast \
///        --sig "linkBase(address,address,address)" <basePool> <rhToken> <rhPool>
///   Once per platform (Base): --sig "deployWrapRouter()"
///   After the live test: --sig "handOffBase(address,address,address)" and
///   --sig "handOffRobinhood(address,address,address)" to the Safe, which then accepts on each contract.
contract SetupCcipWrapper is Script, CcipWrapperSetup {
    /// @notice Step 1 on Base.
    /// @param key "ZEC" or "HYPE".
    function base(
        string calldata key
    ) external {
        WrapperSpec memory s = _spec(key);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        (address wrapper, address pool, address lockBox) = _setupBase(s, vm.addr(pk));
        vm.stopBroadcast();
        console.log("wrapper", wrapper);
        console.log("pool", pool);
        console.log("lockBox", lockBox);
    }

    /// @notice Step 1 on Base for a wrapper already deployed by a plain transaction (mainnet: forge can't simulate
    ///         the wrapper's constructor, which reads cbZEC / cbHYPE decimals). Deploy it first with
    ///         `cast send --create` and constructor (underlying, name, symbol, deployer) from {_spec}.
    /// @param key     "ZEC" or "HYPE".
    /// @param wrapper The deployed wrapper.
    function basePool(string calldata key, address wrapper) external {
        WrapperSpec memory s = _spec(key);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        (address pool, address lockBox) = _setupBasePool(s, wrapper, vm.addr(pk));
        vm.stopBroadcast();
        console.log("pool", pool);
        console.log("lockBox", lockBox);
    }

    /// @notice Step 2 on Robinhood Chain.
    /// @param key         "ZEC" or "HYPE".
    /// @param baseWrapper The wrapper from step 1.
    /// @param basePool    The Base pool from step 1.
    function robinhood(string calldata key, address baseWrapper, address basePool) external {
        WrapperSpec memory s = _spec(key);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        (address token, address pool) = _setupRobinhood(s, vm.addr(pk), baseWrapper, basePool, _limit());
        vm.stopBroadcast();
        console.log("token", token);
        console.log("pool", pool);
    }

    /// @notice Step 3 on Base.
    /// @param basePool The Base pool.
    /// @param rhToken  The Robinhood token from step 2.
    /// @param rhPool   The Robinhood pool from step 2.
    function linkBase(address basePool, address rhToken, address rhPool) external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _linkBase(basePool, rhToken, rhPool, _limit());
        vm.stopBroadcast();
    }

    /// @notice The wrap-and-send router on Base (one for every wrapper).
    function deployWrapRouter() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address r = address(new CcipWrapRouter(BASE_ROUTER, RH_SELECTOR));
        vm.stopBroadcast();
        console.log("wrapRouter", r);
    }

    /// @notice Step 4 on Base.
    /// @param wrapper The wrapper.
    /// @param pool    The Base pool.
    /// @param owner   The Safe.
    function handOffBase(address wrapper, address pool, address owner) external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _handOffBase(wrapper, pool, owner);
        vm.stopBroadcast();
    }

    /// @notice Step 4 on Robinhood Chain.
    /// @param token The Robinhood token.
    /// @param pool  The Robinhood pool.
    /// @param owner The Safe.
    function handOffRobinhood(address token, address pool, address owner) external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _handOffRobinhood(token, pool, owner);
        vm.stopBroadcast();
    }

    function _limit() internal view returns (Ccip.RateLimitConfig memory) {
        return Ccip.RateLimitConfig({
            isEnabled: true,
            capacity: uint128(vm.envUint("RL_CAPACITY")),
            rate: uint128(vm.envUint("RL_RATE"))
        });
    }
}
