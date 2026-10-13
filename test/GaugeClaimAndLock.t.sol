// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RecordingClaimHook {
    uint256 public calls;
    uint256 public tokenId;
    uint256 public amountLocked;
    address public user;
    address public caller;
    address public gaugeArg;
    address public pool;
    address public failGauge;
    mapping(address => uint256) public callsByGauge;
    mapping(address => address) public poolsByGauge;
    bool public fail;
    bool public reenter;
    bool public reentryBlocked;

    error HookFailed();

    function configure(bool _fail, bool _reenter) external {
        fail = _fail;
        reenter = _reenter;
    }

    function setFailGauge(address _gauge) external {
        failGauge = _gauge;
    }

    function onClaim(uint256 _tokenId, uint256 _amountLocked, address _user, address _gauge) external {
        require(msg.sender == _gauge, "caller mismatch");
        if (fail || _gauge == failGauge) revert HookFailed();
        gaugeArg = _gauge;
        pool = IVoter(Gauge(_gauge).voter()).poolForGauge(_gauge);
        callsByGauge[_gauge]++;
        poolsByGauge[_gauge] = pool;
        calls++;
        tokenId = _tokenId;
        amountLocked = _amountLocked;
        user = _user;
        caller = msg.sender;
        if (reenter) {
            try Gauge(msg.sender).getReward(_user) {
                revert("reentry succeeded");
            } catch (bytes memory reason) {
                reentryBlocked = bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
            }
        }
    }
}

