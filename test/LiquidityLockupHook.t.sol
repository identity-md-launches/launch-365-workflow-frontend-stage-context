// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LockupTestBase} from "./utils/LockupTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LiquidityLockupHook} from "../src/LiquidityLockupHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

/// @notice The lock itself: permissions, position keys, the 30-day window, top-ups, fee collection,
/// independent PositionManager NFTs, the shared-router limit, non-ETH pools and caller checks.
contract LiquidityLockupHookTest is LockupTestBase {
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // ───────────────────────────── permissions and construction ─────────────────────────────

    function test_permissionsAreExactlyAfterAddAndBeforeRemove() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertTrue(p.afterAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);

        assertEq(HookFlags.flagsOf(address(hook)), 0x0600, "address bits");
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.LOCK_DURATION(), 30 days);
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        // A plain CREATE lands on an address that (deterministically, here) does not carry 0x0600.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.assume(!HookFlags.matches(predicted, LaunchConfig.HOOK_FLAGS));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new LiquidityLockupHook(manager);
    }

    function test_constructorAcceptsOnlyTheExactBits() public {
        // Extra bits are refused too: the address must carry exactly the declared permissions.
        (address extra, bytes32 salt) = _findSalt(0x0600 | HookFlags.BEFORE_SWAP);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, extra));
        new LiquidityLockupHook{salt: salt}(manager);
    }

    // ───────────────────────────── position keys and views ─────────────────────────────

    function test_positionKeyMatchesThePoolManagers() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);

        bytes32 expected = keccak256(abi.encodePacked(address(posm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(tokenId)));
        bytes32 viaHook = hook.positionKey(address(posm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(tokenId));
        assertEq(viaHook, expected, "hook key is keccak256(owner, tickLower, tickUpper, salt)");
        assertEq(
            viaHook, Position.calculatePositionKey(address(posm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(tokenId))
        );

        // The PoolManager finds the same position under that key.
        (uint128 byKey,,) = IPoolManager(address(manager)).getPositionInfo(poolId, viaHook);
        (uint128 byParts,,) = IPoolManager(address(manager))
            .getPositionInfo(poolId, address(posm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(tokenId));
        assertEq(byKey, 1e18);
        assertEq(byParts, 1e18);

        assertEq(hook.unlockAt(poolId, viaHook), block.timestamp + LOCK);
        assertEq(
            hook.positionUnlockAt(poolId, address(posm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(tokenId)),
            block.timestamp + LOCK
        );
        assertTrue(hook.isLocked(poolId, viaHook));
        assertEq(hook.timeRemaining(poolId, viaHook), LOCK);

        vm.warp(block.timestamp + LOCK - 1);
        assertTrue(hook.isLocked(poolId, viaHook));
        assertEq(hook.timeRemaining(poolId, viaHook), 1);

        vm.warp(block.timestamp + 1);
        assertFalse(hook.isLocked(poolId, viaHook));
        assertEq(hook.timeRemaining(poolId, viaHook), 0);
    }

    function test_unknownPositionIsNotLocked() public view {
        bytes32 never = hook.positionKey(alice, -60, 60, bytes32(uint256(42)));
        assertEq(hook.unlockAt(poolId, never), 0);
        assertFalse(hook.isLocked(poolId, never));
        assertEq(hook.timeRemaining(poolId, never), 0);
    }

    // ───────────────────────────── the 30-day window ─────────────────────────────

    function test_addLocksAndEmits() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 t0 = block.timestamp;
        bytes32 expectedKey = posmKey(1, IN_RANGE_LOWER, IN_RANGE_UPPER);

        vm.expectEmit(true, true, true, true, address(hook));
        emit Locked(
            poolId, expectedKey, address(posm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(uint256(1)), 1e18, t0 + LOCK
        );
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        assertEq(tokenId, 1);
        assertEq(hook.unlockAt(poolId, expectedKey), t0 + LOCK);
    }

    function test_removeRevertsAtUnlockMinusOneSecond() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        uint256 unlock = block.timestamp + LOCK;

        vm.warp(unlock - 1);
        vm.prank(alice);
        vm.expectRevert(wrappedStillLocked(unlock));
        posm.decrease(tokenId, 1);
    }

    function test_removePassesAtExactlyUnlockAt() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        uint256 unlock = block.timestamp + LOCK;

        vm.warp(unlock);
        vm.prank(alice);
        BalanceDelta delta = posm.decrease(tokenId, 0.4e18);
        assertTrue(delta.amount0() > 0 || delta.amount1() > 0, "got funds back");
        assertEq(posm.liquidityOf(tokenId), 0.6e18);

        // Removing does not touch unlockAt, and the rest can go whenever.
        assertEq(hook.unlockAt(poolId, posmKey(tokenId, IN_RANGE_LOWER, IN_RANGE_UPPER)), unlock);
        vm.warp(unlock + 365 days);
        vm.prank(alice);
        posm.burn(tokenId);
        assertEq(posm.liquidityOf(tokenId), 0);
        assertEq(posm.ownerOf(tokenId), address(0));
    }

    function test_removeImmediatelyReverts() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(wrappedStillLocked(block.timestamp + LOCK));
        posm.decrease(tokenId, 1e18);
        vm.expectRevert(wrappedStillLocked(block.timestamp + LOCK));
        posm.burn(tokenId);
        vm.stopPrank();
    }

    function testFuzz_removalBlockedExactlyUntilUnlockAt(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 90 days);
        fund(alice, 10 ether, 100_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        uint256 unlock = block.timestamp + LOCK;

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        if (elapsed < LOCK) {
            vm.expectRevert(wrappedStillLocked(unlock));
            posm.decrease(tokenId, 1e18);
        } else {
            posm.decrease(tokenId, 1e18);
            assertEq(posm.liquidityOf(tokenId), 0);
        }
    }

    function testFuzz_anyAddSizeLocks(uint128 liquidity) public {
        liquidity = uint128(bound(liquidity, 1, 1e24));
        fund(alice, 100 ether, 100_000_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, liquidity);
        assertEq(posm.liquidityOf(tokenId), liquidity);
        assertEq(hook.unlockAt(poolId, posmKey(tokenId, IN_RANGE_LOWER, IN_RANGE_UPPER)), block.timestamp + LOCK);
    }

    function test_topUpRestartsTheFullWindow() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 t0 = block.timestamp;
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        bytes32 k = posmKey(tokenId, IN_RANGE_LOWER, IN_RANGE_UPPER);
        assertEq(hook.unlockAt(poolId, k), t0 + LOCK);

        vm.warp(t0 + 20 days);
        vm.prank(alice);
        posm.increase{value: alice.balance}(tokenId, 1);
        assertEq(hook.unlockAt(poolId, k), t0 + 50 days, "top-up restarted the lock");

        vm.warp(t0 + LOCK);
        vm.prank(alice);
        vm.expectRevert(wrappedStillLocked(t0 + 50 days));
        posm.decrease(tokenId, 1e18);

        vm.warp(t0 + 50 days);
        vm.prank(alice);
        posm.decrease(tokenId, 1e18 + 1);
        assertEq(posm.liquidityOf(tokenId), 0);
    }

    function test_nothingButAnAddChangesTheLock() public {
        fund(alice, 10 ether, 100_000e18);
        fund(bob, 10 ether, 0);
        uint256 t0 = block.timestamp;
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        bytes32 k = posmKey(tokenId, IN_RANGE_LOWER, IN_RANGE_UPPER);

        vm.warp(t0 + 5 days);
        buy(bob, 1 ether);
        sell(bob, 1_000e18);
        vm.prank(bob);
        donateRouter.donate{value: 0.1 ether}(key, 0.1 ether, 0, "");
        vm.prank(alice);
        posm.collect(tokenId);
        assertEq(hook.unlockAt(poolId, k), t0 + LOCK, "swaps, donations and collects leave the lock alone");
    }

    // ───────────────────────────── fee collection (liquidityDelta == 0) ─────────────────────────────

    function test_feeCollectionWorksWhileLocked() public {
        fund(alice, 10 ether, 100_000e18);
        fund(bob, 10 ether, 0);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e21);

        buy(bob, 1 ether); // ETH fees accrue to in-range LPs
        assertTrue(hook.isLocked(poolId, posmKey(tokenId, IN_RANGE_LOWER, IN_RANGE_UPPER)));

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        BalanceDelta fees = posm.collect(tokenId);
        assertGt(fees.amount0(), 0, "collected ETH fees");
        assertGe(fees.amount1(), 0);
        assertEq(alice.balance - ethBefore, uint256(uint128(fees.amount0())), "fees delivered");
        assertEq(posm.liquidityOf(tokenId), 1e21, "liquidity untouched");
    }

    function test_zeroDeltaThroughSharedRouterWhileLocked() public {
        fund(alice, 10 ether, 100_000e18);
        fund(bob, 10 ether, 0);
        modifyViaRouter(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e21, bytes32(0));
        buy(bob, 1 ether);

        BalanceDelta fees = modifyViaRouter(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 0, bytes32(0));
        assertGt(fees.amount0(), 0, "collected ETH fees through the shared router");
    }

    // ───────────────────────────── PositionManager NFTs ─────────────────────────────

    function test_twoNftsOnTheSameRangeLockIndependently() public {
        fund(alice, 10 ether, 100_000e18);
        fund(bob, 10 ether, 100_000e18);
        uint256 t0 = block.timestamp;

        uint256 nft1 = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        vm.warp(t0 + 10 days);
        uint256 nft2 = mintViaPosm(bob, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);

        bytes32 k1 = posmKey(nft1, IN_RANGE_LOWER, IN_RANGE_UPPER);
        bytes32 k2 = posmKey(nft2, IN_RANGE_LOWER, IN_RANGE_UPPER);
        assertTrue(k1 != k2, "different salts, different keys");
        assertEq(hook.unlockAt(poolId, k1), t0 + LOCK, "bob's add did not restart alice's lock");
        assertEq(hook.unlockAt(poolId, k2), t0 + 10 days + LOCK);

        vm.warp(t0 + LOCK);
        vm.prank(alice);
        posm.decrease(nft1, 1e18);

        vm.prank(bob);
        vm.expectRevert(wrappedStillLocked(t0 + 10 days + LOCK));
        posm.decrease(nft2, 1e18);

        vm.warp(t0 + 10 days + LOCK);
        vm.prank(bob);
        posm.burn(nft2);
    }

    function test_sameOwnerTwoNftsSameRange() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 t0 = block.timestamp;
        uint256 nft1 = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        vm.warp(t0 + 1 days);
        uint256 nft2 = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        assertEq(hook.unlockAt(poolId, posmKey(nft1, IN_RANGE_LOWER, IN_RANGE_UPPER)), t0 + LOCK);
        assertEq(hook.unlockAt(poolId, posmKey(nft2, IN_RANGE_LOWER, IN_RANGE_UPPER)), t0 + 1 days + LOCK);
    }

    // ───────────────────────────── the shared-router limit ─────────────────────────────

    function test_sharedRouterKeyIsRestartedByAnyoneAddingToIt() public {
        // Documented limit: on PoolModifyLiquidityTest the sender is the router, so (router, range, salt)
        // is one key for everybody. Bob's add restarts the lock on alice's liquidity.
        fund(alice, 10 ether, 100_000e18);
        fund(bob, 10 ether, 100_000e18);
        uint256 t0 = block.timestamp;
        bytes32 k = routerKey(IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(0));

        modifyViaRouter(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18, bytes32(0));
        assertEq(hook.unlockAt(poolId, k), t0 + LOCK);

        vm.warp(t0 + 10 days);
        modifyViaRouter(bob, IN_RANGE_LOWER, IN_RANGE_UPPER, 1, bytes32(0));
        assertEq(hook.unlockAt(poolId, k), t0 + 10 days + LOCK, "bob restarted the shared key");

        vm.warp(t0 + LOCK);
        vm.prank(alice);
        vm.expectRevert(wrappedStillLocked(t0 + 10 days + LOCK));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: IN_RANGE_LOWER, tickUpper: IN_RANGE_UPPER, liquidityDelta: -1e18, salt: bytes32(0)
            }),
            ""
        );

        // A distinct salt on the same router is a distinct key and is not affected.
        modifyViaRouter(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18, bytes32(uint256(7)));
        assertEq(
            hook.unlockAt(poolId, routerKey(IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(uint256(7)))), t0 + LOCK + LOCK
        );
    }

    // ───────────────────────────── pools whose currency0 is not ETH ─────────────────────────────

    function test_nonEthPoolIsNeverLocked() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000e18);
        MockERC20 b = new MockERC20("B", "B", 1_000_000e18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(erc20Key, SQRT_PRICE_1_1);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);

        vm.recordLogs();
        ModifyLiquidityParams memory add =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        lpRouter.modifyLiquidity(erc20Key, add, "");

        bytes32 k = routerKey(-60, 60, bytes32(0));
        assertEq(hook.unlockAt(erc20Key.toId(), k), 0, "no lock on a non-ETH pool");
        assertFalse(hook.isLocked(erc20Key.toId(), k));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(hook), "hook emitted nothing");
        }

        // A swap works, and liquidity can be removed at once.
        swapRouter.swap(
            erc20Key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: SQRT_PRICE_1_1 / 2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        add.liquidityDelta = -1e18;
        lpRouter.modifyLiquidity(erc20Key, add, "");
    }

    // ───────────────────────────── caller checks ─────────────────────────────

    function test_everyCallbackRefusesCallersOtherThanThePoolManager() public {
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 1});
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes4 err = LiquidityLockupHook.NotPoolManager.selector;

        vm.expectRevert(err);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(err);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(err);
        hook.beforeAddLiquidity(address(this), key, mp, "");
        vm.expectRevert(err);
        hook.afterAddLiquidity(address(this), key, mp, zero, zero, "");
        vm.expectRevert(err);
        hook.beforeRemoveLiquidity(address(this), key, mp, "");
        vm.expectRevert(err);
        hook.afterRemoveLiquidity(address(this), key, mp, zero, zero, "");
        vm.expectRevert(err);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(err);
        hook.afterSwap(address(this), key, sp, zero, "");
        vm.expectRevert(err);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(err);
        hook.afterDonate(address(this), key, 1, 1, "");

        // Nothing changed: a direct afterAddLiquidity from a stranger did not create a lock.
        assertEq(hook.unlockAt(poolId, hook.positionKey(address(this), -60, 60, bytes32(0))), 0);
    }

    function test_directAfterAddCannotLockSomeoneElsesPositionEvenFromTheManager() public {
        // Only the PoolManager can reach the callback, and the manager only ever passes the real
        // msg.sender of modifyLiquidity. Called as the manager, the key is derived from `sender`,
        // never from anything a stranger controls through hookData.
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        vm.prank(address(manager));
        hook.afterAddLiquidity(alice, key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), abi.encode(bob));
        assertEq(hook.unlockAt(poolId, hook.positionKey(alice, -60, 60, bytes32(0))), block.timestamp + LOCK);
        assertEq(hook.unlockAt(poolId, hook.positionKey(bob, -60, 60, bytes32(0))), 0);
    }

    function test_disabledCallbacksRevertEvenForTheManager() public {
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 1});
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes4 err = LiquidityLockupHook.HookNotImplemented.selector;

        vm.startPrank(address(manager));
        vm.expectRevert(err);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(err);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(err);
        hook.beforeAddLiquidity(address(this), key, mp, "");
        vm.expectRevert(err);
        hook.afterRemoveLiquidity(address(this), key, mp, zero, zero, "");
        vm.expectRevert(err);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(err);
        hook.afterSwap(address(this), key, sp, zero, "");
        vm.expectRevert(err);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(err);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    function test_beforeRemoveWithZeroDeltaAlwaysPasses() public {
        fund(alice, 10 ether, 100_000e18);
        uint256 tokenId = mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        ModifyLiquidityParams memory mp = ModifyLiquidityParams({
            tickLower: IN_RANGE_LOWER, tickUpper: IN_RANGE_UPPER, liquidityDelta: 0, salt: bytes32(tokenId)
        });
        vm.prank(address(manager));
        bytes4 sel = hook.beforeRemoveLiquidity(address(posm), key, mp, "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);

        mp.liquidityDelta = -1;
        vm.prank(address(manager));
        // Called directly (as the manager does), the raw error is visible; through the manager it is wrapped.
        vm.expectRevert(abi.encodeWithSelector(LiquidityLockupHook.StillLocked.selector, block.timestamp + LOCK));
        hook.beforeRemoveLiquidity(address(posm), key, mp, "");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _findSalt(uint160 flags) internal view returns (address predicted, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(LiquidityLockupHook).creationCode, abi.encode(manager)));
        for (uint256 i = 0; i < 200_000; i++) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return (predicted, bytes32(i));
        }
        revert("no salt");
    }
}
