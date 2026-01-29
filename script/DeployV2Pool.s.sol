// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/StdJson.sol";
import "forge-std/Script.sol";
import {PoolFactory} from "../contracts/factories/PoolFactory.sol";

contract DeployV2Pool is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);

    address public tokenA = vm.envAddress("TOKEN_A");
    address public tokenB = vm.envAddress("TOKEN_B");
    bool public stable = vm.envOr("POOL_STABLE", false);

    address public factoryAddress = vm.envOr("POOL_FACTORY", address(0));
    string public outputFilename = vm.envOr("OUTPUT_FILENAME", string(""));

    address public pool;

    function run() public {
        if (factoryAddress == address(0)) {
            factoryAddress = _loadFactoryFromOutput();
        }

        vm.startBroadcast(deployerAddress);
        pool = PoolFactory(factoryAddress).createPool(tokenA, tokenB, stable);
        vm.stopBroadcast();

        if (bytes(outputFilename).length == 0) {
            return;
        }

        string memory root = vm.projectRoot();
        string memory basePath = string.concat(root, "/script/constants/");
        string memory path = string.concat(basePath, "output/DeployV2Pool-");
        path = string.concat(path, outputFilename);
        vm.writeJson(vm.serializeAddress("v2", "Pool", pool), path);
    }

    function _loadFactoryFromOutput() internal view returns (address) {
        string memory root = vm.projectRoot();
        string memory basePath = string.concat(root, "/script/constants/");
        string memory outputFile = vm.envString("OUTPUT_FILENAME");
        string memory path = string.concat(basePath, "output/DeployCore-");
        path = string.concat(path, outputFile);
        string memory jsonOutput = vm.readFile(path);
        return abi.decode(jsonOutput.parseRaw(".PoolFactory"), (address));
    }
}
