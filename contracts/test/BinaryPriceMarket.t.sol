// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

import {BinaryPriceMarket} from "../src/BinaryPriceMarket.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BinaryPriceMarketTest is Test {
    BinaryPriceMarket market;
    MockERC20 usdc;
    MockAggregator feed;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant STRIKE = 3_500_00000000; // $3500, 8-dec
    uint256 constant EXPIRY_DELAY = 7 days;
    uint256 constant B_COLLATERAL = 500e6; // $500 in USDC (6-dec)

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new MockAggregator(8, 3_000_00000000); // start at $3000 (YES looks unlikely)

        market = new BinaryPriceMarket(
            BinaryPriceMarket.Params({
                collateral: IERC20(address(usdc)),
                priceFeed: AggregatorV3Interface(address(feed)),
                strike: STRIKE,
                expiry: block.timestamp + EXPIRY_DELAY,
                maxStaleness: 24 hours,
                bCollateral: B_COLLATERAL,
                question: "ETH above $3,500 at expiry"
            })
        );

        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
    }

    function test_InitialProbabilityIsHalf() public view {
        assertEq(market.probYes(), 5e17);
    }

    function test_QuoteIsZeroForZeroShares() public view {
        assertEq(market.quote(true, 0), 0);
        assertEq(market.quote(false, 0), 0);
    }

    function test_BuyYesIncreasesProbability() public {
        uint256 p0 = market.probYes();
        vm.prank(alice);
        market.buy(true, 100 ether, type(uint256).max);
        uint256 p1 = market.probYes();
        assertGt(p1, p0);
    }

    function test_BuyTransfersCostFromUser() public {
        uint256 quoted = market.quote(true, 100 ether);
        assertGt(quoted, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 actual = market.buy(true, 100 ether, type(uint256).max);

        assertEq(actual, quoted);
        assertEq(usdc.balanceOf(alice), aliceBefore - quoted);
        assertEq(usdc.balanceOf(address(market)), quoted);
        assertEq(market.yesShares(alice), 100 ether);
    }

    function test_SlippageProtection() public {
        uint256 quoted = market.quote(true, 100 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BinaryPriceMarket.SlippageExceeded.selector,
                quoted,
                quoted - 1
            )
        );
        market.buy(true, 100 ether, quoted - 1);
    }

    function test_CannotBuyAfterExpiry() public {
        vm.warp(block.timestamp + EXPIRY_DELAY);
        vm.prank(alice);
        vm.expectRevert(BinaryPriceMarket.NotOpen.selector);
        market.buy(true, 100 ether, type(uint256).max);
    }

    function test_CannotResolveBeforeExpiry() public {
        vm.expectRevert(BinaryPriceMarket.NotYetExpired.selector);
        market.resolve();
    }

    function test_ResolveYesWhenPriceAboveStrike() public {
        vm.prank(alice);
        market.buy(true, 100 ether, type(uint256).max);

        vm.warp(block.timestamp + EXPIRY_DELAY);
        feed.set(3_700_00000000, block.timestamp); // $3700 > $3500
        market.resolve();

        assertEq(uint8(market.phase()), uint8(BinaryPriceMarket.Phase.Resolved));
        assertEq(uint8(market.outcome()), uint8(BinaryPriceMarket.Outcome.YES));
        assertEq(market.settlementPrice(), 3_700_00000000);
    }

    function test_ResolveNoWhenPriceBelowStrike() public {
        vm.warp(block.timestamp + EXPIRY_DELAY);
        feed.set(3_200_00000000, block.timestamp); // $3200 < $3500
        market.resolve();
        assertEq(uint8(market.outcome()), uint8(BinaryPriceMarket.Outcome.NO));
    }

    function test_CannotResolveTwice() public {
        vm.warp(block.timestamp + EXPIRY_DELAY);
        feed.set(3_700_00000000, block.timestamp);
        market.resolve();
        vm.expectRevert(BinaryPriceMarket.AlreadyResolved.selector);
        market.resolve();
    }

    function test_CannotRedeemBeforeResolved() public {
        vm.prank(alice);
        market.buy(true, 100 ether, type(uint256).max);
        vm.expectRevert(BinaryPriceMarket.NotResolved.selector);
        vm.prank(alice);
        market.redeem();
    }

    function test_WinnerRedeemsPayout() public {
        // Seed subsidy so the market can cover payout in edge case.
        uint256 subsidy = 1000e6;
        usdc.mint(address(market), subsidy);

        vm.prank(alice);
        market.buy(true, 100 ether, type(uint256).max);

        vm.warp(block.timestamp + EXPIRY_DELAY);
        feed.set(3_700_00000000, block.timestamp);
        market.resolve();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = market.redeem();

        // 100 WAD shares @ 1 USDC each = 100 * 1e6
        assertEq(paid, 100e6);
        assertEq(usdc.balanceOf(alice), before + 100e6);
        assertEq(market.yesShares(alice), 0);
    }

    function test_LoserGetsNothing() public {
        usdc.mint(address(market), 1000e6);

        vm.prank(alice);
        market.buy(true, 100 ether, type(uint256).max);
        vm.prank(bob);
        market.buy(false, 50 ether, type(uint256).max);

        vm.warp(block.timestamp + EXPIRY_DELAY);
        feed.set(3_700_00000000, block.timestamp); // YES wins
        market.resolve();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.redeem();
        assertEq(usdc.balanceOf(alice), aliceBefore + 100e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = market.redeem();
        assertEq(paid, 0);
        assertEq(usdc.balanceOf(bob), bobBefore);
    }

    /// House loss is bounded by b * ln(2) ≈ $346.57
    function test_HouseNetLossBoundedAfterResolution() public {
        // Fund subsidy up front
        uint256 subsidy = 400e6;
        usdc.mint(address(market), subsidy);

        // Alice buys 50k shares YES (extreme imbalance). Needs ~$49.65k collateral.
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        market.buy(true, 50_000 ether, type(uint256).max);

        vm.warp(block.timestamp + EXPIRY_DELAY);
        feed.set(3_700_00000000, block.timestamp);
        market.resolve();

        vm.prank(alice);
        market.redeem();

        // Remaining market balance should be > subsidy - b*ln(2) which is
        // roughly 400 - 346.57 = 53.43 USDC worth of dust.
        uint256 remaining = usdc.balanceOf(address(market));
        assertGt(remaining, 50e6);   // at least $50 left
        assertLt(remaining, 55e6);   // less than $55 left (not $400)
    }
}
