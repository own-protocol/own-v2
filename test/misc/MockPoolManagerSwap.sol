// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey, SwapParams} from "../../misc/interfaces/IPoolManagerSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUnlockCallback {
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory);
}

/// @title MockPoolManagerSwap — v4 flash accounting with a fixed-price swap
/// @notice Exact-input swaps fill `fillBps` of the input at `price1Per0` (currency1 per currency0,
///         1e18 fixed point, in raw token units). Deltas follow v4: negative is owed by the caller,
///         and every delta must be zero when `unlock` returns.
contract MockPoolManagerSwap {
    uint256 public price1Per0 = 1e18;
    uint256 public fillBps = 10_000;
    bool internal _unlocked;
    mapping(address => int256) internal _delta;
    address internal _synced;
    uint256 internal _syncedBalance;
    address[2] internal _currencies;

    function setPrice(
        uint256 p
    ) external {
        price1Per0 = p;
    }

    function setFillBps(
        uint256 f
    ) external {
        fillBps = f;
    }

    function unlock(
        bytes calldata data
    ) external returns (bytes memory result) {
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        _unlocked = false;
        require(_delta[_currencies[0]] == 0 && _delta[_currencies[1]] == 0, "unsettled");
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256) {
        require(_unlocked, "locked");
        require(params.amountSpecified < 0, "exact input only");
        _currencies = [key.currency0, key.currency1];
        uint256 amountIn = uint256(-params.amountSpecified) * fillBps / 10_000;
        uint256 amountOut = params.zeroForOne ? amountIn * price1Per0 / 1e18 : amountIn * 1e18 / price1Per0;
        int128 d0;
        int128 d1;
        if (params.zeroForOne) {
            d0 = -int128(int256(amountIn));
            d1 = int128(int256(amountOut));
        } else {
            d1 = -int128(int256(amountIn));
            d0 = int128(int256(amountOut));
        }
        _delta[key.currency0] += d0;
        _delta[key.currency1] += d1;
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    function sync(
        address currency
    ) external {
        _synced = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedBalance;
        _delta[_synced] += int256(paid);
    }

    function take(address currency, address to, uint256 amount) external {
        _delta[currency] -= int256(amount);
        IERC20(currency).transfer(to, amount);
    }

    /// @dev Calls a contract's unlock callback as the PoolManager, outside any trade.
    function callback(address target, bytes calldata data) external {
        IUnlockCallback(target).unlockCallback(data);
    }
}
