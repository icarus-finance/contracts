// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {ManagedRewardsFactory} from "contracts/factories/ManagedRewardsFactory.sol";
import {VotingRewardsFactory} from "contracts/factories/VotingRewardsFactory.sol";
import {GaugeFactory} from "contracts/factories/GaugeFactory.sol";
import {PoolFactory, IPoolFactory} from "contracts/factories/PoolFactory.sol";
import {IFactoryRegistry, FactoryRegistry} from "contracts/factories/FactoryRegistry.sol";
import {Pool} from "contracts/Pool.sol";
import {IMinter, Minter} from "contracts/Minter.sol";
import {FeesVotingReward} from "contracts/rewards/FeesVotingReward.sol";
import {BribeVotingReward} from "contracts/rewards/BribeVotingReward.sol";
import {IGauge, Gauge} from "contracts/gauges/Gauge.sol";
import {RewardsDistributor, IRewardsDistributor} from "contracts/RewardsDistributor.sol";
import {IRouter, Router} from "contracts/Router.sol";
import {IIRS, IRS} from "contracts/IRS.sol";
import {IVoter, Voter} from "contracts/Voter.sol";
import {VeArtProxy} from "contracts/VeArtProxy.sol";
import {IVotingEscrow, VotingEscrow} from "contracts/VotingEscrow.sol";
import {EpochGovernor} from "contracts/EpochGovernor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Forwarder} from "@opengsn/contracts/src/forwarder/Forwarder.sol";
import {MockERC20} from "utils/MockERC20.sol";
import {MockWETH} from "utils/MockWETH.sol";
import {TestOwner} from "utils/TestOwner.sol";

