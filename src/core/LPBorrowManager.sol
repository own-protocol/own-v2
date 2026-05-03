// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IBorrowDebt} from "../interfaces/IBorrowDebt.sol";
import {ILPBorrowManager} from "../interfaces/ILPBorrowManager.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultBorrowCoordinator} from "../interfaces/IVaultBorrowCoordinator.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
import {InterestRateModel} from "../libraries/InterestRateModel.sol";

import {BPS, Order, OrderStatus, PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPBorrowManager — LP borrowing against vault shares
/// @notice Custody-transfer model: LP transfers their `OwnVault` shares to
///         this contract, which borrows USDC from Aave V3 via credit
///         delegation on the vault's behalf. The manager is registered as a
///         vault share custodian, so vault-fee rewards earned during the
///         borrow window pass through to the LP on collateral return.
///
///         Multicall enables atomic `borrow → placeMintOrder` flows in one tx.
contract LPBorrowManager is ILPBorrowManager, IBorrowDebt, ReentrancyGuard, Multicall {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant AAVE_VARIABLE_RATE_MODE = 2;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    address public immutable override vault;
    address public immutable override stablecoin;
    address public immutable override debtToken;
    address public immutable override aavePool;
    address public immutable override market;
    bytes32 public immutable override collateralAsset;

    IProtocolRegistry public immutable registry;
    IVaultBorrowCoordinator public immutable coordinator;

    uint8 internal immutable _stableDecimals;

    // ──────────────────────────────────────────────────────────
    //  Configuration
    // ──────────────────────────────────────────────────────────

    InterestRateModel.Params internal _rateParams;

    /// @dev Floor on Aave-side rate (BPS). Actual rate = max(floor, coordinator.liveAaveRateBps()).
    uint256 public minAaveBorrowRateBps;

    /// @inheritdoc ILPBorrowManager
    uint256 public override liquidationThresholdBps;
    /// @inheritdoc ILPBorrowManager
    uint256 public override liquidationBonusBps;
    /// @inheritdoc ILPBorrowManager
    uint256 public override borrowLtvBps;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @dev Cumulative interest index (PRECISION-scaled, starts at PRECISION).
    uint256 internal _index;
    uint256 internal _totalScaledDebt;
    uint256 internal _lastAccrual;

    mapping(address => Position) internal _positions;
    mapping(address => uint256) internal _lpStablecoin;
    mapping(uint256 => OrderRef) internal _orderRefs;

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    constructor(
        address vault_,
        address stablecoin_,
        address debtToken_,
        address aavePool_,
        address market_,
        address registry_,
        address coordinator_,
        bytes32 collateralAsset_,
        InterestRateModel.Params memory rateParams_
    ) {
        if (
            vault_ == address(0) || stablecoin_ == address(0) || debtToken_ == address(0) || aavePool_ == address(0)
                || market_ == address(0) || registry_ == address(0) || coordinator_ == address(0)
        ) revert ZeroAddress();
        if (collateralAsset_ == bytes32(0)) revert ZeroAmount();

        vault = vault_;
        stablecoin = stablecoin_;
        debtToken = debtToken_;
        aavePool = aavePool_;
        market = market_;
        registry = IProtocolRegistry(registry_);
        coordinator = IVaultBorrowCoordinator(coordinator_);
        collateralAsset = collateralAsset_;
        _stableDecimals = IERC20Metadata(stablecoin_).decimals();

        _rateParams = rateParams_;

        // Sensible defaults; admin can tune.
        liquidationThresholdBps = 8000; // 80%
        liquidationBonusBps = 500; // 5%
        borrowLtvBps = 7000; // 70%

        // Pre-approve Aave to pull stablecoin on repay.
        IERC20(stablecoin_).forceApprove(aavePool_, type(uint256).max);
        // Pre-approve OwnMarket to pull stablecoin when placing mint orders.
        IERC20(stablecoin_).forceApprove(market_, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Borrower flows
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILPBorrowManager
    function borrow(
        uint256 sharesAmount,
        uint256 stablecoinAmount,
        bytes calldata priceData
    ) external payable nonReentrant {
        if (sharesAmount == 0 || stablecoinAmount == 0) revert ZeroAmount();

        // Verify wstETH price proof and value the LP's pledged shares.
        uint256 wstETHPriceUSD = _verifyPrice(priceData);
        uint256 awstETHAmount = IOwnVault(vault).convertToAssets(sharesAmount);
        uint256 collateralValueUSD = awstETHAmount.mulDiv(wstETHPriceUSD, PRECISION);

        Position storage p = _positions[msg.sender];

        // LTV check at borrow time — apply against the *combined* collateral
        // and debt after this top-up, so partial top-ups can't exceed LTV.
        _accrue();
        uint256 currentDebt = p.principal == 0 ? 0 : p.principal.mulDiv(_index, PRECISION);
        uint256 newDebtUSD = _stableToUSD(currentDebt + stablecoinAmount);
        uint256 totalCollateralUSD = collateralValueUSD;
        if (p.sharesHeld > 0) {
            uint256 existingAwstETH = IOwnVault(vault).convertToAssets(p.sharesHeld);
            totalCollateralUSD += existingAwstETH.mulDiv(wstETHPriceUSD, PRECISION);
        }
        uint256 maxBorrowUSD = totalCollateralUSD.mulDiv(borrowLtvBps, BPS);
        if (newDebtUSD > maxBorrowUSD) revert InsufficientCollateral(newDebtUSD, maxBorrowUSD);

        // Coordinator-level hard cap, denominated in USD added to protocol-wide debt.
        coordinator.preBorrowCheck(_stableToUSD(stablecoinAmount));

        // Pull shares into custody.
        IERC20(vault).safeTransferFrom(msg.sender, address(this), sharesAmount);

        // Borrow stablecoin from Aave on the vault's behalf.
        IAaveV3Pool(aavePool).borrow(stablecoin, stablecoinAmount, AAVE_VARIABLE_RATE_MODE, 0, vault);

        // Record/update position.
        uint256 idx = _index;
        uint256 scaledNew = stablecoinAmount.mulDiv(PRECISION, idx);
        if (p.principal == 0) {
            _positions[msg.sender] = Position({sharesHeld: sharesAmount, principal: scaledNew, interestIndex: idx});
        } else {
            // Settle existing scaled principal to the current index, then add.
            uint256 scaledPrev = p.principal.mulDiv(p.interestIndex, idx);
            p.sharesHeld += sharesAmount;
            p.principal = scaledPrev + scaledNew;
            p.interestIndex = idx;
        }
        _totalScaledDebt += scaledNew;

        _lpStablecoin[msg.sender] += stablecoinAmount;

        emit Borrowed(msg.sender, sharesAmount, stablecoinAmount, collateralValueUSD);
    }

    /// @inheritdoc ILPBorrowManager
    function repay(
        uint256 amount
    ) external nonReentrant returns (uint256 sharesReleased) {
        Position storage p = _positions[msg.sender];
        if (p.principal == 0) revert NoPosition(msg.sender);

        _accrue();
        uint256 idx = _index;
        uint256 currentDebt = p.principal.mulDiv(idx, PRECISION);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        if (repayAmount == 0) revert ZeroAmount();

        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), repayAmount);
        _repayAaveAndSweep(repayAmount);

        if (repayAmount == currentDebt) {
            sharesReleased = p.sharesHeld;
            _totalScaledDebt -= p.principal;
            delete _positions[msg.sender];
        } else {
            sharesReleased = p.sharesHeld.mulDiv(repayAmount, currentDebt);
            uint256 scaledRepay = repayAmount.mulDiv(PRECISION, idx);
            if (scaledRepay > p.principal) scaledRepay = p.principal;
            p.principal -= scaledRepay;
            p.sharesHeld -= sharesReleased;
            p.interestIndex = idx;
            _totalScaledDebt -= scaledRepay;
        }

        if (sharesReleased > 0) {
            // Pass-through redirect on the vault routes accrued LP fees back to the LP.
            IERC20(vault).safeTransfer(msg.sender, sharesReleased);
        }

        emit Repaid(msg.sender, repayAmount, sharesReleased, _positions[msg.sender].principal);
    }

    /// @inheritdoc ILPBorrowManager
    function withdrawBorrowed(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = _lpStablecoin[msg.sender];
        if (bal < amount) revert InsufficientStablecoinBalance(amount, bal);
        _lpStablecoin[msg.sender] = bal - amount;
        IERC20(stablecoin).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc ILPBorrowManager
    function placeMintOrder(
        bytes32 asset,
        uint256 stablecoinAmount,
        uint256 maxPrice,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (stablecoinAmount == 0) revert ZeroAmount();
        uint256 bal = _lpStablecoin[msg.sender];
        if (bal < stablecoinAmount) revert InsufficientStablecoinBalance(stablecoinAmount, bal);

        _lpStablecoin[msg.sender] = bal - stablecoinAmount;

        // OwnMarket pulls the stablecoin from this manager (it is the caller).
        orderId = IOwnMarket(market).placeMintOrder(vault, asset, stablecoinAmount, maxPrice, expiry);

        _orderRefs[orderId] = OrderRef({lp: msg.sender, asset: asset, claimed: false});

        emit MintOrderPlaced(msg.sender, orderId, asset, stablecoinAmount);
    }

    /// @inheritdoc ILPBorrowManager
    function claimMintedETokens(
        uint256 orderId
    ) external nonReentrant {
        OrderRef storage ref = _orderRefs[orderId];
        if (ref.lp == address(0)) revert OrderNotForLP(orderId);
        if (ref.claimed) revert OrderAlreadyClaimed(orderId);

        Order memory ord = IOwnMarket(market).getOrder(orderId);
        if (ord.status != OrderStatus.Confirmed) revert OrderNotConfirmed(orderId);

        // Recompute the minted amount the same way OwnMarket does, so we can
        // transfer exactly what was minted for THIS order without depending on
        // a per-order minted-amount slot.
        uint256 mintedAmount = _computeMintedAmount(ord);

        ref.claimed = true;

        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(ord.asset);
        if (mintedAmount > 0) IERC20(eToken).safeTransfer(ref.lp, mintedAmount);

        emit MintedETokensClaimed(ref.lp, orderId, eToken, mintedAmount);
    }

    /// @inheritdoc ILPBorrowManager
    function liquidate(address lp, bytes calldata priceData) external payable nonReentrant {
        Position storage p = _positions[lp];
        if (p.principal == 0) revert NoPosition(lp);

        _accrue();
        uint256 idx = _index;
        uint256 wstETHPriceUSD = _verifyPrice(priceData);
        _liquidate(lp, idx, wstETHPriceUSD);
    }

    function _liquidate(address lp, uint256 idx, uint256 wstETHPriceUSD) internal {
        Position storage p = _positions[lp];
        uint256 currentDebt = p.principal.mulDiv(idx, PRECISION);

        uint256 awstETHHeld = IOwnVault(vault).convertToAssets(p.sharesHeld);
        uint256 collateralUSD = awstETHHeld.mulDiv(wstETHPriceUSD, PRECISION);
        uint256 hf = _healthFactor(collateralUSD, currentDebt);
        if (hf >= PRECISION) revert NotLiquidatable(hf);

        // Liquidator pays full debt; manager forwards to Aave.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), currentDebt);
        _repayAaveAndSweep(currentDebt);

        // Compute target seize in shares: targetUSD / pricePerShareUSD.
        uint256 targetSeizeUSD = _stableToUSD(currentDebt).mulDiv(BPS + liquidationBonusBps, BPS);
        uint256 targetAwstETH = targetSeizeUSD.mulDiv(PRECISION, wstETHPriceUSD);
        uint256 targetShares = IOwnVault(vault).convertToShares(targetAwstETH);
        uint256 sharesSeized = targetShares > p.sharesHeld ? p.sharesHeld : targetShares;
        uint256 residualShares = p.sharesHeld - sharesSeized;

        _totalScaledDebt -= p.principal;
        delete _positions[lp];

        if (sharesSeized > 0) IERC20(vault).safeTransfer(msg.sender, sharesSeized);
        if (residualShares > 0) IERC20(vault).safeTransfer(lp, residualShares);

        emit Liquidated(lp, msg.sender, currentDebt, sharesSeized, residualShares);
    }

    // ──────────────────────────────────────────────────────────
    //  IBorrowDebt
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowDebt
    function totalDebtUSD() external view returns (uint256) {
        if (_totalScaledDebt == 0) return 0;
        uint256 idx = _projectedIndex();
        uint256 totalStable = _totalScaledDebt.mulDiv(idx, PRECISION);
        return _stableToUSD(totalStable);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILPBorrowManager
    function rateParams()
        external
        view
        returns (uint64 basePremiumBps, uint64 optimalUtilBps, uint64 slope1Bps, uint64 slope2Bps)
    {
        InterestRateModel.Params memory p = _rateParams;
        return (p.basePremiumBps, p.optimalUtilBps, p.slope1Bps, p.slope2Bps);
    }

    /// @inheritdoc ILPBorrowManager
    function positionOf(
        address lp
    ) external view returns (Position memory) {
        return _positions[lp];
    }

    /// @inheritdoc ILPBorrowManager
    function debtOf(
        address lp
    ) external view returns (uint256) {
        Position memory p = _positions[lp];
        if (p.principal == 0) return 0;
        return p.principal.mulDiv(_projectedIndex(), PRECISION);
    }

    /// @inheritdoc ILPBorrowManager
    function lpStablecoinBalance(
        address lp
    ) external view returns (uint256) {
        return _lpStablecoin[lp];
    }

    /// @inheritdoc ILPBorrowManager
    function orderRef(
        uint256 orderId
    ) external view returns (OrderRef memory) {
        return _orderRefs[orderId];
    }

    /// @inheritdoc ILPBorrowManager
    function healthFactor(address lp, uint256 wstETHPriceUSD) external view returns (uint256) {
        Position memory p = _positions[lp];
        if (p.principal == 0) return type(uint256).max;
        uint256 idx = _projectedIndex();
        uint256 currentDebt = p.principal.mulDiv(idx, PRECISION);
        uint256 awstETHHeld = IOwnVault(vault).convertToAssets(p.sharesHeld);
        uint256 collateralUSD = awstETHHeld.mulDiv(wstETHPriceUSD, PRECISION);
        return _healthFactor(collateralUSD, currentDebt);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILPBorrowManager
    function setRateParams(
        InterestRateModel.Params calldata params
    ) external onlyAdmin {
        _rateParams = params;
        emit RateParamsUpdated(params);
    }

    /// @inheritdoc ILPBorrowManager
    function setLiquidationConfig(uint256 liquidationThresholdBps_, uint256 liquidationBonusBps_) external onlyAdmin {
        if (
            liquidationThresholdBps_ == 0 || liquidationThresholdBps_ > BPS || liquidationThresholdBps_ <= borrowLtvBps
                || liquidationBonusBps_ > BPS
        ) revert InvalidLiquidationConfig();
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        emit LiquidationConfigUpdated(liquidationThresholdBps_, liquidationBonusBps_);
    }

    function setBorrowLtvBps(
        uint256 ltvBps
    ) external onlyAdmin {
        if (ltvBps == 0 || ltvBps >= liquidationThresholdBps) revert InvalidLiquidationConfig();
        borrowLtvBps = ltvBps;
    }

    function setMinAaveBorrowRateBps(
        uint256 rateBps
    ) external onlyAdmin {
        minAaveBorrowRateBps = rateBps;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — accrual
    // ──────────────────────────────────────────────────────────

    function _accrue() internal {
        uint256 last = _lastAccrual;
        if (last == 0) {
            _index = PRECISION;
            _lastAccrual = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - last;
        if (dt == 0) return;
        if (_totalScaledDebt == 0) {
            _lastAccrual = block.timestamp;
            return;
        }
        uint256 rateBps = _currentRateBps();
        uint256 idx = _index;
        uint256 growth = idx.mulDiv(rateBps * dt, BPS * SECONDS_PER_YEAR);
        _index = idx + growth;
        _lastAccrual = block.timestamp;
    }

    function _projectedIndex() internal view returns (uint256) {
        uint256 idx = _index;
        if (idx == 0) return PRECISION;
        if (_totalScaledDebt == 0 || _lastAccrual == 0) return idx;
        uint256 dt = block.timestamp - _lastAccrual;
        if (dt == 0) return idx;
        return idx + idx.mulDiv(_currentRateBps() * dt, BPS * SECONDS_PER_YEAR);
    }

    function _currentRateBps() internal view returns (uint256) {
        uint256 utilBps = coordinator.utilizationBps();
        return _aaveRateWithFloor() + InterestRateModel.premium(utilBps, _rateParams);
    }

    function _aaveRateWithFloor() internal view returns (uint256) {
        uint256 live = coordinator.liveAaveRateBps();
        uint256 floor = minAaveBorrowRateBps;
        return live > floor ? live : floor;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Verify wstETH price proof for `collateralAsset` via the asset's
    ///      primary oracle. Returns the price in USD (18 dec).
    function _verifyPrice(
        bytes calldata priceData
    ) internal returns (uint256 price) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(collateralAsset);
        address oracleAddr = oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle();
        (price,) = IOracleVerifier(oracleAddr).verifyPrice{value: msg.value}(collateralAsset, priceData);
    }

    function _repayAaveAndSweep(
        uint256 amount
    ) internal {
        uint256 actualRepaid = IAaveV3Pool(aavePool).repay(stablecoin, amount, AAVE_VARIABLE_RATE_MODE, vault);
        uint256 surplus = amount > actualRepaid ? amount - actualRepaid : 0;
        if (surplus > 0) IERC20(stablecoin).safeTransfer(vault, surplus);
    }

    function _stableToUSD(
        uint256 amount
    ) internal view returns (uint256) {
        if (_stableDecimals == 18) return amount;
        if (_stableDecimals < 18) return amount * 10 ** (18 - _stableDecimals);
        return amount / 10 ** (_stableDecimals - 18);
    }

    function _healthFactor(uint256 collateralUSD, uint256 currentDebt) internal view returns (uint256) {
        if (currentDebt == 0) return type(uint256).max;
        uint256 adjusted = collateralUSD.mulDiv(liquidationThresholdBps, BPS);
        uint256 debtUSD = _stableToUSD(currentDebt);
        return adjusted.mulDiv(PRECISION, debtUSD);
    }

    /// @dev Reproduces OwnMarket's mint amount formula
    ///      `eTokenAmount = (order.amount - fee) * 1e(18-decimals) * PRECISION / order.price`
    ///      so the manager can transfer exactly the minted amount per order.
    function _computeMintedAmount(
        Order memory ord
    ) internal view returns (uint256) {
        uint256 feeBps = _mintFeeBps(ord.asset, ord.amount);
        uint256 feeAmount = ord.amount.mulDiv(feeBps, BPS, Math.Rounding.Ceil);
        uint256 netAmount = ord.amount - feeAmount;
        uint256 decimals = IERC20Metadata(stablecoin).decimals();
        uint256 decimalScaler = 10 ** (18 - decimals);
        return (netAmount * decimalScaler).mulDiv(PRECISION, ord.price);
    }

    /// @dev Mint fee BPS pulled from the FeeCalculator.
    function _mintFeeBps(bytes32 asset, uint256 amount) internal view returns (uint256) {
        address feeCalc = registry.feeCalculator();
        if (feeCalc == address(0)) return 0;
        // External call — kept tightly typed so the compiler still flags an
        // ABI mismatch rather than silently zeroing.
        (bool ok, bytes memory data) =
            feeCalc.staticcall(abi.encodeWithSignature("getMintFee(bytes32,uint256)", asset, amount));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
