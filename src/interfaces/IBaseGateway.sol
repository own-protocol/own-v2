// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IBaseGateway — Base side of the fund cash-out and of the mint-gateway restock, plus manual swaps
/// @notice Cash-out: the Robinhood {IFundExitGateway} sends a basket asset (rZEC, rHYPE, ...) over CCIP.
///         On arrival this contract unwraps an allowed wrapper to its underlying (cbZEC, cbHYPE) and
///         records an order for the receiver. A keeper (or the receiver) then sells the order to USDC
///         through an admin-allowed router and deposits the USDC into Across, which pays the receiver
///         USDG on Robinhood Chain. The sale must pay at least the receiver's minimum after the bridge
///         fee, and the bridge fee is capped. Until it is settled the receiver may lower the minimum or
///         claim the asset on Base instead. A message from any other sender is held for the sender to
///         claim and is never sold.
///
///         Restock: USDC the Robinhood mint gateway bridges over Across lands in {revenueFloat}, a separate
///         contract, never here. A keeper spends it on an allowed wrapper's underlying, wraps it and sends
///         it over CCIP to the mint gateway's stock.
///
///         Manual options: buy an allowed wrapper with USDC, or unwrap and sell it for USDC, in one
///         transaction each. These measure balance changes, so they never touch orders held here.
interface IBaseGateway {
    /// @notice Order state.
    enum Status {
        None,
        Pending,
        Settled,
        Claimed
    }

    /// @notice A bridged asset held for its receiver.
    /// @param receiver Owner: receives the USDG on Robinhood Chain, or the asset on Base on a claim.
    /// @param status   State.
    /// @param token    Asset held (the underlying once unwrapped, else the delivered token).
    /// @param amount   Amount held.
    /// @param minOut   Minimum USDG (6 decimals) the receiver must get on Robinhood Chain;
    ///                 `type(uint256).max` marks a claim-only order.
    struct Order {
        address receiver;
        Status status;
        address token;
        uint256 amount;
        uint256 minOut;
    }

    /// @notice A router call.
    /// @param router Admin-allowed router.
    /// @param data   Router calldata; the router is approved for exactly the amount being sold.
    struct Swap {
        address router;
        bytes data;
    }

    /// @notice Emitted when an order is recorded.
    /// @param id        Order id ({orderId} of the CCIP message and token index).
    /// @param messageId CCIP message id.
    /// @param receiver  Owner.
    /// @param token     Asset held.
    /// @param amount    Amount held.
    /// @param minOut    Minimum USDG for the receiver.
    event OrderReceived(
        bytes32 indexed id,
        bytes32 indexed messageId,
        address indexed receiver,
        address token,
        uint256 amount,
        uint256 minOut
    );

    /// @notice Emitted when an order is sold and bridged.
    /// @param id        Order id.
    /// @param receiver  Receiver of the USDG on Robinhood Chain.
    /// @param usdcIn    USDC from the sale, all deposited into Across.
    /// @param usdgOut   USDG the Across fill pays.
    /// @param caller    Keeper or receiver that settled it.
    event OrderSettled(
        bytes32 indexed id, address indexed receiver, uint256 usdcIn, uint256 usdgOut, address indexed caller
    );

    /// @notice Emitted when the receiver takes the asset on Base.
    /// @param id     Order id.
    /// @param to     Recipient.
    /// @param token  Asset.
    /// @param amount Amount.
    event OrderClaimed(bytes32 indexed id, address indexed to, address token, uint256 amount);

    /// @notice Emitted when the receiver changes an order's minimum.
    /// @param id     Order id.
    /// @param minOut New minimum.
    event MinOutUpdated(bytes32 indexed id, uint256 minOut);

    /// @notice Emitted on a buy of a wrapper with USDC.
    /// @param wrapper  The wrapper.
    /// @param sender   Payer.
    /// @param receiver Receiver of the wrapper.
    /// @param usdcIn   USDC spent.
    /// @param out      Wrapper minted.
    event BoughtAndWrapped(
        address indexed wrapper, address indexed sender, address indexed receiver, uint256 usdcIn, uint256 out
    );

    /// @notice Emitted on a sale of a wrapper for USDC.
    /// @param wrapper  The wrapper.
    /// @param sender   Seller.
    /// @param receiver Receiver of the USDC.
    /// @param amount   Wrapper unwrapped.
    /// @param usdcOut  USDC paid.
    event UnwrappedAndSold(
        address indexed wrapper, address indexed sender, address indexed receiver, uint256 amount, uint256 usdcOut
    );

