// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {LiquidityLockupHook} from "../src/LiquidityLockupHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

/// @notice The rehearsal deploy script, driven directly with a local manager instead of the environment.
contract DeployTest is Test {
    DeployScript internal script;
    IPoolManager internal manager;

    function setUp() public {
        script = new DeployScript();
        manager = IPoolManager(address(new PoolManager(address(this))));
    }

    function test_minedSaltLandsOnTheDeclaredBits() public {
        (address predicted, bytes32 salt) = script.mineSalt(address(script), manager);
        assertTrue(HookFlags.matches(predicted, LaunchConfig.HOOK_FLAGS));
        assertEq(HookFlags.flagsOf(predicted), 0x0600);

        LiquidityLockupHook hook = script.deployHook(manager, salt, address(script));
        assertEq(address(hook), predicted, "deployed where predicted");
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x0600);
    }

    function test_deployHookRejectsAWrongSalt() public {
        (, bytes32 salt) = script.mineSalt(address(script), manager);
        bytes32 wrong = bytes32(uint256(salt) + 1);
        address predicted = script.computeHookAddress(address(script), manager, wrong);
        vm.assume(!HookFlags.matches(predicted, LaunchConfig.HOOK_FLAGS));
        // The hook constructor itself refuses the address before the script's own check runs.
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        script.deployHook(manager, wrong, address(script));
    }

    function test_runRefusesAnyChainButSepolia() public {
        assertTrue(block.chainid != LaunchConfig.CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(DeployScript.WrongChain.selector, block.chainid));
        script.run();
    }

    function test_constants() public pure {
        assertEq(LaunchConfig.SEPOLIA_POOL_MANAGER, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(LaunchConfig.CHAIN_ID, 11155111);
        assertEq(LaunchConfig.POOL_FEE, 3000);
        assertEq(LaunchConfig.TICK_SPACING, 60);
    }
}
