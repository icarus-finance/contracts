// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import {BaseTestRiseTestnetFork} from "../test/BaseTestRiseTestnetFork.sol";
import {LpCandy, ILpCandy} from "../contracts/candy/LpCandy.sol";
import {RewardsCandy, IRewardsCandy} from "../contracts/candy/RewardsCandy.sol";
import {VeCandy} from "../contracts/candy/VeCandy.sol";
import "forge-std/console2.sol";

contract CandyTest is BaseTestRiseTestnetFork {
    LpCandy public candy;
    RewardsCandy public rewards;
    VeCandy public ve;

    function _setUp() internal override {
        candy = new LpCandy(
            0x2323420F16058D7191deb6758e09Ae3aa9F780E2,
            0x91bf71bbFe01Bc40579f7060c414a12395d22E8A,
            0x1111111111111111111111111111111111111111,
            0xCC4CDa7B1E2202371915541ddD4F01F4120EEA5c
        ); // set deployed candy address

        rewards = new RewardsCandy(
            0x2323420F16058D7191deb6758e09Ae3aa9F780E2
        );

        ve = new VeCandy(
            0x2323420F16058D7191deb6758e09Ae3aa9F780E2,
            0xeB9A1bD5D88dC4cB2Fd9314f7B64778C04E62E1E,
            address(0));
    }

    function testCandyAll() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        ILpCandy.Lp[] memory lp = candy.all(5, 0);
        assertEq(lp.length, 5);
        console2.log(lp.length);
        console2.log(lp[0].lp);
        console2.log(lp[1].lp);
        console2.log(lp[2].lp);
        console2.log(lp[3].lp);
        console2.log(lp[4].lp);
    }

    function testCandyAllOffset() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        ILpCandy.Lp[] memory lp = candy.all(5, 2);
        assertEq(lp.length, 3);
        console2.log(lp.length);
        console2.log(lp[0].lp);
        console2.log(lp[1].lp);
        console2.log(lp[2].lp);
    }

    function testCandForSwaps() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        ILpCandy.SwapLp[] memory swaps = candy.forSwaps(5, 0);
    }

    function testCandTokens() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        address[] memory _addresses = new address[](0);
        ILpCandy.Token[] memory tokens = candy.tokens(10, 0, 0x05D3ed0385bEc3a47F1Fc67971E75B6e3041d813, _addresses);
    }

    function testCandPositions() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        // address[] memory _addresses = new address[](0);
        ILpCandy.Position[] memory tokens = candy.positions(10, 0, 0x05D3ed0385bEc3a47F1Fc67971E75B6e3041d813);
    }

    function testCandPositionsByFactoryV2() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        // address[] memory _addresses = new address[](0);
        ILpCandy.Position[] memory tokens = candy.positionsByFactory(
            10,
            0,
            0x05D3ed0385bEc3a47F1Fc67971E75B6e3041d813,
            0x0fc0cAF0b23132ED8759d0C48aB0C5fC151b1Ddf
        );
    }

    function testCandPositionsByFactoryV3() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        // address[] memory _addresses = new address[](0);
        ILpCandy.Position[] memory tokens = candy.positionsByFactory(
            10,
            0,
            0x05D3ed0385bEc3a47F1Fc67971E75B6e3041d813,
            0x5591e3f890725F0f3dbF47B63c81bbb91975483c
        );
    }

    function testRewardsEpochsLatest() public {
        IRewardsCandy.LpEpoch[] memory epoch = rewards.epochsLatest(10, 0);
    }

    function testVeAll() public {
        VeCandy.VeNFT[] memory veNfts = ve.all(10, 0);
    }
}
