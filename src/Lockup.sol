// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Lockup (LKUP)
/// @notice Fixed-supply ERC-20 launch token. The whole supply of 1,000,000,000 LKUP (18 decimals) is
/// minted once, to the deployer, in the constructor. There is no owner, no admin, no mint, no burn,
/// no pause and no upgrade path: after deployment the contract has no privileged function at all.
/// @dev Self-contained implementation (no external base contract) so the published source is the
/// entire behaviour. Custom error names follow the OpenZeppelin ERC-20 conventions.
contract Lockup {
    string public constant name = "Lockup";
    string public constant symbol = "LKUP";
    uint8 public constant decimals = 18;

    /// @notice Total supply, fixed at deployment and never changed.
    uint256 public constant totalSupply = 1_000_000_000e18;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);

    /// @dev Mints the entire supply to `msg.sender`, which at launch is the factory.
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev An allowance of `type(uint256).max` is treated as infinite and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert ERC20InsufficientAllowance(msg.sender, allowed, amount);
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert ERC20InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // The supply is fixed at 1e27, so no balance can overflow a uint256.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
