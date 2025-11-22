// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// import {console} from "forge-std/Test.sol";

uint256 constant SCALE = 1e18;
uint256 constant Q96 = 0x1000000000000000000000000;

contract NonToxicMath {
    function preComputeVolume1(
        bool zeroForOne,
        int256 amountSpecified,
        uint256 sqrtPrice
    ) internal returns (int256 volume1) {
        if (zeroForOne && amountSpecified > 0) return -amountSpecified;
        if (zeroForOne && amountSpecified < 0) return amountSpecified;

        // (zeroForOne && amountSpecified < 0) || (!zeroForOne && amountSpecified > 0)
        return amountSpecified * int256(sqrtPrice) ** 2;
    }

    function computeFees(
        int256 volume1,
        uint256 alpha,
        uint256 activeLiq,
        uint256 initialSqrtprice_,
        uint256 extremumSqrtprice_,
        uint256 currentSqrtPrice
    ) public pure returns (uint256) {
        // uint256 alpha = 2; // >= 1
        // uint256 activeLiq = 123456789123456789; // todo: handle activeLiq = 0

        // // dernier sqrt price ou on a pu se rebalancer (ie: n ticks contre le rally actuel)
        // uint256 initialSqrtprice_;
        // // extremum du sqrt price depuis dernier sqrt price ou on a pu se rebalancer (ie: n ticks contre le rally actuel) (ie: max sqrt price si prix monte, min sinon)
        // uint256 extremumSqrtprice_;
        // uint256 currentSqrtPrice;

        uint256 sqrtpriceHistory;
        // Swap  dans la tendance ?
        // if extremumSqrtprice_ > initialSqrtprice_ tendance is up, else down
        if (
            (extremumSqrtprice_ > initialSqrtprice_ && volume1 > 0) ||
            (extremumSqrtprice_ < initialSqrtprice_ && volume1 < 0)
        ) {
            sqrtpriceHistory = initialSqrtprice_ > currentSqrtPrice
                ? initialSqrtprice_ - currentSqrtPrice
                : currentSqrtPrice - initialSqrtprice_;
        } else {
            sqrtpriceHistory = extremumSqrtprice_ > currentSqrtPrice
                ? extremumSqrtprice_ - currentSqrtPrice
                : currentSqrtPrice - extremumSqrtprice_;
        }

        uint256 volume1Signed = uint256(volume1 > 0 ? volume1 : -volume1);

        // console.log(
        //     "(volume1Signed * 1e18) / (2 * activeLiq)",
        //     (volume1Signed * 1e18) / (2 * activeLiq)
        // );
        // console.log(
        //     "(volume1Signed * 1e18 * 1e18) / (2 * activeLiq * currentSqrtPrice)",
        //     (volume1Signed * 1e18 * 1e18) / (2 * activeLiq * currentSqrtPrice)
        // );
        // console.log("sqrtpriceHistory", sqrtpriceHistory);

        // console.log(
        //     "sqrtpriceHistory / currentSqrtPrice",
        //     (sqrtpriceHistory * 1e18) / currentSqrtPrice
        // );

        uint256 feePercentScaled = ((alpha *
            (((volume1Signed * SCALE) / (2 * activeLiq)) +
                (SCALE * sqrtpriceHistory))) / currentSqrtPrice);

        return feePercentScaled;
    }
}
