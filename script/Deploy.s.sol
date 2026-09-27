// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Lockup} from "../src/Lockup.sol";
import {LiquidityLockupHook} from "../src/LiquidityLockupHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LaunchConfig} from "./LaunchConfig.sol";

/// @title Deploy (rehearsal)
/// @notice Deploys LKUP and LiquidityLockupHook the way the launch expects: the token with no
/// arguments (supply minted to the deployer) and the hook by CREATE2 at an address whose low bits
/// are exactly 0x0600. The live launch goes through the factory and the services stage; this script
/// exists so the same steps can be rehearsed locally and reviewed. It reads no environment
/// variables: every parameter is a constant in `LaunchConfig`.
contract DeployScript is Script {
    /// @dev Forge routes salted `new` through this deterministic deployer when broadcasting.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error WrongChain(uint256 chainId);
    error AddressMismatch(address expected, address actual);
    error NoSaltFound();

    function run() external returns (Lockup token, LiquidityLockupHook hook, bytes32 salt) {
        if (block.chainid != LaunchConfig.CHAIN_ID) revert WrongChain(block.chainid);
        IPoolManager manager = IPoolManager(LaunchConfig.SEPOLIA_POOL_MANAGER);
        (, salt) = mineSalt(CREATE2_DEPLOYER, manager);

        vm.startBroadcast();
        token = new Lockup();
        hook = deployHook(manager, salt, CREATE2_DEPLOYER);
        vm.stopBroadcast();
    }

    /// @notice Deploys the hook at the mined salt and checks the address carries the declared flags.
    /// @param manager The PoolManager the hook serves.
    /// @param salt A salt from `mineSalt` for the same `create2Deployer`.
    /// @param create2Deployer The address executing CREATE2 (the caller of `new` in tests).
    function deployHook(IPoolManager manager, bytes32 salt, address create2Deployer)
        public
        returns (LiquidityLockupHook hook)
    {
        address expected = computeHookAddress(create2Deployer, manager, salt);
        hook = new LiquidityLockupHook{salt: salt}(manager);
        if (address(hook) != expected) revert AddressMismatch(expected, address(hook));
        if (!HookFlags.matches(address(hook), LaunchConfig.HOOK_FLAGS)) {
            revert AddressMismatch(expected, address(hook));
        }
    }

    /// @notice Finds the first salt whose CREATE2 address carries exactly the hook's permission bits.
    function mineSalt(address create2Deployer, IPoolManager manager) public pure returns (address hook, bytes32 salt) {
        bytes32 initCodeHash = hookInitCodeHash(manager);
        for (uint256 i = 0; i < 200_000; i++) {
            hook = _create2Address(create2Deployer, bytes32(i), initCodeHash);
            if (HookFlags.matches(hook, LaunchConfig.HOOK_FLAGS)) return (hook, bytes32(i));
        }
        revert NoSaltFound();
    }

    /// @notice keccak256 of the hook's creation code with its single constructor argument appended.
    function hookInitCodeHash(IPoolManager manager) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(LiquidityLockupHook).creationCode, abi.encode(manager)));
    }

    function computeHookAddress(address create2Deployer, IPoolManager manager, bytes32 salt)
        public
        pure
        returns (address)
    {
        return _create2Address(create2Deployer, salt, hookInitCodeHash(manager));
    }

    function _create2Address(address create2Deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, initCodeHash)))));
    }
}
