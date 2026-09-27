// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Mines a CREATE2 salt that places a hook on an address carrying exactly `flags`.
/// @dev Same procedure as v4-periphery's HookMiner and as the launch floor's `deployAtFlags`.
library HookMiner {
    uint256 internal constant MAX_LOOP = 200_000;

    error NoSaltFound();

    /// @param deployer The address that will execute CREATE2 (the test contract, a factory, or the
    /// deterministic deployer proxy when broadcasting).
    /// @param flags The permission bits the address must carry.
    /// @param creationCode The hook's creation code.
    /// @param constructorArgs ABI-encoded constructor arguments.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            hookAddress = computeAddress(deployer, bytes32(i), initCodeHash);
            if (HookFlags.matches(hookAddress, flags) && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert NoSaltFound();
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
