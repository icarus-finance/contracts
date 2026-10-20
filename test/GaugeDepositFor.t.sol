// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract GaugeDepositForTest is BaseTest {
    function _setUp() public override {
        skipToNextEpoch(0);
        pool.approve(address(gauge), type(uint256).max);
    }

    function testBothDepositSelectorsShareAccounting() public {
        gauge.deposit(POOL_1);
        gauge.deposit(POOL_1, address(owner));
        assertEq(gauge.totalSupply(), 2 * POOL_1);
        assertEq(gauge.balanceOf(address(owner)), 2 * POOL_1);
        assertEq(pool.balanceOf(address(gauge)), 2 * POOL_1);
        assertEq(gauge.earned(address(owner)), 0);
    }

    function testRecipientOwnsWithdrawalRights() public {
        gauge.deposit(POOL_1, address(owner2));
        assertEq(gauge.balanceOf(address(owner)), 0);
        assertEq(gauge.balanceOf(address(owner2)), POOL_1);
        vm.expectRevert(stdError.arithmeticError);
        gauge.withdraw(POOL_1);
        uint256 beforeBalance = pool.balanceOf(address(owner2));
        vm.prank(address(owner2));
        gauge.withdraw(POOL_1);
        assertEq(pool.balanceOf(address(owner2)), beforeBalance + POOL_1);
        assertEq(gauge.totalSupply(), 0);
    }

    function testZeroRecipientRevertsWithoutMovingTokens() public {
        uint256 beforeBalance = pool.balanceOf(address(owner));
        uint256 allowance = pool.allowance(address(owner), address(gauge));
        vm.expectRevert(IGauge.InvalidParams.selector);
        gauge.deposit(POOL_1, address(0));
        assertEq(pool.balanceOf(address(owner)), beforeBalance);
        assertEq(pool.balanceOf(address(gauge)), 0);
        assertEq(pool.allowance(address(owner), address(gauge)), allowance);
        assertEq(gauge.totalSupply(), 0);
        assertEq(gauge.balanceOf(address(0)), 0);
    }

    function testRecipientEarnsAndClaimsRewards() public {
        gauge.deposit(POOL_1, address(owner2));
        _addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        skip(2 days);
        assertGt(gauge.earned(address(owner2)), 0);
        assertEq(gauge.earned(address(owner)), 0);
        uint256 beforeBalance = irs.balanceOf(address(owner2));
        vm.prank(address(owner2));
        gauge.getReward(address(owner2));
        assertGt(irs.balanceOf(address(owner2)), beforeBalance);
        assertEq(gauge.earned(address(owner2)), 0);
    }
}
