// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";
import {IVotingEscrow} from "contracts/interfaces/IVotingEscrow.sol";

/**
 * @title TeamLock Test Suite
 * @notice Comprehensive tests for VotingEscrow team lock functionality
 * @dev Tests cover creation, restrictions, clawback calculations, voting permissions, and edge cases
 *
 * Updated to reflect contract improvements:
 * - Split operations now properly prevented on team locks (noTeamLock modifier added)
 * - Clawback function now correctly sends clawback token to team address
 * - _burn function updated to not require owner approval for clawback operations
 * - Both team and owner can vote on team locks
 */

contract TeamLockTest is BaseTest {
    uint256 constant TEAM_LOCK_DURATION = 2 * 365 * 86400; // 2 years

    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        IVotingEscrow.DepositType indexed depositType,
        uint256 value,
        uint256 locktime,
        uint256 ts
    );

    function _setUp() public override {
        super._setUp();

        // Set up team as the owner for team lock tests
        vm.startPrank(address(owner));
        deal(address(AERO), address(owner), TOKEN_100M);
        AERO.approve(address(escrow), TOKEN_100M);

        // Enable split for all users for testing
        escrow.toggleSplit(address(0), true);
        vm.stopPrank();
    }

    function testCreateTeamLockFor() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;

        vm.expectEmit(true, true, true, true, address(escrow));
        emit Deposit(
            address(owner),
            1,
            IVotingEscrow.DepositType.CREATE_LOCK_TYPE,
            TOKEN_1,
            ((block.timestamp + MAXTIME) / WEEK) * WEEK,
            block.timestamp
        );

        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Verify token was created
        assertEq(tokenId, 1);
        assertEq(escrow.ownerOf(tokenId), address(owner2));

        // Verify team lock data
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.startTs, block.timestamp);
        assertEq(teamLock.endTs, teamUnlockTs);
        assertFalse(teamLock.clawbacked);

        // Verify lock data
        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertEq(uint256(uint128(locked.amount)), TOKEN_1);
        assertEq(locked.end, ((block.timestamp + MAXTIME) / WEEK) * WEEK);
        assertFalse(locked.isPermanent);
    }

    function testCannotCreateTeamLockForIfNotTeam() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.NotTeam.selector);
        escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
    }

    function testCannotCreateTeamLockForWithPastUnlockTime() public {
        uint256 teamUnlockTs = block.timestamp;

        vm.expectRevert(IVotingEscrow.LockDurationNotInFuture.selector);
        escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
    }

    function testUnlockTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward past team unlock time
        vm.warp(teamUnlockTs + 1);

        escrow.unlockTeamLock(tokenId);

        // Verify team lock is removed
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.startTs, 0);
        assertEq(teamLock.endTs, 0);
        assertFalse(teamLock.clawbacked);
    }

    function testCannotUnlockTeamLockBeforeExpiry() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        vm.expectRevert(IVotingEscrow.LockNotExpired.selector);
        escrow.unlockTeamLock(tokenId);
    }

    function testCannotUnlockNonTeamLock() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);

        vm.expectRevert(IVotingEscrow.NotTeamLock.selector);
        escrow.unlockTeamLock(tokenId);
    }

    function testClawbackTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward to 1/4 of the way through the team lock period
        uint256 quarterTime = TEAM_LOCK_DURATION / 4;
        vm.warp(block.timestamp + quarterTime);

        // Even though _burn was updated, approval is still needed for the clawback operation
        // vm.prank(address(owner2));
        // escrow.approve(address(owner), tokenId);

        (uint256 newTokenId, uint256 clawbackTokenId) = escrow.clawbackTeamLock(tokenId);

        // Verify new tokens were created
        assertEq(newTokenId, 2);
        assertEq(clawbackTokenId, 3);

        // Verify ownership - team should now get the clawback token
        assertEq(escrow.ownerOf(newTokenId), address(owner2)); // Owner keeps the remaining amount
        assertEq(escrow.ownerOf(clawbackTokenId), address(owner)); // Team gets the clawback amount

        // Verify amounts (should be split 25%/75%)
        IVotingEscrow.LockedBalance memory newLocked = escrow.locked(newTokenId);
        IVotingEscrow.LockedBalance memory clawbackLocked = escrow.locked(clawbackTokenId);

        uint256 expectedOwnerAmount = TOKEN_1 / 4;
        uint256 expectedTeamAmount = TOKEN_1 - expectedOwnerAmount;

        assertEq(uint256(uint128(newLocked.amount)), expectedOwnerAmount);
        assertEq(uint256(uint128(clawbackLocked.amount)), expectedTeamAmount);

        // Verify team lock state
        IVotingEscrow.TeamLock memory newTeamLock = escrow.teamLocks(newTokenId);
        assertEq(newTeamLock.startTs, block.timestamp - quarterTime);
        assertEq(newTeamLock.endTs, teamUnlockTs);
        assertTrue(newTeamLock.clawbacked);

        // Original token should have team lock removed
        IVotingEscrow.TeamLock memory originalTeamLock = escrow.teamLocks(tokenId);
        assertEq(originalTeamLock.startTs, 0);
        assertEq(originalTeamLock.endTs, 0);
        assertFalse(originalTeamLock.clawbacked);
    }

    function testCannotClawbackTeamLockIfNotTeam() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.NotTeam.selector);
        escrow.clawbackTeamLock(tokenId);
    }

    function testCannotClawbackNonTeamLock() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);

        vm.expectRevert(IVotingEscrow.NotTeamLock.selector);
        escrow.clawbackTeamLock(tokenId);
    }

    function testCannotClawbackAlreadyClawbackedLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward and clawback
        vm.warp(block.timestamp + TEAM_LOCK_DURATION / 2);

        // Approval still needed
        // vm.prank(address(owner2));
        // escrow.approve(address(owner), tokenId);

        (uint256 newTokenId, ) = escrow.clawbackTeamLock(tokenId);

        // Try to clawback the new token which should fail because it's already marked as clawbacked
        vm.expectRevert(IVotingEscrow.AlreadyClawbacked.selector);
        escrow.clawbackTeamLock(newTokenId);
    }

    function testCannotClawbackExpiredTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward past expiry
        vm.warp(teamUnlockTs + 1);

        vm.expectRevert(IVotingEscrow.LockExpired.selector);
        escrow.clawbackTeamLock(tokenId);
    }

    // Test team lock restrictions on operations
    function testCannotTransferTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.transferFrom(address(owner2), address(owner3), tokenId);
    }

    function testCannotSafeTransferTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.safeTransferFrom(address(owner2), address(owner3), tokenId);
    }

    function testCannotMergeTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId1 = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
        uint256 tokenId2 = escrow.createLock(TOKEN_1, MAXTIME);

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.merge(tokenId1, tokenId2);
    }

    function testCannotMergeIntoTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId1 = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 tokenId2 = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Owner2 should not be able to merge into their team locked token
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.NotApprovedOrOwner.selector);
        escrow.merge(tokenId1, tokenId2);
    }

    function testCannotSplitTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Now that noTeamLock modifier is added to split function, it should revert
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.split(tokenId, TOKEN_1 / 2);
    }

    function testCannotWithdrawTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + 1 weeks;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, 1 weeks, address(owner2), teamUnlockTs);

        // Fast forward past lock expiry but not team unlock
        vm.warp(block.timestamp + 2 weeks);

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.withdraw(tokenId);
    }

    // Test that team can vote on behalf of team locks
    function testTeamCanVoteOnTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Move to valid voting window (after vote start, before vote end)
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(epochStart + 2 hours); // 1 hour after vote start

        // Verify team is approved to operate the token
        assertTrue(escrow.isApprovedOrOwner(address(owner), tokenId));

        // Test that team can vote
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        vm.prank(address(owner)); // Team address
        voter.vote(tokenId, pools, weights);

        // Verify vote was recorded
        assertTrue(escrow.voted(tokenId));
    }

    function testOwnerCanAlsoVoteOnTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Move to valid voting window
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(epochStart + 2 hours); // 1 hour after vote start

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        // NOTE: In the current implementation, the owner CAN vote on team locks
        // because isApprovedOrOwner only provides ADDITIONAL permission for team,
        // it doesn't RESTRICT the owner's permissions
        vm.prank(address(owner2)); // Token owner
        voter.vote(tokenId, pools, weights);

        // Verify vote was recorded
        assertTrue(escrow.voted(tokenId));
    }

    // Test operations that should still work on team locks
    function testCanIncreaseAmountOnTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        IVotingEscrow.LockedBalance memory lockBefore = escrow.locked(tokenId);

        // Give owner2 some AERO tokens to increase amount
        deal(address(AERO), address(owner2), TOKEN_1);
        vm.startPrank(address(owner2));
        AERO.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(tokenId, TOKEN_1);
        vm.stopPrank();

        IVotingEscrow.LockedBalance memory lockAfter = escrow.locked(tokenId);
        assertEq(uint256(uint128(lockAfter.amount)), uint256(uint128(lockBefore.amount)) + TOKEN_1);
    }

    function testCanIncreaseUnlockTimeOnTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, 1 weeks, address(owner2), teamUnlockTs);

        IVotingEscrow.LockedBalance memory lockBefore = escrow.locked(tokenId);

        vm.prank(address(owner2));
        escrow.increaseUnlockTime(tokenId, MAXTIME);

        IVotingEscrow.LockedBalance memory lockAfter = escrow.locked(tokenId);
        assertGt(lockAfter.end, lockBefore.end);
    }

    function testCanMakePermanentTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        vm.prank(address(owner2));
        escrow.lockPermanent(tokenId);

        IVotingEscrow.LockedBalance memory lock = escrow.locked(tokenId);
        assertTrue(lock.isPermanent);
    }

    function testCanUnlockPermanentTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        vm.prank(address(owner2));
        escrow.lockPermanent(tokenId);

        vm.prank(address(owner2));
        escrow.unlockPermanent(tokenId);

        IVotingEscrow.LockedBalance memory lock = escrow.locked(tokenId);
        assertFalse(lock.isPermanent);
    }

    // Test edge cases
    function testClawbackCalculationAtStart() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Move forward just 1 second (almost nothing vested)
        vm.warp(block.timestamp + 1);

        // Approval still needed
        // vm.prank(address(owner2));
        // escrow.approve(address(owner), tokenId);

        (uint256 newTokenId, uint256 clawbackTokenId) = escrow.clawbackTeamLock(tokenId);

        // Team should get almost everything, owner should get almost nothing
        IVotingEscrow.LockedBalance memory newLocked = escrow.locked(newTokenId);
        IVotingEscrow.LockedBalance memory clawbackLocked = escrow.locked(clawbackTokenId);

        // With 1 second elapsed out of 2 years, owner should get minimal amount
        // Allow for rounding differences in calculation
        uint256 expectedOwner = (TOKEN_1 * 1) / TEAM_LOCK_DURATION;
        uint256 actualOwner = uint256(uint128(newLocked.amount));
        uint256 actualTeam = uint256(uint128(clawbackLocked.amount));

        // Check that amounts add up to original
        assertEq(actualOwner + actualTeam, TOKEN_1);
        // Check that owner gets very small amount (within 1 wei tolerance)
        assertLe(actualOwner, expectedOwner + 1);
        assertGe(actualOwner, expectedOwner);
    }

    function testClawbackCalculationAtEnd() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward to just before team unlock (99.9% vested)
        vm.warp(teamUnlockTs - 1);

        // Approval still needed
        // vm.prank(address(owner2));
        // escrow.approve(address(owner), tokenId);

        (uint256 newTokenId, uint256 clawbackTokenId) = escrow.clawbackTeamLock(tokenId);

        // Owner should get almost everything, team should get almost nothing
        IVotingEscrow.LockedBalance memory newLocked = escrow.locked(newTokenId);
        IVotingEscrow.LockedBalance memory clawbackLocked = escrow.locked(clawbackTokenId);

        // With 1 second remaining out of 2 years, clawback should be minimal
        uint256 expectedClawback = (TOKEN_1 * 1) / TEAM_LOCK_DURATION;
        uint256 expectedOwner = TOKEN_1 - expectedClawback;

        assertEq(uint256(uint128(newLocked.amount)), expectedOwner);
        assertEq(uint256(uint128(clawbackLocked.amount)), expectedClawback);
    }

    function testTeamLockAfterUnlock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward past team unlock time
        vm.warp(teamUnlockTs + 1);

        // Unlock team lock
        escrow.unlockTeamLock(tokenId);

        // Now token should behave like a normal veNFT
        vm.prank(address(owner2));
        escrow.transferFrom(address(owner2), address(owner3), tokenId);

        assertEq(escrow.ownerOf(tokenId), address(owner3));
    }
}
