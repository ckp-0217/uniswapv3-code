// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut
        )
    {
        //计算买卖方向
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        //根据当前流动性和当前价格 和数量计算出 兑换后的价格△p
        sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
            sqrtPriceCurrentX96,
            liquidity,
            amountRemaining,
            zeroForOne
        );
        //计算 达到兑换后的价格 接收和支出的amount
        amountIn = Math.calcAmount0Delta(
            sqrtPriceCurrentX96,
            sqrtPriceNextX96,
            liquidity
        );
        amountOut = Math.calcAmount1Delta(
            sqrtPriceCurrentX96,
            sqrtPriceNextX96,
            liquidity
        );

        if (!zeroForOne) {
            (amountIn, amountOut) = (amountOut, amountIn);
        }
    }
}
