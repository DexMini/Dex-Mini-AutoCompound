// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap-periphery/base/hooks/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract AutoCompoundHook is BaseHook, ReentrancyGuard {
    using Hooks for IPoolManager;

    uint32 public constant TWAP_WINDOW = 180; // 3 minutes
    uint24 public constant MAX_TICK_DEVIATION = 50; // 0.5% price deviation

    struct Position {
        uint256 nftId;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint256 fees0;
        uint256 fees1;
        uint256 lastCompound;
    }

    mapping(bytes32 => Position) public positions;
    mapping(uint256 => bytes32) public positionIds;
    IERC721 public immutable positionNFT;

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

    constructor(
        IPoolManager _poolManager,
        IERC721 _nft
    ) BaseHook(_poolManager) {
        positionNFT = _nft;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: true,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function afterModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata,
        int256
    ) external override onlyPoolManager nonReentrant {
        bytes32 positionId = keccak256(abi.encode(key));
        _rebalancePosition(key, positionId);
        _compoundFees(key, positionId);
    }

    function createPosition(
        IPoolManager.PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 nftId
    ) external {
        require(positionNFT.ownerOf(nftId) == msg.sender, "Not NFT owner");
        bytes32 positionId = keccak256(abi.encode(key));
        positions[positionId] = Position({
            nftId: nftId,
            lowerTick: lower,
            upperTick: upper,
            liquidity: liquidity,
            fees0: 0,
            fees1: 0,
            lastCompound: block.timestamp
        });
        positionIds[nftId] = positionId;
    }

    // Core logic
    function _rebalancePosition(
        IPoolManager.PoolKey calldata key,
        bytes32 positionId
    ) internal {
        Position storage pos = positions[positionId];
        if (pos.liquidity == 0) return;

        (int24 twapTick, int24 currentTick) = _getTWAP(key);
        int24 safeTick = _abs(currentTick - twapTick) < MAX_TICK_DEVIATION
            ? currentTick
            : twapTick;

        if (
            _needsRebalance(
                pos.lowerTick,
                pos.upperTick,
                safeTick,
                key.tickSpacing
            )
        ) {
            // Remove liquidity
            poolManager.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams({
                    tickLower: pos.lowerTick,
                    tickUpper: pos.upperTick,
                    liquidityDelta: -int128(pos.liquidity)
                })
            );

            // Calculate new range
            (int24 newLower, int24 newUpper) = _calculateNewRange(
                safeTick,
                key.tickSpacing
            );

            // Add new liquidity
            poolManager.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams({
                    tickLower: newLower,
                    tickUpper: newUpper,
                    liquidityDelta: int128(pos.liquidity)
                })
            );

            // Update position
            pos.lowerTick = newLower;
            pos.upperTick = newUpper;
            emit PositionRebalanced(positionId, newLower, newUpper);
        }
    }

    function _compoundFees(
        IPoolManager.PoolKey calldata key,
        bytes32 positionId
    ) internal {
        Position storage pos = positions[positionId];
        if (block.timestamp < pos.lastCompound + 1 hours) return;

        (uint128 fees0, uint128 fees1) = _collectFees(key, positionId);

        if (fees0 > 0 || fees1 > 0) {
            // Verify price stability before compounding
            (int24 twapTick, int24 currentTick) = _getTWAP(key);
            require(
                _abs(currentTick - twapTick) < MAX_TICK_DEVIATION,
                "Price volatile"
            );

            // Reinvest fees
            pos.liquidity += uint128((uint256(fees0) + fees1) / 2);
            pos.lastCompound = block.timestamp;
            emit FeesCompounded(positionId, fees0, fees1);
        }
    }

    // Internal helpers
    function _collectFees(
        IPoolManager.PoolKey calldata key,
        bytes32 positionId
    ) internal returns (uint128, uint128) {
        Position storage pos = positions[positionId];
        (uint128 fees0, uint128 fees1) = (pos.fees0, pos.fees1);

        poolManager.collectFee(key, address(this), fees0, fees1);
        pos.fees0 = 0;
        pos.fees1 = 0;

        return (fees0, fees1);
    }

    function _getTWAP(
        IPoolManager.PoolKey calldata key
    ) internal view returns (int24 twapTick, int24 currentTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = poolManager.observe(
            key,
            secondsAgos
        );
        twapTick = int24(
            (tickCumulatives[1] - tickCumulatives[0]) /
                int56(uint56(TWAP_WINDOW))
        );
        currentTick = poolManager.getCurrentTick(key);
    }

    function _needsRebalance(
        int24 lower,
        int24 upper,
        int24 current,
        int24 spacing
    ) internal pure returns (bool) {
        int24 buffer = spacing * 10;
        return (current >= upper - buffer) || (current <= lower + buffer);
    }

    function _calculateNewRange(
        int24 currentTick,
        int24 spacing
    ) internal pure returns (int24, int24) {
        return (currentTick - spacing * 10, currentTick + spacing * 10);
    }

    function _abs(int24 value) internal pure returns (int24) {
        return value >= 0 ? value : -value;
    }
}
