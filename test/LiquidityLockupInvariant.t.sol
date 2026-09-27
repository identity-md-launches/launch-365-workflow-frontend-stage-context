// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RealPositionManagerTestBase} from "./utils/RealPositionManagerTestBase.sol";
import {PositionActions} from "./utils/PositionActions.sol";
import {PositionManager} from "./vendor/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "./vendor/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "./vendor/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityLockupHook} from "../src/LiquidityLockupHook.sol";
import {Lockup} from "../src/Lockup.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

/// @dev Ghost state is calculated from successful public actions, never from hook getters.
/// Expected lock failures are inspected byte-for-byte; unexpected results latch `violated`
/// instead of reverting, so Foundry cannot silently discard a failing handler call.
contract LockupPositionHandler is Test {
    PositionManager public immutable posm;
    LiquidityLockupHook public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolDonateTest public immutable donateRouter;
    PoolKey internal key;
    uint256[3] public ids;
    uint256[3] public expectedLiquidity;
    uint256[3] public expectedUnlock;
    bool public violated;
    uint256 public adds;
    uint256 public rejectedRemovals;
    uint256 public successfulRemovals;
    uint256 public collections;
    uint256 public swaps;
    uint256 public donations;

    constructor(PositionManager p, LiquidityLockupHook h, PoolKey memory k, PoolSwapTest s, PoolDonateTest d) {
        posm = p;
        hook = h;
        key = k;
        swapRouter = s;
        donateRouter = d;
        Lockup token = Lockup(Currency.unwrap(k.currency1));
        IAllowanceTransfer permit = p.permit2();
        token.approve(address(permit), type(uint256).max);
        permit.approve(address(token), address(p), type(uint160).max, type(uint48).max);
        token.approve(address(s), type(uint256).max);
        token.approve(address(d), type(uint256).max);
    }

    function initialize() external {
        for (uint256 i; i < 3; ++i) {
            ids[i] = posm.nextTokenId();
            posm.modifyLiquidities{value: 1 ether}(
                PositionActions.mint(key, 138_000, 138_300, 1e18, address(this)), type(uint256).max
            );
            expectedLiquidity[i] = 1e18;
            expectedUnlock[i] = block.timestamp + 30 days;
        }
    }

    function topUp(uint256 position, uint128 rawAmount) external {
        uint256 i = position % 3;
        uint256 amount = bound(rawAmount, 1, 1e18);
        (bool ok,) = _execute(PositionActions.increase(key, ids[i], amount), 1 ether);
        if (!ok) {
            violated = true;
            return;
        }
        expectedLiquidity[i] += amount;
        expectedUnlock[i] = block.timestamp + 30 days;
        ++adds;
    }

    function remove(uint256 position, uint128 rawAmount) public {
        uint256 i = position % 3;
        uint256 liquidity = expectedLiquidity[i];
        if (liquidity == 0) return;
        uint256 amount = bound(rawAmount, 1, liquidity);
        bool shouldReject = block.timestamp < expectedUnlock[i];
        (bool ok, bytes memory reason) = _execute(PositionActions.decrease(key, ids[i], amount), 0);
        if (shouldReject) {
            if (ok || keccak256(reason) != keccak256(_lockedError(expectedUnlock[i]))) violated = true;
            ++rejectedRemovals;
        } else {
            if (!ok) {
                violated = true;
                return;
            }
            expectedLiquidity[i] -= amount;
            ++successfulRemovals;
        }
    }

    function collect(uint256 position) external {
        uint256 i = position % 3;
        // PoolManager rejects a poke of an empty position, independently of the hook.
        if (expectedLiquidity[i] == 0) return;
        (bool ok,) = _execute(PositionActions.decrease(key, ids[i], 0), 0);
        if (!ok) violated = true;
        ++collections;
    }

    function advanceTime(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 45 days));
    }

    function probeBoundary(uint256 position, bool exactlyAtUnlock) external {
        uint256 i = position % 3;
        uint256 timestamp = expectedUnlock[i] - (exactlyAtUnlock ? 0 : 1);
        if (timestamp > block.timestamp) vm.warp(timestamp);
        remove(i, 1);
    }

    function swap(uint96 size, bool zeroForOne) external {
        uint256 amount = zeroForOne ? bound(size, 1, 0.001 ether) : bound(size, 1, 100 ether);
        bytes memory data = abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                SwapParams(
                    zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                bytes("arbitrary hook data")
            )
        );
        (bool ok,) = address(swapRouter).call{value: zeroForOne ? amount : 0}(data);
        if (!ok) violated = true;
        ++swaps;
    }

    function donate(uint96 ethAmount, uint96 tokenAmount) external {
        uint256 amount0 = bound(ethAmount, 0, 0.001 ether);
        uint256 amount1 = bound(tokenAmount, 0, 100 ether);
        (bool ok,) = address(donateRouter).call{value: amount0}(
            abi.encodeCall(PoolDonateTest.donate, (key, amount0, amount1, bytes("")))
        );
        if (!ok) violated = true;
        ++donations;
    }

    /// @dev Called only by the test after each invariant sequence to check eventual withdrawal.
    function finish() external {
        uint256 latest = block.timestamp;
        for (uint256 i; i < 3; ++i) {
            if (expectedUnlock[i] > latest) latest = expectedUnlock[i];
        }
        vm.warp(latest);
        for (uint256 i; i < 3; ++i) {
            if (expectedLiquidity[i] > 0) remove(i, uint128(expectedLiquidity[i]));
        }
    }

    function _execute(bytes memory data, uint256 value) internal returns (bool, bytes memory) {
        return
            address(posm).call{value: value}(
                abi.encodeCall(IPositionManager.modifyLiquidities, (data, type(uint256).max))
            );
    }

    function _lockedError(uint256 until) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(LiquidityLockupHook.StillLocked.selector, until),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    receive() external payable {}
}

