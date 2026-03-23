// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockAUSDC — Mock Aave aUSDC with configurable yield accrual
/// @notice Simulates Aave's aToken rebasing behaviour. The balance of each
///         holder grows proportionally as yield accrues. Internally this is
///         modelled via a liquidity index (ray-based, 1e27 precision like Aave).
///         Test code calls `setLiquidityIndex()` to simulate yield growth.
contract MockAUSDC is ERC20 {
    using Math for uint256;

    uint256 private constant RAY = 1e27;

    /// @notice Current liquidity index (Aave convention, 1e27 = 1.0).
    uint256 public liquidityIndex = RAY;

    /// @dev Scaled balances (balance / liquidityIndex at deposit time).
    mapping(address => uint256) private _scaledBalances;
    uint256 private _scaledTotalSupply;

    constructor() ERC20("Mock Aave USDC", "aUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ──────────────────────────────────────────────────────────
    //  Test helpers
    // ──────────────────────────────────────────────────────────

    /// @notice Set the liquidity index to simulate yield accrual.
    /// @param newIndex New index value (1e27 = 1.0).
    function setLiquidityIndex(
        uint256 newIndex
    ) external {
        liquidityIndex = newIndex;
    }

    /// @notice Mint aUSDC to an address at the current index.
    function mint(address to, uint256 amount) external {
        uint256 scaledAmount = amount.mulDiv(RAY, liquidityIndex);
        _scaledBalances[to] += scaledAmount;
        _scaledTotalSupply += scaledAmount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn aUSDC from an address at the current index.
    function burn(address from, uint256 amount) external {
        uint256 scaledAmount = amount.mulDiv(RAY, liquidityIndex, Math.Rounding.Ceil);
        require(_scaledBalances[from] >= scaledAmount, "MockAUSDC: burn exceeds balance");
        _scaledBalances[from] -= scaledAmount;
        _scaledTotalSupply -= scaledAmount;
        emit Transfer(from, address(0), amount);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-20 overrides (rebasing)
    // ──────────────────────────────────────────────────────────

    function totalSupply() public view override returns (uint256) {
        return _scaledTotalSupply.mulDiv(liquidityIndex, RAY);
    }

    function balanceOf(
        address account
    ) public view override returns (uint256) {
        return _scaledBalances[account].mulDiv(liquidityIndex, RAY);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 scaledAmount = amount.mulDiv(RAY, liquidityIndex, Math.Rounding.Ceil);
        require(_scaledBalances[msg.sender] >= scaledAmount, "MockAUSDC: transfer exceeds balance");
        _scaledBalances[msg.sender] -= scaledAmount;
        _scaledBalances[to] += scaledAmount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 scaledAmount = amount.mulDiv(RAY, liquidityIndex, Math.Rounding.Ceil);
        require(_scaledBalances[from] >= scaledAmount, "MockAUSDC: transfer exceeds balance");
        _scaledBalances[from] -= scaledAmount;
        _scaledBalances[to] += scaledAmount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Return the scaled (non-rebased) balance.
    function scaledBalanceOf(
        address account
    ) external view returns (uint256) {
        return _scaledBalances[account];
    }
}
