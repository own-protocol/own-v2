// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";

import {CreateFundParams, FundMetadata, LockOption} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {FundRebalance} from "./libraries/FundRebalance.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Fund — Own Curated Fund token and basket
/// @notice See {IFund}.
/// @dev Deployed as a beacon proxy per fund by {FundFactory}; storage is append-only across
///      upgrades. The ERC-20 name and symbol live in this contract's storage because the inherited
///      ones are constructor-set on the implementation.
contract Fund is IFund, ERC20, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum number of basket assets (bounds every loop over the basket).
    uint256 public constant MAX_ASSETS = 20;

    /// @notice Hard cap on the curator fee.
    uint16 public constant MAX_CURATOR_FEE_BPS = 1000;

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
    uint16 public override curatorFeeBps;

    /// @inheritdoc IFund
    uint64 public override depositorUnlockAt;

    /// @inheritdoc IFund
    address public override curators;

    string private _fundName;
    string private _fundSymbol;

    address[] private _assets;

    /// @inheritdoc IFund
    mapping(address asset => bool) public override isAsset;

    /// @inheritdoc IFund
    mapping(address asset => uint16) public override targetWeightBps;

    LockOption[] private _lockOptions;

    mapping(address account => Lock[]) private _locks;

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

    /// @inheritdoc IFund
    uint16 public override maxPremiumBps;

    modifier onlyAdmin() {
        if (msg.sender != IFundFactory(factory).owner()) revert NotAdmin();
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

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
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
        _setMetadata(params.name, params.symbol, params.logoURI, params.description);
        manager = params.manager;
        emit ManagerSet(params.manager);
        _setCuratorFee(params.curatorFeeBps);
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
        if (msg.sender != launch) revert NotLaunch();
        if (launched) revert AlreadyLaunched();
        launched = true;
        depositorUnlockAt = depositorUnlockAt_;
        emit Launched(depositorUnlockAt_);
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
        (uint256 assetPrice, uint256 mintPrice) = _mintPrices(asset, amount, lockOption);
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
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut
    ) external override nonReentrant returns (uint256[] memory amounts, uint256 usdgAmount) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 n = _assets.length;
        if (minAmountsOut.length != 0 && minAmountsOut.length != n) revert LengthMismatch();

        (uint256 protocolFee, uint256 curatorFee) = _fees(shares);
        uint256 net = shares - protocolFee - curatorFee;
        uint256 supply = effectiveSupply();
        if (net > supply) revert RedeemTooLarge();
        amounts = _redeemAmounts(net, supply);
        for (uint256 i; i < n; ++i) {
            if (minAmountsOut.length != 0 && amounts[i] < minAmountsOut[i]) revert Slippage();
        }
        // Rounds down: the redeemer never takes more than their share.
        uint256 idle = Math.mulDiv(idleUsdg(), net, supply);

        // Burning everything and minting the fees back moves locked launch tokens only by burning.
        _burn(msg.sender, shares);
        _mintFees(protocolFee, curatorFee);

        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) IERC20(_assets[i]).safeTransfer(receiver, amounts[i]);
        }
        if (idle != 0) IERC20(_usdg()).safeTransfer(receiver, idle);
        usdgAmount = idle + IFundHook(IFundFactory(factory).hook()).redeemPosition(net, supply, receiver);
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
        uint256 volume =
            FundRebalance.rebalance(factory, _assets, isAsset, params, rebalanceVolume, rebalanceVolumeUpdatedAt);
        rebalanceVolume = SafeCast.toUint192(volume);
        rebalanceVolumeUpdatedAt = uint64(block.timestamp);
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
    function setCuratorFee(
        uint16 feeBps
    ) external override onlyAdmin {
        _setCuratorFee(feeBps);
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
    ) external override onlyAdmin {
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
    function locksOf(
        address account
    ) external view override returns (Lock[] memory) {
        return _locks[account];
    }

    /// @inheritdoc IFund
    function totalValue() public view override returns (uint256) {
        IFundFactory fac = IFundFactory(factory);
        address usdg = fac.usdg();
        (uint256 positionUsdg,) = positionAmounts();
        return _valueOf(_assets, IFundOracle(fac.oracle()))
            + _usdgValue(usdg, IERC20(usdg).balanceOf(address(this)) + positionUsdg);
    }

    /// @inheritdoc IFund
    function navPerShare() public view override returns (uint256) {
        uint256 supply = effectiveSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(totalValue(), PRECISION, supply);
    }

    /// @inheritdoc IFund
    function idleUsdg() public view override returns (uint256) {
        return IERC20(_usdg()).balanceOf(address(this));
    }

    /// @inheritdoc IFund
    function positionAmounts() public view override returns (uint256 usdgAmount, uint256 fundTokens) {
        if (!launched) return (0, 0);
        return IFundHook(IFundFactory(factory).hook()).positionAmounts(address(this));
    }

    /// @inheritdoc IFund
    function effectiveSupply() public view override returns (uint256) {
        (, uint256 positionTokens) = positionAmounts();
        uint256 supply = totalSupply();
        return supply > positionTokens ? supply - positionTokens : 0;
    }

    /// @inheritdoc IFund
    function isDust(
        address asset
    ) external view override returns (bool) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return true;
        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        (bool ok, uint256 p) = o.tryPrice(asset);
        if (!ok) return false;
        uint256 basket;
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            address a = _assets[i];
            uint256 b = IERC20(a).balanceOf(address(this));
            if (b == 0) continue;
            (bool aOk, uint256 aPrice) = o.tryPrice(a);
            if (!aOk) return false;
            basket += _value(a, b, aPrice);
        }
        return _value(asset, bal, p) <= Math.mulDiv(basket, DUST_BPS, BPS);
    }

    /// @inheritdoc IFund
    function premiumBps() external view override returns (bool ok, int256 premium) {
        IFundFactory fac = IFundFactory(factory);
        IFundOracle o = IFundOracle(fac.oracle());
        (bool marketOk, uint256 market) = o.tryPrice(address(this));
        uint256 supply = effectiveSupply();
        if (!marketOk || supply == 0) return (false, 0);

        address usdg = fac.usdg();
        (uint256 positionUsdg,) = positionAmounts();
        uint256 value = _usdgValue(usdg, IERC20(usdg).balanceOf(address(this)) + positionUsdg);
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
        (assetPrice, mintPrice) = _mintPrices(asset, amount, lockOption);
        uint256 gross = _sharesForValue(_value(asset, amount, assetPrice), mintPrice);
        (uint256 protocolFee, uint256 curatorFee) = _fees(gross);
        shares = gross - protocolFee - curatorFee;
    }

    /// @inheritdoc IFund
    function previewRedeem(
        uint256 shares
    ) external view override returns (uint256[] memory amounts, uint256 usdgAmount) {
        (uint256 protocolFee, uint256 curatorFee) = _fees(shares);
        uint256 net = shares - protocolFee - curatorFee;
        uint256 supply = effectiveSupply();
        if (net > supply) revert RedeemTooLarge();
        amounts = _redeemAmounts(net, supply);
        (uint256 positionUsdg,) = positionAmounts();
        usdgAmount = Math.mulDiv(idleUsdg(), net, supply) + Math.mulDiv(positionUsdg, net, supply);
    }

    /// @dev Asset price and mint price for a mint. The mint price is the fund token's market TWAP,
    ///      capped at the premium ceiling, less the lock discount, but never below NAV (rounded up),
    ///      so a mint never dilutes. While the ceiling binds, the deposit may not take its asset above
    ///      target weight, so arbitrage at the ceiling cannot skew the basket.
    function _mintPrices(
        address asset,
        uint256 amount,
        uint256 lockOption
    ) internal view returns (uint256 assetPrice, uint256 mintPrice) {
        if (!launched) revert NotLaunched();
        if (!isAsset[asset] || targetWeightBps[asset] == 0) revert AssetNotMintable(asset);
        if (lockOption > _lockOptions.length) revert InvalidLockOption();

        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        assetPrice = o.price(asset);
        (bool ok, uint256 market) = o.tryPrice(address(this));
        if (!ok) revert NoMarketPrice();

        uint256 supply = effectiveSupply();
        uint256 nav = supply == 0 ? 0 : Math.mulDiv(totalValue(), PRECISION, supply, Math.Rounding.Ceil);
        uint256 ceiling = maxPremiumBps == 0 ? type(uint256).max : Math.mulDiv(nav, BPS + maxPremiumBps, BPS);
        if (market > ceiling) {
            market = ceiling;
            _checkUnderweight(asset, _value(asset, amount, assetPrice), assetPrice, o);
        }
        uint256 discount = lockOption == 0 ? 0 : _lockOptions[lockOption - 1].discountBps;
        uint256 discounted = Math.mulDiv(market, BPS - discount, BPS, Math.Rounding.Ceil);
        mintPrice = discounted > nav ? discounted : nav;
    }

    function _checkUnderweight(address asset, uint256 deposit, uint256 assetPrice, IFundOracle o) internal view {
        uint256 held = _value(asset, IERC20(asset).balanceOf(address(this)), assetPrice) + deposit;
        if (held * BPS > (_valueOf(_assets, o) + deposit) * targetWeightBps[asset]) revert AssetOverweight(asset);
    }

    function _pull(address asset, uint256 amount) internal returns (uint256 received) {
        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    function _chargeMintFees(
        uint256 gross
    ) internal returns (uint256 net) {
        (uint256 protocolFee, uint256 curatorFee) = _fees(gross);
        _mintFees(protocolFee, curatorFee);
        net = gross - protocolFee - curatorFee;
    }

    function _issue(address receiver, uint256 shares, uint256 lockOption) internal returns (uint256 lockId) {
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

    function _redeemAmounts(uint256 net, uint256 supply) internal view returns (uint256[] memory amounts) {
        uint256 n = _assets.length;
        amounts = new uint256[](n);
        if (supply == 0) return amounts;
        for (uint256 i; i < n; ++i) {
            // Rounds down: the redeemer never takes more than their share.
            amounts[i] = Math.mulDiv(IERC20(_assets[i]).balanceOf(address(this)), net, supply);
        }
    }

    function _fees(
        uint256 shares
    ) internal view returns (uint256 protocolFee, uint256 curatorFee) {
        protocolFee = Math.mulDiv(shares, IFundFactory(factory).protocolFeeBps(), BPS);
        curatorFee = Math.mulDiv(shares, curatorFeeBps, BPS);
    }

    function _mintFees(uint256 protocolFee, uint256 curatorFee) internal {
        if (protocolFee != 0) _mint(IFundFactory(factory).protocolFeeRecipient(), protocolFee);
        if (curatorFee != 0) _mint(curators, curatorFee);
        if (protocolFee != 0 || curatorFee != 0) emit FeesCharged(protocolFee, curatorFee);
    }

    function _setCuratorFee(
        uint16 feeBps
    ) internal {
        if (feeBps > MAX_CURATOR_FEE_BPS) revert FeeTooHigh();
        curatorFeeBps = feeBps;
        emit CuratorFeeSet(feeBps);
    }

    /// @dev Launch-locked tokens can leave an account only by being burned (redeem) or through
    ///      the staking module, which first moves the lock onto the stake.
    function _update(address from, address to, uint256 value) internal override {
        bool lockActive = from != address(0) && block.timestamp < depositorUnlockAt && launchLocked[from] != 0;
        if (lockActive && to != address(0) && balanceOf(from) < value + launchLocked[from]) {
            revert LaunchTokensLocked();
        }
        super._update(from, to, value);
        if (lockActive && to == address(0)) {
            uint256 bal = balanceOf(from);
            if (launchLocked[from] > bal) {
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
            isAsset[old[i]] = false;
            targetWeightBps[old[i]] = 0;
        }

        IFundOracle o = IFundOracle(IFundFactory(factory).oracle());
        address usdg = _usdg();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = assets_[i];
            if (a == address(0) || a == address(this) || a == usdg || isAsset[a] || !o.hasFeed(a)) {
                revert InvalidBasket();
            }
            isAsset[a] = true;
            targetWeightBps[a] = weightsBps_[i];
            sum += weightsBps_[i];
        }
        if (sum != BPS) revert InvalidBasket();

        uint256 dustLimit;
        for (uint256 i; i < old.length; ++i) {
            address a = old[i];
            if (isAsset[a]) continue;
            uint256 bal = IERC20(a).balanceOf(address(this));
            if (bal == 0) continue;
            // Anyone can send a dropped asset back to the fund, so a balance worth under DUST_BPS of the
            // basket is left behind rather than blocking the change.
            (bool ok, uint256 p) = o.tryPrice(a);
            if (dustLimit == 0) dustLimit = Math.mulDiv(_valueOf(old, o), DUST_BPS, BPS);
            if (!ok || _value(a, bal, p) > dustLimit) revert AssetHasBalance(a);
        }

        _assets = assets_;
        emit TargetWeightsSet(assets_, weightsBps_);
    }

    function _valueOf(address[] memory assets, IFundOracle o) internal view returns (uint256 value) {
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            address a = assets[i];
            uint256 bal = IERC20(a).balanceOf(address(this));
            if (bal != 0) value += _value(a, bal, o.price(a));
        }
    }

    function _value(address asset, uint256 amount, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** IERC20Metadata(asset).decimals());
    }

    function _usdgValue(address usdg, uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, PRECISION, 10 ** IERC20Metadata(usdg).decimals());
    }

    function _usdg() internal view returns (address) {
        return IFundFactory(factory).usdg();
    }

    function _sharesForValue(uint256 value, uint256 price) internal pure returns (uint256) {
        if (price == 0) revert NoMarketPrice();
        return Math.mulDiv(value, PRECISION, price);
    }
}
