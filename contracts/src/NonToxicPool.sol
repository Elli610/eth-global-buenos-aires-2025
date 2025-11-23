// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {NonToxicMath, SCALE, Q96} from "./NonToxicMath.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

uint160 constant HOOK_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.AFTER_SWAP_FLAG
);

struct Position {
    int24 tickUpper;
    int24 tickLower;
    uint256 liquidity;
}

// todo: save poolKey to make sure we are always working with the same pool OR map poolIds to all state values
contract NonToxicPool is BaseHook, NonToxicMath {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    uint24 public constant WANTED_DRAWBACK = 9_000; // 1.5 tick spacing

    IStateView public immutable stateView;
    IPositionManager public immutable positionManager;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // Fee multiplier
    uint256 public immutable alpha;

    // Last sqrt price with a drawback > 1 tick
    uint256 public initialSqrtPriceScaled;
    // Max or min sqrt price since the last drawback > 1 tick
    uint256 public extremumSqrtPriceScaled;
    // todo: I guess we can get rid of it since this one matches the tick for extremumSqrtPriceScaled (so can be recomputed)
    int24 public extremumTick;

    Position public position1;
    Position public position2;

    error MustUseDynamicFee();

    constructor(
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IERC20 _token0,
        IERC20 _token1,
        IStateView _stateView,
        uint256 _alpha
    ) BaseHook(_poolManager) {
        alpha = _alpha;
        token0 = _token0;
        token1 = _token1;
        stateView = _stateView;
        positionManager = _positionManager;
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
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
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

    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        // Save the current sqrtPrice and tick
        extremumTick = tick;

        uint256 sqrtPrice = (SCALE * uint256(sqrtPriceX96)) / Q96;
        initialSqrtPriceScaled = sqrtPrice;
        extremumSqrtPriceScaled = sqrtPrice;

        return (BaseHook.afterInitialize.selector);
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
            initialSqrtPriceScaled,
            extremumSqrtPriceScaled,
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

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Identify the trend
        bool isUpTrend = extremumSqrtPriceScaled > initialSqrtPriceScaled;

        (uint160 sqrtPriceX96, int24 currentTick, , ) = stateView.getSlot0(
            key.toId()
        );
        uint256 currentSqrtPriceScaled = (SCALE * uint256(sqrtPriceX96)) / Q96;

        uint256 delta = uint256(
            currentSqrtPriceScaled > extremumSqrtPriceScaled
                ? currentSqrtPriceScaled - extremumSqrtPriceScaled
                : extremumSqrtPriceScaled - currentSqrtPriceScaled
        );

        if (delta / 2e6 > WANTED_DRAWBACK * currentSqrtPriceScaled) {
            initialSqrtPriceScaled = extremumSqrtPriceScaled;
            extremumSqrtPriceScaled = currentSqrtPriceScaled;

            return (BaseHook.afterSwap.selector, 0);
        }

        if (
            (isUpTrend && currentTick > extremumTick) ||
            (!isUpTrend && currentTick < extremumTick)
        ) {
            extremumTick = currentTick;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // Vault logic

    function rebalance(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata,
        uint256 currentSqrtPriceScaled
    ) internal {
        // Let's do it the dummy way

        // remove all positions
        burnLiquidity(key, position1, 1, position1.liquidity, 0, 0);
        burnLiquidity(key, position2, 2, position2.liquidity, 0, 0);

        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        // compute wallet repartition

        // value of balance 1 expressed in token 0
        uint256 balance1In0 = balance1 * currentSqrtPriceScaled ** 2;

        uint256 ratioScaled = balance1 / balance0;

        // Todo: Best thing to do would be doing some research and simulations to know if its better
        //       to rebalance at each swap doesn't matter the volume, liq, etc or rebalance in precise circomstances
        //       might also be useless to do and the diff is non-relevant

        // For today: rebalance at each swap
        // todo
    }

    function mintLiquidity(
        PoolKey calldata poolKey,
        Position memory position,
        uint8 positionIndex,
        uint256 liquidityDelta,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        // Prepare mint parameters
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION parameters
        params[0] = abi.encode(
            poolKey,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            amount0Max,
            amount1Max,
            address(this), // recipient
            bytes("") // hookData
        );

        // SETTLE_PAIR parameters
        params[1] = abi.encode(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1))
        );

        // Add liquidity through PositionManager
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp // deadline
        );

        if (positionIndex == 1) {
            position1.liquidity += liquidityDelta;
            return;
        }
        if (positionIndex == 2) {
            position2.liquidity += liquidityDelta;
            return;
        }

        revert("Invalid position index");
    }

    function burnLiquidity(
        PoolKey calldata poolKey,
        Position memory position,
        uint8 positionIndex,
        uint256 liquidityDelta,
        uint256 amount0Max, // ??
        uint256 amount1Max // ??
    ) internal {
        revert("todo");

        if (positionIndex == 1) {
            position1.liquidity -= liquidityDelta;
        }
        if (positionIndex == 2) {
            position2.liquidity -= liquidityDelta;
        }
    }
}
