// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";

import "./lib/Math.sol";
import "./lib/Position.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";

contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    error InsufficientInputAmount();
    error InvalidTickRange();
    error ZeroLiquidity();

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Pool tokens, immutable
    address public immutable token0;
    address public immutable token1;

    // First slot will contain essential data
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
    }

    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    Slot0 public slot0;

    // Amount of liquidity, L.
    uint128 public liquidity; //总的流动性

    mapping(int24 => Tick.Info) public ticks; //记录所有的流动性
    mapping(int16 => uint256) public tickBitmap; //位图记录是否有流动性
    mapping(bytes32 => Position.Info) public positions; //记录用户的流动性

    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96,
        int24 tick
    ) {
        token0 = token0_;
        token1 = token1_;

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    function mint(
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < MIN_TICK ||
            upperTick > MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();
        //当前的价格区间
        Slot0 memory slot0_ = slot0;
        //计算当前价格到 流动性边界需要的amount
        //当前价到 区间顶部需要多少amount0
        //判断流动性区间和现价的关系
        if (slot0_.tick < lowerTick) {
            //流动性是高过现价 只需要提供a0
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );
        } else if (slot0_.tick < upperTick) {
            //流动性是包含现价
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(lowerTick),
                amount
            );
            //更新现在的流动性
            //更新数量
            liquidity += uint128(amount);
        } else {
            //流动性是低于现价 只要a1
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(lowerTick),
                amount
            );
        }

        //当前价到 区间底部需要多少amount1

        //更新两端流动性

        bool flippedLower = ticks.update(lowerTick, amount);
        bool flippedUpper = ticks.update(upperTick, amount);
        //流动性反转
        if (flippedLower) {
            tickBitmap.flipTick(lowerTick, 1);
        }

        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, 1);
        }
        //更新当前用户的流动性
        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);

        //调用回调
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();

        emit Mint(
            msg.sender,
            owner,
            lowerTick,
            upperTick,
            amount,
            amount0,
            amount1
        );
    }

    function swap(
        address recipient, //接收地址
        bool zeroForOne, //兑换方向
        uint256 amountSpecified, //兑换数量
        bytes calldata data //calldate信息
    ) public returns (int256 amount0, int256 amount1) {
        // 获取当前价格
        Slot0 memory slot0_ = slot0;

        //初始化兑换信息
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });
        //直到用于兑换的token耗尽
        while (state.amountSpecifiedRemaining > 0) {
            StepState memory step; //维护当前循环
            //获取起始价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            //寻找下一个tick
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                zeroForOne
            );
            //获取下一个tick的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            //计算当前价格区间到下个价格区间可以取出 多少流动性
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    step.sqrtPriceStartX96,
                    step.sqrtPriceNextX96,
                    liquidity, //这里假定只有一个流动性区间
                    state.amountSpecifiedRemaining
                );
            //调整当前的state 剩余和累计
            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            //调整tick
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }
        //如果交易后 离开了当前流动性区间 价格和区间需要修正
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }
        //调用callback
        (amount0, amount1) = zeroForOne
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
