// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHookrDirectionalTax, IHookrLauncher} from "../../src/interfaces/external/IHookr.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice One direction's tax queue: pays whatever USDG it holds to the recipient. Tests fund it to
///         stand in for the tax a Hookr pool books on swaps.
contract MockTaxQueue {
    using SafeERC20 for IERC20;

    IERC20 public immutable quote;
    address public immutable recipient;

    error NothingDue();

    constructor(IERC20 quote_, address recipient_) {
        quote = quote_;
        recipient = recipient_;
    }

    function payCreator() external returns (uint256 amount) {
        amount = quote.balanceOf(address(this));
        if (amount == 0) revert NothingDue();
        quote.safeTransfer(recipient, amount);
    }
}

/// @title MockHookr — Hookr's launcher and Directional Tax as a fund venue uses them, on a real v4
///        PoolManager
/// @notice Pools are hookless with the LP fee as their static fee, so swaps pay no tax here; the tax
///         queues are deployed and bound as Hookr does, and tests fund them directly. The family
///         owner's position is held by this contract, keyed by family.
contract MockHookr is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    struct Family {
        address owner;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    IPoolManager public immutable pm;
    uint256 public nonce;
    uint256 public launchFee;
    mapping(bytes32 => Family) internal _families;
    mapping(PoolId => IHookrDirectionalTax.Terms) internal _terms;

    error NotOwner();
    error InvalidFunding();

    constructor(
        IPoolManager pm_
    ) {
        pm = pm_;
    }

    function setLaunchFee(
        uint256 fee
    ) external {
        launchFee = fee;
    }

    function poolManager() external view returns (address) {
        return address(pm);
    }

    function launchAdvised(
        IHookrLauncher.Token calldata token,
        address,
        IHookrLauncher.Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        uint256
    ) external payable returns (bytes32 familyId, address subject) {
        if (msg.value != launchFee) revert InvalidFunding();
        subject = token.existing;
        IHookrLauncher.Member calldata m = members[0];
        address quote = Currency.unwrap(m.quote);
        bool subjectFirst = subject < quote;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(subjectFirst ? subject : quote),
            currency1: Currency.wrap(subjectFirst ? quote : subject),
            fee: m.config.baseLpFeePips,
            tickSpacing: m.tickSpacing,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, m.sqrtPriceX96);
        familyId = keccak256(abi.encode(address(this), ++nonce));
        _families[familyId] = Family(msg.sender, key, m.tickLower, m.tickUpper, 0);
        IHookrDirectionalTax.Config memory c = abi.decode(advisoryConfigs[0], (IHookrDirectionalTax.Config));
        _terms[key.toId()] = IHookrDirectionalTax.Terms({
            buyQueue: _queue(quote, c.buy),
            buyTaxPips: c.buy.taxPips,
            bound: true,
            tiered: false,
            decaying: false,
            sellQueue: _queue(quote, c.sell),
            sellTaxPips: c.sell.taxPips
        });
        _add(familyId, m.liquidity, m.amount0Max, m.amount1Max);
    }

    function withdraw(
        bytes32 familyId,
        uint8,
        uint128 liquidity,
        uint256,
        uint256,
        address recipient,
        uint256
    ) external returns (uint256 amount0, uint256 amount1) {
        Family storage f = _owned(familyId);
        f.liquidity -= liquidity;
        (amount0, amount1) =
            abi.decode(pm.unlock(abi.encode(familyId, -int256(uint256(liquidity)), recipient)), (uint256, uint256));
    }

    function addLiquidity(
        bytes32 familyId,
        uint8,
        uint128 liquidity,
        uint128 max0,
        uint128 max1,
        uint256
    ) external payable returns (uint256 amount0, uint256 amount1) {
        Family storage f = _owned(familyId);
        if (f.liquidity != 0) pm.unlock(abi.encode(familyId, int256(0), msg.sender));
        return _add(familyId, liquidity, max0, max1);
    }

    function position(bytes32 familyId, uint8) external view returns (IHookrLauncher.Position memory p) {
        Family storage f = _families[familyId];
        return IHookrLauncher.Position(f.key, f.tickLower, f.tickUpper, f.liquidity);
    }

    function familyOwner(
        bytes32 familyId
    ) external view returns (address) {
        return _families[familyId].owner;
    }

    function terms(address, PoolId id) external view returns (IHookrDirectionalTax.Terms memory) {
        return _terms[id];
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (bytes32 familyId, int256 delta, address recipient) = abi.decode(data, (bytes32, int256, address));
        Family storage f = _families[familyId];
        (BalanceDelta d,) = pm.modifyLiquidity(
            f.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: f.tickLower,
                tickUpper: f.tickUpper,
                liquidityDelta: delta,
                salt: familyId
            }),
            ""
        );
        return abi.encode(
            _resolve(f.key.currency0, d.amount0(), recipient), _resolve(f.key.currency1, d.amount1(), recipient)
        );
    }

    function _add(
        bytes32 familyId,
        uint128 liquidity,
        uint256 max0,
        uint256 max1
    ) internal returns (uint256 amount0, uint256 amount1) {
        Family storage f = _families[familyId];
        IERC20 t0 = IERC20(Currency.unwrap(f.key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(f.key.currency1));
        t0.safeTransferFrom(msg.sender, address(this), max0);
        t1.safeTransferFrom(msg.sender, address(this), max1);
        f.liquidity += liquidity;
        (amount0, amount1) =
            abi.decode(pm.unlock(abi.encode(familyId, int256(uint256(liquidity)), address(this))), (uint256, uint256));
        t0.safeTransfer(msg.sender, max0 - amount0);
        t1.safeTransfer(msg.sender, max1 - amount1);
    }

    /// @dev Pays a negative delta from this contract's balance, takes a positive one to `recipient`.
    function _resolve(Currency currency, int128 delta, address recipient) internal returns (uint256) {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            pm.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(pm), owed);
            pm.settle();
            return owed;
        }
        if (delta > 0) pm.take(currency, recipient, uint256(int256(delta)));
        return SafeCast.toUint256(int256(delta));
    }

    function _queue(address quote, IHookrDirectionalTax.Leg memory leg) internal returns (address) {
        if (leg.taxPips == 0) return address(0);
        return address(new MockTaxQueue(IERC20(quote), leg.assetRecipient));
    }

    function _owned(
        bytes32 familyId
    ) internal view returns (Family storage f) {
        f = _families[familyId];
        if (f.owner != msg.sender) revert NotOwner();
    }
}