contract LiquidityLockupInvariantTest is RealPositionManagerTestBase {
    using TransientStateLibrary for IPoolManager;
    LockupPositionHandler internal handler;

    function setUp() public override {
        super.setUp();
        fund(bob, 10 ether, 0);
        buy(bob, 1 ether); // keep the seed active for swaps/donations even if all NFTs are withdrawn
        handler = new LockupPositionHandler(realPosm, hook, key, swapRouter, donateRouter);
        vm.deal(address(handler), 10_000 ether);
        factory.distribute(address(handler), 10_000_000 ether);
        handler.initialize();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.topUp.selector;
        selectors[1] = handler.remove.selector;
        selectors[2] = handler.collect.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.probeBoundary.selector;
        selectors[5] = handler.swap.selector;
        selectors[6] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_onlySuccessfulAddsChangeDeadlinesAndLockedPrincipalNeverLeaves() public view {
        assertFalse(handler.violated(), "handler saw an unexpected success, revert, or revert payload");
        for (uint256 i; i < 3; ++i) {
            uint256 id = handler.ids(i);
            uint256 until = handler.expectedUnlock(i);
            bytes32 position = realKey(id);
            assertEq(hook.unlockAt(poolId, position), until);
            assertEq(
                hook.positionUnlockAt(poolId, address(realPosm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(id)), until
            );
            assertEq(hook.isLocked(poolId, position), block.timestamp < until);
            assertEq(hook.timeRemaining(poolId, position), block.timestamp < until ? until - block.timestamp : 0);
            assertEq(realLiquidity(id), handler.expectedLiquidity(i), "PoolManager principal differs from ghost model");
            assertEq(realPosm.getPositionLiquidity(id), handler.expectedLiquidity(i));
            assertEq(realPosm.ownerOf(id), address(handler));
        }
        assertEq(hook.unlockAt(poolId, seedKey()), START_TIME + 30 days, "another position changed the seed lock");
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(realPosm).balance, 0, "unrefunded native currency");
        assertEq(token.balanceOf(address(realPosm)), 0);
        assertFalse(IPoolManager(address(manager)).isUnlocked());
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "unsettled PoolManager deltas");
    }

    function afterInvariant() public {
        handler.finish();
        assertFalse(handler.violated(), "a position could not exit at its final deadline");
        for (uint256 i; i < 3; ++i) {
            assertEq(realLiquidity(handler.ids(i)), 0);
        }
    }

    function test_handlerExercisesBothRemovalOutcomesAndAllFinancialActions() public {
        handler.remove(0, 1);
        handler.topUp(0, 1);
        handler.collect(0);
        handler.swap(1e12, true);
        handler.donate(1e12, 1e18);
        handler.probeBoundary(0, false);
        handler.probeBoundary(0, true);
        invariant_onlySuccessfulAddsChangeDeadlinesAndLockedPrincipalNeverLeaves();
        assertEq(handler.rejectedRemovals(), 2);
        assertEq(handler.successfulRemovals(), 1);
        assertEq(handler.adds(), 1);
        assertEq(handler.collections(), 1);
        assertEq(handler.swaps(), 1);
        assertEq(handler.donations(), 1);
        afterInvariant();
    }
}