contract GaugeClaimAndLockTest is BaseTest {
    RecordingClaimHook internal hook;

    function _setUp() public override {
        hook = new RecordingClaimHook();
        skipToNextEpoch(0);
    }

    function _accrue() internal returns (uint256) {
        pool.approve(address(gauge), POOL_1);
        gauge.deposit(POOL_1);
        _addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        skip(1 days);
        uint256 reward = gauge.earned(address(this));
        assertGt(reward, 0);
        return reward;
    }

    function _createLock(uint256 duration) internal returns (uint256) {
        AERO.approve(address(escrow), TOKEN_1);
        return escrow.createLock(TOKEN_1, duration);
    }

    function _assertHook(uint256 id, uint256 amount) internal view {
        assertEq(hook.calls(), 1);
        assertEq(hook.tokenId(), id);
        assertEq(hook.amountLocked(), amount);
        assertEq(hook.user(), address(this));
        assertEq(hook.caller(), address(gauge));
        assertEq(hook.gaugeArg(), address(gauge));
        assertEq(hook.pool(), address(pool));
    }

    function testClaimCreatesNewLockWithoutWalletApproval() public {
        uint256 reward = _accrue();
        uint256 balanceBefore = AERO.balanceOf(address(this));
        uint256 escrowBefore = AERO.balanceOf(address(escrow));
        voter.setClaimHook(address(hook));
        uint256 id = gauge.getRewardAndLock(address(this), 0, MAXTIME);
        assertEq(escrow.ownerOf(id), address(this));
        assertEq(convert(escrow.locked(id).amount), reward);
        assertEq(escrow.locked(id).end, ((block.timestamp + MAXTIME) / WEEK) * WEEK);
        assertEq(AERO.balanceOf(address(this)), balanceBefore);
        assertEq(AERO.balanceOf(address(escrow)), escrowBefore + reward);
        assertEq(AERO.allowance(address(gauge), address(escrow)), 0);
        assertEq(gauge.earned(address(this)), 0);
        _assertHook(id, reward);
    }

    function testClaimAddsToExistingLockAndPreservesExpiry() public {
        uint256 id = _createLock(MAXTIME);
        uint256 expiry = escrow.locked(id).end;
        uint256 reward = _accrue();
        uint256 balanceBefore = AERO.balanceOf(address(this));
        voter.setClaimHook(address(hook));
        assertEq(gauge.getRewardAndLock(address(this), id, 0), id);
        assertEq(convert(escrow.locked(id).amount), TOKEN_1 + reward);
        assertEq(escrow.locked(id).end, expiry);
        assertEq(AERO.balanceOf(address(this)), balanceBefore);
        assertEq(AERO.allowance(address(gauge), address(escrow)), 0);
        _assertHook(id, reward);
    }

    function testClaimAddsToPermanentLock() public {
        uint256 id = _createLock(MAXTIME);
        escrow.lockPermanent(id);
        uint256 reward = _accrue();
        uint256 permanentBefore = escrow.permanentLockBalance();
        gauge.getRewardAndLock(address(this), id, 0);
        assertTrue(escrow.locked(id).isPermanent);
        assertEq(convert(escrow.locked(id).amount), TOKEN_1 + reward);
        assertEq(escrow.permanentLockBalance(), permanentBefore + reward);
    }

    function testLiquidClaimHookReceivesZeroIdAndZeroLockedAmount() public {
        uint256 reward = _accrue();
        uint256 balanceBefore = AERO.balanceOf(address(this));
        voter.setClaimHook(address(hook));
        gauge.getReward(address(this));
        assertEq(AERO.balanceOf(address(this)), balanceBefore + reward);
        _assertHook(0, 0);
    }

    function testZeroRewardsNeitherCreatesLockNorCallsHook() public {
        voter.setClaimHook(address(hook));
        uint256 supplyBefore = escrow.tokenId();
        assertEq(gauge.getRewardAndLock(address(this), 0, MAXTIME), 0);
        gauge.getReward(address(this));
        assertEq(escrow.tokenId(), supplyBefore);
        assertEq(hook.calls(), 0);
    }

    function testCannotClaimAndLockOtherUsersRewards() public {
        uint256 reward = _accrue();
        vm.prank(address(owner2));
        vm.expectRevert(IGauge.NotAuthorized.selector);
        gauge.getRewardAndLock(address(this), 0, MAXTIME);
        assertEq(gauge.earned(address(this)), reward);
    }

    function testCannotLockIntoOtherUsersNftEvenWithApproval() public {
        vm.startPrank(address(owner2));
        AERO.approve(address(escrow), TOKEN_1);
        uint256 id = escrow.createLock(TOKEN_1, MAXTIME);
        escrow.approve(address(this), id);
        vm.stopPrank();
        uint256 reward = _accrue();
        vm.expectRevert(IGauge.NotAuthorized.selector);
        gauge.getRewardAndLock(address(this), id, 0);
        assertEq(gauge.earned(address(this)), reward);
        assertEq(convert(escrow.locked(id).amount), TOKEN_1);
    }

    function testCannotUseZeroDurationForNewLock() public {
        uint256 reward = _accrue();
        vm.expectRevert(IVotingEscrow.LockDurationNotInFuture.selector);
        gauge.getRewardAndLock(address(this), 0, 0);
        assertEq(gauge.earned(address(this)), reward);
    }

    function testCannotUseDurationForExistingLock() public {
        uint256 id = _createLock(MAXTIME);
        _accrue();
        vm.expectRevert(IGauge.InvalidParams.selector);
        gauge.getRewardAndLock(address(this), id, WEEK);
    }

    function testEscrowRejectsExcessiveDurationAtomically() public {
        uint256 reward = _accrue();
        vm.expectRevert(IVotingEscrow.LockDurationTooLong.selector);
        gauge.getRewardAndLock(address(this), 0, MAXTIME + WEEK);
        assertEq(gauge.earned(address(this)), reward);
        assertEq(AERO.allowance(address(gauge), address(escrow)), 0);
    }

    function testCannotClaimIntoExpiredLock() public {
        uint256 id = _createLock(WEEK);
        uint256 reward = _accrue();
        vm.warp(escrow.locked(id).end + 1);
        reward = gauge.earned(address(this));
        vm.expectRevert(IVotingEscrow.LockExpired.selector);
        gauge.getRewardAndLock(address(this), id, 0);
        assertEq(gauge.earned(address(this)), reward);
        assertEq(convert(escrow.locked(id).amount), TOKEN_1);
    }

    function testHookRevertRestoresNewLockAndRewards() public {
        uint256 reward = _accrue();
        uint256 balanceBefore = AERO.balanceOf(address(this));
        uint256 gaugeBefore = AERO.balanceOf(address(gauge));
        uint256 escrowBefore = AERO.balanceOf(address(escrow));
        uint256 idBefore = escrow.tokenId();
        voter.setClaimHook(address(hook));
        hook.configure(true, false);
        vm.expectRevert(RecordingClaimHook.HookFailed.selector);
        gauge.getRewardAndLock(address(this), 0, MAXTIME);
        assertEq(gauge.earned(address(this)), reward);
        assertEq(escrow.tokenId(), idBefore);
        assertEq(AERO.balanceOf(address(this)), balanceBefore);
        assertEq(AERO.balanceOf(address(gauge)), gaugeBefore);
        assertEq(AERO.balanceOf(address(escrow)), escrowBefore);
        assertEq(AERO.allowance(address(gauge), address(escrow)), 0);
    }

    function testHookRevertRestoresLiquidClaim() public {
        uint256 reward = _accrue();
        uint256 balanceBefore = AERO.balanceOf(address(this));
        voter.setClaimHook(address(hook));
        hook.configure(true, false);
        vm.expectRevert(RecordingClaimHook.HookFailed.selector);
        gauge.getReward(address(this));
        assertEq(gauge.earned(address(this)), reward);
        assertEq(AERO.balanceOf(address(this)), balanceBefore);
    }

    function testHookCannotReenterClaim() public {
        _accrue();
        voter.setClaimHook(address(hook));
        hook.configure(false, true);
        gauge.getRewardAndLock(address(this), 0, MAXTIME);
        assertTrue(hook.reentryBlocked());
        assertEq(hook.calls(), 1);
    }

    function testTeamCanReplaceAndDisableHookForAllGauges() public {
        _accrue();
        pool2.approve(address(gauge2), POOL_1);
        gauge2.deposit(POOL_1);
        _addRewardToGauge(address(voter), address(gauge2), TOKEN_1);
        skip(1 days);
        voter.setClaimHook(address(hook));
        assertEq(voter.claimHook(), address(hook));
        gauge.getReward(address(this));
        gauge2.getReward(address(this));
        assertEq(hook.calls(), 2);
        assertEq(hook.callsByGauge(address(gauge)), 1);
        assertEq(hook.callsByGauge(address(gauge2)), 1);
        assertEq(hook.poolsByGauge(address(gauge)), address(pool));
        assertEq(hook.poolsByGauge(address(gauge2)), address(pool2));

        RecordingClaimHook replacement = new RecordingClaimHook();
        voter.setClaimHook(address(replacement));
        assertEq(voter.claimHook(), address(replacement));
        skip(1 days);
        gauge.getReward(address(this));
        gauge2.getReward(address(this));
        assertEq(replacement.calls(), 2);
        assertEq(hook.calls(), 2);
        voter.setClaimHook(address(0));
        assertEq(voter.claimHook(), address(0));
        skip(1 days);
        gauge.getReward(address(this));
        gauge2.getReward(address(this));
        assertEq(replacement.calls(), 2);
    }

    function testOnlyCurrentTeamCanSetHook() public {
        vm.prank(address(owner2));
        vm.expectRevert(IVotingEscrow.NotTeam.selector);
        voter.setClaimHook(address(hook));
        escrow.setTeam(address(owner2));
        vm.prank(address(owner2));
        escrow.acceptTeam();
        vm.expectRevert(IVotingEscrow.NotTeam.selector);
        voter.setClaimHook(address(hook));
        vm.prank(address(owner2));
        voter.setClaimHook(address(hook));
        assertEq(voter.claimHook(), address(hook));
    }

    function testHookMustHaveCode() public {
        vm.expectRevert(IVoter.InvalidHook.selector);
        voter.setClaimHook(address(0x1234));
    }

    function testNewGaugeUsesLatestGlobalHook() public {
        voter.setClaimHook(address(hook));
        _addLiquidityToPool(address(this), address(router), address(LR), address(USDC), false, TOKEN_1, USDC_1);
        Pool newPool = Pool(factory.getPool(address(LR), address(USDC), false));
        Gauge newGauge = Gauge(voter.createGauge(address(factory), address(newPool)));
        RecordingClaimHook replacement = new RecordingClaimHook();
        voter.setClaimHook(address(replacement));
        newPool.approve(address(newGauge), POOL_1);
        newGauge.deposit(POOL_1);
        _addRewardToGauge(address(voter), address(newGauge), TOKEN_1);
        skip(1 days);
        newGauge.getReward(address(this));
        assertEq(hook.calls(), 0);
        assertEq(replacement.calls(), 1);
        assertEq(replacement.caller(), address(newGauge));
        assertEq(replacement.gaugeArg(), address(newGauge));
        assertEq(replacement.pool(), address(newPool));
    }

    function testVoterBatchCreatesOneLockForTwoGauges() public {
        uint256 reward = _accrue();
        pool2.approve(address(gauge2), POOL_1);
        gauge2.deposit(POOL_1);
        _addRewardToGauge(address(voter), address(gauge2), TOKEN_1);
        skip(1 days);
        reward = gauge.earned(address(this)) + gauge2.earned(address(this));
        uint256 idBefore = escrow.tokenId();
        uint256 balanceBefore = AERO.balanceOf(address(this));
        address[] memory gauges = new address[](2);
        gauges[0] = address(gauge);
        gauges[1] = address(gauge2);
        uint256 id = voter.claimRewardsAndLock(gauges, 0, MAXTIME);
        assertEq(id, idBefore + 1);
        assertEq(escrow.tokenId(), id);
        assertEq(convert(escrow.locked(id).amount), reward);
        assertEq(AERO.balanceOf(address(this)), balanceBefore);
        assertEq(gauge.earned(address(this)), 0);
        assertEq(gauge2.earned(address(this)), 0);
    }

    function testVoterBatchSkipsEmptyFirstGauge() public {
        uint256 reward = _accrue();
        address[] memory gauges = new address[](2);
        gauges[0] = address(gauge2);
        gauges[1] = address(gauge);
        uint256 id = voter.claimRewardsAndLock(gauges, 0, MAXTIME);
        assertEq(escrow.ownerOf(id), address(this));
        assertEq(convert(escrow.locked(id).amount), reward);
    }

    function testVoterBatchSecondHookFailureRestoresBothClaims() public {
        _accrue();
        pool2.approve(address(gauge2), POOL_1);
        gauge2.deposit(POOL_1);
        _addRewardToGauge(address(voter), address(gauge2), TOKEN_1);
        skip(1 days);
        uint256 firstReward = gauge.earned(address(this));
        uint256 secondReward = gauge2.earned(address(this));
        uint256 escrowBefore = AERO.balanceOf(address(escrow));
        uint256 idBefore = escrow.tokenId();
        voter.setClaimHook(address(hook));
        hook.setFailGauge(address(gauge2));
        address[] memory gauges = new address[](2);
        gauges[0] = address(gauge);
        gauges[1] = address(gauge2);
        vm.expectRevert(RecordingClaimHook.HookFailed.selector);
        voter.claimRewardsAndLock(gauges, 0, MAXTIME);
        assertEq(gauge.earned(address(this)), firstReward);
        assertEq(gauge2.earned(address(this)), secondReward);
        assertEq(escrow.tokenId(), idBefore);
        assertEq(AERO.balanceOf(address(escrow)), escrowBefore);
        assertEq(hook.calls(), 0);
    }

    function testClaimIntoTeamLock() public {
        AERO.approve(address(escrow), TOKEN_1);
        uint256 teamUnlockTs = block.timestamp + WEEK;
        uint256 id = escrow.createTeamLockFor(TOKEN_1, MAXTIME, address(this), teamUnlockTs);
        uint256 reward = _accrue();
        gauge.getRewardAndLock(address(this), id, 0);
        assertEq(gauge.earned(address(this)), 0);
        assertEq(convert(escrow.locked(id).amount), TOKEN_1 + reward);
        assertEq(escrow.teamLocks(id).endTs, teamUnlockTs);
    }

    function testTrustedForwarderClaimPreservesUserAndLockOwnership() public {
        uint256 reward = _accrue();
        voter.setClaimHook(address(hook));
        bytes memory payload = abi.encodePacked(
            abi.encodeCall(gauge.getRewardAndLock, (address(this), 0, MAXTIME)),
            address(this)
        );
        vm.prank(address(forwarder));
        (bool success, bytes memory result) = address(gauge).call(payload);
        assertTrue(success);
        uint256 id = abi.decode(result, (uint256));
        assertEq(escrow.ownerOf(id), address(this));
        assertEq(convert(escrow.locked(id).amount), reward);
        _assertHook(id, reward);
    }

    function testFuzzClaimConservesIRS(uint96 funding, uint32 elapsed) public {
        uint256 amount = bound(uint256(funding), TOKEN_1, TOKEN_1M);
        uint256 delay = bound(uint256(elapsed), 1, 6 days);
        pool.approve(address(gauge), POOL_1);
        gauge.deposit(POOL_1);
        _addRewardToGauge(address(voter), address(gauge), amount);
        skip(delay);
        uint256 reward = gauge.earned(address(this));
        uint256 gaugeBefore = AERO.balanceOf(address(gauge));
        uint256 escrowBefore = AERO.balanceOf(address(escrow));
        uint256 userBefore = AERO.balanceOf(address(this));
        uint256 id = gauge.getRewardAndLock(address(this), 0, MAXTIME);
        assertEq(AERO.balanceOf(address(gauge)), gaugeBefore - reward);
        assertEq(AERO.balanceOf(address(escrow)), escrowBefore + reward);
        assertEq(AERO.balanceOf(address(this)), userBefore);
        assertEq(convert(escrow.locked(id).amount), reward);
        assertEq(gauge.earned(address(this)), 0);
    }
}
