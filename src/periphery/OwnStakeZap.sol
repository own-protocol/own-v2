// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSDManager} from "../interfaces/IEUSDManager.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnStakeZap} from "../interfaces/IOwnStakeZap.sol";
import {IOwnStakingV2} from "../interfaces/IOwnStakingV2.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OwnStakeZap — one-transaction routes into OwnStakingV2
/// @notice Collapses the basket flows (swap, PSM-mint, CDP deposit, eUSD mint, dual-asset stake)
///         into single transactions. Stateless: no owner, no admin, no upgrade — replace by
///         deploying a new zap and repointing `EUSDManager.setStakeZap` and
///         `OwnStakingV2.setZap`. Every entry runs on real amounts inside one transaction and
///         reverts whole if any leg fails, so nothing is ever quoted or stranded.
/// @dev Trust model: the zap holds standing user *approvals* but never funds between
///      transactions, so the swap leg is the only dangerous surface. It is confined to the
///      constructor-pinned `swapRouter` with an exact just-in-time allowance that is reset after
///      the call — user-supplied `swapData` can therefore spend at most the caller's own
///      in-flight SPY slice, never another user's approval. On-behalf CDP surfaces
///      ({IEUSDManager.depositFor}/{mintFor}) and staking surfaces ({IOwnStakingV2.unstakeFor}/
///      {claimFor}) only accept this contract, and every entry passes `msg.sender` as the owner,
///      so the zap can only ever act on the caller's own position.
contract OwnStakeZap is IOwnStakeZap, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutable wiring
    // ──────────────────────────────────────────────────────────

    IEUSDManager private immutable _eusdManager;
    IOwnStakingV2 private immutable _staking;
    IOwnMarket private immutable _market;
    IERC4626 private immutable _sEusd;
    IERC20 private immutable _eusd;
    IERC20 private immutable _money;
    IERC20 private immutable _spy;
    IERC20 private immutable _collateral;
    bytes32 private immutable _collateralTicker;
    address private immutable _swapRouter;

    // ──────────────────────────────────────────────────────────
    //  Construction
    // ──────────────────────────────────────────────────────────

    /// @param eusdManager_ CDP engine (must whitelist this zap via setStakeZap).
    /// @param staking_     OwnStakingV2 (must whitelist this zap via setZap).
    /// @param market_      OwnMarket whose PSM converts SPY into the collateral eToken.
    /// @param sEusd_       Legacy sEUSD vault (migration source).
    /// @param eusd_        eUSD token.
    /// @param money_       $MONEY token.
    /// @param spy_         SPY token (PSM wrapper and reward asset).
    /// @param collateral_  Collateral eToken (eSPY).
    /// @param ticker_      PSM asset ticker for the collateral (e.g. bytes32("SPY")).
    /// @param swapRouter_  Vetted router for the SPY→$MONEY swap leg.
    constructor(
        address eusdManager_,
        address staking_,
        address market_,
        address sEusd_,
        address eusd_,
        address money_,
        address spy_,
        address collateral_,
        bytes32 ticker_,
        address swapRouter_
    ) {
        if (
            eusdManager_ == address(0) || staking_ == address(0) || market_ == address(0) || sEusd_ == address(0)
                || eusd_ == address(0) || money_ == address(0) || spy_ == address(0) || collateral_ == address(0)
                || swapRouter_ == address(0)
        ) revert ZeroAddress();
        _eusdManager = IEUSDManager(eusdManager_);
        _staking = IOwnStakingV2(staking_);
        _market = IOwnMarket(market_);
        _sEusd = IERC4626(sEusd_);
        _eusd = IERC20(eusd_);
        _money = IERC20(money_);
        _spy = IERC20(spy_);
        _collateral = IERC20(collateral_);
        _collateralTicker = ticker_;
        _swapRouter = swapRouter_;

        // Standing approvals to the fixed protocol contracts the zap routes through. The router
        // deliberately gets none — its allowance is exact and per-swap.
        IERC20(spy_).forceApprove(market_, type(uint256).max);
        IERC20(collateral_).forceApprove(eusdManager_, type(uint256).max);
        IERC20(money_).forceApprove(staking_, type(uint256).max);
        IERC20(eusd_).forceApprove(staking_, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Entries
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakeZap
    function stakeFromSpy(
        uint256 spyAmount,
        uint256 spyForMoney,
        uint256 minMoneyOut,
        bytes calldata swapData,
        uint256 eusdToMint,
        address hint
    ) external override nonReentrant {
        if (spyAmount == 0) revert ZeroAmount();
        if (spyForMoney > spyAmount) revert InvalidSplit(spyForMoney, spyAmount);
        _spy.safeTransferFrom(msg.sender, address(this), spyAmount);

        uint256 moneyOut;
        if (spyForMoney != 0) {
            // A zero floor would let a sandwich take the whole slice; force the caller (the app)
            // to state one.
            if (minMoneyOut == 0) revert ZeroAmount();
            uint256 moneyBefore = _money.balanceOf(address(this));
            _spy.forceApprove(_swapRouter, spyForMoney);
            (bool ok,) = _swapRouter.call(swapData);
            if (!ok) revert SwapFailed();
            // The router may legitimately pull less than the slice; never leave an allowance.
            _spy.forceApprove(_swapRouter, 0);
            moneyOut = _money.balanceOf(address(this)) - moneyBefore;
            if (moneyOut < minMoneyOut) revert InsufficientMoneyOut(moneyOut, minMoneyOut);
        }

        // PSM-mint the full remaining SPY balance: a partial router pull becomes extra
        // collateral for the caller rather than dust stranded on the zap.
        _buildCdpAndStake(spyAmount, _spy.balanceOf(address(this)), moneyOut, eusdToMint, hint);
    }

    /// @inheritdoc IOwnStakeZap
    function stakeFromSpyAndMoney(
        uint256 spyAmount,
        uint256 moneyAmount,
        uint256 eusdToMint,
        address hint
    ) external override nonReentrant {
        if (spyAmount == 0) revert ZeroAmount();
        _spy.safeTransferFrom(msg.sender, address(this), spyAmount);
        if (moneyAmount != 0) _money.safeTransferFrom(msg.sender, address(this), moneyAmount);
        _buildCdpAndStake(spyAmount, spyAmount, moneyAmount, eusdToMint, hint);
    }

    /// @inheritdoc IOwnStakeZap
    function stakeFromEusdAndMoney(
        uint256 eusdAmount,
        uint256 moneyAmount
    ) external override nonReentrant {
        if (eusdAmount == 0 && moneyAmount == 0) revert ZeroAmount();
        if (eusdAmount != 0) _eusd.safeTransferFrom(msg.sender, address(this), eusdAmount);
        if (moneyAmount != 0) _money.safeTransferFrom(msg.sender, address(this), moneyAmount);
        _staking.stakeFor(msg.sender, moneyAmount, eusdAmount);
        emit ZapStaked(msg.sender, 0, moneyAmount, eusdAmount);
    }

    /// @inheritdoc IOwnStakeZap
    function stakeFromSeusd(
        uint256 shares,
        uint256 moneyAmount
    ) external override nonReentrant {
        if (shares == 0) revert ZeroAmount();
        // Instant ERC-4626 exit; requires the caller's sEUSD approval to the zap.
        uint256 eusdOut = _sEusd.redeem(shares, address(this), msg.sender);
        if (moneyAmount != 0) _money.safeTransferFrom(msg.sender, address(this), moneyAmount);
        _staking.stakeFor(msg.sender, moneyAmount, eusdOut);
        emit Migrated(msg.sender, shares, eusdOut, moneyAmount);
    }

    /// @inheritdoc IOwnStakeZap
    function compound(
        address hint
    ) external override nonReentrant {
        uint256 spyOut = _staking.claimFor(msg.sender);
        if (spyOut == 0) revert NothingToCompound();
        uint256 minted = _market.psmMint(_collateralTicker, address(_spy), spyOut);
        _eusdManager.depositFor(msg.sender, address(_collateral), minted, hint);
        emit Compounded(msg.sender, spyOut, minted);
    }

    /// @inheritdoc IOwnStakeZap
    function rebalance(
        uint256 eusdAmount,
        address hint
    ) external override nonReentrant {
        if (eusdAmount == 0) revert ZeroAmount();
        _staking.unstakeFor(msg.sender, 0, eusdAmount);
        // Repay burns from this contract's balance, capped at the position's debt.
        _eusdManager.repay(address(_collateral), msg.sender, eusdAmount, hint);
        uint256 leftover = _eusd.balanceOf(address(this));
        if (leftover != 0) _eusd.safeTransfer(msg.sender, leftover);
        emit Rebalanced(msg.sender, eusdAmount, eusdAmount - leftover, leftover);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Shared tail of the SPY entries: PSM-mint `spyToPsm` into collateral, deposit it into
    ///      the caller's CDP, mint `eusdToMint` against it (paid to the zap) and stake both legs
    ///      for the caller.
    function _buildCdpAndStake(
        uint256 spyIn,
        uint256 spyToPsm,
        uint256 moneyAmount,
        uint256 eusdToMint,
        address hint
    ) private {
        uint256 minted = _market.psmMint(_collateralTicker, address(_spy), spyToPsm);
        _eusdManager.depositFor(msg.sender, address(_collateral), minted, hint);
        if (eusdToMint != 0) {
            _eusdManager.mintFor(msg.sender, address(_collateral), eusdToMint, hint);
        }
        if (moneyAmount != 0 || eusdToMint != 0) {
            _staking.stakeFor(msg.sender, moneyAmount, eusdToMint);
        }
        emit ZapStaked(msg.sender, spyIn, moneyAmount, eusdToMint);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakeZap
    function eusdManager() external view override returns (address) {
        return address(_eusdManager);
    }

    /// @inheritdoc IOwnStakeZap
    function staking() external view override returns (address) {
        return address(_staking);
    }

    /// @inheritdoc IOwnStakeZap
    function market() external view override returns (address) {
        return address(_market);
    }

    /// @inheritdoc IOwnStakeZap
    function sEusd() external view override returns (address) {
        return address(_sEusd);
    }

    /// @inheritdoc IOwnStakeZap
    function collateral() external view override returns (address) {
        return address(_collateral);
    }

    /// @inheritdoc IOwnStakeZap
    function collateralTicker() external view override returns (bytes32) {
        return _collateralTicker;
    }

    /// @inheritdoc IOwnStakeZap
    function swapRouter() external view override returns (address) {
        return _swapRouter;
    }
}
