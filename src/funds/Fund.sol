// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";

import {
    BasketEntry,
    CreateFundParams,
    FundMetadata,
    LockOption,
    MAX_BASKET_ASSETS
} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {FundRebalance} from "./libraries/FundRebalance.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Fund — Own Curated Fund token and basket
/// @notice See {IFund}.
/// @dev Deployed as a beacon proxy per fund by {FundFactory}; storage is append-only across
///      upgrades. The ERC-20 name and symbol live in this contract's storage because the inherited
///      ones are constructor-set on the implementation.
contract Fund is IFund, ERC20, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Maximum number of basket assets (bounds every loop over the basket).
    uint256 public constant MAX_ASSETS = MAX_BASKET_ASSETS;

    /// @notice Hard cap on the fund fee.
    uint16 public constant MAX_FEE_BPS = 1000;

    /// @notice Fund fee used when a fund is created without one: 1%.
    uint16 public constant DEFAULT_FEE_BPS = 100;

    /// @notice Hard cap on a lock option's discount.
    uint16 public constant MAX_LOCK_DISCOUNT_BPS = 5000;

    /// @notice Maximum number of lock options.
    uint256 public constant MAX_LOCK_OPTIONS = 8;

    /// @notice A dropped asset worth at most this share of the basket may be left behind, in basis points.
    uint256 public constant DUST_BPS = 10;

    uint256 private constant NO_LOCK = type(uint256).max;

    /// @inheritdoc IFund
    address public override factory;

    /// @inheritdoc IFund
    uint16 public override maxPremiumBps;

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
    uint16 public override feeBps;

    /// @inheritdoc IFund
    uint64 public override depositorUnlockAt;

    /// @inheritdoc IFund
    address public override curators;

    string private _fundName;
    string private _fundSymbol;

    address[] private _assets;
    mapping(address asset => BasketEntry) private _basket;

    LockOption[] private _lockOptions;

    /// @notice When {rebalanceVolume} was last updated.
    uint64 public rebalanceVolumeUpdatedAt;

    /// @notice Oracle value sold by rebalances that still counts against the cap, 18 decimals USD.
    ///         It drains linearly at the full cap per day.
    uint192 public rebalanceVolume;

    /// @inheritdoc IFund
    address public override governor;

    /// @inheritdoc IFund
    string public override logoURI;

    /// @inheritdoc IFund
    string public override description;

    /// @inheritdoc IFund
    mapping(address account => uint256) public override launchLocked;

    address private immutable _usdg;

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyStaking() {
        if (msg.sender != staking) revert NotStaking();
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier onlyModule() {
        _checkModule();
        _;
    }

    /// @param usdg_ The factory's USDG, fixed for every fund of the platform.
    constructor(
        address usdg_
    ) ERC20("", "") {
        if (usdg_ == address(0)) revert ZeroAddress();
        _usdg = usdg_;
        _disableInitializers();
    }

    /// @inheritdoc IFund
    function initialize(
        CreateFundParams calldata params
    ) external override initializer {
        if (params.manager == address(0)) revert ZeroAddress();
        // The implementation is built for one USDG; only a factory using the same one may deploy it.
        if (IFundFactory(msg.sender).usdg() != _usdg) revert NotFactory();
        factory = msg.sender;
        _setMetadata(params.name, params.symbol, params.logoURI, params.description);
        manager = params.manager;
        emit ManagerSet(params.manager);
        _setFee(params.feeBps == 0 ? DEFAULT_FEE_BPS : params.feeBps);
        _setBasket(params.assets, params.weightsBps);
        _setLockOptions(params.lockOptions);
        maxPremiumBps = params.maxPremiumBps;
        emit MaxPremiumSet(params.maxPremiumBps);
    }

    /// @inheritdoc IFund
    function setModules(
        address launch_,
        address staking_,
        address governor_,
        address curators_
    ) external override onlyFactory {
        if (launch != address(0)) revert ModulesAlreadySet();
        if (launch_ == address(0) || staking_ == address(0) || governor_ == address(0) || curators_ == address(0)) {
            revert ZeroAddress();
        }
        launch = launch_;
        staking = staking_;
        governor = governor_;
        curators = curators_;
        emit GovernorSet(governor_);
    }

    /// @inheritdoc IFund
    function markLaunched(
        uint64 depositorUnlockAt_
    ) external override {
        _checkLaunch();
        if (launched) revert AlreadyLaunched();
        launched = true;
        depositorUnlockAt = depositorUnlockAt_;
        emit Launched(depositorUnlockAt_);
    }

    /// @inheritdoc IFund
    function sendPoolUsdg(
        uint256 amount
    ) external override {
        _checkLaunch();
        IERC20(_usdg).safeTransfer(_hook(), amount);
    }

    /// @inheritdoc IFund
    function moduleMint(address to, uint256 amount) external override onlyModule {
        _mint(to, amount);
    }

    /// @inheritdoc IFund
    function addLaunchLock(address account, uint256 amount) external override onlyModule {
        if (block.timestamp >= depositorUnlockAt || amount == 0) return;
        uint256 locked = launchLocked[account] + amount;
        launchLocked[account] = locked;
        emit LaunchLockSet(account, locked);
    }

    /// @inheritdoc IFund
    function releaseLaunchLock(address account, uint256 amount) external override onlyStaking returns (uint256 moved) {
        if (block.timestamp >= depositorUnlockAt) return 0;
        uint256 locked = launchLocked[account];
        if (locked == 0) return 0;
        uint256 bal = balanceOf(account);
        uint256 free = bal > locked ? bal - locked : 0;
        if (amount <= free) return 0;
        moved = amount - free;
        if (moved > locked) moved = locked;
        launchLocked[account] = locked - moved;
        emit LaunchLockSet(account, locked - moved);
    }

    /// @inheritdoc IFund
    function mint(
        uint256 navShares,
        uint256 lockOption,
        uint256 minSharesOut,
        address receiver
    ) external override nonReentrant returns (uint256 shares) {
        if (navShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (mintPaused) revert MintPaused();

        // The slice and the prices are read before anything is pulled, so the deposit cannot move them.
        address[] memory basket = _assets;
        address usdg = _usdg;
        (uint256 gross, uint256 mintPrice, uint256[] memory amounts, uint256 usdgAmount) =
            _mintQuote(basket, usdg, navShares, lockOption);
        for (uint256 i; i < basket.length; ++i) {
            _pull(basket[i], amounts[i]);
        }
        _pull(usdg, usdgAmount);
        shares = _chargeMintFees(gross);
        if (shares == 0 || shares < minSharesOut) revert Slippage();
        uint256 lockId = _issue(receiver, shares, lockOption);

        emit Minted(msg.sender, receiver, navShares, shares, mintPrice, lockId);
    }

    /// @inheritdoc IFund
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut
    ) external override nonReentrant returns (uint256[] memory amounts, uint256 usdgAmount) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        address[] memory basket = _assets;
        if (minAmountsOut.length != 0 && minAmountsOut.length != basket.length) revert LengthMismatch();

        address usdg = _usdg;
        address hook = _hook();
        uint256 net;
        uint256 supply;
        uint256 idle;
        {
            uint256 fee = _fee(shares);
            net = shares - fee;
            (, supply) = _poolAndSupplyAt(hook);
            (amounts, idle) = _redeemAmounts(basket, usdg, net, supply);
            for (uint256 i; i < minAmountsOut.length; ++i) {
                if (amounts[i] < minAmountsOut[i]) revert Slippage();
            }

            // Burning everything and minting the fees back moves locked launch tokens only by burning.
            _burn(msg.sender, shares);
            _mintFee(fee);
        }

        for (uint256 i; i < basket.length; ++i) {
            if (amounts[i] != 0) IERC20(basket[i]).safeTransfer(receiver, amounts[i]);
        }
        if (idle != 0) IERC20(usdg).safeTransfer(receiver, idle);
        usdgAmount = idle + IFundHook(hook).redeemPosition(net, supply, receiver);
        if (usdgAmount < minUsdgOut) revert Slippage();

        emit Redeemed(msg.sender, receiver, shares, amounts, usdgAmount);
    }

    /// @inheritdoc IFund
    function burn(
        uint256 amount
    ) external override {
        _burn(msg.sender, amount);
    }

    /// @inheritdoc IFund
    function rebalance(
        RebalanceParams calldata params
    ) external override nonReentrant {
        if (!_isAdmin() && (msg.sender != manager || IFundHook(_hook()).isSeeded(address(this)))) {
            revert NotManager();
        }
        uint256 volume =
            FundRebalance.rebalance(factory, _usdg, _assets, _basket, params, rebalanceVolume, rebalanceVolumeUpdatedAt);
        rebalanceVolume = SafeCast.toUint192(volume);
        rebalanceVolumeUpdatedAt = uint64(block.timestamp);
    }

    /// @inheritdoc IFund
    function auctionPayout(address asset, address to, uint256 amount) external override nonReentrant {
        if (msg.sender != IFundFactory(factory).auctions()) revert NotAuctions();
        if (asset == address(this)) revert InvalidBasket();
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @inheritdoc IFund
    function setTargetWeights(
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) external override onlyGovernor nonReentrant {
        if (!launched) revert NotLaunched();
        _setBasket(assets_, weightsBps_);
    }

    /// @inheritdoc IFund
    function setFee(
        uint16 feeBps_
    ) external override onlyAdmin {
        _setFee(feeBps_);
    }

    /// @inheritdoc IFund
    function setLockOptions(
        LockOption[] calldata options
    ) external override onlyAdmin {
        _setLockOptions(options);
    }

    /// @inheritdoc IFund
    function setGovernor(
        address governor_
    ) external override onlyAdmin {
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
        emit GovernorSet(governor_);
    }

    /// @inheritdoc IFund
    function setMetadata(
        string calldata name_,
        string calldata symbol_,
        string calldata logoURI_,
        string calldata description_
    ) external override onlyAdmin {
        _setMetadata(name_, symbol_, logoURI_, description_);
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
    ) external override {
        _checkOperator();
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    /// @inheritdoc IFund
    function setMaxPremium(
        uint16 maxPremiumBps_
    ) external override onlyAdmin {
        maxPremiumBps = maxPremiumBps_;
        emit MaxPremiumSet(maxPremiumBps_);
    }

    /// @inheritdoc IFund
    function sweep(
        address token
    ) external override nonReentrant returns (uint256 amount) {
        _checkOperator();
        address to = IFundFactory(factory).sweepRecipient();
        if (to == address(0)) revert ZeroAddress();
        if (_basket[token].listed || token == address(this) || token == _usdg) {
            revert NotSweepable(token);
        }
        amount = _balanceOf(token);
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
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
    function metadata() external view override returns (FundMetadata memory) {
        return FundMetadata({
            name: _fundName,
            symbol: _fundSymbol,
            logoURI: logoURI,
            description: description,
            platform: IFundFactory(factory).platformMetadata()
        });
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
    function isAsset(
        address asset
    ) external view override returns (bool) {
        return _basket[asset].listed;
    }

    /// @inheritdoc IFund
    function targetWeightBps(
        address asset
    ) external view override returns (uint16) {
        return _basket[asset].weightBps;
    }

    /// @inheritdoc IFund
    function totalValue() public view override returns (uint256 value) {
        (uint256 poolUsdg,) = positionAmounts();
        (, value) = _totalValue(_oracle(), _assets, _usdg, poolUsdg);
    }

    /// @inheritdoc IFund
    function navPerShare() public view override returns (uint256) {
        (uint256 poolUsdg, uint256 supply) = _poolAndSupply();
        if (supply == 0) return 0;
        (, uint256 value) = _totalValue(_oracle(), _assets, _usdg, poolUsdg);
        return Math.mulDiv(value, PRECISION, supply);
    }

    /// @inheritdoc IFund
    function idleUsdg() public view override returns (uint256) {
        return _balanceOf(_usdg);
    }

    /// @inheritdoc IFund
    function positionAmounts() public view override returns (uint256 usdgAmount, uint256 fundTokens) {
        if (!launched) return (0, 0);
        return IFundHook(_hook()).positionAmounts(address(this));
    }

    /// @inheritdoc IFund
    function effectiveSupply() public view override returns (uint256 supply) {
        (, supply) = _poolAndSupply();
    }

    /// @inheritdoc IFund
    function isDust(
        address asset
    ) external view override returns (bool) {
        uint256 bal = _balanceOf(asset);
        if (bal == 0) return true;
        IFundOracle o = _oracle();
        (bool ok, uint256 p) = o.tryPrice(asset);
        if (!ok) return false;
        (bool basketOk, uint256 basket) = _basketValue(_assets, o, true);
        return basketOk && _value(asset, bal, p) <= Math.mulDiv(basket, DUST_BPS, BPS);
    }

    /// @inheritdoc IFund
    function premiumBps() external view override returns (bool ok, int256 premium) {
        IFundOracle o = _oracle();
        (bool marketOk, uint256 market) = o.tryPrice(address(this));
        (uint256 poolUsdg, uint256 supply) = _poolAndSupply();
        if (!marketOk || supply == 0) return (false, 0);
        (bool basketOk, uint256 basket) = _basketValue(_assets, o, true);
        if (!basketOk) return (false, 0);
        uint256 nav = Math.mulDiv(basket + _usdgBacking(_usdg, poolUsdg), PRECISION, supply);
        if (nav == 0) return (false, 0);
        return (true, int256(Math.mulDiv(market, BPS, nav)) - int256(BPS));
    }

    /// @inheritdoc IFund
    function previewMint(
        uint256 navShares,
        uint256 lockOption
    )
        external
        view
        override
        returns (uint256 shares, uint256 mintPrice, uint256[] memory amounts, uint256 usdgAmount)
    {
        uint256 gross;
        (gross, mintPrice, amounts, usdgAmount) = _mintQuote(_assets, _usdg, navShares, lockOption);
        shares = gross - _fee(gross);
    }

    /// @inheritdoc IFund
    function previewRedeem(
        uint256 shares
    ) external view override returns (uint256[] memory amounts, uint256 usdgAmount) {
        uint256 net = shares - _fee(shares);
        (uint256 poolUsdg, uint256 supply) = _poolAndSupply();
        (amounts, usdgAmount) = _redeemAmounts(_assets, _usdg, net, supply);
        usdgAmount += Math.mulDiv(poolUsdg, net, supply);
    }

    function _hook() internal view returns (address) {
        return IFundFactory(factory).hook();
    }

    function _oracle() internal view returns (IFundOracle) {
        return IFundOracle(IFundFactory(factory).oracle());
    }

    function _balanceOf(
        address token
    ) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _isAdmin() internal view returns (bool) {
        return IFundFactory(factory).isAdmin(msg.sender);
    }

    function _checkAdmin() internal view {
        if (!_isAdmin()) revert NotAdmin();
    }

    function _checkModule() internal view {
        if (msg.sender != launch && msg.sender != staking) revert NotModule();
    }

    function _checkLaunch() internal view {
        if (msg.sender != launch) revert NotLaunch();
    }

    function _checkOperator() internal view {
        if (!IFundFactory(factory).isOperator(msg.sender)) revert NotOperator();
    }

    /// @dev A mint of `navShares`: the depositor brings `navShares / supply` of every basket asset
    ///      and of the fund's USDG (idle plus the pool position's), each rounded up, so no oracle
    ///      values the deposit and the basket keeps its proportions. The fund tokens issued are
    ///      `navShares` scaled down by the mint price over NAV: the market TWAP, capped at the premium
    ///      ceiling, less the lock discount, never below NAV. A mispriced oracle can only cost the
    ///      minter, never dilute holders.
    function _mintQuote(
        address[] memory basket,
        address usdg,
        uint256 navShares,
        uint256 lockOption
    ) internal view returns (uint256 gross, uint256 mintPrice, uint256[] memory amounts, uint256 usdgAmount) {
        if (!launched) revert NotLaunched();
        if (lockOption > _lockOptions.length) revert InvalidLockOption();
        (uint256 poolUsdg, uint256 supply) = _poolAndSupply();
        if (supply == 0) revert EmptyFund();
        uint256 nav;
        (nav, mintPrice) = _mintPrice(basket, usdg, poolUsdg, supply, lockOption);
        // Rounds down: the minter never receives more than its slice is worth at the mint price.
        gross = nav == 0 ? 0 : Math.mulDiv(navShares, nav, mintPrice);
        (amounts, usdgAmount) = _mintAmounts(basket, usdg, navShares, poolUsdg, supply);
    }

    function _mintPrice(
        address[] memory basket,
        address usdg,
        uint256 poolUsdg,
        uint256 supply,
        uint256 lockOption
    ) internal view returns (uint256 nav, uint256 mintPrice) {
        IFundOracle o = _oracle();
        (bool ok, uint256 market) = o.tryPrice(address(this));
        if (!ok) revert NoMarketPrice();
        (, uint256 total) = _totalValue(o, basket, usdg, poolUsdg);
        nav = Math.mulDiv(total, PRECISION, supply, Math.Rounding.Ceil);
        if (maxPremiumBps != 0) market = Math.min(market, Math.mulDiv(nav, BPS + maxPremiumBps, BPS));
        uint256 discount = lockOption == 0 ? 0 : _lockOptions[lockOption - 1].discountBps;
        mintPrice = Math.max(Math.mulDiv(market, BPS - discount, BPS, Math.Rounding.Ceil), nav);
    }

    function _mintAmounts(
        address[] memory basket,
        address usdg,
        uint256 navShares,
        uint256 poolUsdg,
        uint256 supply
    ) internal view returns (uint256[] memory amounts, uint256 usdgAmount) {
        amounts = new uint256[](basket.length);
        for (uint256 i; i < basket.length; ++i) {
            amounts[i] = Math.mulDiv(_balanceOf(basket[i]), navShares, supply, Math.Rounding.Ceil);
        }
        usdgAmount = Math.mulDiv(_balanceOf(usdg) + poolUsdg, navShares, supply, Math.Rounding.Ceil);
    }

    function _pull(address asset, uint256 amount) internal {
        if (amount == 0) return;
        IERC20 token = IERC20(asset);
        uint256 balanceBefore = _balanceOf(asset);
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (_balanceOf(asset) - balanceBefore < amount) revert Slippage();
    }

    function _chargeMintFees(
        uint256 gross
    ) internal returns (uint256 net) {
        uint256 fee = _fee(gross);
        _mintFee(fee);
        net = gross - fee;
    }

    function _issue(address receiver, uint256 shares, uint256 lockOption) internal returns (uint256 lockId) {
        if (lockOption == 0) {
            _mint(receiver, shares);
            return NO_LOCK;
        }
        address stakingModule = staking;
        _mint(stakingModule, shares);
        lockId = IFundStaking(stakingModule).stakeLocked(
            receiver, shares, SafeCast.toUint64(block.timestamp + _lockOptions[lockOption - 1].duration)
        );
    }

    /// @dev Each basket asset's and the idle USDG's share for `net` of `supply`. Rounds down: the
    ///      redeemer never takes more than their share.
    function _redeemAmounts(
        address[] memory basket,
        address usdg,
        uint256 net,
        uint256 supply
    ) internal view returns (uint256[] memory amounts, uint256 idle) {
        if (net > supply) revert RedeemTooLarge();
        uint256 n = basket.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amounts[i] = Math.mulDiv(_balanceOf(basket[i]), net, supply);
        }
        idle = Math.mulDiv(_balanceOf(usdg), net, supply);
    }

    function _fee(
        uint256 shares
    ) internal view returns (uint256) {
        return Math.mulDiv(shares, feeBps, BPS);
    }

    function _mintFee(
        uint256 fee
    ) internal {
        if (fee == 0) return;
        _mint(curators, fee);
        emit FeesCharged(fee);
    }

    function _setFee(
        uint16 feeBps_
    ) internal {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    /// @dev Launch-locked tokens can leave an account only by being burned (redeem) or through
    ///      the staking module, which first moves the lock onto the stake.
    function _update(address from, address to, uint256 value) internal override {
        uint256 locked = from == address(0) || block.timestamp >= depositorUnlockAt ? 0 : launchLocked[from];
        if (locked != 0 && to != address(0) && balanceOf(from) < value + locked) revert LaunchTokensLocked();
        super._update(from, to, value);
        if (locked != 0 && to == address(0)) {
            uint256 bal = balanceOf(from);
            if (locked > bal) {
                launchLocked[from] = bal;
                emit LaunchLockSet(from, bal);
            }
        }
    }

    function _setMetadata(
        string calldata name_,
        string calldata symbol_,
        string calldata logoURI_,
        string calldata description_
    ) internal {
        uint256 nameLen = bytes(name_).length;
        uint256 symbolLen = bytes(symbol_).length;
        if (
            nameLen == 0 || nameLen > 64 || symbolLen == 0 || symbolLen > 16 || bytes(logoURI_).length > 512
                || bytes(description_).length > 2000
        ) revert InvalidMetadata();
        _fundName = name_;
        _fundSymbol = symbol_;
        logoURI = logoURI_;
        description = description_;
        emit MetadataSet(name_, symbol_, logoURI_, description_);
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

    function _setBasket(address[] calldata assets_, uint16[] calldata weightsBps_) internal {
        uint256 n = assets_.length;
        if (n == 0 || n > MAX_ASSETS || n != weightsBps_.length) revert InvalidBasket();

        address[] memory old = _assets;
        for (uint256 i; i < old.length; ++i) {
            delete _basket[old[i]];
        }

        IFundOracle o = _oracle();
        address usdg = _usdg;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = assets_[i];
            if (a == address(0) || a == address(this) || a == usdg || _basket[a].listed || !o.hasFeed(a)) {
                revert InvalidBasket();
            }
            _basket[a] = BasketEntry({listed: true, weightBps: weightsBps_[i]});
            sum += weightsBps_[i];
        }
        if (sum != BPS) revert InvalidBasket();

        uint256 dustLimit;
        for (uint256 i; i < old.length; ++i) {
            address a = old[i];
            if (_basket[a].listed) continue;
            uint256 bal = _balanceOf(a);
            if (bal == 0) continue;
            // Anyone can send a dropped asset back to the fund, so a balance worth under DUST_BPS of the
            // basket is left behind rather than blocking the change.
            (bool ok, uint256 p) = o.tryPrice(a);
            if (dustLimit == 0) {
                (, uint256 oldValue) = _basketValue(old, o, false);
                dustLimit = Math.mulDiv(oldValue, DUST_BPS, BPS);
            }
            if (!ok || _value(a, bal, p) > dustLimit) revert AssetHasBalance(a);
        }

        _assets = assets_;
        emit TargetWeightsSet(assets_, weightsBps_);
    }

    /// @dev The USDG in the fund's pool position and the supply outside the pool, reading the
    ///      position once.
    function _poolAndSupply() internal view returns (uint256 poolUsdg, uint256 supply) {
        return _poolAndSupplyAt(_hook());
    }

    function _poolAndSupplyAt(
        address hook
    ) internal view returns (uint256 poolUsdg, uint256 supply) {
        uint256 poolTokens;
        if (launched) (poolUsdg, poolTokens) = IFundHook(hook).positionAmounts(address(this));
        supply = totalSupply();
        supply = supply > poolTokens ? supply - poolTokens : 0;
    }

    /// @dev The basket's value, and the fund's total value: the basket plus idle and pooled USDG.
    function _totalValue(
        IFundOracle o,
        address[] memory assets_,
        address usdg,
        uint256 poolUsdg
    ) internal view returns (uint256 basket, uint256 total) {
        (, basket) = _basketValue(assets_, o, false);
        total = basket + _usdgBacking(usdg, poolUsdg);
    }

    /// @dev Value of the fund's holdings of `basket` at oracle prices. A missing price reverts, or
    ///      with `soft` returns ok = false.
    function _basketValue(
        address[] memory basket,
        IFundOracle o,
        bool soft
    ) internal view returns (bool ok, uint256 value) {
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            address a = basket[i];
            uint256 bal = _balanceOf(a);
            if (bal == 0) continue;
            uint256 p;
            if (soft) {
                (ok, p) = o.tryPrice(a);
                if (!ok) return (false, 0);
            } else {
                p = o.price(a);
            }
            value += _value(a, bal, p);
        }
        ok = true;
    }

    /// @dev Idle USDG plus `poolUsdg`, valued at $1 (18 decimals).
    function _usdgBacking(address usdg, uint256 poolUsdg) internal view returns (uint256) {
        return _value(usdg, _balanceOf(usdg) + poolUsdg, PRECISION);
    }

    function _value(address asset, uint256 amount, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** IERC20Metadata(asset).decimals());
    }
}
