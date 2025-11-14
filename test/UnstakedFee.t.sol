// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract UnstakedFeeTest is BaseTest {
    function _setUp() public override {
        vm.label(address(pool), "Pool");
        vm.label(address(pool2), "Pool 2");
        vm.label(address(pool3), "Pool 3");
    }

    // Test 1: Setting unstaked fee logic
    function test_SetUnstakedFee() public {
        // Verify default unstaked fee is 0
        assertEq(factory.unstakedFee(), 0);
        
        // Set unstaked fee to 10% (1000 basis points)
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        
        assertEq(factory.unstakedFee(), 1000);
        assertEq(factory.getUnstakedFee(), 1000);
    }

    function test_SetUnstakedFee_RevertIfNotFeeManager() public {
        vm.prank(address(owner2));
        vm.expectRevert(IPoolFactory.NotFeeManager.selector);
        factory.setUnstakedFee(1000);
    }

    function test_SetUnstakedFee_RevertIfFeeTooHigh() public {
        vm.prank(address(owner));
        vm.expectRevert(IPoolFactory.FeeTooHigh.selector);
        factory.setUnstakedFee(5001); // Max is 5000 (50%)
    }

    function test_SetUnstakedFee_MaxFeeAllowed() public {
        vm.prank(address(owner));
        factory.setUnstakedFee(5000); // 50%
        assertEq(factory.unstakedFee(), 5000);
    }

    function test_SetUnstakedFee_ZeroAllowed() public {
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        assertEq(factory.unstakedFee(), 1000);
        
        vm.prank(address(owner));
        factory.setUnstakedFee(0);
        assertEq(factory.unstakedFee(), 0);
    }

    // Test 2: Fees accrue to gaugeFees after unstaked fee is set
    function test_FeesAccrueToGaugeFees_WithUnstakedFee() public {
        // Set unstaked fee to 10%
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        
        // Perform a swap to generate fees
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1);
        router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        vm.stopPrank();
        
        // Check that gaugeFees has received fees
        address gaugeFees = pool.gaugeFees();
        uint256 gaugeFee0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFee1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        // At least one of the tokens should have fees in gaugeFees
        assertGt(gaugeFee0 + gaugeFee1, 0, "GaugeFees should have received fees");
    }

    function test_FeesAccrueToPoolFees_WithUnstakedFee() public {
        // Set unstaked fee to 10%
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        
        // Perform a swap to generate fees
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1);
        router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        vm.stopPrank();
        
        // Check that poolFees has received fees (should be 90% of total fees)
        address poolFees = pool.poolFees();
        uint256 poolFee0 = IERC20(pool.token0()).balanceOf(poolFees);
        uint256 poolFee1 = IERC20(pool.token1()).balanceOf(poolFees);
        
        // At least one of the tokens should have fees in poolFees
        assertGt(poolFee0 + poolFee1, 0, "PoolFees should have received fees");
    }

    function test_FeeRatio_10PercentToGauge_90PercentToPool() public {
        // Set unstaked fee to 10%
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        
        // Perform a swap to generate fees
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1);
        router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        vm.stopPrank();
        
        // Check fee distribution
        address gaugeFees = pool.gaugeFees();
        address poolFees = pool.poolFees();
        
        uint256 gaugeFee0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 poolFee0 = IERC20(pool.token0()).balanceOf(poolFees);
        uint256 gaugeFee1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        uint256 poolFee1 = IERC20(pool.token1()).balanceOf(poolFees);
        
        uint256 totalFees0 = gaugeFee0 + poolFee0;
        uint256 totalFees1 = gaugeFee1 + poolFee1;
        
        // Check ratio (approximately 10% to gauge, 90% to pool)
        if (totalFees0 > 0) {
            // Allow for rounding errors
            assertApproxEqRel(gaugeFee0, totalFees0 * 1000 / 10000, 0.01e18, "GaugeFee should be ~10% of total");
            assertApproxEqRel(poolFee0, totalFees0 * 9000 / 10000, 0.01e18, "PoolFee should be ~90% of total");
        }
        
        if (totalFees1 > 0) {
            assertApproxEqRel(gaugeFee1, totalFees1 * 1000 / 10000, 0.01e18, "GaugeFee should be ~10% of total");
            assertApproxEqRel(poolFee1, totalFees1 * 9000 / 10000, 0.01e18, "PoolFee should be ~90% of total");
        }
    }

    // Test 3: Gauge can claim fees from both poolFees and gaugeFees
    function test_GaugeClaimsBothPoolFeesAndGaugeFees() public {
        // Set unstaked fee to 10%
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        
        // Perform swaps to generate fees
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1 * 10);
        for (uint256 i = 0; i < 10; i++) {
            uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
            router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        }
        vm.stopPrank();
        
        // Capture fees before claim
        address gaugeFees = pool.gaugeFees();
        
        uint256 gaugeFeeBefore0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFeeBefore1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        assertGt(gaugeFeeBefore0 + gaugeFeeBefore1, 0, "GaugeFees should have fees");
        
        // Claim fees as gauge
        address gaugeAddress = voter.gauges(address(pool));
        uint256 balanceBefore0 = IERC20(pool.token0()).balanceOf(gaugeAddress);
        uint256 balanceBefore1 = IERC20(pool.token1()).balanceOf(gaugeAddress);
        
        vm.prank(gaugeAddress);
        (uint256 claimed0, uint256 claimed1) = pool.claimFees();
        
        uint256 balanceAfter0 = IERC20(pool.token0()).balanceOf(gaugeAddress);
        uint256 balanceAfter1 = IERC20(pool.token1()).balanceOf(gaugeAddress);
        
        // Gauge should have received fees from both poolFees and gaugeFees
        assertEq(claimed0, balanceAfter0 - balanceBefore0, "Claimed amount should match balance increase");
        assertEq(claimed1, balanceAfter1 - balanceBefore1, "Claimed amount should match balance increase");
        
        // Both gaugeFees and some poolFees should have been claimed
        assertGt(claimed0 + claimed1, 0, "Gauge should have claimed fees");
        
        // GaugeFees should be empty after claim
        assertEq(IERC20(pool.token0()).balanceOf(gaugeFees), 0, "GaugeFees should be empty");
        assertEq(IERC20(pool.token1()).balanceOf(gaugeFees), 0, "GaugeFees should be empty");
    }

    function test_NonGaugeCannotClaimGaugeFees() public {
        // Set unstaked fee to 10%
        vm.prank(address(owner));
        factory.setUnstakedFee(1000);
        
        // Perform swaps to generate fees
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1 * 5);
        for (uint256 i = 0; i < 5; i++) {
            uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
            router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        }
        vm.stopPrank();
        
        // Capture gaugeFees before claim
        address gaugeFees = pool.gaugeFees();
        uint256 gaugeFeeBefore0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFeeBefore1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        assertGt(gaugeFeeBefore0 + gaugeFeeBefore1, 0, "GaugeFees should have fees");
        
        // Try to claim as owner (non-gauge)
        // uint256 balanceBefore0 = IERC20(pool.token0()).balanceOf(address(owner));
        // uint256 balanceBefore1 = IERC20(pool.token1()).balanceOf(address(owner));
        
        vm.prank(address(owner));
        pool.claimFees();
        
        // Owner should NOT have received gaugeFees
        uint256 gaugeFeesAfter0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFeesAfter1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        // GaugeFees should still be there (not claimed by non-gauge)
        assertEq(gaugeFeesAfter0, gaugeFeeBefore0, "GaugeFees should not be claimed by non-gauge");
        assertEq(gaugeFeesAfter1, gaugeFeeBefore1, "GaugeFees should not be claimed by non-gauge");
    }

    // Test 4: Staked users behavior unchanged (all fees to gauge)
    function test_StakedUsers_AllFeesToGauge_WithZeroUnstakedFee() public {
        // Verify default unstaked fee is 0
        assertEq(factory.unstakedFee(), 0);
        
        // Add liquidity and stake in gauge
        _addLiquidityToPool(address(owner2), address(router), address(FRAX), address(USDC), true, TOKEN_100K, USDC_100K);
        
        vm.startPrank(address(owner2));
        uint256 liquidity = pool.balanceOf(address(owner2));
        pool.approve(address(gauge), liquidity);
        gauge.deposit(liquidity);
        vm.stopPrank();
        
        // Perform swap to generate fees
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1);
        router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        vm.stopPrank();
        
        // Check that no gaugeFees exist (all fees go to poolFees)
        address gaugeFees = pool.gaugeFees();
        uint256 gaugeFee0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFee1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        assertEq(gaugeFee0, 0, "No fees should be in gaugeFees with 0% unstaked fee");
        assertEq(gaugeFee1, 0, "No fees should be in gaugeFees with 0% unstaked fee");
        
        // All fees should be in poolFees
        address poolFees = pool.poolFees();
        uint256 poolFee0 = IERC20(pool.token0()).balanceOf(poolFees);
        uint256 poolFee1 = IERC20(pool.token1()).balanceOf(poolFees);
        
        assertGt(poolFee0 + poolFee1, 0, "All fees should be in poolFees");
    }

    function test_MultipleSwaps_FeesAccumulateCorrectly() public {
        // Set unstaked fee to 20%
        vm.prank(address(owner));
        factory.setUnstakedFee(2000);
        
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        address gaugeFees = pool.gaugeFees();
        address poolFees = pool.poolFees();
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1 * 20);
        
        // Perform multiple swaps and check accumulation
        for (uint256 i = 0; i < 5; i++) {
            uint256 gaugeFeeBefore0 = IERC20(pool.token0()).balanceOf(gaugeFees);
            uint256 poolFeeBefore0 = IERC20(pool.token0()).balanceOf(poolFees);
            
            uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
            router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
            
            uint256 gaugeFeeAfter0 = IERC20(pool.token0()).balanceOf(gaugeFees);
            uint256 poolFeeAfter0 = IERC20(pool.token0()).balanceOf(poolFees);
            
            // Fees should increase with each swap
            assertGt(gaugeFeeAfter0, gaugeFeeBefore0, "GaugeFees should increase");
            assertGt(poolFeeAfter0, poolFeeBefore0, "PoolFees should increase");
        }
        vm.stopPrank();
    }

    function test_DifferentUnstakedFeeRatios() public {
        uint256[] memory feeRatios = new uint256[](5);
        feeRatios[0] = 500;  // 5%
        feeRatios[1] = 1000; // 10%
        feeRatios[2] = 2000; // 20%
        feeRatios[3] = 3000; // 30%
        feeRatios[4] = 5000; // 50%
        
        for (uint256 i = 0; i < feeRatios.length; i++) {
            // Set unstaked fee
            vm.prank(address(owner));
            factory.setUnstakedFee(feeRatios[i]);
            
            // Perform swap on existing pool
            IRouter.Route[] memory routes = new IRouter.Route[](1);
            routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
            
            // Capture state before swap
            address gaugeFees = pool.gaugeFees();
            address poolFees = pool.poolFees();
            uint256 gaugeFee0Before = IERC20(pool.token0()).balanceOf(gaugeFees);
            uint256 poolFee0Before = IERC20(pool.token0()).balanceOf(poolFees);
            
            uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
            
            vm.startPrank(address(owner));
            FRAX.approve(address(router), TOKEN_1);
            router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
            vm.stopPrank();
            
            // Check fee distribution for this swap
            uint256 gaugeFee0After = IERC20(pool.token0()).balanceOf(gaugeFees);
            uint256 poolFee0After = IERC20(pool.token0()).balanceOf(poolFees);
            
            uint256 gaugeFee0Delta = gaugeFee0After - gaugeFee0Before;
            uint256 poolFee0Delta = poolFee0After - poolFee0Before;
            
            if (gaugeFee0Delta + poolFee0Delta > 0) {
                uint256 gaugePercentage = (gaugeFee0Delta * 10000) / (gaugeFee0Delta + poolFee0Delta);
                // Allow for rounding errors
                assertApproxEqRel(gaugePercentage, feeRatios[i], 0.02e18, "Fee ratio should match");
            }
        }
    }

    function test_UnstakedFee_VoterDistribute_ClaimsAll() public {
        // Set unstaked fee to 15%
        vm.prank(address(owner));
        factory.setUnstakedFee(1500);
        
        // Perform multiple swaps
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), true, address(0));
        
        vm.startPrank(address(owner));
        FRAX.approve(address(router), TOKEN_1 * 10);
        for (uint256 i = 0; i < 10; i++) {
            uint256[] memory expectedOutput = router.getAmountsOut(TOKEN_1, routes);
            router.swapExactTokensForTokens(TOKEN_1, expectedOutput[1], routes, address(owner), block.timestamp);
        }
        vm.stopPrank();
        
        // Get gauge address
        address gaugeAddress = voter.gauges(address(pool));
        
        // Capture balances
        address gaugeFees = pool.gaugeFees();
        
        uint256 gaugeFeesBefore0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFeesBefore1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        // Gauge claims fees
        vm.prank(gaugeAddress);
        (uint256 claimed0, uint256 claimed1) = pool.claimFees();
        
        // Verify all fees were claimed
        uint256 gaugeFeesAfter0 = IERC20(pool.token0()).balanceOf(gaugeFees);
        uint256 gaugeFeesAfter1 = IERC20(pool.token1()).balanceOf(gaugeFees);
        
        assertEq(gaugeFeesAfter0, 0, "All gaugeFees should be claimed");
        assertEq(gaugeFeesAfter1, 0, "All gaugeFees should be claimed");
        
        // Claimed amount should include both poolFees portion and all gaugeFees
        assertGt(claimed0 + claimed1, 0, "Fees should have been claimed");
        assertGe(claimed0, gaugeFeesBefore0, "Should include at least all gaugeFees");
        assertGe(claimed1, gaugeFeesBefore1, "Should include at least all gaugeFees");
    }

    function test_UnstakedFee_EmitsCorrectEvents() public {
        // Set unstaked fee
        vm.prank(address(owner));
        vm.expectEmit(true, true, true, true);
        emit IPoolFactory.SetUnstakedFee(1000);
        factory.setUnstakedFee(1000);
    }
}
