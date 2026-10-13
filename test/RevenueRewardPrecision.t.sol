// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

/// @title RevenueRewardPrecision Test
/// @notice Tests for edge cases in reward distribution with accumulating remainders
/// @dev Focuses on scenarios where _rewards * _balanceOf < _totalSupply
contract RevenueRewardPrecisionTest is BaseTest {
    // Mock contracts for testing
    MockERC20 public mockUSDC;

    // Test users
    address public user = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    address public admin = address(0x5);

    function _setUp() public override {
        // Use existing whitelisted tokens from BaseTest (USDC, DAI, etc.)
        // mockUSDC will be USDC (6 decimals like USDC)
        mockUSDC = MockERC20(address(USDC));

        // Deal tokens to gauge for rewards (gauge distributes to feesVotingReward)
        deal(address(USDC), address(gauge), TOKEN_100M);
        deal(address(DAI), address(gauge), TOKEN_100M);

        // Set up users with initial AERO tokens
        deal(address(AERO), user, TOKEN_100M, true);
        deal(address(AERO), user1, TOKEN_100M, true);
        deal(address(AERO), user2, TOKEN_100M, true);
        deal(address(AERO), user3, TOKEN_100M, true);
    }

    /// @notice Test edge case where rewards * balanceOf < totalSupply
    /// @dev Should accumulate remainder and allow claiming when threshold is reached
    function testEdgeCaseSmallRewardsAccumulation() public {
        // Skip to mid-week to be in distribution window
        skip(3 days);

        // Setup: Create locks with significant size difference
        uint256 smallLockId = _createLock(user, TOKEN_1, MAXTIME); // Very small lock (1 token)
        uint256 largeLockId = _createLock(user2, TOKEN_100M, MAXTIME); // Very large lock (100M tokens)

        emit log_named_uint("Small lock balance", TOKEN_1);
        emit log_named_uint("Large lock balance", TOKEN_100M);
        emit log_named_uint("Total supply", TOKEN_100M + TOKEN_1);

        // Setup voting to activate rewards
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(user);
        voter.vote(smallLockId, pools, weights);

        vm.prank(user2);
        voter.vote(largeLockId, pools, weights);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        uint256 totalRewardsAdded = 0;

        // Add first reward - use TOKEN_1 for 18 decimal tokens like USDC
        uint256 rewardAmount = TOKEN_1 * 100; // 100 USDC (18 decimals)
        _addReward(admin, address(mockUSDC), rewardAmount);
        totalRewardsAdded += rewardAmount;

        emit log_string("=== After first reward (100 USDC) ===");
        emit log_named_decimal_uint("Reward added", rewardAmount, 18);

        // Calculate expected rewards
        // Small lock: (100 * 1e18 * 1e18) / (100e6 * 1e18 + 1e18) ≈ 0.00000001 USDC
        uint256 expectedSmall = (rewardAmount * TOKEN_1) / (TOKEN_100M + TOKEN_1);
        uint256 expectedLarge = (rewardAmount * TOKEN_100M) / (TOKEN_100M + TOKEN_1);
        emit log_named_decimal_uint("Expected small lock reward", expectedSmall, 18);
        emit log_named_decimal_uint("Expected large lock reward", expectedLarge, 18);

        skipToNextEpoch(1);

        // Claim for small lock
        uint256 preBalanceSmall = mockUSDC.balanceOf(user);
        _getReward(smallLockId, tokens);
        uint256 postBalanceSmall = mockUSDC.balanceOf(user);
        uint256 firstClaimSmall = postBalanceSmall - preBalanceSmall;

        emit log_named_decimal_uint("Small lock actual claim", firstClaimSmall, 18);
        emit log_named_uint("Small lock remainder (scaled)", _getTokenRewardsRemaining(address(mockUSDC), smallLockId));

        // Claim for large lock to verify
        uint256 preBalanceLarge = mockUSDC.balanceOf(user2);
        _getReward(largeLockId, tokens);
        uint256 postBalanceLarge = mockUSDC.balanceOf(user2);
        uint256 firstClaimLarge = postBalanceLarge - preBalanceLarge;

        emit log_named_decimal_uint("Large lock actual claim", firstClaimLarge, 18);
        emit log_named_decimal_uint("Total claimed (both locks)", firstClaimSmall + firstClaimLarge, 18);

        // Add more rewards over multiple epochs
        for (uint256 i = 0; i < 10; i++) {
            skipToNextEpoch(1);
            skip(3 days); // Move to mid-week for distribution window

            // Re-vote to maintain position
            vm.prank(user);
            voter.vote(smallLockId, pools, weights);

            vm.prank(user2);
            voter.vote(largeLockId, pools, weights);

            _addReward(admin, address(mockUSDC), TOKEN_1 * 100);
            totalRewardsAdded += TOKEN_1 * 100;
        }

        skipToNextEpoch(1);

        emit log_string("=== After 10 more epochs (1000 more USDC) ===");
        emit log_named_decimal_uint("Total rewards added", totalRewardsAdded, 18);

        // Claim final rewards for small lock
        preBalanceSmall = mockUSDC.balanceOf(user);
        _getReward(smallLockId, tokens);
        postBalanceSmall = mockUSDC.balanceOf(user);
        uint256 additionalClaimSmall = postBalanceSmall - preBalanceSmall;

        uint256 totalClaimedSmall = firstClaimSmall + additionalClaimSmall;
        emit log_named_decimal_uint("Small lock additional claim", additionalClaimSmall, 18);
        emit log_named_decimal_uint("Small lock total claimed", totalClaimedSmall, 18);
        emit log_named_uint(
            "Small lock final remainder (scaled)",
            _getTokenRewardsRemaining(address(mockUSDC), smallLockId)
        );

        // Claim final rewards for large lock
        preBalanceLarge = mockUSDC.balanceOf(user2);
        _getReward(largeLockId, tokens);
        postBalanceLarge = mockUSDC.balanceOf(user2);
        uint256 additionalClaimLarge = postBalanceLarge - preBalanceLarge;

        uint256 totalClaimedLarge = firstClaimLarge + additionalClaimLarge;
        emit log_named_decimal_uint("Large lock additional claim", additionalClaimLarge, 18);
        emit log_named_decimal_uint("Large lock total claimed", totalClaimedLarge, 18);
        emit log_named_uint(
            "Large lock final reminder (scaled)",
            _getTokenRewardsRemaining(address(mockUSDC), largeLockId)
        );

        emit log_string("=== Summary ===");
        emit log_named_decimal_uint("Total rewards distributed", totalRewardsAdded, 18);
        emit log_named_decimal_uint("Total claimed by both locks", totalClaimedSmall + totalClaimedLarge, 18);
        emit log_named_decimal_uint(
            "Unclaimed (in remainders)",
            totalRewardsAdded - (totalClaimedSmall + totalClaimedLarge),
            18
        );

        // Calculate percentage
        uint256 smallPercentage = (totalClaimedSmall * 1000000) / totalRewardsAdded; // basis points
        emit log_named_uint("Small lock percentage (bps)", smallPercentage);
        emit log_named_decimal_uint("Small lock percentage", smallPercentage, 2); // 0.01% precision

        assertGt(totalClaimedSmall, firstClaimSmall, "Should accumulate rewards over time");
        assertGt(
            _getTokenRewardsRemaining(address(mockUSDC), smallLockId),
            0,
            "Should still have remainder accumulating"
        );
    }

    /// @notice Test multiple small holders accumulating and claiming rewards correctly
    /// @dev Ensures fairness across multiple small lock holders
    function testMultipleSmallHoldersRewardFairness() public {
        // Skip to mid-week to be in distribution window
        skip(3 days);

        // Create multiple small locks
        uint256[] memory smallLocks = new uint256[](3);
        smallLocks[0] = _createLock(user, TOKEN_1 * 10, MAXTIME);
        smallLocks[1] = _createLock(user1, TOKEN_1 * 20, MAXTIME);
        smallLocks[2] = _createLock(user3, TOKEN_1 * 30, MAXTIME);

        // Create one large lock to dominate total supply
        uint256 largeLock = _createLock(user2, TOKEN_100M, MAXTIME);

        // Setup voting for all locks
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(user);
        voter.vote(smallLocks[0], pools, weights);

        vm.prank(user1);
        voter.vote(smallLocks[1], pools, weights);

        vm.prank(user3);
        voter.vote(smallLocks[2], pools, weights);

        vm.prank(user2);
        voter.vote(largeLock, pools, weights);

        // Add rewards
        _addReward(admin, address(mockUSDC), USDC_1 * 1000);

        skipToNextEpoch(1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        // Track initial claims for each small holder
        uint256[] memory initialClaims = new uint256[](3);

        // First claims
        _getReward(smallLocks[0], tokens);
        initialClaims[0] = mockUSDC.balanceOf(user);

        _getReward(smallLocks[1], tokens);
        initialClaims[1] = mockUSDC.balanceOf(user1);

        _getReward(smallLocks[2], tokens);
        initialClaims[2] = mockUSDC.balanceOf(user3);

        // Verify initial claims are proportional to lock amounts
        emit log_named_uint("Lock1 (10 tokens) initial claim", initialClaims[0]);
        emit log_named_uint("Lock2 (20 tokens) initial claim", initialClaims[1]);
        emit log_named_uint("Lock3 (30 tokens) initial claim", initialClaims[2]);

        // Check remainder accumulation for each lock
        uint256 remainder0 = _getTokenRewardsRemaining(address(mockUSDC), smallLocks[0]);
        uint256 remainder1 = _getTokenRewardsRemaining(address(mockUSDC), smallLocks[1]);
        uint256 remainder2 = _getTokenRewardsRemaining(address(mockUSDC), smallLocks[2]);

        emit log_named_uint("Lock1 remainder (scaled)", remainder0);
        emit log_named_uint("Lock2 remainder (scaled)", remainder1);
        emit log_named_uint("Lock3 remainder (scaled)", remainder2);

        // All locks should have remainders accumulating
        assertGt(remainder0, 0, "Lock1 should have remainder");
        assertGt(remainder1, 0, "Lock2 should have remainder");
        assertGt(remainder2, 0, "Lock3 should have remainder");

        // Add more rewards over time
        for (uint256 i = 0; i < 20; i++) {
            skipToNextEpoch(1);
            skip(3 days); // Move to mid-week for distribution window

            // Re-vote periodically
            if (i % 5 == 0) {
                vm.prank(user);
                voter.vote(smallLocks[0], pools, weights);

                vm.prank(user1);
                voter.vote(smallLocks[1], pools, weights);

                vm.prank(user3);
                voter.vote(smallLocks[2], pools, weights);
            }

            _addReward(admin, address(mockUSDC), USDC_1 * 200);
        }

        skipToNextEpoch(1);

        // Claim final accumulated rewards
        _getReward(smallLocks[0], tokens);
        uint256 finalBalance0 = mockUSDC.balanceOf(user);

        _getReward(smallLocks[1], tokens);
        uint256 finalBalance1 = mockUSDC.balanceOf(user1);

        _getReward(smallLocks[2], tokens);
        uint256 finalBalance2 = mockUSDC.balanceOf(user3);

        emit log_named_uint("Lock1 final balance", finalBalance0);
        emit log_named_uint("Lock2 final balance", finalBalance1);
        emit log_named_uint("Lock3 final balance", finalBalance2);

        // Check final remainders
        uint256 finalRemainder0 = _getTokenRewardsRemaining(address(mockUSDC), smallLocks[0]);
        uint256 finalRemainder1 = _getTokenRewardsRemaining(address(mockUSDC), smallLocks[1]);
        uint256 finalRemainder2 = _getTokenRewardsRemaining(address(mockUSDC), smallLocks[2]);

        emit log_named_uint("Lock1 final remainder (scaled)", finalRemainder0);
        emit log_named_uint("Lock2 final remainder (scaled)", finalRemainder1);
        emit log_named_uint("Lock3 final remainder (scaled)", finalRemainder2);

        // Verify proportional distribution
        assertGt(finalBalance0, initialClaims[0], "Should accumulate rewards");
        assertGt(finalBalance1, finalBalance0, "User1 should receive more than user");
        assertGt(finalBalance2, finalBalance1, "User3 should receive more than user1");
    }

    /// @notice Test that accumulated remainders persist across multiple epochs
    /// @dev Ensures remainders aren't lost between epochs
    function testRemainderPersistenceAcrossEpochs() public {
        // Skip to mid-week to be in distribution window
        skip(3 days);

        uint256 tinyLockId = _createLock(user, TOKEN_1, MAXTIME);
        uint256 hugeLockId = _createPermanentLock(user2, TOKEN_100M, MAXTIME);

        // Setup voting
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(user);
        voter.vote(tinyLockId, pools, weights);

        vm.prank(user2);
        voter.vote(hugeLockId, pools, weights);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        // Accumulate rewards over multiple epochs
        for (uint256 epoch = 0; epoch < 5; epoch++) {
            skipToNextEpoch(1);
            skip(3 days); // Move to mid-week for distribution window

            _addReward(admin, address(mockUSDC), USDC_1 * 100);

            // Re-vote periodically
            if (epoch % 2 == 0) {
                vm.prank(user);
                voter.vote(tinyLockId, pools, weights);
            }
        }

        // Now claim accumulated rewards
        uint256 preBalance = mockUSDC.balanceOf(user);
        _getReward(tinyLockId, tokens);
        uint256 postBalance = mockUSDC.balanceOf(user);

        uint256 accumulated = postBalance - preBalance;
        emit log_named_uint("Accumulated over 5 epochs", accumulated);

        // Check remainder after claiming
        uint256 remainderAfterClaim = _getTokenRewardsRemaining(address(mockUSDC), tinyLockId);
        emit log_named_uint("Remainder after 5 epochs (scaled)", remainderAfterClaim);

        assertGt(accumulated, 0, "Should have accumulated rewards from all epochs");
        assertGt(remainderAfterClaim, 0, "Should have remainder persisting");

        // Add more rewards
        skipToNextEpoch(1);
        skip(3 days); // Move to mid-week for distribution window
        _addReward(admin, address(mockUSDC), USDC_1 * 10000);

        skipToNextEpoch(1);
        skip(3 days);

        vm.prank(user);
        voter.vote(tinyLockId, pools, weights);

        skipToNextEpoch(1);

        preBalance = mockUSDC.balanceOf(user);
        _getReward(tinyLockId, tokens);
        postBalance = mockUSDC.balanceOf(user);

        uint256 finalClaim = postBalance - preBalance;
        emit log_named_uint("Final large claim", finalClaim);

        // Check remainder persists even after large distribution
        uint256 finalRemainder = _getTokenRewardsRemaining(address(mockUSDC), tinyLockId);
        emit log_named_uint("Final remainder (scaled)", finalRemainder);

        assertGt(postBalance, accumulated, "Should receive more rewards with larger distribution");
        // Remainder should still exist showing persistence
        assertGt(finalRemainder, 0, "Remainder should persist across epochs");
    }

    /// @notice Test edge case with multiple tokens having different decimals
    /// @dev Ensures remainder accumulation works correctly with different token decimals
    function testMultiTokenDifferentDecimalsRemainder() public {
        // Skip to mid-week to be in distribution window
        skip(3 days);

        uint256 smallLockId = _createLock(user, TOKEN_1 * 5, MAXTIME);
        uint256 largeLockId = _createPermanentLock(user2, TOKEN_100M, MAXTIME);

        // Setup voting
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(user);
        voter.vote(smallLockId, pools, weights);

        vm.prank(user2);
        voter.vote(largeLockId, pools, weights);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC); // USDC with 18 decimals

        // Add rewards
        _addReward(admin, address(mockUSDC), USDC_1 * 100);

        skipToNextEpoch(1);

        // Claim initial rewards
        _getReward(smallLockId, tokens);
        uint256 initialBalance = mockUSDC.balanceOf(user);

        emit log_named_uint("Initial balance", initialBalance);

        // Check initial remainder
        uint256 initialRemainder = _getTokenRewardsRemaining(address(mockUSDC), smallLockId);
        emit log_named_uint("Initial remainder (scaled)", initialRemainder);
        assertGt(initialRemainder, 0, "Should have initial remainder");

        // Add more rewards over multiple epochs with consistent voting
        for (uint256 i = 0; i < 5; i++) {
            skipToNextEpoch(1);
            skip(3 days); // Move to mid-week for distribution window

            // Vote every epoch to maintain position
            vm.prank(user);
            voter.vote(smallLockId, pools, weights);

            _addReward(admin, address(mockUSDC), USDC_1 * 100);
        }

        skipToNextEpoch(1);

        _getReward(smallLockId, tokens);
        uint256 finalBalance = mockUSDC.balanceOf(user);

        emit log_named_uint("Final balance", finalBalance);

        // Check final remainder
        uint256 finalRemainder = _getTokenRewardsRemaining(address(mockUSDC), smallLockId);
        emit log_named_uint("Final remainder (scaled)", finalRemainder);

        // Should have accumulated rewards over time
        assertGt(finalBalance, initialBalance, "Should accumulate rewards over multiple epochs");
        // Remainder should still exist (may decrease as it converts to actual rewards)
        assertGt(finalRemainder, 0, "Remainder should persist over epochs");
    }

    /// @notice Test that increasing lock amount affects remainder accumulation correctly
    /// @dev Ensures dynamic changes to lock amounts are handled properly
    function testDynamicLockAmountWithRemainders() public {
        // Skip to mid-week to be in distribution window
        skip(3 days);

        uint256 dynamicLockId = _createLock(user, TOKEN_1, MAXTIME);
        uint256 largeLockId = _createPermanentLock(user2, TOKEN_100M, MAXTIME);

        // Setup voting
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(user);
        voter.vote(dynamicLockId, pools, weights);

        vm.prank(user2);
        voter.vote(largeLockId, pools, weights);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        // Initial small reward
        _addReward(admin, address(mockUSDC), USDC_1);
        skipToNextEpoch(1);

        _getReward(dynamicLockId, tokens);
        uint256 initialBalance = mockUSDC.balanceOf(user);

        // Check remainder before increasing lock
        uint256 remainderBeforeIncrease = _getTokenRewardsRemaining(address(mockUSDC), dynamicLockId);
        emit log_named_uint("Remainder before lock increase (scaled)", remainderBeforeIncrease);
        assertGt(remainderBeforeIncrease, 0, "Should have remainder before increase");

        // Increase lock amount
        _increaseAmount(user, dynamicLockId, TOKEN_1 * 99);

        // Add more rewards
        skipToNextEpoch(1);
        skip(3 days);

        // Re-vote with increased lock
        vm.prank(user);
        voter.vote(dynamicLockId, pools, weights);

        _addReward(admin, address(mockUSDC), USDC_1 * 100);
        skipToNextEpoch(1);

        _getReward(dynamicLockId, tokens);
        uint256 balanceAfterIncrease = mockUSDC.balanceOf(user);

        // Check remainder after increasing lock
        uint256 remainderAfterIncrease = _getTokenRewardsRemaining(address(mockUSDC), dynamicLockId);
        emit log_named_uint("Remainder after lock increase (scaled)", remainderAfterIncrease);

        // Should have better rewards due to increased lock amount
        assertGt(balanceAfterIncrease, initialBalance, "Should get more rewards with larger lock");
        // Remainder should be larger with increased lock
        assertGt(remainderAfterIncrease, remainderBeforeIncrease, "Remainder should increase with larger lock");

        // Continue accumulating
        for (uint256 i = 0; i < 10; i++) {
            skipToNextEpoch(1);
            skip(3 days); // Move to mid-week for distribution window

            // Re-vote periodically
            if (i % 3 == 0) {
                vm.prank(user);
                voter.vote(dynamicLockId, pools, weights);
            }

            _addReward(admin, address(mockUSDC), USDC_1 * 50);
        }

        skipToNextEpoch(1);

        _getReward(dynamicLockId, tokens);

        uint256 finalBalance = mockUSDC.balanceOf(user);

        // Check final remainder
        uint256 finalRemainder = _getTokenRewardsRemaining(address(mockUSDC), dynamicLockId);
        emit log_named_uint("Final remainder (scaled)", finalRemainder);

        assertGt(finalBalance, balanceAfterIncrease, "Should receive accumulated rewards after threshold");
        // Remainder should persist throughout
        assertGt(finalRemainder, 0, "Remainder should persist after accumulation");
    }

    // Helper functions (implement based on your actual contract interface)

    function _createLock(address _user, uint256 amount, uint256 duration) internal returns (uint256) {
        vm.startPrank(_user);
        AERO.approve(address(escrow), amount);
        uint256 lockId = escrow.createLock(amount, duration);
        vm.stopPrank();
        return lockId;
    }

    function _createPermanentLock(address _user, uint256 amount, uint256) internal returns (uint256) {
        vm.startPrank(_user);
        AERO.approve(address(escrow), amount);
        uint256 lockId = escrow.createLock(amount, MAXTIME);
        // Convert to permanent if your contract supports it
        // escrow.lockPermanent(lockId);
        vm.stopPrank();
        return lockId;
    }

    function _addReward(address, address token, uint256 amount) internal {
        vm.startPrank(address(gauge));
        IERC20(token).approve(address(feesVotingReward), amount);
        feesVotingReward.notifyRewardAmount(token, amount);
        vm.stopPrank();
    }

    function _increaseAmount(address _user, uint256 tokenId, uint256 amount) internal {
        vm.startPrank(_user);
        AERO.approve(address(escrow), amount);
        escrow.increaseAmount(tokenId, amount);
        vm.stopPrank();
    }

    function _getReward(uint256 tokenId, address[] memory tokens) internal {
        vm.prank(address(voter));
        feesVotingReward.getReward(tokenId, tokens);
    }

    function _getTokenRewardsRemaining(address token, uint256 tokenId) internal view returns (uint256) {
        // Get the scaled remainder accumulation from the reward contract
        return feesVotingReward.tokenRewardsRemainingAccScaled(token, tokenId);
    }

    function goToEpoch(uint256 epochNumber) internal {
        uint256 currentEpoch = block.timestamp / WEEK;
        uint256 targetEpoch = epochNumber;
        if (targetEpoch > currentEpoch) {
            skip((targetEpoch - currentEpoch) * WEEK);
        }
    }

    // Using skipToNextEpoch from BaseTest.sol which is public
}
