// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPaymentTokenRegistry} from "../interfaces/IPaymentTokenRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PaymentTokenRegistry — Payment token (stablecoin) whitelist
/// @notice Manages the set of ERC-20 tokens accepted as payment for minting
///         and as payout for redemptions. Only the admin can mutate state.
contract PaymentTokenRegistry is IPaymentTokenRegistry, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @dev Set of whitelisted token addresses.
    mapping(address => bool) private _whitelisted;

    /// @dev Ordered list for enumeration.
    address[] private _tokens;

    /// @dev Index+1 in `_tokens` for O(1) removal. 0 means not present.
    mapping(address => uint256) private _tokenIndex;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin Initial owner / admin address.
    constructor(
        address admin
    ) Ownable(admin) {}

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IPaymentTokenRegistry
    function addPaymentToken(
        address token
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (_whitelisted[token]) revert AlreadyWhitelisted(token);

        _whitelisted[token] = true;
        _tokens.push(token);
        _tokenIndex[token] = _tokens.length; // 1-indexed

        emit PaymentTokenAdded(token);
    }

    /// @inheritdoc IPaymentTokenRegistry
    function removePaymentToken(
        address token
    ) external onlyOwner {
        if (!_whitelisted[token]) revert NotWhitelisted(token);

        _whitelisted[token] = false;

        // Swap-and-pop for O(1) removal
        uint256 idx = _tokenIndex[token] - 1; // convert to 0-indexed
        uint256 lastIdx = _tokens.length - 1;

        if (idx != lastIdx) {
            address lastToken = _tokens[lastIdx];
            _tokens[idx] = lastToken;
            _tokenIndex[lastToken] = idx + 1; // 1-indexed
        }

        _tokens.pop();
        delete _tokenIndex[token];

        emit PaymentTokenRemoved(token);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IPaymentTokenRegistry
    function isWhitelisted(
        address token
    ) external view returns (bool) {
        return _whitelisted[token];
    }

    /// @inheritdoc IPaymentTokenRegistry
    function getPaymentTokens() external view returns (address[] memory tokens) {
        return _tokens;
    }
}