    /// @notice Emitted when the keeper restocks the Robinhood mint gateway.
    /// @param messageId CCIP message id.
    /// @param wrapper   The wrapper sent.
    /// @param usdcIn    USDC spent.
    /// @param amount    Wrapper sent.
    /// @param fee       CCIP fee paid, in native gas.
    event Restocked(bytes32 indexed messageId, address indexed wrapper, uint256 usdcIn, uint256 amount, uint256 fee);

    /// @notice Emitted when the Robinhood mint gateway is set.
    /// @param gateway The gateway.
    event RemoteMintGatewaySet(address gateway);

    /// @notice Emitted when the Robinhood exit gateway is set.
    /// @param gateway The gateway.
    event RemoteGatewaySet(address gateway);

    /// @notice Emitted when a keeper is allowed or removed.
    /// @param keeper  The keeper.
    /// @param allowed Whether it may settle orders.
    event KeeperSet(address indexed keeper, bool allowed);

    /// @notice Emitted when a router is allowed or removed.
    /// @param router  The router.
    /// @param allowed Whether swaps may go through it.
    event RouterSet(address indexed router, bool allowed);

    /// @notice Emitted when a wrapper is allowed or removed.
    /// @param wrapper The wrapper.
    /// @param allowed Whether it is unwrapped on arrival and tradable through the manual options.
    event WrapperSet(address indexed wrapper, bool allowed);

    /// @notice Emitted when the bridge fee cap changes.
    /// @param maxFeeBps  Cap as a share of the USDC bridged.
    /// @param maxFeeFlat Cap in USDC; the larger of the two applies.
    event BridgeFeeCapSet(uint256 maxFeeBps, uint256 maxFeeFlat);

    /// @notice Emitted when the owner takes tokens out of the float.
    /// @param token  The token.
    /// @param to     Recipient.
    /// @param amount Amount.
    event FloatWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the Across fill window changes.
    /// @param fillWindow Seconds a relayer has to fill before the deposit refunds to the receiver on Base.
    event FillWindowSet(uint32 fillWindow);

    /// @notice Caller is not the CCIP Router.
    error NotRouter();

    /// @notice Caller may not settle this order.
    error NotKeeper();

    /// @notice Caller is not the order's receiver.
    error NotReceiver();

    /// @notice The order is not pending.
    error NotPending();

    /// @notice The order can only be claimed.
    error ClaimOnly();

    /// @notice A router is not allowed.
    error RouterNotAllowed();

    /// @notice The wrapper is not allowed.
    error WrapperNotAllowed();

    /// @notice A router call failed.
    error SwapFailed();

    /// @notice A swap did not spend exactly the order amount.
    error PartialFill();

    /// @notice Output is below the minimum.
    error Slippage();

    /// @notice The Across output exceeds the USDC deposited.
    error OutputTooHigh();

    /// @notice The bridge fee is above the cap.
    error BridgeFeeTooHigh();

    /// @notice Unwrapping did not pay out the full underlying amount.
    error UnwrapFailed();

    /// @notice A required address or amount is zero.
    error ZeroAddress();

    /// @notice A parameter is out of range.
    error InvalidParam();

    /// @notice The float does not cover the amount.
    error InsufficientUsdc();

    /// @notice The native value sent does not cover the CCIP fee.
    /// @param required Fee owed.
    /// @param provided Native value sent.
    error InsufficientFee(uint256 required, uint256 provided);

    /// @notice Refunding the excess native value failed.
    error RefundFailed();

    /// @notice Sell a pending order to USDC and bridge it to the receiver as USDG on Robinhood Chain.
    /// @param id             Order id.
    /// @param swap           Sale of the order's token for USDC (ignored when the token is USDC).
    /// @param outputAmount   USDG the Across relayer pays (from a fresh Across quote).
    /// @param quoteTimestamp Timestamp of that quote.
    function settle(bytes32 id, Swap calldata swap, uint256 outputAmount, uint32 quoteTimestamp) external;

    /// @notice Take a pending order's asset on Base instead of the USDG.
    /// @param id Order id.
    /// @param to Recipient.
    function claim(bytes32 id, address to) external;

    /// @notice Change a pending order's minimum (receiver only), e.g. to accept a lower price.
    /// @param id     Order id.
    /// @param minOut New minimum USDG.
    function updateMinOut(bytes32 id, uint256 minOut) external;

    /// @notice Buy an allowed wrapper's underlying with USDC and wrap it, in one transaction.
    /// @param wrapper  The wrapper (rZEC, rHYPE).
    /// @param usdcIn   USDC pulled from the caller; any the router leaves is refunded.
    /// @param swap     Purchase of the underlying with USDC.
    /// @param minOut   Minimum wrapper out.
    /// @param receiver Receiver of the wrapper.
    /// @return out Wrapper minted.
    function buyAndWrap(
        address wrapper,
        uint256 usdcIn,
        Swap calldata swap,
        uint256 minOut,
        address receiver
    ) external returns (uint256 out);

