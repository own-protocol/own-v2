// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseGateway} from "../../src/bridge/BaseGateway.sol";
import {FundExitGateway} from "../../src/funds/FundExitGateway.sol";
import {FundMintGateway} from "../../src/funds/FundMintGateway.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Puts a gateway implementation behind an ERC-1967 proxy, as the deploy script does.
library GatewayProxies {
    function base(address owner, BaseGateway impl) internal returns (BaseGateway) {
        return BaseGateway(address(new ERC1967Proxy(address(impl), abi.encodeCall(BaseGateway.initialize, (owner)))));
    }

    function mint(address owner, FundMintGateway impl) internal returns (FundMintGateway) {
        return FundMintGateway(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(FundMintGateway.initialize, (owner))))
        );
    }

    function exit(address owner, FundExitGateway impl) internal returns (FundExitGateway) {
        return FundExitGateway(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(FundExitGateway.initialize, (owner))))
        );
    }
}
