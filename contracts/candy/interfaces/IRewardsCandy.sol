// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IRewardsCandy {
    struct LpEpochReward {
        address token;
        uint256 amount;
    }

    struct LpEpoch {
        uint256 ts;
        address lp;
        uint256 votes;
        uint256 emissions;
        LpEpochReward[] bribes;
        LpEpochReward[] fees;
    }

    struct Reward {
        uint256 venft_id;
        address lp;
        uint256 amount;
        address token;
        address fee;
        address bribe;
    }
}
