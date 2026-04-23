// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {BinaryPriceMarket} from "../src/BinaryPriceMarket.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MarketFactoryTest is Test {
    MarketFactory factory;
    MockERC20 usdc;
    MockAggregator feed;

    address owner = address(0x0001);
    address deployer = address(0xD);
    address alice = address(0xA11CE);

    uint256 constant STRIKE = 3_500_00000000;
    uint256 constant B_COLLATERAL = 500e6; // $500 in USDC (6-dec)

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new MockAggregator(8, 3_000_00000000);

        vm.prank(owner);
        factory = new MarketFactory(IERC20(address(usdc)), owner);

        // Deployer has funds + unlimited approval for factory
        usdc.mint(deployer, 100_000e6);
        vm.prank(deployer);
        usdc.approve(address(factory), type(uint256).max);
    }

    // ─── Ownership / allowlist ────────────────────────────────────────

    function test_OwnerIsSetInConstructor() public view {
        assertEq(factory.owner(), owner);
    }

    function test_ApproveFeedRequiresOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        factory.approveFeed(address(feed));
    }

    function test_ApproveFeedFlipsAllowlist() public {
        assertFalse(factory.isFeedApproved(address(feed)));
        vm.prank(owner);
        factory.approveFeed(address(feed));
        assertTrue(factory.isFeedApproved(address(feed)));
    }

    function test_RevokeFeed() public {
        vm.startPrank(owner);
        factory.approveFeed(address(feed));
        factory.revokeFeed(address(feed));
        vm.stopPrank();
        assertFalse(factory.isFeedApproved(address(feed)));
    }

    // ─── Market creation ──────────────────────────────────────────────

    function test_CreateMarketRevertsForUnapprovedFeed() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(MarketFactory.FeedNotApproved.selector, address(feed))
        );
        factory.createMarket(
            AggregatorV3Interface(address(feed)),
            STRIKE,
            block.timestamp + 7 days,
            24 hours,
            B_COLLATERAL,
            "ETH above $3,500"
        );
    }

    function test_CreateMarketDeploysAndSeeds() public {
        vm.prank(owner);
        factory.approveFeed(address(feed));

        uint256 deployerBefore = usdc.balanceOf(deployer);

        vm.prank(deployer);
        (BinaryPriceMarket market, uint256 subsidy) = factory.createMarket(
            AggregatorV3Interface(address(feed)),
            STRIKE,
            block.timestamp + 7 days,
            24 hours,
            B_COLLATERAL,
            "ETH above $3,500"
        );

        // b*ln(2) ≈ 346.57 USDC (6-dec). Factory should pull exactly that.
        assertEq(subsidy, market.requiredSubsidy());
        assertGt(subsidy, 340e6);
        assertLt(subsidy, 350e6);

        // Market holds the full subsidy.
        assertEq(usdc.balanceOf(address(market)), subsidy);
        // Deployer paid it.
        assertEq(usdc.balanceOf(deployer), deployerBefore - subsidy);

        // Market is configured with factory collateral + passed feed.
        assertEq(address(market.collateral()), address(usdc));
        assertEq(address(market.priceFeed()), address(feed));
        assertEq(market.strike(), STRIKE);
    }

    function test_CreateMarketEmitsEvent() public {
        vm.prank(owner);
        factory.approveFeed(address(feed));

        vm.prank(deployer);
        vm.recordLogs();
        factory.createMarket(
            AggregatorV3Interface(address(feed)),
            STRIKE,
            block.timestamp + 7 days,
            24 hours,
            B_COLLATERAL,
            "Q"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Last log from factory is MarketCreated.
        bytes32 sig = keccak256(
            "MarketCreated(address,address,uint256,uint256,uint256,uint256,string)"
        );
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_MarketCountAndAllMarkets() public {
        vm.prank(owner);
        factory.approveFeed(address(feed));

        vm.startPrank(deployer);
        factory.createMarket(
            AggregatorV3Interface(address(feed)),
            STRIKE,
            block.timestamp + 7 days,
            24 hours,
            B_COLLATERAL,
            "Q1"
        );
        factory.createMarket(
            AggregatorV3Interface(address(feed)),
            STRIKE + 1,
            block.timestamp + 14 days,
            24 hours,
            B_COLLATERAL,
            "Q2"
        );
        vm.stopPrank();

        assertEq(factory.marketCount(), 2);
        BinaryPriceMarket[] memory all = factory.allMarkets();
        assertEq(all.length, 2);
        assertTrue(address(all[0]) != address(all[1]));
    }

    function test_CreatedMarketCanBeTradedAndResolvedAndRedeemed() public {
        vm.prank(owner);
        factory.approveFeed(address(feed));

        vm.prank(deployer);
        (BinaryPriceMarket market, ) = factory.createMarket(
            AggregatorV3Interface(address(feed)),
            STRIKE,
            block.timestamp + 7 days,
            24 hours,
            B_COLLATERAL,
            "ETH above $3,500"
        );

        // Alice buys YES and wins.
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(alice);
        market.buy(true, 100 ether, type(uint256).max);

        vm.warp(block.timestamp + 7 days);
        feed.set(3_700_00000000, block.timestamp);
        market.resolve();

        uint256 beforeBal = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = market.redeem();
        assertEq(paid, 100e6);
        assertEq(usdc.balanceOf(alice), beforeBal + 100e6);
    }
}

