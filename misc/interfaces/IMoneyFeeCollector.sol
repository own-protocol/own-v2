// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMoneyFeeCollector — $MONEY fee routing and buy-back
/// @notice Collects the $MONEY trading fees credited to it in the Pons V2 fee escrow and splits
///         each collected amount into a buy-back share, kept for keeper-run $MONEY buy-backs
///         paid to the protocol reserve, and a distribution share paid out immediately to the
///         payees. Everything the contract holds between collections, including direct
///         transfers, is buy-back balance. Parameters named `burn*` configure the buy-back.
interface IMoneyFeeCollector {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice One recipient of the distribution share.
    /// @param account  Payout address.
    /// @param shareBps Fraction of the distribution share, in BPS. All payees sum to 10_000.
    struct Payee {
        address account;
        uint96 shareBps;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice A fee amount was claimed from the escrow and split.
    /// @param token       Claimed asset (address(0) = native coin).
    /// @param amount      Total amount claimed in this collection.
    /// @param burnAmount  Portion kept as buy-back balance.
    event FeesCollected(address indexed token, uint256 amount, uint256 burnAmount);

    /// @notice A payee received its cut of a collection's distribution share.
    /// @param token  Distributed asset (address(0) = native coin).
    /// @param payee  Recipient.
    /// @param amount Amount transferred.
    event FeesDistributed(address indexed token, address indexed payee, uint256 amount);

    /// @notice A keeper converted buy-back balance into $MONEY and sent it to the reserve.
    /// @param tokenIn  Asset spent (address(0) = native coin; the $MONEY token = forwarded as is).
    /// @param amountIn Amount of `tokenIn` spent (`burnSpendBps` of the held balance).
    /// @param moneyOut $MONEY sent to the reserve.
    event MoneyBoughtBack(address indexed tokenIn, uint256 amountIn, uint256 moneyOut);

    /// @notice The buy-back recipient was updated.
    event ReserveSet(address indexed reserve);

    /// @notice The payee set was replaced.
    event PayeesSet(Payee[] payees);

    /// @notice The buy-back share was updated.
    event BurnShareSet(uint256 burnShareBps);

    /// @notice The share of the held balance spent per buy-back was updated.
    event BurnSpendSet(uint256 burnSpendBps);

    /// @notice The minimum interval between buy-backs was updated.
    event BurnIntervalSet(uint256 burnInterval);

    /// @notice A keeper was enabled or disabled.
    event KeeperSet(address indexed keeper, bool allowed);

    /// @notice A swap target was allow-listed or removed.
    event SwapTargetSet(address indexed target, bool allowed);

    /// @notice The fee escrow reference was updated.
    event EscrowSet(address indexed escrow);

    /// @notice An owner-authorized arbitrary call was executed.
    event Executed(address indexed target, uint256 value, bytes data, bytes result);

    /// @notice Two-step ownership handover started.
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);

    /// @notice Ownership handover completed.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller is not the owner.
    error NotOwner();

    /// @notice Caller is not the pending owner.
    error NotPendingOwner();

    /// @notice Caller is not an enabled keeper.
    error NotKeeper();

    /// @notice A required address argument was zero.
    error ZeroAddress();

    /// @notice A required amount argument was zero.
    error ZeroAmount();

    /// @notice A BPS argument exceeds 10_000, or the payee shares do not sum to 10_000.
    error InvalidBps();

    /// @notice A collection produced a distribution share but no payees are configured.
    error PayeesNotConfigured();

    /// @notice The minimum interval since the last buy-back has not elapsed.
    error BurnIntervalNotElapsed();

    /// @notice The swap target is not allow-listed.
    error SwapTargetNotAllowed();

    /// @notice The swap call reverted.
    error SwapFailed();

    /// @notice The swap produced less $MONEY than the keeper's stated minimum.
    error InsufficientMoneyOut(uint256 received, uint256 minOut);

    /// @notice Swap parameters must be empty when the buy-back balance is already $MONEY.
    error InvalidSwapParams();

    /// @notice No reserve is set to receive bought-back $MONEY.
    error ReserveNotSet();

    /// @notice A native-coin transfer to a payee failed.
    error NativeTransferFailed(address to);

    /// @notice The owner-authorized arbitrary call reverted without returning a reason (a revert
    ///         with a reason is bubbled up as-is instead).
    error ExecuteFailed();

    // ──────────────────────────────────────────────────────────
    //  Fee flow
    // ──────────────────────────────────────────────────────────

