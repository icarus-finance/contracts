// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ILpCandy} from "./ILpCandy.sol";

interface INFPositionManager {
    function positions(uint256 _position_id) external view returns (ILpCandy.PositionData memory);
    function tokenOfOwnerByIndex(address _account, uint256 _index) external view returns (uint256);
    function balanceOf(address _account) external view returns (uint256);
    function factory() external view returns (address);
    function userPositions(address _account, address _pool) external view returns (uint256[] memory);
}