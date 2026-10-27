// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract CustomUnstakedFeeTest is BaseTest {
    function _setUp() public override {
        // Set a default swap fee and default unstaked fee
        factory.setFee(true, 5); // 5 bps = 0.05% for stable
        factory.setFee(false, 30); // 30 bps = 0.3% for volatile
        factory.setUnstakedFee(1000); // 10% default unstaked fee
    }

    function testSetCustomUnstakedFeeAndSwap() public {
        // Set custom unstaked fee to 20% (2000 bps) for this pool
        factory.setCustomUnstakedFee(address(pool), 2000);
        assertEq(factory.getUnstakedFee(address(pool)), 2000);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // Total swap fee: USDC_1 * 5 / 10000 = 500
        // Gauge portion (20% of 500): 500 * 2000 / 10000 = 100
        // Pool portion (80% of 500): 500 - 100 = 400
        assertEq(USDC.balanceOf(gaugeFees), 100);
        assertEq(USDC.balanceOf(poolFees), 400);
    }

    function testSetCustomUnstakedFeeHigher() public {
        // Set custom unstaked fee to 50% (5000 bps) - the maximum
        factory.setCustomUnstakedFee(address(pool), 5000);
        assertEq(factory.getUnstakedFee(address(pool)), 5000);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // Total swap fee: USDC_1 * 5 / 10000 = 500
        // Gauge portion (50% of 500): 500 * 5000 / 10000 = 250
        // Pool portion (50% of 500): 500 - 250 = 250
        assertEq(USDC.balanceOf(gaugeFees), 250);
        assertEq(USDC.balanceOf(poolFees), 250);
    }

    function testSetCustomUnstakedFeeToZeroIndicator() public {
        // Set custom unstaked fee to 42000 (zero unstaked fee indicator)
        factory.setCustomUnstakedFee(address(pool), 42000);
        assertEq(factory.getUnstakedFee(address(pool)), 0);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // Total swap fee: USDC_1 * 5 / 10000 = 500
        // Gauge portion (0% of 500): 0
        // Pool portion (100% of 500): 500
        assertEq(USDC.balanceOf(gaugeFees), 0);
        assertEq(USDC.balanceOf(poolFees), 500);
    }

    function testResetCustomUnstakedFeeToDefault() public {
        // First set a custom unstaked fee
        factory.setCustomUnstakedFee(address(pool), 3000);
        assertEq(factory.getUnstakedFee(address(pool)), 3000);

        // Reset to default by setting to 0
        factory.setCustomUnstakedFee(address(pool), 0);
        // Should return to default unstaked fee (1000 bps = 10%)
        assertEq(factory.getUnstakedFee(address(pool)), 1000);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // Total swap fee: USDC_1 * 5 / 10000 = 500
        // Gauge portion (10% of 500): 500 * 1000 / 10000 = 50
        // Pool portion (90% of 500): 500 - 50 = 450
        assertEq(USDC.balanceOf(gaugeFees), 50);
        assertEq(USDC.balanceOf(poolFees), 450);
    }

    function testCustomUnstakedFeeVolatilePool() public {
        // Test with volatile pool (pool2) and custom unstaked fee
        factory.setCustomUnstakedFee(address(pool2), 1500); // 15%
        assertEq(factory.getUnstakedFee(address(pool2)), 1500);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), false, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool2.poolFees();
        address gaugeFees = pool2.gaugeFees();

        // Total swap fee: USDC_1 * 30 / 10000 = 3000 (volatile fee is 30 bps)
        // Gauge portion (15% of 3000): 3000 * 1500 / 10000 = 450
        // Pool portion (85% of 3000): 3000 - 450 = 2550
        assertEq(USDC.balanceOf(gaugeFees), 450);
        assertEq(USDC.balanceOf(poolFees), 2550);
    }

    function testCustomUnstakedFeeDoesNotAffectOtherPools() public {
        // Set custom unstaked fee only on pool, not on pool2
        factory.setCustomUnstakedFee(address(pool), 2500); // 25%

        // pool should have custom unstaked fee
        assertEq(factory.getUnstakedFee(address(pool)), 2500);

        // pool2 should still have default unstaked fee (1000 bps = 10%)
        assertEq(factory.getUnstakedFee(address(pool2)), 1000);
    }

    function testMultipleSwapsWithCustomUnstakedFee() public {
        // Set custom unstaked fee
        factory.setCustomUnstakedFee(address(pool), 2000); // 20%

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        // First swap
        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // After first swap: gauge 100, pool 400
        assertEq(USDC.balanceOf(gaugeFees), 100);
        assertEq(USDC.balanceOf(poolFees), 400);

        // Second swap
        assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        // Total fees after two swaps: gauge 200, pool 800
        assertEq(USDC.balanceOf(gaugeFees), 200);
        assertEq(USDC.balanceOf(poolFees), 800);
    }

    function testChangingCustomUnstakedFeeBetweenSwaps() public {
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        // First swap with 10% unstaked fee
        factory.setCustomUnstakedFee(address(pool), 1000);
        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // Total fee: 500, gauge: 50, pool: 450
        assertEq(USDC.balanceOf(gaugeFees), 50);
        assertEq(USDC.balanceOf(poolFees), 450);

        // Change unstaked fee to 30%
        factory.setCustomUnstakedFee(address(pool), 3000);

        // Second swap with new fee
        assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        // Total fees: gauge (50 + 150 = 200), pool (450 + 350 = 800)
        assertEq(USDC.balanceOf(gaugeFees), 200);
        assertEq(USDC.balanceOf(poolFees), 800);
    }

    function testMaxCustomUnstakedFee() public {
        // Test with maximum allowed unstaked fee (5000 bps = 50%)
        factory.setCustomUnstakedFee(address(pool), 5000);
        assertEq(factory.getUnstakedFee(address(pool)), 5000);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // 50/50 split: gauge 250, pool 250
        assertEq(USDC.balanceOf(gaugeFees), 250);
        assertEq(USDC.balanceOf(poolFees), 250);
    }

    function testCustomUnstakedFeeWithBidirectionalSwaps() public {
        factory.setCustomUnstakedFee(address(pool), 2500); // 25%

        IRouter.Route[] memory routes = new IRouter.Route[](1);

        // Swap USDC -> FRAX
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));
        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // USDC fees: total 500, gauge 125 (25%), pool 375 (75%)
        assertEq(USDC.balanceOf(gaugeFees), 125);
        assertEq(USDC.balanceOf(poolFees), 375);

        // Swap FRAX -> USDC
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        assertedOutput = router.getAmountsOut(TOKEN_1, routes);
        FRAX.approve(address(router), TOKEN_1);
        router.swapExactTokensForTokens(TOKEN_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        // USDC fees should remain the same
        assertEq(USDC.balanceOf(gaugeFees), 125);
        assertEq(USDC.balanceOf(poolFees), 375);

        // FRAX fees: total 5e14, gauge 1.25e14 (25%), pool 3.75e14 (75%)
        assertEq(FRAX.balanceOf(gaugeFees), 1.25e14);
        assertEq(FRAX.balanceOf(poolFees), 3.75e14);
    }

    function testFeeDistributionWithCustomUnstakedFee() public {
        factory.setCustomUnstakedFee(address(pool), 1500); // 15%

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address poolFees = pool.poolFees();
        address gaugeFees = pool.gaugeFees();

        // Fees split: total 500, gauge 75 (15%), pool 425 (85%)
        assertEq(USDC.balanceOf(gaugeFees), 75);
        assertEq(USDC.balanceOf(poolFees), 425);

        // Verify fee ratio is correct
        uint256 totalFees = USDC.balanceOf(gaugeFees) + USDC.balanceOf(poolFees);
        assertEq(totalFees, 500);

        // Gauge portion should be 15%
        assertApproxEqRel(USDC.balanceOf(gaugeFees), (totalFees * 1500) / 10000, 0.01e18);
    }

    function testGaugeFeesNotClaimedByNonGauge() public {
        factory.setCustomUnstakedFee(address(pool), 2000); // 20%

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(FRAX), true, address(0));

        uint256[] memory assertedOutput = router.getAmountsOut(USDC_1, routes);
        USDC.approve(address(router), USDC_1);
        router.swapExactTokensForTokens(USDC_1, assertedOutput[1], routes, address(owner), vm.getBlockTimestamp());

        address gaugeFees = pool.gaugeFees();

        // Fees split: total 500, gauge 100, pool 400
        uint256 gaugeFeeBefore = USDC.balanceOf(gaugeFees);
        assertEq(gaugeFeeBefore, 100);

        // Non-gauge (owner) claims fees
        skip(1801);
        vm.roll(vm.getBlockNumber() + 1);

        pool.claimFees();

        // GaugeFees should remain untouched when non-gauge claims
        uint256 gaugeFeeAfter = USDC.balanceOf(gaugeFees);
        assertEq(gaugeFeeAfter, gaugeFeeBefore);
        assertEq(gaugeFeeAfter, 100);
    }

    function testCannotSetCustomUnstakedFeeAboveMax() public {
        vm.expectRevert(IPoolFactory.FeeTooHigh.selector);
        factory.setCustomUnstakedFee(address(pool), 5001); // Over 50%
    }

    function testCannotSetCustomUnstakedFeeIfNotFeeManager() public {
        vm.prank(address(owner2));
        vm.expectRevert(IPoolFactory.NotFeeManager.selector);
        factory.setCustomUnstakedFee(address(pool), 1500);
    }

    function testCannotSetCustomUnstakedFeeForNonExistentPool() public {
        vm.expectRevert(IPoolFactory.InvalidPool.selector);
        factory.setCustomUnstakedFee(address(1), 1500);
    }
}
