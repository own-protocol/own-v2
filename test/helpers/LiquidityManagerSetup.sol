// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSD} from "../../src/eusd/EUSD.sol";
import {EUSDLiquidityManager} from "../../src/eusd/EUSDLiquidityManager.sol";
import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {PoolKey} from "../../src/interfaces/external/IFables.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {Actors} from "./Actors.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockEmissionStream, MockFablesLedger} from "./MockFables.sol";
import {MockOracleVerifier} from "./MockOracleVerifier.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Deploy an EUSDLiquidityManager behind an ERC-1967 proxy, initialized in the constructor.
function deployEUSDLiquidityManager(
    address registry_,
    address eusd_,
    IEUSDLiquidityManager.RiskParams memory params
) returns (EUSDLiquidityManager) {
    EUSDLiquidityManager implementation = new EUSDLiquidityManager();
    bytes memory initData = abi.encodeCall(EUSDLiquidityManager.initialize, (registry_, eusd_, params));
    return EUSDLiquidityManager(address(new ERC1967Proxy(address(implementation), initData)));
}

/// @title LiquidityManagerSetup — shared fixture for EUSDLiquidityManager tests
/// @notice A manager with two mock Fables pools: SPY/eUSD (18-decimal asset as currency0) and
///         eUSD/USDG (6-decimal asset as currency1), priced at 700 and 1 on both the oracle and
///         the pools.
contract LiquidityManagerSetup is Test {
    ProtocolRegistry internal registry;
    MockOracleVerifier internal oracle;
    EUSD internal eusd;
    EUSDLiquidityManager internal manager;
    MockFablesLedger internal ledger;
    MockEmissionStream internal stream;
    FablesAdapter internal adapterImpl;
    UpgradeableBeacon internal beacon;
    MockERC20 internal spy;
    MockERC20 internal usdg;
    PoolKey internal spyKey;
    PoolKey internal usdKey;

    address internal admin = Actors.ADMIN;
    address internal operator = address(uint160(uint256(keccak256("operator"))));
    address internal treasury = address(uint160(uint256(keccak256("treasury"))));
    address internal alice = Actors.MINTER1;
    address internal bob = Actors.MINTER2;
    address internal keeper = Actors.LIQUIDATOR;
    address internal attacker = Actors.ATTACKER;

    bytes32 internal constant SPY = bytes32("SPY");
    bytes32 internal constant USDG = bytes32("USDG");
    uint256 internal constant SPY_PRICE = 700e18;
    uint256 internal constant SPY_POOL = 0;
    uint256 internal constant USD_POOL = 1;

    uint16 internal constant MCR = 19_000;
    uint16 internal constant LIQ_THRESHOLD = 12_500;
    uint16 internal constant LIQ_BONUS = 500;
    uint16 internal constant STAKED_FEE = 700;
    uint16 internal constant UNSTAKED_FEE = 200;
    uint16 internal constant BAND = 250;
    uint256 internal constant CEILING = 10_000_000e18;
    uint256 internal constant MIN_DEBT = 100e18;
    uint256 internal constant PRICE_MAX_AGE = 1 days;
    uint16 internal constant REDEEM_SHARE = 7500;
    uint16 internal constant REDEEM_FEE = 50;

    function setUp() public virtual {
        vm.warp(1_000_000);
        registry = new ProtocolRegistry(admin, 2 days);
        oracle = new MockOracleVerifier();
        vm.startPrank(admin);
        registry.setOracle(address(oracle));
        registry.setTreasury(treasury);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), operator);
        vm.stopPrank();

        eusd = new EUSD(admin);
        // Pin the assets either side of eUSD so both pool orientations are covered.
        deployCodeTo("test/helpers/MockERC20.sol:MockERC20", abi.encode("SPY", "SPY", uint8(18)), address(0x1000));
        deployCodeTo(
            "test/helpers/MockERC20.sol:MockERC20",
            abi.encode("USDG", "USDG", uint8(6)),
            address(0xfFfffFFFfffFFfFFFFffFFFFffffFfFFFFff0000)
        );
        spy = MockERC20(address(0x1000));
        usdg = MockERC20(address(0xfFfffFFFfffFFfFFFFffFFFFffffFfFFFFff0000));

        ledger = new MockFablesLedger();
        stream = new MockEmissionStream();
        adapterImpl = new FablesAdapter(address(ledger), address(stream), address(0));
        beacon = new UpgradeableBeacon(address(adapterImpl), admin);

        spyKey = PoolKey({
            currency0: address(spy),
            currency1: address(eusd),
            fee: 0x800000,
            tickSpacing: 10,
            hooks: address(ledger)
        });
        usdKey = PoolKey({
            currency0: address(eusd),
            currency1: address(usdg),
            fee: 0x800000,
            tickSpacing: 1,
            hooks: address(ledger)
        });
        oracle.setPrice(SPY, SPY_PRICE);
        oracle.setPrice(USDG, 1e18);
        ledger.setPrice(spyKey, address(spy), SPY_PRICE);
        ledger.setPrice(usdKey, address(usdg), 1e18);

        manager = deployEUSDLiquidityManager(address(registry), address(eusd), defaultParams());
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(manager));
        manager.addPool(address(beacon), address(spy), SPY, abi.encode(spyKey));
        manager.addPool(address(beacon), address(usdg), USDG, abi.encode(usdKey));
        vm.stopPrank();

        // Reserves so the mock pool can pay withdrawals after price moves.
        spy.mint(address(ledger), 1_000_000e18);
        usdg.mint(address(ledger), 1_000_000_000e6);

        address[4] memory users = [alice, bob, keeper, attacker];
        for (uint256 i; i < users.length; i++) {
            spy.mint(users[i], 1_000_000e18);
            usdg.mint(users[i], 1_000_000_000e6);
            vm.startPrank(users[i]);
            spy.approve(address(manager), type(uint256).max);
            usdg.approve(address(manager), type(uint256).max);
            vm.stopPrank();
        }
    }

    function defaultParams() internal pure returns (IEUSDLiquidityManager.RiskParams memory) {
        return IEUSDLiquidityManager.RiskParams({
            mcrBps: MCR,
            liquidationThresholdBps: LIQ_THRESHOLD,
            liquidationBonusBps: LIQ_BONUS,
            stakedFeeBps: STAKED_FEE,
            unstakedFeeBps: UNSTAKED_FEE,
            poolPriceBandBps: BAND,
            redeemMinAssetShareBps: REDEEM_SHARE,
            redeemFeeBps: REDEEM_FEE,
            debtCeiling: CEILING,
            minDebt: MIN_DEBT,
            mintPriceMaxAge: PRICE_MAX_AGE
        });
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Tick at or below the pool tick of an asset price, floored to the spacing. Makes no
    ///      external call, so it can sit between `vm.prank`/`vm.expectRevert` and the call under test.
    function tickAt(uint256 price, uint256 scale, bool assetIsZero, int24 spacing) internal pure returns (int24) {
        uint256 target = LiquidityMath.sqrtPriceFromOracle(price, scale, assetIsZero);
        int24 lo = LiquidityMath.MIN_TICK;
        int24 hi = LiquidityMath.MAX_TICK;
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (LiquidityMath.getSqrtPriceAtTick(mid) <= target) lo = mid;
            else hi = mid;
        }
        int24 r = lo % spacing;
        if (r < 0) r += spacing;
        return lo - r;
    }

    /// @dev SPY range between two prices (SPY is currency0, so ticks follow prices).
    function spyRange(uint256 lowPrice, uint256 highPrice) internal pure returns (int24, int24) {
        return (tickAt(lowPrice, 1e18, true, 10), tickAt(highPrice, 1e18, true, 10));
    }

    /// @dev USDG range between two prices (USDG is currency1, so a higher price is a lower tick).
    function usdRange(uint256 lowPrice, uint256 highPrice) internal pure returns (int24, int24) {
        return (tickAt(highPrice, 1e6, false, 1), tickAt(lowPrice, 1e6, false, 1));
    }

    /// @dev Open a staked SPY position for `user`: deposit `assetIn`, put up to `assetIn` and `eusdMax` in ±15%.
    function openSpy(address user, uint256 assetIn, uint256 eusdMax) internal returns (uint128 liquidity) {
        return openSpy(user, assetIn, eusdMax, true);
    }

    /// @dev As {openSpy}, staked or not.
    function openSpy(
        address user,
        uint256 assetIn,
        uint256 eusdMax,
        bool staked
    ) internal returns (uint128 liquidity) {
        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        vm.prank(user);
        liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: SPY_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: assetIn,
                assetMax: assetIn,
                eusdMax: eusdMax,
                staked: staked
            })
        );
    }

    /// @dev Move both the oracle and the SPY pool to `price`.
    function moveSpy(
        uint256 price
    ) internal {
        oracle.setPrice(SPY, price);
        ledger.setPrice(spyKey, address(spy), price);
    }

    /// @dev Give `to` eUSD by minting as a temporary minter (breaks supply == debt; unit tests only).
    function giveEusd(address to, uint256 amount) internal {
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), admin);
        eusd.mint(to, amount);
        eusd.revokeRole(eusd.MINTER_ROLE(), admin);
        vm.stopPrank();
    }
}
