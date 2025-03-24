# Auto-Compound Hook Test Plan

This document outlines a comprehensive test plan for the Uniswap V4 Auto-Compound Hook implementation.

## Setup Requirements

1. Properly installed dependencies
   - Uniswap V4 Core
   - Uniswap V4 Periphery
   - Solmate
   - OpenZeppelin (if needed)

2. Mock contracts for testing
   - Mock ERC20 tokens
   - Test environment with initialized PoolManager

## Test Categories

### 1. Basic Functionality Tests

#### Test Creating Positions
- Test creating a position with valid parameters
- Test creating a position with invalid parameters (should revert)
- Test creating duplicate positions (should revert)
- Test creating positions with different tick ranges

#### Test Position Management
- Test retrieving position details
- Test modifying positions 
- Test that position details are accurately tracked
- Test position ownership verification

### 2. Fee Handling Tests

#### Test Fee Collection
- Test fees are correctly collected during swaps
- Test fee distribution to positions based on their liquidity share
- Test fee accounting across multiple positions

#### Test Fee Compounding
- Test automatic compounding of fees into additional liquidity
- Test compounding timing mechanism (minimum intervals)
- Test fee reset after compounding
- Test multiple compounding events

### 3. Rebalancing Tests

#### Test Rebalance Triggering
- Test rebalancing when price moves to edge of range
- Test rebalancing after significant price movements
- Test no rebalancing when not needed

#### Test Rebalance Execution
- Test correct calculation of new range
- Test liquidity removal and re-addition
- Test slippage protection during rebalancing
- Test position updates after rebalancing

### 4. Hook Integration Tests

#### Test Hook Callbacks
- Test afterModifyPosition hook execution
- Test afterSwap hook execution
- Test hook permissions

#### Test Interaction with PoolManager
- Test modification of positions through PoolManager
- Test swaps through PoolManager that trigger hook callbacks

### 5. Edge Cases and Security Tests

#### Test Extreme Market Conditions
- Test with extreme price movements
- Test with zero liquidity conditions
- Test with very large/small position sizes

#### Test Security Aspects
- Test reentrancy protection
- Test access control (only position owner can modify)
- Test invalid parameter handling

## Detailed Test Cases

### Position Creation Tests

```solidity
function test_CreatePosition() public {
    // Create a pool and initialize it
    
    // Define position parameters
    int24 lowerTick = -1200; // Approximately -10% from current price
    int24 upperTick = 1200;  // Approximately +10% from current price
    uint128 liquidity = 1e18;
    
    // Create position
    hook.createPosition(poolKey, lowerTick, upperTick, liquidity);
    
    // Verify position was created correctly
    bytes32 positionId = calculatePositionId(alice, lowerTick, upperTick);
    (
        address owner,
        int24 lower,
        int24 upper,
        uint128 posLiquidity,
        ,
        ,
    ) = hook.positions(positionId);
    
    assertEq(owner, alice);
    assertEq(lower, lowerTick);
    assertEq(upper, upperTick);
    assertEq(posLiquidity, liquidity);
}
```

### Fee Collection and Compounding Tests

```solidity
function test_FeeCollection() public {
    // Create a position
    createTestPosition();
    
    // Perform a swap to generate fees
    performSwap(token0, token1, 1e18, true);
    
    // Check fees were collected
    bytes32 positionId = calculatePositionId(alice, -1200, 1200);
    (
        ,
        ,
        ,
        ,
        uint256 fees0,
        uint256 fees1,
    ) = hook.positions(positionId);
    
    assertGt(fees0, 0, "Should have collected token0 fees");
    // or
    assertGt(fees1, 0, "Should have collected token1 fees");
}

function test_FeeCompounding() public {
    // Create a position and generate fees
    test_FeeCollection();
    
    // Store initial liquidity
    bytes32 positionId = calculatePositionId(alice, -1200, 1200);
    (
        ,
        ,
        ,
        uint128 initialLiquidity,
        uint256 initialFees0,
        uint256 initialFees1,
    ) = hook.positions(positionId);
    
    // Fast forward time to allow compounding
    vm.warp(block.timestamp + 2 hours);
    
    // Trigger compounding via a position modification
    modifyPosition();
    
    // Check that liquidity increased and fees were reset
    (
        ,
        ,
        ,
        uint128 newLiquidity,
        uint256 newFees0,
        uint256 newFees1,
    ) = hook.positions(positionId);
    
    assertGt(newLiquidity, initialLiquidity, "Liquidity should have increased");
    assertLt(newFees0, initialFees0, "Fees0 should have decreased");
    assertLt(newFees1, initialFees1, "Fees1 should have decreased");
}
```

### Rebalancing Tests

```solidity
function test_Rebalance() public {
    // Create a position
    createTestPosition();
    
    bytes32 positionId = calculatePositionId(alice, -1200, 1200);
    (
        ,
        int24 initialLower,
        int24 initialUpper,
        uint128 initialLiquidity,
        ,
        ,
    ) = hook.positions(positionId);
    
    // Execute large swap to move price significantly
    performSwap(token0, token1, 50e18, true);
    
    // Trigger rebalance by modifying position
    modifyPosition();
    
    // Check that position range has changed
    (
        ,
        int24 newLower,
        int24 newUpper,
        uint128 newLiquidity,
        ,
        ,
    ) = hook.positions(positionId);
    
    assertNotEq(newLower, initialLower, "Lower tick should have changed");
    assertNotEq(newUpper, initialUpper, "Upper tick should have changed");
    assertGt(newLiquidity, 0, "Should have non-zero liquidity after rebalance");
}
```

## Test Execution Plan

1. Run basic tests first to ensure core functionality works
2. Run comprehensive tests to verify all features
3. Run edge case tests to ensure robustness

To execute tests:
```bash
forge test -vv
```

To run a specific test:
```bash
forge test --match-test test_CreatePosition -vv
```

For gas optimization analysis:
```bash
forge test --gas-report
``` 