// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsFeeEscrowV2} from "../../src/interfaces/external/IPonsFeeEscrowV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockPonsFeeEscrow — Test double for the Pons V2 fee escrow
/// @notice Mirrors the deployed escrow's semantics: per-recipient native and ERC-20 balances,
///         msg.sender-scoped claims, and reverts on claiming a zero balance.
contract MockPonsFeeEscrow is IPonsFeeEscrowV2 {
    using SafeERC20 for IERC20;

    error ZeroClaim();

    mapping(address => uint256) private _native;
    mapping(address => mapping(address => uint256)) private _tokens;

    function credit(
        address account
    ) external payable {
        _native[account] += msg.value;
    }

    function creditToken(address account, address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _tokens[account][token] += amount;
    }

    function claim() external returns (uint256 amount) {
        amount = _native[msg.sender];
        if (amount == 0) revert ZeroClaim();
        _native[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native send failed");
    }

    function claim(
        uint256 amount
    ) external returns (uint256 claimed) {
        if (amount == 0) revert ZeroClaim();
        _native[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native send failed");
        return amount;
    }

    function claimToken(
        address token
    ) external returns (uint256 amount) {
        amount = _tokens[msg.sender][token];
        if (amount == 0) revert ZeroClaim();
        _tokens[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function claimToken(address token, uint256 amount) external returns (uint256 claimed) {
        if (amount == 0) revert ZeroClaim();
        _tokens[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        return amount;
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return _native[account];
    }

    function balanceOfToken(address account, address token) external view returns (uint256) {
        return _tokens[account][token];
    }
}
