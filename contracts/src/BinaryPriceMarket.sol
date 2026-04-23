// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";
import {SD59x18} from "@prb/math/SD59x18.sol";

import {LMSRMath} from "./LMSRMath.sol";
import {PriceOracle} from "./PriceOracle.sol";

/// A single Chainlink-resolved binary prediction market.
///
/// Question: "Will the feed price be ≥ strike at expiry?"
/// Pricing:  LMSR AMM with fixed liquidity parameter `b`.
/// Resolution: anyone can call `resolve()` after expiry; reads Chainlink once,
///             sets outcome forever. No disputes, no human arbitration.
/// Redemption: winning side redeems 1:1 to collateral, losing side gets nothing.
///
/// House max loss is capped at `b * ln(2)` which must be funded before any
/// trades happen (factory handles this on deployment).
contract BinaryPriceMarket {
    using SafeERC20 for IERC20;

    // ─── Immutable config ──────────────────────────────────────────────

    IERC20 public immutable collateral;
    uint8 public immutable collateralDecimals;
    AggregatorV3Interface public immutable priceFeed;
    /// @dev Strike price in 8 decimals (matches PriceOracle's normalized output).
    uint256 public immutable strike;
    /// @dev Unix timestamp at which the market can be resolved.
    uint256 public immutable expiry;
    /// @dev Max age (seconds) accepted from the Chainlink feed at resolution.
    uint256 public immutable maxStaleness;
    /// @dev LMSR liquidity parameter `b` in WAD.
    SD59x18 public immutable bWad;
    /// @dev Human-readable question (e.g. "ETH above $3,500 at 2026-05-01 00:00 UTC").
    string public question;

    // ─── State ─────────────────────────────────────────────────────────

    enum Phase { Open, Resolved }
    enum Outcome { YES, NO }

    Phase public phase;
    Outcome public outcome;
    uint256 public settlementPrice;
    uint256 public resolvedAt;

    /// @dev Total outstanding YES and NO shares, in WAD.
    int256 internal qYesWad;
    int256 internal qNoWad;

    /// @dev Per-user share balances, in WAD (1 share = 1e18).
    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;

    // ─── Events ────────────────────────────────────────────────────────

    event Bought(
        address indexed buyer,
        bool isYes,
        uint256 sharesWad,
        uint256 costCollateral
    );
    event Resolved(Outcome outcome, uint256 settlementPrice, uint256 resolvedAt);
    event Redeemed(address indexed user, uint256 sharesWad, uint256 collateralPaid);

    // ─── Errors ────────────────────────────────────────────────────────

    error NotOpen();
    error NotResolved();
    error AlreadyResolved();
    error NotYetExpired();
    error SlippageExceeded(uint256 actualCost, uint256 maxCost);
    error ZeroShares();

    // ─── Construction ──────────────────────────────────────────────────

    struct Params {
        IERC20 collateral;
        AggregatorV3Interface priceFeed;
        uint256 strike;
        uint256 expiry;
        uint256 maxStaleness;
        uint256 bCollateral; // `b` denominated in collateral units (not WAD)
        string question;
    }

    constructor(Params memory p) {
        require(address(p.collateral) != address(0), "collateral=0");
        require(address(p.priceFeed) != address(0), "feed=0");
        require(p.expiry > block.timestamp, "expiry in past");
        require(p.strike > 0, "strike=0");
        require(p.bCollateral > 0, "b=0");

        collateral = p.collateral;
        collateralDecimals = IERC20Metadata(address(p.collateral)).decimals();
        priceFeed = p.priceFeed;
        strike = p.strike;
        expiry = p.expiry;
        maxStaleness = p.maxStaleness;
        question = p.question;

        // Convert b from collateral units to WAD
        bWad = SD59x18.wrap(int256(_toWad(p.bCollateral)));
        phase = Phase.Open;
    }

    // ─── Pricing (view) ────────────────────────────────────────────────

    /// @return costCollateral Cost to buy `sharesWad` of (YES if isYes else NO).
    function quote(bool isYes, uint256 sharesWad) public view returns (uint256 costCollateral) {
        if (sharesWad == 0) return 0;
        SD59x18 qY = SD59x18.wrap(qYesWad);
        SD59x18 qN = SD59x18.wrap(qNoWad);
        SD59x18 delta = SD59x18.wrap(int256(sharesWad));
        SD59x18 c0 = LMSRMath.cost(qY, qN, bWad);
        SD59x18 c1 = isYes
            ? LMSRMath.cost(qY.add(delta), qN, bWad)
            : LMSRMath.cost(qY, qN.add(delta), bWad);
        int256 costWad = SD59x18.unwrap(c1.sub(c0));
        require(costWad > 0, "cost<=0");
        costCollateral = _fromWadCeil(uint256(costWad));
    }

    /// Probability of YES outcome in WAD (0..1e18).
    function probYes() external view returns (uint256) {
        SD59x18 p = LMSRMath.probYes(SD59x18.wrap(qYesWad), SD59x18.wrap(qNoWad), bWad);
        int256 w = SD59x18.unwrap(p);
        return w < 0 ? 0 : uint256(w);
    }

    function totals() external view returns (uint256 totalYesWad, uint256 totalNoWad) {
        totalYesWad = qYesWad < 0 ? 0 : uint256(qYesWad);
        totalNoWad = qNoWad < 0 ? 0 : uint256(qNoWad);
    }

    // ─── Trading ───────────────────────────────────────────────────────

    /// Buy `sharesWad` of the chosen side. Reverts if cost > `maxCostCollateral`.
    function buy(bool isYes, uint256 sharesWad, uint256 maxCostCollateral)
        external
        returns (uint256 cost)
    {
        if (phase != Phase.Open) revert NotOpen();
        if (block.timestamp >= expiry) revert NotOpen();
        if (sharesWad == 0) revert ZeroShares();

        cost = quote(isYes, sharesWad);
        if (cost > maxCostCollateral) revert SlippageExceeded(cost, maxCostCollateral);

        collateral.safeTransferFrom(msg.sender, address(this), cost);

        if (isYes) {
            qYesWad += int256(sharesWad);
            yesShares[msg.sender] += sharesWad;
        } else {
            qNoWad += int256(sharesWad);
            noShares[msg.sender] += sharesWad;
        }

        emit Bought(msg.sender, isYes, sharesWad, cost);
    }

    // ─── Resolution ────────────────────────────────────────────────────

    /// Permissionless. Reads Chainlink at/after expiry and locks the outcome.
    function resolve() external {
        if (phase == Phase.Resolved) revert AlreadyResolved();
        if (block.timestamp < expiry) revert NotYetExpired();

        uint256 price = PriceOracle.read(priceFeed, maxStaleness);
        Outcome o = price >= strike ? Outcome.YES : Outcome.NO;

        phase = Phase.Resolved;
        outcome = o;
        settlementPrice = price;
        resolvedAt = block.timestamp;

        emit Resolved(o, price, block.timestamp);
    }

    // ─── Redemption ────────────────────────────────────────────────────

    /// Redeem all winning shares for collateral at 1 share = 1 collateral unit.
    function redeem() external returns (uint256 paid) {
        if (phase != Phase.Resolved) revert NotResolved();
        uint256 winningSharesWad = outcome == Outcome.YES
            ? yesShares[msg.sender]
            : noShares[msg.sender];
        if (winningSharesWad == 0) return 0;

        if (outcome == Outcome.YES) {
            yesShares[msg.sender] = 0;
        } else {
            noShares[msg.sender] = 0;
        }

        paid = _fromWadFloor(winningSharesWad);
        collateral.safeTransfer(msg.sender, paid);
        emit Redeemed(msg.sender, winningSharesWad, paid);
    }

    // ─── Decimal helpers ───────────────────────────────────────────────

    function _toWad(uint256 amount) internal view returns (uint256) {
        if (collateralDecimals == 18) return amount;
        if (collateralDecimals < 18) return amount * (10 ** (18 - collateralDecimals));
        return amount / (10 ** (collateralDecimals - 18));
    }

    function _fromWadFloor(uint256 wadAmount) internal view returns (uint256) {
        if (collateralDecimals == 18) return wadAmount;
        if (collateralDecimals < 18) return wadAmount / (10 ** (18 - collateralDecimals));
        return wadAmount * (10 ** (collateralDecimals - 18));
    }

    function _fromWadCeil(uint256 wadAmount) internal view returns (uint256) {
        if (collateralDecimals == 18) return wadAmount;
        if (collateralDecimals < 18) {
            uint256 denom = 10 ** (18 - collateralDecimals);
            return (wadAmount + denom - 1) / denom;
        }
        return wadAmount * (10 ** (collateralDecimals - 18));
    }
}
