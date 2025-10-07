// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

/// @title Partial Reward Claim Test
/// @notice Tests for claiming rewards in chunks using getRewardUntilTs to avoid gas limits
contract PartialRewardClaimTest is BaseTest {
    uint256 tokenId;
    address[] pools;
    uint256[] weights;
    address[] rewardTokens;

    function _setUp() public override {
        // Create a lock
        AERO.approve(address(escrow), TOKEN_1);
        tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        
        // Setup pools and weights for voting
        pools = new address[](1);
        pools[0] = address(pool);
        weights = new uint256[](1);
        weights[0] = 10000;
        
        // Setup rewardTokens array
        rewardTokens = new address[](1);
        rewardTokens[0] = address(FRAX);
        
        // Transfer rewards to gauge (enough for 5 years = 260 epochs * 10 tokens)
        deal(address(FRAX), address(gauge), TOKEN_1 * 3000);
        
        skip(1);
    }

    /// @notice Test basic partial claim - claim up to a specific timestamp
    function testPartialClaimUpToTimestamp() public {
        // Vote to activate rewards
        skip(3 days);
        voter.vote(tokenId, pools, weights);
        
        // Add rewards
        vm.startPrank(address(gauge));
        FRAX.approve(address(feesVotingReward), TOKEN_1 * 100);
        feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 100);
        vm.stopPrank();
        
        // Move to next epoch
        skipToNextEpoch(1);
        uint256 timestampA = block.timestamp;
        
        // Check earned amount at timestamp A
        uint256 earnedAtA = feesVotingReward.earnedUntilTs(address(FRAX), tokenId, timestampA);
        emit log_named_decimal_uint("Earned at timestamp A", earnedAtA, 18);
        assertGt(earnedAtA, 0, "Should have earned rewards");
        
        // Claim up to timestamp A
        uint256 balanceBefore = FRAX.balanceOf(address(owner));
        feesVotingReward.getRewardUntilTs(tokenId, rewardTokens, timestampA);
        uint256 balanceAfter = FRAX.balanceOf(address(owner));
        
        uint256 claimed = balanceAfter - balanceBefore;
        emit log_named_decimal_uint("Claimed up to timestamp A", claimed, 18);
        
        assertEq(claimed, earnedAtA, "Claimed should equal earned at timestamp A");
        
        // Check that earned is now 0 at timestamp A
        uint256 earnedAfterClaim = feesVotingReward.earnedUntilTs(address(FRAX), tokenId, timestampA);
        assertEq(earnedAfterClaim, 0, "Should have no earnings at timestamp A after claim");
    }

    /// @notice Test claiming in two parts - first up to timestamp A, then up to current time
    /// @dev This test demonstrates claiming rewards from epoch 1, then separately from epoch 2
    function testClaimInTwoParts() public {
        // Vote to activate rewards
        skip(3 days);
        voter.vote(tokenId, pools, weights);
        
        // Add rewards in epoch 1
        vm.startPrank(address(gauge));
        FRAX.approve(address(feesVotingReward), TOKEN_1 * 100);
        feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 100);
        vm.stopPrank();
        
        // Move to epoch 2
        skipToNextEpoch(1);
        uint256 timestampA = block.timestamp; // Capture timestamp at start of epoch 2
        
        skip(3 days);
        
        // Re-vote to maintain position
        voter.vote(tokenId, pools, weights);
        
        // Add more rewards in epoch 2
        vm.startPrank(address(gauge));
        FRAX.approve(address(feesVotingReward), TOKEN_1 * 100);
        feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 100);
        vm.stopPrank();
        
        // Move to epoch 3
        skipToNextEpoch(1);
        
        emit log_string("=== First claim up to timestamp A ===");
        
        // Check total earned at current time
        uint256 totalEarned = feesVotingReward.earned(address(FRAX), tokenId);
        emit log_named_decimal_uint("Total earned at current time", totalEarned, 18);
        
        // Check earned at timestamp A (should be less)
        uint256 earnedAtA = feesVotingReward.earnedUntilTs(address(FRAX), tokenId, timestampA);
        emit log_named_decimal_uint("Earned at timestamp A", earnedAtA, 18);
        
        // Note: earnedAtA includes all rewards up to and including the epoch containing timestampA
        // Since timestampA is at start of epoch 2, it includes epoch 1's rewards
        // To get partial rewards, we need timestampA to be mid-epoch or before rewards are added
        assertLe(earnedAtA, totalEarned, "Earned at A should be less than or equal to total");
        
        // Claim up to timestamp A
        uint256 balanceBefore = FRAX.balanceOf(address(owner));
        feesVotingReward.getRewardUntilTs(tokenId, rewardTokens, timestampA);
        uint256 balanceAfter = FRAX.balanceOf(address(owner));
        
        uint256 firstClaim = balanceAfter - balanceBefore;
        emit log_named_decimal_uint("First claim amount", firstClaim, 18);
        assertEq(firstClaim, earnedAtA, "First claim should equal earned at A");
        
        emit log_string("=== Second claim up to current time ===");
        
        // Check remaining earned
        uint256 remainingEarned = feesVotingReward.earned(address(FRAX), tokenId);
        emit log_named_decimal_uint("Remaining earned", remainingEarned, 18);
        
        // Claim remaining rewards
        balanceBefore = FRAX.balanceOf(address(owner));
        feesVotingReward.getReward(tokenId, rewardTokens);
        balanceAfter = FRAX.balanceOf(address(owner));
        
        uint256 secondClaim = balanceAfter - balanceBefore;
        emit log_named_decimal_uint("Second claim amount", secondClaim, 18);
        
        emit log_string("=== Summary ===");
        emit log_named_decimal_uint("Total claimed (both parts)", firstClaim + secondClaim, 18);
        emit log_named_decimal_uint("Expected total", totalEarned, 18);
        
        assertEq(firstClaim + secondClaim, totalEarned, "Total claims should equal total earned");
        
        // Verify no rewards left
        uint256 finalEarned = feesVotingReward.earned(address(FRAX), tokenId);
        assertEq(finalEarned, 0, "Should have no rewards left");
    }

    /// @notice Test claiming rewards accumulated over 1 year in monthly chunks to avoid gas limits
    /// @dev Demonstrates the gas-saving use case for long-term unclaimed rewards
    function testLongTermClaimInMonthlyChunks() public {
        emit log_string("=== Simulating 1 year of unclaimed rewards ===");
        
        // Vote to activate rewards
        skip(3 days);
        voter.vote(tokenId, pools, weights);
        
        uint256 totalRewardsAdded = 0;
        uint256 totalMonths = 12;
        
        uint256[] memory monthEndTimestamps = new uint256[](totalMonths);
        
        // Add rewards every week for 1 year (52 weeks)
        for (uint256 week = 0; week < 52; week++) {
            skipToNextEpoch(1);
            skip(3 days);
            
            // Re-vote every 4 weeks to maintain position
            // if (week % 4 == 0) {
            //     voter.vote(tokenId, pools, weights);
            // }
            
            // Add rewards
            vm.startPrank(address(gauge));
            FRAX.approve(address(feesVotingReward), TOKEN_1 * 10);
            feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 10);
            vm.stopPrank();
            
            totalRewardsAdded += TOKEN_1 * 10;
            
            // Capture timestamp at end of each month (every 4 weeks)
            if ((week + 1) % 4 == 0) {
                uint256 monthIndex = (week + 1) / 4 - 1;
                if (monthIndex < totalMonths) {
                    monthEndTimestamps[monthIndex] = block.timestamp;
                }
            }
        }
        
        emit log_named_uint("Total weeks", 52);
        emit log_named_decimal_uint("Total rewards added", totalRewardsAdded, 18);
        
        // Move to current time (after all rewards)
        skipToNextEpoch(1);
        
        // Check total earned
        uint256 totalEarned = feesVotingReward.earned(address(FRAX), tokenId);
        emit log_named_decimal_uint("Total earned after 1 year", totalEarned, 18);
        
        emit log_string("=== Claiming in monthly chunks ===");
        
        uint256 totalClaimed = 0;
        
        // Claim in 12 monthly chunks
        for (uint256 month = 0; month < totalMonths; month++) {
            emit log_string("");
            emit log_named_uint("Claiming month", month + 1);
            emit log_named_uint("Up to timestamp", monthEndTimestamps[month]);
            
            // Check earned up to this timestamp
            uint256 earnedUpTo = feesVotingReward.earnedUntilTs(address(FRAX), tokenId, monthEndTimestamps[month]);
            emit log_named_decimal_uint("Earned up to this month", earnedUpTo, 18);
            
            // Claim up to this timestamp
            uint256 balanceBefore = FRAX.balanceOf(address(owner));
            feesVotingReward.getRewardUntilTs(tokenId, rewardTokens, monthEndTimestamps[month]);
            uint256 balanceAfter = FRAX.balanceOf(address(owner));
            
            uint256 claimed = balanceAfter - balanceBefore;
            totalClaimed += claimed;
            
            emit log_named_decimal_uint("Claimed this month", claimed, 18);
            emit log_named_decimal_uint("Total claimed so far", totalClaimed, 18);
            
            assertEq(claimed, earnedUpTo, "Claimed should equal earned up to timestamp");
        }
        
        // Claim any remaining rewards (last 4 weeks not captured in monthly timestamps)
        emit log_string("");
        emit log_string("=== Claiming remaining rewards ===");
        
        uint256 remainingEarned = feesVotingReward.earned(address(FRAX), tokenId);
        emit log_named_decimal_uint("Remaining earned", remainingEarned, 18);
        
        if (remainingEarned > 0) {
            uint256 balanceBefore = FRAX.balanceOf(address(owner));
            feesVotingReward.getReward(tokenId, rewardTokens);
            uint256 balanceAfter = FRAX.balanceOf(address(owner));
            
            uint256 finalClaim = balanceAfter - balanceBefore;
            totalClaimed += finalClaim;
            
            emit log_named_decimal_uint("Final claim", finalClaim, 18);
        }
        
        emit log_string("");
        emit log_string("=== Final Summary ===");
        emit log_named_decimal_uint("Total earned", totalEarned, 18);
        emit log_named_decimal_uint("Total claimed in chunks", totalClaimed, 18);
        
        assertEq(totalClaimed, totalEarned, "Total claimed should equal total earned");
        
        // Verify no rewards left
        uint256 finalEarned = feesVotingReward.earned(address(FRAX), tokenId);
        assertEq(finalEarned, 0, "Should have no rewards left after claiming all chunks");
    }

    /// @notice Test that claiming with timestamp in the past before lastEarn returns 0
    function testCannotClaimBeforeLastEarn() public {
        // Vote and add rewards
        skip(3 days);
        voter.vote(tokenId, pools, weights);
        
        vm.startPrank(address(gauge));
        FRAX.approve(address(feesVotingReward), TOKEN_1 * 100);
        feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 100);
        vm.stopPrank();
        
        skipToNextEpoch(1);
        uint256 firstClaimTime = block.timestamp;
        
        // First claim
        feesVotingReward.getReward(tokenId, rewardTokens);
        
        // Try to claim with timestamp before last claim
        uint256 pastTimestamp = firstClaimTime - 1 weeks;
        uint256 earnedAtPast = feesVotingReward.earnedUntilTs(address(FRAX), tokenId, pastTimestamp);
        
        assertEq(earnedAtPast, 0, "Should have 0 earned for timestamp before lastEarn");
        
        // Claim should succeed but get 0
        uint256 balanceBefore = FRAX.balanceOf(address(owner));
        feesVotingReward.getRewardUntilTs(tokenId, rewardTokens, pastTimestamp);
        uint256 balanceAfter = FRAX.balanceOf(address(owner));
        
        assertEq(balanceAfter - balanceBefore, 0, "Should claim 0 for timestamp before lastEarn");
    }

    /// @notice Test claiming with future timestamp should claim all available rewards
    function testClaimWithFutureTimestamp() public {
        // Vote and add rewards
        skip(3 days);
        voter.vote(tokenId, pools, weights);
        
        vm.startPrank(address(gauge));
        FRAX.approve(address(feesVotingReward), TOKEN_1 * 100);
        feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 100);
        vm.stopPrank();
        
        skipToNextEpoch(1);
        
        uint256 totalEarned = feesVotingReward.earned(address(FRAX), tokenId);
        
        // Claim with future timestamp
        uint256 futureTimestamp = block.timestamp + 365 days;
        uint256 earnedAtFuture = feesVotingReward.earnedUntilTs(address(FRAX), tokenId, futureTimestamp);
        
        emit log_named_decimal_uint("Earned at current time", totalEarned, 18);
        emit log_named_decimal_uint("Earned at future timestamp", earnedAtFuture, 18);
        
        assertEq(earnedAtFuture, totalEarned, "Future timestamp should return same as current");
        
        // Claim with future timestamp
        uint256 balanceBefore = FRAX.balanceOf(address(owner));
        feesVotingReward.getRewardUntilTs(tokenId, rewardTokens, futureTimestamp);
        uint256 balanceAfter = FRAX.balanceOf(address(owner));
        
        assertEq(balanceAfter - balanceBefore, totalEarned, "Should claim all available rewards");
    }

    /// @notice Test multiple partial claims with overlapping timestamps
    function testMultiplePartialClaimsProgressive() public {
        // Vote and add rewards across 4 epochs
        skip(3 days);
        voter.vote(tokenId, pools, weights);
        
        uint256[] memory epochTimestamps = new uint256[](4);
        
        for (uint256 i = 0; i < 4; i++) {
            vm.startPrank(address(gauge));
            FRAX.approve(address(feesVotingReward), TOKEN_1 * 100);
            feesVotingReward.notifyRewardAmount(address(FRAX), TOKEN_1 * 100);
            vm.stopPrank();
            
            skipToNextEpoch(1);
            skip(3 days);
            epochTimestamps[i] = block.timestamp;
            
            voter.vote(tokenId, pools, weights);
        }
        
        skipToNextEpoch(1);
        
        uint256 totalEarned = feesVotingReward.earned(address(FRAX), tokenId);
        emit log_named_decimal_uint("Total earned across 4 epochs", totalEarned, 18);
        
        uint256 totalClaimed = 0;
        
        // Claim progressively through each epoch
        for (uint256 i = 0; i < 4; i++) {
            emit log_string("");
            emit log_named_uint("Claiming up to epoch", i + 1);
            
            uint256 balanceBefore = FRAX.balanceOf(address(owner));
            feesVotingReward.getRewardUntilTs(tokenId, rewardTokens, epochTimestamps[i]);
            uint256 balanceAfter = FRAX.balanceOf(address(owner));
            
            uint256 claimed = balanceAfter - balanceBefore;
            totalClaimed += claimed;
            
            emit log_named_decimal_uint("Claimed this epoch", claimed, 18);
            emit log_named_decimal_uint("Total claimed so far", totalClaimed, 18);
        }
        
        emit log_string("");
        emit log_named_decimal_uint("Final total claimed", totalClaimed, 18);
        
        assertEq(totalClaimed, totalEarned, "Progressive claims should equal total earned");
        
        // Verify no rewards left
        assertEq(feesVotingReward.earned(address(FRAX), tokenId), 0, "Should have no rewards left");
    }
}
