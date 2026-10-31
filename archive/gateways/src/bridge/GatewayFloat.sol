// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GatewayFloat — holds the USDC float the Robinhood mint gateway bridges to Base
/// @notice Across fills of the revenue bridge land here, not on the {BaseGateway}, so no swap the gateway
///         measures by balance change can count them. Only the gateway that deployed it can pay out.
contract GatewayFloat {
    using SafeERC20 for IERC20;

    /// @notice The gateway that deployed this float and alone may pay from it.
    address public immutable gateway;

    /// @notice Caller is not the gateway.
    error NotGateway();

    constructor() {
        gateway = msg.sender;
    }

    /// @notice Send `amount` of `token` to `to` (gateway only).
    /// @param token  The token.
    /// @param to     Recipient.
    /// @param amount Amount.
    function pay(address token, address to, uint256 amount) external {
        if (msg.sender != gateway) revert NotGateway();
        IERC20(token).safeTransfer(to, amount);
    }
}
