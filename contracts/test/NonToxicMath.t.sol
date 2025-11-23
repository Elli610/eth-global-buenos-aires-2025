// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {NonToxicMath, Q96, SCALE} from "../src/NonToxicMath.sol";

contract HookTest is Test {
    NonToxicMath public hook;

    function setUp() public {
        hook = new NonToxicMath();
    }

    // Test basic fee computation with upward trend and positive volume
    function testComputeFees() public view {
        int256 volume1 = -12746434883;
        uint256 alpha = 1;
        uint256 activeLiq = 6930192433872;
        uint256 initialSqrtPrice = (SCALE * 2370713100028836327518828066696) /
            Q96;

        uint256 maxSqrtPrice = (SCALE * 2370713100028836327518828066696) / Q96;
        uint256 currentSqrtPrice = (SCALE * 2400895714879232902503166069071) /
            Q96;

        console.log("currentSqrtPrice", currentSqrtPrice);

        uint256 fee = hook.computeFees(
            volume1,
            alpha,
            activeLiq,
            initialSqrtPrice,
            maxSqrtPrice,
            currentSqrtPrice
        );

        console.log("fee: ", fee);

        console.log("uni fee", (fee * 1_000_000) / SCALE);

        // Fee should be greater than 0
        assertGt(fee, 0);
    }
}
