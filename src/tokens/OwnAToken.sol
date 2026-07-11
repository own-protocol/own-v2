// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnLendingPool} from "../interfaces/IOwnLendingPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title OwnAToken — 1:1 receipt token for OwnLendingPool deposits
/// @notice Standard freely-transferable ERC-20 minted/burned only by the pool.
///         The pool accrues no interest, so 1 aToken == 1 underlying at all
///         times (no liquidity index). Held by OwnVault as its ERC-4626 asset.
/// @dev Transfers out of an account with outstanding pool debt are health-checked
///      via {IOwnLendingPool.validateTransfer}, mirroring Aave V3's
///      `finalizeTransfer` — without it a debtor could move their collateral away
///      and leave unbacked debt in the pool.
contract OwnAToken is ERC20 {
    /// @notice The OwnLendingPool this aToken belongs to (sole minter/burner).
    address public immutable pool;

    uint8 private immutable _decimals;

    /// @notice Caller is not the pool.
    error OnlyPool();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address pool_) ERC20(name_, symbol_) {
        pool = pool_;
        _decimals = decimals_;
    }

    /// @notice Mirrors the pool underlying's decimals.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` to `to` — pool-only, on supply.
    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` — pool-only, on withdraw.
    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }

    /// @dev Health-check the sender after user-to-user transfers. Mint (`from == 0`)
    ///      needs no check; burn (`to == 0`) is pool-initiated and the pool enforces
    ///      health in `withdraw` itself.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            IOwnLendingPool(pool).validateTransfer(from);
        }
    }
}
