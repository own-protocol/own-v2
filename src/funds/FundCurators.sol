// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FundCurators — curator set, minimum stake and curator income for one fund
/// @notice See {IFundCurators}.
/// @dev Beacon proxy per fund; storage is append-only across upgrades. Income arrives by plain
///      transfer, so it is picked up from the balance: whatever exceeds what is already owed is new.
///      The protocol curator's share of it is set aside at once; the rest is shared equally by the
///      curators compliant at that moment (all of it goes to the protocol curator while none is).
///      Every change to the compliant set first distributes what has arrived, so income always goes
///      to the curators that were compliant when it came in.
contract FundCurators is IFundCurators, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Hard cap on the minimum stake.
    uint16 public constant MAX_MIN_STAKE_BPS = 1000;

    /// @notice Most bribe reward tokens the module tracks besides the fund token, USDG and staked
    ///         fund tokens.
    uint256 public constant MAX_REWARD_TOKENS = 32;

    /// @notice Length of a vesting period: staked fund tokens a curator earns unlock when it ends.
    uint256 public constant VEST_PERIOD = 30 days;

    struct CuratorState {
        bool active;
        bool compliant;
        uint32 belowSince;
    }

    struct Vest {
        uint192 amount;
        uint64 period;
    }

    /// @inheritdoc IFundCurators
    address public override fund;

    /// @inheritdoc IFundCurators
    uint16 public override minStakeBps;

    address[] private _curators;
    mapping(address curator => CuratorState) private _state;
    uint256 private _compliantCount;

    mapping(address token => uint256) private _accPerCurator;
    mapping(address token => uint256) private _reserved;
    mapping(address curator => mapping(address token => uint256)) private _debt;
    mapping(address curator => mapping(address token => uint256)) private _owed;

    IFundFactory private _factory;

    address[] private _rewardTokens;
    mapping(address token => bool) private _isRewardToken;
    mapping(address token => uint256) private _protocolOwed;
    mapping(address curator => Vest) private _vest;
    uint256 private _accPeriod;
    uint256 private _accAtPeriodStart;

    modifier onlyAdmin() {
        if (!_factory.isAdmin(msg.sender)) revert NotAdmin();
        _;
    }

    modifier onlyAdminOrGovernor() {
        if (msg.sender != IFund(fund).governor() && !_factory.isAdmin(msg.sender)) revert NotAdminOrGovernor();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundCurators
    function initialize(
        address fund_,
        address[] calldata curators_,
        uint16 minStakeBps_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
        _factory = IFundFactory(IFund(fund_).factory());
        _setMinStake(minStakeBps_);
        uint256 cap = _factory.curatorCap();
        for (uint256 i; i < curators_.length; ++i) {
            _add(curators_[i], cap, new address[](0));
        }
    }

    /// @inheritdoc IFundCurators
    function addCurator(
        address curator
    ) external override onlyAdminOrGovernor nonReentrant {
        address[] memory tokens = _distributeAll();
        _add(curator, _factory.curatorCap(), tokens);
    }

    /// @inheritdoc IFundCurators
    function removeCurator(
        address curator
    ) external override onlyAdminOrGovernor nonReentrant {
        _remove(curator, _distributeAll());
    }

    /// @inheritdoc IFundCurators
    function replaceCurator(address curator, address replacement) external override onlyAdminOrGovernor nonReentrant {
        address[] memory tokens = _distributeAll();
        _remove(curator, tokens);
        _add(replacement, type(uint256).max, tokens);
    }

    /// @inheritdoc IFundCurators
    function setMinStake(
        uint16 minStakeBps_
    ) external override onlyAdmin {
        _setMinStake(minStakeBps_);
    }

    /// @inheritdoc IFundCurators
    function notifyYield() external override {
        address staking = _staking();
        if (msg.sender != staking) revert NotStaking();
        // Not guarded: staking calls back here while {_forfeit} unstakes, which keeps `_reserved` exact.
        _distribute(staking, staking);
    }

    /// @inheritdoc IFundCurators
    function registerRewardToken(
        address token
    ) external override {
        if (msg.sender != _factory.modulesOf(fund).bribes) revert NotBribes();
        if (_isRewardToken[token] || _isCoreToken(token, _staking())) return;
        if (_rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        _isRewardToken[token] = true;
        _rewardTokens.push(token);
        emit RewardTokenRegistered(token);
    }

    /// @inheritdoc IFundCurators
    function checkCompliance(
        uint256 epoch
    ) external override nonReentrant {
        IFund f = IFund(fund);
        if (msg.sender != f.governor()) revert NotGovernor();
        address[] memory tokens = _distributeAll();
        uint256 required = Math.mulDiv(f.totalSupply(), minStakeBps, BPS, Math.Rounding.Ceil);
        IFundGovernor gov = IFundGovernor(msg.sender);
        uint256 n = _curators.length;
        for (uint256 i; i < n; ++i) {
            address c = _curators[i];
            CuratorState storage st = _state[c];
            bool ok = gov.stakedAssetsAt(c, epoch) >= required;
            if (ok) {
                st.belowSince = 0;
            } else if (st.belowSince == 0) {
                // First failed check: a week of grace.
                st.belowSince = uint32(epoch);
                continue;
            }
            if (ok != st.compliant) _setCompliant(c, ok, tokens);
        }
    }

    /// @inheritdoc IFundCurators
    function claim(
        address token
    ) external override nonReentrant returns (uint256 amount) {
        address staking = _staking();
        _checkToken(token, staking);
        _distribute(token, staking);
        _settle(msg.sender, token, staking);
        if (token == staking) _rollVest(msg.sender, staking);
        amount = _owed[msg.sender][token];
        _owed[msg.sender][token] = 0;
        if (msg.sender == _factory.protocolCurator()) {
            amount += _protocolOwed[token];
            _protocolOwed[token] = 0;
        }
        if (amount == 0) return 0;
        _reserved[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FeesClaimed(msg.sender, token, amount);
    }

    /// @inheritdoc IFundCurators
    function protocolCurator() public view override returns (address) {
        return _factory.protocolCurator();
    }

    /// @inheritdoc IFundCurators
    function voteShares()
        external
        view
        override
        returns (address[] memory accounts, uint256[] memory baseBps, uint256[] memory silentBps)
    {
        uint256 n = _curators.length;
        accounts = new address[](n + 1);
        baseBps = new uint256[](n + 1);
        silentBps = new uint256[](n + 1);
        uint256 protocolShare = _factory.protocolCuratorShareBps();
        accounts[0] = _factory.protocolCurator();
        baseBps[0] = protocolShare;
        silentBps[0] = protocolShare;
        uint256 m = _compliantCount;
        for (uint256 i; i < n; ++i) {
            address c = _curators[i];
            accounts[i + 1] = c;
            if (!_state[c].compliant) continue;
            baseBps[i + 1] = (BPS - protocolShare) / n;
            silentBps[i + 1] = (BPS - protocolShare) / m;
        }
    }

    /// @inheritdoc IFundCurators
    function curators() external view override returns (address[] memory) {
        return _curators;
    }

    /// @inheritdoc IFundCurators
    function curatorCount() external view override returns (uint256) {
        return _curators.length;
    }

    /// @inheritdoc IFundCurators
    function isCurator(
        address account
    ) external view override returns (bool) {
        return _state[account].active || account == _factory.protocolCurator();
    }

    /// @inheritdoc IFundCurators
    function isCompliant(
        address curator
    ) external view override returns (bool) {
        return _state[curator].compliant || curator == _factory.protocolCurator();
    }

    /// @inheritdoc IFundCurators
    function rewardTokens() external view override returns (address[] memory) {
        return _allTokens();
    }

    /// @inheritdoc IFundCurators
    function claimable(address curator, address token) external view override returns (uint256 amount) {
        address staking = _staking();
        _checkToken(token, staking);
        uint256 fresh = _fresh(token);
        uint256 count = _compliantCount;
        uint256 toProtocol = count == 0 ? fresh : Math.mulDiv(fresh, _factory.protocolCuratorShareBps(), BPS);
        uint256 acc = _accPerCurator[token];
        if (fresh > toProtocol) acc += Math.mulDiv(fresh - toProtocol, PRECISION, count);

        amount = _owed[curator][token];
        if (curator == _factory.protocolCurator()) amount += _protocolOwed[token] + toProtocol;
        if (!_state[curator].compliant) return amount;
        uint256 debt = _debt[curator][token];
        if (token == staking) {
            Vest memory v = _vest[curator];
            if (v.period < _period()) amount += v.amount;
            uint256 boundary = _periodStartAcc(_accPerCurator[token]);
            if (boundary > debt) amount += (boundary - debt) / PRECISION;
        } else {
            amount += (acc - debt) / PRECISION;
        }
    }

    /// @inheritdoc IFundCurators
    function lockedYieldOf(
        address curator
    ) external view override returns (uint256 shares, uint256 unlockAt) {
        address staking = _staking();
        Vest memory v = _vest[curator];
        uint256 q = _period();
        if (v.period == q) shares = v.amount;
        if (_state[curator].compliant) {
            uint256 fresh = _fresh(staking);
            uint256 toProtocol = Math.mulDiv(fresh, _factory.protocolCuratorShareBps(), BPS);
            uint256 acc = _accPerCurator[staking];
            uint256 start = Math.max(_debt[curator][staking], _periodStartAcc(acc));
            acc += Math.mulDiv(fresh - toProtocol, PRECISION, _compliantCount);
            shares += (acc - start) / PRECISION;
        }
        unlockAt = (q + 1) * VEST_PERIOD;
    }

    function _add(address curator, uint256 cap, address[] memory tokens) internal {
        if (curator == address(0)) revert ZeroAddress();
        if (_state[curator].active || curator == _factory.protocolCurator()) revert AlreadyCurator();
        if (_curators.length >= cap) revert CuratorCapReached();
        _curators.push(curator);
        _state[curator].active = true;
        _setCompliant(curator, true, tokens);
        emit CuratorAdded(curator);
    }

    function _remove(address curator, address[] memory tokens) internal {
        if (!_state[curator].active) revert NotCurator();
        if (_state[curator].compliant) _setCompliant(curator, false, tokens);
        delete _state[curator];
        uint256 n = _curators.length;
        for (uint256 i; i < n; ++i) {
            if (_curators[i] == curator) {
                _curators[i] = _curators[n - 1];
                _curators.pop();
                break;
            }
        }
        _forfeit(curator, tokens[2]);
        emit CuratorRemoved(curator);
    }

    /// @dev Burns the staked fund tokens the curator earned this period, which raises NAV for every
    ///      holder; earlier periods have unlocked and stay claimable.
    function _forfeit(address curator, address staking) internal {
        _rollVest(curator, staking);
        uint256 shares = _vest[curator].amount;
        if (shares == 0) return;
        delete _vest[curator];
        // Unstaking accrues first, which can mint new shares here and call {notifyYield}; the shares
        // leave `_reserved` only once they are gone, so that new income is the only fresh balance.
        uint256 assets = IFundStaking(staking).unstake(shares, address(this));
        _reserved[staking] -= shares;
        if (assets != 0) IFund(fund).burn(assets);
        emit YieldForfeited(curator, shares, assets);
    }

    /// @dev Callers distribute arrived income first. `tokens` is {_allTokens} (staked fund tokens
    ///      third), or empty while initialising.
    function _setCompliant(address curator, bool compliant, address[] memory tokens) internal {
        for (uint256 i; i < tokens.length; ++i) {
            _settle(curator, tokens[i], tokens[2]);
            _debt[curator][tokens[i]] = _accPerCurator[tokens[i]];
        }
        _state[curator].compliant = compliant;
        if (compliant) ++_compliantCount;
        else --_compliantCount;
        emit ComplianceSet(curator, compliant);
    }

    /// @dev Staked fund tokens shared out before the current period began are unlocked; the rest
    ///      vest until it ends.
    function _settle(address curator, address token, address staking) internal {
        uint256 acc = _accPerCurator[token];
        uint256 debt = _debt[curator][token];
        _debt[curator][token] = acc;
        if (!_state[curator].compliant || acc == debt) return;
        if (token != staking) {
            _owed[curator][token] += (acc - debt) / PRECISION;
            return;
        }
        _rollVest(curator, staking);
        uint256 boundary = _periodStartAcc(acc);
        if (boundary > debt) _owed[curator][token] += (boundary - debt) / PRECISION;
        uint256 current = (acc - Math.max(debt, boundary)) / PRECISION;
        if (current == 0) return;
        Vest storage v = _vest[curator];
        v.amount += SafeCast.toUint192(current);
        v.period = SafeCast.toUint64(_period());
    }

    /// @dev The staking accumulator when the current period's first income was shared out, or
    ///      `acc` (its value now) if none has been yet.
    function _periodStartAcc(
        uint256 acc
    ) internal view returns (uint256) {
        return _accPeriod == _period() ? _accAtPeriodStart : acc;
    }

    /// @dev Moves staked fund tokens earned in a past period to what the curator can claim.
    function _rollVest(address curator, address staking) internal {
        Vest memory v = _vest[curator];
        if (v.amount == 0 || v.period >= _period()) return;
        delete _vest[curator];
        _owed[curator][staking] += v.amount;
    }

    /// @dev Returns every tracked token.
    function _distributeAll() internal returns (address[] memory tokens) {
        tokens = _allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            _distribute(tokens[i], tokens[2]);
        }
    }

    function _distribute(address token, address staking) internal {
        uint256 fresh = _fresh(token);
        if (fresh == 0) return;
        _reserved[token] += fresh;
        if (token == staking && _accPeriod != _period()) {
            _accPeriod = _period();
            _accAtPeriodStart = _accPerCurator[token];
        }
        uint256 count = _compliantCount;
        // Rounds down for the curators; the protocol curator takes the rest of its share's rounding.
        uint256 toProtocol = count == 0 ? fresh : Math.mulDiv(fresh, _factory.protocolCuratorShareBps(), BPS);
        _protocolOwed[token] += toProtocol;
        // Rounds down; the remainder stays reserved and is never paid out.
        if (fresh > toProtocol) _accPerCurator[token] += Math.mulDiv(fresh - toProtocol, PRECISION, count);
    }

    /// @dev Income not yet shared out; none while the balance is below what is owed (a token that
    ///      rebased down or charged a transfer fee).
    function _fresh(
        address token
    ) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 reserved = _reserved[token];
        return bal > reserved ? bal - reserved : 0;
    }

    function _setMinStake(
        uint16 minStakeBps_
    ) internal {
        if (minStakeBps_ > MAX_MIN_STAKE_BPS) revert InvalidMinStake();
        minStakeBps = minStakeBps_;
        emit MinStakeSet(minStakeBps_);
    }

    function _checkToken(address token, address staking) internal view {
        if (!_isRewardToken[token] && !_isCoreToken(token, staking)) revert NotFeeToken();
    }

    function _isCoreToken(address token, address staking) internal view returns (bool) {
        return token == fund || token == staking || token == _factory.usdg();
    }

    /// @dev The fund token, USDG, staked fund tokens, then the bribe reward tokens.
    function _allTokens() internal view returns (address[] memory tokens) {
        uint256 n = _rewardTokens.length;
        tokens = new address[](n + 3);
        tokens[0] = fund;
        tokens[1] = _factory.usdg();
        tokens[2] = _staking();
        for (uint256 i; i < n; ++i) {
            tokens[i + 3] = _rewardTokens[i];
        }
    }

    function _staking() internal view returns (address) {
        return IFund(fund).staking();
    }

    function _period() internal view returns (uint256) {
        return block.timestamp / VEST_PERIOD;
    }
}
