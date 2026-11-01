// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMoneyFeeCollector} from "./interfaces/IMoneyFeeCollector.sol";
import {IPonsFeeEscrowV2} from "./interfaces/IPonsFeeEscrowV2.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MoneyFeeCollector — $MONEY fee routing and buy-back
/// @notice See {IMoneyFeeCollector}. Registered as the fee recipient of the $MONEY pair in the
///         Pons V2 fee escrow.
/// @dev Runs behind an ERC-1967 proxy (UUPS) so the escrow-credited address survives upgrades.
///      Storage is append-only across upgrades. The owner (protocol Safe, two-step handover) is
///      fully trusted: it upgrades, configures and can {execute} arbitrary calls. Keepers only
///      choose when to buy back and the slippage bound (`minMoneyOut`); each buy-back spends
///      exactly `burnSpendBps` of the held balance through an allow-listed target, which caps a
///      compromised keeper to that slice per interval.
contract MoneyFeeCollector is IMoneyFeeCollector, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Marker for the chain's native coin in `token` parameters and events.
    address private constant NATIVE = address(0);

    /// @dev Basis-point denominator (10 000 = 100%).
    uint256 private constant BPS = 10_000;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IMoneyFeeCollector
    address public override owner;

    /// @inheritdoc IMoneyFeeCollector
    address public override pendingOwner;

    /// @dev Fee escrow claimed from. Owner-settable.
    IPonsFeeEscrowV2 private _escrow;

    /// @dev The $MONEY token. Set once at initialization.
    ERC20Burnable private _money;

    /// @inheritdoc IMoneyFeeCollector
    uint256 public override burnShareBps;

    /// @inheritdoc IMoneyFeeCollector
    uint256 public override burnSpendBps;

    /// @inheritdoc IMoneyFeeCollector
    uint256 public override burnInterval;

    /// @inheritdoc IMoneyFeeCollector
    uint256 public override lastBurnAt;

    /// @inheritdoc IMoneyFeeCollector
    mapping(address => bool) public override isKeeper;

    /// @inheritdoc IMoneyFeeCollector
    mapping(address => bool) public override isSwapTarget;

    /// @dev Distribution payee set; shares sum to exactly BPS (validated in {setPayees}).
    Payee[] private _payees;

    /// @inheritdoc IMoneyFeeCollector
    address public override reserve;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev Reverts unless the caller is the owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Reverts unless the caller is an enabled keeper.
    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev Locks the implementation's initializers; it is only used behind a proxy.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy (called once, in the proxy's constructor).
    /// @param owner_   Contract owner (the protocol Safe).
    /// @param escrow_  Pons V2 fee escrow to claim from.
    /// @param money_   The $MONEY token.
    /// @param keeper_  Initial buy-back keeper (zero = none).
    /// @param payees_  Initial payee set (may be empty while no distribution share is collected).
    function initialize(
        address owner_,
        address escrow_,
        address money_,
        address keeper_,
        Payee[] calldata payees_
    ) external initializer {
        if (owner_ == address(0) || escrow_ == address(0) || money_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        _escrow = IPonsFeeEscrowV2(escrow_);
        emit EscrowSet(escrow_);
        _money = ERC20Burnable(money_);
        burnShareBps = 3000;
        emit BurnShareSet(3000);
        burnSpendBps = 1000;
        emit BurnSpendSet(1000);
        burnInterval = 1 hours;
        emit BurnIntervalSet(1 hours);
        if (keeper_ != address(0)) {
            isKeeper[keeper_] = true;
            emit KeeperSet(keeper_, true);
        }
        _setPayees(payees_);
    }

    /// @dev UUPS upgrade gate: owner only.
    function _authorizeUpgrade(
        address
    ) internal view override onlyOwner {}

    /// @notice Accept native coin: escrow claims arrive as plain transfers, and direct sends become
    ///         buy-back balance.
    receive() external payable {}

    // ──────────────────────────────────────────────────────────
    //  External — fee flow
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IMoneyFeeCollector
    /// @dev Claimed amounts are measured as balance deltas around each escrow call, so balance
    ///      already held is never split again.
    function collectFees(
        address[] calldata tokens
    ) external override nonReentrant {
        IPonsFeeEscrowV2 escrow_ = _escrow;

        if (escrow_.balanceOf(address(this)) != 0) {
            uint256 before = address(this).balance;
            escrow_.claim();
            _split(NATIVE, address(this).balance - before);
        }

        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (escrow_.balanceOfToken(address(this), token) == 0) continue;
            uint256 before = IERC20(token).balanceOf(address(this));
            escrow_.claimToken(token);
            _split(token, IERC20(token).balanceOf(address(this)) - before);
        }
    }

    /// @inheritdoc IMoneyFeeCollector
    /// @dev `amountIn` is derived from the held balance and `burnSpendBps`, never chosen by the
    ///      keeper.
    function buyBack(
        address tokenIn,
        address swapTarget,
        bytes calldata swapData,
        uint256 minMoneyOut
    ) external override onlyKeeper nonReentrant returns (uint256 moneyOut) {
        address reserve_ = reserve;
        if (reserve_ == address(0)) revert ReserveNotSet();
        if (block.timestamp < lastBurnAt + burnInterval) revert BurnIntervalNotElapsed();
        lastBurnAt = block.timestamp;
        uint256 amountIn = burnSpendAmount(tokenIn);
        if (amountIn == 0) revert ZeroAmount();

        IERC20 money_ = IERC20(address(_money));
        if (tokenIn == address(money_)) {
            // Balance already held as $MONEY: forward the slice directly, no swap.
            if (swapTarget != address(0) || swapData.length != 0 || minMoneyOut != 0) revert InvalidSwapParams();
            money_.safeTransfer(reserve_, amountIn);
            emit MoneyBoughtBack(tokenIn, amountIn, amountIn);
            return amountIn;
        }

        if (!isSwapTarget[swapTarget]) revert SwapTargetNotAllowed();
        // A zero bound would let a sandwich take the whole spend; force the keeper to state one.
        if (minMoneyOut == 0) revert ZeroAmount();

        uint256 before = money_.balanceOf(address(this));
        if (tokenIn == NATIVE) {
            (bool ok,) = swapTarget.call{value: amountIn}(swapData);
            if (!ok) revert SwapFailed();
        } else {
            IERC20(tokenIn).forceApprove(swapTarget, amountIn);
            (bool ok,) = swapTarget.call(swapData);
            if (!ok) revert SwapFailed();
            // The target may legitimately pull less than `amountIn`; never leave an allowance.
            IERC20(tokenIn).forceApprove(swapTarget, 0);
        }
        uint256 received = money_.balanceOf(address(this)) - before;
        if (received < minMoneyOut) revert InsufficientMoneyOut(received, minMoneyOut);

        // Forward the full held balance, not just `received`: sweeps donations and prior swap dust.
        moneyOut = money_.balanceOf(address(this));
        money_.safeTransfer(reserve_, moneyOut);
        emit MoneyBoughtBack(tokenIn, amountIn, moneyOut);
    }

    // ──────────────────────────────────────────────────────────
    //  External — owner configuration
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IMoneyFeeCollector
    function setPayees(
        Payee[] calldata newPayees
    ) external override onlyOwner {
        _setPayees(newPayees);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setBurnShareBps(
        uint256 newBurnShareBps
    ) external override onlyOwner {
        if (newBurnShareBps > BPS) revert InvalidBps();
        burnShareBps = newBurnShareBps;
        emit BurnShareSet(newBurnShareBps);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setBurnSpendBps(
        uint256 newBurnSpendBps
    ) external override onlyOwner {
        if (newBurnSpendBps > BPS) revert InvalidBps();
        burnSpendBps = newBurnSpendBps;
        emit BurnSpendSet(newBurnSpendBps);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setBurnInterval(
        uint256 newBurnInterval
    ) external override onlyOwner {
        burnInterval = newBurnInterval;
        emit BurnIntervalSet(newBurnInterval);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setKeeper(address keeper, bool allowed) external override onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setSwapTarget(address target, bool allowed) external override onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        isSwapTarget[target] = allowed;
        emit SwapTargetSet(target, allowed);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setReserve(
        address newReserve
    ) external override onlyOwner {
        if (newReserve == address(0)) revert ZeroAddress();
        reserve = newReserve;
        emit ReserveSet(newReserve);
    }

    /// @inheritdoc IMoneyFeeCollector
    function setEscrow(
        address newEscrow
    ) external override onlyOwner {
        if (newEscrow == address(0)) revert ZeroAddress();
        _escrow = IPonsFeeEscrowV2(newEscrow);
        emit EscrowSet(newEscrow);
    }

    /// @inheritdoc IMoneyFeeCollector
    /// @dev Adds no trust: the owner already controls upgrades.
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external override onlyOwner nonReentrant returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            // Bubble up the target's revert reason.
            if (result.length == 0) revert ExecuteFailed();
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(target, value, data, result);
    }

    /// @inheritdoc IMoneyFeeCollector
    function transferOwnership(
        address newOwner
    ) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @inheritdoc IMoneyFeeCollector
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Split one collected amount: the buy-back share stays in this contract and the rest is
    ///      paid to the payees.
    /// @param token  Collected asset (address(0) = native coin).
    /// @param amount Amount collected.
    function _split(address token, uint256 amount) private {
        if (amount == 0) return;

        // The buy-back share rounds up.
        uint256 distributable = amount * (BPS - burnShareBps) / BPS;
        emit FeesCollected(token, amount, amount - distributable);
        if (distributable == 0) return;

        uint256 len = _payees.length;
        if (len == 0) revert PayeesNotConfigured();
        uint256 remaining = distributable;
        for (uint256 i; i < len; ++i) {
            Payee memory p = _payees[i];
            // The last payee takes the remainder, so no rounding dust is left behind.
            uint256 cut = i == len - 1 ? remaining : distributable * p.shareBps / BPS;
            remaining -= cut;
            if (cut == 0) continue;
            if (token == NATIVE) {
                (bool ok,) = p.account.call{value: cut}("");
                if (!ok) revert NativeTransferFailed(p.account);
            } else {
                IERC20(token).safeTransfer(p.account, cut);
            }
            emit FeesDistributed(token, p.account, cut);
        }
    }

    /// @dev Replace the payee set; shares must sum to exactly BPS. An empty set is allowed, but
    ///      collections then revert while the distribution share is nonzero.
    /// @param newPayees New payee set.
    function _setPayees(
        Payee[] calldata newPayees
    ) private {
        delete _payees;
        uint256 total;
        uint256 len = newPayees.length;
        for (uint256 i; i < len; ++i) {
            Payee calldata p = newPayees[i];
            if (p.account == address(0)) revert ZeroAddress();
            if (p.shareBps == 0) revert ZeroAmount();
            total += p.shareBps;
            _payees.push(p);
        }
        if (len != 0 && total != BPS) revert InvalidBps();
        emit PayeesSet(newPayees);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IMoneyFeeCollector
    function escrow() external view override returns (address) {
        return address(_escrow);
    }

    /// @inheritdoc IMoneyFeeCollector
    function money() external view override returns (address) {
        return address(_money);
    }

    /// @inheritdoc IMoneyFeeCollector
    function payees() external view override returns (Payee[] memory) {
        return _payees;
    }

    /// @inheritdoc IMoneyFeeCollector
    function burnSpendAmount(
        address tokenIn
    ) public view override returns (uint256) {
        uint256 held = tokenIn == NATIVE ? address(this).balance : IERC20(tokenIn).balanceOf(address(this));
        return held * burnSpendBps / BPS;
    }

    /// @inheritdoc IMoneyFeeCollector
    function claimableFees(
        address token
    ) external view override returns (uint256) {
        return token == NATIVE ? _escrow.balanceOf(address(this)) : _escrow.balanceOfToken(address(this), token);
    }
}
