// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMoneyPriceFeed} from "../interfaces/IMoneyPriceFeed.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";

/// @title MoneyPriceFeed — keeper-pushed $MONEY mark behind a Chainlink aggregator surface
/// @notice See {IMoneyPriceFeed}.
contract MoneyPriceFeed is IMoneyPriceFeed {
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @notice ProtocolRegistry used to resolve the ADMIN role.
    IProtocolRegistry public immutable registry;

    /// @inheritdoc IMoneyPriceFeed
    address public override keeper;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(address registry_, address keeper_) {
        if (registry_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IMoneyPriceFeed
    function pushPrice(
        uint256 price
    ) external override {
        if (msg.sender != keeper) revert OnlyKeeper();
        if (price == 0 || price > uint256(type(int256).max)) revert InvalidPrice();

        uint80 round = ++_roundId;
        _answer = int256(price);
        _updatedAt = block.timestamp;

        emit PricePushed(round, price);
    }

    /// @inheritdoc IMoneyPriceFeed
    function setKeeper(
        address keeper_
    ) external override {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IMoneyPriceFeed
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc IMoneyPriceFeed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
