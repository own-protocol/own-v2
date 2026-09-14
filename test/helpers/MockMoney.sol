// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title MockMoney — Test double for the $MONEY token (ERC-20 + Burnable, 18 decimals)
contract MockMoney is ERC20Burnable {
    constructor() ERC20("Money", "MONEY") {}

    /// @notice Mint tokens to any address. Unrestricted for testing.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
