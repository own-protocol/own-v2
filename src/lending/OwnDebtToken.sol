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
    /// @notice The OwnLendingPool this debt token belongs to (debt ledger + allowance authority).
    address public immutable pool;

    /// @notice ERC-20 token name.
    string public name;

    /// @notice ERC-20 token symbol.
    string public symbol;

    /// @notice Token decimals, mirroring the pool's underlying.
    uint8 public immutable decimals;

    /// @dev delegator => delegatee => remaining borrow allowance.
    mapping(address => mapping(address => uint256)) private _borrowAllowances;

    /// @notice Emitted when a delegator sets a delegatee's borrow allowance.
    /// @param delegator Account whose credit line is delegated (the debtor-to-be).
    /// @param delegatee Account permitted to borrow on the delegator's behalf.
    /// @param amount    New allowance (absolute, not additive).
    event BorrowAllowanceDelegated(address indexed delegator, address indexed delegatee, uint256 amount);

    /// @notice Thrown when a pool-only function is called by another account.
    error OnlyPool();

    /// @notice Thrown on any transfer/approve call — debt tokens are non-transferable.
    error NonTransferable();

    /// @notice Thrown when a delegated borrow exceeds the delegatee's remaining allowance.
    /// @param delegator Account whose allowance was checked.
    /// @param delegatee Account attempting the delegated borrow.
    /// @param requested Amount requested that exceeded the allowance.
    error InsufficientDelegation(address delegator, address delegatee, uint256 requested);

    /// @dev Restricts allowance consumption to the owning pool.
    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    /// @param name_     ERC-20 token name.
    /// @param symbol_   ERC-20 token symbol.
    /// @param decimals_ Decimals to expose (mirrors the pool underlying).
    /// @param pool_     The owning OwnLendingPool (debt ledger source and allowance consumer).
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address pool_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        pool = pool_;
    }

    /// @notice Live variable debt of `user`, read from the pool ledger (single source of truth).
    /// @param user Account to query.
    /// @return The account's outstanding debt, in underlying units.
    function balanceOf(
        address user
    ) external view returns (uint256) {
        return IOwnLendingPool(pool).debtOf(user);
    }

    /// @notice Total outstanding pool debt.
    /// @return The pool's total debt, in underlying units.
    function totalSupply() external view returns (uint256) {
        return IOwnLendingPool(pool).totalDebt();
    }

    /// @inheritdoc ICreditDelegation
    function approveDelegation(address delegatee, uint256 amount) external {
        _borrowAllowances[msg.sender][delegatee] = amount;
        emit BorrowAllowanceDelegated(msg.sender, delegatee, amount);
    }

    /// @notice Remaining amount `delegatee` may borrow on `delegator`'s behalf.
    /// @param delegator Account whose credit line is delegated.
    /// @param delegatee Account permitted to borrow.
    /// @return The remaining borrow allowance, in underlying units.
    function borrowAllowance(address delegator, address delegatee) external view returns (uint256) {
        return _borrowAllowances[delegator][delegatee];
    }

    /// @notice Consume a delegatee's allowance on a delegated borrow — pool-only.
    /// @dev Infinite allowance (`type(uint256).max`) is not decremented (Aave parity).
    /// @param delegator Account whose allowance is spent.
    /// @param delegatee Account performing the delegated borrow.
    /// @param amount    Amount to deduct from the allowance.
    function consumeAllowance(address delegator, address delegatee, uint256 amount) external onlyPool {
        uint256 allowed = _borrowAllowances[delegator][delegatee];
        if (allowed < amount) revert InsufficientDelegation(delegator, delegatee, amount);
        if (allowed != type(uint256).max) {
            _borrowAllowances[delegator][delegatee] = allowed - amount;
        }
    }

    /// @notice Reverts — debt is non-transferable (Aave parity).
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Reverts — debt is non-transferable (Aave parity).
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Reverts — debt cannot be approved for transfer (Aave parity).
    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }
}
