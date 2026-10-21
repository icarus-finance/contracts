// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/StdJson.sol";
import "../test/Base.sol";
import {LpCandy} from "../contracts/candy/LpCandy.sol";
import {RewardsCandy} from "../contracts/candy/RewardsCandy.sol";
import {FactoryRegistry} from "../contracts/factories/FactoryRegistry.sol";
import {RewardsDistributor} from "../contracts/RewardsDistributor.sol";
import {ISlipstreamHelper} from "../contracts/candy/interfaces/ISlipstreamHelper.sol";
import {VeCandy} from "../contracts/candy/VeCandy.sol";

/// @notice Deploy script to deploy new pools and gauges
contract DeployCandy is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);
    string public constantsFilename = vm.envString("CONSTANTS_FILENAME");
    string public outputFilename = vm.envString("OUTPUT_FILENAME");
    string public jsonConstants;
    string public jsonOutput;

    Voter public voter;
    FactoryRegistry public factoryRegistry;
    ISlipstreamHelper public slipstreamHelper;
    RewardsDistributor public distributor;
    address public convertor = 0x1111111111111111111111111111111111111111;

    LpCandy public candy;
    RewardsCandy public rewards;
    VeCandy public ve;

    constructor() {}

    function run() public {
        string memory root = vm.projectRoot();
        string memory basePath = string.concat(root, "/script/constants/");
        string memory path = string.concat(basePath, constantsFilename);

        path = string.concat(basePath, "output/DeployCore-");
        path = string.concat(path, outputFilename);
        jsonOutput = vm.readFile(path);
        voter = Voter(abi.decode(jsonOutput.parseRaw(".Voter"), (address)));
        factoryRegistry = FactoryRegistry(abi.decode(jsonOutput.parseRaw(".FactoryRegistry"), (address)));
        distributor = RewardsDistributor(abi.decode(jsonOutput.parseRaw(".Distributor"), (address)));
        slipstreamHelper = ISlipstreamHelper(abi.decode(jsonOutput.parseRaw(".SugarHelper"), (address)));

        vm.startBroadcast(deployerAddress);

        candy = new LpCandy(address(voter), address(factoryRegistry), address(convertor), address(slipstreamHelper));

        // rewards = new RewardsCandy(
        //     address(voter),
        //     address(factoryRegistry),
        //     address(convertor)
        // );

        // ve = new VeCandy(
        //     address(voter),
        //     address(distributor),
        //     address(0));

        vm.stopBroadcast();

        // Write to file
        path = string.concat(basePath, "output/DeployCandy-");
        path = string.concat(path, outputFilename);
        vm.writeJson(vm.serializeAddress("v2", "LpCandy", address(candy)), path);
        vm.writeJson(vm.serializeAddress("v2", "RewardsCandy", address(rewards)), path);
        vm.writeJson(vm.serializeAddress("v2", "VeCandy", address(ve)), path);
    }
}
