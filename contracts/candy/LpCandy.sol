// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/**
 * @title Icarus Finance LP Candy
 * @author Icarus Finance (https://icarus.finance)
 */
import {ILpCandy} from "./interfaces/ILpCandy.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IPoolFactory} from "../interfaces/factories/IPoolFactory.sol";
import {IFactoryRegistry} from "../interfaces/factories/IFactoryRegistry.sol";
import {ICandyPool} from "./interfaces/ICandyPool.sol";
import {ICLGauge} from "./interfaces/ICLGauge.sol";
import {INFPositionManager} from "./interfaces/INFPositionManager.sol";
import {ISlipstreamHelper} from "./interfaces/ISlipstreamHelper.sol";
import {ISymbol} from "./interfaces/ISymbol.sol";
import {ISymbolBytes32} from "./interfaces/ISymbolBytes32.sol";
import {LpShared} from "./libraries/LpShared.sol";

interface IPoolFactoryFix is IPoolFactory {
    /// @notice Support for v3-style pools which wraps around getPool(tokenA,tokenB,stable)
    /// @dev fee is converted to stable boolean.
    /// @param tokenA .
    /// @param tokenB .
    /// @param fee  1 if stable, 0 if volatile, else returns address(0)
    function getPool(address tokenA, address tokenB, int24 fee) external view returns (address);
}

contract LpCandy is ILpCandy {
    // Constants
    uint256 public constant MAX_TOKENS = 2000;
    uint256 public constant MAX_LPS = 500;
    uint256 public constant MAX_POSITIONS = 200;
    uint256 public constant MAX_TOKEN_SYMBOL_LEN = 32;
    uint256 public constant MAX_UINT = type(uint256).max;
    uint256 public constant MAX_FACTORIES = 10;
    uint256 public constant MAX_POOLS = 2000;
    uint256 public constant MAX_ITERATIONS = 16000;

    address internal constant CL_FACTORY = 0x83bBBa92c68a367eAABd9d1AEBe6c71ec5E1d39f;
    address internal constant CL_NFPM = 0x8e1F74CafDdFfC48051AEfe69d0c28F9ADe1c9e2;

    IVoter public immutable voter;
    IFactoryRegistry public immutable registry;
    address public immutable convertor;

    // Variables
    ISlipstreamHelper public cl_helper;

    /**
     * @dev Sets up our external contract addresses
     * @param _voter Address of the voter contract
     * @param _registry Address of the registry contract
     * @param _convertor Address of the convertor contract
     * @param _slipstream_helper Address of the Slipstream helper contract
     */
    constructor(address _voter, address _registry, address _convertor, address _slipstream_helper) {
        voter = IVoter(_voter);
        convertor = _convertor;
        registry = IFactoryRegistry(_registry);
        cl_helper = ISlipstreamHelper(_slipstream_helper);
    }

    /**
     * @notice Returns a compiled list of pools for swaps from pool factories (sans v1)
     * @param _limit The max amount of pools to process
     * @param _offset The amount of pools to skip
     * @return pools Array of SwapLp structs
     */
    function forSwaps(uint256 _limit, uint256 _offset) external view returns (SwapLp[] memory) {
        address[] memory factories = registry.poolFactories();

        // Pre-allocate with maximum size, we'll resize later
        SwapLp[] memory pools = new SwapLp[](_limit);
        uint256 poolCount = 0;
        uint256 toSkip = _offset;

        for (uint256 index = 0; index < factories.length && index < MAX_FACTORIES; index++) {
            IPoolFactory factory = IPoolFactory(factories[index]);
            bool isCL = factories[index] == CL_FACTORY;
            uint256 poolsLength = factory.allPoolsLength();

            for (uint256 pindex = 0; pindex < poolsLength && pindex < MAX_ITERATIONS; pindex++) {
                // If we've collected enough pools, exit
                if (poolCount >= _limit) {
                    break;
                }

                address poolAddr = factory.allPools(pindex);
                
                // Quick filter check: reserve0 > 0 or convertor
                bool passesFilter;
                if (poolAddr == convertor) {
                    passesFilter = true;
                } else if (isCL) {
                    passesFilter = _safeBalanceOf(ICandyPool(poolAddr).token0(), poolAddr) > 0 || _safeBalanceOf(ICandyPool(poolAddr).token1(), poolAddr) > 0;
                } else {
                    passesFilter = ICandyPool(poolAddr).reserve0() > 0;
                }

                if (!passesFilter) {
                    continue;
                }

                // Skip pools for offset (applied after filtering)
                if (toSkip > 0) {
                    toSkip--;
                    continue;
                }

                // Only build full SwapLp when we're actually going to use it
                pools[poolCount++] = _buildSwapLp(factory, poolAddr, isCL);
            }

            // Break outer loop if limit reached
            if (poolCount >= _limit) {
                break;
            }
        }

        // If limit is reached just return the array
        if (poolCount == _limit) {
            return pools;
        }

        // Resize the array to the actual number of pools found
        SwapLp[] memory result = new SwapLp[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            result[i] = pools[i];
        }

        return result;
    }

    /**
     * @notice Helper to build SwapLp struct
     * @param _factory The pool factory
     * @param _poolAddr The pool address
     * @param _isCL Whether this is a CL factory
     * @return swapLp The SwapLp struct
     */
    function _buildSwapLp(
        IPoolFactory _factory,
        address _poolAddr,
        bool _isCL
    ) internal view returns (SwapLp memory swapLp) {
        ICandyPool pool = ICandyPool(_poolAddr);
        address token0 = pool.token0();
        int24 typeId = -1;
        uint256 poolFee;

        if (_isCL) {
            typeId = pool.tickSpacing();
            poolFee = uint256(pool.fee());
        } else {
            bool isStable = pool.stable();
            if (isStable) {
                typeId = 0;
            }
            poolFee = _factory.getFee(_poolAddr, isStable);
        }

        swapLp = SwapLp({
            lp: _poolAddr,
            typeId: typeId,
            token0: token0,
            token1: pool.token1(),
            factory: address(_factory),
            pool_fee: poolFee
        });
    }

    /**
     * @notice Returns a collection of tokens data based on available pools
     * @param _limit The max amount of tokens to return
     * @param _offset The amount of pools to skip
     * @param _account The account to check the balances
     * @param _addresses Array of token addresses to include
     * @return Array of Token structs
     */
    function tokens(
        uint256 _limit,
        uint256 _offset,
        address _account,
        address[] memory _addresses
    ) external view returns (Token[] memory) {
        PoolData[] memory pools = LpShared.pools(_limit, _offset, address(0), registry, voter, convertor);
        uint256 poolsCount = pools.length;
        uint256 addressesCount = _addresses.length;

        // Pre-allocate with maximum size, we'll resize later
        Token[] memory col = new Token[](_limit);
        uint256 colCount = 0;
        address[] memory seen = new address[](MAX_TOKENS);
        uint256 seenCount = 0;

        // First add tokens from the provided addresses list
        for (uint256 index = 0; index < addressesCount && colCount < _limit; index++) {
            seen[seenCount++] = _addresses[index];
            Token memory newToken = _tokenInfo(_addresses[index], _account);

            if (newToken.decimals != 0 && bytes(newToken.symbol).length > 0) {
                col[colCount++] = newToken;
            }
        }

        // Then add tokens from the pools
        for (uint256 index = 0; index < poolsCount && colCount < _limit; index++) {
            PoolData memory poolData = pools[index];
            ICandyPool pool = ICandyPool(poolData.pool);
            address[2] memory _tokens = [pool.token0(), pool.token1()];

            for (uint256 j = 0; j < 2; j++) {
                address ptoken = _tokens[j];
                bool alreadySeen = false;

                // Check if we've already seen this token
                for (uint256 k = 0; k < seenCount; k++) {
                    if (seen[k] == ptoken) {
                        alreadySeen = true;
                        break;
                    }
                }

                if (alreadySeen) continue;

                seen[seenCount++] = ptoken;
                Token memory newToken = _tokenInfo(ptoken, _account);

                // Skip tokens that fail basic ERC20 calls
                if (newToken.decimals != 0 && bytes(newToken.symbol).length > 0) {
                    col[colCount++] = newToken;
                    if (colCount >= _limit) break;
                }
            }
        }

        // If limit is reached just return the array
        if (colCount == _limit) {
            return col;
        }

        // Resize the array to the actual number of tokens found
        Token[] memory result = new Token[](colCount);
        for (uint256 i = 0; i < colCount; i++) {
            result[i] = col[i];
        }

        return result;
    }

    /**
     * @notice Returns a collection of pool data
     * @param _limit The max amount of pools to return
     * @param _offset The amount of pools to skip
     * @return Array of Lp structs
     */
    function all(uint256 _limit, uint256 _offset) external view returns (Lp[] memory) {
        // Pre-allocate with maximum size, we'll resize later
        Lp[] memory col = new Lp[](_limit);
        uint256 colCount = 0;
        PoolData[] memory pools = LpShared.pools(_limit, _offset, address(0), registry, voter, convertor);
        uint256 poolsCount = pools.length;

        for (uint256 index = 0; index < poolsCount && colCount < _limit; index++) {
            PoolData memory poolData = pools[index];
            ICandyPool pool = ICandyPool(poolData.pool);
            address token0 = pool.token0();
            address token1 = pool.token1();

            // If this is a CL factory/NFPM present...
            if (poolData.nfpm != address(0)) {
                col[colCount++] = _clLp(poolData, token0, token1);
            } else {
                col[colCount++] = _v2Lp(poolData, token0, token1);
            }
        }

        // If limit is reached just return the array
        if (colCount == _limit) {
            return col;
        }

        // Resize the array to the actual number of pools found
        Lp[] memory result = new Lp[](colCount);
        for (uint256 i = 0; i < colCount; i++) {
            result[i] = col[i];
        }

        return result;
    }

    /**
     * @notice Returns pool data for a specific address
     * @param _address The pool address to lookup
     * @return Lp struct
     */
    function byAddress(address _address) external view returns (Lp memory) {
        // Limit is max, internal call will return when _address is hit
        PoolData[] memory poolData = LpShared.pools(16000, 0, _address, registry, voter, convertor);
        require(poolData.length > 0, "Pool not found");

        ICandyPool pool = ICandyPool(poolData[0].pool);
        address token0 = pool.token0();
        address token1 = pool.token1();

        // If this is a CL factory/NFPM present...
        if (poolData[0].nfpm != address(0)) {
            return _clLp(poolData[0], token0, token1);
        }

        return _v2Lp(poolData[0], token0, token1);
    }

    /**
     * @notice Returns pool data at a specific stored index
     * @param _index The index to lookup
     * @return Lp struct
     */
    function byIndex(uint256 _index) external view returns (Lp memory) {
        // Basically index is the offset and the limit is always one...
        // This will fire if _index is out of bounds
        PoolData[] memory poolData = LpShared.pools(1, _index, address(0), registry, voter, convertor);
        require(poolData.length > 0, "Pool index out of bounds");

        ICandyPool pool = ICandyPool(poolData[0].pool);
        address token0 = pool.token0();
        address token1 = pool.token1();

        // If this is a CL factory/NFPM present...
        if (poolData[0].nfpm != address(0)) {
            return _clLp(poolData[0], token0, token1);
        }

        return _v2Lp(poolData[0], token0, token1);
    }

    /**
     * @notice Returns a collection of positions
     * @param _limit The max amount of pools to process
     * @param _offset The amount of pools to skip (for optimization)
     * @param _account The account to fetch positions for
     * @return Array of Position structs
     */
    function positions(uint256 _limit, uint256 _offset, address _account) external view returns (Position[] memory) {
        address[] memory factories = registry.poolFactories();
        return _positions(_limit, _offset, _account, factories);
    }

    /**
     * @notice Returns a collection of positions for the given factory
     * @param _limit The max amount of pools to process
     * @param _offset The amount of pools to skip (for optimization)
     * @param _account The account to fetch positions for
     * @param _factory The INFPositionManager address used to fetch positions
     * @return Array of Position structs
     */
    function positionsByFactory(
        uint256 _limit,
        uint256 _offset,
        address _account,
        address _factory
    ) external view returns (Position[] memory) {
        address[] memory factories = new address[](1);
        factories[0] = _factory;
        return _positions(_limit, _offset, _account, factories);
    }

    /**
     * INTERNAL ****
     */

    /**
     * @notice Helper function to get token information
     * @param _address The token address
     * @param _account The account to check balance for
     * @return Token struct with token information
     */
    function _tokenInfo(address _address, address _account) internal view returns (Token memory) {
        uint256 bal = 0;

        if (_account != address(0)) {
            bal = _safeBalanceOf(_address, _account);
        }

        return
            Token({
                token_address: _address,
                symbol: _safeSymbol(_address),
                decimals: _safeDecimals(_address),
                account_balance: bal,
                listed: voter.isWhitelistedToken(_address)
            });
    }

    /**
     * @notice Returns a collection of positions for a set of factories
     * @param _limit The max amount of positions to return
     * @param _offset The amount of positions to skip
     * @param _account The account to fetch positions for
     * @param _factories The factories to fetch from
     * @return Array of Position structs
     */
    function _positions(
        uint256 _limit,
        uint256 _offset,
        address _account,
        address[] memory _factories
    ) internal view returns (Position[] memory) {
        // Pre-allocate with maximum size, we'll resize later
        Position[] memory positionsData = new Position[](_limit);
        uint256 positionsCount = 0;

        if (_account == address(0)) {
            return new Position[](0);
        }

        uint256 toSkip = _offset;
        uint256 factoriesCount = _factories.length;

        for (uint256 index = 0; index < MAX_FACTORIES && index < factoriesCount; index++) {
            // Exit if we've collected enough positions
            if (positionsCount >= _limit) {
                break;
            }

            IPoolFactory factory = IPoolFactory(_factories[index]);

            uint256 poolsCount = factory.allPoolsLength();
            address nfpmAddr = _factories[index] == CL_FACTORY
                ? CL_NFPM
                : address(0);

            // V2/Basic pool
            if (nfpmAddr == address(0)) {
                for (uint256 pindex = 0; pindex < MAX_ITERATIONS && pindex < poolsCount; pindex++) {
                    if (positionsCount >= _limit) {
                        break;
                    }

                    address poolAddr = factory.allPools(pindex);

                    // Skip convertor pool entirely
                    if (poolAddr == convertor) {
                        continue;
                    }

                    // Quick balance check before expensive _v2Position call
                    uint256 lpBalance = ICandyPool(poolAddr).balanceOf(_account);
                    address gaugeAddr = voter.gauges(poolAddr);
                    uint256 stakedBalance = gaugeAddr != address(0) ? IGauge(gaugeAddr).balanceOf(_account) : 0;
                    
                    // Skip if user has no position in this pool
                    if (lpBalance == 0 && stakedBalance == 0) {
                        continue;
                    }

                    // Skip positions for offset (applied after filtering)
                    if (toSkip > 0) {
                        toSkip--;
                        continue;
                    }

                    Position memory pos = _v2Position(_account, poolAddr);

                    if (positionsCount < MAX_POSITIONS) {
                        positionsData[positionsCount++] = pos;
                    } else {
                        break;
                    }
                }
            } else {
                INFPositionManager nfpm = INFPositionManager(nfpmAddr);
                // CL pools
                for (uint256 pindex = 0; pindex < MAX_POOLS && pindex < poolsCount; pindex++) {
                    if (positionsCount >= _limit) {
                        break;
                    }

                    address poolAddr = factory.allPools(pindex);
                    address gaugeAddr = voter.gauges(poolAddr);
                    ICLGauge gauge = ICLGauge(gaugeAddr);

                    // Fetch unstaked CL positions if supported
                    uint256[] memory userPosIds;
                    try nfpm.userPositions(_account, poolAddr) returns (uint256[] memory fetchedPositionIds) {
                        userPosIds = fetchedPositionIds;
                    } catch {
                        userPosIds = new uint256[](0);
                    }

                    if (userPosIds.length > 0) {
                        for (uint256 upindex = 0; upindex < userPosIds.length; upindex++) {
                            if (positionsCount >= _limit) {
                                break;
                            }

                            // Skip positions for offset
                            if (toSkip > 0) {
                                toSkip--;
                                continue;
                            }

                            Position memory pos = _clPosition(
                                userPosIds[upindex],
                                _account,
                                poolAddr,
                                gaugeAddr,
                                address(factory),
                                nfpmAddr
                            );

                            if (positionsCount < MAX_POSITIONS) {
                                positionsData[positionsCount++] = pos;
                            } else {
                                break;
                            }
                        }
                    }

                    // Fetch staked CL positions
                    if (gaugeAddr != address(0)) {
                        uint256[] memory stakedPositionIds = gauge.stakedValues(_account);

                        for (uint256 sindex = 0; sindex < stakedPositionIds.length; sindex++) {
                            if (positionsCount >= _limit) {
                                break;
                            }

                            // Skip positions for offset
                            if (toSkip > 0) {
                                toSkip--;
                                continue;
                            }

                            Position memory pos = _clPosition(
                                stakedPositionIds[sindex],
                                _account,
                                poolAddr,
                                gaugeAddr,
                                address(factory),
                                nfpmAddr
                            );

                            if (positionsCount < MAX_POSITIONS) {
                                positionsData[positionsCount++] = pos;
                            } else {
                                break;
                            }
                        }
                    }
                }
            }
        }

        // If limit is reached just return the array
        if (positionsCount == _limit) {
            return positionsData;
        }

        // Resize the array to the actual number of positions found
        Position[] memory result = new Position[](positionsCount);
        for (uint256 i = 0; i < positionsCount; i++) {
            result[i] = positionsData[i];
        }

        return result;
    }

    /**
     * @notice Returns concentrated pool position data
     * @param _id The token ID of the position
     * @param _account The account to fetch positions for
     * @param _pool The pool address
     * @param _gauge The pool gauge address
     * @param _factory The CL factory address
     * @param _nfpm The NFT position manager address
     * @return A Position struct
     */
    function _clPosition(
        uint256 _id,
        address _account,
        address _pool,
        address _gauge,
        address _factory,
        address _nfpm
    ) internal view returns (Position memory) {
        Position memory pos;
        pos.id = _id;
        pos.lp = _pool;

        INFPositionManager nfpm = INFPositionManager(_nfpm);
        PositionData memory data = nfpm.positions(pos.id);

        // Try to find the pool if we're fetching an unstaked position
        if (pos.lp == address(0)) {
            pos.lp = IPoolFactoryFix(_factory).getPool(data.token0, data.token1, int24(data.tickSpacing));
        }

        if (pos.lp == address(0)) {
            return pos; // Return empty position
        }

        ICLGauge gauge = ICLGauge(_gauge);
        Slot memory slot = ICandyPool(pos.lp).slot0();
        bool staked = false;

        // Try to find the gauge if we're fetching an unstaked position
        if (_gauge == address(0)) {
            gauge = ICLGauge(voter.gauges(pos.lp));
        }

        Amounts memory amounts = cl_helper.principal(_nfpm, pos.id, slot.sqrtPriceX96);
        pos.amount0 = amounts.amount0;
        pos.amount1 = amounts.amount1;

        pos.liquidity = uint256(data.liquidity);
        pos.tick_lower = data.tickLower;
        pos.tick_upper = data.tickUpper;

        pos.sqrt_ratio_lower = cl_helper.getSqrtRatioAtTick(pos.tick_lower);
        pos.sqrt_ratio_upper = cl_helper.getSqrtRatioAtTick(pos.tick_upper);

        Amounts memory amountsFees = cl_helper.fees(_nfpm, pos.id);
        pos.unstaked_earned0 = amountsFees.amount0;
        pos.unstaked_earned1 = amountsFees.amount1;

        if (address(gauge) != address(0)) {
            staked = gauge.stakedContains(_account, pos.id);
        }

        if (staked) {
            pos.emissions_earned = gauge.earned(_account, pos.id) + gauge.rewards(pos.id);
        }

        // Reverse the liquidity since a staked position uses full available liquidity
        if (staked) {
            pos.staked = pos.liquidity;
            pos.staked0 = pos.amount0;
            pos.staked1 = pos.amount1;
            pos.amount0 = 0;
            pos.amount1 = 0;
            pos.liquidity = 0;
        }

        return pos;
    }

    /**
     * @notice Returns v2 pool position data
     * @param _account The account to fetch positions for
     * @param _pool The pool address
     * @return A Position struct
     */
    function _v2Position(address _account, address _pool) internal view returns (Position memory) {
        ICandyPool pool = ICandyPool(_pool);
        address gaugeAddr = voter.gauges(_pool);
        IGauge gauge = IGauge(gaugeAddr);
        uint8 decimals = pool.decimals();

        Position memory pos;
        pos.lp = address(pool);
        pos.liquidity = pool.balanceOf(_account);
        pos.unstaked_earned0 = pool.claimable0(_account);
        pos.unstaked_earned1 = pool.claimable1(_account);

        uint256 claimableDelta0 = pool.index0() - pool.supplyIndex0(_account);
        uint256 claimableDelta1 = pool.index1() - pool.supplyIndex1(_account);

        if (claimableDelta0 > 0) {
            pos.unstaked_earned0 += (pos.liquidity * claimableDelta0) / (10 ** uint256(decimals));
        }
        if (claimableDelta1 > 0) {
            pos.unstaked_earned1 += (pos.liquidity * claimableDelta1) / (10 ** uint256(decimals));
        }

        if (gaugeAddr != address(0)) {
            pos.staked = gauge.balanceOf(_account);
            pos.emissions_earned = gauge.earned(_account);
        }

        if (pos.liquidity + pos.staked + pos.emissions_earned + pos.unstaked_earned0 == 0) {
            return pos; // Return empty position
        }

        uint256 poolLiquidity = pool.totalSupply();
        uint256 reserve0 = pool.reserve0();
        uint256 reserve1 = pool.reserve1();

        if (poolLiquidity > 0) {
            pos.amount0 = (pos.liquidity * reserve0) / poolLiquidity;
            pos.amount1 = (pos.liquidity * reserve1) / poolLiquidity;
            pos.staked0 = (pos.staked * reserve0) / poolLiquidity;
            pos.staked1 = (pos.staked * reserve1) / poolLiquidity;
        }

        return pos;
    }

    /**
     * @notice Returns pool data based on the factory, pool and gauge addresses for V2 pools
     * @param _data The addresses to lookup [factory, pool, gauge, nfpm]
     * @param _token0 Token0 address
     * @param _token1 Token1 address
     * @return Lp struct
     */
    function _v2Lp(PoolData memory _data, address _token0, address _token1) internal view returns (Lp memory) {
        ICandyPool pool = ICandyPool(_data.pool);
        IGauge gauge = IGauge(_data.gauge);

        uint256 poolLiquidity = pool.totalSupply();
        uint256 gaugeLiquidity = 0;
        uint256 emissions = 0;
        address emissionsToken = address(0);
        bool isStable = pool.stable();
        IPoolFactory factory = IPoolFactory(_data.factory);
        uint256 poolFee = factory.getFee(address(pool), isStable);
        address poolFees = pool.poolFees();
        uint256 token0Fees = _safeBalanceOf(_token0, poolFees);
        uint256 token1Fees = _safeBalanceOf(_token1, poolFees);
        bool gaugeAlive = voter.isAlive(address(gauge));
        uint8 decimals = pool.decimals();
        uint256 reserve0 = pool.reserve0();
        uint256 reserve1 = pool.reserve1();
        uint256 staked0 = 0;
        uint256 staked1 = 0;
        int24 typeId = -1;

        if (isStable) {
            typeId = 0;
        }

        if (address(gauge) != address(0)) {
            gaugeLiquidity = gauge.totalSupply();
            emissionsToken = gauge.rewardToken();
        }

        if (gaugeAlive && gauge.periodFinish() > block.timestamp) {
            emissions = gauge.rewardRate();
            if (gaugeLiquidity > 0) {
                token0Fees = (pool.claimable0(_data.gauge) * poolLiquidity) / gaugeLiquidity;
                token1Fees = (pool.claimable1(_data.gauge) * poolLiquidity) / gaugeLiquidity;
                staked0 = (reserve0 * gaugeLiquidity) / poolLiquidity;
                staked1 = (reserve1 * gaugeLiquidity) / poolLiquidity;
            }
        }

        return
            Lp({
                lp: _data.pool,
                symbol: _safeSymbol(address(pool)),
                decimals: decimals,
                liquidity: poolLiquidity,
                typeId: typeId,
                tick: 0,
                sqrt_ratio: 0,
                token0: _token0,
                reserve0: reserve0,
                staked0: staked0,
                token1: _token1,
                reserve1: reserve1,
                staked1: staked1,
                gauge: address(gauge),
                gauge_liquidity: gaugeLiquidity,
                gauge_alive: gaugeAlive,
                fee: voter.gaugeToFees(address(gauge)),
                bribe: voter.gaugeToBribe(address(gauge)),
                factory: _data.factory,
                emissions: emissions,
                emissions_token: emissionsToken,
                pool_fee: poolFee,
                unstaked_fee: 0,
                token0_fees: token0Fees,
                token1_fees: token1Fees,
                nfpm: address(0)
            });
    }

    /**
     * @notice Helper function to get the CL pool data
     * @param _data Pool data [factory, pool, gauge, nfpm]
     * @param _token0 Token0 address
     * @param _token1 Token1 address
     * @return Lp struct
     */
    function _clLp(PoolData memory _data, address _token0, address _token1) internal view returns (Lp memory) {
        ICandyPool pool = ICandyPool(_data.pool);
        ICLGauge gauge = ICLGauge(_data.gauge);

        // This implementation is a placeholder - in a real implementation
        // this would include all the CLPool specific logic
        Slot memory slot = pool.slot0();
        uint128 liquidity = pool.liquidity();
        uint128 stakedLiquidity = pool.stakedLiquidity();
        uint256 totalLiquidity = uint256(liquidity);
        int24 tickSpacing = pool.tickSpacing();
        uint24 fee = pool.fee();
        uint24 unstakedFee = pool.unstakedFee();

        address emissionsToken = address(0);
        uint256 emissions = 0;
        bool gaugeAlive = false;

        if (address(gauge) != address(0)) {
            emissionsToken = gauge.rewardToken();
            gaugeAlive = voter.isAlive(address(gauge));

            if (gaugeAlive && gauge.periodFinish() > block.timestamp) {
                emissions = gauge.rewardRate();
            }
        }

        GaugeFees memory gaugeFees = pool.gaugeFees();

        return
            Lp({
                lp: _data.pool,
                symbol: _safeSymbol(address(pool)),
                decimals: 18, // Most CL pools use 18 decimals
                liquidity: totalLiquidity,
                typeId: tickSpacing,
                tick: slot.tick,
                sqrt_ratio: slot.sqrtPriceX96,
                token0: _token0,
                reserve0: _safeBalanceOf(_token0, _data.pool),
                staked0: uint256(gaugeFees.token0),
                token1: _token1,
                reserve1: _safeBalanceOf(_token1, _data.pool),
                staked1: uint256(gaugeFees.token1),
                gauge: address(gauge),
                gauge_liquidity: uint256(stakedLiquidity),
                gauge_alive: gaugeAlive,
                fee: voter.gaugeToFees(address(gauge)),
                bribe: voter.gaugeToBribe(address(gauge)),
                factory: _data.factory,
                emissions: emissions,
                emissions_token: emissionsToken,
                pool_fee: uint256(fee),
                unstaked_fee: uint256(unstakedFee),
                token0_fees: uint256(gaugeFees.token0),
                token1_fees: uint256(gaugeFees.token1),
                nfpm: _data.nfpm
            });
    }

    /**
     * @notice Helper function to safely get a token's symbol
     * @param _token The token address
     * @return The token symbol or empty string on failure
     */
    function _safeSymbol(address _token) internal view returns (string memory) {
        try ISymbol(_token).symbol() returns (string memory symbol) {
            if (bytes(symbol).length > MAX_TOKEN_SYMBOL_LEN) {
                return "";
            }
            return symbol;
        } catch {
            try ISymbolBytes32(_token).symbol() returns (bytes32 symbolBytes32) {
                string memory symbol = _bytes32ToString(symbolBytes32);
                if (bytes(symbol).length > MAX_TOKEN_SYMBOL_LEN) {
                    return "";
                }
                return symbol;
            } catch {
                return "";
            }
        }
    }

    /**
     * @notice Helper function to safely get a token's decimals
     * @param _token The token address
     * @return The token decimals or 0 on failure
     */
    function _safeDecimals(address _token) internal view returns (uint8) {
        (bool success, bytes memory data) = _token.staticcall(abi.encodeWithSignature("decimals()"));

        if (!success || data.length == 0) {
            return 0;
        }

        return abi.decode(data, (uint8));
    }

    /**
     * @notice Helper function to safely get a token's balance
     * @param _token The token address
     * @param _account The account to check balance for
     * @return The account balance or 0 on failure
     */
    function _safeBalanceOf(address _token, address _account) internal view returns (uint256) {
        (bool success, bytes memory data) = _token.staticcall(abi.encodeWithSignature("balanceOf(address)", _account));

        if (!success || data.length == 0) {
            return 0;
        }

        return abi.decode(data, (uint256));
    }

    /**
     * @notice Helper function to convert bytes32 to string
     * @param _bytes32 The bytes32 to convert
     * @return The converted string
     */
    function _bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while (i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
}
