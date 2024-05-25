// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "prb-math/PRBMath.sol";

import "./FixedPoint128.sol";
import "./LiquidityMath.sol";

library Position {
    struct Info {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;//卖 累计手续费
        uint256 feeGrowthInside1LastX128;//买 累计手续费
        uint128 tokensOwed0;//存储的token0
        uint128 tokensOwed1;//存储的token1
    }

    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 lowerTick,
        int24 upperTick
    ) internal view returns (Position.Info storage position) {
        position = self[
            keccak256(abi.encodePacked(owner, lowerTick, upperTick))
        ];
    }

    //更新流动性产生的手续费 手续费最终都增加到tokensOwed0
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        //计算产生的费用
        uint128 tokensOwed0 = uint128(
            PRBMath.mulDiv(
                feeGrowthInside0X128 - self.feeGrowthInside0LastX128,
                self.liquidity,
                FixedPoint128.Q128
            )
        );
        uint128 tokensOwed1 = uint128(
            PRBMath.mulDiv(
                feeGrowthInside1X128 - self.feeGrowthInside1LastX128,
                self.liquidity,
                FixedPoint128.Q128
            )
        );

        self.liquidity = LiquidityMath.addLiquidity(
            self.liquidity,
            liquidityDelta
        );
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        if (tokensOwed0 > 0) {
            self.tokensOwed0 += tokensOwed0;
        }
        if (tokensOwed1 > 0) {
            self.tokensOwed0 += tokensOwed1;
        }
    }
}
