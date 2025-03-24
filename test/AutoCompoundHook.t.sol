// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {AutoCompoundHook} from "../src/AutoCoumpoundHook.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract AutoCompoundHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Test tokens
    MockERC20 token0;
    MockERC20 token1;

    // Uniswap V4 contracts
    PoolManager poolManager;
    AutoCompoundHook hook;

    // Test parameters
    uint24 constant FEE = 3000; // 0.3% fee tier
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_X96 = 79228162514264337593543950336; // 1:1 price

    // User accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);

        // Ensure token0 address is less than token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Mint tokens to test accounts
        token0.mint(alice, 1000e18);
        token1.mint(alice, 1000e18);
        token0.mint(bob, 1000e18);
        token1.mint(bob, 1000e18);

        // Deploy Uniswap V4 PoolManager
        poolManager = new PoolManager(500000);

        // Deploy AutoCompoundHook
        hook = new AutoCompoundHook(poolManager);

        // Initialize test accounts
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_CreatePosition() public {
        // Create pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Initialize pool
        vm.startPrank(address(hook));
        poolManager.initialize(key, SQRT_PRICE_X96, new bytes(0));
        vm.stopPrank();

        // Define position parameters
        int24 lowerTick = -1200; // Approximately -10% from current price
        int24 upperTick = 1200; // Approximately +10% from current price
        uint128 liquidity = 1e18;

        // Calculate token amounts for liquidity
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                SQRT_PRICE_X96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );

        // Create position
        vm.startPrank(alice);
        hook.createPosition(key, lowerTick, upperTick, liquidity);
        vm.stopPrank();

        // Calculate position ID (this should match the implementation in the hook)
        bytes32 positionId = keccak256(
            abi.encode(
                alice,
                address(token0),
                address(token1),
                lowerTick,
                upperTick
            )
        );

        // Verify position was created correctly
        (
            address owner,
            int24 lower,
            int24 upper,
            uint128 posLiquidity,
            ,
            ,

        ) = hook.positions(positionId);

        assertEq(owner, alice, "Position owner should be alice");
        assertEq(lower, lowerTick, "Lower tick should match");
        assertEq(upper, upperTick, "Upper tick should match");
        assertEq(posLiquidity, liquidity, "Liquidity should match");
    }

    function test_Swap() public {
        // First create a position
        test_CreatePosition();

        // Perform a swap to generate fees
        vm.startPrank(bob);

        // Approve tokens for swap
        token0.approve(address(poolManager), 10e18);

        // Swap parameters
        bool zeroForOne = true;
        uint256 amountIn = 1e18;

        // Execute swap through pool manager
        poolManager.swap(
            PoolKey({
                currency0: Currency.wrap(address(token0)),
                currency1: Currency.wrap(address(token1)),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(hook))
            }),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1
            }),
            new bytes(0)
        );

        vm.stopPrank();

        // Now test the auto-compounding (fast forward time)
        vm.warp(block.timestamp + 2 hours);

        // TODO: Add more assertions to verify fees were collected and compounded
    }

    function test_Rebalance() public {
        // First create a position
        test_CreatePosition();

        // Perform multiple swaps to move price significantly
        vm.startPrank(bob);

        // Approve tokens for swap
        token0.approve(address(poolManager), 100e18);

        // Execute large swap to move price
        poolManager.swap(
            PoolKey({
                currency0: Currency.wrap(address(token0)),
                currency1: Currency.wrap(address(token1)),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(hook))
            }),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(50e18),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            new bytes(0)
        );

        vm.stopPrank();

        // Modify position to trigger rebalance
        vm.startPrank(alice);

        // TODO: Call a function that triggers afterModifyPosition

        vm.stopPrank();

        // TODO: Add assertions to verify position was rebalanced
    }
}
