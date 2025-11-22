// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {NonToxicMath, SCALE, Q96} from "./NonToxicMath.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract NonToxicPool is BaseHook, NonToxicMath {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // Fee multiplier
    uint256 public immutable alpha;

    // Last sqrt price with a drawback > 1 tick
    uint256 public initialSqrtpriceScaled;
    // Max or min sqrt price since the last drawback > 1 tick
    uint256 public extremumSqrtpriceScaled;

    IStateView public stateView;

    error MustUseDynamicFee();

    constructor(
        IPoolManager _poolManager,
        IStateView _stateView,
        uint256 _alpha
    ) BaseHook(_poolManager) {
        alpha = _alpha;
        stateView = _stateView;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory permissions)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        // Check that the attached pool has dynamic fee
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // int256 volume1,
        // uint256 alpha,
        // uint256 activeLiq,
        // uint256 initialSqrtprice_,
        // uint256 extremumSqrtprice_,
        // uint256 currentSqrtPrice

        // struct SwapParams {
        //     /// Whether to swap token0 for token1 or vice versa
        //     bool zeroForOne;
        //     /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
        //     int256 amountSpecified;
        //     /// The sqrt price at which, if reached, the swap will stop executing
        //     uint160 sqrtPriceLimitX96;
        // }

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 currentTick, , ) = stateView.getSlot0(
            poolId
        );

        // todo: if tick < last tick -2 , reset all

        uint256 currentSqrtPriceScaled = (SCALE * uint256(sqrtPriceX96)) / Q96;

        int256 volume1 = preComputeVolume1(
            params.zeroForOne,
            params.amountSpecified,
            uint256(sqrtPriceX96) / Q96
        );

        uint256 activeLiq = uint256(stateView.getLiquidity(poolId));

        uint256 newPoolFeePercentScaled = computeFees(
            volume1,
            alpha,
            activeLiq,
            initialSqrtpriceScaled,
            extremumSqrtpriceScaled,
            currentSqrtPriceScaled
        );

        uint256 newPoolFee = (newPoolFeePercentScaled * 1_000_000) / SCALE;

        poolManager.updateDynamicLPFee(
            key,
            uint24(newPoolFee > 1_000_000 ? 1_000_000 : newPoolFee)
        );

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    // todo: after swap, update sqrt prices
}
