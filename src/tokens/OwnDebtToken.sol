// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnLendingPool} from "../interfaces/IOwnLendingPool.sol";
import {ICreditDelegation} from "../interfaces/external/ILendingVenue.sol";

/// @title OwnDebtToken — non-transferable debt ledger for OwnLendingPool
/// @notice Mirrors Aave V3's variable debt token surface the protocol consumes:
///         `balanceOf(user)` is the user's live pool debt (principal-only — the
///         pool accrues no interest) and `approveDelegation`/`borrowAllowance`
///         implement credit delegation for on-behalf borrows. Balances are a
///         view onto the pool's ledger; this contract stores only allowances.
contract OwnDebtToken is ICreditDelegation {
    /// @notice The OwnLendingPool this debt token belongs to.
    address public immutable pool;

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    /// @dev delegator => delegatee => remaining borrow allowance.
    mapping(address => mapping(address => uint256)) private _borrowAllowances;

    /// @notice `delegatee` was approved to incur `amount` of debt on `delegator`'s behalf.
    event BorrowAllowanceDelegated(address indexed delegator, address indexed delegatee, uint256 amount);

    /// @notice Caller is not the pool.
    error OnlyPool();

    /// @notice Debt tokens cannot be transferred or approved.
    error NonTransferable();

    /// @notice Delegated borrow exceeds the delegatee's remaining allowance.
    error InsufficientDelegation(address delegator, address delegatee, uint256 requested);

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

    /// @notice Live variable debt of `user` — reads the pool ledger (single source of truth).
    function balanceOf(
        address user
    ) external view returns (uint256) {
        return IOwnLendingPool(pool).debtOf(user);
    }

    /// @notice Total outstanding pool debt.
    function totalSupply() external view returns (uint256) {
        return IOwnLendingPool(pool).totalDebt();
    }

    /// @inheritdoc ICreditDelegation
    function approveDelegation(address delegatee, uint256 amount) external {
        _borrowAllowances[msg.sender][delegatee] = amount;
        emit BorrowAllowanceDelegated(msg.sender, delegatee, amount);
    }

    /// @notice Remaining amount `delegatee` may borrow on `delegator`'s behalf.
    function borrowAllowance(address delegator, address delegatee) external view returns (uint256) {
        return _borrowAllowances[delegator][delegatee];
    }

    /// @notice Consume `amount` of `delegatee`'s allowance from `delegator` — pool-only,
    ///         on delegated borrows. Infinite allowance is not decremented (Aave parity).
    function consumeAllowance(address delegator, address delegatee, uint256 amount) external onlyPool {
        uint256 allowed = _borrowAllowances[delegator][delegatee];
        if (allowed < amount) revert InsufficientDelegation(delegator, delegatee, amount);
        if (allowed != type(uint256).max) {
            _borrowAllowances[delegator][delegatee] = allowed - amount;
        }
    }

    /// @notice Debt is non-transferable (Aave parity).
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Debt is non-transferable (Aave parity).
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Debt cannot be approved for transfer (Aave parity).
    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }
}
