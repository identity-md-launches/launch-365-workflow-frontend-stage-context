// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Actions} from "../vendor/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "../vendor/v4-periphery/src/libraries/ActionConstants.sol";

/// @dev Encode the public PositionManager API. CLOSE_CURRENCY pays debts or takes fees;
/// SWEEP refunds unused native currency to the original caller.
library PositionActions {
    function settle(PoolKey memory key, uint256 action, bytes memory operation) internal pure returns (bytes memory) {
        bytes[] memory params = new bytes[](4);
        params[0] = operation;
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        params[3] = abi.encode(key.currency0, ActionConstants.MSG_SENDER);
        return abi.encode(
            abi.encodePacked(
                uint8(action), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.SWEEP)
            ),
            params
        );
    }

    function mint(PoolKey memory key, int24 lower, int24 upper, uint256 liquidity, address owner)
        internal
        pure
        returns (bytes memory)
    {
        return settle(
            key,
            Actions.MINT_POSITION,
            abi.encode(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""))
        );
    }

    function increase(PoolKey memory key, uint256 id, uint256 liquidity) internal pure returns (bytes memory) {
        return settle(
            key, Actions.INCREASE_LIQUIDITY, abi.encode(id, liquidity, type(uint128).max, type(uint128).max, bytes(""))
        );
    }

    function decrease(PoolKey memory key, uint256 id, uint256 liquidity) internal pure returns (bytes memory) {
        return settle(key, Actions.DECREASE_LIQUIDITY, abi.encode(id, liquidity, uint128(0), uint128(0), bytes("")));
    }

    function burn(PoolKey memory key, uint256 id) internal pure returns (bytes memory) {
        return settle(key, Actions.BURN_POSITION, abi.encode(id, uint128(0), uint128(0), bytes("")));
    }
}
