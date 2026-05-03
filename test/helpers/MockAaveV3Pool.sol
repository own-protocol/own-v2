// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAaveV3Pool} from "../../src/interfaces/external/IAaveV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal aToken used by MockAaveV3Pool. Supports mint/burn by the pool
///      and standard ERC-20 transfers. 1 aToken == 1 underlying for the mock
///      (no liquidity index — yield is simulated by minting extra aTokens via
///      `accrue` in tests when needed).
contract MockAToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    address public immutable pool;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    error OnlyPool();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address pool_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        pool = pool_;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(
        address account
    ) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MockAToken: insufficient allowance");
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyPool {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        require(_balances[from] >= amount, "MockAToken: burn exceeds balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "MockAToken: transfer exceeds balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @title MockAaveV3Pool — Minimal mock of Aave V3 Pool for unit tests
/// @notice Supports supply / withdraw of a single registered reserve. Mints a
///         MockAToken 1:1 on supply, burns it 1:1 on withdraw. No interest
///         accrual, no borrow logic — those are exercised in fork tests.
contract MockAaveV3Pool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    /// @dev Per-reserve aToken (underlying => aToken).
    mapping(address => MockAToken) public aTokens;

    /// @notice Register a reserve and deploy its aToken.
    function registerReserve(
        address underlying,
        string memory aTokenName,
        string memory aTokenSymbol,
        uint8 aTokenDecimals
    ) external returns (address aToken) {
        require(address(aTokens[underlying]) == address(0), "MockAaveV3Pool: already registered");
        MockAToken at = new MockAToken(aTokenName, aTokenSymbol, aTokenDecimals, address(this));
        aTokens[underlying] = at;
        return address(at);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        MockAToken at = aTokens[asset];
        require(address(at) != address(0), "MockAaveV3Pool: unknown reserve");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        at.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        MockAToken at = aTokens[asset];
        require(address(at) != address(0), "MockAaveV3Pool: unknown reserve");
        if (amount == type(uint256).max) {
            amount = at.balanceOf(msg.sender);
        }
        at.burn(msg.sender, amount);
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function borrow(address, uint256, uint256, uint16, address) external pure override {
        revert("MockAaveV3Pool: borrow not implemented");
    }

    function repay(address, uint256, uint256, address) external pure override returns (uint256) {
        revert("MockAaveV3Pool: repay not implemented");
    }

    function getUserAccountData(
        address
    ) external pure override returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, type(uint256).max);
    }
}
