// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract IRSTest is BaseTest {
    IRS token;

    function _setUp() public override {
        token = new IRS();
    }

    function testMetadata() public view {
        assertEq(token.name(), "Icarus");
        assertEq(token.symbol(), "IRS");
        assertEq(token.decimals(), 18);
    }

    function testAuthorizedMintUpdatesSupplyAndBalance() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(owner2));
        assertTrue(token.mint(address(owner2), TOKEN_1));
        assertEq(token.totalSupply(), supplyBefore + TOKEN_1);
        assertEq(token.balanceOf(address(owner2)), balanceBefore + TOKEN_1);
    }

    function testPermitDomainUnchanged() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Icarus")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function testCannotSetMinterIfNotMinter() public {
        vm.prank(address(owner2));
        vm.expectRevert(IIRS.NotMinter.selector);
        token.setMinter(address(owner3));
    }

    function testSetMinter() public {
        token.setMinter(address(owner3));

        assertEq(token.minter(), address(owner3));
    }

    function testCannotMintIfNotMinter() public {
        vm.prank(address(owner2));
        vm.expectRevert(IIRS.NotMinter.selector);
        token.mint(address(owner2), TOKEN_1);
    }
}
