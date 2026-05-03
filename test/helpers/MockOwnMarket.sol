// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEToken} from "../../src/interfaces/IEToken.sol";
import {Order, OrderStatus, OrderType, PRECISION} from "../../src/interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockOwnMarket — Minimal stub of OwnMarket for integration tests
/// @notice Records mint orders and lets test code force-confirm them. Pulls
///         payment token from the order placer at place time and (when
///         confirmed in the test harness) mints eTokens to the order user.
///         No oracle, no fee calculator, no VM logic.
contract MockOwnMarket {
    using SafeERC20 for IERC20;
    using Math for uint256;

    mapping(uint256 => Order) public orders;
    mapping(address => address) public eTokenOf; // asset → eToken address (test wiring).
    uint256 public nextId = 1;

    /// @notice Test-only: register the eToken contract that will be minted for
    ///         orders against `asset`.
    function registerEToken(bytes32 asset, address eToken) external {
        eTokenOf[bytes32ToAddrKey(asset)] = eToken;
    }

    function placeMintOrder(
        address vault,
        bytes32 asset,
        uint256 amount,
        uint256 price,
        uint256 expiry
    ) external returns (uint256 orderId) {
        orderId = nextId++;
        IERC20 paymentToken = IERC20(_getPaymentToken(vault));
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            orderType: OrderType.Mint,
            asset: asset,
            amount: amount,
            price: price,
            expiry: expiry,
            status: OrderStatus.Open,
            createdAt: block.timestamp,
            vm: address(0),
            vault: vault,
            claimedAt: 0
        });
    }

    /// @notice Test helper: force-confirm an order, minting the eToken amount
    ///         the LPBorrowManager would expect (no fee in this mock — fee
    ///         calculator returns 0 by default in tests).
    function forceConfirm(
        uint256 orderId
    ) external {
        Order storage o = orders[orderId];
        o.status = OrderStatus.Confirmed;
        // Reproduce OwnMarket's mint-amount formula (no fee).
        address paymentToken = _getPaymentToken(o.vault);
        uint256 decimals = IERC20Metadata(paymentToken).decimals();
        uint256 decimalScaler = 10 ** (18 - decimals);
        uint256 mintedAmount = (o.amount * decimalScaler).mulDiv(PRECISION, o.price);
        address eToken = eTokenOf[bytes32ToAddrKey(o.asset)];
        IEToken(eToken).mint(o.user, mintedAmount);
    }

    function getOrder(
        uint256 orderId
    ) external view returns (Order memory) {
        return orders[orderId];
    }

    function _getPaymentToken(
        address vault
    ) internal view returns (address) {
        // Calls through to OwnVault.paymentToken(); kept loose to avoid
        // pulling in the full IOwnVault here.
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("paymentToken()"));
        require(ok, "MockOwnMarket: paymentToken read failed");
        return abi.decode(data, (address));
    }

    /// @dev Cheap hash from bytes32 ticker → address-shaped key so we can index
    ///      a mapping without colliding identifiers.
    function bytes32ToAddrKey(
        bytes32 b
    ) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }
}
