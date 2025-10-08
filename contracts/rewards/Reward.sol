// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReward} from "../interfaces/IReward.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title Reward
/// @author icarus.finance, velodrome.finance, @figs999, @pegahcarter
/// @notice Base reward contract for distribution of rewards
abstract contract Reward is IReward, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IReward
    uint256 public constant DURATION = 7 days;

    /// @inheritdoc IReward
    address public immutable voter;
    /// @inheritdoc IReward
    address public immutable ve;
    /// @inheritdoc IReward
    address public authorized;

    /// @inheritdoc IReward
    uint256 public totalSupply;
    /// @inheritdoc IReward
    mapping(uint256 => uint256) public balanceOf;
    /// @inheritdoc IReward
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;
    /// @inheritdoc IReward
    mapping(address => mapping(uint256 => uint256)) public lastEarn;
    /// @inheritdoc IReward
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsRemainingAccScaled;

    address[] public rewards;
    /// @inheritdoc IReward
    mapping(address => bool) public isReward;

    /// @notice A record of balance checkpoints for each account, by index
    mapping(uint256 => mapping(uint256 => Checkpoint)) public checkpoints;
    /// @inheritdoc IReward
    mapping(uint256 => uint256) public numCheckpoints;
    /// @notice A record of balance checkpoints for each token, by index
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    /// @inheritdoc IReward
    uint256 public supplyNumCheckpoints;

    /// @notice Scale factor for rewards remaining
    uint256 private constant REWARDS_REMAINING_SCALE = 1e18;

    constructor(address _forwarder, address _voter) ERC2771Context(_forwarder) {
        voter = _voter;
        ve = IVoter(_voter).ve();
    }

    /// @inheritdoc IReward
    function getPriorBalanceIndex(uint256 tokenId, uint256 timestamp) public view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[tokenId];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[tokenId][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[tokenId][0].timestamp > timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[tokenId][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    /// @inheritdoc IReward
    function getPriorSupplyIndex(uint256 timestamp) public view returns (uint256) {
        uint256 nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function _writeCheckpoint(uint256 tokenId, uint256 balance) internal {
        uint256 _nCheckPoints = numCheckpoints[tokenId];
        uint256 _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            ProtocolTimeLibrary.epochStart(checkpoints[tokenId][_nCheckPoints - 1].timestamp) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            checkpoints[tokenId][_nCheckPoints - 1] = Checkpoint(_timestamp, balance);
        } else {
            checkpoints[tokenId][_nCheckPoints] = Checkpoint(_timestamp, balance);
            numCheckpoints[tokenId] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        uint256 _nCheckPoints = supplyNumCheckpoints;
        uint256 _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            ProtocolTimeLibrary.epochStart(supplyCheckpoints[_nCheckPoints - 1].timestamp) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            supplyCheckpoints[_nCheckPoints - 1] = SupplyCheckpoint(_timestamp, totalSupply);
        } else {
            supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, totalSupply);
            supplyNumCheckpoints = _nCheckPoints + 1;
        }
    }

    /// @inheritdoc IReward
    function rewardsListLength() external view returns (uint256) {
        return rewards.length;
    }

    function earned(address token, uint256 tokenId) external view returns (uint256) {
        return _earned(token, tokenId, block.timestamp).unclaimedRewards;
    }

    function earnedUntilTs(address token, uint256 tokenId, uint256 timestamp) external view returns (uint256) {
        return _earned(token, tokenId, timestamp).unclaimedRewards;
    }

    function _earned(address token, uint256 tokenId, uint256 endTs) internal view returns (EarnedResult memory reward) {
        // Set default value to false
        reward = EarnedResult(0, 0, false);

        // If tokenId doesn't have any checkpoints, return false
        if (numCheckpoints[tokenId] == 0) {
            return EarnedResult(0, 0, false);
        }

        uint256 _supply = 1;
        uint256 _endTsEpoch = ProtocolTimeLibrary.epochStart(endTs);    // take epoch of provided endTs
        uint256 _currTs = ProtocolTimeLibrary.epochStart(lastEarn[token][tokenId]); // take epoch last claimed in as starting point
        uint256 _index = getPriorBalanceIndex(tokenId, _currTs);    // find index of checkpoint in epoch of last claim
        Checkpoint memory cp0 = checkpoints[tokenId][_index];   // get checkpoint at found index

        // accounts for case where lastEarn is before first checkpoint
        _currTs = Math.max(_currTs, ProtocolTimeLibrary.epochStart(cp0.timestamp));

        // if endTs is before lastEarn, return false
        if (_currTs > _endTsEpoch) return reward;

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 numEpochs = (_endTsEpoch - _currTs) / DURATION;

        uint256 accumulatedReward = 0;
        uint256 accumulatedRemainder = tokenRewardsRemainingAccScaled[token][tokenId];

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                // get index of last checkpoint in this epoch
                _index = getPriorBalanceIndex(tokenId, _currTs + DURATION - 1);
                // get checkpoint in this epoch
                cp0 = checkpoints[tokenId][_index];
                // get supply of last checkpoint in this epoch
                _supply = Math.max(supplyCheckpoints[getPriorSupplyIndex(_currTs + DURATION - 1)].supply, 1);

                (uint256 rewardAmount, uint256 scaledRemainder) = _calculateEpochReward(tokenRewardsPerEpoch[token][_currTs], cp0.balanceOf, _supply);
                accumulatedReward += rewardAmount;
                accumulatedRemainder += scaledRemainder;
                _currTs += DURATION;
            }

            uint256 rewardFromRemaining = accumulatedRemainder / REWARDS_REMAINING_SCALE;
            uint256 newRemainder = accumulatedRemainder - rewardFromRemaining * REWARDS_REMAINING_SCALE;
            reward = EarnedResult(accumulatedReward + rewardFromRemaining, newRemainder, true);
        }
    }

    /**
     * @notice Calculates reward for a single epoch with overflow protection
     */
    function _calculateEpochReward(uint256 _rewards, uint256 _balanceOf, uint256 _totalSupply)
        internal
        pure
        returns (uint256 rewardAmount, uint256 scaledRemainder)
    {
        // whole units: floor(rewardsThisEpoch * userBalanceThisEpoch / totalSupply)
        rewardAmount = Math.mulDiv(_rewards, _balanceOf, _totalSupply);

        // fractional remainder scaled
        uint256 remainder = mulmod(_rewards, _balanceOf, _totalSupply);
        scaledRemainder = Math.mulDiv(remainder, REWARDS_REMAINING_SCALE, _totalSupply);
    }

    /// @inheritdoc IReward
    function _deposit(uint256 amount, uint256 tokenId) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();

        totalSupply += amount;
        balanceOf[tokenId] += amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();

        emit Deposit(sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function _withdraw(uint256 amount, uint256 tokenId) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();

        totalSupply -= amount;
        balanceOf[tokenId] -= amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();

        emit Withdraw(sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function getReward(uint256 tokenId, address[] memory tokens) external virtual nonReentrant {}

    /// @inheritdoc IReward
    function getRewardUntilTs(uint256 tokenId, address[] memory tokens, uint256 timestamp) external virtual nonReentrant {}

    /// @dev used with all getReward implementations
    function _getReward(address recipient, uint256 tokenId, address[] memory tokens, uint256 rewardPeriodEndTs) internal {
        uint256 _length = tokens.length;
        for (uint256 i = 0; i < _length; i++) {
            address token = tokens[i];
            EarnedResult memory _earnedResult = _earned(tokens[i], tokenId, rewardPeriodEndTs);

            if (_earnedResult.success) {
                lastEarn[token][tokenId] = rewardPeriodEndTs;
                tokenRewardsRemainingAccScaled[token][tokenId] = _earnedResult.rewardRemainders;
                if (_earnedResult.unclaimedRewards > 0) {
                    IERC20(token).safeTransfer(recipient, _earnedResult.unclaimedRewards);
                    emit ClaimRewards(recipient, token, _earnedResult.unclaimedRewards);
                }
            }
        }
    }

    /// @inheritdoc IReward
    function notifyRewardAmount(address token, uint256 amount) external virtual nonReentrant {}

    /// @dev used within all notifyRewardAmount implementations
    function _notifyRewardAmount(address sender, address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(sender, address(this), amount);

        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
        tokenRewardsPerEpoch[token][epochStart] += amount;

        emit NotifyReward(sender, token, epochStart, amount);
    }
}
