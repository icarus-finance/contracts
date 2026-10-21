// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract RewardsDistributorTest is BaseTest {
    event Claimed(uint256 indexed tokenId, uint256 indexed epochStart, uint256 indexed epochEnd, uint256 amount);

    mapping(uint256 => uint256) internal expectedRebases;

    /// @dev Model funding from pre-mint supply and split it by elapsed time in each epoch.
    ///      This keeps exact rebate assertions independent of historic team-emission totals.
    function _updatePeriodAndModelRebase() internal {
        uint256 epoch = _getEpochStart(block.timestamp);
        if (epoch <= minter.activePeriod()) {
            minter.updatePeriod();
            return;
        }
        uint256 supply = irs.totalSupply();
        uint256 emission = minter.weekly();
        if (emission < minter.TAIL_START()) emission = (supply * minter.tailEmissionRate()) / minter.MAX_BPS();
        uint256 unlocked = supply - escrow.totalSupplyAt(epoch - 1);
        uint256 growth = (((emission * unlocked) / supply) * unlocked) / supply / 2;
        uint256 previousCheckpoint = distributor.lastTokenTime();
        uint256 balanceBefore = irs.balanceOf(address(distributor));
        for (uint256 week = _getEpochStart(previousCheckpoint); week <= epoch; week += WEEK) {
            uint256 start = week > previousCheckpoint ? week : previousCheckpoint;
            uint256 end = week + WEEK < block.timestamp ? week + WEEK : block.timestamp;
            expectedRebases[week] += (growth * (end - start)) / (block.timestamp - previousCheckpoint);
        }
        minter.updatePeriod();
        assertEq(irs.balanceOf(address(distributor)) - balanceBefore, growth);
        for (uint256 week = _getEpochStart(previousCheckpoint); week <= epoch; week += WEEK) {
            assertEq(distributor.tokensPerWeek(week), expectedRebases[week]);
        }
    }

    /// @dev Sum predicted buckets weighted by the NFT's historical share, after its last claim.
    function _expectedClaimable(uint256 id) internal view returns (uint256 expected) {
        uint256 cursor = distributor.timeCursorOf(id);
        if (cursor == 0) cursor = _getEpochStart(escrow.userPointHistory(id, 1).ts);
        uint256 end = _getEpochStart(distributor.lastTokenTime());
        for (uint256 week = cursor; week < end; week += WEEK) {
            uint256 supply = escrow.totalSupplyAt(week + WEEK - 1);
            if (supply != 0) {
                expected += (expectedRebases[week] * escrow.balanceOfNFTAt(id, week + WEEK - 1)) / supply;
            }
        }
    }

    function _setUp() public override {
        // timestamp: 604801
        irs.approve(address(escrow), TOKEN_1);
        uint256 tokenId = escrow.createLock(TOKEN_1, MAXTIME);
        skip(1);

        address[] memory pools = new address[](2);
        pools[0] = address(pool);
        pools[1] = address(pool2);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        skip(1 hours);
        voter.vote(tokenId, pools, weights);
    }

    function testInitialize() public view {
        assertEq(distributor.startTime(), 604800);
        assertEq(distributor.lastTokenTime(), 604800);
        assertEq(distributor.token(), address(irs));
        assertEq(address(distributor.ve()), address(escrow));
    }

    function testClaim() public {
        skipToNextEpoch(1 days); // epoch 1, ts: 1296000, blk: 2

        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(locked.end, 127008000);
        assertEq(locked.isPermanent, false);

        assertEq(escrow.userPointEpoch(tokenId), 1);
        IVotingEscrow.UserPoint memory userPoint = escrow.userPointHistory(tokenId, 1);
        assertEq(convert(userPoint.slope), TOKEN_1M / MAXTIME); // TOKEN_1M / MAXTIME
        assertEq(convert(userPoint.bias), 996575342465753345952000); // (TOKEN_1M / MAXTIME) * (127008000 - 1296000)
        assertEq(userPoint.ts, 1296000);
        assertEq(userPoint.blk, 2);

        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        locked = escrow.locked(tokenId2);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(locked.end, 127008000);
        assertEq(locked.isPermanent, false);

        assertEq(escrow.userPointEpoch(tokenId2), 1);
        userPoint = escrow.userPointHistory(tokenId2, 1);
        assertEq(convert(userPoint.slope), TOKEN_1M / MAXTIME); // TOKEN_1M / MAXTIME
        assertEq(convert(userPoint.bias), 996575342465753345952000); // (TOKEN_1M / MAXTIME) * (127008000 - 1296000)
        assertEq(userPoint.ts, 1296000);
        assertEq(userPoint.blk, 2);

        // epoch 2
        skipToNextEpoch(0); // distribute epoch 1's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 3
        skipToNextEpoch(0); // distribute epoch 2's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 4
        skipToNextEpoch(0); // distribute epoch 3's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 5
        skipToNextEpoch(0); // distribute epoch 4's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        IVotingEscrow.LockedBalance memory preLocked = escrow.locked(tokenId);
        uint256 expectedClaim = _expectedClaimable(tokenId);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit Claimed(tokenId, 1209600, 3628800, expectedClaim);
        distributor.claim(tokenId);
        IVotingEscrow.LockedBalance memory postLocked = escrow.locked(tokenId);
        assertEq(postLocked.amount - preLocked.amount, int128(int256(expectedClaim)));
        assertEq(postLocked.end, 127008000);
        assertEq(postLocked.isPermanent, false);
    }

    function testClaimWithPermanentLocks() public {
        skipToNextEpoch(1 days); // epoch 1, ts: 1296000, blk: 2

        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(locked.end, 0);
        assertEq(locked.isPermanent, true);

        assertEq(escrow.userPointEpoch(tokenId), 1);
        IVotingEscrow.UserPoint memory userPoint = escrow.userPointHistory(tokenId, 1);
        assertEq(convert(userPoint.slope), 0);
        assertEq(convert(userPoint.bias), 0);
        assertEq(userPoint.ts, 1296000);
        assertEq(userPoint.blk, 2);
        assertEq(userPoint.permanent, TOKEN_1M);

        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId2);
        vm.stopPrank();

        locked = escrow.locked(tokenId2);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(locked.end, 0);
        assertEq(locked.isPermanent, true);

        assertEq(escrow.userPointEpoch(tokenId2), 1);
        userPoint = escrow.userPointHistory(tokenId2, 1);
        assertEq(convert(userPoint.slope), 0);
        assertEq(convert(userPoint.bias), 0);
        assertEq(userPoint.ts, 1296000);
        assertEq(userPoint.blk, 2);
        assertEq(userPoint.permanent, TOKEN_1M);

        // epoch 2
        skipToNextEpoch(0); // distribute epoch 1's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 3
        skipToNextEpoch(0); // distribute epoch 2's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 4
        skipToNextEpoch(0); // distribute epoch 3's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 5
        skipToNextEpoch(0); // distribute epoch 4's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        IVotingEscrow.LockedBalance memory preLocked = escrow.locked(tokenId);
        uint256 expectedClaim = _expectedClaimable(tokenId);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit Claimed(tokenId, 1209600, 3628800, expectedClaim);
        distributor.claim(tokenId);
        IVotingEscrow.LockedBalance memory postLocked = escrow.locked(tokenId);
        assertEq(postLocked.amount - preLocked.amount, int128(int256(expectedClaim)));
        assertEq(postLocked.end, 0);
        assertEq(postLocked.isPermanent, true);
    }

    function testClaimWithBothLocks() public {
        skipToNextEpoch(1 days); // epoch 1, ts: 1296000, blk: 2

        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId);

        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // expect permanent lock to earn more rebases
        // epoch 2
        skipToNextEpoch(0); // distribute epoch 1's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 3
        skipToNextEpoch(0); // distribute epoch 2's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 4
        skipToNextEpoch(0); // distribute epoch 3's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        // epoch 5
        skipToNextEpoch(0); // distribute epoch 4's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        uint256 pre = convert(escrow.locked(tokenId).amount);
        uint256 expectedClaim = _expectedClaimable(tokenId);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit Claimed(tokenId, 1209600, 3628800, expectedClaim);
        distributor.claim(tokenId);
        uint256 post = convert(escrow.locked(tokenId).amount);

        assertEq(post - pre, expectedClaim);
    }

    function testClaimWithLockCreatedMoreThan50EpochsLater() public {
        for (uint256 i = 0; i < 55; i++) {
            skipToNextEpoch(0);
            _updatePeriodAndModelRebase();
        }

        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);

        skipToNextEpoch(0);
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        skipToNextEpoch(0);
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        uint256 pre = convert(escrow.locked(tokenId).amount);
        uint256 expectedClaim = _expectedClaimable(tokenId);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit Claimed(tokenId, 33868800, 35078400, expectedClaim);
        distributor.claim(tokenId);
        uint256 post = convert(escrow.locked(tokenId).amount);

        assertEq(post - pre, expectedClaim);
    }

    function testClaimWithIncreaseAmountOnEpochFlip() public {
        skipToNextEpoch(1 days); // epoch 1
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);

        skipToNextEpoch(0); // distribute epoch 1's rebases
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));

        skipToNextEpoch(0);
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));
        // making lock larger on flip should not impact claimable
        irs.approve(address(escrow), TOKEN_1M);
        escrow.increaseAmount(tokenId, TOKEN_1M);
        _updatePeriodAndModelRebase(); // epoch 1's rebases available
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));
    }

    function testClaimWithExpiredNFT() public {
        // test reward claims to expired NFTs are distributed as unlocked irs
        // ts: 608402
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, WEEK * 4);

        skipToNextEpoch(1);
        _updatePeriodAndModelRebase();
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));

        for (uint256 i = 0; i < 4; i++) {
            _updatePeriodAndModelRebase();
            skipToNextEpoch(1);
        }
        _updatePeriodAndModelRebase();

        assertGt(distributor.claimable(tokenId), 4996770462023280576149678); // accrued rebases

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertGt(vm.getBlockTimestamp(), locked.end); // lock expired

        uint256 rebase = distributor.claimable(tokenId);
        uint256 pre = irs.balanceOf(address(owner));
        uint256 expectedClaim = _expectedClaimable(tokenId);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit Claimed(tokenId, 604800, 3628800, expectedClaim);
        distributor.claim(tokenId);
        uint256 post = irs.balanceOf(address(owner));

        locked = escrow.locked(tokenId); // update locked value post claim
        assertEq(post - pre, rebase); // expired rebase distributed as unlocked irs
        assertEq(uint256(uint128(locked.amount)), TOKEN_1M); // expired nft locked balance unchanged
    }

    function testClaimManyWithExpiredNFT() public {
        // test claim many with one expired nft and one normal nft
        // ts: 608402
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, WEEK * 4);
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);

        skipToNextEpoch(1);
        minter.updatePeriod();
        assertEq(distributor.claimable(tokenId), 68580676158366995877271);
        assertEq(distributor.claimable(tokenId2), 4732064084665303035783005);

        for (uint256 i = 0; i < 4; i++) {
            minter.updatePeriod();
            skipToNextEpoch(1);
        }
        minter.updatePeriod();

        assertGt(distributor.claimable(tokenId), 0); // accrued rebases
        assertGt(distributor.claimable(tokenId2), 0);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertGt(vm.getBlockTimestamp(), locked.end); // lock expired

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = tokenId2;

        uint256 rebase = distributor.claimable(tokenId);
        uint256 rebase2 = distributor.claimable(tokenId2);

        uint256 pre = irs.balanceOf(address(owner));
        assertTrue(distributor.claimMany(tokenIds));
        uint256 post = irs.balanceOf(address(owner));

        locked = escrow.locked(tokenId); // update locked value post claim
        IVotingEscrow.LockedBalance memory postLocked2 = escrow.locked(tokenId2);

        assertEq(post - pre, rebase); // expired rebase distributed as unlocked irs
        assertEq(uint256(uint128(locked.amount)), TOKEN_1M); // expired nft locked balance unchanged
        assertEq(uint256(uint128(postLocked2.amount)) - uint256(uint128(locked.amount)), rebase2); // rebase accrued to normal nft
    }

    function testClaimRebaseWithManagedLocks() public {
        _updatePeriodAndModelRebase(); // does nothing
        irs.approve(address(escrow), type(uint256).max);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId2);
        uint256 mTokenId = escrow.createManagedLockFor(address(owner));

        voter.depositManaged(tokenId2, mTokenId);

        skipAndRoll(1 hours); // created at epoch 0 + 1 days + 1 hours
        uint256 tokenId3 = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId3);

        assertEq(distributor.claimable(tokenId), 0);
        assertEq(distributor.claimable(tokenId2), 0);
        assertEq(distributor.claimable(tokenId3), 0);
        assertEq(distributor.claimable(mTokenId), 0);

        skipToNextEpoch(0); // epoch 1
        _updatePeriodAndModelRebase();

        // epoch 0 rebases distributed
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), 0);
        assertEq(distributor.claimable(tokenId3), _expectedClaimable(tokenId3));
        assertEq(distributor.claimable(mTokenId), _expectedClaimable(mTokenId));

        skipAndRoll(1 days); // deposit @ epoch 1 + 1 days
        voter.depositManaged(tokenId3, mTokenId);

        skipToNextEpoch(0); // epoch 2
        _updatePeriodAndModelRebase();

        // epoch 1 rebases distributed
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), 0);
        assertEq(distributor.claimable(tokenId3), _expectedClaimable(tokenId3));
        assertEq(distributor.claimable(mTokenId), _expectedClaimable(mTokenId));
        distributor.claim(mTokenId); // claim token rewards
        assertEq(distributor.claimable(mTokenId), 0);

        uint256 tokenId4 = escrow.createLock(TOKEN_1M, MAXTIME); // lock created in epoch 2
        escrow.lockPermanent(tokenId4);

        skipToNextEpoch(1 hours); // epoch 3
        _updatePeriodAndModelRebase();

        // epoch 2 rebases distributed
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), 0);
        assertEq(distributor.claimable(tokenId3), _expectedClaimable(tokenId3)); // claimable unchanged
        assertEq(distributor.claimable(tokenId4), _expectedClaimable(tokenId4)); // claim rebases from last epoch
        assertEq(distributor.claimable(mTokenId), _expectedClaimable(mTokenId));

        skipToNextEpoch(0); // epoch 4
        _updatePeriodAndModelRebase();

        // rewards for epoch 2 locks
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), 0);
        assertEq(distributor.claimable(tokenId3), _expectedClaimable(tokenId3)); // claimable unchanged
        assertEq(distributor.claimable(tokenId4), _expectedClaimable(tokenId4));
        assertEq(distributor.claimable(mTokenId), _expectedClaimable(mTokenId));

        skipAndRoll(1 hours + 1);
        voter.withdrawManaged(tokenId3);

        for (uint256 i = 0; i <= 6; i++) {
            if (i == tokenId2) continue;
            distributor.claim(i);
            assertEq(distributor.claimable(i), 0);
        }

        assertLt(irs.balanceOf(address(distributor)), 100); // dust
    }

    function testClaimRebaseWithDepositManaged() public {
        _updatePeriodAndModelRebase(); // does nothing
        vm.startPrank(address(owner2));
        irs.approve(address(escrow), TOKEN_10M);
        uint256 tokenId = escrow.createLock(TOKEN_10M, MAXTIME);
        escrow.lockPermanent(tokenId);
        vm.stopPrank();

        vm.startPrank(address(owner3));
        irs.approve(address(escrow), TOKEN_10M);
        uint256 tokenId2 = escrow.createLock(TOKEN_10M, MAXTIME);
        escrow.lockPermanent(tokenId2);
        vm.stopPrank();
        uint256 mTokenId = escrow.createManagedLockFor(address(owner));

        assertEq(distributor.claimable(tokenId), 0);
        assertEq(distributor.claimable(tokenId2), 0);
        assertEq(distributor.claimable(mTokenId), 0);

        skipToNextEpoch(0); // epoch 1
        _updatePeriodAndModelRebase();

        // epoch 0 rebases distributed
        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));
        assertEq(distributor.claimable(mTokenId), 0);

        skipAndRoll(1 days);
        vm.prank(address(owner3));
        voter.depositManaged(tokenId2, mTokenId);

        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));
        assertEq(distributor.claimable(mTokenId), 0);

        skipToNextEpoch(1 hours); // epoch 2
        _updatePeriodAndModelRebase();

        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2)); // claimable unchanged
        assertEq(distributor.claimable(mTokenId), _expectedClaimable(mTokenId)); // rebase earned by tokenId2

        skipAndRoll(1);
        vm.prank(address(owner3));
        voter.withdrawManaged(tokenId2);

        skipToNextEpoch(0); // epoch 3
        _updatePeriodAndModelRebase();

        assertEq(distributor.claimable(tokenId), _expectedClaimable(tokenId));
        assertEq(distributor.claimable(tokenId2), _expectedClaimable(tokenId2));
        assertEq(distributor.claimable(mTokenId), _expectedClaimable(mTokenId)); // claimable unchanged
    }

    function testCannotClaimRebaseWithLockedNFT() public {
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId);
        uint256 mTokenId = escrow.createManagedLockFor(address(owner));

        skipToNextEpoch(2 hours); // epoch 1
        minter.updatePeriod();

        assertEq(distributor.claimable(tokenId), 4745500980370920284233136);
        assertEq(distributor.claimable(mTokenId), 0);

        voter.depositManaged(tokenId, mTokenId);

        skipToNextEpoch(1 days); // epoch 3
        minter.updatePeriod();

        vm.expectRevert(IRewardsDistributor.NotManagedOrNormalNFT.selector);
        distributor.claim(tokenId);
    }

    function testCannotClaimBeforeUpdatePeriod() public {
        irs.approve(address(escrow), type(uint256).max);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M * 8, MAXTIME);

        skipToNextEpoch(2 hours); // epoch 1
        minter.updatePeriod();

        assertEq(distributor.claimable(tokenId), 370382813492688374288331);
        assertEq(distributor.claimable(tokenId2), 2963062507941507227914498);

        skipToNextEpoch(1 hours); // epoch 3
        vm.expectRevert(IRewardsDistributor.UpdatePeriod.selector);
        distributor.claim(tokenId);

        skipAndRoll(1 hours);
        minter.updatePeriod();

        distributor.claim(tokenId);
    }

    function testCannotCheckpointTokenIfNotMinter() public {
        vm.expectRevert(IRewardsDistributor.NotMinter.selector);
        vm.prank(address(owner2));
        distributor.checkpointToken();
    }

    function testClaimBeforeLockedEnd() public {
        uint256 duration = WEEK * 12;
        vm.startPrank(address(owner));
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, duration);

        skipToNextEpoch(1);
        minter.updatePeriod();
        assertGt(distributor.claimable(tokenId), 0);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        vm.warp(locked.end - 1);
        assertEq(vm.getBlockTimestamp(), locked.end - 1);
        minter.updatePeriod();

        // Rebase should deposit into veNFT one second before expiry
        distributor.claim(tokenId);
        locked = escrow.locked(tokenId);
        assertGt(uint256(uint128((locked.amount))), TOKEN_1M);
    }

    function testClaimOnLockedEnd() public {
        uint256 duration = WEEK * 12;
        vm.startPrank(address(owner));
        irs.approve(address(escrow), TOKEN_1M);
        uint256 tokenId = escrow.createLock(TOKEN_1M, duration);

        skipToNextEpoch(1);
        minter.updatePeriod();
        assertGt(distributor.claimable(tokenId), 0);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        vm.warp(locked.end);
        assertEq(vm.getBlockTimestamp(), locked.end);
        minter.updatePeriod();

        // Rebase should deposit into veNFT one second before expiry
        uint256 balanceBefore = irs.balanceOf(address(owner));
        distributor.claim(tokenId);
        assertGt(irs.balanceOf(address(owner)), balanceBefore);
    }
}
