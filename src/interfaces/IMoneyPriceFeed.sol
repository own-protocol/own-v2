// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMoneyPriceFeed — keeper-pushed $MONEY price mark behind a Chainlink aggregator surface
/// @notice Chainlink publishes no $MONEY feed, so this adapter serves a keeper-pushed TWAP mark
///         (18 decimals, window managed off-chain by the keeper service) through the AggregatorV3
///         read surface the ChainlinkOracleVerifier consumes. Register it as the MONEY aggregator
///         with `bandBps = 0` (no in-house signer leg); the verifier's `maxAnchorAge` enforces
///         staleness, and OwnStakingV2 additionally degrades to its cached mark — the feed gates
///         boost weight only, never funds.
interface IMoneyPriceFeed {
    /// @notice A new mark was pushed.
    event PricePushed(uint80 indexed roundId, uint256 price);
    /// @notice The keeper address was set (constructor or admin rotation).
    event KeeperSet(address indexed keeper);

    /// @notice Caller does not hold the ADMIN role on the registry.
    error OnlyAdmin();
    /// @notice Caller is not the keeper.
    error OnlyKeeper();
    /// @notice Price is zero or does not fit int256.
    error InvalidPrice();
    /// @notice Zero address supplied.
    error ZeroAddress();

    /// @notice Push a fresh $MONEY mark (18-decimal USD). Keeper only.
    /// @dev Stamps `block.timestamp` and advances the round id.
    function pushPrice(
        uint256 price
    ) external;

    /// @notice Rotate the keeper address. ADMIN only.
    function setKeeper(
        address keeper_
    ) external;

    /// @notice The address allowed to push marks.
    function keeper() external view returns (address);

    /// @notice Aggregator surface: always 18 (marks are pushed at protocol precision).
    function decimals() external view returns (uint8);

    /// @notice Aggregator surface: the latest pushed mark.
    /// @return roundId Monotonic push counter (0 = never pushed).
    /// @return answer The mark, 18-decimal USD.
    /// @return startedAt Same as `updatedAt`.
    /// @return updatedAt Push timestamp (0 = never pushed; the verifier treats the round as invalid).
    /// @return answeredInRound Same as `roundId`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
