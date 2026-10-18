// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundMintGateway} from "../interfaces/IFundMintGateway.sol";
import {IFundMintZap} from "../interfaces/IFundMintZap.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IAcrossSpokePool} from "../interfaces/external/IAcrossSpokePool.sol";
import {CcipClient, IAny2EVMMessageReceiver} from "../interfaces/external/ICcip.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundMintGateway — mint with USDG from a float-funded stock of Base-sourced assets
/// @notice See {IFundMintGateway}.
contract FundMintGateway is
    IFundMintGateway,
    IAny2EVMMessageReceiver,
    IERC165,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_MARKUP_BPS = 500;
    uint256 private constant MAX_FEE_BPS = 1000;
    uint64 private constant MIN_WAIT = 1 hours;
    uint64 private constant MAX_WAIT = 7 days;
    uint32 private constant MIN_FILL_WINDOW = 10 minutes;

    /// @dev A mint request, kept in memory to stay within the stack.
    struct Req {
        address fund;
        uint256 usdgIn;
        uint256 navShares;
        uint256 minSharesOut;
        bool atNav;
        address[] assets;
        uint256[] amounts;
        uint256 cost;
    }

    /// @dev Balances and amounts for one mint, kept in memory to stay within the stack.
    struct Run {
        address fund;
        address receiver;
        address[] assets;
        uint256[] taken;
        uint256[] before;
        uint256[] avail;
        uint256[] pre;
        uint256 budget;
        uint256 usdgBefore;
    }

    /// @notice The fund factory.
    address public immutable factory;
    /// @notice The factory's mint zap (this gateway holds its FUND_GATEWAY role).
    address public immutable zap;
    /// @notice The CCIP Router on this chain.
    address public immutable ccipRouter;
    /// @notice CCIP selector of Base.
    uint64 public immutable baseSelector;
    /// @notice The Base gateway: sends restock over CCIP.
    address public immutable baseGateway;
    /// @notice The Base gateway's float: receives the bridged revenue.
    address public immutable baseFloat;
    /// @notice The Across SpokePool on this chain.
    address public immutable spokePool;
    /// @notice USDC on Base (the Across output token).
    address public immutable baseUsdc;
    /// @notice EVM chain id of Base.
    uint256 public immutable baseChainId;

    address private immutable _usdg;
    uint256 private immutable _usdgScale;

    /// @inheritdoc IFundMintGateway
    uint256 public override revenue;
    /// @inheritdoc IFundMintGateway
    uint256 public override queuedUsdg;
    /// @notice Markup on stock over the oracle price.
    uint256 public markupBps;
    /// @notice Bridge fee cap as a share of the USDG bridged.
    uint256 public maxFeeBps;
    /// @notice Bridge fee cap in USDG; the larger applies.
    uint256 public maxFeeFlat;
    /// @notice Seconds before a receiver may cancel a queued order.
    uint64 public maxWait;
    /// @notice Seconds a relayer has to fill a revenue bridge.
    uint32 public fillWindow;
    /// @notice Orders queued so far (ids start at 1).
    uint256 public orderCount;

    mapping(address => uint256) private _stock;
    mapping(address => uint256) private _reserved;
    mapping(address => bool) private _baseAssets;
    mapping(address => bool) private _keepers;
    mapping(uint256 => Order) private _orders;

    modifier onlyKeeper() {
        if (!_keepers[msg.sender]) revert NotKeeper();
        _;
    }

    /// @param owner_        Owner (the governance Safe).
    /// @param factory_      The fund factory.
    /// @param zap_          The factory's mint zap.
    /// @param ccipRouter_   The CCIP Router on this chain.
    /// @param baseSelector_ CCIP selector of Base.
    /// @param baseGateway_  The Base gateway.
    /// @param baseFloat_    The Base gateway's float.
    /// @param spokePool_    The Across SpokePool on this chain.
    /// @param baseUsdc_     USDC on Base.
    /// @param baseChainId_  EVM chain id of Base.
    constructor(
        address owner_,
        address factory_,
        address zap_,
        address ccipRouter_,
        uint64 baseSelector_,
        address baseGateway_,
        address baseFloat_,
        address spokePool_,
        address baseUsdc_,
        uint256 baseChainId_
    ) Ownable(owner_) {
        if (
            factory_ == address(0) || zap_ == address(0) || ccipRouter_ == address(0) || baseGateway_ == address(0)
                || baseFloat_ == address(0) || spokePool_ == address(0) || baseUsdc_ == address(0) || baseSelector_ == 0
                || baseChainId_ == 0
        ) revert ZeroAddress();
        factory = factory_;
        zap = zap_;
        ccipRouter = ccipRouter_;
        baseSelector = baseSelector_;
        baseGateway = baseGateway_;
        baseFloat = baseFloat_;
        spokePool = spokePool_;
        baseUsdc = baseUsdc_;
        baseChainId = baseChainId_;
        address usdg = IFundFactory(factory_).usdg();
        _usdg = usdg;
        _usdgScale = 10 ** IERC20Metadata(usdg).decimals();
        markupBps = 30;
        maxWait = 1 days;
        maxFeeBps = 50;
        maxFeeFlat = 2 * _usdgScale;
        fillWindow = 4 hours;
    }

    /// @inheritdoc IFundMintGateway
    function mint(
        address fund,
        uint256 usdgIn,
        Swap[] calldata swaps,
        uint256 navShares,
        uint256 minSharesOut,
        bool atNav
    ) external override nonReentrant returns (uint256 shares, uint256 id) {
        if (!IFundFactory(factory).isFund(fund)) revert NotFund();
        if (usdgIn == 0 || navShares == 0) revert ZeroAddress();
        IERC20(_usdg).safeTransferFrom(msg.sender, address(this), usdgIn);
        Req memory q = Req(fund, usdgIn, navShares, minSharesOut, atNav, IFund(fund).assets(), new uint256[](0), 0);
        uint256 quoted;
        (quoted,, q.amounts,,) = IFund(fund).previewMint(navShares, atNav);
        bool short;
        (q.cost, short) = _quote(q.assets, q.amounts);
        if (q.cost > usdgIn) revert InsufficientUsdg();
        revenue += q.cost;

        if (short) {
            // A minimum above today's quote would let the receiver block keeper fills.
            if (minSharesOut > quoted) revert Slippage();
            return (0, _queue(q));
        }
        shares = _mintNow(q, swaps);
    }

    function _mintNow(Req memory q, Swap[] calldata swaps) internal returns (uint256 shares) {
        Run memory run = _run(q.fund, msg.sender, q.assets, _takeStock(q.assets, q.amounts), q.usdgIn - q.cost);
        shares = _execute(run, swaps, q.navShares, q.minSharesOut, q.atNav, true);
        emit MintedNow(q.fund, msg.sender, q.usdgIn, shares);
    }

    /// @inheritdoc IFundMintGateway
    function fill(
        uint256 id,
        Swap[] calldata swaps,
        uint256 navShares
    ) external override nonReentrant returns (uint256 shares) {
        Order storage o = _orders[id];
        if (o.status != Status.Queued) revert NotQueued();
        address receiver = o.receiver;
        if (!_keepers[msg.sender] && msg.sender != receiver) revert NotKeeper();
        uint256 orderShares = o.navShares;
        if (navShares == 0 || navShares > orderShares) revert InvalidParam();
        if (navShares != orderShares && !_keepers[msg.sender]) revert InvalidParam();

        o.status = Status.Filled;
        uint256 budget = o.usdg;
        queuedUsdg -= budget;
        address fund = o.fund;
        Run memory run = _run(fund, receiver, IFund(fund).assets(), new uint256[](0), budget);
        run.taken = _takeOwed(o, run.assets, receiver);
        shares = _execute(
            run,
            swaps,
            navShares,
            Math.mulDiv(o.minSharesOut, navShares, orderShares, Math.Rounding.Ceil),
            o.atNav,
            false
        );
        emit Filled(id, shares, msg.sender);
    }

    /// @inheritdoc IFundMintGateway
    function cancel(
        uint256 id
    ) external override nonReentrant {
        Order storage o = _orders[id];
        if (o.status != Status.Queued) revert NotQueued();
        if (msg.sender != o.receiver) revert NotReceiver();
        if (block.timestamp < o.createdAt + maxWait) revert TooEarly();
        uint256 usdg = o.usdg;
        uint256 prepaid = o.prepaid;
        bool inKind = _covers(o);
        if (!inKind && revenue < prepaid) {
            // The prepaid part is on Base; release the order's own USDG and keep the order open.
            if (usdg == 0) revert InsufficientRevenue();
            o.usdg = 0;
            queuedUsdg -= usdg;
            IERC20(_usdg).safeTransfer(msg.sender, usdg);
            emit UsdgReleased(id, usdg);
            return;
        }
        o.status = Status.Cancelled;
        queuedUsdg -= usdg;
        uint256 refund = usdg;
        if (!inKind) {
            revenue -= prepaid;
            refund += prepaid;
        }
        _releaseOwed(o, inKind, msg.sender);
        if (refund != 0) IERC20(_usdg).safeTransfer(msg.sender, refund);
        emit Cancelled(id, refund, inKind);
    }

    /// @notice Adds Base-sourced assets the Base gateway sends to the stock (called by the CCIP Router).
    /// @dev Never reverts for a router delivery, except one re-entered from inside a call here (the message
    ///      then stays open for manual execution). Anything not from the Base gateway, or not a Base-sourced
    ///      asset, stays untracked for the owner to sweep.
    /// @param message The CCIP message.
    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external override nonReentrant {
        if (msg.sender != ccipRouter) revert NotRouter();
        if (message.sourceChainSelector != baseSelector || message.sender.length != 32) return;
        if (abi.decode(message.sender, (uint256)) != uint256(uint160(baseGateway))) return;
        uint256 n = message.destTokenAmounts.length;
        for (uint256 i; i < n; ++i) {
            address token = message.destTokenAmounts[i].token;
            if (!_baseAssets[token]) continue;
            uint256 amount = message.destTokenAmounts[i].amount;
            _stock[token] += amount;
            emit Restocked(token, amount);
        }
    }

    /// @inheritdoc IFundMintGateway
    function bridgeRevenue(
        uint256 usdgIn,
        uint256 usdcOut,
        uint32 quoteTimestamp
    ) external override onlyKeeper nonReentrant {
        if (usdgIn == 0) revert ZeroAddress();
        uint256 rev = revenue;
        if (usdgIn > rev) revert InsufficientRevenue();
        // Below the size where the flat cap dominates, only a bridge of all revenue, so the cap can't be split.
        if (usdgIn != rev && usdgIn * maxFeeBps / BPS < maxFeeFlat) revert InvalidParam();
        if (usdcOut > usdgIn || usdgIn - usdcOut > Math.max(maxFeeFlat, usdgIn * maxFeeBps / BPS)) {
            revert BridgeFeeTooHigh();
        }
        revenue = rev - usdgIn;
        address pool = spokePool;
        IERC20(_usdg).forceApprove(pool, usdgIn);
        // An unfilled bridge refunds the owner, so no refund can land here in the middle of a swap.
        IAcrossSpokePool(pool).depositV3(
            owner(),
            baseFloat,
            _usdg,
            baseUsdc,
            usdgIn,
            usdcOut,
            baseChainId,
            address(0),
            quoteTimestamp,
            uint32(block.timestamp) + fillWindow,
            0,
            ""
        );
        IERC20(_usdg).forceApprove(pool, 0);
        emit RevenueBridged(usdgIn, usdcOut);
    }

    /// @inheritdoc IFundMintGateway
    function syncRevenue() external override nonReentrant {
        if (!_keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
        uint256 held = IERC20(_usdg).balanceOf(address(this));
        uint256 tracked = revenue + queuedUsdg;
        if (held > tracked) revenue += held - tracked;
        emit RevenueSynced(revenue);
    }

    /// @inheritdoc IFundMintGateway
    function addStock(address asset, uint256 amount) external override onlyOwner nonReentrant {
        if (!_baseAssets[asset]) revert InvalidParam();
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = IERC20(asset).balanceOf(address(this)) - before;
        _stock[asset] += got;
        emit Restocked(asset, got);
    }

    /// @inheritdoc IFundMintGateway
    function removeStock(address asset, uint256 amount, address to) external override onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (_free(asset) < amount) revert InsufficientStock();
        _stock[asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        emit StockRemoved(asset, amount, to);
    }

    /// @inheritdoc IFundMintGateway
    function withdrawRevenue(uint256 amount, address to) external override onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > revenue) revert InsufficientRevenue();
        revenue -= amount;
        IERC20(_usdg).safeTransfer(to, amount);
        emit RevenueSynced(revenue);
    }

    /// @notice Send `token` the gateway holds beyond its stock, revenue and orders (owner).
    /// @param token The token.
    /// @param to    Recipient.
    function sweep(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 tracked = _stock[token];
        if (token == _usdg) tracked += revenue + queuedUsdg;
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held > tracked) IERC20(token).safeTransfer(to, held - tracked);
    }

    /// @inheritdoc IFundMintGateway
    function setKeeper(address keeper, bool allowed) external override onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        _keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @inheritdoc IFundMintGateway
    function setBaseAsset(address asset, bool allowed) external override onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == _usdg || (!allowed && (_stock[asset] != 0 || _reserved[asset] != 0))) revert InvalidParam();
        _baseAssets[asset] = allowed;
        emit BaseAssetSet(asset, allowed);
    }

    /// @inheritdoc IFundMintGateway
    function setSettings(
        uint256 markupBps_,
        uint64 maxWait_,
        uint256 maxFeeBps_,
        uint256 maxFeeFlat_,
        uint32 fillWindow_
    ) external override onlyOwner {
        if (
            markupBps_ > MAX_MARKUP_BPS || maxWait_ < MIN_WAIT || maxWait_ > MAX_WAIT || maxFeeBps_ > MAX_FEE_BPS
                || fillWindow_ < MIN_FILL_WINDOW || fillWindow_ > IAcrossSpokePool(spokePool).fillDeadlineBuffer()
        ) revert InvalidParam();
        markupBps = markupBps_;
        maxWait = maxWait_;
        maxFeeBps = maxFeeBps_;
        maxFeeFlat = maxFeeFlat_;
        fillWindow = fillWindow_;
        emit SettingsSet(markupBps_, maxWait_, maxFeeBps_, maxFeeFlat_, fillWindow_);
    }

    /// @inheritdoc IFundMintGateway
    function stockCost(address asset, uint256 amount) public view override returns (uint256) {
        uint256 price = IFundOracle(IFundFactory(factory).oracle()).price(asset);
        uint256 unit = 10 ** IERC20Metadata(asset).decimals();
        // Rounds up: the minter pays at least the stock's value.
        return Math.mulDiv(amount, price * (BPS + markupBps) * _usdgScale, unit * BPS * 1e18, Math.Rounding.Ceil);
    }

    /// @inheritdoc IFundMintGateway
    function getOrder(
        uint256 id
    ) external view override returns (Order memory) {
        return _orders[id];
    }

    /// @inheritdoc IFundMintGateway
    function stock(
        address asset
    ) external view override returns (uint256) {
        return _stock[asset];
    }

    /// @inheritdoc IFundMintGateway
    function reserved(
        address asset
    ) external view override returns (uint256) {
        return _reserved[asset];
    }

    /// @notice Whether `asset` is Base-sourced (stocked here).
    /// @param asset The asset.
    /// @return True if stocked.
    function isBaseAsset(
        address asset
    ) external view returns (bool) {
        return _baseAssets[asset];
    }

    /// @notice Whether `keeper` may fill orders and bridge revenue.
    /// @param keeper The address.
    /// @return True if allowed.
    function isKeeper(
        address keeper
    ) external view returns (bool) {
        return _keepers[keeper];
    }

    /// @notice ERC-165: the CCIP OffRamp only calls `ccipReceive` on contracts that report it.
    /// @param interfaceId The interface id.
    /// @return True for IAny2EVMMessageReceiver and IERC165.
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _quote(
        address[] memory assets,
        uint256[] memory amounts
    ) internal view returns (uint256 cost, bool short) {
        for (uint256 i; i < assets.length; ++i) {
            if (!_baseAssets[assets[i]] || amounts[i] == 0) continue;
            cost += stockCost(assets[i], amounts[i]);
            if (_free(assets[i]) < amounts[i]) short = true;
        }
    }

    function _takeStock(address[] memory assets, uint256[] memory amounts) internal returns (uint256[] memory taken) {
        taken = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            if (!_baseAssets[assets[i]] || amounts[i] == 0) continue;
            _stock[assets[i]] -= amounts[i];
            taken[i] = amounts[i];
        }
    }

    function _takeOwed(
        Order storage o,
        address[] memory assets,
        address receiver
    ) internal returns (uint256[] memory taken) {
        taken = new uint256[](assets.length);
        uint256 m = o.assets.length;
        for (uint256 j; j < m; ++j) {
            address asset = o.assets[j];
            uint256 owed = o.owed[j];
            if (_stock[asset] < owed) revert InsufficientStock();
            _stock[asset] -= owed;
            _reserved[asset] -= owed;
            bool inBasket;
            for (uint256 i; i < assets.length; ++i) {
                if (assets[i] == asset) (taken[i], inBasket) = (owed, true);
            }
            // An asset dropped from the basket while the order waited is the receiver's in kind.
            if (!inBasket) IERC20(asset).safeTransfer(receiver, owed);
        }
    }

    function _free(
        address asset
    ) internal view returns (uint256) {
        uint256 s = _stock[asset];
        uint256 r = _reserved[asset];
        return s > r ? s - r : 0;
    }

    function _covers(
        Order storage o
    ) internal view returns (bool) {
        for (uint256 j; j < o.assets.length; ++j) {
            if (_stock[o.assets[j]] < o.owed[j]) return false;
        }
        return true;
    }

    /// @dev Drops the order's reservation; `take` also hands the owed stock to `to` in kind.
    function _releaseOwed(Order storage o, bool take, address to) internal {
        for (uint256 j; j < o.assets.length; ++j) {
            address asset = o.assets[j];
            uint256 owed = o.owed[j];
            _reserved[asset] -= owed;
            if (take) {
                _stock[asset] -= owed;
                IERC20(asset).safeTransfer(to, owed);
            }
        }
    }

    function _queue(
        Req memory q
    ) internal returns (uint256 id) {
        id = ++orderCount;
        Order storage o = _orders[id];
        o.receiver = msg.sender;
        o.status = Status.Queued;
        o.atNav = q.atNav;
        o.createdAt = uint64(block.timestamp);
        o.fund = q.fund;
        o.navShares = q.navShares;
        o.minSharesOut = q.minSharesOut;
        uint256 usdg = q.usdgIn - q.cost;
        o.usdg = usdg;
        o.prepaid = q.cost;
        for (uint256 i; i < q.assets.length; ++i) {
            if (!_baseAssets[q.assets[i]] || q.amounts[i] == 0) continue;
            o.assets.push(q.assets[i]);
            o.owed.push(q.amounts[i]);
            _reserved[q.assets[i]] += q.amounts[i];
        }
        queuedUsdg += usdg;
        emit Queued(id, q.fund, msg.sender, usdg, q.cost);
    }

    function _run(
        address fund,
        address receiver,
        address[] memory assets,
        uint256[] memory taken,
        uint256 budget
    ) internal view returns (Run memory run) {
        run.fund = fund;
        run.receiver = receiver;
        run.assets = assets;
        run.taken = taken;
        run.budget = budget;
        run.before = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            run.before[i] = IERC20(assets[i]).balanceOf(address(this));
        }
        run.usdgBefore = IERC20(_usdg).balanceOf(address(this));
    }

    /// @dev Buys the Robinhood assets with `run.budget` USDG, mints through the zap, and settles every
    ///      balance by its change: leftover Robinhood assets and USDG to the receiver, leftover stock back
    ///      to the stock (`restock`) or, for a queued order that prepaid it, to the receiver.
    function _execute(
        Run memory run,
        Swap[] calldata swaps,
        uint256 navShares,
        uint256 minSharesOut,
        bool atNav,
        bool restock
    ) internal returns (uint256 shares) {
        uint256 spent = _swapAll(run, swaps);
        _approveZap(run, run.budget - spent);
        shares = IFundMintZap(zap).zapMintFor(run.fund, navShares, minSharesOut, run.receiver, atNav);
        _settle(run, restock);
    }

    function _swapAll(Run memory run, Swap[] calldata swaps) internal returns (uint256 spent) {
        address usdg = _usdg;
        IFundFactory fac = IFundFactory(factory);
        for (uint256 i; i < swaps.length; ++i) {
            Swap calldata s = swaps[i];
            if (!fac.isRouter(s.router) || s.router == run.fund || s.tokenIn != usdg) revert RouterNotAllowed();
            IERC20(usdg).forceApprove(s.router, s.amountIn);
            (bool ok,) = s.router.call(s.data);
            if (!ok) revert SwapFailed();
            IERC20(usdg).forceApprove(s.router, 0);
        }
        spent = run.usdgBefore - IERC20(usdg).balanceOf(address(this));
        if (spent > run.budget) revert InsufficientUsdg();
    }

    function _approveZap(Run memory run, uint256 usdgAllowance) internal {
        address z = zap;
        uint256 n = run.assets.length;
        run.avail = new uint256[](n);
        run.pre = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 bal = IERC20(run.assets[i]).balanceOf(address(this));
            run.pre[i] = bal;
            run.avail[i] = run.taken[i] != 0 ? run.taken[i] : bal - run.before[i];
            IERC20(run.assets[i]).forceApprove(z, run.avail[i]);
        }
        IERC20(_usdg).forceApprove(z, usdgAllowance);
    }

    function _settle(Run memory run, bool restock) internal {
        address z = zap;
        IERC20 usdg = IERC20(_usdg);
        usdg.forceApprove(z, 0);
        for (uint256 i; i < run.assets.length; ++i) {
            IERC20 a = IERC20(run.assets[i]);
            a.forceApprove(z, 0);
            // Saturating: a zap refund above what it pulled (a donation) must not revert the mint.
            uint256 have = a.balanceOf(address(this)) + run.avail[i];
            uint256 left = have > run.pre[i] ? have - run.pre[i] : 0;
            if (left == 0) continue;
            if (run.taken[i] != 0 && restock) _stock[run.assets[i]] += left;
            else a.safeTransfer(run.receiver, left);
        }
        uint256 usdgHave = usdg.balanceOf(address(this)) + run.budget;
        uint256 usdgLeft = usdgHave > run.usdgBefore ? usdgHave - run.usdgBefore : 0;
        if (usdgLeft != 0) usdg.safeTransfer(run.receiver, usdgLeft);
    }
}
