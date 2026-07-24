// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnershipNFT} from "../interfaces/IOwnershipNFT.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title OwnershipNFT — Soulbound identity anchor for the Own points program
/// @notice Minimal soulbound ERC-721, one per wallet. Points, tiers, and images are
///         served off-chain by the points-service via `tokenURI`; nothing but identity
///         lives on-chain. Transfers and approvals are disabled until governance flips
///         `transfersEnabled`. Mints and burns are always allowed.
contract OwnershipNFT is ERC721, AccessControl, IOwnershipNFT {
    // ──────────────────────────────────────────────────────────
    //  Roles
    // ──────────────────────────────────────────────────────────

    /// @notice Role allowed to mint (points-service hot wallet).
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnershipNFT
    bool public override transfersEnabled;

    /// @inheritdoc IOwnershipNFT
    string public override baseURI;

    /// @inheritdoc IOwnershipNFT
    string public override contractURI;

    /// @inheritdoc IOwnershipNFT
    uint256 public override nextTokenId = 1;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param name_    Token name (e.g. "Ownership NFT").
    /// @param symbol_  Token symbol (e.g. "OwnNFT").
    /// @param admin_   DEFAULT_ADMIN_ROLE holder (protocol multisig).
    /// @param minter_  MINTER_ROLE holder (points-service hot wallet).
    /// @param baseURI_ Initial base URI (points-service metadata endpoint).
    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address minter_,
        string memory baseURI_
    ) ERC721(name_, symbol_) {
        if (admin_ == address(0) || minter_ == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MINTER_ROLE, minter_);
        baseURI = baseURI_;
    }

    // ──────────────────────────────────────────────────────────
    //  Minter functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnershipNFT
    function mintTo(
        address to
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (balanceOf(to) != 0) revert AlreadyOwnsToken(to);

        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnershipNFT
    function burn(
        uint256 tokenId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _burn(tokenId);
    }

    /// @inheritdoc IOwnershipNFT
    function setTransfersEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transfersEnabled = enabled;
        emit TransfersEnabled(enabled);
    }

    /// @inheritdoc IOwnershipNFT
    function setBaseURI(
        string calldata newBaseURI
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /// @inheritdoc IOwnershipNFT
    function setContractURI(
        string calldata newContractURI
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractURI = newContractURI;
        emit ContractURIUpdated(newContractURI);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal: soulbound gates
    // ──────────────────────────────────────────────────────────

    /// @dev Blocks wallet-to-wallet transfers while soulbound. Mints (from == 0) and
    ///      burns (to == 0) always pass.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !transfersEnabled) revert TransfersDisabled();

        return super._update(to, tokenId, auth);
    }

    /// @dev Blocks granting per-token approvals while soulbound. Clearing (to == 0,
    ///      done internally by _update on every transfer/burn) always passes.
    function _approve(address to, uint256 tokenId, address auth, bool emitEvent) internal override {
        if (to != address(0) && !transfersEnabled) revert TransfersDisabled();

        super._approve(to, tokenId, auth, emitEvent);
    }

    /// @dev Blocks granting operator approvals while soulbound. Revocation always passes.
    function _setApprovalForAll(address owner, address operator, bool approved) internal override {
        if (approved && !transfersEnabled) revert TransfersDisabled();

        super._setApprovalForAll(owner, operator, approved);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @dev ERC721.tokenURI concatenates this with the token id.
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, AccessControl, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
