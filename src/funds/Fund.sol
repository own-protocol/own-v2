// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {CreateFundParams, LockOption} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Fund — MONEY Market Fund token and basket
/// @notice See {IFund}.
/// @dev Deployed as a beacon proxy per fund by {FundFactory}; storage is append-only across
///      upgrades. The ERC-20 name and symbol live in this contract's storage because the inherited
///      ones are constructor-set on the implementation.
contract Fund is IFund, ERC20, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum number of basket assets (bounds every loop over the basket).
    uint256 public constant MAX_ASSETS = 20;

    /// @notice Hard cap on the creator fee.
    uint16 public constant MAX_CREATOR_FEE_BPS = 1000;

    /// @notice Hard cap on a lock option's discount.
    uint16 public constant MAX_LOCK_DISCOUNT_BPS = 5000;

    /// @notice Maximum number of lock options.
    uint256 public constant MAX_LOCK_OPTIONS = 8;

    uint256 private constant NO_LOCK = type(uint256).max;

    /// @inheritdoc IFund
    address public override factory;

    /// @inheritdoc IFund
    address public override manager;

    /// @inheritdoc IFund
    address public override launch;

    /// @inheritdoc IFund
    address public override staking;

    /// @inheritdoc IFund
    bool public override launched;

    /// @inheritdoc IFund
    bool public override mintPaused;

    /// @inheritdoc IFund
    uint16 public override creatorFeeBps;

    /// @inheritdoc IFund
    address public override creatorFeeRecipient;

    string private _fundName;
    string private _fundSymbol;

    address[] private _assets;

    /// @inheritdoc IFund
    mapping(address asset => bool) public override isAsset;

    /// @inheritdoc IFund
    mapping(address asset => uint16) public override targetWeightBps;

    LockOption[] private _lockOptions;

    mapping(address account => Lock[]) private _locks;

    /// @notice Start of the current rebalance volume window.
    uint64 public rebalanceWindowStart;

    /// @notice Oracle value sold by rebalances in the current window, 18 decimals USD.
    uint192 public rebalanceWindowVolume;

    modifier onlyAdmin() {
        if (msg.sender != IFundFactory(factory).owner()) revert NotAdmin();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    modifier onlyModule() {
        if (msg.sender != launch && msg.sender != staking) revert NotModule();
        _;
    }

    constructor() ERC20("", "") {
        _disableInitializers();
    }

    /// @inheritdoc IFund
    function initialize(
        CreateFundParams calldata params
    ) external override initializer {
        if (params.manager == address(0)) revert ZeroAddress();
        factory = msg.sender;
        _fundName = params.name;
        _fundSymbol = params.symbol;
        manager = params.manager;
        emit ManagerSet(params.manager);
        _setCreatorFee(params.creatorFeeBps, params.creatorFeeRecipient);
        _setBasket(params.assets, params.weightsBps);
        _setLockOptions(params.lockOptions);
    }

    /// @inheritdoc IFund
    function setModules(
        address launch_,
        address staking_
    ) external override onlyFactory {
        if (launch != address(0)) revert ModulesAlreadySet();
        if (launch_ == address(0) || staking_ == address(0)) revert ZeroAddress();
        launch = launch_;
        staking = staking_;
    }

    /// @inheritdoc IFund
    function markLaunched() external override {
        if (msg.sender != launch) revert NotLaunch();
        if (launched) revert AlreadyLaunched();
        launched = true;
        emit Launched();
    }

    /// @inheritdoc IFund
    function moduleMint(
        address to,
        uint256 amount
    ) external override onlyModule {
        _mint(to, amount);
    }

    /// @inheritdoc IFund
    function mint(
        address asset,
        uint256 amount,
        uint256 lockOption,
        uint256 minSharesOut,
        address receiver
    ) external override nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (mintPaused) revert MintPaused();

        // Prices and NAV are read before the deposit lands, so the deposit cannot move them.
        (uint256 assetPrice, uint256 mintPrice) = _mintPrices(asset, lockOption);
        uint256 received = _pull(asset, amount);
        shares = _chargeMintFees(_sharesForValue(_value(asset, received, assetPrice), mintPrice));
        if (shares == 0 || shares < minSharesOut) revert Slippage();
        uint256 lockId = _issue(receiver, shares, lockOption);

        emit Minted(msg.sender, receiver, asset, received, shares, mintPrice, lockId);
    }

    /// @inheritdoc IFund
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external override nonReentrant returns (uint256[] memory amounts) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 n = _assets.length;
        if (minAmountsOut.length != 0 && minAmountsOut.length != n) revert LengthMismatch();

        (uint256 protocolFee, uint256 creatorFee) = _fees(shares);
        uint256 net = shares - protocolFee - creatorFee;
        amounts = _redeemAmounts(net);

        for (uint256 i; i < n; ++i) {
            if (minAmountsOut.length != 0 && amounts[i] < minAmountsOut[i]) revert Slippage();
        }

        if (protocolFee != 0) _transfer(msg.sender, IFundFactory(factory).protocolFeeRecipient(), protocolFee);
        if (creatorFee != 0) _transfer(msg.sender, creatorFeeRecipient, creatorFee);
        if (protocolFee != 0 || creatorFee != 0) emit FeesCharged(protocolFee, creatorFee);
        _burn(msg.sender, net);

        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) IERC20(_assets[i]).safeTransfer(receiver, amounts[i]);
        }

        emit Redeemed(msg.sender, receiver, shares, amounts);
    }

    /// @inheritdoc IFund
    function burn(
        uint256 amount
    ) external override {
        _burn(msg.sender, amount);
    }

    /// @inheritdoc IFund
    function claimLocks(
        uint256[] calldata lockIds
    ) external override nonReentrant returns (uint256 amount) {
        Lock[] storage locks = _locks[msg.sender];
        for (uint256 i; i < lockIds.length; ++i) {
            uint256 id = lockIds[i];
            if (id >= locks.length) revert LockNotClaimable(id);
            Lock memory lock = locks[id];
            if (lock.amount == 0 || block.timestamp < lock.unlockAt) revert LockNotClaimable(id);
            locks[id].amount = 0;
            amount += lock.amount;
            emit LockClaimed(msg.sender, id, lock.amount);
        }
        if (amount != 0) _transfer(address(this), msg.sender, amount);
    }

    /// @inheritdoc IFund
    function rebalance(
        RebalanceParams calldata params
    ) external override onlyManager nonReentrant {
        IFundFactory fac = IFundFactory(factory);
        if (!fac.isRouter(params.router) || isAsset[params.router] || params.router == address(this)) {
            revert RouterNotAllowed();
        }
        if (!isAsset[params.sellAsset] || !isAsset[params.buyAsset] || params.sellAsset == params.buyAsset) {
            revert InvalidBasket();
        }
        if (params.sellAmount == 0) revert ZeroAmount();

        uint256 n = _assets.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = IERC20(_assets[i]).balanceOf(address(this));
        }
        uint256 sharesBefore = balanceOf(address(this));

        IERC20(params.sellAsset).forceApprove(params.router, params.sellAmount);
        (bool success,) = params.router.call(params.data);
        if (!success) revert RebalanceCallFailed();
        IERC20(params.sellAsset).forceApprove(params.router, 0);

        uint256 sold;
        uint256 bought;
        for (uint256 i; i < n; ++i) {
            address a = _assets[i];
            uint256 afterBal = IERC20(a).balanceOf(address(this));
            if (a == params.sellAsset) {
                if (afterBal > before[i]) revert RebalanceInvalid();
                sold = before[i] - afterBal;
            } else if (a == params.buyAsset) {
                if (afterBal < before[i]) revert RebalanceInvalid();
                bought = afterBal - before[i];
            } else if (afterBal < before[i]) {
                revert RebalanceInvalid();
            }
        }
        if (balanceOf(address(this)) < sharesBefore) revert RebalanceInvalid();
        if (sold > params.sellAmount || bought < params.minBuyAmount) revert RebalanceInvalid();

        IFundOracle o = IFundOracle(fac.oracle());
        uint256 soldValue = _value(params.sellAsset, sold, o.price(params.sellAsset));
        uint256 boughtValue = _value(params.buyAsset, bought, o.price(params.buyAsset));
        uint256 minValue = Math.mulDiv(soldValue, BPS - fac.maxRebalanceSlippageBps(), BPS, Math.Rounding.Ceil);
        if (boughtValue < minValue) revert RebalanceInvalid();
        _trackRebalanceVolume(fac, soldValue);

        emit Rebalanced(params.sellAsset, sold, params.buyAsset, bought);
    }

    /// @inheritdoc IFund
    function setTargetWeights(
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) external override onlyManager {
        if (!launched) revert NotLaunched();
        _setBasket(assets_, weightsBps_);
    }

    /// @inheritdoc IFund
    function setCreatorFee(
        uint16 feeBps,
        address recipient
    ) external override onlyAdmin {
        _setCreatorFee(feeBps, recipient);
    }

    /// @inheritdoc IFund
    function setLockOptions(
        LockOption[] calldata options
    ) external override onlyAdmin {
        _setLockOptions(options);
    }

    /// @inheritdoc IFund
    function setManager(
        address manager_
    ) external override onlyAdmin {
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    /// @inheritdoc IFund
    function setMintPaused(
        bool paused
    ) external override onlyAdmin {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    /// @notice Token name.
    /// @return The name.
    function name() public view override returns (string memory) {
        return _fundName;
    }

    /// @notice Token symbol.
    /// @return The symbol.
    function symbol() public view override returns (string memory) {
        return _fundSymbol;
    }

    /// @inheritdoc IFund
    function assets() external view override returns (address[] memory) {
        return _assets;
    }

    /// @inheritdoc IFund
    function lockOptions() external view override returns (LockOption[] memory) {
        return _lockOptions;
    }

    /// @inheritdoc IFund
    function locksOf(
        address account
    ) external view override returns (Lock[] memory) {
        return _locks[account];
    }

    /// @inheritdoc IFund
    function totalValue() public view override returns (uint256 value) {
        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            address a = _assets[i];
            uint256 bal = IERC20(a).balanceOf(address(this));
            if (bal != 0) value += _value(a, bal, o.price(a));
        }
    }

    /// @inheritdoc IFund
    function navPerShare() public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(totalValue(), PRECISION, supply);
    }

    /// @inheritdoc IFund
    function premiumBps() external view override returns (bool ok, int256 premium) {
        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        (bool marketOk, uint256 market) = o.tryPrice(address(this));
        uint256 supply = totalSupply();
        if (!marketOk || supply == 0) return (false, 0);

        uint256 value;
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            address a = _assets[i];
            uint256 bal = IERC20(a).balanceOf(address(this));
            if (bal == 0) continue;
            (bool priceOk, uint256 p) = o.tryPrice(a);
            if (!priceOk) return (false, 0);
            value += _value(a, bal, p);
        }
        uint256 nav = Math.mulDiv(value, PRECISION, supply);
        if (nav == 0) return (false, 0);
        return (true, int256(Math.mulDiv(market, BPS, nav)) - int256(BPS));
    }

    /// @inheritdoc IFund
    function previewMint(
        address asset,
        uint256 amount,
        uint256 lockOption
    ) external view override returns (uint256 shares, uint256 mintPrice) {
        uint256 assetPrice;
        (assetPrice, mintPrice) = _mintPrices(asset, lockOption);
        uint256 gross = _sharesForValue(_value(asset, amount, assetPrice), mintPrice);
        (uint256 protocolFee, uint256 creatorFee) = _fees(gross);
        shares = gross - protocolFee - creatorFee;
    }

    /// @inheritdoc IFund
    function previewRedeem(
        uint256 shares
    ) external view override returns (uint256[] memory amounts) {
        (uint256 protocolFee, uint256 creatorFee) = _fees(shares);
        return _redeemAmounts(shares - protocolFee - creatorFee);
    }

    /// @dev Asset price and mint price for a mint. The mint price is the fund token's market TWAP,
    ///      less the lock discount, but never below NAV (rounded up), so a mint never dilutes.
    function _mintPrices(
        address asset,
        uint256 lockOption
    ) internal view returns (uint256 assetPrice, uint256 mintPrice) {
        if (!launched) revert NotLaunched();
        if (!isAsset[asset] || targetWeightBps[asset] == 0) revert AssetNotMintable(asset);
        if (lockOption > _lockOptions.length) revert InvalidLockOption();

        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        assetPrice = o.price(asset);
        (bool ok, uint256 market) = o.tryPrice(address(this));
        if (!ok) revert NoMarketPrice();

        uint256 discount = lockOption == 0 ? 0 : _lockOptions[lockOption - 1].discountBps;
        uint256 discounted = Math.mulDiv(market, BPS - discount, BPS, Math.Rounding.Ceil);
        uint256 supply = totalSupply();
        uint256 nav = supply == 0 ? 0 : Math.mulDiv(totalValue(), PRECISION, supply, Math.Rounding.Ceil);
        mintPrice = discounted > nav ? discounted : nav;
    }

    function _trackRebalanceVolume(
        IFundFactory fac,
        uint256 soldValue
    ) internal {
        uint256 volume = rebalanceWindowVolume;
        if (block.timestamp >= uint256(rebalanceWindowStart) + 1 days) {
            rebalanceWindowStart = uint64(block.timestamp);
            volume = 0;
        }
        volume += soldValue;
        // Measured against the post-trade basket, which differs from pre-trade by at most the slippage bound.
        if (volume > Math.mulDiv(totalValue(), fac.rebalanceVolumeCapBps(), BPS)) revert RebalanceVolumeExceeded();
        rebalanceWindowVolume = SafeCast.toUint192(volume);
    }

    function _pull(
        address asset,
        uint256 amount
    ) internal returns (uint256 received) {
        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    function _chargeMintFees(
        uint256 gross
    ) internal returns (uint256 net) {
        (uint256 protocolFee, uint256 creatorFee) = _fees(gross);
        _mintFees(protocolFee, creatorFee);
        net = gross - protocolFee - creatorFee;
    }

    function _issue(
        address receiver,
        uint256 shares,
        uint256 lockOption
    ) internal returns (uint256 lockId) {
        if (lockOption == 0) {
            _mint(receiver, shares);
            return NO_LOCK;
        }
        _mint(address(this), shares);
        lockId = _locks[receiver].length;
        _locks[receiver].push(
            Lock({
                amount: SafeCast.toUint128(shares),
                unlockAt: SafeCast.toUint64(block.timestamp + _lockOptions[lockOption - 1].duration)
            })
        );
    }

    function _redeemAmounts(
        uint256 net
    ) internal view returns (uint256[] memory amounts) {
        uint256 n = _assets.length;
        amounts = new uint256[](n);
        uint256 supply = totalSupply();
        if (supply == 0) return amounts;
        for (uint256 i; i < n; ++i) {
            // Rounds down: the redeemer never takes more than their share.
            amounts[i] = Math.mulDiv(IERC20(_assets[i]).balanceOf(address(this)), net, supply);
        }
    }

    function _fees(
        uint256 shares
    ) internal view returns (uint256 protocolFee, uint256 creatorFee) {
        protocolFee = Math.mulDiv(shares, IFundFactory(factory).protocolFeeBps(), BPS);
        creatorFee = Math.mulDiv(shares, creatorFeeBps, BPS);
    }

    function _mintFees(
        uint256 protocolFee,
        uint256 creatorFee
    ) internal {
        if (protocolFee != 0) _mint(IFundFactory(factory).protocolFeeRecipient(), protocolFee);
        if (creatorFee != 0) _mint(creatorFeeRecipient, creatorFee);
        if (protocolFee != 0 || creatorFee != 0) emit FeesCharged(protocolFee, creatorFee);
    }

    function _setCreatorFee(
        uint16 feeBps,
        address recipient
    ) internal {
        if (feeBps > MAX_CREATOR_FEE_BPS) revert FeeTooHigh();
        if (recipient == address(0)) revert ZeroAddress();
        creatorFeeBps = feeBps;
        creatorFeeRecipient = recipient;
        emit CreatorFeeSet(feeBps, recipient);
    }

    function _setLockOptions(
        LockOption[] calldata options
    ) internal {
        if (options.length > MAX_LOCK_OPTIONS) revert InvalidLockOptions();
        delete _lockOptions;
        for (uint256 i; i < options.length; ++i) {
            if (options[i].duration == 0 || options[i].discountBps > MAX_LOCK_DISCOUNT_BPS) {
                revert InvalidLockOptions();
            }
            _lockOptions.push(options[i]);
        }
        emit LockOptionsSet(options);
    }

    function _setBasket(
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) internal {
        uint256 n = assets_.length;
        if (n == 0 || n > MAX_ASSETS || n != weightsBps_.length) revert InvalidBasket();

        address[] memory old = _assets;
        for (uint256 i; i < old.length; ++i) {
            isAsset[old[i]] = false;
            targetWeightBps[old[i]] = 0;
        }

        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = assets_[i];
            if (a == address(0) || a == address(this) || isAsset[a] || !o.hasFeed(a)) revert InvalidBasket();
            isAsset[a] = true;
            targetWeightBps[a] = weightsBps_[i];
            sum += weightsBps_[i];
        }
        if (sum != BPS) revert InvalidBasket();

        for (uint256 i; i < old.length; ++i) {
            if (!isAsset[old[i]] && IERC20(old[i]).balanceOf(address(this)) != 0) revert AssetHasBalance(old[i]);
        }

        _assets = assets_;
        emit TargetWeightsSet(assets_, weightsBps_);
    }

    function _value(
        address asset,
        uint256 amount,
        uint256 price
    ) internal view returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** IERC20Metadata(asset).decimals());
    }

    function _sharesForValue(
        uint256 value,
        uint256 price
    ) internal pure returns (uint256) {
        if (price == 0) revert NoMarketPrice();
        return Math.mulDiv(value, PRECISION, price);
    }
}
