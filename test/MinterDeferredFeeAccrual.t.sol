// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {ManagedRewardsFactory} from "contracts/factories/ManagedRewardsFactory.sol";
import {VotingRewardsFactory} from "contracts/factories/VotingRewardsFactory.sol";
import {GaugeFactory} from "contracts/factories/GaugeFactory.sol";
import {PoolFactory} from "contracts/factories/PoolFactory.sol";
import {FactoryRegistry} from "contracts/factories/FactoryRegistry.sol";
import {Pool} from "contracts/Pool.sol";
import {IMinter, Minter} from "contracts/Minter.sol";
import {FeesVotingReward} from "contracts/rewards/FeesVotingReward.sol";
import {Gauge} from "contracts/gauges/Gauge.sol";
import {RewardsDistributor} from "contracts/RewardsDistributor.sol";
import {IRouter, Router} from "contracts/Router.sol";
import {IRS} from "contracts/IRS.sol";
import {Voter} from "contracts/Voter.sol";
import {VeArtProxy} from "contracts/VeArtProxy.sol";
import {VotingEscrow} from "contracts/VotingEscrow.sol";
import {EpochGovernor} from "contracts/EpochGovernor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Forwarder} from "@opengsn/contracts/src/forwarder/Forwarder.sol";
import {MockERC20} from "utils/MockERC20.sol";
import {MockWETH} from "utils/MockWETH.sol";

