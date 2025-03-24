// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract MockPoolManager {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 protocolFee;
        uint16 swapFee;
        bool unlocked;
    }

    mapping(bytes32 => Slot0) public slots;

    function modifyLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        // Mock implementation - return some reasonable values
        return BalanceDelta.wrap(int256(params.liquidityDelta));
    }

    function getSlot0(
        PoolKey calldata key
    )
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 protocolFee,
            uint16 swapFee,
            bool unlocked
        )
    {
        Slot0 memory slot = slots[keccak256(abi.encode(key))];
        return (
            slot.sqrtPriceX96 == 0
                ? 79228162514264337593543950336
                : slot.sqrtPriceX96, // Default to 1:1 price
            slot.tick,
            slot.protocolFee,
            slot.swapFee,
            true
        );
    }

    function swap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        // Mock implementation - return some reasonable values
        if (params.zeroForOne) {
            return BalanceDelta.wrap(int256(-1000));
        } else {
            return BalanceDelta.wrap(int256(1000));
        }
    }
}