    /// @notice Unwrap an allowed wrapper and sell the underlying for USDC, in one transaction.
    /// @param wrapper    The wrapper.
    /// @param amount     Wrapper pulled from the caller.
    /// @param swap       Sale of the underlying for USDC; any underlying it leaves goes to the receiver.
    /// @param minUsdcOut Minimum USDC out.
    /// @param receiver   Receiver of the USDC.
    /// @return usdcOut USDC paid.
    function unwrapAndSell(
        address wrapper,
        uint256 amount,
        Swap calldata swap,
        uint256 minUsdcOut,
        address receiver
    ) external returns (uint256 usdcOut);

    /// @notice Restock the Robinhood mint gateway (keeper): buy an allowed wrapper's underlying with USDC
    ///         from the float (bridged from Robinhood Chain), wrap it and send it over CCIP. The keeper pays
    ///         the CCIP fee; any excess is refunded.
    /// @param wrapper The wrapper (rZEC, rHYPE).
    /// @param usdcIn  USDC taken from the float; any the router leaves goes back to it.
    /// @param swap    Purchase of the underlying with USDC.
    /// @param minOut  Minimum wrapper sent.
    /// @return messageId CCIP message id.
    function restock(
        address wrapper,
        uint256 usdcIn,
        Swap calldata swap,
        uint256 minOut
    ) external payable returns (bytes32 messageId);

    /// @notice Set the Robinhood mint gateway that restocks go to (owner).
    /// @param gateway The gateway.
    function setRemoteMintGateway(
        address gateway
    ) external;

    /// @notice USDC in the float, free for restocks.
    /// @return Amount.
    function freeUsdc() external view returns (uint256);

    /// @notice The contract the mint gateway's revenue bridge pays on Base.
    /// @return The float.
    function revenueFloat() external view returns (address);

    /// @notice Take tokens out of the float (owner).
    /// @param token  The token.
    /// @param to     Recipient.
    /// @param amount Amount.
    function withdrawFloat(address token, address to, uint256 amount) external;

    /// @notice Set the Robinhood exit gateway whose messages become sellable orders (owner).
    /// @param gateway The gateway.
    function setRemoteGateway(
        address gateway
    ) external;

    /// @notice Allow or remove a keeper (owner).
    /// @param keeper  The keeper.
    /// @param allowed Whether it may settle orders.
    function setKeeper(address keeper, bool allowed) external;

    /// @notice Allow or remove a router (owner).
    /// @param router  The router.
    /// @param allowed Whether swaps may go through it.
    function setRouter(address router, bool allowed) external;

    /// @notice Allow or remove a wrapper (owner).
    /// @param wrapper The wrapper.
    /// @param allowed Whether it is unwrapped on arrival and tradable through the manual options.
    function setWrapper(address wrapper, bool allowed) external;

    /// @notice Set the bridge fee cap (owner).
    /// @param maxFeeBps  Cap as a share of the USDC bridged (at most 10%).
    /// @param maxFeeFlat Cap in USDC; the larger of the two applies.
    function setBridgeFeeCap(uint256 maxFeeBps, uint256 maxFeeFlat) external;

    /// @notice Set the Across fill window (owner).
    /// @param fillWindow Seconds, at least 10 minutes and within the SpokePool's buffer.
    function setFillWindow(
        uint32 fillWindow
    ) external;

    /// @notice An order.
    /// @param id Order id.
    /// @return The order.
    function getOrder(
        bytes32 id
    ) external view returns (Order memory);

    /// @notice Id of the order for token `index` of CCIP message `messageId`.
    /// @param messageId CCIP message id.
    /// @param index     Token index in the message (0 for an exit leg).
    /// @return The order id.
    function orderId(bytes32 messageId, uint256 index) external pure returns (bytes32);

    /// @notice The Robinhood exit gateway.
    /// @return The gateway.
    function remoteGateway() external view returns (address);

    /// @notice Whether `keeper` may settle orders.
    /// @param keeper The address.
    /// @return True if allowed.
    function isKeeper(
        address keeper
    ) external view returns (bool);

    /// @notice Whether `router` is allowed.
    /// @param router The address.
    /// @return True if allowed.
    function isRouter(
        address router
    ) external view returns (bool);

    /// @notice Whether `wrapper` is allowed.
    /// @param wrapper The address.
    /// @return True if allowed.
    function isWrapper(
        address wrapper
    ) external view returns (bool);
}
