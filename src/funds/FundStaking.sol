// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {IFundVenue} from "../interfaces/IFundVenue.sol";
import {IPositionManager} from "../interfaces/external/IPositionManager.sol";
import {BPS_TO_WAD, PremiumConfig, Valuation, ValuationLib, YieldPoint} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {EpochHistory} from "./libraries/EpochHistory.sol";
import {LpPositions} from "./libraries/LpPositions.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FundStaking — staked fund token vault with tiered yield, Premium Boost and Premium Pot
/// @notice See {IFundStaking}.
/// @dev Beacon proxy per fund. Share maths uses one virtual share and one virtual asset, which
///      makes first-depositor donation attacks unprofitable. Staked LP positions are paid from one
///      yield-per-liquidity counter: every full-range position holds the same fund tokens per unit
///      of liquidity at a given price, so the counter pays each in proportion to its fund tokens.
///      Boosts are settled lazily per account, and the pot drips through the share price, so
///      neither needs a loop or a global index.
contract FundStaking is IFundStaking, ERC20, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EpochHistory for EpochHistory.History;
    using ValuationLib for Valuation;

    // Maximum number of yield curve points.
    uint256 private constant MAX_YIELD_POINTS = 8;

    // Curators' share of staker yield a new fund starts with: 15%.
    uint16 private constant DEFAULT_CURATOR_YIELD_BPS = 1500;

    // Hard cap on the curators' share of staker yield.
    uint16 private constant MAX_CURATOR_YIELD_BPS = 5000;

    uint16 private constant MAX_REFERRAL_YIELD_BPS = 3000;

    uint256 private constant YEAR = 365 days;

    // Below one whole share staked the pot is burned into backing: dripping it onto dust would
    // inflate the share price until new stakes round to nothing.
    uint256 private constant MIN_POT_SHARES = 1e18;

    // Same weekly epoch as the governor's.
    uint256 private constant EPOCH = 1 weeks;

    uint256 private constant Q128 = 1 << 128;

    struct LpPosition {
        address owner;
        uint32 epoch;
        uint128 liquidity;
        uint256 paid;
    }

    /// @dev The fund's valuation, read at most once per call: what the call then mints is applied
    ///      to it rather than valuing the basket again.
    struct Snapshot {
        bool read;
        Valuation v;
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

    mapping(address account => Boost) private _boosts;

    mapping(address account => MintLock) private _mintLocks;

    mapping(address account => MintLock) private _navLocks;

    /// @inheritdoc IFundStaking
    uint16 public override boostShareBps;

    /// @inheritdoc IFundStaking
    uint32 public override boostSpeedBpsPerYear;

    /// @inheritdoc IFundStaking
    uint32 public override potDripPeriod;

    /// @inheritdoc IFundStaking
    uint128 public override potLeft;

    /// @inheritdoc IFundStaking
    uint64 public override potEnd;

    uint64 private _potUpdatedAt;

    /// @inheritdoc IFundStaking
    uint256 public override potPending;

    // Rate of the last fresh premium reading: each accrual pays at the lower of it and the rate
    // read then, so no single reading prices the stretch on its own.
    uint128 private _lastRate;

    // False until the first fresh reading sets `_lastRate`.
    bool private _rateRead;

    /// @inheritdoc IFundStaking
    uint32 public override lpEpoch;

    // `_lpYieldPerLiquidity` when each earlier pool stopped earning.
    mapping(uint32 epoch => uint256) private _lpAccAtEnd;

    /// @inheritdoc IFundStaking
    address public override referralWallet;

    /// @inheritdoc IFundStaking
    uint16 public override referralYieldBps;

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
        IFundFactory fac = IFundFactory(IFund(fund_).factory());
        _factory = fac;
        lastAccrual = uint64(block.timestamp);
        _setCurve(curve_.length == 0 ? fac.defaultYieldCurve() : curve_);
        _setCuratorYield(DEFAULT_CURATOR_YIELD_BPS, 0);
        PremiumConfig memory c = fac.premiumConfig();
        _setPremiumConfig(c.boostShareBps, c.boostSpeedBpsPerYear, c.potDripPeriod);
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
    function stakeMinted(
        address account,
        uint256 assets,
        uint256 payment,
        uint256 boost,
        uint64 unlockAt,
        bool atNav
    ) external override nonReentrant returns (uint256 shares) {
        if (msg.sender != fund) revert NotFund();
        _accrueAndSettle(account);
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();
        _totalStaked += assets;
        _mint(account, shares);
        if (unlockAt > block.timestamp) _joinMintLock(account, shares, unlockAt, atNav);

        uint256 speed = Math.mulDiv(payment, boostSpeedBpsPerYear, BPS * YEAR);
        // A mint too small for any speed would never finish paying: its boost tokens go to backing.
        if (boost != 0 && speed == 0) {
            IFund(fund).burn(boost);
        } else if (boost != 0) {
            Boost storage b = _boosts[account];
            // A finished boost leaves no shares behind, so a new one starts from this mint alone.
            if (b.left == 0) b.shares = 0;
            b.perSec += SafeCast.toUint128(speed);
            b.left += SafeCast.toUint128(boost);
            b.shares += SafeCast.toUint128(shares);
            b.lastSettle = uint64(block.timestamp);
            emit BoostAdded(account, boost, b.perSec, b.left, b.shares);
        }
        emit Staked(msg.sender, account, assets, shares);
    }

    /// @inheritdoc IFundStaking
    function addPot(
        uint256 tokens
    ) external override {
        if (msg.sender != fund) revert NotFund();
        _checkpointPot();
        uint256 left = potLeft + tokens;
        uint64 end = uint64(block.timestamp + potDripPeriod);
        (potLeft, potEnd, _potUpdatedAt) = (SafeCast.toUint128(left), end, uint64(block.timestamp));
        emit PotAdded(tokens, left, end);
    }

    /// @inheritdoc IFundStaking
    function settleBoost(
        address account
    ) external override nonReentrant {
        _accrueAndSettle(account);
    }

    /// @inheritdoc IFundStaking
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut,
        address[] calldata skip
    ) external override nonReentrant returns (uint256[] memory amounts, uint256 usdgAmount) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _accrueAndSettle(msg.sender);
        uint256 assets = convertToAssets(shares);
        _totalStaked -= assets;
        _burn(msg.sender, shares);
        emit Unstaked(msg.sender, address(this), assets, shares);
        (amounts, usdgAmount) = IFund(fund).redeemSkipping(assets, receiver, minAmountsOut, minUsdgOut, skip);
    }

    /// @inheritdoc IFundStaking
    function setPremiumConfig(
        uint16 boostShareBps_,
        uint32 boostSpeedBpsPerYear_,
        uint32 potDripPeriod_
    ) external override nonReentrant {
        _checkAdmin();
        _accrue();
        _setPremiumConfig(boostShareBps_, boostSpeedBpsPerYear_, potDripPeriod_);
    }

    /// @notice Transfer shares, paying the sender's boost up to now first.
    /// @param to    Receiver.
    /// @param value Shares.
    /// @return True.
    function transfer(address to, uint256 value) public override(ERC20, IERC20) nonReentrant returns (bool) {
        _settleBefore(msg.sender);
        return super.transfer(to, value);
    }

    /// @notice Transfer shares on behalf of `from`, paying its boost up to now first.
    /// @param from  Owner.
    /// @param to    Receiver.
    /// @param value Shares.
    /// @return True.
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override(ERC20, IERC20) nonReentrant returns (bool) {
        _settleBefore(from);
        return super.transferFrom(from, to, value);
    }

    /// @inheritdoc IFundStaking
    function unstake(uint256 shares, address receiver) external override nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _accrueAndSettle(msg.sender);
        uint256 mintLocked = _activeMintLock(msg.sender);
        if (mintLocked != 0 && _held(msg.sender, IFund(fund).governor()) < shares + mintLocked) revert SharesLocked();
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
        if (p.epoch == lpEpoch) lpLiquidity -= p.liquidity;
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
        LpPositions.collectFees(positionManager, tokenId, to);
        emit PositionFeesCollected(tokenId, to);
    }

    /// @inheritdoc IFundStaking
    function recoverPosition(uint256 tokenId, address to) external override nonReentrant {
        _checkAdmin();
        if (_positions[tokenId].owner != address(0)) revert PositionIsStaked();
        positionManager.safeTransferFrom(address(this), to, tokenId);
    }

    /// @inheritdoc IFundStaking
    function poolMoved() external override nonReentrant {
        if (msg.sender != IFund(fund).venue()) revert NotVenue();
        _accrue();
        uint32 epoch = lpEpoch;
        _lpAccAtEnd[epoch] = _lpYieldPerLiquidity;
        lpEpoch = epoch + 1;
        lpLiquidity = 0;
        emit LpPoolMoved(epoch + 1);
    }

    /// @inheritdoc IFundStaking
    function accrue() external override nonReentrant returns (uint256 minted) {
        return _accrue();
    }

    /// @inheritdoc IFundStaking
    function setYieldCurve(
        YieldPoint[] calldata curve_
    ) external override nonReentrant {
        _checkAdmin();
        _accrue();
        _setCurve(curve_);
    }

    /// @inheritdoc IFundStaking
    function setCuratorYield(uint16 shareBps, uint16 capBpsPerYear) external override nonReentrant {
        _checkAdmin();
        _accrue();
        _setCuratorYield(shareBps, capBpsPerYear);
    }

    /// @inheritdoc IFundStaking
    function setReferralYield(uint16 shareBps, address wallet) external override nonReentrant {
        _checkAdmin();
        _accrue();
        if (shareBps > MAX_REFERRAL_YIELD_BPS || (shareBps != 0 && wallet == address(0))) {
            revert InvalidReferralYield();
        }
        (referralYieldBps, referralWallet) = (shareBps, wallet);
        emit ReferralYieldSet(shareBps, wallet);
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
        return Math.mulDiv(p.liquidity, _lpAccOf(p.epoch) - p.paid, Q128);
    }

    /// @inheritdoc IFundStaking
    function boostOf(
        address account
    ) external view override returns (Boost memory) {
        return _boosts[account];
    }

    /// @inheritdoc IFundStaking
    function pendingBoost(
        address account
    ) external view override returns (uint256) {
        Boost memory b = _boosts[account];
        return Math.min(uint256(b.perSec) * (block.timestamp - b.lastSettle), b.left);
    }

    /// @inheritdoc IFundStaking
    function mintLockOf(address account, bool atNav) external view override returns (MintLock memory) {
        return _lockOf(account, atNav);
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
        rate = Math.min(_curve[i - 1].rateBpsPerYear, _maxRate()) * BPS_TO_WAD;
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
        // A launch lock stays with its owner, as in `unstake`.
        if (moved != 0 && receiver != msg.sender) revert SharesLocked();
        uint256 locked = Math.min(Math.mulDiv(shares, moved, assets, Math.Rounding.Ceil), shares);
        IERC20(fund).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        if (locked != 0) _addLock(receiver, locked);
        emit Staked(msg.sender, receiver, assets, shares);
    }

    /// @dev Mints the yield owed since the last accrual, at the lower of the rate read now and the
    ///      rate read then, to stakers and to staked LP positions (on their fund tokens at the pool
    ///      TWAP; LP yield is held here until claimed). The curators get `curatorYieldBps` of the
    ///      stakers' yield minted on top (capped by `curatorYieldCapBps` of the staked balance a year
    ///      when set), paid to the curators module as shares, so it stays staked. Without a fresh
    ///      premium reading the clock waits, so the stretch is paid once a price is back.
    function _accrue() internal returns (uint256) {
        Snapshot memory s;
        return _accrue(s);
    }

    function _accrue(
        Snapshot memory s
    ) internal returns (uint256 minted) {
        if (block.timestamp <= lastAccrual) return 0;

        uint256 staked = totalAssets();
        bool stakers = staked != 0 && totalSupply() != 0;
        _releasePot(stakers);
        staked = totalAssets();
        uint128 lpLiq = lpLiquidity;
        if (!stakers && lpLiq == 0) {
            lastAccrual = uint64(block.timestamp);
            return 0;
        }

        (bool ok, int256 premium) = _valued(s).premiumBps();
        if (!ok) return 0;
        uint256 read = rateForPremium(premium);
        // The first reading has nothing to compare with; it covers only the stretch since staking began.
        uint256 rate = _rateRead ? Math.min(read, _lastRate) : read;
        (_lastRate, _rateRead) = (SafeCast.toUint128(read), true);
        uint256 elapsed = block.timestamp - lastAccrual;
        lastAccrual = uint64(block.timestamp);
        if (rate == 0) return 0;

        uint256 curatorShares;
        uint256 referralShares;
        if (stakers) {
            uint256 stakerYield = Math.mulDiv(staked, rate * elapsed, PRECISION * YEAR);
            uint256 cuts;
            (curatorShares, referralShares, cuts) = _cuts(staked, stakerYield, elapsed);
            minted = stakerYield + cuts;
            _totalStaked += minted;
        }
        uint256 lpMinted;
        if (lpLiq != 0) {
            (, uint256 lpTokens) = IFundVenue(IFund(fund).venue()).liquidityAmounts(lpLiq);
            lpMinted = Math.mulDiv(lpTokens, rate * elapsed, PRECISION * YEAR);
            _lpYieldPerLiquidity += Math.mulDiv(lpMinted, Q128, lpLiq);
        }
        if (minted + lpMinted != 0) {
            IFund(fund).moduleMint(address(this), minted + lpMinted);
            s.v.supply += minted + lpMinted;
        }
        if (curatorShares != 0) {
            address cur = IFund(fund).curators();
            _mint(cur, curatorShares);
            IFundCurators(cur).notifyYield();
        }
        if (referralShares != 0) _mint(referralWallet, referralShares);
        emit YieldAccrued(elapsed, premium, rate, minted, lpMinted, curatorShares);
    }

    /// @dev The curators' and the referral cuts of `stakerYield`, as shares priced after the stakers'
    ///      yield lands (so each is worth its cut, rounded down), and the two cuts' fund tokens.
    function _cuts(
        uint256 staked,
        uint256 stakerYield,
        uint256 elapsed
    ) internal view returns (uint256 curatorShares, uint256 referralShares, uint256 cuts) {
        uint256 cut = Math.mulDiv(stakerYield, curatorYieldBps, BPS);
        uint256 cap = curatorYieldCapBps;
        if (cap != 0) cut = Math.min(cut, Math.mulDiv(staked, cap * elapsed, BPS * YEAR));
        uint256 referralCut = Math.mulDiv(stakerYield, referralYieldBps, BPS);
        uint256 supply = totalSupply() + 1;
        uint256 assets = staked + stakerYield + 1;
        curatorShares = Math.mulDiv(cut, supply, assets);
        referralShares = Math.mulDiv(referralCut, supply, assets);
        cuts = cut + referralCut;
    }

    /// @dev Moves the pot's drip since the last checkpoint into `potPending`: the rest drips
    ///      linearly until `potEnd`. An empty pot's clock stands still; {addPot} restarts it.
    function _checkpointPot() internal {
        uint256 left = potLeft;
        if (left == 0) return;
        uint256 last = _potUpdatedAt;
        _potUpdatedAt = uint64(block.timestamp);
        uint256 end = potEnd;
        if (block.timestamp <= last) return;
        uint256 released = block.timestamp >= end ? left : Math.mulDiv(left, block.timestamp - last, end - last);
        potLeft = SafeCast.toUint128(left - released);
        potPending += released;
    }

    /// @dev Pays the dripped pot tokens, already minted here, into the vault. With less than a
    ///      whole share staked they are burned into backing instead.
    function _releasePot(
        bool stakers
    ) internal {
        _checkpointPot();
        uint256 pending = potPending;
        if (pending == 0) return;
        potPending = 0;
        bool toStakers = stakers && totalSupply() >= MIN_POT_SHARES;
        if (toStakers) _totalStaked += pending;
        else IFund(fund).burn(pending);
        emit PotReleased(pending, toStakers);
    }

    /// @dev Pays `account`'s boost owed since its last settlement as staked shares, from the boost
    ///      tokens already minted here. Callers accrue first, so the shares are priced after the
    ///      tier yield.
    function _settleBoost(
        address account
    ) internal {
        Boost storage b = _boosts[account];
        uint256 left = b.left;
        if (left == 0) return;
        uint256 owed = Math.min(uint256(b.perSec) * (block.timestamp - b.lastSettle), left);
        if (owed == 0) return;
        uint256 shares = convertToShares(owed);
        if (owed == left) delete _boosts[account];
        else (b.left, b.lastSettle) = (uint128(left - owed), uint64(block.timestamp));
        _totalStaked += owed;
        _mint(account, shares);
        emit BoostPaid(account, owed, shares);
    }

    /// @dev Accrues, then pays `account`'s boost at the NAV after the accrual.
    function _accrueAndSettle(
        address account
    ) internal {
        _accrue();
        _settleBoost(account);
    }

    function _settleBefore(
        address account
    ) internal {
        if (_boosts[account].left != 0) _accrueAndSettle(account);
    }

    /// @dev The snapshot, valuing the fund on first use.
    function _valued(
        Snapshot memory s
    ) internal view returns (Valuation memory) {
        if (!s.read) (s.read, s.v) = (true, IFund(fund).valuation());
        return s.v;
    }

    /// @dev Scales `account`'s boost down to the shares it still holds (in hand or in the governor),
    ///      burning the unpaid boost tokens of the shares that left into backing.
    function _forfeit(address account, address gov) internal {
        Boost storage b = _boosts[account];
        uint256 left = b.left;
        uint256 boosted = b.shares;
        if (left == 0) return;
        uint256 held = _held(account, gov);
        if (held >= boosted) return;
        uint256 keptLeft = Math.mulDiv(left, held, boosted);
        if (keptLeft == 0) {
            delete _boosts[account];
        } else {
            b.left = uint128(keptLeft);
            b.perSec = uint128(Math.mulDiv(b.perSec, held, boosted));
            b.shares = uint128(held);
        }
        IFund(fund).burn(left - keptLeft);
        emit BoostForfeited(account, left - keptLeft, keptLeft);
    }

    function _held(address account, address gov) internal view returns (uint256 held) {
        held = balanceOf(account) + IFundGovernor(gov).escrowOf(account, address(this));
        address prev = IFund(fund).previousGovernor();
        if (prev != address(0) && prev != gov) held += IFundGovernor(prev).escrowOf(account, address(this));
    }

    function _lockOf(address account, bool atNav) internal view returns (MintLock storage) {
        return atNav ? _navLocks[account] : _mintLocks[account];
    }

    /// @dev One lock of each kind per account, ending at the share-weighted end: shares times time
    ///      locked are kept, so a mint to someone else cannot hold their earlier shares longer than
    ///      it pays for. Direct and NAV mints never share a lock, so neither can shorten the other.
    ///      A NAV lock always ends at the largest uint64, which the weighting returns exactly.
    function _joinMintLock(address account, uint256 shares, uint64 unlockAt, bool atNav) internal {
        MintLock storage lock = _lockOf(account, atNav);
        uint256 held = lock.unlockAt > block.timestamp ? lock.shares : 0;
        uint256 total = held + shares;
        uint256 left = Math.mulDiv(
            held * (held == 0 ? 0 : lock.unlockAt - block.timestamp) + shares * (unlockAt - block.timestamp),
            1,
            total,
            Math.Rounding.Ceil
        );
        (lock.shares, lock.unlockAt) = (SafeCast.toUint128(total), uint64(block.timestamp + left));
        emit MintLockSet(account, total, lock.unlockAt, atNav);
    }

    /// @dev Shares under `account`'s running direct and NAV mint locks.
    function _activeMintLock(
        address account
    ) internal view returns (uint256 locked) {
        MintLock memory lock = _mintLocks[account];
        if (block.timestamp < lock.unlockAt) locked = lock.shares;
        lock = _navLocks[account];
        if (block.timestamp < lock.unlockAt) locked += lock.shares;
    }

    /// @dev Caps `account`'s running mint lock of the kind to `held` after a burn; returns what is
    ///      left of `held` past it.
    function _capMintLock(address account, bool atNav, uint256 held) internal returns (uint256) {
        MintLock storage lock = _lockOf(account, atNav);
        if (block.timestamp >= lock.unlockAt) return held;
        uint256 locked = lock.shares;
        if (locked <= held) return held - locked;
        lock.shares = uint128(held);
        emit MintLockSet(account, held, lock.unlockAt, atNav);
        return 0;
    }

    /// @dev Takes custody of a full-range position in the fund's pool. Its liquidity cannot change
    ///      while staked: only the owner (this contract) can modify it.
    function _stakePosition(uint256 tokenId, address owner) internal {
        uint128 liquidity = LpPositions.fundLiquidity(positionManager, IFund(fund).venue(), tokenId);
        _accrue();
        lpLiquidity += liquidity;
        _positions[tokenId] =
            LpPosition({owner: owner, epoch: lpEpoch, liquidity: liquidity, paid: _lpYieldPerLiquidity});
        emit PositionStaked(owner, tokenId, liquidity);
    }

    function _ownedPosition(
        uint256 tokenId
    ) internal view returns (LpPosition storage p) {
        p = _positions[tokenId];
        if (p.owner != msg.sender) revert NotPositionOwner();
    }

    /// @dev Yield per unit of liquidity for positions staked in pool `epoch`: still growing for the
    ///      current pool, frozen at the move for an earlier one.
    function _lpAccOf(
        uint32 epoch
    ) internal view returns (uint256) {
        return epoch == lpEpoch ? _lpYieldPerLiquidity : _lpAccAtEnd[epoch];
    }

    function _payPosition(uint256 tokenId, LpPosition storage p, address to) internal returns (uint256 paid) {
        uint256 acc = _lpAccOf(p.epoch);
        // Rounds down: positions are never paid more than was minted for them.
        paid = Math.mulDiv(p.liquidity, acc - p.paid, Q128);
        p.paid = acc;
        if (paid != 0) IERC20(fund).safeTransfer(to, paid);
        emit PositionYieldClaimed(tokenId, to, paid);
    }

    /// @dev Locked shares (launch or direct mint) can leave an account only by being burned
    ///      (unstake moves a launch lock back onto the fund tokens; a mint lock can only be redeemed)
    ///      or by going into the governor, which returns them to the same account; shares held in
    ///      the governor still count towards the account's holdings. Shares leaving any other way
    ///      scale the account's boost down.
    function _update(address from, address to, uint256 value) internal override {
        // Anyone can move zero tokens from any account, so a zero transfer must not touch its lock or boost.
        if (value == 0) return super._update(from, to, value);
        uint256 launchLocked = from == address(0) ? 0 : _activeLock(from);
        uint256 mintLocked = from == address(0) ? 0 : _activeMintLock(from);
        bool boosted = from != address(0) && _boosts[from].left != 0;
        address gov = launchLocked + mintLocked == 0 && !boosted ? address(0) : IFund(fund).governor();
        if (
            launchLocked + mintLocked != 0 && to != address(0) && to != gov
                && _held(from, gov) < value + launchLocked + mintLocked
        ) {
            revert SharesLocked();
        }
        super._update(from, to, value);
        if (to == address(0) && launchLocked + mintLocked != 0) {
            uint256 held = _capMintLock(from, true, _capMintLock(from, false, _held(from, gov)));
            if (launchLocked > held) {
                lockedShares[from] = held;
                emit LockedSharesSet(from, held);
            }
        }
        if (boosted && to != gov) _forfeit(from, gov);
        if (from == address(0) || to == address(0)) _recordSupply();
    }

    /// @dev An epoch's supply is fixed when it opens: shares minted or burned during it count from the
    ///      next epoch, so no stake or unstake moves the total an epoch's votes are measured against.
    function _recordSupply() internal {
        uint256 e = block.timestamp / EPOCH;
        _supply.set(e, _supply.valueAt(e), totalSupply());
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
        YieldPoint[] memory curve_
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

    function _setPremiumConfig(uint16 shareBps, uint32 speedBpsPerYear, uint32 dripPeriod) internal {
        if (
            shareBps > BPS || speedBpsPerYear == 0 || speedBpsPerYear > 1_000_000 || dripPeriod < 1 hours
                || dripPeriod > 365 days
        ) {
            revert InvalidPremiumConfig();
        }
        boostShareBps = shareBps;
        boostSpeedBpsPerYear = speedBpsPerYear;
        potDripPeriod = dripPeriod;
        emit PremiumConfigSet(shareBps, speedBpsPerYear, dripPeriod);
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

    function _checkAdmin() internal view {
        if (!_factory.isAdmin(msg.sender)) revert NotAdmin();
    }
}
