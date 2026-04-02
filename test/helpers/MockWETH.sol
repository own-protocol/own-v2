// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWETH — Mock WETH9 with deposit/withdraw for testing
/// @notice Simulates the standard WETH9 contract: deposit ETH to mint WETH,
///         withdraw WETH to receive ETH back.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Wrap sent ETH into WETH.
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Unwrap WETH back to ETH.
    /// @param amount Amount of WETH to unwrap.
    function withdraw(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /// @notice Accept ETH directly (same as deposit).
    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Testnet helper — mint WETH freely without depositing ETH.
    /// @dev Not in real WETH9; used for testnet convenience so testers don't
    ///      need real testnet ETH to seed the vault.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
