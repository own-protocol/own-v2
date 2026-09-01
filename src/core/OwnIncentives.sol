// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnIncentives} from "../interfaces/IOwnIncentives.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {PRECISION} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnIncentives — on-chain OWN incentives for sEUSD holders
/// @notice Aave-style single-reward controller. See {IOwnIncentives}. sEUSD calls {handleAction} on
///         every balance change; holders accrue OWN pro-rata to their sEUSD balance and claim here.
/// @dev One global `index` over sEUSD total supply (`index += emissionPerSecond · Δt / totalSupply`,
///      capped at `distributionEnd`), plus per-holder index snapshots. Funded from an OWN budget;
///      no mint rights, so claims are capped at the budget and never insolvent.
contract OwnIncentives is IOwnIncentives, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant ADMIN = keccak256("ADMIN");

    IProtocolRegistry public immutable registry;
    IERC20 private immutable _sEusd;
    IERC20 private immutable _own;

    /// @inheritdoc IOwnIncentives
    uint256 public override emissionPerSecond;
    /// @inheritdoc IOwnIncentives
    uint256 public override distributionEnd;
    /// @inheritdoc IOwnIncentives
    uint256 public override rewardReserve;

    uint256 private _index;
    uint256 private _lastUpdate;
    mapping(address => uint256) private _userIndex;
    mapping(address => uint256) private _accrued;

    /// @dev Partner account => destination for swept OWN (address(0) = not a partner).
    mapping(address => address) private _partnerDestination;

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @param registry_ ProtocolRegistry (role authority).
    /// @param sEusd_    sEUSD token — the only permitted caller of {handleAction}.
    /// @param own_      OWN reward token.
    constructor(address registry_, address sEusd_, address own_) {
        if (registry_ == address(0) || sEusd_ == address(0) || own_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
        _sEusd = IERC20(sEusd_);
        _own = IERC20(own_);
        _lastUpdate = block.timestamp;
    }

    // ── Hook ──────────────────────────────────────────────────

    /// @inheritdoc IOwnIncentives
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external override {
        if (msg.sender != address(_sEusd)) revert OnlyStakedToken();
        _updateGlobal(totalSupply);
        _accrue(user, userBalance);
    }

    // ── Claim ─────────────────────────────────────────────────

    /// @inheritdoc IOwnIncentives
    function claim(
        address to
    ) external override nonReentrant returns (uint256 paid) {
        if (to == address(0)) revert ZeroAddress();
        // Read live balance/supply: the holder's balance is unchanged since their last checkpoint,
        // and every supply change was checkpointed by the hook, so this segment is well-defined.
        _updateGlobal(_sEusd.totalSupply());
        _accrue(msg.sender, _sEusd.balanceOf(msg.sender));
        paid = _pay(msg.sender, to);
        emit RewardsClaimed(msg.sender, to, paid);
    }

    /// @inheritdoc IOwnIncentives
    function sweepPartner(
        address account
    ) external override nonReentrant returns (uint256 paid) {
        address dest = _partnerDestination[account];
        if (dest == address(0)) revert NotPartner();
        // Settle the partner's pooled balance to now, then push its share to the fixed destination.
        _updateGlobal(_sEusd.totalSupply());
        _accrue(account, _sEusd.balanceOf(account));
        paid = _pay(account, dest);
        emit PartnerSwept(account, dest, paid);
    }

    // ── Funding & governance ──────────────────────────────────

    /// @inheritdoc IOwnIncentives
    function fund(
        uint256 amount
    ) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = _own.balanceOf(address(this));
        _own.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = _own.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
        rewardReserve += received;
        emit ReserveFunded(msg.sender, received);
    }

    /// @inheritdoc IOwnIncentives
    function setDistribution(uint256 emissionPerSecond_, uint256 distributionEnd_) external override onlyAdmin {
        _updateGlobal(_sEusd.totalSupply()); // settle at the old rate; sets _lastUpdate = now
        emissionPerSecond = emissionPerSecond_;
        distributionEnd = distributionEnd_;
        emit DistributionSet(emissionPerSecond_, distributionEnd_);
    }

    /// @inheritdoc IOwnIncentives
    function recoverReserve(uint256 amount, address to) external override onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (amount > rewardReserve) revert InsufficientReserve(amount, rewardReserve);
        rewardReserve -= amount;
        _own.safeTransfer(to, amount);
        emit ReserveRecovered(to, amount);
    }

    /// @inheritdoc IOwnIncentives
    function setPartner(address account, address destination) external override onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        _partnerDestination[account] = destination;
        emit PartnerSet(account, destination);
    }

    // ── Internal ──────────────────────────────────────────────

    /// @dev Advance the global index over the elapsed, in-campaign period. Always moves `_lastUpdate`
    ///      to now so a paused/ended gap is never accrued retroactively when a new campaign is set.
    function _updateGlobal(
        uint256 totalSupply
    ) private {
        uint256 capNow = Math.min(block.timestamp, distributionEnd);
        uint256 last = _lastUpdate;
        if (capNow > last && emissionPerSecond > 0 && totalSupply > 0) {
            _index += Math.mulDiv(emissionPerSecond * (capNow - last), PRECISION, totalSupply);
        }
        _lastUpdate = block.timestamp;
    }

    /// @dev Pay `account`'s accrued OWN to `to`, capped at the reserve. Assumes accrual is settled.
    function _pay(address account, address to) private returns (uint256 paid) {
        uint256 owed = _accrued[account];
        paid = Math.min(owed, rewardReserve);
        _accrued[account] = owed - paid;
        if (paid > 0) {
            rewardReserve -= paid;
            _own.safeTransfer(to, paid);
        }
        if (paid < owed) emit RewardShortfall(account, owed, paid);
    }

    /// @dev Fold a holder's balance over the latest index delta into their accrued OWN.
    function _accrue(address user, uint256 userBalance) private {
        uint256 delta = _index - _userIndex[user];
        if (userBalance > 0 && delta > 0) {
            uint256 amount = Math.mulDiv(userBalance, delta, PRECISION);
            _accrued[user] += amount;
            emit Accrued(user, amount, _index);
        }
        _userIndex[user] = _index;
    }

    // ── Views ─────────────────────────────────────────────────

    /// @inheritdoc IOwnIncentives
    function sEusd() external view override returns (address) {
        return address(_sEusd);
    }

    /// @inheritdoc IOwnIncentives
    function own() external view override returns (address) {
        return address(_own);
    }

    /// @inheritdoc IOwnIncentives
    function partnerDestination(
        address account
    ) external view override returns (address) {
        return _partnerDestination[account];
    }

    /// @inheritdoc IOwnIncentives
    function earned(
        address user
    ) external view override returns (uint256) {
        uint256 supply = _sEusd.totalSupply();
        uint256 idx = _index;
        uint256 capNow = Math.min(block.timestamp, distributionEnd);
        if (capNow > _lastUpdate && emissionPerSecond > 0 && supply > 0) {
            idx += Math.mulDiv(emissionPerSecond * (capNow - _lastUpdate), PRECISION, supply);
        }
        return _accrued[user] + Math.mulDiv(_sEusd.balanceOf(user), idx - _userIndex[user], PRECISION);
    }
}
