// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Lockup} from "../../src/Lockup.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";

/// @notice Stand-in for the launch factory. Mirrors the shape of the live launch: deploys the token
/// (so the whole supply is minted to the factory), initialises the native-ETH / LKUP pool, and seeds
/// one-sided LKUP liquidity as its own position (sender = factory, salt = 0). It never needs to
/// remove that position; `unseed` exists only so tests can prove the seed is locked like any other.
contract MockLaunchFactory is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;
    Lockup public token;
    PoolKey public poolKey;

    error NotPoolManager();
    error SeedNeedsEth(int128 amount0);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Deploys LKUP, opens the pool at `sqrtPriceX96` and seeds `liquidity` over [tickLower, tickUpper].
    function launch(IHooks hook, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (PoolKey memory key, int24 tick, BalanceDelta delta)
    {
        token = new Lockup();
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LaunchConfig.POOL_FEE,
            tickSpacing: LaunchConfig.TICK_SPACING,
            hooks: hook
        });
        poolKey = key;
        tick = poolManager.initialize(key, sqrtPriceX96);
        delta = _modify(tickLower, tickUpper, int256(uint256(liquidity)));
    }

    /// @notice Removes `liquidity` from the seed position. Not part of the launch; used to test the lock.
    function unseed(int24 tickLower, int24 tickUpper, uint128 liquidity) external returns (BalanceDelta) {
        return _modify(tickLower, tickUpper, -int256(uint256(liquidity)));
    }

    /// @notice Hands LKUP from the factory's remaining balance to `to` (test convenience only).
    function distribute(address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function _modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal returns (BalanceDelta) {
        return abi.decode(poolManager.unlock(abi.encode(tickLower, tickUpper, liquidityDelta)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (int24 tickLower, int24 tickUpper, int256 liquidityDelta) = abi.decode(data, (int24, int24, int256));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );

        // The live factory holds no ETH at launch: a seed that needed any would fail there too.
        if (liquidityDelta > 0 && delta.amount0() != 0) revert SeedNeedsEth(delta.amount0());

        if (delta.amount0() < 0) {
            poolKey.currency0.settle(poolManager, address(this), uint128(-delta.amount0()), false);
        }
        if (delta.amount1() < 0) {
            poolKey.currency1.settle(poolManager, address(this), uint128(-delta.amount1()), false);
        }
        if (delta.amount0() > 0) poolKey.currency0.take(poolManager, address(this), uint128(delta.amount0()), false);
        if (delta.amount1() > 0) poolKey.currency1.take(poolManager, address(this), uint128(delta.amount1()), false);

        return abi.encode(delta);
    }

    receive() external payable {}
}