/// @title MinterDeferredFeeAccrualTest
/// @notice Verifies pre-minter swap fees (gauge fees) accrue and flow to the sole voter after initialization.
contract MinterDeferredFeeAccrualTest is Test {
    uint256 constant TOKEN_1 = 1e18;
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

    // Pool and gauge
    Pool public pool;
    Gauge public gauge;
    FeesVotingReward public feesVotingReward;

    // Actors
    address public lp;
    address public trader;
    address public irsHolder;

    function setUp() public {
        vm.warp(WEEK);

        lp = makeAddr("lp");
        trader = makeAddr("trader");
        irsHolder = makeAddr("irsHolder");

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
        router = new Router(address(forwarder), address(factoryRegistry), address(factory), address(voter), address(WETH));

        // Deploy Minter - but do not initialize
        minter = new Minter(address(voter), address(escrow), address(distributor));
        distributor.setMinter(address(minter));
        irs.setMinter(address(minter));

        // Initialize voter with minter and whitelist tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(FRAX);
        tokens[2] = address(irs);
        voter.initialize(tokens, address(minter));

        // Setup epoch governor
        epochGovernor = new EpochGovernor(address(forwarder), escrow, address(minter));
        voter.setEpochGovernor(address(epochGovernor));
    }

    function test_FeesBeforeMinterInitFlowToSoleVoter() public {
        pool = _createStablePoolWithLiquidity();

        // Set unstaked fee to 10% so gauge fees accrue even without a gauge.
        factory.setUnstakedFee(1000);

        // Pre-gauge swaps -> gauge fees accrue to pool.gaugeFees()
        _swapFraxForUsdc(100_000 * TOKEN_1);

        address token0 = pool.token0();
        address token1 = pool.token1();
        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        uint256 preGaugeFee0 = IERC20(token0).balanceOf(gaugeFees);
        uint256 preGaugeFee1 = IERC20(token1).balanceOf(gaugeFees);
        uint256 prePoolFee0 = IERC20(token0).balanceOf(poolFees);
        uint256 prePoolFee1 = IERC20(token1).balanceOf(poolFees);

        assertGt(preGaugeFee0 + preGaugeFee1, 0, "expected pre-gauge fees");

        uint256 totalFee0 = preGaugeFee0 + prePoolFee0;
        uint256 totalFee1 = preGaugeFee1 + prePoolFee1;
        if (totalFee0 > 0) {
            assertApproxEqRel(
                preGaugeFee0,
                (totalFee0 * 1000) / 10_000,
                0.02e18,
                "gauge fee0 ~= 10%"
            );
        }
        if (totalFee1 > 0) {
            assertApproxEqRel(
                preGaugeFee1,
                (totalFee1 * 1000) / 10_000,
                0.02e18,
                "gauge fee1 ~= 10%"
            );
        }

        // Create gauge and stake LP
        gauge = Gauge(voter.createGauge(address(factory), address(pool)));
        feesVotingReward = FeesVotingReward(voter.gaugeToFees(address(gauge)));

        uint256 lpBalance = pool.balanceOf(lp);
        vm.startPrank(lp);
        IERC20(address(pool)).approve(address(gauge), lpBalance);
        gauge.deposit(lpBalance);
        vm.stopPrank();

        uint256 poolFeesBefore0 = IERC20(token0).balanceOf(poolFees);
        uint256 poolFeesBefore1 = IERC20(token1).balanceOf(poolFees);
        uint256 gaugeFeesBefore0 = IERC20(token0).balanceOf(gaugeFees);
        uint256 gaugeFeesBefore1 = IERC20(token1).balanceOf(gaugeFees);

        // Post-stake swaps -> 100% of fees for stakers should be claimable by gauge
        _swapFraxForUsdc(50_000 * TOKEN_1);

        uint256 poolFeesAfter0 = IERC20(token0).balanceOf(poolFees);
        uint256 poolFeesAfter1 = IERC20(token1).balanceOf(poolFees);
        uint256 gaugeFeesAfter0 = IERC20(token0).balanceOf(gaugeFees);
        uint256 gaugeFeesAfter1 = IERC20(token1).balanceOf(gaugeFees);

        assertGe(poolFeesAfter0, poolFeesBefore0);
        assertGe(poolFeesAfter1, poolFeesBefore1);
        assertGe(gaugeFeesAfter0, gaugeFeesBefore0);
        assertGe(gaugeFeesAfter1, gaugeFeesBefore1);

        uint256 postPoolDelta0 = poolFeesAfter0 - poolFeesBefore0;
        uint256 postPoolDelta1 = poolFeesAfter1 - poolFeesBefore1;
        uint256 maxReward0 = gaugeFeesAfter0 + postPoolDelta0;
        uint256 maxReward1 = gaugeFeesAfter1 + postPoolDelta1;

        // Initialize minter with a single locked recipient
        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: new address[](0),
            liquidAmounts: new uint256[](0),
            lockedWallets: _singleAddress(irsHolder),
            lockedAmounts: _singleUint(10_000 * TOKEN_1)
        });
        minter.initialize(params, 10_000_000 ether);
        assertEq(escrow.ownerOf(1), irsHolder);

        // Move into voting window and vote for pool
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(irsHolder);
        voter.vote(1, pools, weights);

        // Epoch flip and distribute (claims fees + starts emissions)
        _skipToNextEpoch(1);
        voter.distribute(0, 1);

        // Gauge fees are fully claimed; pool fees revert to (approx) pre-stake levels
        assertEq(IERC20(token0).balanceOf(gaugeFees), 0, "gaugeFees0 claimed");
        assertEq(IERC20(token1).balanceOf(gaugeFees), 0, "gaugeFees1 claimed");
        uint256 poolFeesFinal0 = IERC20(token0).balanceOf(poolFees);
        uint256 poolFeesFinal1 = IERC20(token1).balanceOf(poolFees);
        uint256 tol0 = poolFeesBefore0 / 1e12 + 1;
        uint256 tol1 = poolFeesBefore1 / 1e12 + 1;
        assertApproxEqAbs(poolFeesFinal0, poolFeesBefore0, tol0, "poolFees0 pre-stake retained");
        assertApproxEqAbs(poolFeesFinal1, poolFeesBefore1, tol1, "poolFees1 pre-stake retained");

        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        uint256 epochReward0 = feesVotingReward.tokenRewardsPerEpoch(token0, epochStart);
        uint256 epochReward1 = feesVotingReward.tokenRewardsPerEpoch(token1, epochStart);
        assertGe(epochReward0, gaugeFeesAfter0, "epoch reward0 includes pre-gauge fees");
        assertGe(epochReward1, gaugeFeesAfter1, "epoch reward1 includes pre-gauge fees");
        assertLe(epochReward0, maxReward0, "epoch reward0 capped by post-stake fees");
        assertLe(epochReward1, maxReward1, "epoch reward1 capped by post-stake fees");

        // Move forward one epoch so rewards are claimable
        _skipToNextEpoch(1);

        address[] memory feeRewards = new address[](1);
        feeRewards[0] = address(feesVotingReward);
        address[][] memory rewardTokens = new address[][](1);
        rewardTokens[0] = new address[](2);
        rewardTokens[0][0] = token0;
        rewardTokens[0][1] = token1;

        uint256 irsBal0Before = IERC20(token0).balanceOf(irsHolder);
        uint256 irsBal1Before = IERC20(token1).balanceOf(irsHolder);

        vm.prank(irsHolder);
        voter.claimFees(feeRewards, rewardTokens, 1);

        uint256 irsBal0After = IERC20(token0).balanceOf(irsHolder);
        uint256 irsBal1After = IERC20(token1).balanceOf(irsHolder);

        assertEq(irsBal0After - irsBal0Before, epochReward0, "sole voter receives all fee0");
        assertEq(irsBal1After - irsBal1Before, epochReward1, "sole voter receives all fee1");
    }

    function test_PreInitFeesSharedWhenAnotherVoterLocksBeforeDistribute() public {
        pool = _createStablePoolWithLiquidity();

        // Accrue gauge fees pre-init
        factory.setUnstakedFee(1000);
        _swapFraxForUsdc(100_000 * TOKEN_1);

        // Create gauge and stake LP
        gauge = Gauge(voter.createGauge(address(factory), address(pool)));
        feesVotingReward = FeesVotingReward(voter.gaugeToFees(address(gauge)));
        uint256 lpBalance = pool.balanceOf(lp);
        vm.startPrank(lp);
        IERC20(address(pool)).approve(address(gauge), lpBalance);
        gauge.deposit(lpBalance);
        vm.stopPrank();

        // Initialize minter: IRS holder gets locked, LP gets liquid to lock
        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: _singleAddress(lp),
            liquidAmounts: _singleUint(20_000 * TOKEN_1),
            lockedWallets: _singleAddress(irsHolder),
            lockedAmounts: _singleUint(20_000 * TOKEN_1)
        });
        minter.initialize(params, 10_000_000 ether);
        assertEq(escrow.ownerOf(1), irsHolder);

        // LP locks and makes permanent to ensure meaningful voting power
        vm.startPrank(lp);
        irs.approve(address(escrow), type(uint256).max);
        uint256 lpTokenId = escrow.createLock(20_000 * TOKEN_1, MAXTIME);
        escrow.lockPermanent(lpTokenId);
        vm.stopPrank();

        // Vote in the same epoch before distribute
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        vm.prank(irsHolder);
        voter.vote(1, pools, weights);
        vm.prank(lp);
        voter.vote(lpTokenId, pools, weights);

        // Epoch flip and distribute (claims fees + starts emissions)
        _skipToNextEpoch(1);
        voter.distribute(0, 1);

        address token0 = pool.token0();
        address token1 = pool.token1();
        uint256 epochStart = (block.timestamp / WEEK) * WEEK;
        uint256 epochReward0 = feesVotingReward.tokenRewardsPerEpoch(token0, epochStart);
        uint256 epochReward1 = feesVotingReward.tokenRewardsPerEpoch(token1, epochStart);

        // Move forward one epoch so rewards are claimable
        _skipToNextEpoch(1);

        address[] memory feeRewards = new address[](1);
        feeRewards[0] = address(feesVotingReward);
        address[][] memory rewardTokens = new address[][](1);
        rewardTokens[0] = new address[](2);
        rewardTokens[0][0] = token0;
        rewardTokens[0][1] = token1;

        uint256 irs0Before = IERC20(token0).balanceOf(irsHolder);
        uint256 irs1Before = IERC20(token1).balanceOf(irsHolder);
        vm.prank(irsHolder);
        voter.claimFees(feeRewards, rewardTokens, 1);
        uint256 irs0After = IERC20(token0).balanceOf(irsHolder);
        uint256 irs1After = IERC20(token1).balanceOf(irsHolder);

        uint256 lp0Before = IERC20(token0).balanceOf(lp);
        uint256 lp1Before = IERC20(token1).balanceOf(lp);
        vm.prank(lp);
        voter.claimFees(feeRewards, rewardTokens, lpTokenId);
        uint256 lp0After = IERC20(token0).balanceOf(lp);
        uint256 lp1After = IERC20(token1).balanceOf(lp);

        uint256 irsClaim0 = irs0After - irs0Before;
        uint256 irsClaim1 = irs1After - irs1Before;
        uint256 lpClaim0 = lp0After - lp0Before;
        uint256 lpClaim1 = lp1After - lp1Before;

        if (epochReward0 > 0) {
            assertGt(lpClaim0, 0, "lp shares fee0");
            assertLt(irsClaim0, epochReward0, "irs not all fee0");
            assertLe(irsClaim0 + lpClaim0, epochReward0, "fee0 rounding bound");
        }
        if (epochReward1 > 0) {
            assertGt(lpClaim1, 0, "lp shares fee1");
            assertLt(irsClaim1, epochReward1, "irs not all fee1");
            assertLe(irsClaim1 + lpClaim1, epochReward1, "fee1 rounding bound");
        }
    }

    function test_EmissionsBootstrapVotingSharesPreInitFees() public {
        pool = _createStablePoolWithLiquidity();

        // Accrue gauge fees pre-init
        factory.setUnstakedFee(1000);
        _swapFraxForUsdc(100_000 * TOKEN_1);

        // Create gauge and stake LP
        gauge = Gauge(voter.createGauge(address(factory), address(pool)));
        feesVotingReward = FeesVotingReward(voter.gaugeToFees(address(gauge)));
        uint256 lpBalance = pool.balanceOf(lp);
        vm.startPrank(lp);
        IERC20(address(pool)).approve(address(gauge), lpBalance);
        gauge.deposit(lpBalance);
        vm.stopPrank();

        // Initialize minter: only IRS holder gets locked airdrop
        IMinter.AirdropParams memory params = IMinter.AirdropParams({
            liquidWallets: new address[](0),
            liquidAmounts: new uint256[](0),
            lockedWallets: _singleAddress(irsHolder),
            lockedAmounts: _singleUint(20_000 * TOKEN_1)
        });
        minter.initialize(params, 10_000_000 ether);
        assertEq(escrow.ownerOf(1), irsHolder);

        // IRS holder votes in epoch -1
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(irsHolder);
        voter.vote(1, pools, weights);

        // Epoch flip 0 and distribute: fees get allocated to epoch 0
        _skipToNextEpoch(1);
        voter.distribute(0, 1);

        address token0 = pool.token0();
        address token1 = pool.token1();
        uint256 epoch0Start = (block.timestamp / WEEK) * WEEK;
        uint256 epochReward0 = feesVotingReward.tokenRewardsPerEpoch(token0, epoch0Start);
        uint256 epochReward1 = feesVotingReward.tokenRewardsPerEpoch(token1, epoch0Start);

        // LP earns emissions during epoch 0, locks, and votes in the same epoch
        vm.warp(epoch0Start + 1 days);
        vm.roll(block.number + 1);

        uint256 irsBefore = irs.balanceOf(lp);
        vm.prank(lp);
        gauge.getReward(lp);
        uint256 irsAfter = irs.balanceOf(lp);
        assertGt(irsAfter - irsBefore, 0, "lp earned emissions");

        vm.startPrank(lp);
        irs.approve(address(escrow), type(uint256).max);
        uint256 lpTokenId = escrow.createLock(irsAfter - irsBefore, MAXTIME);
        escrow.lockPermanent(lpTokenId);
        vm.stopPrank();

        vm.prank(lp);
        voter.vote(lpTokenId, pools, weights);

        // Epoch flip 1: claims for epoch 0 now possible
        _skipToNextEpoch(1);

        address[] memory feeRewards = new address[](1);
        feeRewards[0] = address(feesVotingReward);
        address[][] memory rewardTokens = new address[][](1);
        rewardTokens[0] = new address[](2);
        rewardTokens[0][0] = token0;
        rewardTokens[0][1] = token1;

        uint256 irs0Before = IERC20(token0).balanceOf(irsHolder);
        uint256 irs1Before = IERC20(token1).balanceOf(irsHolder);
        vm.prank(irsHolder);
        voter.claimFees(feeRewards, rewardTokens, 1);
        uint256 irs0After = IERC20(token0).balanceOf(irsHolder);
        uint256 irs1After = IERC20(token1).balanceOf(irsHolder);

        uint256 lp0Before = IERC20(token0).balanceOf(lp);
        uint256 lp1Before = IERC20(token1).balanceOf(lp);
        vm.prank(lp);
        voter.claimFees(feeRewards, rewardTokens, lpTokenId);
        uint256 lp0After = IERC20(token0).balanceOf(lp);
        uint256 lp1After = IERC20(token1).balanceOf(lp);

        uint256 irsClaim0 = irs0After - irs0Before;
        uint256 irsClaim1 = irs1After - irs1Before;
        uint256 lpClaim0 = lp0After - lp0Before;
        uint256 lpClaim1 = lp1After - lp1Before;

        if (epochReward0 > 0) {
            assertGt(lpClaim0, 0, "lp shares fee0");
            assertLt(irsClaim0, epochReward0, "irs not all fee0");
            assertLe(irsClaim0 + lpClaim0, epochReward0, "fee0 rounding bound");
        }
        if (epochReward1 > 0) {
            assertGt(lpClaim1, 0, "lp shares fee1");
            assertLt(irsClaim1, epochReward1, "irs not all fee1");
            assertLe(irsClaim1 + lpClaim1, epochReward1, "fee1 rounding bound");
        }
    }

    function _createStablePoolWithLiquidity() internal returns (Pool createdPool) {
        deal(address(USDC), lp, 1_000_000 * USDC_1);
        deal(address(FRAX), lp, 1_000_000 * TOKEN_1);

        vm.startPrank(lp);
        USDC.approve(address(router), type(uint256).max);
        FRAX.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(FRAX),
            address(USDC),
            true,
            1_000_000 * TOKEN_1,
            1_000_000 * USDC_1,
            0,
            0,
            lp,
            block.timestamp
        );
        vm.stopPrank();

        createdPool = Pool(factory.getPool(address(FRAX), address(USDC), true));
        assertTrue(address(createdPool) != address(0), "pool not created");
    }

    function _swapFraxForUsdc(uint256 amountIn) internal {
        deal(address(FRAX), trader, amountIn);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));

        uint256[] memory expectedOutput = router.getAmountsOut(amountIn, routes);

        vm.startPrank(trader);
        FRAX.approve(address(router), amountIn);
        router.swapExactTokensForTokens(amountIn, expectedOutput[1], routes, trader, block.timestamp);
        vm.stopPrank();
    }

    function _skipToNextEpoch(uint256 offset) internal {
        uint256 ts = block.timestamp;
        uint256 nextEpoch = ts - (ts % WEEK) + WEEK;
        vm.warp(nextEpoch + offset);
        vm.roll(block.number + 1);
    }

    function _singleAddress(address value) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = value;
    }

    function _singleUint(uint256 value) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = value;
    }
}
