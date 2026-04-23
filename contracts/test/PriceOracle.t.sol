// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

/// External wrapper so `vm.expectRevert` can catch the library's internal reverts.
contract PriceReader {
    function read(AggregatorV3Interface feed, uint256 maxStaleness) external view returns (uint256) {
        return PriceOracle.read(feed, maxStaleness);
    }
}

contract PriceOracleTest is Test {
    using PriceOracle for AggregatorV3Interface;

    AggregatorV3Interface feed8;
    AggregatorV3Interface feed18;
    PriceReader reader;

    function setUp() public {
        feed8 = AggregatorV3Interface(address(new MockAggregator(8, 3_500_00000000))); // $3500
        feed18 = AggregatorV3Interface(address(new MockAggregator(18, int256(3500 ether))));
        reader = new PriceReader();
    }

    function test_Read8DecimalFeed() public view {
        assertEq(feed8.read(1 hours), 3_500_00000000);
    }

    function test_Read18DecimalFeedScalesDown() public view {
        // 3500 ether = 3500e18, expected 3500e8
        assertEq(feed18.read(1 hours), 3_500_00000000);
    }

    function test_RevertWhen_Stale() public {
        vm.warp(block.timestamp + 3 hours);
        uint256 staleAt = block.timestamp - 2 hours;
        MockAggregator(address(feed8)).set(3_500_00000000, staleAt);
        vm.expectRevert(
            abi.encodeWithSelector(PriceOracle.StalePrice.selector, staleAt, uint256(1 hours))
        );
        reader.read(feed8, 1 hours);
    }

    function test_RevertWhen_NegativeAnswer() public {
        MockAggregator(address(feed8)).set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPrice.selector, int256(-1)));
        reader.read(feed8, 1 hours);
    }

    function test_RevertWhen_ZeroAnswer() public {
        MockAggregator(address(feed8)).set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPrice.selector, int256(0)));
        reader.read(feed8, 1 hours);
    }
}
