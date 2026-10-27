// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILpCandy} from "./ILpCandy.sol";
import {IReward} from "../../interfaces/IReward.sol";

interface IBribe {
    function supplyCheckpoints(uint256 index) external view returns (IReward.SupplyCheckpoint memory);
}
