// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

interface IUniswapV3PoolDeployer {
    struct PoolParameters {
        string name;
        address issuer;
        address token0;
        address token1;
        address management;
        uint24 tickSpacing;
        uint24 fee;
        uint24 platformFee;
    }

    function parameters()
        external
        returns (
            string memory name,
            address issuer,
            address token0,
            address token1,
            address management,
            uint24 tickSpacing,
            uint24 fee,
            uint24 platformFee
        );
}
