// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IRewards {
    function rewards(uint256 index) external view returns (address);
}