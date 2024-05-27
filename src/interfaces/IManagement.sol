// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

interface IManagement {
    
    function platformFeeAddress() external view returns (address);

    function isContractManager(address manager) external view returns (bool);

    function isWhiteInvestor(address investor) external view returns (bool);

    function isRestrictInvestor(address investor) external view returns (bool);

    function isWhiteContract(address contractAddress) external view returns (bool);
    
    function isBlockInvestor(address investor) external view returns (bool);

    
}
