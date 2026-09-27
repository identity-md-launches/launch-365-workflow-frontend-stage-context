// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LockupTestBase} from "./utils/LockupTestBase.sol";
import {MockLaunchFactory} from "./utils/MockLaunchFactory.sol";
import {Lockup} from "../src/Lockup.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";

contract LaunchExtensionsTest is LockupTestBase {
    using StateLibrary for IPoolManager;
    PoolKey internal controlKey;

    function test_samePositionKeyInDifferentPoolsHasIndependentDeadlines() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, LaunchConfig.INITIAL_SQRT_PRICE_X96);
        fund(alice, 10 ether, 100_000 ether);
        bytes32 salt = bytes32(uint256(17));
        bytes32 position = keccak256(abi.encodePacked(address(lpRouter), IN_RANGE_LOWER, IN_RANGE_UPPER, salt));
        modifyViaRouter(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18, salt);
        vm.warp(START_TIME + 10 days);
        ModifyLiquidityParams memory params = ModifyLiquidityParams(IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18, salt);
        vm.prank(alice);
        lpRouter.modifyLiquidity{value: 1 ether}(other, params, abi.encode(alice));
        assertEq(hook.unlockAt(poolId, position), START_TIME + LOCK);
        assertEq(hook.unlockAt(other.toId(), position), START_TIME + 10 days + LOCK);

        vm.warp(START_TIME + LOCK);
        modifyViaRouter(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, -1e18, salt);
        params.liquidityDelta = -1e18;
        vm.prank(alice);
        vm.expectRevert(wrappedStillLocked(START_TIME + 10 days + LOCK));
        lpRouter.modifyLiquidity(other, params, "");
        vm.warp(START_TIME + 10 days + LOCK);
        vm.prank(alice);
        lpRouter.modifyLiquidity(other, params, "");
        (uint128 remaining,,) = IPoolManager(address(manager)).getPositionInfo(other.toId(), position);
        assertEq(remaining, 0);
    }

    function testFuzz_factoryOneSidedSeedSupportsDifferentSizesPricesAndRangeEdges(
        uint96 rawAmount,
        uint16 rawTick,
        uint8 rawGap
    ) public {
        // Valid, well-funded ranges: prices from 1 LKUP/ETH to about 65 million LKUP/ETH.
        // gap == 0 exercises initialization exactly at the seed's upper boundary.
        uint256 amount = bound(rawAmount, 1e6, 900_000_000 ether);
        int24 upper = int24(int256(bound(rawTick, 0, 3000) * 60));
        int24 lower = upper - 600;
        uint160 price = TickMath.getSqrtPriceAtTick(upper + int24(int256(bound(rawGap, 0, 59))));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
        );
        MockLaunchFactory launcher = new MockLaunchFactory(manager);
        (PoolKey memory launched,, BalanceDelta delta) =
            launcher.launch(IHooks(address(hook)), price, lower, upper, liquidity);
        PoolId id = launched.toId();
        bytes32 position = keccak256(abi.encodePacked(address(launcher), lower, upper, bytes32(0)));
        assertEq(delta.amount0(), 0, "factory required ETH");
        assertLt(delta.amount1(), 0);
        assertLe(uint256(uint128(-delta.amount1())), amount);
        assertEq(address(manager).balance, 0, "seeding introduced ETH");
        assertEq(hook.unlockAt(id, position), START_TIME + LOCK);
        (uint128 actual,,) =
            IPoolManager(address(manager)).getPositionInfo(id, address(launcher), lower, upper, bytes32(0));
        assertEq(actual, liquidity);
        assertEq(hook.unlockAt(poolId, seedKey()), START_TIME + LOCK, "new pool changed original seed");

        vm.warp(START_TIME + LOCK - 1);
        vm.expectRevert(wrappedStillLocked(START_TIME + LOCK));
        launcher.unseed(lower, upper, liquidity);
        vm.warp(START_TIME + LOCK);
        launcher.unseed(lower, upper, liquidity);
        (actual,,) = IPoolManager(address(manager)).getPositionInfo(id, address(launcher), lower, upper, bytes32(0));
        assertEq(actual, 0);
        assertEq(hook.unlockAt(id, position), START_TIME + LOCK);
    }

    function testFuzz_swapsAndDonationsMatchAnUnhookedPool(
        bool zeroForOne,
        bool exactOutput,
        uint96 size,
        uint96 donation0,
        uint96 donation1
    ) public {
        _launchControl();
        assertEq(address(manager).balance, 0, "both pools start without ETH");
        vm.warp(START_TIME + 7 days);
        vm.recordLogs();
        _swapPair(true, -1 ether); // first buy crosses the empty interval into one-sided seed
        uint256 amount = zeroForOne
            ? bound(size, 1, exactOutput ? 1_000 ether : 1 ether)
            : bound(size, 1, exactOutput ? 0.001 ether : 1_000 ether);
        _swapPair(zeroForOne, exactOutput ? int256(amount) : -int256(amount));

        uint256 amount0 = bound(donation0, 0, 0.1 ether);
        uint256 amount1 = bound(donation1, 0, 100 ether);
        vm.prank(alice);
        BalanceDelta actual = donateRouter.donate{value: amount0}(key, amount0, amount1, hex"deadbeef");
        vm.prank(bob);
        BalanceDelta control = donateRouter.donate{value: amount0}(controlKey, amount0, amount1, hex"deadbeef");
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(control), "hook altered donation deltas");
        assertEq(actual.amount0(), -int256(amount0));
        assertEq(actual.amount1(), -int256(amount1));
        _assertPoolStateEqual();
        assertEq(hook.unlockAt(poolId, seedKey()), START_TIME + LOCK);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(hook), "swap/donation emitted a hook event");
        }
    }

    function _launchControl() internal {
        MockLaunchFactory controlFactory = new MockLaunchFactory(manager);
        (controlKey,,) = controlFactory.launch(
            IHooks(address(0)),
            LaunchConfig.INITIAL_SQRT_PRICE_X96,
            LaunchConfig.SEED_TICK_LOWER,
            LaunchConfig.SEED_TICK_UPPER,
            seedLiquidity
        );
        Lockup controlToken = controlFactory.token();
        fund(alice, 20 ether, 0);
        vm.deal(bob, 20 ether);
        vm.startPrank(bob);
        controlToken.approve(address(swapRouter), type(uint256).max);
        controlToken.approve(address(donateRouter), type(uint256).max);
        vm.stopPrank();
        assertEq(controlToken.balanceOf(address(manager)), token.balanceOf(address(manager)));
    }

    function _swapPair(bool zeroForOne, int256 amount) internal {
        BalanceDelta actual = swapAs(alice, zeroForOne, amount, alice.balance);
        vm.prank(bob);
        BalanceDelta control = swapRouter.swap{value: zeroForOne ? bob.balance : 0}(
            controlKey,
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(control), "hook altered swap deltas");
        int128 specifiedDelta = amount < 0
            ? (zeroForOne ? actual.amount0() : actual.amount1())
            : (zeroForOne ? actual.amount1() : actual.amount0());
        assertEq(int256(specifiedDelta), amount, "trade only partially filled");
        _assertPoolStateEqual();
    }

    function _assertPoolStateEqual() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 actualPrice, int24 actualTick,,) = pm.getSlot0(poolId);
        (uint160 controlPrice, int24 controlTick,,) = pm.getSlot0(controlKey.toId());
        assertEq(actualPrice, controlPrice);
        assertEq(actualTick, controlTick);
        assertEq(pm.getLiquidity(poolId), pm.getLiquidity(controlKey.toId()));
        (uint256 actualFee0, uint256 actualFee1) = pm.getFeeGrowthGlobals(poolId);
        (uint256 controlFee0, uint256 controlFee1) = pm.getFeeGrowthGlobals(controlKey.toId());
        assertEq(actualFee0, controlFee0);
        assertEq(actualFee1, controlFee1);
    }
}
