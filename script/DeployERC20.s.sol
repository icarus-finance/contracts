// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import {Meme} from "../contracts/Meme.sol";

contract DeployERC20 is Script {
    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);

    string public tokenName = vm.envString("TOKEN_NAME");
    string public tokenSymbol = vm.envString("TOKEN_SYMBOL");
    uint256 public tokenSupply = vm.envUint("TOKEN_SUPPLY");
    string public outputFilename = vm.envOr("OUTPUT_FILENAME", string(""));

    Meme public token;

    function run() public {
        vm.startBroadcast(deployerAddress);
        token = new Meme(tokenName, tokenSymbol, tokenSupply);
        vm.stopBroadcast();

        if (bytes(outputFilename).length == 0) {
            return;
        }

        string memory root = vm.projectRoot();
        string memory basePath = string.concat(root, "/script/constants/");
        string memory path = string.concat(basePath, "output/DeployERC20-");
        path = string.concat(path, outputFilename);
        vm.writeJson(vm.serializeAddress("v2", "ERC20", address(token)), path);
    }
}
