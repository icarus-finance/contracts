// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/StdJson.sol";
import "forge-std/Script.sol";
import {LpCandy} from "../contracts/candy/LpCandy.sol";

contract DeployGovernors is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployAddress = vm.rememberKey(deployPrivateKey);
    string public constantsFilename = vm.envString("CONSTANTS_FILENAME");
    string public outputFilename = vm.envString("OUTPUT_FILENAME");
    string public jsonConstants;
    string public jsonOutput;

    constructor() {}

    function run() public {
        vm.startBroadcast(deployAddress);

        address candy = address(
            new LpCandy(
                0x2323420F16058D7191deb6758e09Ae3aa9F780E2,
                0x91bf71bbFe01Bc40579f7060c414a12395d22E8A,
                0x1111111111111111111111111111111111111111,
                0xCC4CDa7B1E2202371915541ddD4F01F4120EEA5c
            )
        );

        vm.stopBroadcast();
    }
}
