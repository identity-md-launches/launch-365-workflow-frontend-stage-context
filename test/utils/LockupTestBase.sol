// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

import {Lockup} from "../../src/Lockup.sol";
import {LiquidityLockupHook} from "../../src/LiquidityLockupHook.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {HookMiner} from "./HookMiner.sol";
import {MockLaunchFactory} from "./MockLaunchFactory.sol";
import {MockPositionManager} from "./MockPositionManager.sol";

/// @notice Shared fixture: a real v4-core PoolManager, the hook at a mined address, and the launch
/// already rehearsed exactly as the factory does it (initialise at the manifest price, seed one-sided
/// LKUP). Every test starts from the state the pool is in right after launch: no ETH, seed locked.
abstract contract LockupTestBase is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant START_TIME = 1_800_000_000;
    uint256 internal constant LOCK = 30 days;

    // An in-range band around the initial tick (138162), multiples of 60.
    int24 internal constant IN_RANGE_LOWER = 138_000;
    int24 internal constant IN_RANGE_UPPER = 138_300;

    PoolManager internal manager;
    LiquidityLockupHook internal hook;
    MockLaunchFactory internal factory;
    MockPositionManager internal posm;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    PoolDonateTest internal donateRouter;
    Lockup internal token;

    PoolKey internal key;
    PoolId internal poolId;
    uint128 internal seedLiquidity;
    int24 internal initialTick;
    BalanceDelta internal seedDelta;
    uint256 internal launchTime;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Locked(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        int256 liquidityDelta,
        uint256 unlockAt
    );

    function setUp() public virtual {
        vm.warp(START_TIME);

        manager = new PoolManager(address(this));
        hook = deployHookAtMinedAddress(manager);

        factory = new MockLaunchFactory(manager);
        posm = new MockPositionManager(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        donateRouter = new PoolDonateTest(manager);

        seedLiquidity = seedLiquidityFor(LaunchConfig.SEED_AMOUNT);
        launchTime = block.timestamp;
        (key, initialTick, seedDelta) = factory.launch(
            IHooks(address(hook)),
            LaunchConfig.INITIAL_SQRT_PRICE_X96,
            LaunchConfig.SEED_TICK_LOWER,
            LaunchConfig.SEED_TICK_UPPER,
            seedLiquidity
        );
        poolId = key.toId();
        token = factory.token();
    }

    // ───────────────────────────── deployment helpers ─────────────────────────────

    /// @dev Mines a salt for the 0x0600 bits and deploys by CREATE2 from this contract.
    function deployHookAtMinedAddress(IPoolManager _manager) internal returns (LiquidityLockupHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), LaunchConfig.HOOK_FLAGS, type(LiquidityLockupHook).creationCode, abi.encode(_manager)
        );
        deployed = new LiquidityLockupHook{salt: salt}(_manager);
        assertEq(address(deployed), expected, "hook landed on an unexpected address");
    }

    function seedLiquidityFor(uint256 lkupAmount) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(LaunchConfig.SEED_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(LaunchConfig.SEED_TICK_UPPER),
            lkupAmount
        );
    }

    // ───────────────────────────── account helpers ─────────────────────────────

    /// @dev Gives `who` ETH and LKUP (from the factory's unseeded remainder) and approves every router.
    function fund(address who, uint256 eth, uint256 lkup) internal {
        vm.deal(who, eth);
        if (lkup > 0) factory.distribute(who, lkup);
        vm.startPrank(who);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(posm), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ───────────────────────────── position helpers ─────────────────────────────

    function routerKey(int24 tickLower, int24 tickUpper, bytes32 salt) internal view returns (bytes32) {
        return hook.positionKey(address(lpRouter), tickLower, tickUpper, salt);
    }

    function posmKey(uint256 tokenId, int24 tickLower, int24 tickUpper) internal view returns (bytes32) {
        return hook.positionKey(address(posm), tickLower, tickUpper, bytes32(tokenId));
    }

    function seedKey() internal view returns (bytes32) {
        return
            hook.positionKey(address(factory), LaunchConfig.SEED_TICK_LOWER, LaunchConfig.SEED_TICK_UPPER, bytes32(0));
    }

    /// @dev Adds or removes liquidity through the shared router as `who`, forwarding all of `who`'s ETH
    /// (the router refunds what it does not need).
    function modifyViaRouter(address who, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(who);
        delta = lpRouter.modifyLiquidity{value: liquidityDelta > 0 ? who.balance : 0}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
            }),
            ""
        );
    }

    function mintViaPosm(address who, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(who);
        (tokenId,) = posm.mint{value: who.balance}(key, tickLower, tickUpper, liquidity, who);
    }

    // ───────────────────────────── swap helpers ─────────────────────────────

    /// @dev ETH -> LKUP, exact input. The pool's first trades are of this shape.
    function buy(address who, uint256 ethIn) internal returns (BalanceDelta) {
        return swapAs(who, true, -int256(ethIn), ethIn);
    }

    /// @dev LKUP -> ETH, exact input.
    function sell(address who, uint256 lkupIn) internal returns (BalanceDelta) {
        return swapAs(who, false, -int256(lkupIn), 0);
    }

    /// @param maxEth ETH forwarded to the router for zeroForOne swaps; the surplus is refunded.
    function swapAs(address who, bool zeroForOne, int256 amountSpecified, uint256 maxEth)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(who);
        delta = swapRouter.swap{value: zeroForOne ? maxEth : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev What a caller of the PoolManager sees when the hook refuses a removal: v4-core wraps the
    /// hook's `StillLocked(unlockAt)` in an ERC-7751 `WrappedError(hook, selector, reason, details)`.
    function wrappedStillLocked(uint256 unlockAt) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(LiquidityLockupHook.StillLocked.selector, unlockAt),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function poolLiquidity() internal view returns (uint128) {
        return IPoolManager(address(manager)).getLiquidity(poolId);
    }

    function currentTick() internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    function managerEth() internal view returns (uint256) {
        return address(manager).balance;
    }
}
