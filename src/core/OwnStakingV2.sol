// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnStakingV2} from "../interfaces/IOwnStakingV2.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnStakingV2 — dual-asset staking with a curve-boosted SPY reward stream
/// @notice Stake eUSD alongside $MONEY. eUSD is the earning principal; the oracle-priced value of
///         the staked $MONEY relative to it (the coverage ratio) sets a boost multiplier read off
///         an admin-set piecewise-linear knot curve. Rewards are SPY, streamed linearly
///         (Synthetix-style index over `weight = eusdStaked × boost`): the operator pulls each
///         batch from the reward source (the treasury Safe) within its live ERC-20 allowance, so
///         the allowance is the on-chain spending cap and no hot key ever holds funds.
/// @dev Boosts are snapshots taken whenever a position is touched, which keeps the reward index
///      exact between touches; price moves are folded in by the permissionless {refreshBoost}.
///      The oracle only gates how much weight a $MONEY stake carries, never funds: a stale, zero,
///      or missing price floors the boost (first curve knot) on stake and refresh, and unstaking
///      never reads a price, so a full exit always works. Runs behind an ERC-1967 proxy (UUPS),
///      ADMIN-gated upgrade via ProtocolRegistry roles; storage is append-only across upgrades.
///      Positions are plain per-account storage — non-transferable by construction.
contract OwnStakingV2 is IOwnStakingV2, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @dev Ticker of the $MONEY price on the registry's in-house oracle.
    bytes32 private constant MONEY_TICKER = bytes32("MONEY");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve roles and the in-house oracle.
    /// @dev Initializer-set, fixed thereafter (storage, not immutable, so an upgraded
    ///      implementation can never silently rebind it).
    IProtocolRegistry public registry;

    /// @dev Staked assets and the reward asset. Initializer-set, fixed thereafter.
    IERC20 private _eusd;
    IERC20 private _money;
    IERC20 private _spy;

    /// @inheritdoc IOwnStakingV2
    address public override rewardSource;

    /// @inheritdoc IOwnStakingV2
    uint256 public override rewardsDuration;

    /// @inheritdoc IOwnStakingV2
    uint256 public override priceMaxAge;

    /// @inheritdoc IOwnStakingV2
    uint256 public override maxBoostBps;

    /// @inheritdoc IOwnStakingV2
    uint256 public override stakeCap;

    /// @dev Boost curve knots; validated monotone in {_setCurve}.
    Knot[] private _curve;

    /// @inheritdoc IOwnStakingV2
    uint256 public override totalWeight;

    /// @inheritdoc IOwnStakingV2
    uint256 public override totalEusdStaked;

    /// @inheritdoc IOwnStakingV2
    uint256 public override totalMoneyStaked;

    /// @inheritdoc IOwnStakingV2
    /// @dev PRECISION-scaled (SPY-wei × PRECISION per second) so a small stream over a long
    ///      window loses no more than one wei per second to rounding.
    uint256 public override rewardRate;

    /// @inheritdoc IOwnStakingV2
    uint256 public override periodFinish;

    /// @dev Timestamp of the last global index update.
    uint256 private _lastUpdateTime;

    /// @dev Global reward index: PRECISION-scaled SPY per unit of weight.
    uint256 private _rewardPerWeightStored;

    /// @inheritdoc IOwnStakingV2
    uint256 public override undistributed;

    /// @dev SPY the stream accounting owns: notified batches plus synced surpluses minus claims.
    ///      `balanceOf(this) − _accountedRewards` is therefore exactly the un-absorbed surplus
    ///      {syncRewards} may fold in — pre-existing stream, owed rewards, the undistributed
    ///      bucket, and rounding dust are never re-counted.
    uint256 private _accountedRewards;

    /// @dev Positions by owner.
    mapping(address => Position) private _positions;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
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

    /// @notice Initialize the staking proxy (runs once, in the proxy's constructor call).
    /// @param registry_     ProtocolRegistry (role authority + oracle lookup).
    /// @param eusd_         eUSD token — the earning principal.
    /// @param money_        $MONEY token — the boost leg.
    /// @param spy_          SPY token — the reward asset.
    /// @param rewardSource_ Address {notifyRewardAmount} pulls SPY from (the treasury Safe).
    /// @param knots         Initial boost curve.
    function initialize(
        address registry_,
        address eusd_,
        address money_,
        address spy_,
        address rewardSource_,
        Knot[] calldata knots
    ) external initializer {
        if (
            registry_ == address(0) || eusd_ == address(0) || money_ == address(0) || spy_ == address(0)
                || rewardSource_ == address(0)
        ) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
        _eusd = IERC20(eusd_);
        _money = IERC20(money_);
        _spy = IERC20(spy_);
        rewardSource = rewardSource_;
        emit RewardSourceSet(rewardSource_);
        rewardsDuration = 7 days;
        emit RewardsDurationSet(7 days);
        priceMaxAge = 24 hours;
        emit PriceMaxAgeSet(24 hours);
        maxBoostBps = 36_000;
        emit MaxBoostSet(36_000);
        _setCurve(knots);
    }

    /// @dev UUPS upgrade gate: ADMIN (via ProtocolRegistry) only.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

    // ──────────────────────────────────────────────────────────
    //  External — user actions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakingV2
    function stake(
        uint256 money,
        uint256 eusd
    ) external override nonReentrant {
        if (money == 0 && eusd == 0) revert ZeroAmount();
        _settle(msg.sender);

        Position storage p = _positions[msg.sender];
        uint256 oldWeight = p.eusdStaked * p.boostBps / BPS;
        if (eusd != 0) {
            uint256 totalAfter = totalEusdStaked + eusd;
            if (stakeCap != 0 && totalAfter > stakeCap) revert StakeCapExceeded(totalAfter, stakeCap);
            totalEusdStaked = totalAfter;
            p.eusdStaked += eusd;
        }
        if (money != 0) {
            totalMoneyStaked += money;
            p.moneyStaked += money;
        }
        _resnapshotBoost(p, oldWeight);
        emit Staked(msg.sender, money, eusd, p.boostBps);

        if (money != 0) _money.safeTransferFrom(msg.sender, address(this), money);
        if (eusd != 0) _eusd.safeTransferFrom(msg.sender, address(this), eusd);
    }

    /// @inheritdoc IOwnStakingV2
    function unstake(
        uint256 money,
        uint256 eusd
    ) external override nonReentrant {
        _unstake(money, eusd);
    }

    /// @inheritdoc IOwnStakingV2
    function claim(
        address to
    ) external override nonReentrant returns (uint256 amount) {
        return _claim(to);
    }

    /// @inheritdoc IOwnStakingV2
    function exit() external override nonReentrant {
        Position storage p = _positions[msg.sender];
        _unstake(p.moneyStaked, p.eusdStaked);
        _claim(msg.sender);
    }

    /// @inheritdoc IOwnStakingV2
    /// @dev Unbounded caller-chosen loop: gas is the caller's own concern and each iteration only
    ///      re-prices one position, so the worst case is the caller's out-of-gas.
    function refreshBoost(
        address[] calldata users
    ) external override {
        uint256 len = users.length;
        for (uint256 i; i < len; ++i) {
            address user = users[i];
            _settle(user);
            Position storage p = _positions[user];
            uint256 oldBoost = p.boostBps;
            _resnapshotBoost(p, p.eusdStaked * oldBoost / BPS);
            emit BoostRefreshed(user, oldBoost, p.boostBps);
        }
    }

    /// @inheritdoc IOwnStakingV2
    function syncRewards() external override nonReentrant returns (uint256 amount) {
        uint256 held = _spy.balanceOf(address(this));
        // held >= accounted always: accounted only grows with actual transfers in.
        amount = held - _accountedRewards;
        if (amount == 0) revert NothingToSync();
        _accountedRewards = held;
        _notify(amount);
        emit RewardsSynced(amount);
    }

    // ──────────────────────────────────────────────────────────
    //  External — operator
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakingV2
    /// @dev The reward source's live allowance to this contract bounds the pull on-chain, so a
    ///      compromised operator key can at worst stream the approved budget early — funds can
    ///      only ever move from the source into this contract.
    function notifyRewardAmount(
        uint256 amount
    ) external override onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accountedRewards += amount;
        _notify(amount);
        _spy.safeTransferFrom(rewardSource, address(this), amount);
    }

    /// @inheritdoc IOwnStakingV2
    function renotifyUndistributed() external override onlyOperator nonReentrant returns (uint256 amount) {
        // Settle the index first so the bucket includes every zero-weight second up to now.
        _updateGlobal();
        amount = undistributed;
        if (amount == 0) revert NoUndistributed();
        undistributed = 0;
        // Already held and accounted — re-enters the stream without a transfer.
        _notify(amount);
        emit UndistributedRenotified(amount);
    }

    // ──────────────────────────────────────────────────────────
    //  External — admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakingV2
    function setCurve(
        Knot[] calldata knots
    ) external override onlyAdmin {
        _setCurve(knots);
    }

    /// @inheritdoc IOwnStakingV2
    function setStakeCap(
        uint256 cap
    ) external override onlyAdmin {
        stakeCap = cap;
        emit StakeCapSet(cap);
    }

    /// @inheritdoc IOwnStakingV2
    /// @dev Existing snapshots above a lowered cap keep earning at their snapshot until the next
    ///      touch or refresh — the cap clamps at evaluation time, not retroactively.
    function setMaxBoost(
        uint256 maxBoostBps_
    ) external override onlyAdmin {
        if (maxBoostBps_ == 0) revert ZeroAmount();
        maxBoostBps = maxBoostBps_;
        emit MaxBoostSet(maxBoostBps_);
    }

    /// @inheritdoc IOwnStakingV2
    function setRewardsDuration(
        uint256 duration
    ) external override onlyAdmin {
        if (duration == 0) revert ZeroAmount();
        _updateGlobal();
        if (block.timestamp < periodFinish) {
            // Re-stream the in-flight remainder over the new window from now: total payout is
            // unchanged and the rate moves once, without a gap or a double-count.
            uint256 leftoverScaled = rewardRate * (periodFinish - block.timestamp);
            rewardRate = leftoverScaled / duration;
            periodFinish = block.timestamp + duration;
            _lastUpdateTime = block.timestamp;
        }
        rewardsDuration = duration;
        emit RewardsDurationSet(duration);
    }

    /// @inheritdoc IOwnStakingV2
    function setPriceMaxAge(
        uint256 maxAge
    ) external override onlyAdmin {
        if (maxAge == 0) revert ZeroAmount();
        priceMaxAge = maxAge;
        emit PriceMaxAgeSet(maxAge);
    }

    /// @inheritdoc IOwnStakingV2
    function setRewardSource(
        address source
    ) external override onlyAdmin {
        if (source == address(0)) revert ZeroAddress();
        rewardSource = source;
        emit RewardSourceSet(source);
    }

    /// @inheritdoc IOwnStakingV2
    /// @dev SPY, eUSD and $MONEY are never rescuable — user deposits and the reward stream live
    ///      on this contract's balance.
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external override onlyAdmin nonReentrant {
        if (token == address(_spy) || token == address(_eusd) || token == address(_money)) {
            revert ProtectedToken(token);
        }
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — position flows
    // ──────────────────────────────────────────────────────────

    /// @dev Shared unstake body; callers hold the reentrancy guard.
    function _unstake(
        uint256 money,
        uint256 eusd
    ) private {
        if (money == 0 && eusd == 0) revert ZeroAmount();
        _settle(msg.sender);

        Position storage p = _positions[msg.sender];
        if (money > p.moneyStaked || eusd > p.eusdStaked) revert InsufficientStake();
        uint256 oldWeight = p.eusdStaked * p.boostBps / BPS;
        if (eusd != 0) {
            p.eusdStaked -= eusd;
            totalEusdStaked -= eusd;
        }
        if (money != 0) {
            p.moneyStaked -= money;
            totalMoneyStaked -= money;
        }
        _resnapshotBoost(p, oldWeight);
        emit Unstaked(msg.sender, money, eusd, p.boostBps);

        if (money != 0) _money.safeTransfer(msg.sender, money);
        if (eusd != 0) _eusd.safeTransfer(msg.sender, eusd);
    }

    /// @dev Shared claim body; callers hold the reentrancy guard.
    function _claim(
        address to
    ) private returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        _settle(msg.sender);
        Position storage p = _positions[msg.sender];
        amount = p.rewardsOwed;
        if (amount == 0) return 0;
        p.rewardsOwed = 0;
        _accountedRewards -= amount;
        _spy.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — reward accounting
    // ──────────────────────────────────────────────────────────

    /// @dev Advance the global index to now. Seconds that pass with zero total weight bank their
    ///      slice into {undistributed} instead of inflating the index, so the first staker in can
    ///      never sweep a backlog and nothing is lost.
    function _updateGlobal() private {
        uint256 applicable = _lastTimeRewardApplicable();
        uint256 dt = applicable - _lastUpdateTime;
        if (dt != 0 && rewardRate != 0) {
            uint256 accruedScaled = rewardRate * dt;
            uint256 weight = totalWeight;
            if (weight == 0) {
                undistributed += accruedScaled / PRECISION;
            } else {
                _rewardPerWeightStored += accruedScaled / weight;
            }
        }
        _lastUpdateTime = applicable;
    }

    /// @dev Settle a position's accrued rewards at its current (pre-change) weight.
    function _settle(
        address user
    ) private {
        _updateGlobal();
        Position storage p = _positions[user];
        uint256 weight = p.eusdStaked * p.boostBps / BPS;
        if (weight != 0) {
            p.rewardsOwed += weight * (_rewardPerWeightStored - p.rewardIndexPaid) / PRECISION;
        }
        p.rewardIndexPaid = _rewardPerWeightStored;
    }

    /// @dev Re-snapshot a settled position's boost at the current oracle price and fold the
    ///      weight change into the total. Must run after {_settle}; `oldWeight` is the position's
    ///      weight before any amount mutation — the weight its rewards were just settled at.
    function _resnapshotBoost(
        Position storage p,
        uint256 oldWeight
    ) private {
        uint256 newBoost = _boostFor(p.moneyStaked, p.eusdStaked);
        uint256 newWeight = p.eusdStaked * newBoost / BPS;
        p.boostBps = newBoost;
        totalWeight = totalWeight - oldWeight + newWeight;
    }

    /// @dev Fold `amount` (already held or about to be pulled) into the linear stream: any
    ///      unstreamed remainder joins the new batch and both vest over a fresh window, so the
    ///      rate never drops discontinuously and a batch cannot be sniped.
    function _notify(
        uint256 amount
    ) private {
        _updateGlobal();
        uint256 duration = rewardsDuration;
        uint256 scaled = amount * PRECISION;
        if (block.timestamp < periodFinish) {
            scaled += rewardRate * (periodFinish - block.timestamp);
        }
        rewardRate = scaled / duration;
        periodFinish = block.timestamp + duration;
        _lastUpdateTime = block.timestamp;
        emit RewardNotified(msg.sender, amount, rewardRate);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — boost pricing
    // ──────────────────────────────────────────────────────────

    /// @dev Replace the curve after validating monotonicity: at least two knots, coverage
    ///      strictly increasing, boost non-decreasing, capped by {maxBoostBps}.
    function _setCurve(
        Knot[] calldata knots
    ) private {
        uint256 len = knots.length;
        if (len < 2) revert InvalidCurve();
        for (uint256 i; i < len; ++i) {
            if (i != 0) {
                if (knots[i].coverageBps <= knots[i - 1].coverageBps) revert InvalidCurve();
                if (knots[i].boostBps < knots[i - 1].boostBps) revert InvalidCurve();
            }
            if (knots[i].boostBps > maxBoostBps) revert InvalidCurve();
        }
        delete _curve;
        for (uint256 i; i < len; ++i) {
            _curve.push(knots[i]);
        }
        emit CurveSet(knots);
    }

    /// @dev Boost for a hypothetical position at the current oracle price. A position with no
    ///      eUSD carries no weight, so its boost is 0; an unusable price (stale, zero, missing)
    ///      evaluates at zero coverage — the curve floor — never reverting.
    function _boostFor(
        uint256 money,
        uint256 eusd
    ) private view returns (uint256) {
        if (eusd == 0) return 0;
        uint256 coverageBps;
        if (money != 0) {
            uint256 price = _moneyPrice();
            if (price != 0) {
                coverageBps = Math.mulDiv(money, price * BPS, eusd * PRECISION);
            }
        }
        uint256 boost = _evalCurve(coverageBps);
        return boost > maxBoostBps ? maxBoostBps : boost;
    }

    /// @dev Piecewise-linear interpolation over the knots, clamped to the first and last.
    function _evalCurve(
        uint256 coverageBps
    ) private view returns (uint256) {
        Knot[] storage knots = _curve;
        uint256 last = knots.length - 1;
        if (coverageBps <= knots[0].coverageBps) return knots[0].boostBps;
        if (coverageBps >= knots[last].coverageBps) return knots[last].boostBps;
        for (uint256 i = 1; i <= last; ++i) {
            Knot memory hi = knots[i];
            if (coverageBps <= hi.coverageBps) {
                Knot memory lo = knots[i - 1];
                return lo.boostBps + (uint256(hi.boostBps) - lo.boostBps) * (coverageBps - lo.coverageBps)
                    / (uint256(hi.coverageBps) - lo.coverageBps);
            }
        }
        // Unreachable: coverage below the last knot always lands in a segment.
        return knots[last].boostBps;
    }

    /// @dev Current $MONEY price from the registry's in-house oracle; 0 when the oracle is unset,
    ///      reverts (stale / unavailable), returns zero, or the price is older than
    ///      {priceMaxAge}. Callers treat 0 as "floor the boost" — the oracle never gates funds.
    function _moneyPrice() private view returns (uint256) {
        address oracle = registry.inhouseOracle();
        if (oracle == address(0) || oracle.code.length == 0) return 0;
        try IOracleVerifier(oracle).getPrice(MONEY_TICKER) returns (uint256 price, uint256 timestamp) {
            if (price == 0 || block.timestamp > timestamp + priceMaxAge) return 0;
            return price;
        } catch {
            return 0;
        }
    }

    /// @dev The stream accrues only up to its end.
    function _lastTimeRewardApplicable() private view returns (uint256) {
        uint256 finish = periodFinish;
        return block.timestamp < finish ? block.timestamp : finish;
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnStakingV2
    function position(
        address user
    ) external view override returns (Position memory) {
        return _positions[user];
    }

    /// @inheritdoc IOwnStakingV2
    function earned(
        address user
    ) external view override returns (uint256) {
        Position storage p = _positions[user];
        uint256 weight = p.eusdStaked * p.boostBps / BPS;
        uint256 rewardPerWeight = _rewardPerWeightStored;
        uint256 globalWeight = totalWeight;
        uint256 applicable = _lastTimeRewardApplicable();
        if (globalWeight != 0 && applicable > _lastUpdateTime && rewardRate != 0) {
            rewardPerWeight += rewardRate * (applicable - _lastUpdateTime) / globalWeight;
        }
        return p.rewardsOwed + weight * (rewardPerWeight - p.rewardIndexPaid) / PRECISION;
    }

    /// @inheritdoc IOwnStakingV2
    function boostBps(
        address user
    ) external view override returns (uint256) {
        return _positions[user].boostBps;
    }

    /// @inheritdoc IOwnStakingV2
    function previewBoost(
        uint256 money,
        uint256 eusd
    ) external view override returns (uint256) {
        return _boostFor(money, eusd);
    }

    /// @inheritdoc IOwnStakingV2
    function moneyPrice() external view override returns (uint256) {
        return _moneyPrice();
    }

    /// @inheritdoc IOwnStakingV2
    function curve() external view override returns (Knot[] memory) {
        return _curve;
    }
}
