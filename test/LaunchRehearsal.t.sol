// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";

import {LockupTestBase} from "./utils/LockupTestBase.sol";
import {MockLaunchFactory} from "./utils/MockLaunchFactory.sol";
import {LiquidityLockupHook} from "../src/LiquidityLockupHook.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

/// @notice The launch, rehearsed the way the factory performs it: initialise the native-ETH / LKUP
/// pool at the manifest price, seed one-sided LKUP as the factory's own position, then trade into a
/// pool that holds no ETH. Also every swap and donation shape, to show the hook never touches them.
contract LaunchRehearsalTest is LockupTestBase {
    using StateLibrary for IPoolManager;

    // ───────────────────────────── the launch itself ─────────────────────────────

    function test_launchParametersAreConsistent() public pure {
        assertEq(LaunchConfig.HOOK_FLAGS, 0x0600, "flags are afterAddLiquidity | beforeRemoveLiquidity");
        assertEq(TickMath.getTickAtSqrtPrice(LaunchConfig.INITIAL_SQRT_PRICE_X96), LaunchConfig.INITIAL_TICK);
        assertEq(LaunchConfig.SEED_TICK_LOWER % LaunchConfig.TICK_SPACING, 0, "seed lower not on spacing");
        assertEq(LaunchConfig.SEED_TICK_UPPER % LaunchConfig.TICK_SPACING, 0, "seed upper not on spacing");
        assertLe(LaunchConfig.SEED_TICK_UPPER, LaunchConfig.INITIAL_TICK, "seed must sit at or below the price");
        assertGe(LaunchConfig.SEED_TICK_LOWER, TickMath.MIN_TICK, "seed lower below MIN_TICK");
        assertLe(LaunchConfig.SEED_AMOUNT, 1_000_000_000e18, "cannot seed more than the supply");
    }

    function test_factoryInitializeAndOneSidedSeedSucceed() public view {
        // The pool opened at the manifest price and tick.
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(sqrtPriceX96, LaunchConfig.INITIAL_SQRT_PRICE_X96, "price");
        assertEq(tick, LaunchConfig.INITIAL_TICK, "tick");
        assertEq(initialTick, LaunchConfig.INITIAL_TICK, "tick returned by initialize");
        assertEq(lpFee, LaunchConfig.POOL_FEE, "fee");
        assertEq(Currency.unwrap(key.currency0), address(0), "currency0 is native ETH");
        assertEq(Currency.unwrap(key.currency1), address(token), "currency1 is LKUP");
        assertEq(address(key.hooks), address(hook), "hook");

        // The seed cost the factory LKUP only. The pool holds no ETH.
        assertEq(seedDelta.amount0(), 0, "seed must not need ETH");
        assertLt(seedDelta.amount1(), 0, "seed pays LKUP");
        assertEq(managerEth(), 0, "pool holds no ETH after launch");
        assertEq(token.balanceOf(address(manager)), uint256(uint128(-seedDelta.amount1())), "pool holds the seed");
        assertApproxEqRel(uint256(uint128(-seedDelta.amount1())), LaunchConfig.SEED_AMOUNT, 1e12, "seed amount");
        assertEq(
            token.balanceOf(address(factory)) + token.balanceOf(address(manager)), token.totalSupply(), "supply split"
        );

        // The seed position exists under the factory's own key with salt 0.
        (uint128 liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(
                poolId, address(factory), LaunchConfig.SEED_TICK_LOWER, LaunchConfig.SEED_TICK_UPPER, bytes32(0)
            );
        assertEq(liquidity, seedLiquidity, "seed liquidity recorded");

        // The pool's active liquidity is zero: the whole seed sits below the price, waiting for the first buy.
        assertEq(poolLiquidity(), 0, "no in-range liquidity yet");
    }

    function test_seedIsLockedLikeAnyOtherPosition() public {
        assertEq(hook.unlockAt(poolId, seedKey()), launchTime + LOCK, "seed unlockAt");
        assertTrue(hook.isLocked(poolId, seedKey()));

        vm.expectRevert(wrappedStillLocked(launchTime + LOCK));
        factory.unseed(LaunchConfig.SEED_TICK_LOWER, LaunchConfig.SEED_TICK_UPPER, 1);

        vm.warp(launchTime + LOCK - 1);
        vm.expectRevert(wrappedStillLocked(launchTime + LOCK));
        factory.unseed(LaunchConfig.SEED_TICK_LOWER, LaunchConfig.SEED_TICK_UPPER, 1);

        // The launch never needs this, but the factory is not trapped either.
        vm.warp(launchTime + LOCK);
        factory.unseed(LaunchConfig.SEED_TICK_LOWER, LaunchConfig.SEED_TICK_UPPER, 1);
    }

    function test_launchEmitsLockedForTheSeed() public {
        // A second launch on a fresh factory (and hence a fresh token and pool) to observe the event.
        MockLaunchFactory second = new MockLaunchFactory(manager);
        bytes32 expectedKey = Position.calculatePositionKey(
            address(second), LaunchConfig.SEED_TICK_LOWER, LaunchConfig.SEED_TICK_UPPER, bytes32(0)
        );

        vm.expectEmit(false, true, true, true, address(hook));
        emit Locked(
            PoolId.wrap(bytes32(0)), // pool id is not known before the token address is; topic1 unchecked
            expectedKey,
            address(second),
            LaunchConfig.SEED_TICK_LOWER,
            LaunchConfig.SEED_TICK_UPPER,
            bytes32(0),
            int256(uint256(seedLiquidity)),
            block.timestamp + LOCK
        );
        (PoolKey memory k,,) = second.launch(
            IHooks(address(hook)),
            LaunchConfig.INITIAL_SQRT_PRICE_X96,
            LaunchConfig.SEED_TICK_LOWER,
            LaunchConfig.SEED_TICK_UPPER,
            seedLiquidity
        );
        assertEq(hook.unlockAt(k.toId(), expectedKey), block.timestamp + LOCK);
    }

    function test_afterAddLiquidityReturnsZeroDeltaForTheSeed() public {
        // Called as the PoolManager would, the callback reports no hook delta at all.
        vm.prank(address(manager));
        (bytes4 selector, BalanceDelta hookDelta) = hook.afterAddLiquidity(
            address(factory), key, _seedParams(int256(uint256(seedLiquidity))), seedDelta, BalanceDelta.wrap(0), ""
        );
        assertEq(selector, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(hookDelta), 0, "hook delta must be zero");
    }

    // ───────────────────────────── the first buy and later trades ─────────────────────────────

    function test_firstBuyLandsInAnEthLessPool() public {
        assertEq(managerEth(), 0);
        fund(alice, 10 ether, 0);

        uint256 lkupBefore = token.balanceOf(alice);
        BalanceDelta delta = buy(alice, 1 ether);

        assertEq(delta.amount0(), -1 ether, "paid exactly 1 ETH");
        assertGt(delta.amount1(), 0, "received LKUP");
        assertEq(token.balanceOf(alice) - lkupBefore, uint256(uint128(delta.amount1())), "LKUP delivered");
        assertEq(managerEth(), 1 ether, "the pool now holds the ETH");
        assertEq(alice.balance, 9 ether, "router refunded nothing extra");
        // Roughly 1,000,000 LKUP per ETH minus the 0.3% fee and price impact.
        assertApproxEqRel(uint256(uint128(delta.amount1())), 997_000e18, 0.01e18, "price around 1e6 LKUP/ETH");
        assertLt(currentTick(), LaunchConfig.INITIAL_TICK, "price moved down into the seed range");
        assertGt(poolLiquidity(), 0, "seed liquidity is active now");
    }

    function test_exactOutBuy() public {
        fund(alice, 10 ether, 0);
        BalanceDelta delta = swapAs(alice, true, 500_000e18, 10 ether);
        assertEq(delta.amount1(), 500_000e18, "received exactly the LKUP asked for");
        assertLt(delta.amount0(), 0, "paid ETH");
        assertEq(alice.balance, 10 ether - uint256(uint128(-delta.amount0())), "surplus ETH refunded");
    }

    function test_exactInSellAfterFirstBuy() public {
        fund(alice, 10 ether, 0);
        buy(alice, 1 ether);
        uint256 lkup = token.balanceOf(alice);

        BalanceDelta delta = sell(alice, lkup / 2);
        assertEq(delta.amount1(), -int256(lkup / 2), "paid exactly half the LKUP");
        assertGt(delta.amount0(), 0, "received ETH");
        assertGt(alice.balance, 9 ether, "ETH came back");
    }

    function test_exactOutSellAfterFirstBuy() public {
        fund(alice, 10 ether, 0);
        buy(alice, 1 ether);

        BalanceDelta delta = swapAs(alice, false, 0.1 ether, 0);
        assertEq(delta.amount0(), 0.1 ether, "received exactly 0.1 ETH");
        assertLt(delta.amount1(), 0, "paid LKUP");
    }

    function test_dustSwapsBothWays() public {
        fund(alice, 10 ether, 0);
        BalanceDelta dustBuy = buy(alice, 1);
        assertEq(dustBuy.amount0(), -1, "1 wei in");
        assertGe(dustBuy.amount1(), 0);

        buy(alice, 1 ether);
        BalanceDelta dustSell = sell(alice, 1);
        assertEq(dustSell.amount1(), -1, "1 wei of LKUP in");
        assertGe(dustSell.amount0(), 0);
    }

    function testFuzz_buySizes(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 100 ether);
        fund(alice, ethIn, 0);
        BalanceDelta delta = buy(alice, ethIn);
        assertEq(delta.amount0(), -int256(ethIn));
        assertGe(delta.amount1(), 0);
        assertEq(managerEth(), ethIn);
        assertEq(token.balanceOf(alice), uint256(uint128(delta.amount1())));
    }

    function testFuzz_roundTrip(uint256 ethIn, uint256 sellFraction) public {
        ethIn = bound(ethIn, 1e12, 100 ether);
        sellFraction = bound(sellFraction, 1, 100);
        fund(alice, ethIn, 0);
        BalanceDelta bought = buy(alice, ethIn);
        uint256 toSell = uint256(uint128(bought.amount1())) * sellFraction / 100;
        vm.assume(toSell > 0);
        BalanceDelta sold = sell(alice, toSell);
        assertEq(sold.amount1(), -int256(toSell));
        assertLe(uint256(uint128(sold.amount0())), ethIn, "cannot get more ETH out than went in");
    }

    function test_donationsAreUnaffected() public {
        fund(alice, 10 ether, 1_000e18);
        buy(alice, 1 ether); // brings the seed into range so there is liquidity to donate to
        vm.prank(alice);
        BalanceDelta delta = donateRouter.donate{value: 0.5 ether}(key, 0.5 ether, 1_000e18, "");
        assertEq(delta.amount0(), -0.5 ether);
        assertEq(delta.amount1(), -1_000e18);
        assertEq(managerEth(), 1.5 ether);
    }

    function test_hookHoldsNoFundsAndAcceptsNoEth() public {
        fund(alice, 10 ether, 10_000e18);
        buy(alice, 1 ether);
        mintViaPosm(alice, IN_RANGE_LOWER, IN_RANGE_UPPER, 1e18);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);

        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "hook must not accept ETH");
    }

    function _seedParams(int256 liquidityDelta) internal pure returns (ModifyLiquidityParams memory p) {
        p.tickLower = LaunchConfig.SEED_TICK_LOWER;
        p.tickUpper = LaunchConfig.SEED_TICK_UPPER;
        p.liquidityDelta = liquidityDelta;
        p.salt = bytes32(0);
    }
}
