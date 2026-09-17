// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IOwnershipNFT — Soulbound identity anchor for the Own points program
/// @notice Minimal soulbound ERC-721, one token per wallet. All points math lives
///         off-chain; `tokenURI` points at the points-service metadata endpoint,
///         which serves live points, tier, and image.
///
///         Roles (OpenZeppelin AccessControl):
///         - DEFAULT_ADMIN_ROLE (protocol multisig): sets URIs, toggles transfers,
///           burns tokens, rotates the minter.
///         - MINTER_ROLE (points-service hot wallet): mint-only.
interface IOwnershipNFT is IERC721 {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when the admin toggles transferability.
    /// @param enabled True if transfers and approvals are now allowed.
    event TransfersEnabled(bool enabled);

    /// @notice Emitted when the admin updates the base URI.
    /// @param newBaseURI The new base URI.
    event BaseURIUpdated(string newBaseURI);

    /// @notice Emitted when the admin updates the collection-level metadata URI.
    /// @param newContractURI The new contract URI.
    event ContractURIUpdated(string newContractURI);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The recipient already owns a token (one per wallet).
    error AlreadyOwnsToken(address owner);

    /// @notice Transfers and approvals are disabled (token is soulbound).
    error TransfersDisabled();

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Minter functions
    // ──────────────────────────────────────────────────────────

    /// @notice Mint a token to a wallet. Restricted to MINTER_ROLE.
    /// @dev Reverts with AlreadyOwnsToken if `to` already holds a token.
    ///      Token ids auto-increment starting at 1.
    /// @param to Recipient wallet.
    /// @return tokenId The freshly minted token id.
    function mintTo(
        address to
    ) external returns (uint256 tokenId);

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @notice Burn a token. Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev Burns are allowed regardless of the transfersEnabled flag.
    /// @param tokenId Token to burn.
    function burn(
        uint256 tokenId
    ) external;

    /// @notice Toggle transferability. Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev Kept two-way for flexibility; expected to be flipped once by governance.
    /// @param enabled True to allow transfers and approvals.
    function setTransfersEnabled(
        bool enabled
    ) external;

    /// @notice Update the base URI. Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev Allows hosting migration without touching tokens.
    /// @param newBaseURI New base URI (token id is appended).
    function setBaseURI(
        string calldata newBaseURI
    ) external;

    /// @notice Update the collection-level metadata URI. Restricted to DEFAULT_ADMIN_ROLE.
    /// @param newContractURI New contract URI.
    function setContractURI(
        string calldata newContractURI
    ) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Whether transfers and approvals are currently allowed.
    /// @return True if transfers are enabled.
    function transfersEnabled() external view returns (bool);

    /// @notice Base URI prepended to token ids in tokenURI.
    /// @return The base URI string.
    function baseURI() external view returns (string memory);

    /// @notice Collection-level metadata URI.
    /// @return The contract URI string.
    function contractURI() external view returns (string memory);

    /// @notice The id the next mint will receive.
    /// @return The next token id.
    function nextTokenId() external view returns (uint256);
}
