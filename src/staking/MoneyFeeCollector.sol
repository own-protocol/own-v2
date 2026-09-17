// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMoneyFeeCollector} from "../interfaces/IMoneyFeeCollector.sol";
import {IPonsFeeEscrowV2} from "../interfaces/external/IPonsFeeEscrowV2.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MoneyFeeCollector — $MONEY fee routing and buy-&-burn
/// @notice Registered as the fee recipient of the $MONEY pair in the Pons V2 fee escrow. Anyone
///         can trigger {collectFees}: every amount claimed from the escrow is split at that
///         moment — `burnShareBps` (initially 30%) stays in this contract as burn reserve, the
///         rest is paid out immediately to the owner-configured payee set. Because the
///         distribution share never idles here, the contract's entire held balance IS the burn
///         reserve; assets transferred in directly (e.g. the initial Safe seed) therefore go
///         towards burns in full, by construction. Keepers convert reserve into $MONEY through an
///         owner-allow-listed swap target and burn it ({buyAndBurn}), at most once per
///         `burnInterval` (initially 1 hour).
/// @dev Runs behind an ERC-1967 proxy (UUPS) so the escrow-credited address survives upgrades;
///      upgrades and configuration are owner-gated, with the protocol Safe as owner (two-step
///      handover). Storage is append-only across upgrades. Trust model: owner (Safe) is fully
///      trusted — it can upgrade and {execute} arbitrarily. Keepers are hot keys trusted only for
///      burn timing and slippage bounds (`minMoneyOut`): they cannot move funds anywhere but into
///      an allow-listed swap and the $MONEY burn, and never choose the spend — each burn spends
///      exactly `burnSpendBps` of the held input balance (initially 10%), so a compromised keeper
///      key is capped to that slice per interval even through a permissive swap target. The
///      escrow and swap targets are owner-vetted external contracts. Swaps are sandwich-exposed
///      up to the keeper's `minMoneyOut`, which is why targets are allow-listed and burns
///      keeper-gated.
contract MoneyFeeCollector is IMoneyFeeCollector, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Marker for the chain's native coin in `token` parameters and events.
    address private constant NATIVE = address(0);

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IMoneyFeeCollector
    address public override owner;

    /// @inheritdoc IMoneyFeeCollector
    address public override pendingOwner;

    /// @dev Fee escrow claimed from. Owner-settable (Pons migration lever).
    IPonsFeeEscrowV2 private _escrow;

    /// @dev The $MONEY token. Initializer-set, fixed thereafter — burning a different token is a
    ///      different contract, not a config change.
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

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev The implementation is only ever used behind an ERC-1967 proxy; lock its own
    ///      initializers so the bare implementation can never be initialized or taken over.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the collector proxy (runs once, in the proxy's constructor call).
    /// @param owner_   Contract owner (the protocol Safe).
    /// @param escrow_  Pons V2 fee escrow to claim from.
    /// @param money_   The $MONEY token (must expose ERC20Burnable `burn`).
    /// @param keeper_  Initial burn keeper (zero = none yet; enable later via {setKeeper}).
    /// @param payees_  Initial distribution payee set (may be empty only if collections are not
    ///                 expected before {setPayees}, or while `burnShareBps` is 10_000).
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

    /// @dev UUPS upgrade gate: only the owner (Safe) may upgrade this proxy's implementation.
    function _authorizeUpgrade(
        address
    ) internal view override onlyOwner {}

    /// @notice Accept native coin: escrow claims arrive as plain transfers, and direct sends are
    ///         seeds that become burn reserve by construction.
    receive() external payable {}

    // ──────────────────────────────────────────────────────────
    //  External — fee flow
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IMoneyFeeCollector
    /// @dev Permissionless: claimed funds can only travel the configured split, so a third-party
    ///      trigger merely moves fees along. Claimed amounts are measured as balance deltas
    ///      around each escrow call rather than trusted return values, so pre-existing reserve
    ///      (seeds) is never re-split.
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
    /// @dev The keeper has no say in the spend: `amountIn` is derived on-chain from the held
    ///      balance and the owner-set `burnSpendBps`, capping what a compromised keeper key can
    ///      route through a swap to that slice per `burnInterval`.
    function buyAndBurn(
        address tokenIn,
        address swapTarget,
        bytes calldata swapData,
        uint256 minMoneyOut
    ) external override onlyKeeper nonReentrant returns (uint256 moneyBurned) {
        if (block.timestamp < lastBurnAt + burnInterval) revert BurnIntervalNotElapsed();
        lastBurnAt = block.timestamp;
        uint256 amountIn = burnSpendAmount(tokenIn);
        if (amountIn == 0) revert ZeroAmount();

        ERC20Burnable money_ = _money;
        if (tokenIn == address(money_)) {
            // Reserve already held as $MONEY (e.g. a seed): burn the slice directly, no swap.
            if (swapTarget != address(0) || swapData.length != 0 || minMoneyOut != 0) revert InvalidSwapParams();
            money_.burn(amountIn);
            emit MoneyBurned(tokenIn, amountIn, amountIn);
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

        // Burn the full held balance, not just `received`: sweeps donations and prior swap dust.
        moneyBurned = money_.balanceOf(address(this));
        money_.burn(moneyBurned);
        emit MoneyBurned(tokenIn, amountIn, moneyBurned);
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
    function setEscrow(
        address newEscrow
    ) external override onlyOwner {
        if (newEscrow == address(0)) revert ZeroAddress();
        _escrow = IPonsFeeEscrowV2(newEscrow);
        emit EscrowSet(newEscrow);
    }

    /// @inheritdoc IMoneyFeeCollector
    /// @dev No privilege escalation: the owner already controls upgrades, so this adds reach
    ///      (Pons-side fee-rights calls, asset rescue) without adding trust.
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external override onlyOwner nonReentrant returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            // Bubble the target's revert reason so Safe simulations show the real cause.
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

    /// @dev Split one collected amount: retain the burn share (it simply stays on this contract's
    ///      balance), pay the rest out to the payee set immediately.
    function _split(address token, uint256 amount) private {
        if (amount == 0) return;

        // Burn share rounds up: ties favour the burn reserve over the payout.
        uint256 distributable = amount * (BPS - burnShareBps) / BPS;
        emit FeesCollected(token, amount, amount - distributable);
        if (distributable == 0) return;

        uint256 len = _payees.length;
        if (len == 0) revert PayeesNotConfigured();
        uint256 remaining = distributable;
        for (uint256 i; i < len; ++i) {
            Payee memory p = _payees[i];
            // Last payee takes the remainder so rounding dust never accretes into the reserve.
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

    /// @dev Replace the payee set atomically; shares must sum to exactly BPS. An empty set is
    ///      allowed (burn-only mode): collections then revert while a distribution share exists.
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
