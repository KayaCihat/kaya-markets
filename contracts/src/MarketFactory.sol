// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

import {BinaryPriceMarket} from "./BinaryPriceMarket.sol";

/// Deploys `BinaryPriceMarket` instances with a single shared collateral token.
/// - Owner curates an allowlist of Chainlink feeds (so random feeds can't be used).
/// - `createMarket` deploys the market and auto-seeds `requiredSubsidy()` from the
///   caller in the same tx, so every market is funded before it can trade.
contract MarketFactory is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;

    mapping(address feed => bool) public isFeedApproved;
    BinaryPriceMarket[] public markets;

    event FeedApproved(address indexed feed);
    event FeedRevoked(address indexed feed);
    event MarketCreated(
        address indexed market,
        address indexed feed,
        uint256 strike,
        uint256 expiry,
        uint256 bCollateral,
        uint256 subsidy,
        string question
    );

    error FeedNotApproved(address feed);

    constructor(IERC20 _collateral, address _owner) Ownable(_owner) {
        require(address(_collateral) != address(0), "collateral=0");
        collateral = _collateral;
    }

    // ─── Feed allowlist ────────────────────────────────────────────────

    function approveFeed(address feed) external onlyOwner {
        require(feed != address(0), "feed=0");
        isFeedApproved[feed] = true;
        emit FeedApproved(feed);
    }

    function revokeFeed(address feed) external onlyOwner {
        isFeedApproved[feed] = false;
        emit FeedRevoked(feed);
    }

    // ─── Market creation ───────────────────────────────────────────────

    /// Deploy a new binary market and seed it with `requiredSubsidy()` collateral
    /// pulled from `msg.sender`. Caller must approve this factory for that amount.
    function createMarket(
        AggregatorV3Interface feed,
        uint256 strike,
        uint256 expiry,
        uint256 maxStaleness,
        uint256 bCollateral,
        string calldata question
    ) external returns (BinaryPriceMarket market, uint256 subsidy) {
        if (!isFeedApproved[address(feed)]) revert FeedNotApproved(address(feed));

        market = new BinaryPriceMarket(
            BinaryPriceMarket.Params({
                collateral: collateral,
                priceFeed: feed,
                strike: strike,
                expiry: expiry,
                maxStaleness: maxStaleness,
                bCollateral: bCollateral,
                question: question
            })
        );

        subsidy = market.requiredSubsidy();
        collateral.safeTransferFrom(msg.sender, address(market), subsidy);

        markets.push(market);
        emit MarketCreated(
            address(market),
            address(feed),
            strike,
            expiry,
            bCollateral,
            subsidy,
            question
        );
    }

    // ─── Views ─────────────────────────────────────────────────────────

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function allMarkets() external view returns (BinaryPriceMarket[] memory) {
        return markets;
    }
}
