// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {BaseGateway} from "../../src/bridge/BaseGateway.sol";
import {FundExitGateway} from "../../src/funds/FundExitGateway.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundMintGateway} from "../../src/funds/FundMintGateway.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title DeployGateways — the USDG mint and exit gateways on Robinhood Chain and their Base counterpart
/// @notice In order:
///         1. `deployBase()` on Base: the {BaseGateway}, owned by the Base Safe.
///         2. `deployRobinhood()` on Robinhood Chain (BASE_GATEWAY set): the ownerless {FundExitGateway} and the
///            {FundMintGateway}, owned by the governance Safe.
///         3. `robinhoodBatch()`: the governance Safe grants the mint gateway FUND_GATEWAY (so the mint zap
///            mints for its users), marks rZEC and rHYPE as stocked and allows the keeper.
///         4. `baseBatch()`: the Base Safe points the Base gateway at both Robinhood gateways, allows the
///            keeper, the rZEC and rHYPE wrappers and the swap router.
///         Each batch is simulated as its Safe on the RPC's chain and written to `safe-batches/<name>.json`
///         for the Safe Transaction Builder, with `<name>.md` listing every call.
///         After both batches: Own's float stocks the mint gateway (`addStock`, any amount, from the Safe).
///
/// Env: DEPLOYER_PRIVATE_KEY_BASE / DEPLOYER_PRIVATE_KEY_ROBINHOOD (deploys), FUND_FACTORY, BASE_GATEWAY,
///      FUND_EXIT_GATEWAY, FUND_MINT_GATEWAY, GATEWAY_KEEPER (optional, default the Own keeper),
///      BASE_SWAP_ROUTER (optional, default 1inch's AggregationRouterV6).
///
/// Usage:
///   forge script script/funds/DeployGateways.s.sol --rpc-url base --sig "deployBase()" --broadcast
///   forge script script/funds/DeployGateways.s.sol --rpc-url robinhood --sig "deployRobinhood()" --broadcast
///   forge script script/funds/DeployGateways.s.sol --rpc-url robinhood --sig "robinhoodBatch()"
///   forge script script/funds/DeployGateways.s.sol --rpc-url base --sig "baseBatch()"
contract DeployGateways is Script {
    struct Call {
        address to;
        bytes data;
        string label;
    }

    uint256 constant BASE_CHAIN_ID = 8453;
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    uint64 constant BASE_SELECTOR = 15_971_525_489_660_198_786;
    uint64 constant RH_SELECTOR = 6_180_753_054_346_818_345;

    address constant RH_SAFE = 0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2;
    address constant BASE_SAFE = 0xE76d38c37AaA115D3E5155A81E5f545401462d80;
    address constant KEEPER = 0xB1284eC8A142d71A3694b66e2fe9a8e0014de88e;
    address constant REGISTRY = 0x93e08ca467046737F75AAD4C936356c196AaA36F;

    address constant BASE_CCIP_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address constant RH_CCIP_ROUTER = 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9;
    address constant BASE_SPOKE_POOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    address constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ONE_INCH_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    address constant RZEC_RH = 0xaB100cbD80441499A4cBEe4927B1F2424B09a5fC;
    address constant RHYPE_RH = 0x133b1D01554B5665cf93358959857BDf063a26aF;
    address constant RZEC_BASE = 0x364e5B569d4765c8157638b01278Fc33Ac53F820;
    address constant RHYPE_BASE = 0xF3104de3A75593F0ae80d01BF4572a90033fF04b;

    bytes32 constant FUND_GATEWAY = keccak256("FUND_GATEWAY");
    string constant OUT_DIR = "safe-batches/";

    function run() external pure {
        revert("pick a step with --sig, see the header");
    }

    /// @notice Step 1 (Base): deploy the Base gateway, owned by the Base Safe.
    function deployBase() external {
        require(block.chainid == BASE_CHAIN_ID, "RPC is not Base (8453)");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_BASE"));
        BaseGateway gw = new BaseGateway(
            BASE_SAFE, BASE_CCIP_ROUTER, RH_SELECTOR, BASE_USDC, BASE_SPOKE_POOL, ROBINHOOD_CHAIN_ID, USDG
        );
        vm.stopBroadcast();
        console.log("BaseGateway     ", address(gw));
    }

    /// @notice Step 2 (Robinhood Chain): deploy the exit and mint gateways against the Base gateway.
    function deployRobinhood() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        address factory = vm.envAddress("FUND_FACTORY");
        address baseGateway = vm.envAddress("BASE_GATEWAY");
        address zap = FundFactory(factory).mintZap();
        require(zap != address(0), "factory has no mint zap");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        FundExitGateway exitGw = new FundExitGateway(factory, RH_CCIP_ROUTER, BASE_SELECTOR, baseGateway);
        FundMintGateway mintGw = new FundMintGateway(
            RH_SAFE, factory, zap, RH_CCIP_ROUTER, BASE_SELECTOR, baseGateway, RH_SPOKE_POOL, BASE_USDC, BASE_CHAIN_ID
        );
        vm.stopBroadcast();
        console.log("FundExitGateway ", address(exitGw));
        console.log("FundMintGateway ", address(mintGw));
    }

    /// @notice Step 3 (Robinhood Chain): the governance Safe's batch.
    function robinhoodBatch() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        address mintGw = vm.envAddress("FUND_MINT_GATEWAY");
        address keeper = vm.envOr("GATEWAY_KEEPER", KEEPER);
        require(FundMintGateway(mintGw).owner() == RH_SAFE, "mint gateway owner");
        require(FundMintGateway(mintGw).baseGateway() == vm.envAddress("BASE_GATEWAY"), "mint gateway Base side");

        Call[] memory calls = new Call[](4);
        calls[0] = Call(
            REGISTRY,
            abi.encodeCall(IAccessControl.grantRole, (FUND_GATEWAY, mintGw)),
            "registry.grantRole(FUND_GATEWAY, mint gateway)"
        );
        calls[1] = Call(mintGw, abi.encodeCall(FundMintGateway.setBaseAsset, (RZEC_RH, true)), "setBaseAsset(rZEC)");
        calls[2] = Call(mintGw, abi.encodeCall(FundMintGateway.setBaseAsset, (RHYPE_RH, true)), "setBaseAsset(rHYPE)");
        calls[3] = Call(mintGw, abi.encodeCall(FundMintGateway.setKeeper, (keeper, true)), "setKeeper(keeper)");
        _simulate(RH_SAFE, calls);
        require(IProtocolRegistry(REGISTRY).hasRole(FUND_GATEWAY, mintGw), "role");
        _write(
            "gateways-robinhood",
            "USDG gateways on Robinhood Chain: the mint gateway may mint for its users, stocks rZEC and rHYPE, and the keeper may fill queued mints and bridge the float",
            ROBINHOOD_CHAIN_ID,
            RH_SAFE,
            calls
        );
    }

    /// @notice Step 4 (Base): the Base Safe's batch.
    function baseBatch() external {
        require(block.chainid == BASE_CHAIN_ID, "RPC is not Base (8453)");
        address gw = vm.envAddress("BASE_GATEWAY");
        address exitGw = vm.envAddress("FUND_EXIT_GATEWAY");
        address mintGw = vm.envAddress("FUND_MINT_GATEWAY");
        address keeper = vm.envOr("GATEWAY_KEEPER", KEEPER);
        address swapRouter = vm.envOr("BASE_SWAP_ROUTER", ONE_INCH_V6);
        require(BaseGateway(gw).owner() == BASE_SAFE, "Base gateway owner");

        Call[] memory calls = new Call[](6);
        calls[0] = Call(gw, abi.encodeCall(BaseGateway.setRemoteGateway, (exitGw)), "setRemoteGateway(exit gateway)");
        calls[1] =
            Call(gw, abi.encodeCall(BaseGateway.setRemoteMintGateway, (mintGw)), "setRemoteMintGateway(mint gateway)");
        calls[2] = Call(gw, abi.encodeCall(BaseGateway.setKeeper, (keeper, true)), "setKeeper(keeper)");
        calls[3] = Call(gw, abi.encodeCall(BaseGateway.setWrapper, (RZEC_BASE, true)), "setWrapper(rZEC)");
        calls[4] = Call(gw, abi.encodeCall(BaseGateway.setWrapper, (RHYPE_BASE, true)), "setWrapper(rHYPE)");
        calls[5] = Call(gw, abi.encodeCall(BaseGateway.setRouter, (swapRouter, true)), "setRouter(swap router)");
        _simulate(BASE_SAFE, calls);
        require(BaseGateway(gw).remoteGateway() == exitGw, "remote gateway");
        _write(
            "gateways-base",
            "USDG gateways on Base: the Base gateway accepts sells from the Robinhood exit gateway, restocks the mint gateway, and may wrap rZEC and rHYPE and swap through the router",
            BASE_CHAIN_ID,
            BASE_SAFE,
            calls
        );
    }

    function _simulate(address safe, Call[] memory calls) internal {
        vm.startPrank(safe);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                vm.stopPrank();
                revert(string.concat("call ", vm.toString(i + 1), " failed: ", calls[i].label, " ", vm.toString(ret)));
            }
        }
        vm.stopPrank();
    }

    function _write(
        string memory name,
        string memory description,
        uint256 chainId,
        address safe,
        Call[] memory calls
    ) internal {
        string memory txs;
        string memory list;
        for (uint256 i; i < calls.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '\n    {"to": "',
                vm.toString(calls[i].to),
                '", "value": "0", "data": "',
                vm.toString(calls[i].data),
                '"}'
            );
            list =
                string.concat(list, vm.toString(i + 1), ". `", calls[i].label, "` on ", vm.toString(calls[i].to), "\n");
        }
        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "',
            vm.toString(chainId),
            '",\n  "createdAt": ',
            vm.toString(vm.unixTime()),
            ',\n  "meta": {"name": "',
            name,
            '", "description": "',
            description,
            '", "createdFromSafeAddress": "',
            vm.toString(safe),
            '"},\n  "transactions": [',
            txs,
            "\n  ]\n}\n"
        );
        string memory md = string.concat(
            "# ",
            name,
            "\n\n",
            description,
            ".\n\nSafe ",
            vm.toString(safe),
            " on chain ",
            vm.toString(chainId),
            ". Simulated as the Safe at block ",
            vm.toString(block.number),
            ".\n\n",
            list
        );
        vm.createDir(OUT_DIR, true);
        vm.writeFile(string.concat(OUT_DIR, name, ".json"), json);
        vm.writeFile(string.concat(OUT_DIR, name, ".md"), md);
    }
}