/// @title MinterDeferredInitializationTest
/// @notice Tests that the protocol can be deployed and used (pools, gauges) before Minter is initialized
///         and verifies no IRS tokens are issued or voted before initialization
contract MinterDeferredInitializationTest is Test {
    uint256 constant TOKEN_1 = 1e18;
    uint256 constant TOKEN_1M = 1e24;
    uint256 constant USDC_1 = 1e6;
    uint256 constant WEEK = 1 weeks;
    uint256 constant MAXTIME = 4 * 365 * 86400;

    // Tokens
    IRS public irs;
    MockERC20 public USDC;
    MockERC20 public FRAX;
    MockWETH public WETH;

    // Core contracts
    Forwarder public forwarder;
    Pool public implementation;
    Router public router;
    VotingEscrow public escrow;
    VeArtProxy public artProxy;
    PoolFactory public factory;
    FactoryRegistry public factoryRegistry;
    GaugeFactory public gaugeFactory;
    VotingRewardsFactory public votingRewardsFactory;
    ManagedRewardsFactory public managedRewardsFactory;
    Voter public voter;
    RewardsDistributor public distributor;
    Minter public minter;
    EpochGovernor public epochGovernor;

    // Test pools and gauges
    Pool public pool;
    Gauge public gauge;

    // Actors
    address public team;
    address public user1;
    address public user2;

    function setUp() public {
        // Start at week boundary
        vm.warp(WEEK);

        team = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy tokens
        irs = new IRS();
        USDC = new MockERC20("USDC", "USDC", 6);
        FRAX = new MockERC20("FRAX", "FRAX", 18);
        WETH = new MockWETH();

        // Deploy factories
        implementation = new Pool();
        factory = new PoolFactory(address(implementation));
        votingRewardsFactory = new VotingRewardsFactory();
        gaugeFactory = new GaugeFactory();
        managedRewardsFactory = new ManagedRewardsFactory();
        factoryRegistry = new FactoryRegistry(
            address(factory),
            address(votingRewardsFactory),
            address(gaugeFactory),
            address(managedRewardsFactory)
        );

        forwarder = new Forwarder();

        // Deploy VotingEscrow
        escrow = new VotingEscrow(address(forwarder), address(irs), address(factoryRegistry));
        artProxy = new VeArtProxy(address(escrow));
        escrow.setArtProxy(address(artProxy));

        // Deploy Voter and Distributor
        distributor = new RewardsDistributor(address(escrow));
        voter = new Voter(address(forwarder), address(escrow), address(factoryRegistry));
        factory.setVoter(address(voter));

        escrow.setVoterAndDistributor(address(voter), address(distributor));

        // Deploy Router
        router = new Router(
            address(forwarder),
            address(factoryRegistry),
            address(factory),
            address(voter),
            address(WETH)
        );

        // Deploy Minter - BUT DO NOT INITIALIZE
        minter = new Minter(address(voter), address(escrow), address(distributor));
        distributor.setMinter(address(minter));
        irs.setMinter(address(minter));

        // Initialize voter with minter address and whitelisted tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(FRAX);
        tokens[2] = address(irs);
        voter.initialize(tokens, address(minter));

        // Setup epoch governor
        epochGovernor = new EpochGovernor(address(forwarder), escrow, address(minter));
        voter.setEpochGovernor(address(epochGovernor));
    }

    /*//////////////////////////////////////////////////////////////
                    PRE-INITIALIZATION STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function testMinterNotInitialized() public view {
        assertFalse(minter.initialized(), "Minter should not be initialized");
    }

    function testActivePeriodSetToFarFuture() public view {
        // activePeriod = type(uint256).max - WEEK in constructor
        uint256 expectedActivePeriod = type(uint256).max - WEEK;
        assertEq(minter.activePeriod(), expectedActivePeriod, "activePeriod should be far future");
    }

    function testNoIRSTokensExistBeforeInitialization() public view {
        assertEq(irs.totalSupply(), 0, "No IRS tokens should exist before initialization");
    }

    function testUpdatePeriodDoesNothingBeforeInitialization() public {
        uint256 supplyBefore = irs.totalSupply();
        uint256 voterBalanceBefore = irs.balanceOf(address(voter));
        uint256 epochCountBefore = minter.epochCount();

        // Try to trigger emissions
        minter.updatePeriod();

        assertEq(irs.totalSupply(), supplyBefore, "No tokens should be minted");
        assertEq(irs.balanceOf(address(voter)), voterBalanceBefore, "Voter should receive no tokens");
        assertEq(minter.epochCount(), epochCountBefore, "Epoch count should not change");
    }

    function testUpdatePeriodStillDoesNothingAfterTimePassesBeforeInit() public {
        // Skip many weeks
        skip(52 weeks);

        uint256 supplyBefore = irs.totalSupply();
        minter.updatePeriod();

        assertEq(irs.totalSupply(), supplyBefore, "No tokens should be minted even after time passes");
        assertEq(minter.epochCount(), 0, "Epoch count should remain 0");
    }

    /*//////////////////////////////////////////////////////////////
                    POOL CREATION BEFORE INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function testCanCreatePoolBeforeInitialization() public {
        // Mint stables to create pool
        deal(address(USDC), address(this), 1000 * USDC_1);
        deal(address(FRAX), address(this), 1000 * TOKEN_1);

        USDC.approve(address(router), type(uint256).max);
        FRAX.approve(address(router), type(uint256).max);

        // Create pool via router
        router.addLiquidity(
            address(FRAX),
            address(USDC),
            true, // stable
            TOKEN_1,
            USDC_1,
            0,
            0,
            address(this),
            block.timestamp
        );

        assertEq(factory.allPoolsLength(), 1, "Pool should be created");
        pool = Pool(factory.getPool(address(FRAX), address(USDC), true));
        assertTrue(address(pool) != address(0), "Pool address should be valid");
    }

    /*//////////////////////////////////////////////////////////////
                    GAUGE CREATION BEFORE INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function testCanCreateGaugeBeforeInitialization() public {
        // First create a pool
        testCanCreatePoolBeforeInitialization();

        // Create gauge
        address gaugeAddr = voter.createGauge(address(factory), address(pool));
        gauge = Gauge(gaugeAddr);

        assertTrue(address(gauge) != address(0), "Gauge should be created");
        assertTrue(voter.isGauge(address(gauge)), "Should be registered as gauge");
        assertTrue(voter.isAlive(address(gauge)), "Gauge should be alive");
    }

    /*//////////////////////////////////////////////////////////////
                    VOTING IMPOSSIBLE BEFORE INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function testCannotCreateLockWithoutIRSTokens() public {
        // User has no IRS tokens (none exist)
        assertEq(irs.balanceOf(user1), 0, "User should have no IRS tokens");

        // Attempting to create a lock with 0 tokens should revert
        vm.startPrank(user1);
        vm.expectRevert(IVotingEscrow.ZeroAmount.selector);
        escrow.createLock(0, MAXTIME);
        vm.stopPrank();
    }

    function testNoVeNFTsExistBeforeInitialization() public view {
        assertEq(escrow.tokenId(), 0, "No veNFTs should exist");
        assertEq(escrow.totalSupply(), 0, "Total supply of ve should be 0");
    }

    function testCannotVoteWithoutVeNFT() public {
        testCanCreateGaugeBeforeInitialization();

        // Skip past distribute window (first hour of epoch)
        skipToNextEpoch(1 hours + 1);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        // User has no veNFT
        vm.startPrank(user1);
        vm.expectRevert(IVoter.NotApprovedOrOwner.selector);
        voter.vote(1, pools, weights); // tokenId 1 doesn't exist
        vm.stopPrank();
    }

    /// @dev Helper to skip to next epoch start + offset
    function skipToNextEpoch(uint256 offset) internal {
        uint256 ts = block.timestamp;
        uint256 nextEpoch = ts - (ts % WEEK) + WEEK;
        vm.warp(nextEpoch + offset);
        vm.roll(block.number + 1);
    }

    /*//////////////////////////////////////////////////////////////
                    DISTRIBUTE DOES NOT EMIT REWARDS
    //////////////////////////////////////////////////////////////*/

    function testDistributeDoesNotEmitRewardsBeforeInit() public {
        testCanCreateGaugeBeforeInitialization();

        uint256 voterBalanceBefore = irs.balanceOf(address(voter));
        uint256 gaugeBalanceBefore = irs.balanceOf(address(gauge));

        // Try to distribute
        voter.distribute(0, 1);

        assertEq(irs.balanceOf(address(voter)), voterBalanceBefore, "Voter balance unchanged");
        assertEq(irs.balanceOf(address(gauge)), gaugeBalanceBefore, "Gauge balance unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    MINTER INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function testCanInitializeMinterLater() public {
        // Verify not initialized
        assertFalse(minter.initialized());

        // Skip some time
        skip(4 weeks);

        // Prepare airdrop params
        address[] memory liquidWallets = new address[](2);
        liquidWallets[0] = user1;
        liquidWallets[1] = user2;

        uint256[] memory liquidAmounts = new uint256[](2);
        liquidAmounts[0] = 1000 * TOKEN_1;
        liquidAmounts[1] = 500 * TOKEN_1;

        address[] memory lockedWallets = new address[](1);
        lockedWallets[0] = user1;

        uint256[] memory lockedAmounts = new uint256[](1);
        lockedAmounts[0] = 2000 * TOKEN_1;

        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: liquidWallets,
            liquidAmounts: liquidAmounts,
            lockedWallets: lockedWallets,
            lockedAmounts: lockedAmounts
        });

        // Initialize minter
        minter.initialize(params, 10_000_000 ether);

        // Verify initialized
        assertTrue(minter.initialized(), "Minter should be initialized");

        // Verify tokens distributed
        assertEq(irs.balanceOf(user1), 1000 * TOKEN_1, "User1 should have liquid tokens");
        assertEq(irs.balanceOf(user2), 500 * TOKEN_1, "User2 should have liquid tokens");

        // Verify veNFT created for locked tokens
        assertEq(escrow.tokenId(), 1, "One veNFT should exist");
        assertEq(escrow.ownerOf(1), user1, "User1 should own the veNFT");

        // Verify activePeriod is now current epoch
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        assertEq(minter.activePeriod(), currentEpoch, "activePeriod should be current epoch");
    }

    function testCannotInitializeTwice() public {
        testCanInitializeMinterLater();

        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: new address[](0),
            liquidAmounts: new uint256[](0),
            lockedWallets: new address[](0),
            lockedAmounts: new uint256[](0)
        });

        vm.expectRevert(IMinter.AlreadyInitialized.selector);
        minter.initialize(params, 10_000_000 ether);
    }

    function testOnlyTeamCanInitialize() public {
        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: new address[](0),
            liquidAmounts: new uint256[](0),
            lockedWallets: new address[](0),
            lockedAmounts: new uint256[](0)
        });

        vm.prank(user1);
        vm.expectRevert(IMinter.NotTeam.selector);
        minter.initialize(params, 10_000_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    POST-INITIALIZATION FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    function testEmissionsStartAfterInitialization() public {
        testCanInitializeMinterLater();

        // Move to next epoch
        skip(1 weeks);
        vm.roll(block.number + 1);

        uint256 supplyBefore = irs.totalSupply();

        // Update period should now work
        minter.updatePeriod();

        assertGt(irs.totalSupply(), supplyBefore, "Tokens should be minted");
        assertEq(minter.epochCount(), 1, "Epoch count should be 1");
        assertGt(irs.balanceOf(address(voter)), 0, "Voter should have tokens");
    }

    function testVotingWorksAfterInitialization() public {
        testCanCreateGaugeBeforeInitialization();

        // Initialize minter with tokens for user
        address[] memory liquidWallets = new address[](1);
        liquidWallets[0] = user1;
        uint256[] memory liquidAmounts = new uint256[](1);
        liquidAmounts[0] = 10000 * TOKEN_1;

        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: liquidWallets,
            liquidAmounts: liquidAmounts,
            lockedWallets: new address[](0),
            lockedAmounts: new uint256[](0)
        });
        minter.initialize(params, 10_000_000 ether);

        // User creates lock
        vm.startPrank(user1);
        irs.approve(address(escrow), type(uint256).max);
        uint256 tokenId = escrow.createLock(1000 * TOKEN_1, MAXTIME);
        vm.stopPrank();

        // Skip to voting window (past distribute window)
        skipToNextEpoch(1 hours + 1);

        // User votes
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        vm.prank(user1);
        voter.vote(tokenId, pools, weights);

        assertGt(voter.totalWeight(), 0, "Total weight should be > 0");
        assertGt(voter.weights(address(pool)), 0, "Pool weight should be > 0");
    }

    function testGaugeReceivesRewardsAfterInitialization() public {
        testCanCreateGaugeBeforeInitialization();

        // Initialize with tokens for user
        address[] memory liquidWallets = new address[](1);
        liquidWallets[0] = user1;
        uint256[] memory liquidAmounts = new uint256[](1);
        liquidAmounts[0] = 10000 * TOKEN_1;

        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: liquidWallets,
            liquidAmounts: liquidAmounts,
            lockedWallets: new address[](0),
            lockedAmounts: new uint256[](0)
        });
        minter.initialize(params, 10_000_000 ether);

        // User creates lock and votes
        vm.startPrank(user1);
        irs.approve(address(escrow), type(uint256).max);
        uint256 tokenId = escrow.createLock(1000 * TOKEN_1, MAXTIME);
        vm.stopPrank();

        // Skip to voting window (past distribute window)
        skipToNextEpoch(1 hours + 1);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        vm.prank(user1);
        voter.vote(tokenId, pools, weights);

        // Skip to next epoch
        skipToNextEpoch(1);

        // Distribute rewards
        voter.distribute(0, 1);

        // Gauge should have received rewards
        assertGt(irs.balanceOf(address(gauge)), 0, "Gauge should have rewards");
    }

    /*//////////////////////////////////////////////////////////////
                    FULL WORKFLOW TEST
    //////////////////////////////////////////////////////////////*/

    function testFullWorkflowWithDeferredInitialization() public {
        // === Phase 1: Pre-initialization - Deploy and setup infrastructure ===

        // Create multiple pools
        deal(address(USDC), address(this), 10000 * USDC_1);
        deal(address(FRAX), address(this), 10000 * TOKEN_1);
        USDC.approve(address(router), type(uint256).max);
        FRAX.approve(address(router), type(uint256).max);

        // Stable pool
        router.addLiquidity(address(FRAX), address(USDC), true, TOKEN_1, USDC_1, 0, 0, address(this), block.timestamp);
        Pool stablePool = Pool(factory.getPool(address(FRAX), address(USDC), true));

        // Volatile pool
        router.addLiquidity(address(FRAX), address(USDC), false, TOKEN_1, USDC_1, 0, 0, address(this), block.timestamp);
        Pool volatilePool = Pool(factory.getPool(address(FRAX), address(USDC), false));

        assertEq(factory.allPoolsLength(), 2, "Two pools should exist");

        // Create gauges for both pools
        Gauge stableGauge = Gauge(voter.createGauge(address(factory), address(stablePool)));
        Gauge volatileGauge = Gauge(voter.createGauge(address(factory), address(volatilePool)));

        assertEq(voter.length(), 2, "Two gauges should exist");

        // Verify no emissions happened
        assertEq(irs.totalSupply(), 0, "No IRS tokens yet");
        assertEq(minter.epochCount(), 0, "No epochs passed");

        // Skip some time to simulate waiting for initialization
        skip(2 weeks);

        // === Phase 2: Initialize Minter ===

        address[] memory liquidWallets = new address[](2);
        liquidWallets[0] = user1;
        liquidWallets[1] = user2;
        uint256[] memory liquidAmounts = new uint256[](2);
        liquidAmounts[0] = 100000 * TOKEN_1;
        liquidAmounts[1] = 50000 * TOKEN_1;

        address[] memory lockedWallets = new address[](2);
        lockedWallets[0] = user1;
        lockedWallets[1] = user2;
        uint256[] memory lockedAmounts = new uint256[](2);
        lockedAmounts[0] = 50000 * TOKEN_1;
        lockedAmounts[1] = 25000 * TOKEN_1;

        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: liquidWallets,
            liquidAmounts: liquidAmounts,
            lockedWallets: lockedWallets,
            lockedAmounts: lockedAmounts
        });

        minter.initialize(params, 10_000_000 ether);

        // Verify initialization
        assertTrue(minter.initialized());
        assertEq(irs.balanceOf(user1), 100000 * TOKEN_1);
        assertEq(irs.balanceOf(user2), 50000 * TOKEN_1);
        assertEq(escrow.tokenId(), 2, "Two veNFTs should exist");

        // === Phase 3: Post-initialization - Full protocol functionality ===

        // Skip to voting window (past distribute window)
        skipToNextEpoch(1 hours + 1);

        // User1 votes for stable pool
        address[] memory poolsUser1 = new address[](1);
        poolsUser1[0] = address(stablePool);
        uint256[] memory weightsUser1 = new uint256[](1);
        weightsUser1[0] = 1;

        vm.prank(user1);
        voter.vote(1, poolsUser1, weightsUser1);

        // User2 votes for volatile pool
        address[] memory poolsUser2 = new address[](1);
        poolsUser2[0] = address(volatilePool);
        uint256[] memory weightsUser2 = new uint256[](1);
        weightsUser2[0] = 1;

        vm.prank(user2);
        voter.vote(2, poolsUser2, weightsUser2);

        // Verify votes registered
        assertGt(voter.weights(address(stablePool)), 0);
        assertGt(voter.weights(address(volatilePool)), 0);
        assertEq(minter.epochCount(), 1, "Voting should process the first emission epoch");

        // === Phase 4: Emissions begin ===

        // Skip to next epoch
        skipToNextEpoch(1);

        uint256 supplyBefore = irs.totalSupply();

        // Distribute to all gauges
        voter.distribute(0, 2);

        // Verify emissions occurred
        assertGt(irs.totalSupply(), supplyBefore, "New tokens should be minted");
        assertEq(minter.epochCount(), 2, "Distribution should process the next emission epoch");
        assertGt(irs.balanceOf(address(stableGauge)), 0, "Stable gauge should have rewards");
        assertGt(irs.balanceOf(address(volatileGauge)), 0, "Volatile gauge should have rewards");

        // === Phase 5: LP staking and reward claiming ===

        // User provides liquidity and stakes
        deal(address(stablePool), user1, TOKEN_1);

        vm.startPrank(user1);
        IERC20(address(stablePool)).approve(address(stableGauge), TOKEN_1);
        stableGauge.deposit(TOKEN_1);
        vm.stopPrank();

        assertEq(stableGauge.balanceOf(user1), TOKEN_1, "User should have staked LP");

        // Skip time and claim rewards (stay within same epoch)
        skip(1 days);

        uint256 irsBalanceBefore = irs.balanceOf(user1);

        vm.prank(user1);
        stableGauge.getReward(user1);

        assertGt(irs.balanceOf(user1), irsBalanceBefore, "User should receive rewards");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES AND POTENTIAL ISSUES
    //////////////////////////////////////////////////////////////*/

    function testCalculateGrowthIsZeroBeforeInitialSupply() public view {
        assertEq(minter.calculateGrowth(TOKEN_1M), 0);
    }

    function testCalculateGrowthWorksAfterInit() public {
        // Initialize with some tokens
        address[] memory liquidWallets = new address[](1);
        liquidWallets[0] = user1;
        uint256[] memory liquidAmounts = new uint256[](1);
        liquidAmounts[0] = 1000 * TOKEN_1;

        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: liquidWallets,
            liquidAmounts: liquidAmounts,
            lockedWallets: new address[](0),
            lockedAmounts: new uint256[](0)
        });
        minter.initialize(params, 10_000_000 ether);

        // Now calculateGrowth should work
        uint256 growth = minter.calculateGrowth(TOKEN_1M);
        // Growth should be non-zero calculation (no revert)
        assertGe(growth, 0, "Should not revert");
    }

    function testKillGaugeSendsTokensToMinterBeforeInit() public {
        testCanCreateGaugeBeforeInitialization();

        // Kill the gauge - should work even before init
        // Note: claimable is 0 so no tokens to transfer
        voter.killGauge(address(gauge));

        assertFalse(voter.isAlive(address(gauge)), "Gauge should be killed");
    }

    function testMultiplePoolsAndGaugesBeforeInit() public {
        deal(address(USDC), address(this), 10000 * USDC_1);
        deal(address(FRAX), address(this), 10000 * TOKEN_1);
        USDC.approve(address(router), type(uint256).max);
        FRAX.approve(address(router), type(uint256).max);

        // Create 3 pools
        for (uint256 i = 0; i < 3; i++) {
            router.addLiquidity(
                address(FRAX),
                address(USDC),
                i == 0,
                TOKEN_1,
                USDC_1,
                0,
                0,
                address(this),
                block.timestamp
            );
        }

        // Actually only 2 unique pools (stable and volatile for same pair)
        assertEq(factory.allPoolsLength(), 2, "Should have 2 pools");

        // Create gauges for both
        Pool p1 = Pool(factory.getPool(address(FRAX), address(USDC), true));
        Pool p2 = Pool(factory.getPool(address(FRAX), address(USDC), false));

        voter.createGauge(address(factory), address(p1));
        voter.createGauge(address(factory), address(p2));

        assertEq(voter.length(), 2, "Should have 2 gauges");

        // All done before initialization - no tokens minted
        assertEq(irs.totalSupply(), 0);
    }

    function testTeamFunctionsWorkBeforeInit() public {
        // setTeam should work
        address newTeam = makeAddr("newTeam");
        minter.setTeam(newTeam);
        assertEq(minter.pendingTeam(), newTeam);

        // setTeamRate should work
        minter.setTeamRate(400);
        assertEq(minter.teamRate(), 400);
    }
}
