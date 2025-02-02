# 🔄 AutoCompoundHook

Automated Uniswap V4 Position Management with Smart Rebalancing & Fee Compounding

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## 📚 Overview

AutoCompoundHook is a smart contract that automates Uniswap V4 liquidity positions management. It provides hands-free fee compounding and position rebalancing, optimizing returns while maintaining efficient capital utilization.

## ⭐ Key Features

### 🔄 Automated Fee Compounding
- 💰 Automatically collects and reinvests trading fees
- ⏱️ Hourly compounding optimization
- 🛡️ Price stability verification
- 📊 Fee compound event tracking

### 📈 Smart Position Rebalancing
- 🎯 Auto-rebalances near range boundaries
- ⚖️ 3-minute TWAP price validation
- 🛡️ 10-tick spacing safety buffer
- 🔒 Manipulation resistance

### 🎨 NFT-Based Management
- 🔑 NFT ownership verification
- 👥 Clear position ownership
- 🔌 DeFi protocol integration ready

## 🚀 Getting Started

### 📝 Creating a Position

1. **Prerequisites**
   - Own a supported NFT
   - Have tokens for liquidity

2. **Function Call**
```solidity
function createPosition(
    IPoolManager.PoolKey calldata key,  // Pool information
    int24 lower,                        // Lower tick bound
    int24 upper,                        // Upper tick bound
    uint128 liquidity,                  // Amount of liquidity
    uint256 nftId                       // Your NFT ID
)
```

3. **Example Usage**
```javascript
await autoCompoundHook.createPosition(
    poolKey,
    -100,    // Lower tick
    100,     // Upper tick
    1000000, // Liquidity amount
    42       // Your NFT ID
);
```

### 📊 Position Monitoring

Track your position with these events:
```solidity
event PositionRebalanced(
    bytes32 indexed positionId,
    int24 newLower,
    int24 newUpper
);

event FeesCompounded(
    bytes32 indexed positionId,
    uint256 amount0,
    uint256 amount1
);
```

### 🔍 View Position Details
```javascript
const position = await autoCompoundHook.positions(positionId);
console.log({
    nftId: position.nftId,
    lowerTick: position.lowerTick,
    upperTick: position.upperTick,
    liquidity: position.liquidity,
    fees0: position.fees0,
    fees1: position.fees1,
    lastCompound: position.lastCompound
});
```

## 🛡️ Safety Features

### 💪 Price Protection
- ⏰ 3-minute TWAP window
- 📊 0.5% max price deviation
- ⚡ Hourly compound limiting

### 🔒 Access Control
- 🎨 NFT-based verification
- 🛡️ ReentrancyGuard protection
- 🔑 Pool manager restrictions

## ⚙️ Technical Parameters

### Configuration Constants
```solidity
TWAP_WINDOW = 180 seconds (3 minutes)
MAX_TICK_DEVIATION = 50 (0.5%)
REBALANCE_BUFFER = 10 * tickSpacing
COMPOUND_INTERVAL = 1 hour
```

### Position Structure
```solidity
struct Position {
    uint256 nftId;        // Associated NFT ID
    int24 lowerTick;      // Lower price bound
    int24 upperTick;      // Upper price bound
    uint128 liquidity;    // Position size
    uint256 fees0;        // Accumulated token0 fees
    uint256 fees1;        // Accumulated token1 fees
    uint256 lastCompound; // Last compound timestamp
}
```

## 🛠️ Development

### Prerequisites
- Solidity ^0.8.24
- Uniswap V4 Core
- OpenZeppelin contracts

### Dependencies
```solidity
import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
```

## 🗺️ Future Roadmap

### 📈 Enhanced Position Management
- Multiple positions per NFT
- Partial liquidation support
- Emergency withdrawal system

### 🎯 Advanced Features
- Custom rebalancing strategies
- Dynamic fee optimization
- External oracle integration

### ⚠️ Risk Management
- Position size limits
- Volatility circuit breakers
- Advanced analytics suite

## 🤝 Contributing
We welcome contributions! See our contributing guidelines for details.

## 📄 License
This project is licensed under the MIT License.