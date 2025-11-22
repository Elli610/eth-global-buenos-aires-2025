// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {NonToxicPool, HOOK_FLAGS} from "../src/NonToxicPool.sol";
import {MockERC20} from "../test/MockERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Helper contract for CREATE2 deployment
contract Create2Factory {
    event Deployed(address addr, bytes32 salt);

    function deploy(
        bytes memory bytecode,
        bytes32 salt
    ) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        emit Deployed(addr, salt);
    }

    function computeAddress(
        bytes32 salt,
        bytes32 bytecodeHash
    ) external view returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                bytecodeHash
                            )
                        )
                    )
                )
            );
    }
}

contract DeployNonToxicPool is Script {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IStateView public stateView;
    IPermit2 public permit2;
    PoolSwapTest public swapRouter;
    NonToxicPool public hook;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public poolKey;
    Create2Factory public factory;

    // Deployment parameters
    uint256 public constant ALPHA = 1; // Fee multiplier
    uint160 public constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // Roughly 1:1 price

    // Liquidity parameters
    uint256 public constant LIQUIDITY_AMOUNT = 1000 ether; // Amount of each token to provide
    int24 public constant TICK_RANGE = 600; // Range around current tick (10 ticks * 60 tickSpacing)

    // Swap parameters
    uint256 public constant SWAP_AMOUNT = 10 ether; // Amount to swap

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the CREATE2 factory first
        factory = new Create2Factory();
        console.log("Create2Factory deployed at:", address(factory));

        // Set up mainnet contract addresses
        poolManager = IPoolManager(
            address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) // Sepolia PoolManager
        );

        positionManager = IPositionManager(
            address(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4) // Sepolia PositionManager
        );

        // Deploy StateView or use existing deployment
        stateView = IStateView(
            address(0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C)
        );

        permit2 = IPermit2(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

        // Deploy or use existing PoolSwapTest
        swapRouter = new PoolSwapTest(poolManager);

        console.log("PoolManager:", address(poolManager));
        console.log("PositionManager:", address(positionManager));
        console.log("StateView:", address(stateView));
        console.log("SwapRouter:", address(swapRouter));

        // Deploy mock tokens
        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();

        console.log("TokenA deployed at:", address(tokenA));
        console.log("TokenB deployed at:", address(tokenB));

        // Sort tokens - currency0 must be < currency1
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        console.log("Token0 (sorted):", address(token0));
        console.log("Token1 (sorted):", address(token1));

        // Get the bytecode for the hook
        bytes memory hookBytecode = abi.encodePacked(
            type(NonToxicPool).creationCode,
            abi.encode(poolManager, stateView, ALPHA)
        );

        // Mine for the correct salt
        bytes32 salt = mineSalt(address(factory), hookBytecode);
        console.log("Found salt:");
        console.logBytes32(salt);

        // Deploy the hook using CREATE2
        address hookAddress = factory.deploy(hookBytecode, salt);
        hook = NonToxicPool(hookAddress);

        console.log("NonToxicPool deployed at:", address(hook));
        console.log("Hook alpha parameter:", hook.alpha());

        // Verify the hook address has the correct flags
        uint160 hookAddressInt = uint160(address(hook));
        uint160 actualFlags = hookAddressInt & Hooks.ALL_HOOK_MASK;

        console.log("Expected flags:", HOOK_FLAGS);
        console.log("Actual flags:", actualFlags);

        require(
            actualFlags == HOOK_FLAGS,
            "Hook address does not have required flags"
        );

        // Set up dynamic fee (0x800000 is the dynamic fee flag)
        uint24 dynamicFee = 0x800000;

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: dynamicFee,
            tickSpacing: int24(60), // Standard tick spacing for dynamic fee pools
            hooks: hook
        });

        console.log("Initializing pool...");
        console.log("Currency0:", Currency.unwrap(poolKey.currency0));
        console.log("Currency1:", Currency.unwrap(poolKey.currency1));
        console.log("Fee:", poolKey.fee);
        console.log("TickSpacing:", poolKey.tickSpacing);
        console.log("Initial sqrtPrice:", INITIAL_SQRT_PRICE);

        // Initialize the pool
        poolManager.initialize(poolKey, INITIAL_SQRT_PRICE);

        console.log("Pool initialized successfully!");

        // Add liquidity around the current tick
        addLiquidity(deployer);

        // Perform a test swap
        performSwap(deployer);

        vm.stopBroadcast();

        PoolId poolId = poolKey.toId();

        // Log deployment info for verification
        console.log("\n=== Deployment Summary ===");
        console.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console.log("Factory:", address(factory));
        console.log("Hook:", address(hook));
        console.log("Token0:", address(token0));
        console.log("Token1:", address(token1));
        console.log("PoolManager:", address(poolManager));
        console.log("PositionManager:", address(positionManager));
        console.log("StateView:", address(stateView));
        console.log("SwapRouter:", address(swapRouter));
        console.log("Alpha:", ALPHA);
    }

    /// @notice Add liquidity to the pool around the current tick
    function addLiquidity(address deployer) internal {
        console.log("\n=== Adding Liquidity ===");

        // Mint tokens to deployer
        token0.mint(deployer, LIQUIDITY_AMOUNT);
        token1.mint(deployer, LIQUIDITY_AMOUNT);

        console.log("Minted tokens:");
        console.log("Token0 balance:", token0.balanceOf(deployer));
        console.log("Token1 balance:", token1.balanceOf(deployer));

        // Approve PositionManager to spend tokens
        // First approve Permit2 to spend tokens
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);

        console.log("Approved Permit2 to spend tokens");

        // Then use Permit2 to approve PositionManager
        permit2.approve(
            address(token0),
            address(positionManager),
            type(uint160).max,
            type(uint48).max // No expiration
        );

        permit2.approve(
            address(token1),
            address(positionManager),
            type(uint160).max,
            type(uint48).max // No expiration
        );

        console.log("Approved PositionManager through Permit2");

        // Calculate tick range around current price
        // sqrtPrice of 2288668768328953335596493506431 corresponds to tick 0 (approximately)
        int24 currentTick = 0; // Approximate tick for 1:1 price

        // Align ticks to tickSpacing
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = ((currentTick - TICK_RANGE) / tickSpacing) *
            tickSpacing;
        int24 tickUpper = ((currentTick + TICK_RANGE) / tickSpacing) *
            tickSpacing;

        console.log("Current tick (approx):", currentTick);
        console.log("Tick lower:", tickLower);
        console.log("Tick upper:", tickUpper);

        // Prepare mint parameters
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION parameters
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            LIQUIDITY_AMOUNT, // liquidity amount
            LIQUIDITY_AMOUNT, // amount0Max
            LIQUIDITY_AMOUNT, // amount1Max
            deployer, // recipient
            bytes("") // hookData
        );

        // SETTLE_PAIR parameters
        params[1] = abi.encode(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1))
        );

        console.log("Calling modifyLiquidities...");

        // Add liquidity through PositionManager
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60 // deadline
        );

        console.log("Liquidity added successfully!");
        console.log("Position range:");
        console.log("tickLower", tickLower);
        console.log("tickUpper", tickUpper);
    }

    /// @notice Perform a test swap on the pool
    function performSwap(address deployer) internal {
        console.log("\n=== Performing Test Swap ===");

        // Mint tokens for swap
        token0.mint(deployer, SWAP_AMOUNT);

        console.log("Token balances before swap:");
        console.log("Token0:", token0.balanceOf(deployer));
        console.log("Token1:", token1.balanceOf(deployer));

        // Approve swap router to spend tokens
        token0.approve(address(swapRouter), SWAP_AMOUNT);

        console.log("Approved SwapRouter to spend token0");

        // Set up swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: true, // Swapping token0 for token1
            amountSpecified: -int256(SWAP_AMOUNT), // Negative for exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 // No price limit
        });

        // Prepare test settings
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap...");
        console.log("Swapping", SWAP_AMOUNT, "token0 for token1");

        // Execute swap
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            params,
            testSettings,
            bytes("") // hookData
        );

        console.log("Swap completed!");
        console.log("Token balances after swap:");
        console.log("Token0:", token0.balanceOf(deployer));
        console.log("Token1:", token1.balanceOf(deployer));

        // Log the delta
        console.log("Balance delta:");
        console.log("Amount0:", delta.amount0());
        console.log("Amount1:", delta.amount1());
    }

    /// @notice Mine for a salt that will produce a hook address with the desired flags
    /// @param factoryAddr The address of the CREATE2 factory
    /// @param bytecode The creation bytecode
    /// @return salt The salt that produces the correct address
    function mineSalt(
        address factoryAddr,
        bytes memory bytecode
    ) internal view returns (bytes32) {
        bytes32 bytecodeHash = keccak256(bytecode);

        console.log("Mining for salt with factory:", factoryAddr);
        console.log("Bytecode hash:");
        console.logBytes32(bytecodeHash);
        console.log("Target flags:", HOOK_FLAGS);

        // Mine for a salt
        for (uint256 i = 0; i < 100_000_000; i++) {
            bytes32 salt = bytes32(i);

            address predictedAddress = computeCreate2Address(
                factoryAddr,
                salt,
                bytecodeHash
            );

            uint160 addressFlags = uint160(predictedAddress) &
                Hooks.ALL_HOOK_MASK;

            // Check if this address has the required hook flags
            if (addressFlags == HOOK_FLAGS) {
                console.log("Found valid salt after", i, "iterations");
                console.log("Predicted address:", predictedAddress);
                return salt;
            }

            // Log progress every million iterations
            if (i % 1_000_000 == 0 && i > 0) {
                console.log("Checked", i, "salts...");
            }
        }

        revert("Could not find valid salt within range");
    }

    /// @notice Compute the CREATE2 address
    /// @param deployer The deployer address (factory)
    /// @param salt The salt
    /// @param initCodeHash The init code hash
    /// @return The predicted address
    function computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }
}

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}
