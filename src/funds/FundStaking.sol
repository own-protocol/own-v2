// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {YieldTier} from "../interfaces/types/FundTypes.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundStaking — staked fund token vault with premium-tiered issuance
/// @notice See {IFundStaking}.
/// @dev Beacon proxy per fund. Share maths uses one virtual share and one virtual asset, which
///      makes first-depositor donation attacks unprofitable.
contract FundStaking is IFundStaking, ERC20, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Longest period a single accrual covers; keepers accrue far more often than this.
    uint256 public constant MAX_ACCRUAL_PERIOD = 1 days;

    /// @notice Maximum number of yield tiers.
    uint256 public constant MAX_TIERS = 8;

    /// @inheritdoc IFundStaking
    address public override fund;

    /// @inheritdoc IFundStaking
    uint64 public override lastAccrual;

    YieldTier[] private _tiers;

    // Tracked rather than read from the balance, so donated fund tokens earn no yield.
    uint256 private _totalStaked;

    constructor() ERC20("", "") {
        _disableInitializers();
    }

    /// @inheritdoc IFundStaking
    function initialize(
        address fund_,
        YieldTier[] calldata tiers_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
        lastAccrual = uint64(block.timestamp);
        _setTiers(tiers_);
    }

    /// @inheritdoc IFundStaking
    function stake(
        uint256 assets,
        address receiver
    ) external override nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _accrue();
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();
        _totalStaked += assets;
        IERC20(fund).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Staked(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IFundStaking
    function unstake(
        uint256 shares,
        address receiver
    ) external override nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _accrue();
        assets = convertToAssets(shares);
        _totalStaked -= assets;
        _burn(msg.sender, shares);
        IERC20(fund).safeTransfer(receiver, assets);
        emit Unstaked(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IFundStaking
    function accrue() external override nonReentrant returns (uint256 minted) {
        return _accrue();
    }

    /// @inheritdoc IFundStaking
    function setYieldTiers(
        YieldTier[] calldata tiers_
    ) external override nonReentrant {
        if (msg.sender != IFundFactory(IFund(fund).factory()).owner()) revert NotAdmin();
        _accrue();
        _setTiers(tiers_);
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
    function yieldTiers() external view override returns (YieldTier[] memory) {
        return _tiers;
    }

    /// @inheritdoc IFundStaking
    function rateForPremium(
        int256 premiumBps
    ) public view override returns (uint256 rate) {
        uint256 n = _tiers.length;
        for (uint256 i; i < n; ++i) {
            if (premiumBps < int256(uint256(_tiers[i].minPremiumBps))) break;
            rate = _tiers[i].rateBpsPerDay;
        }
        if (rate != 0) {
            uint256 cap = _maxRate();
            if (rate > cap) rate = cap;
        }
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

    /// @dev Mints the yield owed since the last accrual, at the rate of the premium read now.
    ///      No yield without a fresh premium reading; the period is still consumed, so a stale
    ///      oracle can only withhold yield, never inflate it later.
    function _accrue() internal returns (uint256 minted) {
        uint256 last = lastAccrual;
        if (block.timestamp <= last) return 0;
        uint256 elapsed = block.timestamp - last;
        if (elapsed > MAX_ACCRUAL_PERIOD) elapsed = MAX_ACCRUAL_PERIOD;
        lastAccrual = uint64(block.timestamp);

        uint256 staked = totalAssets();
        if (staked == 0 || totalSupply() == 0) return 0;

        (bool ok, int256 premium) = IFund(fund).premiumBps();
        if (!ok) return 0;
        uint256 rate = rateForPremium(premium);
        if (rate == 0) return 0;

        minted = Math.mulDiv(staked, rate * elapsed, BPS * 1 days);
        if (minted != 0) {
            _totalStaked += minted;
            IFund(fund).moduleMint(address(this), minted);
        }
        emit YieldAccrued(elapsed, premium, rate, minted);
    }

    function _setTiers(
        YieldTier[] calldata tiers_
    ) internal {
        if (tiers_.length > MAX_TIERS) revert InvalidTiers();
        uint256 cap = _maxRate();
        delete _tiers;
        for (uint256 i; i < tiers_.length; ++i) {
            if (tiers_[i].rateBpsPerDay > cap) revert InvalidTiers();
            if (i != 0 && tiers_[i].minPremiumBps <= tiers_[i - 1].minPremiumBps) revert InvalidTiers();
            _tiers.push(tiers_[i]);
        }
        emit YieldTiersSet(tiers_);
    }

    function _maxRate() internal view returns (uint256) {
        return IFundFactory(IFund(fund).factory()).maxYieldRateBpsPerDay();
    }
}
