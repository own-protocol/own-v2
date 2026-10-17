// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICcipWrappedToken} from "../interfaces/ICcipWrappedToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title CcipWrappedToken — 1:1 wrapper of a third-party token for CCIP (rZEC, rHYPE)
/// @notice See {ICcipWrappedToken}.
contract CcipWrappedToken is ICcipWrappedToken, ERC20Wrapper, ReentrancyGuardTransient {
    address private immutable _ccipAdmin;
    uint8 private immutable _decimals;

    /// @param underlying_ The token to wrap.
    /// @param name_       Wrapper name.
    /// @param symbol_     Wrapper symbol.
    /// @param ccipAdmin_  Address allowed to register the wrapper with CCIP (the deployer that runs the setup).
    constructor(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_,
        address ccipAdmin_
    ) ERC20(name_, symbol_) ERC20Wrapper(underlying_) {
        if (address(underlying_) == address(0) || ccipAdmin_ == address(0)) revert ZeroAddress();
        _ccipAdmin = ccipAdmin_;
        _decimals = IERC20Metadata(address(underlying_)).decimals();
    }

    /// @inheritdoc ICcipWrappedToken
    function depositFor(
        address account,
        uint256 value
    ) public override(ICcipWrappedToken, ERC20Wrapper) nonReentrant returns (bool) {
        IERC20 token = underlying();
        uint256 before = token.balanceOf(address(this));
        super.depositFor(account, value);
        if (token.balanceOf(address(this)) - before != value) revert UnexpectedBalanceChange();
        return true;
    }

    /// @inheritdoc ICcipWrappedToken
    function withdrawTo(
        address account,
        uint256 value
    ) public override(ICcipWrappedToken, ERC20Wrapper) nonReentrant returns (bool) {
        return super.withdrawTo(account, value);
    }

    /// @inheritdoc ICcipWrappedToken
    function getCCIPAdmin() external view override returns (address) {
        return _ccipAdmin;
    }

    /// @notice Same decimals as the underlying, read once at deploy.
    /// @return The wrapper's decimals.
    function decimals() public view override(ERC20Wrapper) returns (uint8) {
        return _decimals;
    }
}
