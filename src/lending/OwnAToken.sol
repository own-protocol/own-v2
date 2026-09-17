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

    /// @dev Decimals mirrored from the pool's underlying, set once at construction.
    uint8 private immutable _decimals;

    /// @notice Thrown when a pool-only function is called by another account.
    error OnlyPool();

    /// @dev Restricts mint/burn to the owning pool.
    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    /// @param name_     ERC-20 token name.
    /// @param symbol_   ERC-20 token symbol.
    /// @param decimals_ Decimals to expose (mirrors the pool underlying).
    /// @param pool_     The owning OwnLendingPool (sole minter/burner and health authority).
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address pool_) ERC20(name_, symbol_) {
        pool = pool_;
        _decimals = decimals_;
    }

    /// @notice The token's decimals, mirroring the pool's underlying.
    /// @return The number of decimals.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint aTokens — pool-only, invoked on {IOwnLendingPool-supply}.
    /// @param to     Recipient of the minted aTokens.
    /// @param amount Amount to mint (1:1 with supplied underlying).
    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /// @notice Burn aTokens — pool-only, invoked on {IOwnLendingPool-withdraw}.
    /// @param from   Account whose aTokens are burned.
    /// @param amount Amount to burn (1:1 with withdrawn underlying).
    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }

    /// @dev Overrides the OZ ERC-20 hook to health-check the sender after user-to-user
    ///      transfers, mirroring Aave V3's `finalizeTransfer`: a debtor cannot move
    ///      collateral away and leave unbacked debt. Mint (`from == 0`) needs no check;
    ///      burn (`to == 0`) is pool-initiated and the pool enforces health in `withdraw`.
    /// @param from  Sender (zero on mint).
    /// @param to    Recipient (zero on burn).
    /// @param value Amount transferred.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            IOwnLendingPool(pool).validateTransfer(from);
        }
    }
}
