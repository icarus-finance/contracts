// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";
import {IVotingEscrow} from "contracts/interfaces/IVotingEscrow.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";

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
        deal(address(irs), address(owner), TOKEN_100M);
        irs.approve(address(escrow), TOKEN_100M);

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

    function testCannotMergeIntoTeamLockWithoutSourceApproval() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId1 = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 tokenId2 = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Owning the destination does not authorize burning someone else's source NFT.
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

    // Test isApprovedOrOwner behavior for team locks
    function testTeamIsApprovedForActiveTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Team should be approved for active team lock
        assertTrue(escrow.isApprovedOrOwner(address(owner), tokenId), "Team should be approved before expiry");
    }

    function testTeamIsNotApprovedForExpiredTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward past team lock expiry
        vm.warp(teamUnlockTs + 1);

        // Team should NOT be approved after team lock expires
        assertFalse(escrow.isApprovedOrOwner(address(owner), tokenId), "Team should not be approved after expiry");

        // Only the actual owner should be approved
        assertTrue(escrow.isApprovedOrOwner(address(owner2), tokenId), "Owner should still be approved");
    }

    function testOwnerCanStillVoteOnExpiredTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward past team lock expiry
        vm.warp(teamUnlockTs + 1);

        // Move to valid voting window
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(epochStart + 2 hours);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        // Owner should still be able to vote after team lock expires
        vm.prank(address(owner2));
        voter.vote(tokenId, pools, weights);
        assertTrue(escrow.voted(tokenId), "Owner should be able to vote after expiry");
    }

    function testCanIncreaseAmountOnTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
        IVotingEscrow.LockedBalance memory beforeLock = escrow.locked(tokenId);
        uint256 supplyBefore = escrow.supply();
        uint256 escrowBalanceBefore = irs.balanceOf(address(escrow));

        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(tokenId, TOKEN_1);
        vm.stopPrank();

        IVotingEscrow.LockedBalance memory afterLock = escrow.locked(tokenId);
        assertEq(uint256(uint128(afterLock.amount)), TOKEN_1 * 2);
        assertEq(afterLock.end, beforeLock.end);
        assertEq(escrow.supply(), supplyBefore + TOKEN_1);
        assertEq(irs.balanceOf(address(escrow)), escrowBalanceBefore + TOKEN_1);
        assertEq(escrow.teamLocks(tokenId).endTs, teamUnlockTs);
    }

    function testCannotIncreaseTeamLockAmountWithoutApproval() public {
        uint256 tokenId = escrow.createTeamLockFor(
            TOKEN_1, MAXTIME, address(owner2), block.timestamp + TEAM_LOCK_DURATION
        );
        vm.prank(address(owner3));
        vm.expectRevert(IVotingEscrow.NotApprovedOrOwner.selector);
        escrow.increaseAmount(tokenId, TOKEN_1);
    }

    function testAnyoneCanDepositForTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
        uint256 supplyBefore = escrow.supply();
        uint256 payerBalanceBefore = irs.balanceOf(address(owner3));

        vm.startPrank(address(owner3));
        irs.approve(address(escrow), TOKEN_1);
        escrow.depositFor(tokenId, TOKEN_1);
        vm.stopPrank();

        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1 * 2);
        assertEq(escrow.supply(), supplyBefore + TOKEN_1);
        assertEq(irs.balanceOf(address(owner3)), payerBalanceBefore - TOKEN_1);
        assertEq(escrow.ownerOf(tokenId), address(owner2));
        assertEq(escrow.teamLocks(tokenId).endTs, teamUnlockTs);
    }

    function testTeamNeedsNftApprovalToIncreaseAmountDespiteVotingAuthority() public {
        uint256 tokenId = escrow.createTeamLockFor(
            TOKEN_1, MAXTIME, address(owner2), block.timestamp + TEAM_LOCK_DURATION
        );
        uint256 teamBalanceBefore = irs.balanceOf(address(owner));
        uint256 recipientBalanceBefore = irs.balanceOf(address(owner2));
        assertTrue(escrow.isApprovedOrOwner(address(owner), tokenId), "team can vote");

        vm.expectRevert(IVotingEscrow.NotApprovedOrOwner.selector);
        escrow.increaseAmount(tokenId, TOKEN_1);
        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1);
        assertEq(irs.balanceOf(address(owner)), teamBalanceBefore);

        vm.prank(address(owner2));
        escrow.approve(address(owner), tokenId);
        escrow.increaseAmount(tokenId, TOKEN_1);
        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1 * 2);
        assertEq(irs.balanceOf(address(owner)), teamBalanceBefore - TOKEN_1, "approved caller funds addition");
        assertEq(irs.balanceOf(address(owner2)), recipientBalanceBefore, "owner does not fund operator deposit");
        assertEq(escrow.ownerOf(tokenId), address(owner2));
    }

    function testExpiredEscrowTeamLockRejectsAdditionsWithoutMovingFunds() public {
        uint256 teamEnd = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, 2 weeks, address(owner2), teamEnd);
        IVotingEscrow.LockedBalance memory beforeLock = escrow.locked(tokenId);
        uint256 source = escrow.createLockFor(TOKEN_1, MAXTIME, address(owner2));
        uint256 supplyBefore = escrow.supply();
        uint256 payerBefore = irs.balanceOf(address(owner));
        uint256 escrowBalanceBefore = irs.balanceOf(address(escrow));
        vm.warp(beforeLock.end);

        vm.expectRevert(IVotingEscrow.LockExpired.selector);
        escrow.depositFor(tokenId, TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        vm.expectRevert(IVotingEscrow.LockExpired.selector);
        escrow.increaseAmount(tokenId, TOKEN_1);
        vm.expectRevert(IVotingEscrow.LockExpired.selector);
        escrow.merge(source, tokenId);
        vm.stopPrank();

        assertEq(escrow.locked(tokenId).amount, beforeLock.amount);
        assertEq(escrow.locked(tokenId).end, beforeLock.end);
        assertEq(escrow.teamLocks(tokenId).endTs, teamEnd);
        assertEq(escrow.ownerOf(source), address(owner2), "failed merge preserves source");
        assertEq(uint256(uint128(escrow.locked(source).amount)), TOKEN_1);
        assertEq(escrow.supply(), supplyBefore);
        assertEq(irs.balanceOf(address(owner)), payerBefore);
        assertEq(irs.balanceOf(address(escrow)), escrowBalanceBefore);
    }

    function testAdditionsAndIncomingMergeParticipateInClawback() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, 365 days, address(owner2), teamUnlockTs);
        uint256 startTs = escrow.teamLocks(tokenId).startTs;
        uint256 source = escrow.createLockFor(TOKEN_1, MAXTIME, address(owner2));
        uint256 sourceEnd = escrow.locked(source).end;
        uint256 supplyBefore = escrow.supply();
        uint256 escrowBalanceBefore = irs.balanceOf(address(escrow));

        vm.warp(startTs + TEAM_LOCK_DURATION / 4);
        escrow.depositFor(tokenId, TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(tokenId, TOKEN_1);
        escrow.merge(source, tokenId);
        vm.stopPrank();

        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1 * 4);
        assertEq(escrow.locked(tokenId).end, sourceEnd);
        assertEq(escrow.ownerOf(source), address(0));
        assertEq(escrow.locked(source).amount, 0);
        assertEq(escrow.supply(), supplyBefore + TOKEN_1 * 2);
        assertEq(irs.balanceOf(address(escrow)), escrowBalanceBefore + TOKEN_1 * 2);
        assertEq(escrow.teamLocks(tokenId).startTs, startTs);
        assertEq(escrow.teamLocks(tokenId).endTs, teamUnlockTs);

        (uint256 retained, uint256 clawback) = escrow.clawbackTeamLock(tokenId);
        assertEq(uint256(uint128(escrow.locked(retained).amount)), TOKEN_1);
        assertEq(uint256(uint128(escrow.locked(clawback).amount)), TOKEN_1 * 3);
        assertEq(escrow.supply(), supplyBefore + TOKEN_1 * 2);
        assertEq(escrow.ownerOf(retained), address(owner2));
        assertEq(escrow.ownerOf(clawback), address(owner));
    }

    function testTeamCanMergeOwnedNormalLockIntoApprovedTeamLock() public {
        uint256 tokenId = escrow.createTeamLockFor(
            TOKEN_1, MAXTIME, address(owner2), block.timestamp + TEAM_LOCK_DURATION
        );
        uint256 source = escrow.createLock(TOKEN_1, MAXTIME);
        vm.expectRevert(IVotingEscrow.NotApprovedOrOwner.selector);
        escrow.merge(source, tokenId);
        vm.prank(address(owner2));
        escrow.approve(address(owner), tokenId);
        escrow.merge(source, tokenId);
        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1 * 2);
        assertEq(escrow.ownerOf(tokenId), address(owner2));
        assertEq(escrow.ownerOf(source), address(0));
    }

    function testPermanentTeamLockAdditionsAndMergeAccounting() public {
        uint256 tokenId = escrow.createTeamLockFor(
            TOKEN_1, MAXTIME, address(owner2), block.timestamp + TEAM_LOCK_DURATION
        );
        uint256 source = escrow.createLockFor(TOKEN_1, MAXTIME, address(owner2));
        vm.prank(address(owner2));
        escrow.lockPermanent(tokenId);
        uint256 permanentBefore = escrow.permanentLockBalance();
        uint256 supplyBefore = escrow.supply();

        escrow.depositFor(tokenId, TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(tokenId, TOKEN_1);
        escrow.merge(source, tokenId);
        vm.stopPrank();

        assertTrue(escrow.locked(tokenId).isPermanent);
        assertEq(escrow.locked(tokenId).end, 0);
        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1 * 4);
        assertEq(escrow.permanentLockBalance(), permanentBefore + TOKEN_1 * 3);
        assertEq(escrow.supply(), supplyBefore + TOKEN_1 * 2);
    }

    function testClawbackedTeamLockAcceptsAdditionsButCannotMergeOut() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
        vm.warp(block.timestamp + TEAM_LOCK_DURATION / 2);
        (uint256 retained, ) = escrow.clawbackTeamLock(tokenId);
        uint256 source = escrow.createLockFor(TOKEN_1, MAXTIME, address(owner2));

        escrow.depositFor(retained, TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(retained, TOKEN_1);
        escrow.merge(source, retained);
        vm.stopPrank();
        assertEq(uint256(uint128(escrow.locked(retained).amount)), TOKEN_1 / 2 + TOKEN_1 * 3);
        assertTrue(escrow.teamLocks(retained).clawbacked);
        assertEq(escrow.teamLocks(retained).endTs, teamUnlockTs);

        vm.expectRevert(IVotingEscrow.AlreadyClawbacked.selector);
        escrow.clawbackTeamLock(retained);
        assertEq(uint256(uint128(escrow.locked(retained).amount)), TOKEN_1 / 2 + TOKEN_1 * 3);

        uint256 destination = escrow.createLockFor(TOKEN_1, MAXTIME, address(owner2));
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.merge(retained, destination);
    }

    function testExpiredTeamRestrictionPersistsUntilExplicitUnlock() public {
        uint256 teamUnlockTs = block.timestamp + 1 weeks;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);
        uint256 destination = escrow.createLockFor(TOKEN_1, MAXTIME, address(owner2));
        vm.warp(teamUnlockTs);
        escrow.depositFor(tokenId, TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(tokenId, TOKEN_1);
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.merge(tokenId, destination);
        vm.stopPrank();

        escrow.unlockTeamLock(tokenId);
        vm.prank(address(owner2));
        escrow.merge(tokenId, destination);
        assertEq(uint256(uint128(escrow.locked(destination).amount)), TOKEN_1 * 4);
        assertEq(escrow.teamLocks(destination).endTs, 0);
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

    // Test claiming irs from RewardsDistributor on team locks
    function testCanClaimIrsFromRewardsDistributorOnTeamLock() public {
        // Start from epoch 1
        skipToNextEpoch(1 days);

        // Create a team lock
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1M, MAXTIME, address(owner2), teamUnlockTs);

        IVotingEscrow.LockedBalance memory initialLocked = escrow.locked(tokenId);
        assertEq(uint256(uint128(initialLocked.amount)), TOKEN_1M);
        assertGt(initialLocked.end, block.timestamp);
        assertFalse(initialLocked.isPermanent);

        // Verify team lock is set
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertGt(teamLock.endTs, block.timestamp);
        assertFalse(teamLock.clawbacked);

        // Progress to epoch 2 so rebases can be distributed
        skipToNextEpoch(0);
        minter.updatePeriod();

        // Check claimable amount
        uint256 claimableAmount = distributor.claimable(tokenId);
        assertGt(claimableAmount, 0, "Should have claimable rewards");

        // Claim rewards through the actual distributor compounding path.
        uint256 balanceBeforeClaim = irs.balanceOf(address(owner2));
        distributor.claim(tokenId);

        // Since the lock is not expired, rewards should be deposited back into the lock
        IVotingEscrow.LockedBalance memory lockedAfterClaim = escrow.locked(tokenId);
        assertEq(
            uint256(uint128(lockedAfterClaim.amount)),
            uint256(uint128(initialLocked.amount)) + claimableAmount,
            "Claimed rewards should be added to lock amount"
        );

        // Owner should not receive tokens directly since lock is still active
        uint256 balanceAfterClaim = irs.balanceOf(address(owner2));
        assertEq(balanceAfterClaim, balanceBeforeClaim, "Owner should not receive tokens directly for active lock");

        // Verify team lock is still intact
        IVotingEscrow.TeamLock memory teamLockAfter = escrow.teamLocks(tokenId);
        assertEq(teamLockAfter.endTs, teamLock.endTs, "Team lock should remain unchanged");

        uint256 compoundedAmount = TOKEN_1M + claimableAmount;
        uint256 expectedClawback = (compoundedAmount * (teamLock.endTs - block.timestamp)) /
            (teamLock.endTs - teamLock.startTs);
        (uint256 retained, uint256 clawback) = escrow.clawbackTeamLock(tokenId);
        assertEq(uint256(uint128(escrow.locked(clawback).amount)), expectedClawback);
        assertEq(uint256(uint128(escrow.locked(retained).amount)), compoundedAmount - expectedClawback);
    }

    function testCannotVoteWhenTeamLockBlacklisted() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Move to valid voting window
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(epochStart + 2 hours);

        // Blacklist the team lock before voting
        voter.blacklistVotingTeamLock(tokenId);

        // Setup vote parameters
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        // Try to vote - should fail because blacklisted
        vm.prank(address(owner2));
        vm.expectRevert(IVoter.TeamLockBlacklisted.selector);
        voter.vote(tokenId, pools, weights);
    }

    function testCannotPokeWhenTeamLockBlacklisted() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Move to valid voting window
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(epochStart + 2 hours);

        // First vote to set up state
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        vm.prank(address(owner2));
        voter.vote(tokenId, pools, weights);

        // Move to next epoch
        skipToNextEpoch(1);
        vm.warp((block.timestamp / WEEK) * WEEK + 2 hours);

        // Blacklist the team lock
        voter.blacklistVotingTeamLock(tokenId);

        // Try to poke - should fail
        vm.expectRevert(IVoter.TeamLockBlacklisted.selector);
        voter.poke(tokenId);
    }

    function testCanVoteAfterBlacklistExpires() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Move to valid voting window
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(epochStart + 2 hours);

        // Blacklist the team lock
        voter.blacklistVotingTeamLock(tokenId);

        // Verify blacklist is active
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        vm.prank(address(owner2));
        vm.expectRevert(IVoter.TeamLockBlacklisted.selector);
        voter.vote(tokenId, pools, weights);

        // Fast forward past blacklist period (1 day + buffer)
        skip(1 days + 1);

        // Now should be able to vote
        vm.prank(address(owner2));
        voter.vote(tokenId, pools, weights);
        assertTrue(escrow.voted(tokenId), "Should be able to vote after blacklist expires");
    }

    function testCannotBlacklistTeamLockIfNotTeam() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Try to blacklist as non-team
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.NotTeam.selector);
        voter.blacklistVotingTeamLock(tokenId);
    }

    function testCannotBlacklistNonTeamLock() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);

        // Try to blacklist a normal lock
        vm.expectRevert(IVotingEscrow.NotTeamLock.selector);
        voter.blacklistVotingTeamLock(tokenId);
    }

    function testCannotBlacklistClawbackedTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Fast forward and clawback
        vm.warp(block.timestamp + TEAM_LOCK_DURATION / 2);
        (uint256 newTokenId, ) = escrow.clawbackTeamLock(tokenId);

        // Try to blacklist the clawbacked token
        vm.expectRevert(IVotingEscrow.AlreadyClawbacked.selector);
        voter.blacklistVotingTeamLock(newTokenId);
    }

    function testCannotBlacklistAlreadyBlacklistedTeamLock() public {
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Blacklist once
        voter.blacklistVotingTeamLock(tokenId);

        // Try to blacklist again immediately
        vm.expectRevert(IVoter.TeamLockBlacklisted.selector);
        voter.blacklistVotingTeamLock(tokenId);
    }

    // Test depositManaged restrictions on team locks
    function testCannotDepositManagedWithTeamLock() public {
        // Create a managed NFT as owner3
        escrow.setAllowedManager(address(owner3));
        vm.prank(address(owner3));
        uint256 mTokenId = escrow.createManagedLockFor(address(owner3));

        // Create a team locked NFT (owner as team, owner2 as token owner)
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner3), teamUnlockTs);

        // Skip to avoid distribute window restrictions
        skip(1 hours);

        // Try to deposit the team locked NFT into managed NFT - should fail
        vm.prank(address(owner3));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        voter.depositManaged(tokenId, mTokenId);
    }

    function testCanDepositManagedAfterTeamUnlock() public {
        // Create a managed NFT as owner3
        escrow.setAllowedManager(address(owner3));
        vm.prank(address(owner3));
        uint256 mTokenId = escrow.createManagedLockFor(address(owner3));

        // Create a team locked NFT (owner as team, owner3 as token owner)
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner3), teamUnlockTs);

        // Fast forward past team unlock time
        vm.warp(teamUnlockTs + 1);

        // Unlock the team lock
        escrow.unlockTeamLock(tokenId);

        // Skip to avoid distribute window restrictions
        skip(1 hours);

        // Now deposit should succeed since it's no longer a team lock
        vm.prank(address(owner3));
        voter.depositManaged(tokenId, mTokenId);

        // Verify the NFT is now locked to the managed NFT
        assertEq(uint256(escrow.escrowType(tokenId)), uint256(IVotingEscrow.EscrowType.LOCKED));
        assertEq(escrow.idToManaged(tokenId), mTokenId);
    }

    function testCreateTeamLockForExistingToken() public {
        // Team creates a normal lock
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        assertEq(escrow.ownerOf(tokenId), address(owner));

        // Verify no team lock initially
        IVotingEscrow.TeamLock memory teamLockBefore = escrow.teamLocks(tokenId);
        assertEq(teamLockBefore.endTs, 0);

        // Team transfers it with a team lock to owner2
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Verify transfer occurred
        assertEq(escrow.ownerOf(tokenId), address(owner2));

        // Verify team lock was applied
        IVotingEscrow.TeamLock memory teamLockAfter = escrow.teamLocks(tokenId);
        assertEq(teamLockAfter.startTs, block.timestamp);
        assertEq(teamLockAfter.endTs, teamUnlockTs);
        assertFalse(teamLockAfter.clawbacked);

        // Verify lock data remains unchanged
        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertEq(uint256(uint128(locked.amount)), TOKEN_1);
        assertEq(locked.end, ((block.timestamp + MAXTIME) / WEEK) * WEEK);
    }

    function testCreateTeamLockForExistingTokenToSameOwner() public {
        // Team creates a normal lock
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        
        // Team can transfer it to itself with a team lock
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        escrow.createTeamLockFor(tokenId, address(owner), teamUnlockTs);

        // Still owned by team but now team locked
        assertEq(escrow.ownerOf(tokenId), address(owner));
        
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.endTs, teamUnlockTs);
    }

    function testCannotCreateTeamLockForExistingTokenIfNotTeam() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;

        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.NotTeam.selector);
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);
    }

    function testCannotCreateTeamLockForTokenNotOwnedByTeam() public {
        // Owner2 creates a lock (not team)
        deal(address(irs), address(owner2), TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        vm.stopPrank();

        // Team tries to team lock it without approval
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        vm.expectRevert(IVotingEscrow.NotApprovedOrOwner.selector);
        escrow.createTeamLockFor(tokenId, address(owner3), teamUnlockTs);
    }

    function testCreateTeamLockForTokenOwnedByTeam() public {
        // Team creates a lock and keeps it
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        assertEq(escrow.ownerOf(tokenId), address(owner));

        // Team transfers it with team lock to owner3
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        escrow.createTeamLockFor(tokenId, address(owner3), teamUnlockTs);

        // Verify transfer and team lock
        assertEq(escrow.ownerOf(tokenId), address(owner3));
        
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.endTs, teamUnlockTs);
    }

    function testCannotCreateTeamLockForExistingTokenWithPastUnlockTime() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp; // Not in future

        vm.expectRevert(IVotingEscrow.LockDurationNotInFuture.selector);
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);
    }

    function testCreateTeamLockForExistingTokenRestrictsTransfer() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Owner2 cannot transfer it
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.transferFrom(address(owner2), address(owner3), tokenId);
    }

    function testCreateTeamLockForExistingTokenRestrictsMerge() public {
        uint256 tokenId1 = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId1, address(owner2), teamUnlockTs);

        // Create another lock for owner2
        deal(address(irs), address(owner2), TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        uint256 tokenId2 = escrow.createLock(TOKEN_1, MAXTIME);
        
        // Cannot merge team locked token
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.merge(tokenId1, tokenId2);
        vm.stopPrank();
    }

    function testCreateTeamLockForExistingTokenRestrictsSplit() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Owner2 cannot split it
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.split(tokenId, TOKEN_1 / 2);
    }

    function testCreateTeamLockForExistingTokenRestrictsWithdraw() public {
        uint256 tokenId = escrow.createLock(1 weeks, 1 weeks);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Fast forward past lock expiry but not team lock
        vm.warp(block.timestamp + 2 weeks);

        // Owner2 cannot withdraw
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.withdraw(tokenId);
    }

    function testCreateTeamLockForExistingTokenAllowsIncreaseAmount() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // The converted lock accepts owner-funded top-ups.
        deal(address(irs), address(owner2), TOKEN_1);
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1);
        escrow.increaseAmount(tokenId, TOKEN_1);
        vm.stopPrank();
        assertEq(uint256(uint128(escrow.locked(tokenId).amount)), TOKEN_1 * 2);
        assertEq(escrow.teamLocks(tokenId).endTs, teamUnlockTs);
    }

    function testCreateTeamLockForExistingTokenAllowsIncreaseUnlockTime() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, 1 weeks);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        IVotingEscrow.LockedBalance memory lockBefore = escrow.locked(tokenId);

        // Owner2 can increase unlock time
        vm.prank(address(owner2));
        escrow.increaseUnlockTime(tokenId, MAXTIME);

        IVotingEscrow.LockedBalance memory lockAfter = escrow.locked(tokenId);
        assertGt(lockAfter.end, lockBefore.end);
    }

    function testCreateTeamLockForExistingTokenCanBeUnlockedAfterExpiry() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Fast forward past team unlock
        vm.warp(teamUnlockTs + 1);

        // Anyone can unlock the team lock
        escrow.unlockTeamLock(tokenId);

        // Now owner2 can transfer freely
        vm.prank(address(owner2));
        escrow.transferFrom(address(owner2), address(owner3), tokenId);

        assertEq(escrow.ownerOf(tokenId), address(owner3));
    }

    function testCreateTeamLockForExistingTokenCanBeClawbacked() public {
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Fast forward to midpoint
        vm.warp(block.timestamp + TEAM_LOCK_DURATION / 2);

        // Team can clawback
        (uint256 newTokenId, uint256 clawbackTokenId) = escrow.clawbackTeamLock(tokenId);

        // Verify split
        assertEq(escrow.ownerOf(newTokenId), address(owner2));
        assertEq(escrow.ownerOf(clawbackTokenId), address(owner));

        // Amounts should be split 50/50
        IVotingEscrow.LockedBalance memory newLocked = escrow.locked(newTokenId);
        IVotingEscrow.LockedBalance memory clawbackLocked = escrow.locked(clawbackTokenId);

        assertEq(uint256(uint128(newLocked.amount)), TOKEN_1 / 2);
        assertEq(uint256(uint128(clawbackLocked.amount)), TOKEN_1 - TOKEN_1 / 2);
    }

    // Note: Voting behavior is already tested in testTeamCanVoteOnTeamLock and testOwnerCanAlsoVoteOnTeamLock
    // The createTeamLockFor(tokenId) overload doesn't change voting behavior

    function testCannotTeamLockAlreadyTeamLockedToken() public {
        // Create token with team lock using original function
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(owner2), teamUnlockTs);

        // Verify it has team lock
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.endTs, teamUnlockTs);
        
        // Owner2 cannot transfer it back to team due to team lock restriction
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.transferFrom(address(owner2), address(owner), tokenId);
    }

    function testCannotCreateTeamLockForAlreadyTeamLockedToken() public {
        // Create token with team lock using original function
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        uint256 tokenId = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(this), teamUnlockTs);

        // Verify it has team lock
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.endTs, teamUnlockTs);
        
        // Team tries to apply another team lock to already team-locked token
        // This fails because the token is owned by owner2, not team
        uint256 newTeamUnlockTs = block.timestamp + TEAM_LOCK_DURATION * 2;
        vm.expectRevert(IVotingEscrow.TeamLocked.selector);
        escrow.createTeamLockFor(tokenId, address(owner3), newTeamUnlockTs);
    }

    function testCreateTeamLockForExistingPermanentToken() public {
        // Create permanent lock
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        escrow.lockPermanent(tokenId);

        IVotingEscrow.LockedBalance memory lockBefore = escrow.locked(tokenId);
        assertTrue(lockBefore.isPermanent);

        // Team can still transfer it with team lock
        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;
        escrow.createTeamLockFor(tokenId, address(owner2), teamUnlockTs);

        // Verify transfer and team lock
        assertEq(escrow.ownerOf(tokenId), address(owner2));
        
        IVotingEscrow.TeamLock memory teamLock = escrow.teamLocks(tokenId);
        assertEq(teamLock.endTs, teamUnlockTs);

        // Should still be permanent
        IVotingEscrow.LockedBalance memory lockAfter = escrow.locked(tokenId);
        assertTrue(lockAfter.isPermanent);
    }

    function testCreateTeamLockForMultipleTokensSequentially() public {
        // Create multiple tokens
        uint256 tokenId1 = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 tokenId3 = escrow.createLock(TOKEN_1, MAXTIME);

        uint256 teamUnlockTs = block.timestamp + TEAM_LOCK_DURATION;

        // Team lock all of them to different owners
        escrow.createTeamLockFor(tokenId1, address(owner2), teamUnlockTs);
        escrow.createTeamLockFor(tokenId2, address(owner3), teamUnlockTs);
        escrow.createTeamLockFor(tokenId3, address(owner4), teamUnlockTs);

        // Verify all transfers and team locks
        assertEq(escrow.ownerOf(tokenId1), address(owner2));
        assertEq(escrow.ownerOf(tokenId2), address(owner3));
        assertEq(escrow.ownerOf(tokenId3), address(owner4));

        assertEq(escrow.teamLocks(tokenId1).endTs, teamUnlockTs);
        assertEq(escrow.teamLocks(tokenId2).endTs, teamUnlockTs);
        assertEq(escrow.teamLocks(tokenId3).endTs, teamUnlockTs);
    }
}
