// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMoneyFeeCollector — $MONEY fee routing and buy-&-burn
/// @notice Receives the $MONEY trading fees credited to it in the Pons V2 fee escrow, splits
///         every collected amount into a burn share (retained for keeper-driven $MONEY
///         buy-&-burns) and a distribution share paid out immediately to a configurable set of
///         payees. Every balance the contract holds between collections is burn reserve —
///         including direct transfers in (seeds), which therefore go towards burns in full.
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
    /// @param burnAmount  Portion retained in the burn reserve.
    event FeesCollected(address indexed token, uint256 amount, uint256 burnAmount);

    /// @notice A payee received its cut of a collection's distribution share.
    /// @param token  Distributed asset (address(0) = native coin).
    /// @param payee  Recipient.
    /// @param amount Amount transferred.
    event FeesDistributed(address indexed token, address indexed payee, uint256 amount);

    /// @notice A keeper converted burn reserve into $MONEY and burned it.
    /// @param tokenIn     Asset spent (address(0) = native coin; the $MONEY token = direct burn).
    /// @param amountIn    Amount of `tokenIn` spent.
    /// @param moneyBurned $MONEY supply burned.
    event MoneyBurned(address indexed tokenIn, uint256 amountIn, uint256 moneyBurned);

    /// @notice The payee set was replaced.
    event PayeesSet(Payee[] payees);

    /// @notice The burn share was updated.
    event BurnShareSet(uint256 burnShareBps);

    /// @notice The minimum interval between burns was updated.
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

    /// @notice The minimum interval since the last burn has not elapsed.
    error BurnIntervalNotElapsed();

    /// @notice The swap target is not allow-listed.
    error SwapTargetNotAllowed();

    /// @notice The swap call reverted.
    error SwapFailed();

    /// @notice The swap produced less $MONEY than the keeper's stated minimum.
    error InsufficientMoneyOut(uint256 received, uint256 minOut);

    /// @notice Swap parameters must be empty for a direct $MONEY burn.
    error InvalidSwapParams();

    /// @notice A native-coin transfer to a payee failed.
    error NativeTransferFailed(address to);

    /// @notice The owner-authorized arbitrary call reverted.
    error ExecuteFailed();

    // ──────────────────────────────────────────────────────────
    //  Fee flow
    // ──────────────────────────────────────────────────────────

    /// @notice Claim all accrued fees from the escrow (native coin plus each listed token) and
    ///         split every claimed amount: `burnShareBps` stays as burn reserve, the remainder is
    ///         paid out to the configured payees pro-rata immediately.
    /// @param tokens ERC-20 fee assets to claim (native coin is always attempted). Assets with a
    ///               zero escrow balance are skipped.
    function collectFees(
        address[] calldata tokens
    ) external;

    /// @notice Spend `amountIn` of burn reserve on $MONEY via an allow-listed swap target, then
    ///         burn the contract's entire resulting $MONEY balance. Keeper-only, rate-limited to
    ///         one burn per `burnInterval`. When `tokenIn` is the $MONEY token itself, no swap is
    ///         performed (`swapTarget`/`swapData`/`minMoneyOut` must be empty) and `amountIn` is
    ///         burned directly.
    /// @param tokenIn      Reserve asset to spend (address(0) = native coin).
    /// @param amountIn     Amount of `tokenIn` to spend.
    /// @param swapTarget   Allow-listed contract executing the swap.
    /// @param swapData     Calldata forwarded to `swapTarget` (native input is attached as value;
    ///                     ERC-20 input is approved for exactly `amountIn`).
    /// @param minMoneyOut  Minimum $MONEY the swap must produce (slippage bound; must be nonzero).
    /// @return moneyBurned $MONEY supply burned.
    function buyAndBurn(
        address tokenIn,
        uint256 amountIn,
        address swapTarget,
        bytes calldata swapData,
        uint256 minMoneyOut
    ) external returns (uint256 moneyBurned);

    // ──────────────────────────────────────────────────────────
    //  Owner configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Replace the distribution payee set. Shares must sum to exactly 10_000 BPS.
    function setPayees(
        Payee[] calldata newPayees
    ) external;

    /// @notice Set the fraction of every collection retained for burns, in BPS (≤ 10_000).
    function setBurnShareBps(
        uint256 newBurnShareBps
    ) external;

    /// @notice Set the minimum interval between burns.
    function setBurnInterval(
        uint256 newBurnInterval
    ) external;

    /// @notice Enable or disable a burn keeper.
    function setKeeper(address keeper, bool allowed) external;

    /// @notice Allow-list or remove a swap target for {buyAndBurn}.
    function setSwapTarget(address target, bool allowed) external;

    /// @notice Point the collector at a new fee escrow (Pons migration lever).
    function setEscrow(
        address newEscrow
    ) external;

    /// @notice Execute an arbitrary owner-authorized call from this contract — the lever for
    ///         managing this contract's fee-recipient rights on the Pons side (which are bound to
    ///         this address) and for rescuing mis-sent assets.
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

    /// @notice Contract owner (admin; intended to be the protocol Safe).
    function owner() external view returns (address);

    /// @notice Address that can complete a started ownership handover.
    function pendingOwner() external view returns (address);

    /// @notice Fee escrow currently collected from.
    function escrow() external view returns (address);

    /// @notice The $MONEY token bought and burned.
    function money() external view returns (address);

    /// @notice Fraction of every collection retained for burns, in BPS.
    function burnShareBps() external view returns (uint256);

    /// @notice Minimum interval between burns.
    function burnInterval() external view returns (uint256);

    /// @notice Timestamp of the last burn.
    function lastBurnAt() external view returns (uint256);

    /// @notice Whether `account` is an enabled burn keeper.
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
