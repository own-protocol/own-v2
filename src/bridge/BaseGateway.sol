// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseGateway} from "../interfaces/IBaseGateway.sol";

import {ICcipWrappedToken} from "../interfaces/ICcipWrappedToken.sol";
import {IAcrossSpokePool} from "../interfaces/external/IAcrossSpokePool.sol";
import {CcipClient, IAny2EVMMessageReceiver, ICcipRouter} from "../interfaces/external/ICcip.sol";
import {GatewayFloat} from "./GatewayFloat.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseGateway — sells fund exit legs on Base and bridges the USDC back as USDG
/// @notice See {IBaseGateway}.
contract BaseGateway is IBaseGateway, IAny2EVMMessageReceiver, IERC165, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_FEE_BPS = 1000;
    uint32 private constant MIN_FILL_WINDOW = 10 minutes;
    uint256 private constant CLAIM_ONLY = type(uint256).max;
    /// @notice Gas for the mint gateway's `ccipReceive` (one stock update).
    uint256 public constant RESTOCK_GAS_LIMIT = 200_000;

    /// @notice The CCIP Router on Base.
    address public immutable ccipRouter;
    /// @notice CCIP selector of Robinhood Chain.
    uint64 public immutable remoteSelector;
    /// @notice USDC on Base.
    address public immutable usdc;
    /// @notice The Across SpokePool on Base.
    address public immutable spokePool;
    /// @notice EVM chain id of Robinhood Chain.
    uint256 public immutable remoteChainId;
    /// @notice USDG on Robinhood Chain (the Across output token).
    address public immutable remoteUsdg;
    /// @inheritdoc IBaseGateway
    address public immutable override revenueFloat;

    /// @inheritdoc IBaseGateway
    address public override remoteGateway;
    /// @notice Bridge fee cap as a share of the USDC bridged.
    uint256 public maxFeeBps;
    /// @notice Bridge fee cap in USDC; the larger cap applies.
    uint256 public maxFeeFlat;
    /// @notice Seconds a relayer has to fill before the deposit refunds to the receiver on Base.
    uint32 public fillWindow;
    /// @notice The Robinhood mint gateway restocks go to.
    address public remoteMintGateway;

    mapping(bytes32 => Order) private _orders;
    mapping(address => bool) private _keepers;
    mapping(address => bool) private _routers;
    mapping(address => bool) private _wrappers;

    modifier onlyRouter() {
        if (msg.sender != ccipRouter) revert NotRouter();
        _;
    }

    /// @param owner_          Owner (the Base Safe).
    /// @param ccipRouter_     The CCIP Router on Base.
    /// @param remoteSelector_ CCIP selector of Robinhood Chain.
    /// @param usdc_           USDC on Base.
    /// @param spokePool_      The Across SpokePool on Base.
    /// @param remoteChainId_  EVM chain id of Robinhood Chain.
    /// @param remoteUsdg_     USDG on Robinhood Chain.
    constructor(
        address owner_,
        address ccipRouter_,
        uint64 remoteSelector_,
        address usdc_,
        address spokePool_,
        uint256 remoteChainId_,
        address remoteUsdg_
    ) Ownable(owner_) {
        if (
            ccipRouter_ == address(0) || usdc_ == address(0) || spokePool_ == address(0) || remoteUsdg_ == address(0)
                || remoteSelector_ == 0 || remoteChainId_ == 0
        ) revert ZeroAddress();
        ccipRouter = ccipRouter_;
        remoteSelector = remoteSelector_;
        usdc = usdc_;
        spokePool = spokePool_;
        remoteChainId = remoteChainId_;
        remoteUsdg = remoteUsdg_;
        maxFeeBps = 50;
        maxFeeFlat = 2e6;
        fillWindow = 4 hours;
        revenueFloat = address(new GatewayFloat());
    }

    /// @notice Records each delivered token as an order for its receiver.
    /// @dev Never reverts for a router delivery, so the CCIP transfer always lands, except one re-entered
    ///      from inside a call here (the message then stays open for manual execution). Only a message from
    ///      {remoteGateway} on Robinhood Chain carrying `abi.encode(receiver, minOut)` becomes a sellable
    ///      order; anything else is held claim-only for the sender's address.
    /// @param message The CCIP message.
    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external override onlyRouter nonReentrant {
        (address receiver, uint256 minOut) = _parse(message);
        if (receiver == address(0)) return;
        uint256 n = message.destTokenAmounts.length;
        for (uint256 i; i < n; ++i) {
            address token = message.destTokenAmounts[i].token;
            uint256 amount = message.destTokenAmounts[i].amount;
            if (amount == 0) continue;
            if (_wrappers[token]) (token, amount) = _tryUnwrap(token, amount);
            bytes32 id = orderId(message.messageId, i);
            _orders[id] =
                Order({receiver: receiver, status: Status.Pending, token: token, amount: amount, minOut: minOut});
            emit OrderReceived(id, message.messageId, receiver, token, amount, minOut);
        }
    }

    /// @inheritdoc IBaseGateway
    function settle(
        bytes32 id,
        Swap calldata swap,
        uint256 outputAmount,
        uint32 quoteTimestamp
    ) external override nonReentrant {
        Order storage o = _orders[id];
        if (o.status != Status.Pending) revert NotPending();
        address receiver = o.receiver;
        if (!_keepers[msg.sender] && msg.sender != receiver) revert NotKeeper();
        uint256 minOut = o.minOut;
        if (minOut == CLAIM_ONLY) revert ClaimOnly();
        address token = o.token;
        uint256 amount = o.amount;
        o.status = Status.Settled;

        uint256 usdcIn = token == usdc ? amount : _sell(token, amount, swap);
        if (outputAmount < minOut) revert Slippage();
        if (outputAmount > usdcIn) revert OutputTooHigh();
        uint256 cap = Math.max(maxFeeFlat, usdcIn * maxFeeBps / BPS);
        if (usdcIn - outputAmount > cap) revert BridgeFeeTooHigh();

        _deposit(receiver, usdcIn, outputAmount, quoteTimestamp);

        emit OrderSettled(id, receiver, usdcIn, outputAmount, msg.sender);
    }

    /// @inheritdoc IBaseGateway
    function claim(bytes32 id, address to) external override nonReentrant {
        Order storage o = _orders[id];
        if (o.status != Status.Pending) revert NotPending();
        if (msg.sender != o.receiver) revert NotReceiver();
        if (to == address(0)) revert ZeroAddress();
        o.status = Status.Claimed;
        IERC20(o.token).safeTransfer(to, o.amount);
        emit OrderClaimed(id, to, o.token, o.amount);
    }

    /// @inheritdoc IBaseGateway
    function updateMinOut(bytes32 id, uint256 minOut) external override {
        Order storage o = _orders[id];
        if (o.status != Status.Pending) revert NotPending();
        if (msg.sender != o.receiver) revert NotReceiver();
        if (o.minOut == CLAIM_ONLY || minOut == CLAIM_ONLY) revert ClaimOnly();
        o.minOut = minOut;
        emit MinOutUpdated(id, minOut);
    }

    /// @inheritdoc IBaseGateway
    function buyAndWrap(
        address wrapper,
        uint256 usdcIn,
        Swap calldata swap,
        uint256 minOut,
        address receiver
    ) external override nonReentrant returns (uint256 out) {
        if (!_wrappers[wrapper]) revert WrapperNotAllowed();
        if (receiver == address(0) || usdcIn == 0) revert ZeroAddress();
        IERC20 u = IERC20(usdc);
        IERC20 underlying = ERC20Wrapper(wrapper).underlying();

        uint256 usdcBefore = u.balanceOf(address(this));
        uint256 underBefore = underlying.balanceOf(address(this));
        u.safeTransferFrom(msg.sender, address(this), usdcIn);
        _call(address(u), usdcIn, swap);
        uint256 usdcLeft = u.balanceOf(address(this)) - usdcBefore;
        out = underlying.balanceOf(address(this)) - underBefore;
        if (out < minOut || out == 0) revert Slippage();

        underlying.forceApprove(wrapper, out);
        ICcipWrappedToken(wrapper).depositFor(receiver, out);
        underlying.forceApprove(wrapper, 0);
        if (usdcLeft != 0) u.safeTransfer(msg.sender, usdcLeft);

        emit BoughtAndWrapped(wrapper, msg.sender, receiver, usdcIn - usdcLeft, out);
    }

    /// @inheritdoc IBaseGateway
    function unwrapAndSell(
        address wrapper,
        uint256 amount,
        Swap calldata swap,
        uint256 minUsdcOut,
        address receiver
    ) external override nonReentrant returns (uint256 usdcOut) {
        if (!_wrappers[wrapper]) revert WrapperNotAllowed();
        if (receiver == address(0) || amount == 0) revert ZeroAddress();
        IERC20 u = IERC20(usdc);
        IERC20 underlying = ERC20Wrapper(wrapper).underlying();

        uint256 usdcBefore = u.balanceOf(address(this));
        uint256 underBefore = underlying.balanceOf(address(this));
        IERC20(wrapper).safeTransferFrom(msg.sender, address(this), amount);
        ICcipWrappedToken(wrapper).withdrawTo(address(this), amount);
        if (underlying.balanceOf(address(this)) - underBefore != amount) revert UnwrapFailed();
        _call(address(underlying), amount, swap);
        uint256 underLeft = underlying.balanceOf(address(this)) - underBefore;
        usdcOut = u.balanceOf(address(this)) - usdcBefore;
        if (usdcOut < minUsdcOut) revert Slippage();

        if (usdcOut != 0) u.safeTransfer(receiver, usdcOut);
        if (underLeft != 0) underlying.safeTransfer(receiver, underLeft);

        emit UnwrappedAndSold(wrapper, msg.sender, receiver, amount, usdcOut);
    }

    /// @inheritdoc IBaseGateway
    function restock(
        address wrapper,
        uint256 usdcIn,
        Swap calldata swap,
        uint256 minOut
    ) external payable override nonReentrant returns (bytes32 messageId) {
        if (!_keepers[msg.sender]) revert NotKeeper();
        if (!_wrappers[wrapper]) revert WrapperNotAllowed();
        address mintGateway = remoteMintGateway;
        if (mintGateway == address(0) || usdcIn == 0) revert ZeroAddress();
        if (usdcIn > freeUsdc()) revert InsufficientUsdc();

        GatewayFloat(revenueFloat).pay(usdc, address(this), usdcIn);
        (uint256 spent, uint256 out) = _buyWrapped(wrapper, usdcIn, swap, minOut);
        if (spent > usdcIn) revert InsufficientUsdc();
        if (spent != usdcIn) IERC20(usdc).safeTransfer(revenueFloat, usdcIn - spent);
        uint256 fee;
        (messageId, fee) = _sendRestock(wrapper, out, mintGateway);
        emit Restocked(messageId, wrapper, spent, out, fee);

        uint256 refund = msg.value - fee;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IBaseGateway
    function setRemoteMintGateway(
        address gateway
    ) external override onlyOwner {
        if (gateway == address(0)) revert ZeroAddress();
        remoteMintGateway = gateway;
        emit RemoteMintGatewaySet(gateway);
    }

    /// @inheritdoc IBaseGateway
    function setRemoteGateway(
        address gateway
    ) external override onlyOwner {
        if (gateway == address(0)) revert ZeroAddress();
        remoteGateway = gateway;
        emit RemoteGatewaySet(gateway);
    }

    /// @inheritdoc IBaseGateway
    function setKeeper(address keeper, bool allowed) external override onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        _keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @inheritdoc IBaseGateway
    function setRouter(address router, bool allowed) external override onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        if (
            allowed
                && (
                    router == usdc || router == spokePool || router == ccipRouter || router == revenueFloat
                        || _wrappers[router]
                )
        ) {
            revert InvalidParam();
        }
        _routers[router] = allowed;
        emit RouterSet(router, allowed);
    }

    /// @inheritdoc IBaseGateway
    function setWrapper(address wrapper, bool allowed) external override onlyOwner {
        if (wrapper == address(0)) revert ZeroAddress();
        if (allowed && _routers[wrapper]) revert InvalidParam();
        _wrappers[wrapper] = allowed;
        emit WrapperSet(wrapper, allowed);
    }

    /// @inheritdoc IBaseGateway
    function setBridgeFeeCap(uint256 maxFeeBps_, uint256 maxFeeFlat_) external override onlyOwner {
        if (maxFeeBps_ > MAX_FEE_BPS) revert InvalidParam();
        maxFeeBps = maxFeeBps_;
        maxFeeFlat = maxFeeFlat_;
        emit BridgeFeeCapSet(maxFeeBps_, maxFeeFlat_);
    }

    /// @inheritdoc IBaseGateway
    function setFillWindow(
        uint32 fillWindow_
    ) external override onlyOwner {
        if (fillWindow_ < MIN_FILL_WINDOW || fillWindow_ > IAcrossSpokePool(spokePool).fillDeadlineBuffer()) {
            revert InvalidParam();
        }
        fillWindow = fillWindow_;
        emit FillWindowSet(fillWindow_);
    }

    /// @inheritdoc IBaseGateway
    function withdrawFloat(address token, address to, uint256 amount) external override onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        GatewayFloat(revenueFloat).pay(token, to, amount);
        emit FloatWithdrawn(token, to, amount);
    }

    /// @inheritdoc IBaseGateway
    function freeUsdc() public view override returns (uint256) {
        return IERC20(usdc).balanceOf(revenueFloat);
    }

    /// @inheritdoc IBaseGateway
    function getOrder(
        bytes32 id
    ) external view override returns (Order memory) {
        return _orders[id];
    }

    /// @inheritdoc IBaseGateway
    function isKeeper(
        address keeper
    ) external view override returns (bool) {
        return _keepers[keeper];
    }

    /// @inheritdoc IBaseGateway
    function isRouter(
        address router
    ) external view override returns (bool) {
        return _routers[router];
    }

    /// @inheritdoc IBaseGateway
    function isWrapper(
        address wrapper
    ) external view override returns (bool) {
        return _wrappers[wrapper];
    }

    /// @notice ERC-165: the CCIP OffRamp only calls `ccipReceive` on contracts that report it.
    /// @param interfaceId The interface id.
    /// @return True for IAny2EVMMessageReceiver and IERC165.
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBaseGateway
    function orderId(bytes32 messageId, uint256 index) public pure override returns (bytes32) {
        return keccak256(abi.encode(messageId, index));
    }

    function _buyWrapped(
        address wrapper,
        uint256 usdcIn,
        Swap calldata swap,
        uint256 minOut
    ) internal returns (uint256 spent, uint256 out) {
        IERC20 u = IERC20(usdc);
        IERC20 underlying = ERC20Wrapper(wrapper).underlying();
        uint256 usdcBefore = u.balanceOf(address(this));
        uint256 underBefore = underlying.balanceOf(address(this));
        _call(address(u), usdcIn, swap);
        spent = usdcBefore - u.balanceOf(address(this));
        out = underlying.balanceOf(address(this)) - underBefore;
        if (out < minOut || out == 0) revert Slippage();
        underlying.forceApprove(wrapper, out);
        ICcipWrappedToken(wrapper).depositFor(address(this), out);
        underlying.forceApprove(wrapper, 0);
    }

    function _sendRestock(
        address wrapper,
        uint256 amount,
        address to
    ) internal returns (bytes32 messageId, uint256 fee) {
        CcipClient.EVM2AnyMessage memory message = _restockMessage(wrapper, amount, to);
        ICcipRouter ccip = ICcipRouter(ccipRouter);
        fee = ccip.getFee(remoteSelector, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);
        IERC20(wrapper).forceApprove(address(ccip), amount);
        messageId = ccip.ccipSend{value: fee}(remoteSelector, message);
        IERC20(wrapper).forceApprove(address(ccip), 0);
    }

    function _restockMessage(
        address wrapper,
        uint256 amount,
        address to
    ) internal pure returns (CcipClient.EVM2AnyMessage memory message) {
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: wrapper, amount: amount});
        message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(to),
            data: "",
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: CcipClient.encodeExtraArgs(
                CcipClient.GenericExtraArgsV2({gasLimit: RESTOCK_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });
    }

    function _sell(address token, uint256 amount, Swap calldata swap) internal returns (uint256 usdcIn) {
        IERC20 u = IERC20(usdc);
        uint256 usdcBefore = u.balanceOf(address(this));
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        _call(token, amount, swap);
        if (tokenBefore - IERC20(token).balanceOf(address(this)) != amount) revert PartialFill();
        usdcIn = u.balanceOf(address(this)) - usdcBefore;
    }

    function _deposit(address receiver, uint256 usdcIn, uint256 outputAmount, uint32 quoteTimestamp) internal {
        address pool = spokePool;
        IERC20(usdc).forceApprove(pool, usdcIn);
        IAcrossSpokePool(pool).depositV3(
            receiver,
            receiver,
            usdc,
            remoteUsdg,
            usdcIn,
            outputAmount,
            remoteChainId,
            address(0),
            quoteTimestamp,
            uint32(block.timestamp) + fillWindow,
            0,
            ""
        );
        IERC20(usdc).forceApprove(pool, 0);
    }

    function _call(address tokenIn, uint256 amount, Swap calldata swap) internal {
        address target = swap.router;
        if (!_routers[target]) revert RouterNotAllowed();
        IERC20(tokenIn).forceApprove(target, amount);
        (bool ok,) = target.call(swap.data);
        if (!ok) revert SwapFailed();
        IERC20(tokenIn).forceApprove(target, 0);
    }

    // Low-level so a wrapper that can't unwrap (its underlying frozen or paused) leaves the order in the wrapper.
    function _tryUnwrap(address wrapper, uint256 amount) internal returns (address, uint256) {
        (bool okU, bytes memory ret) = wrapper.staticcall(abi.encodeCall(ERC20Wrapper.underlying, ()));
        if (!okU || ret.length != 32) return (wrapper, amount);
        address underlying = abi.decode(ret, (address));
        (bool okB, bytes memory b) = underlying.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!okB || b.length != 32) return (wrapper, amount);
        uint256 before = abi.decode(b, (uint256));
        (bool ok,) = wrapper.call(abi.encodeCall(ICcipWrappedToken.withdrawTo, (address(this), amount)));
        if (!ok) return (wrapper, amount);
        if (IERC20(underlying).balanceOf(address(this)) - before != amount) return (wrapper, amount);
        return (underlying, amount);
    }

    function _parse(
        CcipClient.Any2EVMMessage calldata message
    ) internal view returns (address receiver, uint256 minOut) {
        address sender = _word(message.sender);
        address remote = remoteGateway;
        if (message.sourceChainSelector == remoteSelector && remote != address(0) && sender == remote) {
            if (message.data.length == 64) {
                (uint256 r, uint256 m) = abi.decode(message.data, (uint256, uint256));
                if (r != 0 && r <= type(uint160).max && m != CLAIM_ONLY) return (address(uint160(r)), m);
            }
        }
        return (sender, CLAIM_ONLY);
    }

    function _word(
        bytes calldata data
    ) internal pure returns (address) {
        if (data.length != 32) return address(0);
        uint256 w = abi.decode(data, (uint256));
        return w <= type(uint160).max ? address(uint160(w)) : address(0);
    }
}
