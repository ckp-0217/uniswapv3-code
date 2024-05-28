// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "./ERC20Mintable.sol";
import "./TestUtils.sol";

import "../src/interfaces/IUniswapV3Pool.sol";
import "../src/UniswapV3Factory.sol";
import "../src/UniswapV3Pool.sol";

contract UniswapV3FactoryTest is Test, TestUtils {
    ERC20Mintable weth;
    ERC20Mintable usdc;
    UniswapV3Factory factory;
    string name;
    address issuer;
    address management;
    uint256[] params;

    function setUp() public {
        name = "usdc-weth";
        issuer = 0x0000000000000000000000000000000000000000;
        weth = new ERC20Mintable("Ether", "ETH", 18);
        usdc = new ERC20Mintable("USDC", "USDC", 18);
        factory = new UniswapV3Factory();
        management = 0x0000000000000000000000000000000000000001;
        params[0] = 10;
        params[1] = 2000; //0.2%
        params[2] = 1000; //0.1%
    }

    function testcreateAMMPair() public {
        address poolAddress = factory.createAMMPair(
            name,
            issuer,
            address(usdc),
            address(weth),
            management,
            params
        );

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        assertEq(pool.name(), name, "invalid name ");
        assertEq(pool.issuer(), issuer, "invalid issuer address");
        assertEq(pool.token0(), address(usdc), "invalid weth address");
        assertEq(pool.token1(), address(weth), "invalid usdc address");
        assertEq(pool.management(), management, "invalid management address");
        assertEq(pool.tickSpacing(), 10, "invalid tick spacing");
        assertEq(pool.fee(), 2000, "invalid fee");
        assertEq(pool.platformFee(), 2000, "invalid platformFee");

        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(sqrtPriceX96, 0, "invalid sqrtPriceX96");
        assertEq(tick, 0, "invalid tick");
    }

    function testcreateAMMPairIdenticalTokens() public {
        vm.expectRevert(encodeError("TokensMustBeDifferent()"));
        factory.createAMMPair(
            name,
            issuer,
            address(usdc),
            address(weth),
            management,
            params
        );
    }

    function testCreateZeroTokenAddress() public {
        vm.expectRevert(encodeError("ZeroAddressNotAllowed()"));
        factory.createAMMPair(
            name,
            issuer,
            address(usdc),
            address(weth),
            management,
            params
        );
    }

    function testCreateAlreadyExists() public {
        factory.createAMMPair(
            name,
            issuer,
            address(usdc),
            address(weth),
            management,
            params
        );
        vm.expectRevert(encodeError("PoolAlreadyExists()"));
        factory.createAMMPair(
            name,
            issuer,
            address(usdc),
            address(weth),
            management,
            params
        );
    }
}
