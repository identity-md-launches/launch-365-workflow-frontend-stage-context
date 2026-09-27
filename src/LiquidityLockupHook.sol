// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title LiquidityLockupHook
/// @notice Uniswap v4 hook that locks every liquidity position on a native-ETH pool for 30 days
/// after its last add. Nothing else: no deltas, no fee, no funds held, no owner, no setter.
///
/// Position identity is exactly the PoolManager's own position key,
/// `keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))`, where `owner` is the `sender`
/// argument of the liquidity callbacks. That sender is the contract that called
/// `PoolManager.modifyLiquidity` (a router or the PositionManager). The PositionManager uses the NFT
/// tokenId as the salt, so every PositionManager NFT is its own independent lock.
///
/// Behaviour:
/// - `afterAddLiquidity` with `liquidityDelta > 0` on a pool whose currency0 is native ETH sets
///   `unlockAt[poolId][positionKey] = block.timestamp + LOCK_DURATION` and emits `Locked`. Every
///   top-up restarts the full window.
/// - `beforeRemoveLiquidity` with `liquidityDelta < 0` reverts `StillLocked(unlockAt)` while
///   `block.timestamp < unlockAt`. A call with `liquidityDelta == 0` (fee collection, which v4
///   routes through `beforeRemoveLiquidity`) always passes, as does any removal at or after
///   `unlockAt`.
/// - Pools whose currency0 is not native ETH are never locked; the hook returns zero deltas and has
///   no other effect on them.
/// - Every callback requires `msg.sender == poolManager`.
///
/// Known limit: on a shared router (for example v4-core's `PoolModifyLiquidityTest`) the sender is
/// the router itself, so anyone adding to the same (router, range, salt) key restarts that key's
/// lock. LPs should use the PositionManager, whose tokenId salt makes each NFT its own key.
contract LiquidityLockupHook is IHooks {
    using CurrencyLibrary for Currency;

    /// @notice How long a position stays locked after its most recent add.
    uint256 public constant LOCK_DURATION = 30 days;

    /// @notice The only PoolManager allowed to drive this hook.
    IPoolManager public immutable poolManager;

    /// @notice Timestamp (inclusive) from which the position may remove liquidity. Zero means never locked.
    mapping(PoolId poolId => mapping(bytes32 positionKey => uint256 unlockAt)) public unlockAt;

    /// @notice Emitted whenever an add restarts a position's lock.
    /// @param poolId The pool the position belongs to.
    /// @param positionKey The PoolManager position key: keccak256(owner, tickLower, tickUpper, salt).
    /// @param sender The `sender` argument of the callback: the router or PositionManager that called modifyLiquidity.
    /// @param tickLower Lower tick of the position.
    /// @param tickUpper Upper tick of the position.
    /// @param salt The position salt (the NFT tokenId when the sender is the PositionManager).
    /// @param liquidityDelta The liquidity added in this call.
    /// @param unlockAt The timestamp from which removal is allowed again.
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

    /// @notice A callback was invoked by an address other than the PoolManager.
    error NotPoolManager();
    /// @notice A callback this hook does not enable was invoked.
    error HookNotImplemented();
    /// @notice Liquidity removal attempted before the position's unlock time.
    /// @param unlockAt The timestamp from which removal is allowed.
    error StillLocked(uint256 unlockAt);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The Uniswap v4 PoolManager this hook serves. The only constructor argument.
    /// @dev Reverts `Hooks.HookAddressNotValid` unless the deployment address carries exactly the
    /// bits for afterAddLiquidity and beforeRemoveLiquidity (0x0600), so the CREATE2 salt must be
    /// mined for those bits.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Permissions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Exactly afterAddLiquidity and beforeRemoveLiquidity; every other flag is false.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The PoolManager position key for (owner, tickLower, tickUpper, salt).
    /// @dev `owner` is the address that calls `PoolManager.modifyLiquidity` (router or PositionManager),
    /// and for the PositionManager `salt` is `bytes32(tokenId)`.
    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
    }

    /// @notice Unlock timestamp for a position described by its components rather than its key.
    function positionUnlockAt(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256)
    {
        return unlockAt[poolId][Position.calculatePositionKey(owner, tickLower, tickUpper, salt)];
    }

    /// @notice True while removing liquidity from the position would revert.
    function isLocked(PoolId poolId, bytes32 key) public view returns (bool) {
        return block.timestamp < unlockAt[poolId][key];
    }

    /// @notice Seconds until the position can remove liquidity; zero when it already can.
    function timeRemaining(PoolId poolId, bytes32 key) external view returns (uint256) {
        uint256 until = unlockAt[poolId][key];
        return block.timestamp < until ? until - block.timestamp : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Enabled callbacks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IHooks
    /// @dev Never reverts for a valid PoolManager call, so it can never block the factory's seed
    /// add. Always returns a zero delta: the hook takes nothing and owes nothing.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta > 0 && key.currency0.isAddressZero()) {
            _lock(key.toId(), sender, params);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Restarts the full lock window for the position and records it in `Locked`.
    function _lock(PoolId poolId, address sender, ModifyLiquidityParams calldata params) internal {
        bytes32 posKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        uint256 until = block.timestamp + LOCK_DURATION;
        unlockAt[poolId][posKey] = until;
        emit Locked(
            poolId, posKey, sender, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta, until
        );
    }

    /// @inheritdoc IHooks
    /// @dev v4 routes every `modifyLiquidity` with `liquidityDelta <= 0` here, including the zero
    /// delta used to collect fees. Only a strictly negative delta is ever refused.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (params.liquidityDelta < 0) {
            bytes32 posKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
            uint256 until = unlockAt[key.toId()][posKey];
            if (block.timestamp < until) revert StillLocked(until);
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Disabled callbacks. The address does not carry their bits, so the PoolManager never calls
    // them; they exist only to satisfy IHooks and refuse every caller.
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
