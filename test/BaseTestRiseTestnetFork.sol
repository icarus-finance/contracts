// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

abstract contract BaseTestRiseTestnetFork is Test {
    string internal RISE_TESTNET_RPC_URL = "https://rise-testnet.g.alchemy.com/v2/nVgJ07m4qes-NhJrwjAWGnPwFaixV5E9";

    function setUp() public virtual {
        // fork current block monad testnet
        uint256 riseFork = vm.createFork(RISE_TESTNET_RPC_URL);
        vm.selectFork(riseFork);
        _setUp();
        _testSetup();
    }

    /// @dev Implement this if you want a custom configured deployment
    function _setUp() internal virtual {}

    function _testSetup() internal virtual {}
}
