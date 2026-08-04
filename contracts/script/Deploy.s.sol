// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {BinaryPriceMarket} from "../src/BinaryPriceMarket.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// Deploys MockUSDC + MarketFactory + 5 BTC/ETH markets to Base Sepolia.
///
/// Prereqs (env):
///   PRIVATE_KEY           — deployer key with Base Sepolia ETH
///   BASE_SEPOLIA_RPC      — RPC URL (referenced via foundry.toml)
///   BASESCAN_API_KEY      — for --verify (optional)
///
/// Run:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url base_sepolia \
///     --broadcast --verify
contract Deploy is Script {
    // ─── Base Sepolia Chainlink feeds ──────────────────────────────────
    // Source: Chainlink reference-data-directory (feeds-ethereum-testnet-sepolia-base-1.json)
    address constant BTC_USD_FEED = 0x961AD289351459A45fC90884eF3AB0278ea95DDE;
    address constant ETH_USD_FEED = 0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3;
    // Heartbeat is 1200s (20 min). Give 2h of slack.
    uint256 constant MAX_STALENESS = 2 hours;

    // ─── Market params ─────────────────────────────────────────────────
    // LMSR depth per market: 500 USDC → max house loss ≈ 346.57 USDC each.
    uint256 constant B_COLLATERAL = 500e6;
    // Strikes in 8-decimal fixed point (Chainlink output).
    uint256 constant D8 = 1e8;

    // Initial MockUSDC mint to deployer (covers all 5 subsidies + headroom).
    uint256 constant DEPLOYER_MINT = 10_000e6;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // 1. MockUSDC (6-dec) so we don't need real testnet USDC.
        MockERC20 usdc = new MockERC20("Mock USD Coin", "mUSDC", 6);
        usdc.mint(deployer, DEPLOYER_MINT);
        console2.log("MockUSDC:", address(usdc));

        // 2. Factory.
        MarketFactory factory = new MarketFactory(IERC20(address(usdc)), deployer);
        console2.log("MarketFactory:", address(factory));

        // 3. Allowlist feeds.
        factory.approveFeed(BTC_USD_FEED);
        factory.approveFeed(ETH_USD_FEED);

        // 4. Approve factory to pull subsidy for all 5 markets.
        usdc.approve(address(factory), type(uint256).max);

        // 5. Create 5 markets.
        uint256 baseExpiry = block.timestamp + 14 days;

        _create(
            factory,
            AggregatorV3Interface(BTC_USD_FEED),
            100_000 * D8,
            baseExpiry,
            "BTC above $100,000 in 14 days"
        );
        _create(
            factory,
            AggregatorV3Interface(BTC_USD_FEED),
            120_000 * D8,
            baseExpiry + 14 days,
            "BTC above $120,000 in 28 days"
        );
        _create(
            factory,
            AggregatorV3Interface(ETH_USD_FEED),
            3_500 * D8,
            baseExpiry,
            "ETH above $3,500 in 14 days"
        );
        _create(
            factory,
            AggregatorV3Interface(ETH_USD_FEED),
            4_000 * D8,
            baseExpiry + 14 days,
            "ETH above $4,000 in 28 days"
        );
        _create(
            factory,
            AggregatorV3Interface(ETH_USD_FEED),
            5_000 * D8,
            baseExpiry + 30 days,
            "ETH above $5,000 in 44 days"
        );

        vm.stopBroadcast();

        console2.log("Markets created:", factory.marketCount());
        BinaryPriceMarket[] memory all = factory.allMarkets();
        for (uint256 i; i < all.length; i++) {
            console2.log("  market", i, address(all[i]));
        }
    }

    function _create(
        MarketFactory factory,
        AggregatorV3Interface feed,
        uint256 strike,
        uint256 expiry,
        string memory question
    ) internal returns (BinaryPriceMarket m) {
        (m, ) = factory.createMarket(
            feed,
            strike,
            expiry,
            MAX_STALENESS,
            B_COLLATERAL,
            question
        );
    }
}
