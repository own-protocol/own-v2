// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEToken} from "../interfaces/IEToken.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EToken — Synthetic asset token with dividends and admin-updatable metadata
/// @notice Each tradeable asset (eTSLA, eGOLD, eTLT, …) has one active EToken.
///         Implements ERC-20 + ERC-2612 Permit with restricted mint/burn,
///         admin-updatable name/symbol, and a rewards-per-share dividend accumulator.
contract EToken is ERC20, ERC20Permit, IEToken {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    /// @notice Asset ticker this eToken represents.
    bytes32 public immutable override ticker;

    /// @notice ERC-20 token used for dividend payouts.
    address public immutable override rewardToken;

    /// @notice Protocol registry for resolving all contract addresses.
    IProtocolRegistry public immutable registry;

    // ──────────────────────────────────────────────────────────
    //  Mutable metadata (stock-split renaming)
    // ──────────────────────────────────────────────────────────

    string private _name;
    string private _symbol;

    // ──────────────────────────────────────────────────────────
    //  Rewards-per-share accumulator
    // ──────────────────────────────────────────────────────────

    /// @notice Cumulative rewards per share, scaled by PRECISION.
    uint256 private _rewardsPerShare;

    /// @dev Per-account snapshot of _rewardsPerShare at last settlement.
    mapping(address => uint256) private _userRewardsPerSharePaid;

    /// @dev Per-account accrued but unclaimed rewards.
    mapping(address => uint256) private _accruedRewards;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyOrderSystem() {
        if (msg.sender != registry.market()) revert Unauthorized();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param name_        Initial token name.
    /// @param symbol_      Initial token symbol.
    /// @param ticker_      Asset ticker (bytes32).
    /// @param registry_    ProtocolRegistry contract address.
    /// @param rewardToken_ ERC-20 token for dividend payouts.
    constructor(
        string memory name_,
        string memory symbol_,
        bytes32 ticker_,
        address registry_,
        address rewardToken_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (registry_ == address(0)) revert ZeroAddress();

        ticker = ticker_;
        registry = IProtocolRegistry(registry_);
        rewardToken = rewardToken_;
        _name = name_;
        _symbol = symbol_;
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-20 overrides (name/symbol are mutable)
    // ──────────────────────────────────────────────────────────

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev Override required by Solidity for diamond inheritance (ERC20Permit + IERC20Permit).
    function nonces(
        address owner
    ) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    // ──────────────────────────────────────────────────────────
    //  Restricted mint/burn
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEToken
    function mint(address to, uint256 amount) external onlyOrderSystem {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        _settleRewards(to);
        _mint(to, amount);

        emit Minted(to, amount);
    }

    /// @inheritdoc IEToken
    function burn(address from, uint256 amount) external onlyOrderSystem {
        if (amount == 0) revert ZeroAmount();

        _settleRewards(from);
        _burn(from, amount);

        emit Burned(from, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin: name/symbol update
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEToken
    function updateName(
        string calldata newName
    ) external onlyAdmin {
        string memory oldName = _name;
        _name = newName;
        emit NameUpdated(oldName, newName);
    }

    /// @inheritdoc IEToken
    function updateSymbol(
        string calldata newSymbol
    ) external onlyAdmin {
        string memory oldSymbol = _symbol;
        _symbol = newSymbol;
        emit SymbolUpdated(oldSymbol, newSymbol);
    }

    // ──────────────────────────────────────────────────────────
    //  Dividend / rewards functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEToken
    function depositRewards(
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        require(supply > 0, "EToken: no supply");

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        // Rounding: floor is fine here — any dust stays for the next deposit
        _rewardsPerShare += amount.mulDiv(PRECISION, supply);

        emit RewardsDeposited(amount, _rewardsPerShare);
    }

    /// @inheritdoc IEToken
    function claimRewards() external returns (uint256 amount) {
        _settleRewards(msg.sender);

        amount = _accruedRewards[msg.sender];
        if (amount == 0) revert NoRewardsToClaim();

        _accruedRewards[msg.sender] = 0;

        IERC20(rewardToken).safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount);
    }

    /// @inheritdoc IEToken
    function claimableRewards(
        address account
    ) external view returns (uint256 amount) {
        uint256 owed = _rewardsPerShare - _userRewardsPerSharePaid[account];
        // Rounding: floor — protocol keeps dust
        amount = _accruedRewards[account] + balanceOf(account).mulDiv(owed, PRECISION);
    }

    /// @inheritdoc IEToken
    function rewardsPerShare() external view returns (uint256) {
        return _rewardsPerShare;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal: reward settlement on transfer
    // ──────────────────────────────────────────────────────────

    /// @dev Override _update to settle rewards for both sender and receiver
    ///      on every transfer, mint, and burn. This is the OZ v5 hook.
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            _settleRewards(from);
        }
        if (to != address(0)) {
            _settleRewards(to);
        }
        super._update(from, to, amount);
    }

    /// @dev Settle pending rewards for an account.
    function _settleRewards(
        address account
    ) private {
        uint256 owed = _rewardsPerShare - _userRewardsPerSharePaid[account];
        if (owed > 0) {
            // Rounding: floor — protocol keeps dust
            _accruedRewards[account] += balanceOf(account).mulDiv(owed, PRECISION);
            _userRewardsPerSharePaid[account] = _rewardsPerShare;
        } else if (_userRewardsPerSharePaid[account] != _rewardsPerShare) {
            _userRewardsPerSharePaid[account] = _rewardsPerShare;
        }
    }
}
