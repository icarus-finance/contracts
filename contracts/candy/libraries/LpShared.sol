// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {ILpCandy} from "../interfaces/ILpCandy.sol";
import {IPoolFactory} from "../../interfaces/factories/IPoolFactory.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {IFactoryRegistry} from "../../interfaces/factories/IFactoryRegistry.sol";

/**
 * @title Icarus Finance LP Candy
 * @author Icarus Finance (https://icarus.finance)
 */
library LpShared {
    uint256 internal constant MAX_FACTORIES = 10;
    uint256 internal constant MAX_POOLS = 2000;
    uint256 internal constant MAX_ITERATIONS = 16000;

    IFactoryRegistry internal constant registry =
        IFactoryRegistry(0x91bf71bbFe01Bc40579f7060c414a12395d22E8A);
    IVoter internal constant voter = IVoter(0x2323420F16058D7191deb6758e09Ae3aa9F780E2);
    address internal constant convertor = 0x1111111111111111111111111111111111111111;

    /**
     * @param _limit The max amount of pools to return
     * @param _offset The amount of pools to skip (for optimization)
     * @param _toFind The pool address to find
     * @notice Returns a compiled list of pool and its factory and gauge
     * @return Array of four addresses (factory, pool, gauge, nfpm)
     */
    function pools(uint256 _limit, uint256 _offset, address _toFind) public view returns (ILpCandy.PoolData[] memory) {
        address[] memory factories = registry.poolFactories();
        uint256 factoriesCount = factories.length;

        uint256 toSkip = _offset;

        // Pre-allocate with maximum size, we'll resize later
        ILpCandy.PoolData[] memory poolsData = new ILpCandy.PoolData[](MAX_POOLS);
        uint256 poolCount = 0;

        for (uint256 index = 0; index < MAX_FACTORIES && index < factoriesCount; index++) {
            IPoolFactory factory = IPoolFactory(factories[index]);

            uint256 poolsCount = factory.allPoolsLength();
            address nfpm = factories[index] == 0x5591e3f890725F0f3dbF47B63c81bbb91975483c
                ? 0x425fe0aEAE03E532eDD2524A217016E9D38413C2
                : address(0);

            for (uint256 pindex = 0; pindex < MAX_ITERATIONS && pindex < poolsCount; pindex++) {
                // Check if we've collected enough pools
                if (poolCount >= _limit || poolCount >= MAX_POOLS) {
                    break;
                }

                address poolAddr = factory.allPools(pindex);

                // Skip the convertor pool entirely (doesn't count towards offset or results)
                if (pindex == 0 && poolAddr == convertor) {
                    continue;
                }

                // Skip pools for offset (these count as "seen" but not returned)
                if (toSkip > 0) {
                    toSkip--;
                    continue;
                }

                if (_toFind != address(0) && _toFind != poolAddr) {
                    continue;
                }

                address gaugeAddr = voter.gauges(poolAddr);

                poolsData[poolCount] = ILpCandy.PoolData({factory: address(factory), pool: poolAddr, gauge: gaugeAddr, nfpm: nfpm});
                poolCount++;

                if (_toFind != address(0) && _toFind == poolAddr) {
                    break;
                }
            }

            // Break outer loop if we've collected enough pools
            if (poolCount >= _limit || poolCount >= MAX_POOLS) {
                break;
            }
        }

        // If limit is reached just return the array
        if (poolCount == _limit) {
            return poolsData;
        }

        // Resize the array to the actual number of pools found
        ILpCandy.PoolData[] memory result = new ILpCandy.PoolData[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            result[i] = poolsData[i];
        }

        return result;
    }
}