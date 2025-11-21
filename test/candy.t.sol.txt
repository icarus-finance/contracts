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
            0x4ef9959218f463b51cB7Cb98F72Af6aC64676A1b,
            0x5394D7ABbE45852a74B77198a8a805101fe81974,
            0x1111111111111111111111111111111111111111,
            0x48c04a8dE98D343CAb5eabEAd4c2e5596dd82F00
        ); // set deployed candy address

        rewards = new RewardsCandy(
            0x4ef9959218f463b51cB7Cb98F72Af6aC64676A1b
        );

        ve = new VeCandy(
            0x4ef9959218f463b51cB7Cb98F72Af6aC64676A1b,
            0x51750C7E45614640ACd7a621FF152A63Ece107ad,
            address(0));
    }

    function testCandyAll() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        ILpCandy.Lp[] memory lp = candy.all(100, 0);
        // assertEq(lp.length, 5);
        // console2.log(lp.length);
        // console2.log(lp[0].lp);
        // console2.log(lp[1].lp);
        // console2.log(lp[2].lp);
        // console2.log(lp[3].lp);
        // console2.log(lp[4].lp);
    }

    function testCandyOffsetAll() public {
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

    function testCandyPositions() public {
        // assertEq(candy.convertor(), 0x1111111111111111111111111111111111111111);
        // address[] memory _addresses = new address[](0);
        ILpCandy.Position[] memory tokens = candy.positions(20, 0, 0x05D3ed0385bEc3a47F1Fc67971E75B6e3041d813);
        assertEq(tokens.length, 9);
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

    function testRewardsOfNFT() public {
        IRewardsCandy.Reward[] memory rewardsData = rewards.rewards(10, 0, 1);
        assertEq(rewardsData.length, 3);
    }

    function testVeAll() public {
        VeCandy.VeNFT[] memory veNfts = ve.all(10, 0);
    }
}
