// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ILpCandy {
    struct Slot {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 cardinality;
        uint16 cardinalityNext;
        bool unlocked;
    }

    struct GaugeFees {
        uint128 token0;
        uint128 token1;
    }

    struct Amounts {
        uint256 amount0;
        uint256 amount1;
    }

    struct PositionData {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    struct Position {
        uint256 id;
        address lp;
        uint256 liquidity;
        uint256 staked;
        uint256 amount0;
        uint256 amount1;
        uint256 staked0;
        uint256 staked1;
        uint256 unstaked_earned0;
        uint256 unstaked_earned1;
        uint256 emissions_earned;
        int24 tick_lower;
        int24 tick_upper;
        uint160 sqrt_ratio_lower;
        uint160 sqrt_ratio_upper;
    }

    struct Token {
        address token_address;
        string symbol;
        uint8 decimals;
        uint256 account_balance;
        bool listed;
    }

    struct SwapLp {
        address lp;
        int24 typeId;
        address token0;
        address token1;
        address factory;
        uint256 pool_fee;
    }

    struct Lp {
        address lp;
        string symbol;
        uint8 decimals;
        uint256 liquidity;
        int24 typeId;
        int24 tick;
        uint160 sqrt_ratio;
        address token0;
        uint256 reserve0;
        uint256 staked0;
        address token1;
        uint256 reserve1;
        uint256 staked1;
        address gauge;
        uint256 gauge_liquidity;
        bool gauge_alive;
        address fee;
        address bribe;
        address factory;
        uint256 emissions;
        address emissions_token;
        uint256 pool_fee;
        uint256 unstaked_fee;
        uint256 token0_fees;
        uint256 token1_fees;
        address nfpm;
    }

    struct PoolData {
        address factory;
        address pool;
        address gauge;
        address nfpm;
    }
}
