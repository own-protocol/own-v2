// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {IPositionManager} from "../interfaces/external/IPositionManager.sol";
import {BPS_TO_WAD, YieldPoint} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {EpochHistory} from "./libraries/EpochHistory.sol";
import {PositionFees} from "./libraries/PositionFees.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundStaking — staked fund token vault with premium-based issuance
/// @notice See {IFundStaking}.
/// @dev Beacon proxy per fund. Share maths uses one virtual share and one virtual asset, which
///      makes first-depositor donation attacks unprofitable. Staked LP positions are paid from one
///      yield-per-liquidity counter: every full-range position holds the same fund tokens per unit
///      of liquidity at a given price, so the counter pays each in proportion to its fund tokens.
contract FundStaking is IFundStaking, ERC20, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EpochHistory for EpochHistory.History;
    using PoolIdLibrary for PoolKey;

    /// @notice Longest period one accrual covers. Yield is distributed every 8 hours, so one
    ///         premium reading never sets the rate for longer than that.
    uint256 public constant MAX_ACCRUAL_PERIOD = 8 hours;

    /// @notice Maximum number of yield curve points.
    uint256 public constant MAX_YIELD_POINTS = 8;

    /// @notice Curators' share of staker yield a new fund starts with: 15%.
    uint16 public constant DEFAULT_CURATOR_YIELD_BPS = 1500;

    /// @notice Hard cap on the curators' share of staker yield.
    uint16 public constant MAX_CURATOR_YIELD_BPS = 5000;

    uint256 private constant YEAR = 365 days;

    // Same weekly epoch as the governor's.
    uint256 private constant EPOCH = 1 weeks;

    uint256 private constant Q128 = 1 << 128;

    struct LpPosition {
        address owner;
        uint128 liquidity;
        uint256 paid;
    }

    /// @inheritdoc IFundStaking
    IPositionManager public immutable override positionManager;

    /// @inheritdoc IFundStaking
    address public override fund;

    /// @inheritdoc IFundStaking
    uint64 public override lastAccrual;

    // The fund's depositorUnlockAt, which never changes once set at launch; zero until first read.
    uint32 private _unlockAt;

    YieldPoint[] private _curve;

    // Tracked rather than read from the balance, so donated fund tokens earn no yield.
    uint256 private _totalStaked;

    /// @inheritdoc IFundStaking
    mapping(address account => uint256) public override lockedShares;

    IFundFactory private _factory;

    EpochHistory.History private _supply;

    /// @inheritdoc IFundStaking
    uint128 public override lpLiquidity;

    // Fund tokens owed per unit of staked LP liquidity since launch, Q128.
    uint256 private _lpYieldPerLiquidity;

    mapping(uint256 tokenId => LpPosition) private _positions;

    /// @inheritdoc IFundStaking
    uint16 public override curatorYieldBps;

    /// @inheritdoc IFundStaking
    uint16 public override curatorYieldCapBps;

    mapping(address account => Lock[]) private _locks;

    /// @param positionManager_ The Uniswap v4 PositionManager whose positions can be staked.
    constructor(
        address positionManager_
    ) ERC20("", "") {
        if (positionManager_ == address(0)) revert ZeroAddress();
        positionManager = IPositionManager(positionManager_);
        _disableInitializers();
    }

    /// @inheritdoc IFundStaking
    function initialize(address fund_, YieldPoint[] calldata curve_) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
        _factory = IFundFactory(IFund(fund_).factory());
        lastAccrual = uint64(block.timestamp);
        _setCurve(curve_);
        _setCuratorYield(DEFAULT_CURATOR_YIELD_BPS, 0);
    }

    /// @inheritdoc IFundStaking
    function stake(uint256 assets, address receiver) external override nonReentrant returns (uint256 shares) {
        return _stake(assets, receiver);
    }

    /// @inheritdoc IFundStaking
    function transferLocked(address to, uint256 shares) external override nonReentrant {
        if (msg.sender != IFund(fund).launch()) revert NotLaunch();
        _transfer(msg.sender, to, shares);
        _addLock(to, shares);
    }

    /// @inheritdoc IFundStaking
    function stakeLocked(
        address account,
        uint256 assets,
        uint64 unlockAt
    ) external override nonReentrant returns (uint256 lockId) {
        if (msg.sender != fund) revert NotFund();
        _accrue();
        uint256 shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();
        _totalStaked += assets;
        _mint(address(this), shares);
        lockId = _locks[account].length;
        _locks[account].push(Lock({shares: SafeCast.toUint128(shares), unlockAt: unlockAt}));
        emit MintLocked(account, lockId, assets, shares, unlockAt);
    }

    /// @inheritdoc IFundStaking
    function claimLocks(
        uint256[] calldata lockIds
    ) external override nonReentrant returns (uint256 shares) {
        Lock[] storage locks = _locks[msg.sender];
        for (uint256 i; i < lockIds.length; ++i) {
            uint256 id = lockIds[i];
            if (id >= locks.length) revert LockNotClaimable(id);
            Lock memory lock = locks[id];
            if (lock.shares == 0 || block.timestamp < lock.unlockAt) revert LockNotClaimable(id);
            locks[id].shares = 0;
            shares += lock.shares;
            emit LockClaimed(msg.sender, id, lock.shares);
        }
        if (shares != 0) _transfer(address(this), msg.sender, shares);
    }

    /// @inheritdoc IFundStaking
    function unstake(uint256 shares, address receiver) external override nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _accrue();
        assets = convertToAssets(shares);
        _totalStaked -= assets;
        uint256 lockedBefore = _activeLock(msg.sender);
        _burn(msg.sender, shares);
        IERC20(fund).safeTransfer(receiver, assets);
        if (lockedBefore != 0) {
            uint256 lockedAfter = lockedShares[msg.sender];
            if (lockedAfter != lockedBefore && receiver != msg.sender) revert SharesLocked();
            // Rounds up: unstaking locked shares never yields unlocked fund tokens.
            uint256 lockedAssets = Math.mulDiv(assets, lockedBefore - lockedAfter, shares, Math.Rounding.Ceil);
            IFund(fund).addLaunchLock(receiver, Math.min(lockedAssets, assets));
        }
        emit Unstaked(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IFundStaking
    function stakePosition(
        uint256 tokenId
    ) external override nonReentrant {
        positionManager.transferFrom(msg.sender, address(this), tokenId);
        _stakePosition(tokenId, msg.sender);
    }

    /// @notice Stakes a position sent with `safeTransferFrom`, for the address it came from.
    /// @param from    Previous owner, credited with the position.
    /// @param tokenId The position.
    /// @return The receiver selector.
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override nonReentrant returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        _stakePosition(tokenId, from);
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IFundStaking
    function unstakePosition(uint256 tokenId, address to) external override nonReentrant returns (uint256 paid) {
        if (to == address(0)) revert ZeroAddress();
        LpPosition storage p = _ownedPosition(tokenId);
        _accrue();
        paid = _payPosition(tokenId, p, to);
        lpLiquidity -= p.liquidity;
        delete _positions[tokenId];
        positionManager.safeTransferFrom(address(this), to, tokenId);
        emit PositionUnstaked(msg.sender, tokenId, to);
    }

    /// @inheritdoc IFundStaking
    function claimPositionYield(uint256 tokenId, address to) external override nonReentrant returns (uint256 paid) {
        if (to == address(0)) revert ZeroAddress();
        LpPosition storage p = _ownedPosition(tokenId);
        _accrue();
        paid = _payPosition(tokenId, p, to);
    }

    /// @inheritdoc IFundStaking
    function collectPositionFees(uint256 tokenId, address to) external override nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _ownedPosition(tokenId);
        PositionFees.collect(positionManager, tokenId, to);
        emit PositionFeesCollected(tokenId, to);
    }

    /// @inheritdoc IFundStaking
    function recoverPosition(uint256 tokenId, address to) external override nonReentrant {
        if (!_factory.isAdmin(msg.sender)) revert NotAdmin();
        if (_positions[tokenId].owner != address(0)) revert PositionIsStaked();
        positionManager.safeTransferFrom(address(this), to, tokenId);
    }

    /// @inheritdoc IFundStaking
    function accrue() external override nonReentrant returns (uint256 minted) {
        return _accrue();
    }

    /// @inheritdoc IFundStaking
    function setYieldCurve(
        YieldPoint[] calldata curve_
    ) external override nonReentrant {
        if (!_factory.isAdmin(msg.sender)) revert NotAdmin();
        _accrue();
        _setCurve(curve_);
    }

    /// @inheritdoc IFundStaking
    function setCuratorYield(uint16 shareBps, uint16 capBpsPerYear) external override nonReentrant {
        if (!_factory.isAdmin(msg.sender)) revert NotAdmin();
        _accrue();
        _setCuratorYield(shareBps, capBpsPerYear);
    }

    /// @notice Share token name, following the fund's current name.
    /// @return The name.
    function name() public view override returns (string memory) {
        return string.concat("Staked ", IERC20Metadata(fund).name());
    }

    /// @notice Share token symbol, following the fund's current symbol.
    /// @return The symbol.
    function symbol() public view override returns (string memory) {
        return string.concat("s", IERC20Metadata(fund).symbol());
    }

    /// @inheritdoc IFundStaking
    function totalAssets() public view override returns (uint256) {
        return _totalStaked;
    }

    /// @inheritdoc IFundStaking
    function totalSupplyAt(
        uint256 epoch
    ) external view override returns (uint256) {
        return _supply.valueAt(epoch);
    }

    /// @inheritdoc IFundStaking
    function positionOf(
        uint256 tokenId
    ) external view override returns (address owner, uint128 liquidity) {
        LpPosition storage p = _positions[tokenId];
        return (p.owner, p.liquidity);
    }

    /// @inheritdoc IFundStaking
    function pendingPositionYield(
        uint256 tokenId
    ) external view override returns (uint256) {
        LpPosition storage p = _positions[tokenId];
        return Math.mulDiv(p.liquidity, _lpYieldPerLiquidity - p.paid, Q128);
    }

    /// @inheritdoc IFundStaking
    function locksOf(
        address account
    ) external view override returns (Lock[] memory) {
        return _locks[account];
    }

    /// @inheritdoc IFundStaking
    function yieldCurve() external view override returns (YieldPoint[] memory) {
        return _curve;
    }

    /// @inheritdoc IFundStaking
    function rateForPremium(
        int256 premiumBps
    ) public view override returns (uint256 rate) {
        uint256 n = _curve.length;
        if (n == 0 || premiumBps < int256(uint256(_curve[0].premiumBps))) return 0;
        uint256 p = uint256(premiumBps);
        uint256 i = 1;
        while (i < n && p >= _curve[i].premiumBps) {
            ++i;
        }
        YieldPoint memory lo = _curve[i - 1];
        rate = uint256(lo.rateBpsPerYear) * BPS_TO_WAD;
        if (i < n) {
            YieldPoint memory hi = _curve[i];
            uint256 span = hi.premiumBps - lo.premiumBps;
            uint256 hiRate = uint256(hi.rateBpsPerYear) * BPS_TO_WAD;
            rate = hiRate >= rate
                ? rate + Math.mulDiv(hiRate - rate, p - lo.premiumBps, span)
                : rate - Math.mulDiv(rate - hiRate, p - lo.premiumBps, span, Math.Rounding.Ceil);
        }
        uint256 cap = _maxRate() * BPS_TO_WAD;
        if (rate > cap) rate = cap;
    }

    /// @inheritdoc IFundStaking
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        // Rounds down: stakers never receive more shares than their deposit is worth.
        return Math.mulDiv(assets, totalSupply() + 1, totalAssets() + 1);
    }

    /// @inheritdoc IFundStaking
    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {
        // Rounds down: unstakers never take more than their shares are worth.
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply() + 1);
    }

    /// @dev With `allLocked` every new share is locked; otherwise as many as the launch-locked fund
    ///      tokens moved in, rounded up so a locked deposit never yields an unlocked share.
    function _stake(uint256 assets, address receiver) internal returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _accrue();
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();
        _totalStaked += assets;
        uint256 moved = block.timestamp < _depositorUnlockAt() ? IFund(fund).releaseLaunchLock(msg.sender, assets) : 0;
        uint256 locked = Math.min(Math.mulDiv(shares, moved, assets, Math.Rounding.Ceil), shares);
        IERC20(fund).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        if (locked != 0) _addLock(receiver, locked);
        emit Staked(msg.sender, receiver, assets, shares);
    }

    /// @dev Mints the yield owed since the last accrual, at the rate of the premium read now, to
    ///      stakers and to staked LP positions (on their fund tokens at the pool TWAP; LP yield is
    ///      held here until claimed). The curators get `curatorYieldBps` of the stakers' yield minted
    ///      on top (capped by `curatorYieldCapBps` of the staked balance a year when set), paid to the
    ///      curators module as shares, so it stays staked. No yield without a fresh premium reading; the period is
    ///      still consumed, so a stale oracle can only withhold yield, never inflate it later.
    function _accrue() internal returns (uint256 minted) {
        uint256 last = lastAccrual;
        if (block.timestamp <= last) return 0;
        uint256 elapsed = block.timestamp - last;
        if (elapsed > MAX_ACCRUAL_PERIOD) elapsed = MAX_ACCRUAL_PERIOD;
        lastAccrual = uint64(block.timestamp);

        uint256 staked = totalAssets();
        bool stakers = staked != 0 && totalSupply() != 0;
        uint128 lpLiq = lpLiquidity;
        if (!stakers && lpLiq == 0) return 0;

        (bool ok, int256 premium) = IFund(fund).premiumBps();
        if (!ok) return 0;
        uint256 rate = rateForPremium(premium);
        if (rate == 0) return 0;

        uint256 curatorShares;
        if (stakers) {
            uint256 stakerYield = Math.mulDiv(staked, rate * elapsed, PRECISION * YEAR);
            uint256 cut = Math.mulDiv(stakerYield, curatorYieldBps, BPS);
            uint256 cap = curatorYieldCapBps;
            if (cap != 0) cut = Math.min(cut, Math.mulDiv(staked, cap * elapsed, BPS * YEAR));
            // Priced after the stakers' yield lands, so the shares are worth `cut`, rounded down.
            if (cut != 0) curatorShares = Math.mulDiv(cut, totalSupply() + 1, staked + stakerYield + 1);
            minted = stakerYield + cut;
            _totalStaked += minted;
        }
        uint256 lpMinted;
        if (lpLiq != 0) {
            (, uint256 lpTokens) = IFundHook(_factory.hook()).liquidityAmounts(fund, lpLiq);
            lpMinted = Math.mulDiv(lpTokens, rate * elapsed, PRECISION * YEAR);
            _lpYieldPerLiquidity += Math.mulDiv(lpMinted, Q128, lpLiq);
        }
        if (minted + lpMinted != 0) IFund(fund).moduleMint(address(this), minted + lpMinted);
        if (curatorShares != 0) {
            address cur = IFund(fund).curators();
            _mint(cur, curatorShares);
            IFundCurators(cur).notifyYield();
        }
        emit YieldAccrued(elapsed, premium, rate, minted, lpMinted, curatorShares);
    }

    /// @dev Takes custody of a full-range position in the fund's pool. Its liquidity cannot change
    ///      while staked: only the owner (this contract) can modify it.
    function _stakePosition(uint256 tokenId, address owner) internal {
        (PoolKey memory key, uint256 info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolKey memory fundKey = IFundHook(_factory.hook()).poolKeyOf(fund);
        if (address(fundKey.hooks) == address(0) || PoolId.unwrap(key.toId()) != PoolId.unwrap(fundKey.toId())) {
            revert NotFundPosition();
        }
        // PositionInfo packs tick lower at bits 8-31 and tick upper at bits 32-55.
        if (
            int24(uint24(info >> 8)) != TickMath.minUsableTick(key.tickSpacing)
                || int24(uint24(info >> 32)) != TickMath.maxUsableTick(key.tickSpacing)
        ) revert NotFullRange();
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert ZeroAmount();
        _accrue();
        lpLiquidity += liquidity;
        _positions[tokenId] = LpPosition({owner: owner, liquidity: liquidity, paid: _lpYieldPerLiquidity});
        emit PositionStaked(owner, tokenId, liquidity);
    }

    function _ownedPosition(
        uint256 tokenId
    ) internal view returns (LpPosition storage p) {
        p = _positions[tokenId];
        if (p.owner != msg.sender) revert NotPositionOwner();
    }

    function _payPosition(uint256 tokenId, LpPosition storage p, address to) internal returns (uint256 paid) {
        uint256 acc = _lpYieldPerLiquidity;
        // Rounds down: positions are never paid more than was minted for them.
        paid = Math.mulDiv(p.liquidity, acc - p.paid, Q128);
        p.paid = acc;
        if (paid != 0) IERC20(fund).safeTransfer(to, paid);
        emit PositionYieldClaimed(tokenId, to, paid);
    }

    /// @dev Locked shares can leave an account only by being burned (unstake, which moves the lock
    ///      back onto the fund tokens) or by going into the governor, which returns them to the
    ///      same account; shares held in the governor still count towards the account's holdings.
    function _update(address from, address to, uint256 value) internal override {
        uint256 locked = from == address(0) ? 0 : _activeLock(from);
        address gov = locked == 0 ? address(0) : IFund(fund).governor();
        uint256 escrowed = locked == 0 ? 0 : IFundGovernor(gov).escrowOf(from, address(this));
        if (locked != 0 && to != address(0) && to != gov && balanceOf(from) + escrowed < value + locked) {
            revert SharesLocked();
        }
        super._update(from, to, value);
        if (locked != 0 && to == address(0)) {
            uint256 held = balanceOf(from) + escrowed;
            if (locked > held) {
                lockedShares[from] = held;
                emit LockedSharesSet(from, held);
            }
        }
        if (from == address(0) || to == address(0)) _recordSupply();
    }

    /// @dev New shares count from the next epoch; burned shares leave the current epoch at once, so
    ///      staking and unstaking within an epoch never raises that epoch's supply.
    function _recordSupply() internal {
        uint256 e = block.timestamp / EPOCH;
        uint256 live = totalSupply();
        _supply.set(e, Math.min(_supply.valueAt(e), live), live);
    }

    function _addLock(address account, uint256 shares) internal {
        if (block.timestamp >= _depositorUnlockAt()) return;
        uint256 locked = lockedShares[account] + shares;
        lockedShares[account] = locked;
        emit LockedSharesSet(account, locked);
    }

    function _activeLock(
        address account
    ) internal returns (uint256) {
        uint256 locked = lockedShares[account];
        if (locked == 0 || block.timestamp >= _depositorUnlockAt()) return 0;
        return locked;
    }

    function _depositorUnlockAt() internal returns (uint256 at) {
        at = _unlockAt;
        if (at == 0) {
            at = IFund(fund).depositorUnlockAt();
            if (at != 0 && at <= type(uint32).max) _unlockAt = uint32(at);
        }
    }

    function _setCurve(
        YieldPoint[] calldata curve_
    ) internal {
        if (curve_.length > MAX_YIELD_POINTS) revert InvalidYieldCurve();
        uint256 cap = _maxRate();
        delete _curve;
        for (uint256 i; i < curve_.length; ++i) {
            if (curve_[i].rateBpsPerYear > cap) revert InvalidYieldCurve();
            if (i != 0 && curve_[i].premiumBps <= curve_[i - 1].premiumBps) revert InvalidYieldCurve();
            _curve.push(curve_[i]);
        }
        emit YieldCurveSet(curve_);
    }

    function _setCuratorYield(uint16 shareBps, uint16 capBpsPerYear) internal {
        if (shareBps > MAX_CURATOR_YIELD_BPS) revert InvalidCuratorYield();
        curatorYieldBps = shareBps;
        curatorYieldCapBps = capBpsPerYear;
        emit CuratorYieldSet(shareBps, capBpsPerYear);
    }

    function _maxRate() internal view returns (uint256) {
        return _factory.maxYieldRateBpsPerYear();
    }
}
