// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Plain ERC-20 test token that mints `supply` to its deployer. Used for pools whose
/// currency0 is not native ETH and by the launch floor.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, supply);
    }
}
