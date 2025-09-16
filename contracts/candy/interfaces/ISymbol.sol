// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ISymbol {
    function symbol() external view returns (string memory);
}