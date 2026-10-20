// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract VoterRebaseTest is BaseTest {
    function _createLock(bool permanent) internal returns (uint256 tokenId) {
        irs.approve(address(escrow), TOKEN_1M);
        tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        if (permanent) escrow.lockPermanent(tokenId);
    }

    /// @dev Preview the same rollover and claim in isolated state, including its voting power.
    function _preview(uint256 tokenId) internal returns (uint256 amount, uint256 votingPower) {
        uint256 snapshot = vm.snapshotState();
        minter.updatePeriod();
        amount = distributor.claim(tokenId);
        votingPower = escrow.balanceOfNFT(tokenId);
        assertTrue(vm.revertToState(snapshot));
    }

    function _voteOne(uint256 tokenId, uint256 votingPower) internal {
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = votingPower;
        voter.vote(tokenId, pools, amounts);
    }

    function testVoteRollsEpochClaimsRebaseAndUsesNewVotingPower() public {
        uint256 tokenId = _createLock(false);
        skipToNextEpoch(1 hours + 1);
        uint256 previousPeriod = minter.activePeriod();
        uint256 powerBefore = escrow.balanceOfNFT(tokenId);
        (uint256 rebase, uint256 expectedPower) = _preview(tokenId);
        assertGt(rebase, 0);
        assertGt(expectedPower, powerBefore);

        _voteOne(tokenId, expectedPower);

        assertGt(minter.activePeriod(), previousPeriod);
        assertEq(convert(escrow.locked(tokenId).amount), TOKEN_1M + rebase);
        assertEq(voter.votes(tokenId, address(pool)), expectedPower);
        assertEq(voter.usedWeights(tokenId), expectedPower);
        assertEq(distributor.claimable(tokenId), 0);
        assertEq(feesVotingReward.balanceOf(tokenId), expectedPower);
        assertEq(bribeVotingReward.balanceOf(tokenId), expectedPower);
    }

    function testVoteAcceptsExactPostRebaseAmountsAcrossPools() public {
        uint256 tokenId = _createLock(true);
        skipToNextEpoch(1 hours + 1);
        (uint256 rebase, uint256 expectedPower) = _preview(tokenId);
        assertGt(rebase, 0);
        assertEq(expectedPower, TOKEN_1M + rebase);

        address[] memory pools = new address[](2);
        pools[0] = address(pool);
        pools[1] = address(pool2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = expectedPower / 3;
        amounts[1] = expectedPower - amounts[0];
        voter.vote(tokenId, pools, amounts);

        assertEq(voter.votes(tokenId, address(pool)), amounts[0]);
        assertEq(voter.votes(tokenId, address(pool2)), amounts[1]);
        assertEq(voter.usedWeights(tokenId), expectedPower);
        assertEq(convert(escrow.locked(tokenId).amount), expectedPower);
    }

    function testVoteWithNoClaimableRebase() public {
        uint256 tokenId = _createLock(true);
        skipAndRoll(1 hours + 1);
        assertEq(distributor.claimable(tokenId), 0);

        _voteOne(tokenId, TOKEN_1M);

        assertEq(convert(escrow.locked(tokenId).amount), TOKEN_1M);
        assertEq(voter.votes(tokenId, address(pool)), TOKEN_1M);
    }

    function testVoteAfterManualRebaseClaimDoesNotCompoundTwice() public {
        uint256 tokenId = _createLock(true);
        skipToNextEpoch(1 hours + 1);
        minter.updatePeriod();
        uint256 rebase = distributor.claim(tokenId);
        assertGt(rebase, 0);
        uint256 lockedBefore = convert(escrow.locked(tokenId).amount);
        uint256 distributorBalanceBefore = irs.balanceOf(address(distributor));
        uint256 cursorBefore = distributor.timeCursorOf(tokenId);
        uint256 supplyBefore = irs.totalSupply();

        _voteOne(tokenId, lockedBefore);

        assertEq(convert(escrow.locked(tokenId).amount), lockedBefore);
        assertEq(voter.usedWeights(tokenId), lockedBefore);
        assertEq(voter.votes(tokenId, address(pool)), lockedBefore);
        assertEq(irs.balanceOf(address(distributor)), distributorBalanceBefore);
        assertEq(distributor.timeCursorOf(tokenId), cursorBefore);
        assertEq(irs.totalSupply(), supplyBefore);
        assertEq(distributor.claimable(tokenId), 0);
    }

    function testVoteCompoundsTeamLockUnderExistingVestingSchedule() public {
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId =
            escrow.createTeamLockFor(TOKEN_1M, MAXTIME, address(owner2), vm.getBlockTimestamp() + 2 * 365 days);
        IVotingEscrow.TeamLock memory teamBefore = escrow.teamLocks(tokenId);
        skipToNextEpoch(1 hours + 1);
        (uint256 rebase, uint256 expectedPower) = _preview(tokenId);
        assertGt(rebase, 0);
        uint256 liquidBefore = irs.balanceOf(address(owner2));

        // Team authorization covers voting on this lock without NFT ownership or approval.
        _voteOne(tokenId, expectedPower);

        assertEq(convert(escrow.locked(tokenId).amount), TOKEN_1M + rebase);
        assertEq(voter.usedWeights(tokenId), expectedPower);
        IVotingEscrow.TeamLock memory teamAfter = escrow.teamLocks(tokenId);
        assertEq(teamAfter.startTs, teamBefore.startTs);
        assertEq(teamAfter.endTs, teamBefore.endTs);
        assertEq(teamAfter.clawbacked, teamBefore.clawbacked);
        assertEq(irs.balanceOf(address(owner2)), liquidBefore);
    }

    function testVoteCompoundsManagedLockRebase() public {
        uint256 tokenId = _createLock(true);
        uint256 managedId = escrow.createManagedLockFor(address(owner));
        skipAndRoll(1 hours + 1);
        voter.depositManaged(tokenId, managedId);
        skipToNextEpoch(1 hours + 1);
        (uint256 rebase, uint256 expectedPower) = _preview(managedId);
        assertGt(rebase, 0);

        _voteOne(managedId, expectedPower);

        assertEq(convert(escrow.locked(managedId).amount), TOKEN_1M + rebase);
        assertEq(voter.usedWeights(managedId), expectedPower);
        assertEq(distributor.claimable(managedId), 0);
    }

    function testInvalidPoolRollsBackRolloverClaimAndPartialVote() public {
        _assertFailedVoteRollsBack(false);
    }

    function testDeadGaugeRollsBackRolloverClaimAndPartialVote() public {
        _assertFailedVoteRollsBack(true);
    }

    function _assertFailedVoteRollsBack(bool deadGauge) internal {
        uint256 tokenId = _createLock(true);
        if (deadGauge) voter.killGauge(address(gauge2));
        skipToNextEpoch(1 hours + 1);
        (uint256 rebase, uint256 expectedPower) = _preview(tokenId);
        assertGt(rebase, 0);
        uint256 previousPeriod = minter.activePeriod();
        uint256 previousCheckpoint = distributor.lastTokenTime();
        uint256 previousSupply = irs.totalSupply();
        uint256 previousDistributorBalance = irs.balanceOf(address(distributor));
        uint256 previousCursor = distributor.timeCursorOf(tokenId);

        address[] memory pools = new address[](2);
        pools[0] = address(pool);
        pools[1] = deadGauge ? address(pool2) : address(0xDEAD);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = expectedPower / 2;
        amounts[1] = expectedPower - amounts[0];
        if (deadGauge) {
            vm.expectRevert(abi.encodeWithSelector(IVoter.GaugeNotAlive.selector, address(gauge2)));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IVoter.GaugeDoesNotExist.selector, address(0xDEAD)));
        }
        voter.vote(tokenId, pools, amounts);

        assertEq(minter.activePeriod(), previousPeriod);
        assertEq(distributor.lastTokenTime(), previousCheckpoint);
        assertEq(distributor.timeCursorOf(tokenId), previousCursor);
        assertEq(irs.totalSupply(), previousSupply);
        assertEq(irs.balanceOf(address(distributor)), previousDistributorBalance);
        assertEq(convert(escrow.locked(tokenId).amount), TOKEN_1M);
        assertEq(voter.lastVoted(tokenId), 0);
        assertEq(voter.votes(tokenId, address(pool)), 0);
        assertEq(voter.totalWeight(), 0);
        assertEq(feesVotingReward.balanceOf(tokenId), 0);
        assertEq(bribeVotingReward.balanceOf(tokenId), 0);
        assertFalse(escrow.voted(tokenId));
    }
}
