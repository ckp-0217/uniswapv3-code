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
        uint24 fee,
        uint24 platformFee
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount,
            uint256 platformFeeAmount
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
            feeAmount = Math.mulDivRoundingUp(amountRemaining, fee, 1e6);
            platformFeeAmount = Math.mulDivRoundingUp(
                amountRemaining,
                platformFee,
                1e6
            );
            amountRemainingLessFee =
                amountRemaining -
                feeAmount -
                platformFeeAmount;
        }

        // 根据方法计算可以填充多少In
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
        else
            // 如果In数量足够填充全部订单 说明价格会在区间内部
            // 计算出兑换后的价格
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
                sqrtPriceCurrentX96,
                liquidity,
                amountRemainingLessFee,
                zeroForOne
            );
        //判断价格是否达到区间边缘,也就是消耗了当前所有的流动性
        bool max = sqrtPriceNextX96 == sqrtPriceTargetX96;
        //计算 到兑换的价格可以提供多少的In和Out
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
            // 卖单手续费计算
            feeAmount = Math.mulDivRoundingUp(amountOut, fee, 1e6);
            platformFeeAmount = Math.mulDivRoundingUp(
                amountOut - feeAmount,
                platformFee,
                1e6
            );
        } else {
            // 买单手续费计算
            // 这里的amountIn 是扣除了手续费之后的
            // 如果没有达到价格边缘 直接返回前面计算好的流动性
            if (max) {
                //达到了边缘 根据In反推手续费
                feeAmount = Math.mulDivRoundingUp(
                    amountIn,
                    fee,
                    1e6 - fee - platformFee
                );
                platformFeeAmount = Math.mulDivRoundingUp(
                    amountIn,
                    platformFee,
                    1e6 - fee - platformFee
                );
            }
        }
    }
}
