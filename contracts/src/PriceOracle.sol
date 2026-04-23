// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

/// Reads a Chainlink aggregator and returns the price in 8-decimal fixed-point.
/// Reverts if the feed is stale or returns a non-positive answer.
library PriceOracle {
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);
    error InvalidPrice(int256 answer);
    error IncompleteRound();

    /// @param feed Chainlink aggregator address (e.g. BTC/USD, ETH/USD)
    /// @param maxStaleness Seconds beyond which the feed is considered stale
    /// @return price Price scaled to 1e8 regardless of the feed's reported decimals
    function read(AggregatorV3Interface feed, uint256 maxStaleness)
        internal
        view
        returns (uint256 price)
    {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (answeredInRound < roundId) revert IncompleteRound();
        if (block.timestamp > updatedAt + maxStaleness) {
            revert StalePrice(updatedAt, maxStaleness);
        }

        uint8 dec = feed.decimals();
        if (dec == 8) {
            price = uint256(answer);
        } else if (dec < 8) {
            price = uint256(answer) * (10 ** (8 - dec));
        } else {
            price = uint256(answer) / (10 ** (dec - 8));
        }
    }
}
