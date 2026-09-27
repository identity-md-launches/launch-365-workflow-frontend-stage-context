// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Lockup} from "../src/Lockup.sol";

/// @notice The LKUP token: fixed supply minted to the deployer, plain ERC-20 semantics, nothing else.
contract LockupTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    Lockup internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new Lockup();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Lockup");
        assertEq(token.symbol(), "LKUP");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_mintsWholeSupplyToDeployerOnce() public {
        assertEq(token.balanceOf(deployer), SUPPLY);

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        Lockup another = new Lockup();
        assertEq(another.balanceOf(alice), SUPPLY);
        assertEq(another.totalSupply(), SUPPLY);
    }

    function test_transfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 1e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1e18));
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Lockup.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Lockup.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 5e18);
        assertTrue(token.approve(alice, 5e18));
        assertEq(token.allowance(deployer, alice), 5e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 2e18));
        assertEq(token.balanceOf(bob), 2e18);
        assertEq(token.allowance(deployer, alice), 3e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Lockup.ERC20InsufficientAllowance.selector, alice, 3e18, 4e18));
        token.transferFrom(deployer, bob, 4e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Lockup.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_noAdminOrMintPath() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(alice);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
    }

    function testFuzz_transferConservesSupply(uint256 amount, address to) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
