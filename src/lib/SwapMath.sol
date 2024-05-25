// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    // 根据价格 流动性 计算兑换的资金数量
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint24 fee
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        // 判断买卖方向
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        uint256 amountRemainingLessFee;
        if (zeroForOne) {
            // 卖单最后扣除手续费
            amountRemainingLessFee = amountRemaining;
        } else {
            // 买单提前扣除手续费
            amountRemainingLessFee = PRBMath.mulDiv(
                amountRemaining,
                1e6 - fee,
                1e6
            );
        }

        // 根据方法计算可以销毁多少In
        amountIn = zeroForOne
            ? Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity,
                true
            )
            : Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity,
                true
            );
        if (amountRemainingLessFee >= amountIn)
            // 如果In数量不足够填充全部订单 说明消耗当前区间所有流动性 价格达到区间边缘
            sqrtPriceNextX96 = sqrtPriceTargetX96;
            // 如果In数量足够填充全部订单 说明价格会在区间内部
            // 计算出兑换后的价格
        else
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
                sqrtPriceCurrentX96,
                liquidity,
                amountRemainingLessFee,
                zeroForOne
            );
        //判断价格是否达到区间边缘,也就是消耗了当前所有的流动性
        bool max = sqrtPriceNextX96 == sqrtPriceTargetX96;
        //根据 计算 到兑换的价格可以提供多少的In(扣除手续费后)和Out
        if (zeroForOne) {
            amountIn = max
                ? amountIn
                : Math.calcAmount0Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    true
                );
            amountOut = Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceNextX96,
                liquidity,
                false
            );
        } else {
            amountIn = max
                ? amountIn
                : Math.calcAmount1Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    true
                );
            amountOut = Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceNextX96,
                liquidity,
                false
            );
        }

        if (zeroForOne) {
            //卖单手续费计算
            uint256 amountOutLessFee = PRBMath.mulDiv(
                amountOut,
                1e6 - fee,
                1e6
            );
            feeAmount = amountOutLessFee - amountOut;
            amountOut = amountOutLessFee;
        } else {
            //买单手续费计算
            //这里的amountIn 是扣除了手续费之后的
            //如果没有达到价格边缘 实际收取的手续费 返回差额
            //达到了边缘 根据In反推手续费
            if (!max) {
                feeAmount = amountRemaining - amountIn;
            } else {
                feeAmount = Math.mulDivRoundingUp(amountIn, fee, 1e6 - fee);
            }
        }
    }
}
