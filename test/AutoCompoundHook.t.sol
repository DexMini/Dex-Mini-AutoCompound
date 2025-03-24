// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import "../src/AutoCoumpoundHook.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";

contract AutoCompoundHookTest is Test {
    AutoCompoundHook hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;

    // Test accounts
    address public alice;
    address public bob;

    function setUp() public {
        // Setup test accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy mocks
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Deploy hook
        hook = new AutoCompoundHook(IPoolManager(address(poolManager)));

        // Setup pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Setup initial token balances
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(bob, 1000 ether);
        token1.mint(bob, 1000 ether);

        // Setup approvals
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_HookPermissions() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertFalse(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertTrue(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertTrue(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    function test_CreatePosition() public {
        // Setup test parameters
        int24 lowerTick = -120;
        int24 upperTick = 120;
        uint128 liquidity = 1000000;

        // Mint tokens to this contract
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        // Approve tokens
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Create position
        hook.createPosition(poolKey, lowerTick, upperTick, liquidity);

        // Get position ID
        bytes32 positionId = keccak256(
            abi.encode(
                address(this),
                address(token0),
                address(token1),
                lowerTick,
                upperTick
            )
        );

        // Verify position was created
        (
            address owner,
            int24 storedLower,
            int24 storedUpper,
            uint128 storedLiquidity,
            ,
            ,

        ) = hook.positions(positionId);

        assertEq(owner, address(this));
        assertEq(storedLower, lowerTick);
        assertEq(storedUpper, upperTick);
        assertEq(storedLiquidity, liquidity);
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
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            }),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
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
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            }),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(50e18),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
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
