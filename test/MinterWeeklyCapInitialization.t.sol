// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {IRS} from "contracts/IRS.sol";
import {Minter, IMinter} from "contracts/Minter.sol";
import {Voter} from "contracts/Voter.sol";
import {VotingEscrow, IVotingEscrow} from "contracts/VotingEscrow.sol";
import {RewardsDistributor} from "contracts/RewardsDistributor.sol";
import {Pool} from "contracts/Pool.sol";
import {PoolFactory} from "contracts/factories/PoolFactory.sol";
import {FactoryRegistry} from "contracts/factories/FactoryRegistry.sol";
import {GaugeFactory} from "contracts/factories/GaugeFactory.sol";
import {VotingRewardsFactory} from "contracts/factories/VotingRewardsFactory.sol";
import {ManagedRewardsFactory} from "contracts/factories/ManagedRewardsFactory.sol";
import {Forwarder} from "@opengsn/contracts/src/forwarder/Forwarder.sol";

/// @dev Real mint authority and distribution wiring; no initialized BaseTest or storage overrides.
contract MinterWeeklyCapInitializationFlowTest is Test {
    uint256 internal constant WEEK = 1 weeks;
    uint256 internal constant INITIAL_SUPPLY = 100_000_000 ether;
    uint256 internal constant LOCKED = 40_000_000 ether;
    uint256 internal constant CAP = 1_000_000 ether;
    address internal reporter;
    address internal user;
    IRS internal token;
    VotingEscrow internal escrow;
    Voter internal voter;
    RewardsDistributor internal distributor;
    Minter internal minter;

    function setUp() public {
        vm.warp(WEEK);
        reporter = makeAddr("cap reporter");
        user = makeAddr("airdrop recipient");
        token = new IRS();
        PoolFactory factory = new PoolFactory(address(new Pool()));
        FactoryRegistry registry = new FactoryRegistry(
            address(factory),
            address(new VotingRewardsFactory()),
            address(new GaugeFactory()),
            address(new ManagedRewardsFactory())
        );
        Forwarder forwarder = new Forwarder();
        escrow = new VotingEscrow(address(forwarder), address(token), address(registry));
        voter = new Voter(address(forwarder), address(escrow), address(registry));
        distributor = new RewardsDistributor(address(escrow));
        escrow.setVoterAndDistributor(address(voter), address(distributor));
        factory.setVoter(address(voter));
        minter = new Minter(address(voter), address(escrow), address(distributor));
        token.setMinter(address(minter));
        distributor.setMinter(address(minter));
        voter.initialize(new address[](0), address(minter));
        minter.setCapReporter(reporter, true);
    }

    function _params() internal view returns (IMinter.AirdropParams memory params) {
        params.liquidWallets = new address[](1);
        params.liquidWallets[0] = user;
        params.liquidAmounts = new uint256[](1);
        params.liquidAmounts[0] = INITIAL_SUPPLY - LOCKED;
        params.lockedWallets = new address[](1);
        params.lockedWallets[0] = user;
        params.lockedAmounts = new uint256[](1);
        params.lockedAmounts[0] = LOCKED;
    }

    function _report(uint256 epoch, uint256 amount) internal {
        vm.prank(reporter);
        minter.setWeeklyCap(epoch, amount);
    }

    function _assertReport(uint256 epoch, uint256 expected) internal view {
        (uint256 amount, bool reported) = minter.weeklyCaps(epoch);
        assertEq(amount, expected);
        assertEq(reported, expected != 0);
    }

    function _initialize() internal {
        minter.initialize(_params(), 10_000_000 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "airdrop unaffected by cap");
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - LOCKED);
        assertEq(token.balanceOf(address(escrow)), LOCKED);
        assertEq(escrow.ownerOf(1), user);
        assertTrue(escrow.locked(1).isPermanent);
        assertEq(token.balanceOf(address(voter)), 0);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(minter.epochCount(), 0);
    }

    function _assertFirstFunding(uint256 epoch, uint256 emission) internal {
        _assertFirstFunding(epoch, emission, 10_300_000 ether);
    }

    function _assertFirstFunding(uint256 epoch, uint256 emission, uint256 expectedWeekly) internal {
        vm.warp(epoch);
        uint256 supplyBefore = token.totalSupply();
        uint256 votingPower = escrow.totalSupplyAt(epoch - 1);
        assertEq(votingPower, LOCKED, "permanent airdrop voting power");
        // Independently derive funding from pre-mint supply and actual approved emissions.
        uint256 growth = (((emission * (supplyBefore - votingPower)) / supplyBefore) * (supplyBefore - votingPower)) /
            supplyBefore /
            2;
        uint256 teamReward = (500 * (emission + growth)) / 9500;
        assertEq(minter.updatePeriod(), epoch);
        assertEq(token.balanceOf(address(voter)), emission);
        assertEq(token.balanceOf(address(distributor)), growth);
        assertEq(token.balanceOf(address(this)), teamReward);
        assertEq(token.totalSupply() - supplyBefore, emission + growth + teamReward);
        assertEq(token.balanceOf(address(minter)), 0);
        assertEq(token.allowance(address(minter), address(voter)), 0);
        assertEq(distributor.tokenLastBalance(), growth);
        assertEq(distributor.lastTokenTime(), epoch);
        assertEq(minter.activePeriod(), epoch);
        assertEq(minter.epochCount(), 1);
        assertEq(minter.weekly(), expectedWeekly, "nominal schedule after first emission");
        minter.updatePeriod();
        assertEq(token.totalSupply(), supplyBefore + emission + growth + teamReward, "no double funding");
    }

    function testWeeklyUnsetBeforeInitialization() public view {
        assertEq(minter.weekly(), 0);
        assertFalse(minter.initialized());
    }

    function testCustomInitialWeeklyFundsFirstEpochAndGrows() public {
        uint256 initialWeekly = 20_000_000 ether;
        minter.initialize(_params(), initialWeekly);
        assertEq(minter.weekly(), initialWeekly);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(minter.activePeriod(), WEEK);
        assertEq(minter.epochCount(), 0);
        assertEq(minter.updatePeriod(), WEEK);
        assertEq(token.balanceOf(address(voter)), 0);
        _assertFirstFunding(2 * WEEK, initialWeekly, (initialWeekly * minter.WEEKLY_GROWTH()) / minter.MAX_BPS());
    }

    function testInitialWeeklyAtThresholdUsesNominalEmissionAndGrowth() public {
        uint256 initialWeekly = minter.TAIL_START();
        minter.initialize(_params(), initialWeekly);
        _assertFirstFunding(2 * WEEK, initialWeekly, (initialWeekly * minter.WEEKLY_GROWTH()) / minter.MAX_BPS());
    }

    function testInitialWeeklyBelowThresholdUsesSupplyBasedTailImmediately() public {
        uint256 initialWeekly = minter.TAIL_START() - 1;
        minter.initialize(_params(), initialWeekly);
        uint256 emission = (INITIAL_SUPPLY * minter.tailEmissionRate()) / minter.MAX_BPS();
        assertTrue(emission != initialWeekly);
        _assertFirstFunding(2 * WEEK, emission, initialWeekly);
    }

    function testZeroInitialWeeklyAcceptedAndUsesSupplyBasedTail() public {
        minter.initialize(_params(), 0);
        assertTrue(minter.initialized());
        assertEq(minter.weekly(), 0);
        uint256 emission = (INITIAL_SUPPLY * minter.tailEmissionRate()) / minter.MAX_BPS();
        assertGt(emission, 0, "zero weekly does not disable tail emissions");
        _assertFirstFunding(2 * WEEK, emission, 0);
    }

    function testMaximumInitialWeeklyAcceptedAndFundsFirstEpoch() public {
        uint256 initialWeekly = 100_000_000 ether;
        minter.initialize(_params(), initialWeekly);
        assertEq(minter.weekly(), initialWeekly);
        assertTrue(minter.initialized());
        _assertFirstFunding(2 * WEEK, initialWeekly, initialWeekly * minter.WEEKLY_GROWTH() / minter.MAX_BPS());
    }

    function testInitialWeeklyOneBaseUnitAboveMaximumReverts() public {
        _assertInvalidInitialWeekly(100_000_000 ether + 1);
    }

    function testUint256MaximumInitialWeeklyReverts() public {
        _assertInvalidInitialWeekly(type(uint256).max);
    }

    function testFuzzInitialWeeklyAboveMaximumReverts(uint256 initialWeekly) public {
        initialWeekly = bound(initialWeekly, 100_000_000 ether + 1, type(uint256).max);
        _assertInvalidInitialWeekly(initialWeekly);
    }

    function _assertInvalidInitialWeekly(uint256 initialWeekly) internal {
        IMinter.AirdropParams memory params = _params();
        vm.expectRevert(IMinter.InvalidParams.selector);
        minter.initialize(params, initialWeekly);
        assertFalse(minter.initialized());
        assertEq(minter.weekly(), 0);
        assertEq(minter.activePeriod(), type(uint256).max - WEEK);
        assertEq(token.totalSupply(), 0);
        assertEq(escrow.tokenId(), 0);
        _initialize();
    }

    function testFirstFundedEpochCanBeCappedBeforeInitialization() public {
        _report(2 * WEEK, CAP);
        _initialize();
        _assertReport(2 * WEEK, CAP);
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testFirstCappedRebaseCanBeClaimedIntoPermanentAirdropLock() public {
        _report(2 * WEEK, CAP);
        _initialize();
        _assertFirstFunding(2 * WEEK, CAP);
        uint256 growth = token.balanceOf(address(distributor));
        assertGt(growth, 0);
        assertEq(distributor.claimable(1), growth, "sole permanent lock earns entire rebase");
        assertEq(distributor.claim(1), growth);
        assertEq(uint256(uint128(escrow.locked(1).amount)), LOCKED + growth);
        assertTrue(escrow.locked(1).isPermanent);
        assertEq(token.balanceOf(address(escrow)), LOCKED + growth);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(distributor.tokenLastBalance(), 0);
        assertEq(distributor.claim(1), 0, "rebase cannot be claimed twice");
    }

    function testFirstFundedEpochCanBeCappedAfterInitialization() public {
        _initialize();
        _report(2 * WEEK, CAP);
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testFirstCapCanBeReportedAtBoundaryBeforeProcessing() public {
        _initialize();
        vm.warp(2 * WEEK);
        _report(2 * WEEK, CAP);
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testMissingFirstReportUsesNormalSchedule() public {
        _initialize();
        _assertFirstFunding(2 * WEEK, 10_000_000 ether);
    }

    function testZeroFirstReportUsesNormalSchedule() public {
        _report(2 * WEEK, 0);
        _assertReport(2 * WEEK, 0);
        _initialize();
        _assertFirstFunding(2 * WEEK, 10_000_000 ether);
    }

    function testFirstReportCanBeRemovedAfterInitialization() public {
        _report(2 * WEEK, CAP);
        _initialize();
        _report(2 * WEEK, 0);
        _assertReport(2 * WEEK, 0);
        _assertFirstFunding(2 * WEEK, 10_000_000 ether);
    }

    function testFirstReportCanBeReinstatedBeforeInitialization() public {
        _report(2 * WEEK, CAP);
        _report(2 * WEEK, 0);
        _report(2 * WEEK, 2 * CAP);
        _initialize();
        _assertFirstFunding(2 * WEEK, 2 * CAP);
    }

    function testInitializationWeekReportNeverFundsOrCarriesForward() public {
        _report(WEEK, CAP);
        _initialize();
        assertEq(minter.updatePeriod(), WEEK);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(minter.epochCount(), 0);
        _assertReport(WEEK, CAP);
        vm.prank(reporter);
        vm.expectRevert(IMinter.InvalidCapEpoch.selector);
        minter.setWeeklyCap(WEEK, 0);
        _assertFirstFunding(2 * WEEK, 10_000_000 ether);
    }

    function testDelayedInitializationIgnoresOldIntendedFirstEpoch() public {
        _report(2 * WEEK, CAP);
        vm.warp(5 * WEEK + 1 days);
        _initialize();
        assertEq(minter.activePeriod(), 5 * WEEK);
        assertEq(minter.updatePeriod(), 5 * WEEK);
        _assertFirstFunding(6 * WEEK, 10_000_000 ether);
    }

    function testDelayedInitializationPreservesFutureFirstEpochReport() public {
        _report(2 * WEEK, CAP);
        _report(6 * WEEK, 2 * CAP);
        vm.warp(5 * WEEK + 1 days);
        _initialize();
        _assertFirstFunding(6 * WEEK, 2 * CAP);
    }

    function testPreInitializationUpdatesCannotConsumeReports() public {
        _report(2 * WEEK, CAP);
        uint256 sentinel = minter.activePeriod();
        assertEq(minter.updatePeriod(), sentinel);
        vm.warp(2 * WEEK);
        assertEq(minter.updatePeriod(), sentinel);
        assertEq(token.totalSupply(), 0);
        assertEq(minter.epochCount(), 0);
        _assertReport(2 * WEEK, CAP);
        _report(3 * WEEK, CAP);
        _initialize();
        _assertFirstFunding(3 * WEEK, CAP);
    }

    function testUnauthorizedInitializationPreservesCapAndUninitializedState() public {
        _report(2 * WEEK, CAP);
        IMinter.AirdropParams memory params = _params();
        vm.prank(reporter);
        vm.expectRevert(IMinter.NotTeam.selector);
        minter.initialize(params, 123 ether);
        assertFalse(minter.initialized());
        assertEq(minter.weekly(), 0, "failed initialization cannot set weekly");
        assertEq(token.totalSupply(), 0);
        _assertReport(2 * WEEK, CAP);
        _initialize();
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testInvalidInitializationPreservesCapAndAllowsRetry() public {
        _report(2 * WEEK, CAP);
        IMinter.AirdropParams memory params = _params();
        params.liquidAmounts = new uint256[](0);
        vm.expectRevert(IMinter.InvalidParams.selector);
        minter.initialize(params, 123 ether);
        assertFalse(minter.initialized());
        assertEq(minter.weekly(), 0, "failed initialization cannot set weekly");
        assertEq(token.totalSupply(), 0);
        _assertReport(2 * WEEK, CAP);
        _initialize();
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testRevertingAirdropRollsBackMintAndPreservesCap() public {
        _report(2 * WEEK, CAP);
        IMinter.AirdropParams memory params = _params();
        params.lockedAmounts[0] = 0;
        vm.expectRevert(IVotingEscrow.ZeroAmount.selector);
        minter.initialize(params, 123 ether);
        assertFalse(minter.initialized());
        assertEq(minter.weekly(), 0, "failed initialization cannot set weekly");
        assertEq(token.totalSupply(), 0, "liquid airdrop mint rolled back");
        assertEq(token.balanceOf(user), 0);
        assertEq(escrow.tokenId(), 0);
        assertEq(minter.activePeriod(), type(uint256).max - WEEK);
        _assertReport(2 * WEEK, CAP);
        _initialize();
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testSecondInitializationCannotResetOrConsumeFirstCap() public {
        _report(2 * WEEK, CAP);
        _initialize();
        IMinter.AirdropParams memory params = _params();
        vm.warp(WEEK + 1 days);
        vm.expectRevert(IMinter.AlreadyInitialized.selector);
        minter.initialize(params, 123 ether);
        assertEq(minter.weekly(), 10_000_000 ether, "repeat initialization cannot reset weekly");
        assertEq(minter.activePeriod(), WEEK);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        _assertReport(2 * WEEK, CAP);
        _assertFirstFunding(2 * WEEK, CAP);
    }

    function testPreInitializationReportingStillRequiresWhitelist() public {
        vm.expectRevert(IMinter.NotCapReporter.selector);
        minter.setWeeklyCap(2 * WEEK, CAP);
        minter.setCapReporter(reporter, false);
        vm.prank(reporter);
        vm.expectRevert(IMinter.NotCapReporter.selector);
        minter.setWeeklyCap(2 * WEEK, 0);
        _assertReport(2 * WEEK, 0);
    }

    function testEmptyAirdropFirstEpochWithPositiveCap() public {
        _report(2 * WEEK, CAP);
        _assertEmptyAirdropFunding(CAP);
    }

    function testEmptyAirdropFirstEpochWithMissingReport() public {
        _assertEmptyAirdropFunding(10_000_000 ether);
    }

    function testEmptyAirdropFirstEpochWithRemovedReport() public {
        _report(2 * WEEK, CAP);
        _report(2 * WEEK, 0);
        _assertReport(2 * WEEK, 0);
        _assertEmptyAirdropFunding(10_000_000 ether);
    }

    function _assertEmptyAirdropFunding(uint256 emission) internal {
        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: new address[](0),
            liquidAmounts: new uint256[](0),
            lockedWallets: new address[](0),
            lockedAmounts: new uint256[](0)
        });
        minter.initialize(params, 10_000_000 ether);
        assertEq(token.totalSupply(), 0);
        assertEq(minter.calculateGrowth(emission), 0);
        assertEq(minter.updatePeriod(), WEEK);
        vm.warp(2 * WEEK);
        minter.updatePeriod();
        uint256 teamReward = (500 * emission) / 9500;
        assertEq(token.balanceOf(address(voter)), emission);
        assertEq(token.balanceOf(address(this)), teamReward);
        assertEq(token.totalSupply(), emission + teamReward);
        assertEq(token.balanceOf(address(distributor)), 0, "no preexisting supply to rebase");
        assertEq(distributor.tokenLastBalance(), 0);
        assertEq(distributor.lastTokenTime(), 2 * WEEK, "zero rebase still checkpointed");
        assertEq(token.balanceOf(address(minter)), 0);
        assertEq(token.allowance(address(minter), address(voter)), 0);
        assertEq(minter.epochCount(), 1);
        assertEq(minter.activePeriod(), 2 * WEEK);
        assertEq(minter.weekly(), 10_300_000 ether);
        minter.updatePeriod();
        assertEq(token.totalSupply(), emission + teamReward, "no duplicate mint");
    }

    function testFuzzInitializeOffsetFirstFundingUsesNextBoundary(uint256 offset, uint256 cap) public {
        offset = bound(offset, 0, WEEK - 1);
        cap = bound(cap, 1, 20_000_000 ether);
        _report(2 * WEEK, cap);
        vm.warp(WEEK + offset);
        _initialize();
        assertEq(minter.activePeriod(), WEEK);
        vm.warp(2 * WEEK - 1);
        assertEq(minter.updatePeriod(), WEEK);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        _assertFirstFunding(2 * WEEK, cap < 10_000_000 ether ? cap : 10_000_000 ether);
    }
}
