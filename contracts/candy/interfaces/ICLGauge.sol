// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ICLGauge {
    function earned(address _account, uint256 _position_id) external view returns (uint256);
    function rewards(uint256 _position_id) external view returns (uint256);
    function rewardRate() external view returns (uint256);
    function rewardRateByEpoch(uint256 _ts) external view returns (uint256);
    function rewardToken() external view returns (address);
    function feesVotingReward() external view returns (address);
    function stakedContains(address _account, uint256 _position_id) external view returns (bool);
    function stakedValues(address _account) external view returns (uint256[] memory);
    function periodFinish() external view returns (uint256);
}
