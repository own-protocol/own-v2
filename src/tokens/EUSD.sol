// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSD} from "../interfaces/IEUSD.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title EUSD — CDP stablecoin (ERC-20 + ERC-2612 Permit)
/// @notice Minimal stablecoin token. All supply changes go through MINTER_ROLE, held only by the
///         EUSDManager; burns are allowance-free so the manager can retire debt directly from the
///         payer on repay / redeem / liquidate. No other logic lives here.
contract EUSD is IEUSD, ERC20Permit, AccessControl {
    /// @inheritdoc IEUSD
    bytes32 public constant override MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @param admin Initial holder of DEFAULT_ADMIN_ROLE (grants/revokes MINTER_ROLE).
    constructor(
        address admin
    ) ERC20("eUSD", "eUSD") ERC20Permit("eUSD") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IEUSD
    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IEUSD
    function burn(address from, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    /// @inheritdoc IERC20Permit
    function nonces(
        address owner
    ) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}
