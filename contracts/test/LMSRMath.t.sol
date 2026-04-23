// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMath} from "../src/LMSRMath.sol";
import {SD59x18} from "@prb/math/SD59x18.sol";

contract LMSRMathTest is Test {
    // b = 500 * 1e18 (i.e. "500 USDC" of depth in wad)
    SD59x18 constant B = SD59x18.wrap(500 ether);
    SD59x18 constant ZERO = SD59x18.wrap(0);

    function _wad(int256 x) internal pure returns (SD59x18) {
        return SD59x18.wrap(x * 1e18);
    }

    function _approxEq(SD59x18 a, SD59x18 b_, int256 tolerance) internal pure returns (bool) {
        int256 ai = SD59x18.unwrap(a);
        int256 bi = SD59x18.unwrap(b_);
        int256 diff = ai > bi ? ai - bi : bi - ai;
        return diff <= tolerance;
    }

    /// At q_yes = q_no = 0, cost = b * ln(2)
    function test_EmptyPoolCostIsBLn2() public pure {
        SD59x18 c = LMSRMath.cost(ZERO, ZERO, B);
        // b * ln(2) ≈ 500 * 0.6931471805599453 ≈ 346.5735902
        int256 expected = 346_573590279972654709; // 346.57... * 1e18
        assertTrue(_approxEq(c, SD59x18.wrap(expected), 1e10));
    }

    /// At q_yes = q_no = 0, p(YES) = 0.5
    function test_EmptyPoolProbabilityIsHalf() public pure {
        SD59x18 p = LMSRMath.probYes(ZERO, ZERO, B);
        // 0.5 in WAD = 5e17
        assertEq(SD59x18.unwrap(p), 5e17);
    }

    /// Buying YES shares pushes probability of YES up
    function test_BuyingYesRaisesYesProbability() public pure {
        SD59x18 p0 = LMSRMath.probYes(ZERO, ZERO, B);
        SD59x18 p1 = LMSRMath.probYes(_wad(100), ZERO, B);
        SD59x18 p2 = LMSRMath.probYes(_wad(500), ZERO, B);

        assertTrue(SD59x18.unwrap(p1) > SD59x18.unwrap(p0));
        assertTrue(SD59x18.unwrap(p2) > SD59x18.unwrap(p1));
    }

    /// Marginal price approaches 1 as qYes dominates
    function test_YesPriceApproachesOneAsQYesDominates() public pure {
        SD59x18 p = LMSRMath.probYes(_wad(5_000), ZERO, B);
        // ≈ exp(10) / (1+exp(10)) ≈ 0.99995
        assertTrue(SD59x18.unwrap(p) > 9995e14);
    }

    /// Cost is symmetric in qYes/qNo
    function test_CostIsSymmetric() public pure {
        SD59x18 c1 = LMSRMath.cost(_wad(100), _wad(200), B);
        SD59x18 c2 = LMSRMath.cost(_wad(200), _wad(100), B);
        assertEq(SD59x18.unwrap(c1), SD59x18.unwrap(c2));
    }

    /// Probability is anti-symmetric around 0.5
    function test_ProbIsAntiSymmetric() public pure {
        SD59x18 pYes = LMSRMath.probYes(_wad(100), _wad(50), B);
        SD59x18 pNo  = LMSRMath.probYes(_wad(50), _wad(100), B);
        // pYes + pNo should equal 1e18
        int256 sum = SD59x18.unwrap(pYes) + SD59x18.unwrap(pNo);
        assertApproxEqAbs(sum, 1e18, 1e10);
    }

    /// Buying shares always costs less than shares * 1 (since price < 1)
    function test_BuyCostLessThanShareCount() public pure {
        SD59x18 before = LMSRMath.cost(ZERO, ZERO, B);
        SD59x18 after_ = LMSRMath.cost(_wad(100), ZERO, B);
        SD59x18 buyCost = after_.sub(before);
        // Buying 100 shares must cost < 100 (since initial p < 1)
        assertTrue(SD59x18.unwrap(buyCost) < 100 ether);
        // And > 0
        assertTrue(SD59x18.unwrap(buyCost) > 0);
    }

    /// Max house subsidy = b * ln(2). After full liquidation of YES, the amount
    /// paid out minus amount collected is bounded.
    function test_WorstCaseHouseLossBounded() public pure {
        // At q=0,q=0 market value is b*ln(2)≈346.57. If market resolves to YES
        // with only Q YES shares outstanding, payout is Q. Cost received was
        // cost(Q,0) - cost(0,0). Max loss = payout - received =
        //   Q - (cost(Q,0) - cost(0,0)) which must equal b*ln(2) - (something).
        // As Q→∞, loss → b*ln(2).
        SD59x18 c0 = LMSRMath.cost(ZERO, ZERO, B);
        SD59x18 cLarge = LMSRMath.cost(_wad(50_000), ZERO, B);
        SD59x18 received = cLarge.sub(c0);
        SD59x18 payout = _wad(50_000);
        SD59x18 loss = payout.sub(received);
        // loss should be close to b*ln(2) ≈ 346.57
        assertApproxEqAbs(SD59x18.unwrap(loss), 346_573590279972654709, 1e14);
    }
}
