// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/StdJson.sol";
import "../test/Base.sol";

/// @notice Deploy script to deploy new pools and gauges
contract DeployGaugesAndPools is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);
    string public constantsFilename = vm.envString("CONSTANTS_FILENAME");
    string public outputFilename = vm.envString("OUTPUT_FILENAME");
    string public jsonConstants;
    string public jsonOutput;

    PoolFactory public factory;
    Voter public voter;
    address public irs;

    struct PoolNonIrs {
        bool stable;
        address tokenA;
        address tokenB;
    }

    struct PoolIrs {
        bool stable;
        address token;
    }

    address[] pools;
    // address[] gauges;

    constructor() {}

    function run() public {
        string memory root = vm.projectRoot();
        string memory basePath = string.concat(root, "/script/constants/");
        string memory path = string.concat(basePath, constantsFilename);

        // load in vars
        jsonConstants = vm.readFile(path);
        PoolNonIrs[] memory _pools = abi.decode(jsonConstants.parseRaw(".pools"), (PoolNonIrs[]));
        // PoolIrs[] memory poolsIrs = abi.decode(jsonConstants.parseRaw(".poolsIrs"), (PoolIrs[]));

        path = string.concat(basePath, "output/DeployCore-");
        path = string.concat(path, outputFilename);
        jsonOutput = vm.readFile(path);
        factory = PoolFactory(abi.decode(jsonOutput.parseRaw(".PoolFactory"), (address)));
        // voter = Voter(abi.decode(jsonOutput.parseRaw(".Voter"), (address)));
        irs = abi.decode(jsonOutput.parseRaw(".IRS"), (address));

        vm.startBroadcast(deployerAddress);

        // Deploy all non-IRS pools & gauges
        for (uint256 i = 0; i < _pools.length; i++) {
            address newPool = factory.createPool(_pools[i].tokenA, _pools[i].tokenB, _pools[i].stable);
            // address newGauge = voter.createGauge(address(factory), newPool);

            pools.push(newPool);
            // gauges.push(newGauge);
        }

        // Deploy all IRS pools & gauges
        // for (uint256 i = 0; i < poolsIrs.length; i++) {
            // address newPool = factory.createPool(irs, poolsIrs[i].token, poolsIrs[i].stable);
            // address newGauge = voter.createGauge(address(factory), newPool);

            // pools.push(newPool);
            // gauges.push(newGauge);
        // }

        vm.stopBroadcast();

        // Write to file
        path = string.concat(basePath, "output/DeployGaugesAndPools-");
        path = string.concat(path, outputFilename);
        // vm.writeJson(vm.serializeAddress("v2", "gaugesPools", gauges), path);
        vm.writeJson(vm.serializeAddress("v2", "pools", pools), path);
    }
}
