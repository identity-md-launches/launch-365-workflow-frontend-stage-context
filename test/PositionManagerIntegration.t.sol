// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealPositionManagerTestBase} from "./utils/RealPositionManagerTestBase.sol";
import {PositionActions} from "./utils/PositionActions.sol";
import {IPositionManager} from "./vendor/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "./vendor/v4-periphery/src/libraries/Actions.sol";
import {SlippageCheck} from "./vendor/v4-periphery/src/libraries/SlippageCheck.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice All liquidity operations here use the upstream PositionManager, including
/// its ERC721 authorization, action decoding, multicall, Permit2, and settlement.
contract PositionManagerIntegrationTest is RealPositionManagerTestBase {
    function test_realMintEventUsesPositionManagerAsOwnerAndNftIdAsSalt() public {
        fundReal(alice);
        uint256 id = realPosm.nextTokenId();
        vm.expectEmit(true, true, true, true, address(hook));
        emit Locked(
            poolId, realKey(id), address(realPosm), IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(id), 1e18, START_TIME + LOCK
        );
        assertEq(mintReal(alice, 1e18), id);
        assertEq(realPosm.ownerOf(id), alice);
        assertEq(realLiquidity(id), 1e18);
        bytes32 walletKey = keccak256(abi.encodePacked(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, bytes32(id)));
        assertEq(hook.unlockAt(poolId, walletKey), 0, "wallet was mistaken for PoolManager's position owner");
    }

    function testFuzz_realDecreaseRejectsOneSecondEarlyAndPassesExactlyAtUnlock(uint128 size, uint128 removal) public {
        uint256 liquidity = bound(size, 1, 1e20);
        uint256 amount = bound(removal, 1, liquidity);
        fundReal(alice);
        uint256 id = mintReal(alice, liquidity);
        uint256 until = START_TIME + 30 days;
        assertEq(hook.unlockAt(poolId, realKey(id)), until);

        vm.warp(until - 1);
        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);
        _expectLocked(alice, PositionActions.decrease(key, id, amount), until);
        assertEq(realLiquidity(id), liquidity, "rejected decrease changed principal");
        assertEq(realPosm.ownerOf(id), alice);
        assertEq(alice.balance, ethBefore);
        assertEq(token.balanceOf(alice), tokenBefore);
        assertEq(hook.timeRemaining(poolId, realKey(id)), 1);

        vm.warp(until);
        decreaseReal(alice, id, amount);
        assertEq(realLiquidity(id), liquidity - amount);
        assertEq(hook.unlockAt(poolId, realKey(id)), until, "decrease changed the deadline");
        assertFalse(hook.isLocked(poolId, realKey(id)));
        assertEq(hook.timeRemaining(poolId, realKey(id)), 0);
    }

    function test_realBurnRevertsBeforeUnlockAndRollsBackNftDeletion() public {
        fundReal(alice);
        uint256 id = mintReal(alice, 1e18);
        bytes memory data = PositionActions.burn(key, id);
        vm.warp(START_TIME + LOCK - 1);
        _expectLocked(alice, data, START_TIME + LOCK);
        assertEq(realPosm.ownerOf(id), alice, "failed burn destroyed the NFT");
        assertEq(realLiquidity(id), 1e18);

        vm.warp(START_TIME + LOCK);
        vm.prank(alice);
        realPosm.modifyLiquidities(data, type(uint256).max);
        assertEq(realLiquidity(id), 0);
        vm.expectRevert("NOT_MINTED");
        realPosm.ownerOf(id);
    }

    function testFuzz_topUpRelocksOnlyItsOwnNft(uint128 size, uint32 delay) public {
        uint256 topUp = bound(size, 1, 1e20);
        uint256 elapsed = bound(delay, 1, 60 days);
        fundReal(alice);
        fundReal(bob);
        uint256 first = mintReal(alice, 1e18);
        uint256 second = mintReal(bob, 1e18);
        vm.warp(START_TIME + elapsed);
        increaseReal(alice, first, topUp);
        uint256 restarted = START_TIME + elapsed + LOCK;

        assertEq(hook.unlockAt(poolId, realKey(first)), restarted);
        assertEq(hook.unlockAt(poolId, realKey(second)), START_TIME + LOCK);
        assertEq(realLiquidity(first), 1e18 + topUp);
        // Both NFTs use exactly the same owner in PoolManager and the same ticks.
        // At this point only their salts can distinguish their lock schedules.
        vm.warp(restarted - 1);
        _expectLocked(alice, PositionActions.decrease(key, first, 1), restarted);
        decreaseReal(bob, second, 1e18);
        assertEq(realLiquidity(second), 0);
        assertEq(realLiquidity(first), 1e18 + topUp);

        vm.warp(restarted);
        decreaseReal(alice, first, 1e18 + topUp);
        assertEq(realLiquidity(first), 0);
    }

    function test_twoNftsOwnedBySameWalletHaveIndependentDeadlines() public {
        fundReal(alice);
        uint256 first = mintReal(alice, 1e18);
        vm.warp(START_TIME + 10 days);
        uint256 second = mintReal(alice, 1e18);
        assertTrue(realKey(first) != realKey(second));
        vm.warp(START_TIME + LOCK);
        decreaseReal(alice, first, 1e18);
        _expectLocked(alice, PositionActions.burn(key, second), START_TIME + 10 days + LOCK);
        assertEq(realLiquidity(second), 1e18);
    }

    function test_realFeeCollectionPaysBothCurrenciesWithoutExtendingLock() public {
        fundReal(alice);
        fundReal(bob);
        uint256 id = mintReal(alice, 1e18);
        _donateToActivePosition();
        vm.warp(START_TIME + 1 days);
        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);
        vm.recordLogs();
        decreaseReal(alice, id, 0);
        assertGt(alice.balance, ethBefore, "delta-zero collection delivered no ETH fees");
        assertGt(token.balanceOf(alice), tokenBefore, "delta-zero collection delivered no LKUP fees");
        assertEq(realLiquidity(id), 1e18, "fee collection removed principal");
        assertEq(hook.unlockAt(poolId, realKey(id)), START_TIME + LOCK);
        assertTrue(hook.isLocked(poolId, realKey(id)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(hook));
        }

        ethBefore = alice.balance;
        tokenBefore = token.balanceOf(alice);
        decreaseReal(alice, id, 0);
        assertEq(alice.balance, ethBefore, "same fees collected twice");
        assertEq(token.balanceOf(alice), tokenBefore);
        _expectLocked(alice, PositionActions.decrease(key, id, 1), START_TIME + LOCK);
    }

    function test_multicallCannotCollectThenBypassLockAndRevertsAtomically() public {
        fundReal(alice);
        fundReal(bob);
        uint256 id = mintReal(alice, 1e18);
        _donateToActivePosition();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            IPositionManager.modifyLiquidities, (PositionActions.decrease(key, id, 0), type(uint256).max)
        );
        calls[1] =
            abi.encodeCall(IPositionManager.modifyLiquidities, (PositionActions.burn(key, id), type(uint256).max));
        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(wrappedStillLocked(START_TIME + LOCK));
        realPosm.multicall(calls);
        assertEq(alice.balance, ethBefore, "earlier collection escaped multicall rollback");
        assertEq(token.balanceOf(alice), tokenBefore);
        assertEq(realPosm.ownerOf(id), alice);
        assertEq(realLiquidity(id), 1e18);

        vm.warp(START_TIME + LOCK);
        vm.prank(alice);
        realPosm.multicall(calls);
        assertEq(realLiquidity(id), 0);
        assertGt(alice.balance, ethBefore);
        assertGt(token.balanceOf(alice), tokenBefore);
    }

    function test_failedTopUpCannotRestartTheLock() public {
        fundReal(alice);
        uint256 id = mintReal(alice, 1e18);
        vm.warp(START_TIME + 20 days);
        // Hook runs before PositionManager's slippage check: its write must roll back too.
        bytes memory data = PositionActions.settle(
            key, Actions.INCREASE_LIQUIDITY, abi.encode(id, uint256(1e18), uint128(0), uint128(0), bytes(""))
        );
        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(realPosm).call{value: 1 ether}(
            abi.encodeCall(IPositionManager.modifyLiquidities, (data, type(uint256).max))
        );
        assertFalse(ok, "zero input limits should reject a positive top-up");
        assertEq(bytes4(reason), SlippageCheck.MaximumAmountExceeded.selector);
        assertEq(realLiquidity(id), 1e18);
        assertEq(hook.unlockAt(poolId, realKey(id)), START_TIME + LOCK);
        assertEq(alice.balance, ethBefore);
        assertEq(token.balanceOf(alice), tokenBefore);
        vm.warp(START_TIME + LOCK);
        decreaseReal(alice, id, 1e18);
    }

    function test_strangerCannotTopUpCollectDecreaseOrBurnSomeoneElsesNft() public {
        fundReal(alice);
        fundReal(bob);
        uint256 id = mintReal(alice, 1e18);
        vm.warp(START_TIME + 20 days);
        bytes[4] memory attempts = [
            PositionActions.increase(key, id, 1),
            PositionActions.decrease(key, id, 0),
            PositionActions.decrease(key, id, 1),
            PositionActions.burn(key, id)
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, bob));
            realPosm.modifyLiquidities(attempts[i], type(uint256).max);
        }
        assertEq(realLiquidity(id), 1e18);
        assertEq(hook.unlockAt(poolId, realKey(id)), START_TIME + LOCK);
    }

    function test_transferAndApprovalDoNotBypassOrRestartLock() public {
        fundReal(alice);
        uint256 id = mintReal(alice, 1e18);
        vm.warp(START_TIME + 20 days);
        vm.prank(alice);
        realPosm.approve(bob, id);
        _expectLocked(bob, PositionActions.decrease(key, id, 1), START_TIME + LOCK);
        vm.prank(bob);
        realPosm.transferFrom(alice, bob, id);
        assertEq(realPosm.ownerOf(id), bob);
        assertEq(hook.unlockAt(poolId, realKey(id)), START_TIME + LOCK);
        _expectLocked(bob, PositionActions.burn(key, id), START_TIME + LOCK);
        vm.warp(START_TIME + LOCK);
        decreaseReal(bob, id, 1e18);
        assertEq(realLiquidity(id), 0);
    }

    function test_zeroIncreaseCollectsFeesWithoutRestartingLock() public {
        fundReal(alice);
        fundReal(bob);
        uint256 id = mintReal(alice, 1e18);
        _donateToActivePosition();
        vm.warp(START_TIME + 20 days);
        uint256 ethBefore = alice.balance;
        increaseReal(alice, id, 0);
        assertGt(alice.balance, ethBefore, "zero increase should deliver fees");
        assertEq(realLiquidity(id), 1e18);
        assertEq(hook.unlockAt(poolId, realKey(id)), START_TIME + LOCK);
        vm.warp(START_TIME + LOCK);
        decreaseReal(alice, id, 1e18);
    }

    function _donateToActivePosition() internal {
        vm.prank(bob);
        donateRouter.donate{value: 0.01 ether}(key, 0.01 ether, 1_000 ether, "");
    }

    function _expectLocked(address caller, bytes memory data, uint256 until) internal {
        vm.prank(caller);
        vm.expectRevert(wrappedStillLocked(until));
        realPosm.modifyLiquidities(data, type(uint256).max);
    }
}
