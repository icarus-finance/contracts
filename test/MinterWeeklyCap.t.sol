// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract MinterWeeklyCapTest is BaseTest {
    using stdStorage for StdStorage;

    address internal reporter = address(0xCA9);

    function _setUp() public override {
        minter.setCapReporter(reporter, true);
        irs.approve(address(escrow), TOKEN_1M);
        escrow.createLock(TOKEN_1M, MAXTIME);
    }

    function _nextEpoch() internal view returns (uint256) {
        return _getEpochStart(block.timestamp) + 1 weeks;
    }

    function _report(uint256 epoch, uint256 amount) internal {
        vm.prank(reporter);
        minter.setWeeklyCap(epoch, amount);
    }

    function testOnlyTeamCanManageReporters() public {
        vm.prank(address(owner2));
        vm.expectRevert(IMinter.NotTeam.selector);
        minter.setCapReporter(address(owner2), true);
        assertFalse(minter.capReporters(address(owner2)));
        assertTrue(minter.capReporters(reporter));

        minter.setCapReporter(reporter, false);
        assertFalse(minter.capReporters(reporter));
        vm.prank(reporter);
        vm.expectRevert(IMinter.NotCapReporter.selector);
        minter.setWeeklyCap(_nextEpoch(), 1);
    }

    function testCannotWhitelistZeroAddress() public {
        vm.expectRevert(IMinter.ZeroAddress.selector);
        minter.setCapReporter(address(0), true);
    }

    function testOnlyReporterCanSetOrClearCap() public {
        uint256 epoch = _nextEpoch();
        vm.expectRevert(IMinter.NotCapReporter.selector);
        minter.setWeeklyCap(epoch, 1);
        vm.expectRevert(IMinter.NotCapReporter.selector);
        minter.setWeeklyCap(epoch, 0);
    }

    function testReporterCanOverwriteAndClearBeforeFunding() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, 100);
        _report(epoch, 200);
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 200);
        assertTrue(reported);
        vm.prank(reporter);
        minter.setWeeklyCap(epoch, 0);
        (amount, reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 0);
        assertFalse(reported);

        vm.warp(epoch);
        _assertFunding(minter.weekly(), 0);
    }

    function testPositiveZeroPositiveReportLifecycle() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        _report(epoch, 0);
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 0);
        assertFalse(reported);
        _report(epoch, 2 * TOKEN_1M);
        (amount, reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 2 * TOKEN_1M);
        assertTrue(reported);
        vm.warp(epoch);
        _assertFunding(2 * TOKEN_1M, 0);
    }

    function testZeroReportIsIdempotentAndDoesNotCarryForward() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        _report(epoch, 0);
        _report(epoch, 0);
        vm.warp(epoch);
        _assertFunding(minter.weekly(), 0);
        vm.warp(epoch + 1 weeks);
        _assertFunding(minter.weekly(), 0);
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch + 1 weeks);
        assertEq(amount, 0);
        assertFalse(reported);
    }

    function testOtherAuthorizedReporterCanRemoveReport() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        minter.setCapReporter(reporter, false);
        minter.setCapReporter(address(owner2), true);
        vm.prank(address(owner2));
        minter.setWeeklyCap(epoch, 0);
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 0);
        assertFalse(reported);
        vm.warp(epoch);
        _assertFunding(minter.weekly(), 0);
    }

    function testReportEventsIncludeZeroRemoval() public {
        uint256 epoch = _nextEpoch();
        vm.expectEmit(true, true, false, true, address(minter));
        emit IMinter.SetWeeklyCap(epoch, TOKEN_1M, reporter);
        _report(epoch, TOKEN_1M);
        vm.expectEmit(true, true, false, true, address(minter));
        emit IMinter.SetWeeklyCap(epoch, 0, reporter);
        _report(epoch, 0);
        uint256 scheduled = minter.weekly();
        vm.warp(epoch);
        vm.expectEmit(true, false, false, true, address(minter));
        emit IMinter.WeeklyCapApplied(epoch, scheduled, scheduled, false);
        minter.updatePeriod();
    }

    function testPositiveReportApplicationEvent() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        uint256 scheduled = minter.weekly();
        vm.warp(epoch);
        vm.expectEmit(true, false, false, true, address(minter));
        emit IMinter.WeeklyCapApplied(epoch, scheduled, TOKEN_1M, true);
        minter.updatePeriod();
    }

    function testCurrentEpochCanBeReportedUntilFunding() public {
        uint256 epoch = _nextEpoch();
        vm.warp(epoch + 1 hours);
        _report(epoch, TOKEN_1M);
        _assertFunding(TOKEN_1M, 0);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(epoch, TOKEN_1M);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(epoch, 0);
    }

    function testRejectsPastAndMisalignedEpochs() public {
        uint256 next = _nextEpoch();
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(next + 1, 1);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(next + 1, 0);
        vm.warp(next + 1 weeks);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(next, 1);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(next, 0);
    }

    function testMissingReportUsesSchedule() public {
        uint256 epoch = _nextEpoch();
        vm.warp(epoch);
        _assertFunding(minter.weekly(), 0);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(epoch, 0);
    }

    function testOneWeiCapRemainsReportedAndLimitsFunding() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, 1);
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 1);
        assertTrue(reported);
        vm.warp(epoch);
        _assertFunding(1, 0);
    }

    function testHighCapCannotIncreaseEmissions() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, type(uint256).max);
        vm.warp(epoch);
        _assertFunding(minter.weekly(), 0);
    }

    function testZeroReportUsesScheduleAndAdvancesEpoch() public {
        uint256 epoch = _nextEpoch();
        uint256 scheduled = minter.weekly();
        _report(epoch, 0);
        vm.warp(epoch);
        _assertFunding(scheduled, 0);
        assertEq(minter.activePeriod(), epoch);
        assertEq(minter.epochCount(), 1);
        assertEq(distributor.lastTokenTime(), block.timestamp);
        assertEq(minter.weekly(), scheduled * minter.WEEKLY_GROWTH() / minter.MAX_BPS());
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch);
        assertEq(amount, 0);
        assertFalse(reported);
    }

    function testCapDoesNotCarryIntoNextEpochOrChangeGrowthSchedule() public {
        uint256 epoch = _nextEpoch();
        uint256 scheduled = minter.weekly();
        _report(epoch, TOKEN_1M);
        vm.warp(epoch);
        _assertFunding(TOKEN_1M, 0);
        uint256 nextScheduled = scheduled * minter.WEEKLY_GROWTH() / minter.MAX_BPS();
        assertEq(minter.weekly(), nextScheduled);
        vm.warp(epoch + 1 weeks);
        _assertFunding(nextScheduled, 0);
    }

    function testRepeatedUpdateDoesNotMintOrTransferTwice() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        vm.warp(epoch);
        _assertFunding(TOKEN_1M, 0);
        uint256 supply = irs.totalSupply();
        uint256 voterBalance = irs.balanceOf(address(voter));
        uint256 distributorBalance = irs.balanceOf(address(distributor));
        uint256 teamBalance = irs.balanceOf(minter.team());
        uint256 scheduled = minter.weekly();
        assertEq(minter.updatePeriod(), epoch);
        assertEq(irs.totalSupply(), supply);
        assertEq(irs.balanceOf(address(voter)), voterBalance);
        assertEq(irs.balanceOf(address(distributor)), distributorBalance);
        assertEq(irs.balanceOf(minter.team()), teamBalance);
        assertEq(minter.weekly(), scheduled);
        assertEq(minter.epochCount(), 1);
    }

    function testSkippedEpochCapDoesNotAffectCurrentFunding() public {
        uint256 next = _nextEpoch();
        _report(next, 1);
        vm.warp(next + 2 weeks);
        _assertFunding(minter.weekly(), 0);
        assertEq(minter.epochCount(), 1);
    }

    function testSkippedEpochUsesOnlyCurrentReport() public {
        uint256 next = _nextEpoch();
        _report(next, 1);
        _report(next + 2 weeks, TOKEN_1M);
        vm.warp(next + 2 weeks);
        _assertFunding(TOKEN_1M, 0);
        assertEq(minter.epochCount(), 1);
    }

    function testCapDoesNotChangeDecaySchedule() public {
        stdstore.target(address(minter)).sig("epochCount()").checked_write(14);
        uint256 scheduled = minter.weekly();
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        vm.warp(epoch);
        _assertFunding(TOKEN_1M, 0);
        assertEq(minter.weekly(), scheduled * minter.WEEKLY_DECAY() / minter.MAX_BPS());
    }

    function testCapAppliesToTailAndMissingReportRestoresSupplyBasedTail() public {
        uint256 weekly = minter.TAIL_START() - 1;
        stdstore.target(address(minter)).sig("weekly()").checked_write(weekly);
        uint256 epoch = _nextEpoch();
        uint256 nominal = irs.totalSupply() * minter.tailEmissionRate() / minter.MAX_BPS();
        _report(epoch, nominal / 2);
        vm.warp(epoch);
        _assertFunding(nominal / 2, 0);
        assertEq(minter.weekly(), weekly);
        vm.warp(epoch + 1 weeks);
        nominal = irs.totalSupply() * minter.tailEmissionRate() / minter.MAX_BPS();
        _assertFunding(nominal, 0);
    }

    function testZeroReportRestoresSupplyBasedTail() public {
        uint256 weekly = minter.TAIL_START() - 1;
        stdstore.target(address(minter)).sig("weekly()").checked_write(weekly);
        uint256 epoch = _nextEpoch();
        uint256 nominal = irs.totalSupply() * minter.tailEmissionRate() / minter.MAX_BPS();
        _report(epoch, nominal / 2);
        _report(epoch, 0);
        vm.warp(epoch);
        _assertFunding(nominal, 0);
        assertEq(minter.weekly(), weekly);
    }

    function testRemovingOneEpochDoesNotChangeAnotherReport() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        _report(epoch + 1 weeks, 2 * TOKEN_1M);
        _report(epoch, 0);
        vm.warp(epoch);
        _assertFunding(minter.weekly(), 0);
        vm.warp(epoch + 1 weeks);
        _assertFunding(2 * TOKEN_1M, 0);
    }

    function testRevocationPreventsClearingExistingReport() public {
        uint256 epoch = _nextEpoch();
        _report(epoch, TOKEN_1M);
        minter.setCapReporter(reporter, false);
        vm.prank(reporter);
        vm.expectRevert(IMinter.NotCapReporter.selector);
        minter.setWeeklyCap(epoch, 0);
        vm.warp(epoch);
        _assertFunding(TOKEN_1M, 0);
    }

    function testNewTeamControlsWhitelist() public {
        minter.setTeam(address(owner2));
        vm.prank(address(owner2));
        minter.acceptTeam();
        vm.expectRevert(IMinter.NotTeam.selector);
        minter.setCapReporter(reporter, false);
        vm.prank(address(owner2));
        minter.setCapReporter(reporter, false);
        assertFalse(minter.capReporters(reporter));
    }

    function testFuzzCapFundingAccounting(uint256 cap, uint256 prefund, uint256 rate) public {
        cap = bound(cap, 0, 20 * TOKEN_1M);
        prefund = bound(prefund, 0, TOKEN_1M);
        rate = bound(rate, 0, minter.MAXIMUM_TEAM_RATE());
        minter.setTeamRate(rate);
        uint256 epoch = _nextEpoch();
        uint256 approved = cap != 0 && cap < minter.weekly() ? cap : minter.weekly();
        _report(epoch, cap);
        vm.warp(epoch);
        _assertFunding(approved, prefund);
    }

    // Independent balance conservation check, including the pre-mint supply used for rebases.
    function _assertFunding(uint256 emission, uint256 prefund) internal {
        if (prefund != 0) irs.transfer(address(minter), prefund);
        uint256 supply = irs.totalSupply();
        uint256 veSupply = escrow.totalSupplyAt(_getEpochStart(block.timestamp) - 1);
        uint256 growth = (((emission * (supply - veSupply)) / supply) * (supply - veSupply)) / supply / 2;
        uint256 teamAmount = minter.teamRate() * (emission + growth) / (minter.MAX_BPS() - minter.teamRate());
        uint256 required = emission + growth + teamAmount;
        uint256 held = irs.balanceOf(address(minter));
        uint256 voterBefore = irs.balanceOf(address(voter));
        uint256 distributorBefore = irs.balanceOf(address(distributor));
        uint256 teamBefore = irs.balanceOf(minter.team());
        minter.updatePeriod();
        assertEq(irs.balanceOf(address(voter)) - voterBefore, emission, "gauge funding");
        assertEq(irs.balanceOf(address(distributor)) - distributorBefore, growth, "rebase funding");
        assertEq(irs.balanceOf(minter.team()) - teamBefore, teamAmount, "team funding");
        assertEq(irs.totalSupply() - supply, required > held ? required - held : 0, "mint only shortfall");
        assertEq(irs.balanceOf(address(minter)), held > required ? held - required : 0, "retained prefunding");
        assertEq(irs.allowance(address(minter), address(voter)), 0, "no residual allowance");
    }
}
