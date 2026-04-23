// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SD59x18} from "@prb/math/SD59x18.sol";

/// LMSR (Logarithmic Market Scoring Rule) cost + probability functions for a
/// binary outcome market, in 18-decimal signed fixed-point (WAD).
///
/// Cost function (Hanson 2003):
///   C(qY, qN) = b * ln(exp(qY/b) + exp(qN/b))
///
/// Numerically stable form used below:
///   C(qY, qN) = max(qY, qN) + b * ln(1 + exp(-|qY - qN|/b))
///
/// Probability of YES:
///   p = 1 / (1 + exp((qN - qY)/b))
library LMSRMath {
    SD59x18 private constant ONE = SD59x18.wrap(1e18);

    /// @param qYes Outstanding YES shares (WAD)
    /// @param qNo  Outstanding NO shares (WAD)
    /// @param b    Liquidity parameter (WAD). Larger b = deeper liquidity, bigger house loss.
    /// @return    Total LMSR cost function value (WAD).
    function cost(SD59x18 qYes, SD59x18 qNo, SD59x18 b) internal pure returns (SD59x18) {
        (SD59x18 hi, SD59x18 lo) = qYes.gt(qNo) ? (qYes, qNo) : (qNo, qYes);
        SD59x18 negDiffOverB = lo.sub(hi).div(b); // (lo - hi) / b  ≤ 0
        SD59x18 expPart = negDiffOverB.exp(); // ∈ (0, 1]
        SD59x18 lnPart = ONE.add(expPart).ln();
        return hi.add(b.mul(lnPart));
    }

    /// Probability of YES outcome, WAD (0..1e18).
    function probYes(SD59x18 qYes, SD59x18 qNo, SD59x18 b) internal pure returns (SD59x18) {
        SD59x18 expPart = qNo.sub(qYes).div(b).exp(); // exp((qNo-qYes)/b)
        return ONE.div(ONE.add(expPart));
    }
}
