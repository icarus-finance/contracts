// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";
import {LiquidityStakeHelper} from "contracts/LiquidityStakeHelper.sol";

contract LiquidityStakeHelperTest is BaseTest {
    LiquidityStakeHelper helper;

    function _setUp() public override {
        helper = new LiquidityStakeHelper(address(router));
        USDC.approve(address(helper), type(uint256).max);
        FRAX.approve(address(helper), type(uint256).max);
    }

    function params() internal view returns (LiquidityStakeHelper.AddLiquidityParams memory p) {
        p = LiquidityStakeHelper.AddLiquidityParams({
            tokenA: address(USDC),
            tokenB: address(FRAX),
            stable: true,
            amountADesired: USDC_1,
            amountBDesired: TOKEN_1,
            amountAMin: 0,
            amountBMin: 0,
            minLiquidity: 1,
            recipient: address(owner2),
            deadline: block.timestamp
        });
    }

    function testStakeAndWithdraw() public {
        (, , uint256 liquidity) = helper.addLiquidityAndStake(params());
        assertEq(gauge.balanceOf(address(owner2)), liquidity);
        assertEq(pool.balanceOf(address(helper)), 0);
        assertEq(USDC.allowance(address(helper), address(router)), 0);
        assertEq(FRAX.allowance(address(helper), address(router)), 0);
        assertEq(pool.allowance(address(helper), address(gauge)), 0);
        uint256 beforeBalance = pool.balanceOf(address(owner2));
        vm.prank(address(owner2));
        gauge.withdraw(liquidity);
        assertEq(pool.balanceOf(address(owner2)), beforeBalance + liquidity);
    }

    function testRefundPreservesDonations() public {
        USDC.transfer(address(helper), 123);
        FRAX.transfer(address(helper), 456);
        pool.transfer(address(helper), 789);
        uint256 beforeA = USDC.balanceOf(address(this));
        uint256 beforeB = FRAX.balanceOf(address(this));
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.amountBDesired *= 2;
        (uint256 a, uint256 b, ) = helper.addLiquidityAndStake(p);
        assertLt(b, p.amountBDesired);
        assertEq(USDC.balanceOf(address(this)), beforeA - a);
        assertEq(FRAX.balanceOf(address(this)), beforeB - b);
        assertEq(USDC.balanceOf(address(helper)), 123);
        assertEq(FRAX.balanceOf(address(helper)), 456);
        assertEq(pool.balanceOf(address(helper)), 789);
    }

    function testVolatileReverseTokens() public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.stable = false;
        p.tokenA = address(FRAX);
        p.tokenB = address(USDC);
        p.amountADesired = TOKEN_1;
        p.amountBDesired = USDC_1;
        (, , uint256 liquidity) = helper.addLiquidityAndStake(p);
        assertEq(gauge2.balanceOf(address(owner2)), liquidity);
    }

    function testKilledGauge() public {
        voter.killGauge(address(gauge));
        vm.expectRevert(LiquidityStakeHelper.InvalidGauge.selector);
        helper.addLiquidityAndStake(params());
    }

    function testMissingGauge() public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.tokenB = address(DAI);
        vm.expectRevert(LiquidityStakeHelper.InvalidGauge.selector);
        helper.addLiquidityAndStake(p);
    }

    function testMinLiquidityRollback() public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.minLiquidity = type(uint256).max;
        uint256 beforeBalance = USDC.balanceOf(address(this));
        vm.expectRevert(LiquidityStakeHelper.InsufficientLiquidity.selector);
        helper.addLiquidityAndStake(p);
        assertEq(USDC.balanceOf(address(this)), beforeBalance);
        assertEq(gauge.balanceOf(address(owner2)), 0);
        assertEq(USDC.allowance(address(helper), address(router)), 0);
    }

    function testDeadline() public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.deadline = block.timestamp - 1;
        vm.expectRevert(IRouter.Expired.selector);
        helper.addLiquidityAndStake(p);
    }

    function testSlippage() public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.amountAMin = p.amountADesired + 1;
        vm.expectRevert(IRouter.InsufficientAmountADesired.selector);
        helper.addLiquidityAndStake(p);
    }

    function testZeroRecipient() public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.recipient = address(0);
        vm.expectRevert(LiquidityStakeHelper.InvalidParams.selector);
        helper.addLiquidityAndStake(p);
    }

    function testRejectsShortTransferWithoutSpendingDonations() public {
        USDC.transfer(address(helper), USDC_1);
        vm.mockCall(
            address(USDC),
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(helper), USDC_1),
            abi.encode(true)
        );
        vm.expectRevert(LiquidityStakeHelper.UnsupportedToken.selector);
        helper.addLiquidityAndStake(params());
        assertEq(USDC.balanceOf(address(helper)), USDC_1);
    }

    function testRejectsMismatchedGauge() public {
        vm.mockCall(address(gauge), abi.encodeWithSelector(IGauge.stakingToken.selector), abi.encode(address(pool2)));
        vm.expectRevert(LiquidityStakeHelper.InvalidGauge.selector);
        helper.addLiquidityAndStake(params());
    }

    function testFuzzRefundAccounting(uint96 desiredA, uint96 desiredB, bool stable) public {
        LiquidityStakeHelper.AddLiquidityParams memory p = params();
        p.amountADesired = bound(desiredA, USDC_1, USDC_10K);
        p.amountBDesired = bound(desiredB, TOKEN_1, TOKEN_10K);
        p.stable = stable;
        uint256 beforeA = USDC.balanceOf(address(this));
        uint256 beforeB = FRAX.balanceOf(address(this));
        (uint256 a, uint256 b, uint256 liquidity) = helper.addLiquidityAndStake(p);
        assertEq(USDC.balanceOf(address(this)), beforeA - a);
        assertEq(FRAX.balanceOf(address(this)), beforeB - b);
        assertEq(USDC.balanceOf(address(helper)), 0);
        assertEq(FRAX.balanceOf(address(helper)), 0);
        assertEq((stable ? gauge : gauge2).balanceOf(address(owner2)), liquidity);
    }
}
