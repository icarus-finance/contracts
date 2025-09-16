// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ILpCandy} from "./ILpCandy.sol";

interface ISlipstreamHelper {
    function getAmountsForLiquidity(uint160 _ratio, uint160 _ratioA, uint160 _ratioB, uint128 _liquidity) external view returns (ILpCandy.Amounts memory);
    function getSqrtRatioAtTick(int24 _tick) external view returns (uint160);
    function principal(address _nfpm, uint256 _position_id, uint160 _ratio) external view returns (ILpCandy.Amounts memory);
    function fees(address _nfpm, uint256 _position_id) external view returns (ILpCandy.Amounts memory);
    function poolFees(address _pool, uint128 _liquidity, int24 _current_tick, int24 _lower_tick, int24 _upper_tick) external view returns (ILpCandy.Amounts memory);
}
