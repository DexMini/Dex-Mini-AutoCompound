// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Updated imports with correct paths
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract AutoCompoundHook is BaseHook, ReentrancyGuard {
    using Hooks for IPoolManager;

    // Configuration constants
    uint32 public constant TWAP_WINDOW = 3600; // 1-hour TWAP
    uint24 public constant MAX_TICK_DEVIATION = 50; // 0.5% price deviation
    uint24 public constant SLIPPAGE_TOLERANCE = 500; // 5% slippage protection
    uint256 public constant MAX_POSITIONS_PER_TX = 50; // Gas optimization
    uint256 public constant MIN_COMPOUND_INTERVAL = 1 hours; // Minimum time between compounds

    // Position management structures
    struct Position {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint256 fees0;
        uint256 fees1;
        uint256 lastCompound;
    }

    struct PoolState {
        bytes32[] positionIds;
        uint256 totalLiquidity;
        uint256 lastProcessedIndex;
    }

    // State storage
    mapping(bytes32 => Position) public positions;
    mapping(address => uint256) private totalFees0;
    mapping(address => uint256) private totalFees1;
    mapping(bytes32 => PoolState) private poolStates;

    // Events
    event PositionCreated(bytes32 indexed positionId);
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
    event TokensWithdrawn(address indexed to, uint256 amount0, uint256 amount1);
    event LiquidityUpdated(bytes32 indexed positionId, uint128 newLiquidity);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                noOp: false,
                accessLock: false
            });
    }

    /// @notice Creates a new liquidity position
    /// @dev Stores position with unique ID and registers in pool
    function createPosition(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external nonReentrant {
        bytes32 positionId = _getPositionId(msg.sender, key, lower, upper);
        require(positions[positionId].owner == address(0), "Position exists");

        bytes32 poolId = _getPoolId(key);
        poolStates[poolId].positionIds.push(positionId);
        poolStates[poolId].totalLiquidity += liquidity;

        // Transfer tokens from user to this contract
        (uint256 amount0, uint256 amount1) = _calculateAmountsForLiquidity(
            key,
            lower,
            upper,
            liquidity
        );
        ERC20(Currency.unwrap(key.currency0)).transferFrom(
            msg.sender,
            address(this),
            amount0
        );
        ERC20(Currency.unwrap(key.currency1)).transferFrom(
            msg.sender,
            address(this),
            amount1
        );

        // Add liquidity to the pool
        ERC20(Currency.unwrap(key.currency0)).approve(
            address(poolManager),
            amount0
        );
        ERC20(Currency.unwrap(key.currency1)).approve(
            address(poolManager),
            amount1
        );

        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        positions[positionId] = Position({
            owner: msg.sender,
            lowerTick: lower,
            upperTick: upper,
            liquidity: liquidity,
            fees0: 0,
            fees1: 0,
            lastCompound: block.timestamp
        });

        emit PositionCreated(positionId);
    }

    /// @notice Hook executed after position modification
    function afterModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        nonReentrant
        returns (bytes4, BalanceDelta)
    {
        bytes32 positionId = _getPositionId(
            sender,
            key,
            params.tickLower,
            params.tickUpper
        );

        Position storage pos = positions[positionId];

        // Only process existing positions
        if (pos.owner != address(0)) {
            // Check if compounding is needed
            if (block.timestamp >= pos.lastCompound + MIN_COMPOUND_INTERVAL) {
                _compoundFees(key, positionId);
            }

            // Check if rebalancing is needed
            _rebalancePosition(key, positionId);
        }

        return (this.afterModifyPosition.selector, BalanceDelta.wrap(0));
    }

    /// @notice Hook executed after swaps to distribute fees
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager nonReentrant returns (bytes4, int128) {
        (uint256 fee0, uint256 fee1) = _calculateSwapFees(key, params, delta);
        _distributeFeesToActivePositions(key, fee0, fee1);

        return (this.afterSwap.selector, 0);
    }

    // ================= INTERNAL FUNCTIONS ================= //

    /// @dev Compounds accumulated fees into additional liquidity
    function _compoundFees(PoolKey calldata key, bytes32 positionId) internal {
        Position storage pos = positions[positionId];
        if (pos.fees0 == 0 && pos.fees1 == 0) return;

        // Get current position fees
        uint256 fee0 = pos.fees0;
        uint256 fee1 = pos.fees1;

        // Reset fees
        pos.fees0 = 0;
        pos.fees1 = 0;

        // Update total fees
        totalFees0[Currency.unwrap(key.currency0)] -= fee0;
        totalFees1[Currency.unwrap(key.currency1)] -= fee1;

        // Calculate new liquidity from fees
        uint128 additionalLiquidity = _calculateLiquidityFromAmounts(
            key,
            pos.lowerTick,
            pos.upperTick,
            fee0,
            fee1
        );

        if (additionalLiquidity > 0) {
            // Add new liquidity to the pool
            ERC20(Currency.unwrap(key.currency0)).approve(
                address(poolManager),
                fee0
            );
            ERC20(Currency.unwrap(key.currency1)).approve(
                address(poolManager),
                fee1
            );

            poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos.lowerTick,
                    tickUpper: pos.upperTick,
                    liquidityDelta: int256(uint256(additionalLiquidity)),
                    salt: bytes32(0)
                }),
                bytes("")
            );

            // Update position
            pos.liquidity += additionalLiquidity;

            // Update pool state
            bytes32 poolId = _getPoolId(key);
            poolStates[poolId].totalLiquidity += additionalLiquidity;

            // Update last compound time
            pos.lastCompound = block.timestamp;

            emit FeesCompounded(positionId, fee0, fee1);
            emit LiquidityUpdated(positionId, pos.liquidity);
        }
    }

    /// @dev Rebalances position based on current price
    function _rebalancePosition(
        PoolKey calldata key,
        bytes32 positionId
    ) internal {
        Position storage pos = positions[positionId];
        if (pos.liquidity == 0) return;

        (int24 currentTick, ) = _getCurrentTick(key);

        if (
            !_needsRebalance(
                pos.lowerTick,
                pos.upperTick,
                currentTick,
                key.tickSpacing
            )
        ) {
            return;
        }

        // Remove existing liquidity
        uint256 amount0;
        uint256 amount1;

        {
            BalanceDelta delta = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos.lowerTick,
                    tickUpper: pos.upperTick,
                    liquidityDelta: -int256(uint256(pos.liquidity)),
                    salt: bytes32(0)
                }),
                bytes("")
            );

            // Get removed token amounts
            amount0 = uint256(uint128(BalanceDelta.unwrap(delta).amount0()));
            amount1 = uint256(uint128(BalanceDelta.unwrap(delta).amount1()));
        }

        // Calculate new range centered around current tick
        (int24 newLower, int24 newUpper) = _calculateNewRange(
            currentTick,
            key.tickSpacing
        );

        // Add liquidity in new range
        uint128 newLiquidity = _calculateLiquidityFromAmounts(
            key,
            newLower,
            newUpper,
            amount0,
            amount1
        );

        // Ensure we don't lose too much in the rebalance
        uint128 minLiquidity = (pos.liquidity * (10_000 - SLIPPAGE_TOLERANCE)) /
            10_000;
        require(newLiquidity >= minLiquidity, "Slippage limit exceeded");

        {
            // Add new liquidity
            ERC20(Currency.unwrap(key.currency0)).approve(
                address(poolManager),
                amount0
            );
            ERC20(Currency.unwrap(key.currency1)).approve(
                address(poolManager),
                amount1
            );

            poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: newLower,
                    tickUpper: newUpper,
                    liquidityDelta: int256(uint256(newLiquidity)),
                    salt: bytes32(0)
                }),
                bytes("")
            );
        }

        // Update position state
        pos.lowerTick = newLower;
        pos.upperTick = newUpper;
        pos.liquidity = newLiquidity;

        emit PositionRebalanced(positionId, newLower, newUpper);
        emit LiquidityUpdated(positionId, newLiquidity);
    }

    /// @dev Distributes fees to active positions based on their share of liquidity
    function _distributeFeesToActivePositions(
        PoolKey calldata key,
        uint256 fee0,
        uint256 fee1
    ) internal {
        if (fee0 == 0 && fee1 == 0) return;

        bytes32 poolId = _getPoolId(key);
        PoolState storage pool = poolStates[poolId];

        if (pool.totalLiquidity == 0 || pool.positionIds.length == 0) return;

        uint256 start = pool.lastProcessedIndex;
        uint256 end = _min(
            start + MAX_POSITIONS_PER_TX,
            pool.positionIds.length
        );

        for (uint256 i = start; i < end; i++) {
            bytes32 positionId = pool.positionIds[i];
            Position storage pos = positions[positionId];

            if (_isPositionActive(pos, key)) {
                uint256 share0 = (fee0 * pos.liquidity) / pool.totalLiquidity;
                uint256 share1 = (fee1 * pos.liquidity) / pool.totalLiquidity;

                if (share0 > 0 || share1 > 0) {
                    pos.fees0 += share0;
                    pos.fees1 += share1;
                    totalFees0[Currency.unwrap(key.currency0)] += share0;
                    totalFees1[Currency.unwrap(key.currency1)] += share1;
                }
            }
        }

        // Update processing index for next time
        pool.lastProcessedIndex = end >= pool.positionIds.length ? 0 : end;
    }

    // ================= HELPER FUNCTIONS ================= //

    /// @dev Checks if position is currently active (in range)
    function _isPositionActive(
        Position storage pos,
        PoolKey calldata key
    ) internal view returns (bool) {
        (int24 currentTick, ) = _getCurrentTick(key);
        return currentTick >= pos.lowerTick && currentTick <= pos.upperTick;
    }

    /// @dev Checks if position needs rebalancing
    function _needsRebalance(
        int24 lower,
        int24 upper,
        int24 current,
        int24 spacing
    ) internal pure returns (bool) {
        int24 range = upper - lower;
        int24 buffer = spacing * 10; // Buffer of 10 ticks

        // Rebalance if price is in the outer 20% of the range
        return (current >= upper - buffer) || (current <= lower + buffer);
    }

    /// @dev Calculates new range centered around current tick
    function _calculateNewRange(
        int24 currentTick,
        int24 spacing
    ) internal pure returns (int24 newLower, int24 newUpper) {
        // Create a range centered around current tick
        int24 halfRange = 60 * spacing; // 60 tick spacing units on each side

        // Round to nearest valid tick
        newLower = ((currentTick - halfRange) / spacing) * spacing;
        newUpper = ((currentTick + halfRange) / spacing) * spacing;
    }

    /// @dev Calculate swap fees based on swap parameters and delta
    function _calculateSwapFees(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) internal pure returns (uint256 fee0, uint256 fee1) {
        // Get absolute swap amount
        uint256 amount0 = params.zeroForOne
            ? uint256(uint128(-BalanceDelta.unwrap(delta).amount0()))
            : 0;
        uint256 amount1 = !params.zeroForOne
            ? uint256(uint128(-BalanceDelta.unwrap(delta).amount1()))
            : 0;

        // Calculate fees based on pool fee tier
        fee0 = (amount0 * key.fee) / 1_000_000;
        fee1 = (amount1 * key.fee) / 1_000_000;
    }

    /// @dev Gets current tick from pool
    function _getCurrentTick(
        PoolKey calldata key
    ) internal view returns (int24 tick, uint160 sqrtPriceX96) {
        (sqrtPriceX96, tick, , , ) = poolManager.getSlot0(key);
    }

    /// @dev Calculates liquidity from token amounts
    function _calculateLiquidityFromAmounts(
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128 liquidity) {
        (uint160 sqrtPriceX96, ) = _getCurrentTick(key);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        );
    }

    /// @dev Calculates token amounts needed for given liquidity
    function _calculateAmountsForLiquidity(
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96, ) = _getCurrentTick(key);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );

        amount1 = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
    }

    /// @dev Generates position ID using cryptographic hashing
    function _getPositionId(
        address owner,
        PoolKey calldata key,
        int24 lower,
        int24 upper
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    owner,
                    Currency.unwrap(key.currency0),
                    Currency.unwrap(key.currency1),
                    lower,
                    upper
                )
            );
    }

    /// @dev Generates pool ID for internal tracking
    function _getPoolId(PoolKey calldata key) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    Currency.unwrap(key.currency0),
                    Currency.unwrap(key.currency1)
                )
            );
    }

    /// @dev Min function to replace Math.min
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
