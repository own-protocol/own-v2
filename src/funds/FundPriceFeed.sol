// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundPriceHub} from "../interfaces/IFundPriceHub.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title FundPriceFeed — one asset's FundPriceHub price behind a Chainlink aggregator surface
/// @notice Deployed by the hub ({IFundPriceHub-createFeed}) and registered in the FundOracle with
///         its own staleness bound. Answers 0 until the first push, which the oracle treats as
///         unavailable.
contract FundPriceFeed {
    /// @notice The hub holding the price.
    IFundPriceHub public immutable hub;

    /// @notice The asset priced.
    address public immutable asset;

    /// @param asset_ The asset priced; the deployer is the hub.
    constructor(
        address asset_
    ) {
        hub = IFundPriceHub(msg.sender);
        asset = asset_;
    }

    /// @notice Aggregator surface: answers carry 18 decimals.
    /// @return 18.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Aggregator surface: feed description.
    /// @return The description.
    function description() external view returns (string memory) {
        return string.concat(IERC20Metadata(asset).symbol(), " / USD (Own push)");
    }

    /// @notice Aggregator surface: the latest pushed price.
    /// @return roundId         The push timestamp.
    /// @return answer          USD per whole token, 18 decimals (0 before the first push).
    /// @return startedAt       The push timestamp.
    /// @return updatedAt       The push timestamp.
    /// @return answeredInRound Same as `roundId`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 price, uint256 at) = hub.priceOf(asset);
        roundId = uint80(at);
        answer = int256(price);
        startedAt = at;
        updatedAt = at;
        answeredInRound = roundId;
    }
}
