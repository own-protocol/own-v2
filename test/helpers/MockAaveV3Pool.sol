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

/// @dev Minimal Aave variable debt token used by MockAaveV3Pool. Records
///      credit-delegation allowances. Not transferable.
contract MockAaveDebtToken {
    mapping(address => mapping(address => uint256)) private _allowances;

    function approveDelegation(address delegatee, uint256 amount) external {
        _allowances[msg.sender][delegatee] = amount;
    }

    function borrowAllowance(address fromUser, address toUser) external view returns (uint256) {
        return _allowances[fromUser][toUser];
    }

    function consume(address fromUser, address toUser, uint256 amount) external {
        uint256 allowed = _allowances[fromUser][toUser];
        require(allowed >= amount, "MockAaveDebtToken: allowance too low");
        if (allowed != type(uint256).max) _allowances[fromUser][toUser] = allowed - amount;
    }
}

/// @title MockAaveV3Pool — Minimal mock of Aave V3 Pool for unit tests
/// @notice Supports supply / withdraw / borrow / repay against a registered reserve.
///         Borrows honour credit delegation read from a per-asset
///         MockAaveDebtToken. No interest accrual on the mock side; tests can
///         simulate accrual by calling `accrueDebt` directly.
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

    /// @notice Records `setUserUseReserveAsCollateral` calls per (caller, asset).
    mapping(address => mapping(address => bool)) public reserveAsCollateral;

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external override {
        reserveAsCollateral[msg.sender][asset] = useAsCollateral;
    }

    /// @dev Per-(user, asset) variable debt balance. Mock has no interest curve;
    ///      tests can call `accrueDebt` to simulate Aave-side interest.
    mapping(address => mapping(address => uint256)) public debtOf;

    /// @dev Per-asset registered debt token (informational; not enforced here).
    mapping(address => address) public variableDebtToken;

    /// @notice Register a debt token for a reserve (test convenience). Real Aave
    ///         deploys this internally on reserve init.
    function setVariableDebtToken(address asset, address debtToken_) external {
        variableDebtToken[asset] = debtToken_;
    }

    /// @notice Test-helper: deploy a MockAaveDebtToken and register it for `asset`.
    function deployVariableDebtToken(
        address asset
    ) external returns (address) {
        MockAaveDebtToken dt = new MockAaveDebtToken();
        variableDebtToken[asset] = address(dt);
        return address(dt);
    }

    /// @dev Add to a position's outstanding debt (simulates Aave interest accrual).
    function accrueDebt(address user, address asset, uint256 extra) external {
        debtOf[user][asset] += extra;
    }

    function borrow(
        address asset,
        uint256 amount,
        uint256, /*interestRateMode*/
        uint16, /*referralCode*/
        address onBehalfOf
    ) external override {
        // Honour delegation when caller != onBehalfOf, mirroring Aave V3.
        if (msg.sender != onBehalfOf) {
            address dt = variableDebtToken[asset];
            require(dt != address(0), "MockAaveV3Pool: no debt token");
            MockAaveDebtToken(dt).consume(onBehalfOf, msg.sender, amount);
        }
        debtOf[onBehalfOf][asset] += amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function repay(
        address asset,
        uint256 amount,
        uint256, /*interestRateMode*/
        address onBehalfOf
    ) external override returns (uint256) {
        uint256 outstanding = debtOf[onBehalfOf][asset];
        uint256 toRepay = amount > outstanding ? outstanding : amount;
        if (toRepay == 0) return 0;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), toRepay);
        debtOf[onBehalfOf][asset] = outstanding - toRepay;
        return toRepay;
    }

    /// @dev Test seeding helper: deposit reserve liquidity so borrow can pay out.
    function seedReserve(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Per-asset variable borrow rate (RAY-scaled, annualized). Settable
    ///      so tests can simulate Aave rate moves and verify the floor logic.
    mapping(address => uint128) public currentVariableBorrowRate;

    function setCurrentVariableBorrowRate(address asset, uint128 rateRay) external {
        currentVariableBorrowRate[asset] = rateRay;
    }

    function getReserveData(
        address asset
    ) external view override returns (ReserveDataLegacy memory data) {
        // Mock fills only the fields the manager actually reads
        // (`currentVariableBorrowRate` + the address fields downstream code may
        // glance at). Everything else stays zeroed.
        data.currentVariableBorrowRate = currentVariableBorrowRate[asset];
        data.aTokenAddress = address(aTokens[asset]);
        data.variableDebtTokenAddress = variableDebtToken[asset];
    }

    function getUserAccountData(
        address
    ) external pure override returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, type(uint256).max);
    }
}
