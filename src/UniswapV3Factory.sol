// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./UniswapV3Pool.sol";

contract UniswapV3Factory is IUniswapV3PoolDeployer {
    error PoolAlreadyExists();
    error ZeroAddressNotAllowed();
    error TokensMustBeDifferent();
    error UnsupportedTickSpacing();

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed tickSpacing,
        uint24 fee,
        uint24 platformFee,
        address pool
    );

    PoolParameters public parameters;

    function createAMMPair(
        string memory name,
        address issuer,
        address tokenA,
        address tokenB,
        address management,
        uint256[] memory params //0-tickSpacings 0-fee 1-platformFee
    ) public returns (address pool) {
        if (tokenA == tokenB) revert TokensMustBeDifferent();
        if (tokenA == address(0)) revert ZeroAddressNotAllowed();
        uint24 tickSpacing_ = uint24(params[0]);
        uint24 fee_ = uint24(params[1]);
        uint24 platformFee_ = uint24(params[2]);
        // string memory name,
        // address issuer,
        // address token0,
        // address token1,
        // address management,
        // uint24 tickSpacing,
        // uint24 fee,
        // uint24 platformFee
        parameters = PoolParameters({
            name: name,
            issuer: issuer,
            token0: tokenA,
            token1: tokenB,
            management: management,
            tickSpacing: tickSpacing_,
            fee: fee_,
            platformFee: platformFee_
        });

        pool = address(
            new UniswapV3Pool{
                salt: keccak256(abi.encodePacked(tokenA, tokenB))
            }()
        );

        delete parameters;

        emit PoolCreated(
            tokenA,
            tokenB,
            tickSpacing_,
            fee_,
            platformFee_,
            pool
        );
    }
}
