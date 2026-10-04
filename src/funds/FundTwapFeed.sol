// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundHook} from "../interfaces/IFundHook.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundTwapFeed — a fund token's pool TWAP behind a Chainlink aggregator surface
/// @notice Reads the time-weighted mean tick the hook records for the fund's USDG pool and quotes
///         one fund token in USD (18 decimals), counting USDG as $1. Register it in the
///         FundOracle under the fund's address; mint pricing and the staking premium then use it.
///         Nothing is pushed, so there is no keeper to trust: until the pool has `window` of
///         history the answer is 0, which the oracle treats as unavailable.
contract FundTwapFeed {
    /// @notice The hook recording the pool's tick accumulator.
    IFundHook public immutable hook;

    /// @notice The fund token priced.
    address public immutable fund;

    /// @notice Minimum averaging period, in seconds.
    uint32 public immutable window;

    bool private immutable _fundIsCurrency0;
    uint256 private immutable _baseAmount;
    uint256 private immutable _usdgUnit;

    /// @notice The window is zero or longer than the hook serves.
    error InvalidWindow();

    /// @notice The fund has no pool on the hook.
    error NotRegistered();

    /// @param hook_   The fund hook.
    /// @param fund_   The fund.
    /// @param window_ Minimum averaging period, in seconds.
    constructor(IFundHook hook_, address fund_, uint32 window_) {
        if (window_ == 0 || window_ > hook_.maxTwapWindow()) revert InvalidWindow();
        PoolKey memory key = hook_.poolKeyOf(fund_);
        if (address(key.hooks) == address(0)) revert NotRegistered();
        hook = hook_;
        fund = fund_;
        window = window_;
        _fundIsCurrency0 = Currency.unwrap(key.currency0) == fund_;
        address usdg = Currency.unwrap(_fundIsCurrency0 ? key.currency1 : key.currency0);
        // One fund token scaled by 1e18, so the raw USDG quote keeps 18 decimals of precision.
        _baseAmount = 10 ** (uint256(IERC20Metadata(fund_).decimals()) + 18);
        _usdgUnit = 10 ** uint256(IERC20Metadata(usdg).decimals());
    }

    /// @notice Aggregator surface: answers carry 18 decimals.
    /// @return 18.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Aggregator surface: feed description.
    /// @return The description.
    function description() external view returns (string memory) {
        return string.concat(IERC20Metadata(fund).symbol(), " / USD pool TWAP");
    }

    /// @notice Aggregator surface: the current TWAP.
    /// @return roundId         The block timestamp.
    /// @return answer          USD per fund token, 18 decimals (0 while unavailable).
    /// @return startedAt       Start of the measured period (0 while unavailable).
    /// @return updatedAt       The block timestamp (0 while unavailable).
    /// @return answeredInRound Same as `roundId`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (bool ok, int24 meanTick, uint32 period) = hook.consult(fund, window);
        if (!ok) return (0, 0, 0, 0, 0);
        roundId = uint80(block.timestamp);
        answer = int256(_quote(meanTick));
        startedAt = block.timestamp - period;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    function _quote(
        int24 tick
    ) private view returns (uint256) {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 rawUsdg;
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = sqrtPriceX96 * sqrtPriceX96;
            rawUsdg = _fundIsCurrency0
                ? Math.mulDiv(ratioX192, _baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, _baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            rawUsdg = _fundIsCurrency0
                ? Math.mulDiv(ratioX128, _baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, _baseAmount, ratioX128);
        }
        return rawUsdg / _usdgUnit;
    }
}
