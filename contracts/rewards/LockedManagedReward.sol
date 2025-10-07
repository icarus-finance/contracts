// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import {ManagedReward} from "./ManagedReward.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

/// @notice Stores rewards that are max-locked (i.e. rebases / tokens that were compounded)
/// @dev Rewards are distributed based on weight contribution to managed nft
contract LockedManagedReward is ManagedReward {
    constructor(address _forwarder, address _voter) ManagedReward(_forwarder, _voter) {}

     modifier authorizedForOrVoter(address token) {
        if (_msgSender() != ve) revert NotVotingEscrow();
        if (token != IVotingEscrow(ve).token()) revert NotEscrowToken();
        _;
    }

    /// @inheritdoc ManagedReward
    /// @dev Called by VotingEscrow to retrieve locked rewards
    function getReward(uint256 tokenId, address[] memory tokens) external override nonReentrant authorizedForOrVoter(tokens[0]) {
        if (tokens.length != 1) revert NotSingleToken();
        _getReward(_msgSender(), tokenId, tokens, block.timestamp);
    }

    /// @inheritdoc ManagedReward
    /// @dev Called by VotingEscrow to retrieve locked rewards
    function getRewardUntilTs(uint256 tokenId, address[] memory tokens, uint256 timestamp) external override nonReentrant authorizedForOrVoter(tokens[0]) {
        if (tokens.length != 1) revert NotSingleToken();
        _getReward(_msgSender(), tokenId, tokens, timestamp);
    }

    /// @inheritdoc ManagedReward
    /// @dev Called by VotingEscrow to add rebases / compounded rewards for disbursement
    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant authorizedForOrVoter(token){
        _notifyRewardAmount(_msgSender(), token, amount);
    }
}
