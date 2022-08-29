// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import {Test, stdError} from "forge-std/Test.sol";
import "./ERC20Mintable.sol";
import "./TestUtils.sol";

import "../src/lib/LiquidityMath.sol";
import "../src/UniswapV3Factory.sol";
import "../src/UniswapV3NFTManager.sol";

contract UniswapV3NFTManagerTest is Test, TestUtils {
    uint24 constant FEE = 3000;
    uint256 constant INIT_PRICE = 5000;
    uint256 constant USER_WETH_BALANCE = 1_000 ether;
    uint256 constant USER_USDC_BALANCE = 1_000_000 ether;

    ERC20Mintable weth;
    ERC20Mintable usdc;
    ERC20Mintable uni;
    UniswapV3Factory factory;
    UniswapV3Pool wethUSDC;
    UniswapV3NFTManager nft;

    bytes extra;

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 18);
        weth = new ERC20Mintable("Ether", "ETH", 18);

        factory = new UniswapV3Factory();
        nft = new UniswapV3NFTManager(address(factory));
        wethUSDC = deployPool(
            factory,
            address(weth),
            address(usdc),
            FEE,
            INIT_PRICE
        );

        weth.mint(address(this), USER_WETH_BALANCE);
        usdc.mint(address(this), USER_USDC_BALANCE);
        weth.approve(address(nft), type(uint256).max);
        usdc.approve(address(nft), type(uint256).max);

        extra = encodeExtra(address(weth), address(usdc), address(this));
    }

    function testMint() public {
        UniswapV3NFTManager.MintParams memory params = UniswapV3NFTManager
            .MintParams({
                recipient: address(this),
                tokenA: address(weth),
                tokenB: address(usdc),
                fee: FEE,
                lowerTick: tick60(4545),
                upperTick: tick60(5500),
                amount0Desired: 1 ether,
                amount1Desired: 5000 ether,
                amount0Min: 0,
                amount1Min: 0
            });
        uint256 tokenId = nft.mint(params);

        (uint256 expectedAmount0, uint256 expectedAmount1) = (
            0.987078348444137445 ether,
            5000 ether
        );

        assertEq(tokenId, 0, "invalid token id");

        assertMany(
            ExpectedMany({
                pool: wethUSDC,
                tokens: [weth, usdc],
                liquidity: liquidity(params, INIT_PRICE),
                sqrtPriceX96: sqrtP(INIT_PRICE),
                tick: tick(INIT_PRICE),
                fees: [uint256(0), 0],
                userBalances: [
                    USER_WETH_BALANCE - expectedAmount0,
                    USER_USDC_BALANCE - expectedAmount1
                ],
                poolBalances: [expectedAmount0, expectedAmount1],
                position: ExpectedPositionShort({
                    owner: address(nft),
                    ticks: [params.lowerTick, params.upperTick],
                    liquidity: liquidity(params, INIT_PRICE),
                    feeGrowth: [uint256(0), 0],
                    tokensOwed: [uint128(0), 0]
                }),
                ticks: mintParamsToTicks(params, INIT_PRICE),
                observation: ExpectedObservationShort({
                    index: 0,
                    timestamp: 1,
                    tickCumulative: 0,
                    initialized: true
                })
            })
        );

        assertNFTs(
            ExpectedNFTs({
                nft: nft,
                owner: address(this),
                tokens: nfts(
                    ExpectedNFT({
                        id: tokenId,
                        pool: address(wethUSDC),
                        lowerTick: params.lowerTick,
                        upperTick: params.upperTick
                    })
                )
            })
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function mintParamsToTicks(
        UniswapV3NFTManager.MintParams memory mint,
        uint256 currentPrice
    ) internal pure returns (ExpectedTickShort[2] memory ticks) {
        uint128 liq = liquidity(mint, currentPrice);

        ticks[0] = ExpectedTickShort({
            tick: mint.lowerTick,
            initialized: true,
            liquidityGross: liq,
            liquidityNet: int128(liq)
        });
        ticks[1] = ExpectedTickShort({
            tick: mint.upperTick,
            initialized: true,
            liquidityGross: liq,
            liquidityNet: -int128(liq)
        });
    }

    function liquidity(
        UniswapV3NFTManager.MintParams memory params,
        uint256 currentPrice
    ) internal pure returns (uint128 liquidity_) {
        liquidity_ = LiquidityMath.getLiquidityForAmounts(
            sqrtP(currentPrice),
            sqrtP60FromTick(params.lowerTick),
            sqrtP60FromTick(params.upperTick),
            params.amount0Desired,
            params.amount1Desired
        );
    }

    function nfts(ExpectedNFT memory nft_)
        internal
        pure
        returns (ExpectedNFT[] memory nfts_)
    {
        nfts_ = new ExpectedNFT[](1);
        nfts_[0] = nft_;
    }
}
