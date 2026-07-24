// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnershipNFT} from "../../src/interfaces/IOwnershipNFT.sol";
import {OwnershipNFT} from "../../src/tokens/OwnershipNFT.sol";
import {Actors} from "../helpers/Actors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";

/// @title OwnershipNFT Unit Tests
/// @notice Tests one-per-address minting, auto-increment ids, soulbound transfer/approval
///         gating, admin burn, role gating and rotation, and URI management.
contract OwnershipNFTTest is Test {
    OwnershipNFT public nft;

    address public pointsService;

    string constant NAME = "Own Ownership";
    string constant SYMBOL = "OWNSHIP";
    string constant BASE_URI = "https://points.own.finance/metadata/";
    string constant CONTRACT_URI = "https://points.own.finance/collection.json";

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        pointsService = makeAddr("pointsService");

        nft = new OwnershipNFT(NAME, SYMBOL, Actors.ADMIN, pointsService, BASE_URI);
        vm.label(address(nft), "OwnershipNFT");
        vm.label(Actors.ADMIN, "admin");
        vm.label(Actors.ATTACKER, "attacker");
    }

    /// @dev Mint a token to `to` as the points service and return its id.
    function _mint(
        address to
    ) internal returns (uint256 tokenId) {
        vm.prank(pointsService);
        tokenId = nft.mintTo(to);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsNameSymbol() public view {
        assertEq(nft.name(), NAME);
        assertEq(nft.symbol(), SYMBOL);
    }

    function test_constructor_grantsRoles() public view {
        assertTrue(nft.hasRole(DEFAULT_ADMIN_ROLE, Actors.ADMIN));
        assertTrue(nft.hasRole(MINTER_ROLE, pointsService));
        assertFalse(nft.hasRole(MINTER_ROLE, Actors.ADMIN));
    }

    function test_constructor_setsBaseURI() public view {
        assertEq(nft.baseURI(), BASE_URI);
    }

    function test_constructor_transfersDisabledByDefault() public view {
        assertFalse(nft.transfersEnabled());
    }

    function test_constructor_nextTokenIdStartsAtOne() public view {
        assertEq(nft.nextTokenId(), 1);
    }

    function test_constructor_zeroAdmin_reverts() public {
        vm.expectRevert(IOwnershipNFT.ZeroAddress.selector);
        new OwnershipNFT(NAME, SYMBOL, address(0), pointsService, BASE_URI);
    }

    function test_constructor_zeroMinter_reverts() public {
        vm.expectRevert(IOwnershipNFT.ZeroAddress.selector);
        new OwnershipNFT(NAME, SYMBOL, Actors.ADMIN, address(0), BASE_URI);
    }

    // ──────────────────────────────────────────────────────────
    //  mintTo
    // ──────────────────────────────────────────────────────────

    function test_mintTo_mintsTokenWithSequentialIds() public {
        uint256 id1 = _mint(Actors.MINTER1);
        uint256 id2 = _mint(Actors.MINTER2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(nft.ownerOf(1), Actors.MINTER1);
        assertEq(nft.ownerOf(2), Actors.MINTER2);
        assertEq(nft.balanceOf(Actors.MINTER1), 1);
        assertEq(nft.balanceOf(Actors.MINTER2), 1);
        assertEq(nft.nextTokenId(), 3);
    }

    function test_mintTo_emitsTransferEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(address(0), Actors.MINTER1, 1);

        _mint(Actors.MINTER1);
    }

    function test_mintTo_alreadyOwnsToken_reverts() public {
        _mint(Actors.MINTER1);

        vm.prank(pointsService);
        vm.expectRevert(abi.encodeWithSelector(IOwnershipNFT.AlreadyOwnsToken.selector, Actors.MINTER1));
        nft.mintTo(Actors.MINTER1);
    }

    function test_mintTo_zeroAddress_reverts() public {
        vm.prank(pointsService);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        nft.mintTo(address(0));
    }

    function test_mintTo_nonMinter_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, MINTER_ROLE
            )
        );
        nft.mintTo(Actors.MINTER1);
    }

    function test_mintTo_adminWithoutMinterRole_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ADMIN, MINTER_ROLE)
        );
        nft.mintTo(Actors.MINTER1);
    }

    function test_mintTo_afterBurn_remintsWithFreshId() public {
        uint256 id1 = _mint(Actors.MINTER1);

        vm.prank(Actors.ADMIN);
        nft.burn(id1);

        uint256 id2 = _mint(Actors.MINTER1);

        // Ids are never reused.
        assertEq(id2, 2);
        assertEq(nft.balanceOf(Actors.MINTER1), 1);
        assertEq(nft.ownerOf(id2), Actors.MINTER1);
    }

    // ──────────────────────────────────────────────────────────
    //  Soulbound: transfers and approvals
    // ──────────────────────────────────────────────────────────

    function test_transferFrom_whileDisabled_reverts() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnershipNFT.TransfersDisabled.selector);
        nft.transferFrom(Actors.MINTER1, Actors.MINTER2, id);
    }

    function test_safeTransferFrom_whileDisabled_reverts() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnershipNFT.TransfersDisabled.selector);
        nft.safeTransferFrom(Actors.MINTER1, Actors.MINTER2, id);
    }

    function test_approve_whileDisabled_reverts() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnershipNFT.TransfersDisabled.selector);
        nft.approve(Actors.MINTER2, id);
    }

    function test_setApprovalForAll_whileDisabled_reverts() public {
        _mint(Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnershipNFT.TransfersDisabled.selector);
        nft.setApprovalForAll(Actors.MINTER2, true);
    }

    function test_setApprovalForAll_revokeWhileDisabled_succeeds() public {
        _mint(Actors.MINTER1);

        vm.prank(Actors.ADMIN);
        nft.setTransfersEnabled(true);

        vm.prank(Actors.MINTER1);
        nft.setApprovalForAll(Actors.MINTER2, true);

        vm.prank(Actors.ADMIN);
        nft.setTransfersEnabled(false);

        // Revoking a stale operator approval must not be blocked by the soulbound gate.
        vm.prank(Actors.MINTER1);
        nft.setApprovalForAll(Actors.MINTER2, false);

        assertFalse(nft.isApprovedForAll(Actors.MINTER1, Actors.MINTER2));
    }

    function test_transferFrom_whenEnabled_succeeds() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.ADMIN);
        nft.setTransfersEnabled(true);

        vm.prank(Actors.MINTER1);
        nft.transferFrom(Actors.MINTER1, Actors.LP1, id);

        assertEq(nft.ownerOf(id), Actors.LP1);
        assertEq(nft.balanceOf(Actors.MINTER1), 0);
        assertEq(nft.balanceOf(Actors.LP1), 1);
    }

    function test_approveAndTransferFrom_whenEnabled_succeeds() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.ADMIN);
        nft.setTransfersEnabled(true);

        vm.prank(Actors.MINTER1);
        nft.approve(Actors.MINTER2, id);
        assertEq(nft.getApproved(id), Actors.MINTER2);

        vm.prank(Actors.MINTER2);
        nft.transferFrom(Actors.MINTER1, Actors.LP1, id);

        assertEq(nft.ownerOf(id), Actors.LP1);
    }

    function test_transferFrom_toExistingHolder_whenEnabled_succeeds() public {
        // One-per-wallet is enforced only at mint; transfers can stack once enabled.
        uint256 id1 = _mint(Actors.MINTER1);
        _mint(Actors.MINTER2);

        vm.prank(Actors.ADMIN);
        nft.setTransfersEnabled(true);

        vm.prank(Actors.MINTER1);
        nft.transferFrom(Actors.MINTER1, Actors.MINTER2, id1);

        assertEq(nft.balanceOf(Actors.MINTER2), 2);
    }

    function test_transferFrom_afterReDisable_reverts() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.startPrank(Actors.ADMIN);
        nft.setTransfersEnabled(true);
        nft.setTransfersEnabled(false);
        vm.stopPrank();

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnershipNFT.TransfersDisabled.selector);
        nft.transferFrom(Actors.MINTER1, Actors.MINTER2, id);
    }

    function test_mintTo_whileTransfersDisabled_succeeds() public {
        // Mints must pass the soulbound gate (transfers disabled by default in setUp).
        uint256 id = _mint(Actors.MINTER1);
        assertEq(nft.ownerOf(id), Actors.MINTER1);
    }

    // ──────────────────────────────────────────────────────────
    //  setTransfersEnabled
    // ──────────────────────────────────────────────────────────

    function test_setTransfersEnabled_setsFlagAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IOwnershipNFT.TransfersEnabled(true);

        vm.prank(Actors.ADMIN);
        nft.setTransfersEnabled(true);

        assertTrue(nft.transfersEnabled());
    }

    function test_setTransfersEnabled_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, DEFAULT_ADMIN_ROLE
            )
        );
        nft.setTransfersEnabled(true);
    }

    function test_setTransfersEnabled_minter_reverts() public {
        vm.prank(pointsService);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, pointsService, DEFAULT_ADMIN_ROLE
            )
        );
        nft.setTransfersEnabled(true);
    }

    // ──────────────────────────────────────────────────────────
    //  burn
    // ──────────────────────────────────────────────────────────

    function test_burn_admin_succeedsWhileTransfersDisabled() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(Actors.MINTER1, address(0), id);

        vm.prank(Actors.ADMIN);
        nft.burn(id);

        assertEq(nft.balanceOf(Actors.MINTER1), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);
    }

    function test_burn_nonAdmin_reverts() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, DEFAULT_ADMIN_ROLE
            )
        );
        nft.burn(id);
    }

    function test_burn_holder_reverts() public {
        uint256 id = _mint(Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.MINTER1, DEFAULT_ADMIN_ROLE
            )
        );
        nft.burn(id);
    }

    function test_burn_nonexistentToken_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        nft.burn(999);
    }

    // ──────────────────────────────────────────────────────────
    //  tokenURI / baseURI
    // ──────────────────────────────────────────────────────────

    function test_tokenURI_concatsBaseURIAndId() public {
        _mint(Actors.MINTER1);
        _mint(Actors.MINTER2);

        assertEq(nft.tokenURI(1), string.concat(BASE_URI, "1"));
        assertEq(nft.tokenURI(2), string.concat(BASE_URI, "2"));
    }

    function test_tokenURI_nonexistentToken_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.tokenURI(1);
    }

    function test_setBaseURI_updatesTokenURIAndEmits() public {
        _mint(Actors.MINTER1);
        string memory newBase = "https://points-v2.own.finance/metadata/";

        vm.expectEmit(true, true, true, true);
        emit IOwnershipNFT.BaseURIUpdated(newBase);

        vm.prank(Actors.ADMIN);
        nft.setBaseURI(newBase);

        assertEq(nft.baseURI(), newBase);
        assertEq(nft.tokenURI(1), string.concat(newBase, "1"));
    }

    function test_setBaseURI_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, DEFAULT_ADMIN_ROLE
            )
        );
        nft.setBaseURI("ipfs://nope/");
    }

    // ──────────────────────────────────────────────────────────
    //  contractURI
    // ──────────────────────────────────────────────────────────

    function test_contractURI_defaultsEmpty() public view {
        assertEq(nft.contractURI(), "");
    }

    function test_setContractURI_setsAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IOwnershipNFT.ContractURIUpdated(CONTRACT_URI);

        vm.prank(Actors.ADMIN);
        nft.setContractURI(CONTRACT_URI);

        assertEq(nft.contractURI(), CONTRACT_URI);
    }

    function test_setContractURI_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, DEFAULT_ADMIN_ROLE
            )
        );
        nft.setContractURI(CONTRACT_URI);
    }

    // ──────────────────────────────────────────────────────────
    //  Role rotation
    // ──────────────────────────────────────────────────────────

    function test_minterRotation_oldRevertsNewMints() public {
        address newMinter = makeAddr("newMinter");

        vm.startPrank(Actors.ADMIN);
        nft.grantRole(MINTER_ROLE, newMinter);
        nft.revokeRole(MINTER_ROLE, pointsService);
        vm.stopPrank();

        vm.prank(pointsService);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pointsService, MINTER_ROLE)
        );
        nft.mintTo(Actors.MINTER1);

        vm.prank(newMinter);
        uint256 id = nft.mintTo(Actors.MINTER1);
        assertEq(nft.ownerOf(id), Actors.MINTER1);
    }

    function test_grantRole_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, DEFAULT_ADMIN_ROLE
            )
        );
        nft.grantRole(MINTER_ROLE, Actors.ATTACKER);
    }

    // ──────────────────────────────────────────────────────────
    //  supportsInterface
    // ──────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertTrue(nft.supportsInterface(0x7965db0b)); // AccessControl
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC-165
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_mintTo_manyWallets_noIdCollisions(
        uint8 count
    ) public {
        uint256 n = bound(count, 1, 64);

        for (uint256 i; i < n; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode("fuzzWallet", i)))));
            uint256 id = _mint(to);

            assertEq(id, i + 1);
            assertEq(nft.ownerOf(id), to);
            assertEq(nft.balanceOf(to), 1);
        }

        assertEq(nft.nextTokenId(), n + 1);
    }

    function testFuzz_mintTo_arbitraryWallet(
        address to
    ) public {
        vm.assume(to != address(0));

        uint256 id = _mint(to);

        assertEq(id, 1);
        assertEq(nft.ownerOf(id), to);
        assertEq(nft.balanceOf(to), 1);

        // Second mint to the same wallet always reverts.
        vm.prank(pointsService);
        vm.expectRevert(abi.encodeWithSelector(IOwnershipNFT.AlreadyOwnsToken.selector, to));
        nft.mintTo(to);
    }
}
