// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "prb-math/PRBMath.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IManagement.sol";

import "./lib/FixedPoint128.sol";
import "./lib/LiquidityMath.sol";
import "./lib/Math.sol";
import "./lib/Position.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "./lib/TransferHelper.sol";

contract UniswapV3Pool is IUniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    error AlreadyInitialized();
    error InsufficientInputAmount();
    error InvalidPriceLimit();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();
    error InvalidInvestor();
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );

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
    event TransferPlatformFee(address indexed feeAddress, uint256 feeRequested);
    // Pool parameters
    address public immutable factory;
    address public immutable token0; // UT
    address public immutable token1; // ST
    uint24 public immutable tickSpacing;
    uint24 public immutable fee;
    uint24 public platformFee;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    IManagement public management;
    uint256 public platformFeeAmount;

    // First slot will contain essential data
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 platformFee;
        uint128 liquidity;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 platformFeeAmount;
    }

    Slot0 public slot0;

    // Amount of liquidity, L.
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;
    modifier onlyContractManager() {
        require(
            management.isContractManager(msg.sender),
            "Caller is not contract manager"
        );
        _;
    }

    constructor() {
        (
            factory,
            token0,
            token1,
            tickSpacing,
            fee,
            platformFee
        ) = IUniswapV3PoolDeployer(msg.sender).parameters();
    }

    //检查白名单 trye-白名单或受限名单(卖出) false-白名单(买入,增减流动性)
    function checkInvestor(bool zeroForOne, address investor)
        public
        view
        returns (bool)
    {
        if (zeroForOne) {
            return
                management.isWhiteInvestor(investor) ||
                management.isRestrictInvestor(investor);
        } else {
            return management.isWhiteInvestor(investor);
        }
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    // 根据区间 和 流动性 计算需要支出的token数量
    function _modifyPosition(ModifyPositionParams memory params)
        internal
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        // gas optimizations
        Slot0 memory slot0_ = slot0;
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128;
        // 获取当前区间用户的流动性
        position = positions.get(
            params.owner,
            params.lowerTick,
            params.upperTick
        );
        // 更新tick 判断flag翻转
        bool flippedLower = ticks.update(
            params.lowerTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            false
        );
        bool flippedUpper = ticks.update(
            params.upperTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            true
        );

        if (flippedLower) {
            tickBitmap.flipTick(params.lowerTick, int24(tickSpacing));
        }

        if (flippedUpper) {
            tickBitmap.flipTick(params.upperTick, int24(tickSpacing));
        }
        // 获取fee
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks
            .getFeeGrowthInside(
                params.lowerTick,
                params.upperTick,
                slot0_.tick,
                feeGrowthGlobal0X128_,
                feeGrowthGlobal1X128_
            );

        position.update(
            params.liquidityDelta,
            feeGrowthInside0X128,
            feeGrowthInside1X128
        );

        if (slot0_.tick < params.lowerTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        } else if (slot0_.tick < params.upperTick) {
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                slot0_.sqrtPriceX96,
                params.liquidityDelta
            );

            liquidity = LiquidityMath.addLiquidity(
                liquidity,
                params.liquidityDelta
            );
        } else {
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        }
    }

    function mint(
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        if (checkInvestor(false, msg.sender)) revert InvalidInvestor();
        if (
            lowerTick >= upperTick ||
            lowerTick < TickMath.MIN_TICK ||
            upperTick > TickMath.MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();
        // 计算需要支出的数量
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount)
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

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

    // 销毁流动性 将流动性移到手续费
    function burn(
        int24 lowerTick,
        int24 upperTick,
        uint128 amount
    ) public returns (uint256 amount0, uint256 amount1) {
        if (checkInvestor(false, msg.sender)) revert InvalidInvestor();
        (
            Position.Info storage position,
            int256 amount0Int,
            int256 amount1Int
        ) = _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidityDelta: -(int128(amount))
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0) + uint128(amount1),
                position.tokensOwed1
            );
        }

        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public returns (uint128 amount0, uint128 amount1) {
        if (checkInvestor(false, recipient)) revert InvalidInvestor();
        Position.Info memory position = positions.get(
            msg.sender,
            lowerTick,
            upperTick
        );

        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(
            msg.sender,
            recipient,
            lowerTick,
            upperTick,
            amount0,
            amount1
        );
    }

    function swap(
        address recipient, // 接收方
        bool zeroForOne, // false -买，true -卖
        uint256 amountSpecified, // 数量
        uint160 sqrtPriceLimitX96, // 滑点限价
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        if (checkInvestor(zeroForOne, recipient)) revert InvalidInvestor();
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;
        // 根据买卖 检查当前限价
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0_.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0_.sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "SPL"
        );
        // 维护当前订单
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            platformFee: 0,
            liquidity: liquidity_
        });
        // 循环兑换 直到订单填满或达到限价
        while (
            state.amountSpecifiedRemaining > 0 &&
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            // 兑换信息
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 获取下个有流动性的tick,或者是word的最后一个tick
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                int24(tickSpacing),
                zeroForOne
            );
            // 获取tick价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // 计算兑换的 价格 数量和手续费
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount,
                step.platformFeeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    zeroForOne
                        ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                )
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee,
                platformFee
            );
            // 订单状态更新 卖单扣除OUT 买单扣除IN
            if (zeroForOne) {
                // 卖单
                state.amountSpecifiedRemaining -= step.amountIn;
                state.amountCalculated +=
                    step.amountOut -
                    step.feeAmount -
                    step.platformFeeAmount;
            } else {
                // 买单
                state.amountSpecifiedRemaining -=
                    step.amountIn +
                    step.feeAmount +
                    step.platformFeeAmount;
                state.amountCalculated += step.amountOut;
            }
            //累计协议的手续费
            state.platformFee += uint128(step.platformFeeAmount);
            // 计算每单位流动性获得的手续费
            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += PRBMath.mulDiv(
                    step.feeAmount,
                    FixedPoint128.Q128,
                    state.liquidity
                );
            }
            // 当价格达到边界 需要cross到下一个tick
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 获取下一个tick的流动性 并且在下一个tick中记录手续费 区分买卖收取的手续费
                int128 liquidityDelta = ticks.cross(
                    step.nextTick,
                    (
                        zeroForOne
                            ? state.feeGrowthGlobalX128
                            : feeGrowthGlobal0X128
                    ),
                    (
                        zeroForOne
                            ? feeGrowthGlobal1X128
                            : state.feeGrowthGlobalX128
                    )
                );
                // 如果是卖 说明流动性达到左边 加上相反的流动性
                if (zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(
                    state.liquidity,
                    liquidityDelta
                );
                // 这里为0 说明没有其他流动性区间了
                if (state.liquidity == 0) revert NotEnoughLiquidity();
                // 卖： tick是变小 区间是左闭右开 需要减一到达下一个区间
                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 价格没有到达边界 直接获取价格所在的tick
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        // 更新价格 和 更新tick
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }
        // 更新流动性
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;
        // 更新手续费
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }
        platformFeeAmount += state.platformFee;
        // 最终的数量
        (amount0, amount1) = zeroForOne
            ? (
                // 收取已经成交部分 总数量-已经填充数量
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );

        if (zeroForOne) {
            if (amount1 < 0)
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            // 金额校验
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            if (amount0 < 0)
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );

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
            state.liquidity,
            slot0.tick
        );
    }

    function transferPlatformFee(uint256 feeRequested)
        external
        onlyContractManager
        returns (uint256 amount)
    {
        amount = feeRequested > platformFeeAmount
            ? platformFeeAmount
            : feeRequested;
        address feeAddress;
        if (amount > 0) {
            feeAddress = management.platformFeeAddress();
            if (amount == platformFeeAmount) amount--; //slot不为0 可以节省gas
            platformFeeAmount -= amount;
            TransferHelper.safeTransfer(token0, feeAddress, amount);
        }

        emit TransferPlatformFee(feeAddress, amount);
    }

    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
