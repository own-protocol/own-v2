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
    DUST_BPS,
    FundMetadata,
    PremiumConfig,
    PremiumConfigLib,
    Valuation,
    ValuationLib
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
    using ValuationLib for Valuation;

    /// @dev A priced mint: fund tokens before the fee, the price and NAV, the slice to bring, and
    ///      whether the premium cap set the price.
    struct MintQuote {
        uint256 gross;
        uint256 mintPrice;
        uint256 nav;
        uint256[] amounts;
        uint256 usdgAmount;
        bool capped;
    }

    // Hard cap on the fund fee.
    uint16 private constant MAX_FEE_BPS = 1000;

    // Fund fee used when a fund is created without one: 1%.
    uint16 private constant DEFAULT_FEE_BPS = 100;

    /// @inheritdoc IFund
    address public override factory;

    /// @inheritdoc IFund
    uint32 public override mintLock;

    /// @inheritdoc IFund
    int16 public override mintAdjustmentBps;

    /// @inheritdoc IFund
    uint32 public override navMintLock;

    /// @inheritdoc IFund
    uint32 public override maxPremiumBps;

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
        FundRebalance.setBasket(_oracle(), _usdg, _assets, _basket, params.assets, params.weightsBps);
        PremiumConfig memory c = IFundFactory(msg.sender).premiumConfig();
        _setMintConfig(c.mintLock, c.mintAdjustmentBps, c.navMintLock, c.maxPremiumBps);
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
        uint256 minSharesOut,
        address receiver,
        bool atNav
    ) external override nonReentrant returns (uint256 shares) {
        if (navShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (mintPaused) revert MintPaused();

        // The slice and the prices are read before anything is pulled, so the deposit cannot move them.
        address[] memory basket = _assets;
        MintQuote memory q = _mintQuote(basket, _usdg, navShares, atNav);
        for (uint256 i; i < basket.length; ++i) {
            _pull(basket[i], q.amounts[i]);
        }
        _pull(_usdg, q.usdgAmount);
        shares = _chargeMintFees(q.gross);
        if (shares == 0 || shares < minSharesOut) revert Slippage();
        uint256 boost;
        if (q.capped) {
            _mint(receiver, shares);
        } else {
            // A lock or a boost lands only on the caller (the zap mints for its own caller).
            if (receiver != msg.sender && msg.sender != IFundFactory(factory).mintZap()) revert NotReceiver();
            boost = _stakeMinted(receiver, shares, navShares, q.gross, atNav);
        }

        emit Minted(msg.sender, receiver, navShares, shares, q.mintPrice, boost);
    }

    /// @inheritdoc IFund
    function hookIssue(address to, uint256 shares, uint256 pot) external override {
        if (msg.sender != _hook()) revert NotHook();
        _mint(to, shares);
        if (pot != 0) {
            address stakingModule = staking;
            _mint(stakingModule, pot);
            IFundStaking(stakingModule).addPot(pot);
        }
        emit Issued(shares, pot);
    }

    /// @inheritdoc IFund
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut
    ) external override nonReentrant returns (uint256[] memory amounts, uint256 usdgAmount) {
        return _redeem(shares, receiver, minAmountsOut, minUsdgOut, new address[](0));
    }

    /// @inheritdoc IFund
    function redeemSkipping(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut,
        address[] calldata skip
    ) external override nonReentrant returns (uint256[] memory amounts, uint256 usdgAmount) {
        return _redeem(shares, receiver, minAmountsOut, minUsdgOut, skip);
    }

    function _redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut,
        address[] memory skip
    ) internal returns (uint256[] memory amounts, uint256 usdgAmount) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        address[] memory basket = _assets;
        if (minAmountsOut.length != 0 && minAmountsOut.length != basket.length) revert LengthMismatch();

        (uint256 net, uint256 supply, uint256 idle) = _redeemQuote(_hook(), shares);
        amounts = _redeemAssets(basket, net, supply);
        _skipAndCheck(basket, amounts, skip, minAmountsOut);

        // Burning everything and minting the fees back moves locked launch tokens only by burning.
        _burn(msg.sender, shares);
        _mintFee(_fee(shares));

        for (uint256 i; i < basket.length; ++i) {
            if (amounts[i] != 0) IERC20(basket[i]).safeTransfer(receiver, amounts[i]);
        }
        if (idle != 0) IERC20(_usdg).safeTransfer(receiver, idle);
        usdgAmount = idle + IFundHook(_hook()).redeemPosition(net, supply, receiver);
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
        FundRebalance.setBasket(_oracle(), _usdg, _assets, _basket, assets_, weightsBps_);
    }

    /// @inheritdoc IFund
    function setFee(
        uint16 feeBps_
    ) external override onlyAdmin {
        _setFee(feeBps_);
        IFundHook(_hook()).setFundFee(feeBps_);
    }

    /// @inheritdoc IFund
    function setMintConfig(
        uint32 lock,
        int16 adjustmentBps,
        uint32 navLock,
        uint32 maxPremiumBps_
    ) external override onlyAdmin {
        _setMintConfig(lock, adjustmentBps, navLock, maxPremiumBps_);
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
    function increasePosition(
        uint256 usdgAmount
    ) external override onlyAdmin nonReentrant returns (uint128 liquidity) {
        address hook = _hook();
        IERC20(_usdg).safeTransfer(hook, usdgAmount);
        liquidity = IFundHook(hook).increasePosition(usdgAmount);
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
    function tryNav() external view override returns (bool ok, uint256 nav, uint256 supply) {
        Valuation memory v = _valuation(false);
        nav = v.nav();
        return (nav != 0, nav, v.supply);
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
    function valuation() external view override returns (Valuation memory) {
        return _valuation(true);
    }

    /// @inheritdoc IFund
    function premiumBps() external view override returns (bool ok, int256 premium) {
        return _valuation(true).premiumBps();
    }

    /// @inheritdoc IFund
    function previewMint(
        uint256 navShares,
        bool atNav
    )
        external
        view
        override
        returns (uint256 shares, uint256 mintPrice, uint256[] memory amounts, uint256 usdgAmount, bool locked)
    {
        MintQuote memory q = _mintQuote(_assets, _usdg, navShares, atNav);
        return (q.gross - _fee(q.gross), q.mintPrice, q.amounts, q.usdgAmount, !q.capped);
    }

    /// @inheritdoc IFund
    function previewRedeem(
        uint256 shares
    ) external view override returns (uint256[] memory amounts, uint256 usdgAmount) {
        address[] memory basket = _assets;
        address hook = _hook();
        (uint256 net, uint256 supply, uint256 idle) = _redeemQuote(hook, shares);
        amounts = _redeemAssets(basket, net, supply);
        (uint256 poolUsdg,) = _boundedPoolAndSupply(hook, false);
        usdgAmount = idle + Math.mulDiv(poolUsdg, net, supply);
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

    /// @dev A mint of `navShares`: the depositor brings `navShares` worth at NAV of a slice of
    ///      everything backing the fund (every basket asset and the fund's USDG, idle plus the pool
    ///      position's), each rounded up, so no oracle values the deposit
    ///      and the basket keeps its proportions. The fund tokens issued are `navShares` scaled down
    ///      by the mint price over NAV: NAV itself for a mint at NAV, else the pool price (see
    ///      {_poolMintPrice}). A mispriced oracle can only cost the minter, never dilute holders.
    function _mintQuote(
        address[] memory basket,
        address usdg,
        uint256 navShares,
        bool atNav
    ) internal view returns (MintQuote memory q) {
        if (!launched) revert NotLaunched();
        address hook = _hook();
        (uint256 poolUsdg, uint256 supply) = _boundedPoolAndSupply(hook, true);
        if (supply == 0) revert EmptyFund();
        IFundOracle o = _oracle();
        (, uint256 total) = _totalValue(o, basket, usdg, poolUsdg);
        q.nav = Math.mulDiv(total, PRECISION, supply, Math.Rounding.Ceil);
        q.mintPrice = q.nav;
        if (!atNav) _poolMintPrice(o, hook, q);
        // Rounds down: the minter never receives more than its slice is worth at the mint price.
        q.gross = q.nav == 0 ? 0 : Math.mulDiv(navShares, q.nav, q.mintPrice);
        (q.amounts, q.usdgAmount) = _mintAmounts(basket, usdg, navShares, poolUsdg, supply);
    }

    /// @dev The higher of the pool's spot price and its TWAP, so pushing the pool down for a block
    ///      never mints cheaply, adjusted by the mint adjustment; held to the premium cap when one is
    ///      set (and marked capped), and never below NAV.
    function _poolMintPrice(IFundOracle o, address hook, MintQuote memory q) internal view {
        (bool ok, uint256 market) = o.tryPrice(address(this));
        if (!ok) revert NoMarketPrice();
        market = Math.max(market, IFundHook(hook).spotPrice(address(this)));
        uint256 price = Math.mulDiv(market, uint256(int256(BPS) + mintAdjustmentBps), BPS, Math.Rounding.Ceil);
        uint256 cap = maxPremiumBps;
        if (cap != 0) {
            cap = Math.mulDiv(q.nav, BPS + cap, BPS, Math.Rounding.Ceil);
            if (price > cap) (price, q.capped) = (cap, true);
        }
        q.mintPrice = Math.max(price, q.nav);
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

    /// @dev Mints the boost, the staking module's share of the premium in fund tokens (the
    ///      `navShares` paid for less the `gross` issued; none at NAV), to the staking module with
    ///      `shares`, and stakes `shares` for `receiver`, locked for the direct or NAV mint lock.
    function _stakeMinted(
        address receiver,
        uint256 shares,
        uint256 navShares,
        uint256 gross,
        bool atNav
    ) internal returns (uint256 boost) {
        address stakingModule = staking;
        if (!atNav) boost = Math.mulDiv(navShares - gross, IFundStaking(stakingModule).boostShareBps(), BPS);
        _mint(stakingModule, shares + boost);
        IFundStaking(stakingModule).stakeMinted(
            receiver,
            shares,
            navShares,
            boost,
            SafeCast.toUint64(block.timestamp + (atNav ? navMintLock : mintLock)),
            atNav
        );
    }

    /// @dev The fund tokens `shares` (fees included) claim after the fee, the supply they are a
    ///      share of, and their share of the idle USDG. Rounds down: the redeemer never takes more
    ///      than their share.
    function _redeemQuote(
        address hook,
        uint256 shares
    ) internal view returns (uint256 net, uint256 supply, uint256 idle) {
        (, supply) = _boundedPoolAndSupply(hook, false);
        net = shares - _fee(shares);
        if (net > supply) revert RedeemTooLarge();
        idle = Math.mulDiv(_balanceOf(_usdg), net, supply);
    }

    /// @dev Zeroes the skipped assets' amounts (their slices stay in the fund for the remaining
    ///      holders), then checks the per-asset minimums.
    function _skipAndCheck(
        address[] memory basket,
        uint256[] memory amounts,
        address[] memory skip,
        uint256[] calldata minAmountsOut
    ) internal pure {
        for (uint256 i; i < skip.length; ++i) {
            for (uint256 j; j < basket.length; ++j) {
                if (basket[j] == skip[i]) amounts[j] = 0;
            }
        }
        for (uint256 i; i < minAmountsOut.length; ++i) {
            if (amounts[i] < minAmountsOut[i]) revert Slippage();
        }
    }

    /// @dev Each basket asset's share for `net` of `supply`. Rounds down.
    function _redeemAssets(
        address[] memory basket,
        uint256 net,
        uint256 supply
    ) internal view returns (uint256[] memory amounts) {
        uint256 n = basket.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amounts[i] = Math.mulDiv(_balanceOf(basket[i]), net, supply);
        }
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

    function _setMintConfig(uint32 lock, int16 adjustmentBps, uint32 navLock, uint32 maxPremiumBps_) internal {
        if (!PremiumConfigLib.mintValid(lock, adjustmentBps, navLock)) revert InvalidMintConfig();
        (mintLock, mintAdjustmentBps, navMintLock, maxPremiumBps) = (lock, adjustmentBps, navLock, maxPremiumBps_);
        emit MintConfigSet(lock, adjustmentBps, navLock, maxPremiumBps_);
    }

    /// @dev The holdings at oracle prices without reverting, with the market price when `market`.
    function _valuation(
        bool market
    ) internal view returns (Valuation memory v) {
        uint256 poolUsdg;
        (poolUsdg, v.supply) = _poolAndSupply();
        IFundOracle o = _oracle();
        uint256 basket;
        (v.ok, basket) = _basketValue(_assets, o, true);
        if (v.ok) v.total = basket + _usdgBacking(_usdg, poolUsdg);
        if (market) (v.marketOk, v.market) = o.tryPrice(address(this));
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
        supply = _supplyOutside(poolTokens);
    }

    /// @dev As {_poolAndSupplyAt}, but each amount at whichever of the TWAP and spot readings costs
    ///      the caller: the lower for a redeem, the higher for a mint. A move held for the TWAP
    ///      window and then reversed, or one made within a block, never moves both readings.
    function _boundedPoolAndSupply(address hook, bool mint) internal view returns (uint256 poolUsdg, uint256 supply) {
        uint256 poolTokens;
        if (launched) (poolUsdg, poolTokens) = IFundHook(hook).positionBounds(address(this), mint);
        supply = _supplyOutside(poolTokens);
    }

    function _supplyOutside(
        uint256 poolTokens
    ) internal view returns (uint256 supply) {
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
