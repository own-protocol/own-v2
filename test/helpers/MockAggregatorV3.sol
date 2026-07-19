// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockAggregatorV3 — Configurable Chainlink aggregator proxy for tests
contract MockAggregatorV3 {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(
        uint8 decimals_
    ) {
        decimals = decimals_;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

/// @title MockScaledUiToken — ERC-8056 uiMultiplier stub for tests
contract MockScaledUiToken {
    uint256 public uiMultiplier = 1e18;

    function setUiMultiplier(
        uint256 mult
    ) external {
        uiMultiplier = mult;
    }
}
