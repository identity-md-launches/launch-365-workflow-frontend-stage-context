// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookFlags} from "../src/HookFlags.sol";

/// @title LaunchConfig
/// @notice Deployment parameters of the LKUP / LiquidityLockupHook launch, in one place.
/// @dev Tests and the rehearsal deploy script read these constants; nothing reads the environment.
/// The launch manifest (launch.json, written by a separate assignment) must agree with them, and the
/// README lists each as a deployment parameter. Values marked "rehearsal" are this suite's stand-in
/// for a choice the factory makes at launch time.
library LaunchConfig {
    /// @notice Sepolia chain id: the only network this launch targets.
    uint256 internal constant CHAIN_ID = 11155111;

    /// @notice Uniswap v4 PoolManager on Sepolia. The hook's only constructor argument.
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice Permission bits the hook address must carry: afterAddLiquidity | beforeRemoveLiquidity.
    uint160 internal constant HOOK_FLAGS = HookFlags.AFTER_ADD_LIQUIDITY | HookFlags.BEFORE_REMOVE_LIQUIDITY; // 0x0600

    /// @notice Pool key parameters the factory uses: currency0 native ETH, currency1 LKUP.
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;

    /// @notice Initial sqrt price, Q64.96: 1 ETH = 1,000,000 LKUP (sqrt(1e6) = 1000, times 2^96).
    /// Rehearsal value: the manifest sets the real one; any price works for the hook.
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336000;

    /// @notice The tick of INITIAL_SQRT_PRICE_X96 (floor(log_1.0001(1e6))).
    int24 internal constant INITIAL_TICK = 138162;

    /// @notice The factory's one-sided seed range. Entirely at or below the initial tick, so the
    /// position holds only LKUP and the pool opens with no ETH. Rehearsal values.
    int24 internal constant SEED_TICK_LOWER = -887_220; // lowest tick usable with spacing 60
    int24 internal constant SEED_TICK_UPPER = 138_120; // highest multiple of 60 not above INITIAL_TICK

    /// @notice LKUP the rehearsal factory seeds. The real split is the factory's; the hook is indifferent.
    uint256 internal constant SEED_AMOUNT = 800_000_000e18;
}
