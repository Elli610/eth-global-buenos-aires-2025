// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {NonToxicMath, Q96, SCALE} from "../src/NonToxicMath.sol";

contract HookTest is Test {
    NonToxicMath public hook;

    function setUp() public {
        hook = new NonToxicMath();
    }

    // lobster_data=> select * from swap_events where chain_id = 1 and emitter = '\x99ac8cA7087fA4A2A1FB6357269965A2014ABc35' order by block_number DESC limit 6;
    //  chain_id | block_number |                          transaction_hash                          | log_index |                  emitter                   |                   sender                   |                 recipient                  |  amount0  |   amount1    |         sqrt_price_x96          |   liquidity   | tick
    // ----------+--------------+--------------------------------------------------------------------+-----------+--------------------------------------------+--------------------------------------------+--------------------------------------------+-----------+--------------+---------------------------------+---------------+-------
    //         1 |     23833977 | \x7a22aaa60ec0764f76ecc7a40bbc4780dfcc05a13c2aac6f53c0bdd5293c110f |       155 | \x99ac8ca7087fa4a2a1fb6357269965a2014abc35 | \x6747bcaf9bd5a5f0758cbe08903490e45ddfacb5 | \x6930e17f5e687cd138474a5215d09324d2fdb316 |  13921300 | -12746434883 | 2400895714879232902503166069071 | 6930192433872 | 68228
    //         1 |     23833976 | \x0e8a5d50652a3546d9bb5c266df6cf157327873d99fb53bbf21fb0f6735410f8 |        21 | \x99ac8ca7087fa4a2a1fb6357269965a2014abc35 | \x50d3865a63d52c0a54e4679949647ea752107390 | \x50d3865a63d52c0a54e4679949647ea752107390 |  31563899 | -28905847724 | 2401041436173994538821021827605 | 6930192433872 | 68229
    //         1 |     23833958 | \x691822da6538d596542aaffb800c7b0f602c3e41d532c849978efee5cf559d19 |        48 | \x99ac8ca7087fa4a2a1fb6357269965a2014abc35 | \x51c72848c68a965f66fa7a88855f9f7784502a7f | \x51c72848c68a965f66fa7a88855f9f7784502a7f | -46259235 |  42616238553 | 2401371897012278534835809741597 | 6930192433872 | 68232
    //         1 |     23833921 | \xce521d226fb73801a2fe9a89bee7a2a0e890281d54c02748eed056f49dc3f39c |        61 | \x99ac8ca7087fa4a2a1fb6357269965a2014abc35 | \xe592427a0aece92de3edee1f18e0157c05861564 | \x00c600b30fb0400701010f4b080409018b9006e0 | -21902933 |  20172025085 | 2400886156235655617171479152061 | 6930185419902 | 68228
    //         1 |     23833920 | \xc423f08619c7c8063883adbd942e873a46c341a836e266d3d89082e67f7f5f42 |        14 | \x99ac8ca7087fa4a2a1fb6357269965a2014abc35 | \xa69babef1ca67a37ffaf7a485dfff3382056e78c | \xa69babef1ca67a37ffaf7a485dfff3382056e78c | -30547018 |  28126549500 | 2400656234839960164680498307442 | 6930185419902 | 68226
    //         1 |     23833919 | \x2442a80645302540d0d3b02d09db3d7f0466f2ac21461b8b86133f93547eb1b8 |       230 | \x99ac8ca7087fa4a2a1fb6357269965a2014abc35 | \x51c72848c68a965f66fa7a88855f9f7784502a7f | \x51c72848c68a965f66fa7a88855f9f7784502a7f | -43981044 |  40482904973 | 2400335647517169737909674096814 | 6930185419902 | 68224
    // (6 rows)

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
