// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LockupTestBase} from "./LockupTestBase.sol";
import {PositionActions} from "./PositionActions.sol";
import {PositionManager} from "../vendor/v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "../vendor/permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../vendor/permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "../vendor/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "../vendor/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

abstract contract RealPositionManagerTestBase is LockupTestBase {
    using StateLibrary for IPoolManager;

    PositionManager internal realPosm;
    IAllowanceTransfer internal permit2;

    function setUp() public virtual override {
        super.setUp();
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        realPosm = new PositionManager(manager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
    }

    function fundReal(address who) internal {
        fund(who, 100 ether, 10_000_000 ether);
        vm.startPrank(who);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(realPosm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function mintReal(address who, uint256 liquidity) internal returns (uint256 id) {
        id = realPosm.nextTokenId();
        bytes memory data = PositionActions.mint(key, IN_RANGE_LOWER, IN_RANGE_UPPER, liquidity, who);
        vm.prank(who);
        realPosm.modifyLiquidities{value: 1 ether}(data, type(uint256).max);
    }

    function increaseReal(address who, uint256 id, uint256 liquidity) internal {
        bytes memory data = PositionActions.increase(key, id, liquidity);
        vm.prank(who);
        realPosm.modifyLiquidities{value: 1 ether}(data, type(uint256).max);
    }

    function decreaseReal(address who, uint256 id, uint256 liquidity) internal {
        bytes memory data = PositionActions.decrease(key, id, liquidity);
        vm.prank(who);
        realPosm.modifyLiquidities(data, type(uint256).max);
    }

    function realKey(uint256 id) internal view returns (bytes32) {
        // Independent oracle: packed widths are address(20), int24(3), int24(3), salt(32).
        return keccak256(abi.encodePacked(address(realPosm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(id)));
    }

    function realLiquidity(uint256 id) internal view returns (uint128 liquidity) {
        (liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(poolId, address(realPosm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(id));
    }
}
