// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundCurators — curator set, minimum stake and curator fee split for one fund
/// @notice See {IFundCurators}.
/// @dev Beacon proxy per fund; storage is append-only across upgrades. Fees arrive by plain
///      transfer, so they are picked up from the balance: whatever exceeds what is already owed is
///      new and is shared equally by the curators compliant at that moment. Every change to the
///      compliant set first distributes what has arrived, so fees always go to the curators that
///      were compliant when they came in.
contract FundCurators is IFundCurators, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Hard cap on the minimum stake.
    uint16 public constant MAX_MIN_STAKE_BPS = 1000;

    struct CuratorState {
        bool active;
        bool compliant;
        uint32 belowSince;
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

    modifier onlyAdmin() {
        if (msg.sender != _factory().owner()) revert NotAdmin();
        _;
    }

    modifier onlyAdminOrGovernor() {
        if (msg.sender != _factory().owner() && msg.sender != IFund(fund).governor()) revert NotAdminOrGovernor();
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
        _setMinStake(minStakeBps_);
        uint256 cap = IFundFactory(msg.sender).curatorCap();
        for (uint256 i; i < curators_.length; ++i) {
            _add(curators_[i], cap);
        }
    }

    /// @inheritdoc IFundCurators
    function addCurator(
        address curator
    ) external override onlyAdminOrGovernor {
        _distributeAll();
        _add(curator, _factory().curatorCap());
    }

    /// @inheritdoc IFundCurators
    function removeCurator(
        address curator
    ) external override onlyAdminOrGovernor {
        _distributeAll();
        _remove(curator);
    }

    /// @inheritdoc IFundCurators
    function replaceCurator(address curator, address replacement) external override onlyAdminOrGovernor {
        _distributeAll();
        _remove(curator);
        _add(replacement, type(uint256).max);
    }

    /// @inheritdoc IFundCurators
    function setMinStake(
        uint16 minStakeBps_
    ) external override onlyAdmin {
        _setMinStake(minStakeBps_);
    }

    /// @inheritdoc IFundCurators
    function checkCompliance(
        uint256 epoch
    ) external override {
        IFund f = IFund(fund);
        if (msg.sender != f.governor()) revert NotGovernor();
        _distributeAll();
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
            if (ok != st.compliant) _setCompliant(c, ok);
        }
    }

    /// @inheritdoc IFundCurators
    function claim(
        address token
    ) external override nonReentrant returns (uint256 amount) {
        _checkFeeToken(token);
        _distribute(token);
        _settle(msg.sender, token);
        amount = _owed[msg.sender][token];
        if (amount == 0) return 0;
        _owed[msg.sender][token] = 0;
        _reserved[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FeesClaimed(msg.sender, token, amount);
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
        return _state[account].active;
    }

    /// @inheritdoc IFundCurators
    function isCompliant(
        address curator
    ) external view override returns (bool) {
        return _state[curator].compliant;
    }

    /// @inheritdoc IFundCurators
    function claimable(address curator, address token) external view override returns (uint256 amount) {
        _checkFeeToken(token);
        uint256 acc = _accPerCurator[token];
        if (_compliantCount != 0) {
            uint256 fresh = IERC20(token).balanceOf(address(this)) - _reserved[token];
            acc += Math.mulDiv(fresh, PRECISION, _compliantCount);
        }
        amount = _owed[curator][token];
        if (_state[curator].compliant) amount += (acc - _debt[curator][token]) / PRECISION;
    }

    function _add(address curator, uint256 cap) internal {
        if (curator == address(0)) revert ZeroAddress();
        if (_state[curator].active) revert AlreadyCurator();
        if (_curators.length >= cap) revert CuratorCapReached();
        _curators.push(curator);
        _state[curator].active = true;
        _state[curator].belowSince = 0;
        _setCompliant(curator, true);
        emit CuratorAdded(curator);
    }

    function _remove(
        address curator
    ) internal {
        if (!_state[curator].active) revert NotCurator();
        if (_state[curator].compliant) _setCompliant(curator, false);
        delete _state[curator];
        uint256 n = _curators.length;
        for (uint256 i; i < n; ++i) {
            if (_curators[i] == curator) {
                _curators[i] = _curators[n - 1];
                _curators.pop();
                break;
            }
        }
        emit CuratorRemoved(curator);
    }

    /// @dev Callers distribute arrived fees first.
    function _setCompliant(address curator, bool compliant) internal {
        address[2] memory tokens = _feeTokens();
        for (uint256 i; i < 2; ++i) {
            _settle(curator, tokens[i]);
            _debt[curator][tokens[i]] = _accPerCurator[tokens[i]];
        }
        _state[curator].compliant = compliant;
        if (compliant) ++_compliantCount;
        else --_compliantCount;
        emit ComplianceSet(curator, compliant);
    }

    function _settle(address curator, address token) internal {
        uint256 acc = _accPerCurator[token];
        if (_state[curator].compliant) {
            _owed[curator][token] += (acc - _debt[curator][token]) / PRECISION;
        }
        _debt[curator][token] = acc;
    }

    function _distributeAll() internal {
        address[2] memory tokens = _feeTokens();
        _distribute(tokens[0]);
        _distribute(tokens[1]);
    }

    function _distribute(
        address token
    ) internal {
        uint256 count = _compliantCount;
        if (count == 0) return;
        uint256 fresh = IERC20(token).balanceOf(address(this)) - _reserved[token];
        if (fresh == 0) return;
        // Rounds down; the remainder stays reserved and is never paid out.
        _accPerCurator[token] += Math.mulDiv(fresh, PRECISION, count);
        _reserved[token] += fresh;
    }

    function _setMinStake(
        uint16 minStakeBps_
    ) internal {
        if (minStakeBps_ > MAX_MIN_STAKE_BPS) revert InvalidMinStake();
        minStakeBps = minStakeBps_;
        emit MinStakeSet(minStakeBps_);
    }

    function _checkFeeToken(
        address token
    ) internal view {
        address[2] memory tokens = _feeTokens();
        if (token != tokens[0] && token != tokens[1]) revert NotFeeToken();
    }

    function _feeTokens() internal view returns (address[2] memory) {
        return [fund, _factory().usdg()];
    }

    function _factory() internal view returns (IFundFactory) {
        return IFundFactory(IFund(fund).factory());
    }
}
