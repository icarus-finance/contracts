// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILpCandy} from "./ILpCandy.sol";

interface ICandyPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
    function claimable0(address _account) external view returns (uint256);
    function claimable1(address _account) external view returns (uint256);
    function supplyIndex0(address _account) external view returns (uint256);
    function supplyIndex1(address _account) external view returns (uint256);
    function index0() external view returns (uint256);
    function index1() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function stable() external view returns (bool);
    function balanceOf(address _account) external view returns (uint256);
    function poolFees() external view returns (address);
    function gauge() external view returns (address); // fetches gauge from CL pool
    function tickSpacing() external view returns (int24); // CL tick spacing
    function slot0() external view returns (ILpCandy.Slot memory); // CL slot data
    function gaugeFees() external view returns (ILpCandy.GaugeFees memory); // CL gauge fees amounts
    function fee() external view returns (uint24); // CL fee level
    function unstakedFee() external view returns (uint24); // CL unstaked fee level
    function liquidity() external view returns (uint128); // CL active liquidity
    function stakedLiquidity() external view returns (uint128); // CL active staked liquidity
    function factory() external view returns (address); // CL factory address
}