    /// @notice Claim all accrued fees from the escrow (native coin plus each listed token) and
    ///         split each claimed amount: `burnShareBps` stays for buy-backs and the rest is paid
    ///         to the payees pro rata. Permissionless.
    /// @param tokens ERC-20 fee assets to claim (native coin is always attempted). Assets with a
    ///               zero escrow balance are skipped.
    function collectFees(
        address[] calldata tokens
    ) external;

    /// @notice Spend `burnSpendBps` of the held `tokenIn` balance (see {burnSpendAmount}) on $MONEY
    ///         through an allow-listed swap target, then send the contract's whole $MONEY balance to
    ///         `reserve`. Keeper only, at most once per `burnInterval`. When `tokenIn` is $MONEY,
    ///         the slice is forwarded without a swap and the swap arguments must be empty.
    /// @param tokenIn      Held asset to spend (address(0) = native coin).
    /// @param swapTarget   Allow-listed contract executing the swap.
    /// @param swapData     Calldata forwarded to `swapTarget` (native input is attached as value;
    ///                     ERC-20 input is approved for exactly the computed spend, so the
    ///                     calldata must not pull more — read {burnSpendAmount} when encoding).
    /// @param minMoneyOut  Minimum $MONEY the swap must produce (slippage bound; must be nonzero).
    /// @return moneyOut   $MONEY sent to the reserve.
    function buyBack(
        address tokenIn,
        address swapTarget,
        bytes calldata swapData,
        uint256 minMoneyOut
    ) external returns (uint256 moneyOut);

    // ──────────────────────────────────────────────────────────
    //  Owner configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Replace the distribution payee set. Shares must sum to exactly 10_000 BPS.
    function setPayees(
        Payee[] calldata newPayees
    ) external;

    /// @notice Set the share of every collection kept for buy-backs, in BPS (≤ 10_000).
    function setBurnShareBps(
        uint256 newBurnShareBps
    ) external;

    /// @notice Set the share of the held balance spent per buy-back, in BPS (≤ 10_000). Zero
    ///         pauses buy-backs.
    function setBurnSpendBps(
        uint256 newBurnSpendBps
    ) external;

    /// @notice Set the minimum interval between buy-backs.
    function setBurnInterval(
        uint256 newBurnInterval
    ) external;

    /// @notice Enable or disable a buy-back keeper.
    function setKeeper(address keeper, bool allowed) external;

    /// @notice Allow-list or remove a swap target for {buyBack}.
    function setSwapTarget(address target, bool allowed) external;

    /// @notice Set the address that receives bought-back $MONEY (the protocol reserve).
    function setReserve(
        address newReserve
    ) external;

    /// @notice Point the collector at a new fee escrow.
    function setEscrow(
        address newEscrow
    ) external;

    /// @notice Execute an arbitrary call from this contract (owner). Used to manage this
    ///         contract's fee-recipient rights on Pons and to rescue mis-sent assets.
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory result);

    /// @notice Start the two-step ownership handover to `newOwner`.
    function transferOwnership(
        address newOwner
    ) external;

    /// @notice Complete the ownership handover (pending owner only).
    function acceptOwnership() external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Contract owner (the protocol Safe).
    function owner() external view returns (address);

    /// @notice Address that can complete a started ownership handover.
    function pendingOwner() external view returns (address);

    /// @notice Fee escrow currently collected from.
    function escrow() external view returns (address);

    /// @notice The $MONEY token bought back.
    function money() external view returns (address);

    /// @notice Recipient of bought-back $MONEY (address(0) = not set; buy-backs revert).
    function reserve() external view returns (address);

    /// @notice Share of every collection kept for buy-backs, in BPS.
    function burnShareBps() external view returns (uint256);

    /// @notice Share of the held balance spent per buy-back, in BPS. Zero = buy-backs paused.
    function burnSpendBps() external view returns (uint256);

    /// @notice The exact `tokenIn` amount the next {buyBack} would spend right now
    ///         (`burnSpendBps` of the currently held balance; address(0) = native coin).
    function burnSpendAmount(
        address tokenIn
    ) external view returns (uint256);

    /// @notice Minimum interval between buy-backs.
    function burnInterval() external view returns (uint256);

    /// @notice Timestamp of the last buy-back.
    function lastBurnAt() external view returns (uint256);

    /// @notice Whether `account` is an enabled buy-back keeper.
    function isKeeper(
        address account
    ) external view returns (bool);

    /// @notice Whether `target` is an allow-listed swap target.
    function isSwapTarget(
        address target
    ) external view returns (bool);

    /// @notice The current payee set.
    function payees() external view returns (Payee[] memory);

    /// @notice Fees claimable from the escrow (address(0) = native coin).
    function claimableFees(
        address token
    ) external view returns (uint256);
}
