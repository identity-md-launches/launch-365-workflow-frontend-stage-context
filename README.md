# Lockup (LKUP) and LiquidityLockupHook

A Uniswap v4 launch on Sepolia: a fixed-supply ERC-20, **Lockup (LKUP)**, and a hook,
**LiquidityLockupHook**, that locks every liquidity position on the token's native-ETH pool for
30 days after its last add. Nothing else. The hook takes no fee, returns no deltas, holds no funds
and has no owner.

Site label: `lab-lp-lockup-hook`. Network: Sepolia (chain id 11155111) only.

## Contracts

| Contract              | File                          | Constructor                        | ABI                                    |
| --------------------- | ----------------------------- | ---------------------------------- | -------------------------------------- |
| `Lockup`              | `src/Lockup.sol`              | none                               | `docs/abi/Lockup.json`                 |
| `LiquidityLockupHook` | `src/LiquidityLockupHook.sol` | `(IPoolManager poolManager)`       | `docs/abi/LiquidityLockupHook.json`    |
| `HookFlags`           | `src/HookFlags.sol`           | library (permission bits, no code) |                                        |

### Lockup (LKUP)

- Name `Lockup`, symbol `LKUP`, 18 decimals, total supply `1_000_000_000e18`.
- The whole supply is minted once, in the constructor, to `msg.sender` (the factory at launch).
- Plain ERC-20 (`transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`, `totalSupply`).
  An allowance of `type(uint256).max` is infinite and never decremented. Transfers to the zero
  address revert.
- No mint, burn, owner, admin, pause, permit, proxy, `delegatecall` or `selfdestruct`. There is
  no privileged function of any kind after deployment.

### LiquidityLockupHook

**Permissions.** Exactly `afterAddLiquidity` and `beforeRemoveLiquidity`; the other twelve flags
are false. The address must therefore carry the low bits `0x0600`. The constructor calls
`Hooks.validateHookPermissions`, so a deployment at an address with any other bit pattern reverts
`HookAddressNotValid`. The deploy salt is mined for those bits (see `script/Deploy.s.sol` and
`test/utils/HookMiner.sol`).

**Constructor.** One argument: the PoolManager. On Sepolia that is
`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`. Every rate and window is a source constant.
There is no owner, admin, setter, pause, upgrade, sweep, `$owner` or `$token` argument.

**Position identity.** Exactly the PoolManager's own key,
`keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))`, where `owner` is the `sender`
argument of the liquidity callbacks: the router or PositionManager that called
`PoolManager.modifyLiquidity`. The PositionManager uses the NFT `tokenId` as the salt, so every
PositionManager NFT is its own position with its own lock. `positionKey(owner, tickLower,
tickUpper, salt)` on the hook returns this key.

**Behaviour.**

| Callback                | Condition                                                   | Effect                                                                                                             |
| ----------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `afterAddLiquidity`     | `liquidityDelta > 0` and `key.currency0` is native ETH      | `unlockAt[poolId][positionKey] = block.timestamp + 30 days`; emits `Locked`. Every top-up restarts the full window. |
| `afterAddLiquidity`     | otherwise                                                   | nothing                                                                                                            |
| `beforeRemoveLiquidity` | `liquidityDelta < 0` and `block.timestamp < unlockAt`       | reverts `StillLocked(unlockAt)`                                                                                    |
| `beforeRemoveLiquidity` | `liquidityDelta == 0` (fee collection) or `block.timestamp >= unlockAt` | passes                                                                                                 |
| all others              | never called (address bits are unset); revert if called     | `HookNotImplemented`                                                                                               |

- Removal is allowed from `unlockAt` on, inclusive. Removing never changes `unlockAt`; nothing
  can extend or shorten a lock except a new add to the same key.
- Fee collection is a `modifyLiquidity` with `liquidityDelta == 0`, which v4 routes through
  `beforeRemoveLiquidity`. It is never blocked.
- All state is keyed by `PoolId`. A pool on this hook whose `currency0` is not native ETH is
  never locked: the hook returns zero deltas and has no other effect.
- Every callback requires `msg.sender == poolManager`; anyone else gets `NotPoolManager`.
- The hook returns `BalanceDeltaLibrary.ZERO_DELTA` from `afterAddLiquidity` and has no
  return-delta permissions, so it can neither take nor owe currency. It has no `receive` or
  `fallback`; ETH sent to it reverts.
- Swaps and donations never reach the hook.
- The factory's own seed position is locked like any other. The launch never needs to remove it.

**Views.**

| Function                                                        | Returns                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------- |
| `LOCK_DURATION()`                                               | `2_592_000` (30 days)                                         |
| `poolManager()`                                                 | the PoolManager                                               |
| `getHookPermissions()`                                          | the `Hooks.Permissions` struct above                          |
| `unlockAt(PoolId, bytes32 positionKey)`                         | unlock timestamp, `0` if never locked                         |
| `positionKey(owner, tickLower, tickUpper, salt)`                | the PoolManager position key                                  |
| `positionUnlockAt(PoolId, owner, tickLower, tickUpper, salt)`   | unlock timestamp by components                                |
| `isLocked(PoolId, positionKey)`                                 | `block.timestamp < unlockAt`                                  |
| `timeRemaining(PoolId, positionKey)`                            | seconds until removal is allowed, `0` when it already is      |

**Events and errors.**

```solidity
event Locked(
    PoolId indexed poolId,
    bytes32 indexed positionKey,
    address indexed sender,   // router or PositionManager that called modifyLiquidity
    int24 tickLower,
    int24 tickUpper,
    bytes32 salt,             // the NFT tokenId when sender is the PositionManager
    int256 liquidityDelta,
    uint256 unlockAt
);

error NotPoolManager();
error HookNotImplemented();
error StillLocked(uint256 unlockAt);
```

When a removal is refused, the caller of the PoolManager does not see `StillLocked` directly.
v4-core wraps every hook revert in ERC-7751 form:
`WrappedError(hook, IHooks.beforeRemoveLiquidity.selector, abi.encode(StillLocked(unlockAt)), abi.encode(Hooks.HookCallFailed.selector))`.
Front ends should decode the inner `reason` to read the unlock time.

## Known limits

- **Shared routers.** On a router where the router itself is the `sender` (for example v4-core's
  `PoolModifyLiquidityTest`), the key `(router, range, salt)` is one position for everybody.
  Anyone adding to it restarts its lock, and anyone can remove from it once it unlocks. LPs must
  use Uniswap's published Sepolia PositionManager
  (`0x429ba70129df741b2ca2a85bc3a2a3328e5c09b4`), whose `tokenId` salt makes each NFT its own key.
  The README and the site direct LPs there. `test_sharedRouterKeyIsRestartedByAnyoneAddingToIt`
  demonstrates the limit.
- **Time source.** The lock is measured in `block.timestamp`. A validator can shift a block's
  timestamp by a few seconds; that is the precision of the 30-day window.
- **Fees stay collectable while locked.** This is by design: only principal is locked.
- **No emergency path.** There is no owner and no way to unlock early. Anything deposited is
  locked for 30 days from its last add, including by mistake.
- `hookData` is ignored entirely. Nothing in the hook trusts it.

## Deployment parameters

Every value lives in `script/LaunchConfig.sol` and is read by the tests and the rehearsal script.
Nothing reads the environment. The launch manifest (`launch.json`, written by a separate
assignment) must agree with the values marked **manifest**.

| Parameter                 | Value                                        | Source                                             |
| ------------------------- | -------------------------------------------- | -------------------------------------------------- |
| Chain                     | Sepolia, `11155111`                          | manifest                                           |
| PoolManager               | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | manifest; hook constructor argument                |
| Hook permission bits      | `0x0600`                                     | source (`getHookPermissions`); manifest            |
| Token constructor         | none; supply minted to the deployer          | source                                             |
| Pool key                  | currency0 native ETH, currency1 LKUP, fee `3000`, tickSpacing `60` | factory / manifest           |
| Lock duration             | 30 days                                      | source constant                                    |
| Initial sqrt price        | `79228162514264337593543950336000` (1 ETH = 1,000,000 LKUP, tick 138162) | **rehearsal**; the manifest sets the real price |
| Seed range                | ticks `[-887220, 138120]`, entirely at or below the initial tick | **rehearsal**; the factory chooses |
| Seed amount               | 800,000,000 LKUP                             | **rehearsal**; the factory chooses the split       |

The hook is indifferent to the price, range and amount: any one-sided LKUP seed at or below the
initial tick is accepted, and `afterAddLiquidity` cannot revert for a valid PoolManager call.

`script/Deploy.s.sol` rehearses the two deployments: the token by plain `CREATE`, the hook by
`CREATE2` through forge's deterministic deployer with a salt mined by `mineSalt`. `run()` refuses
any chain but Sepolia. The live launch goes through the factory and the services stage; this
assignment authorises no transaction and controls no wallet.

## Assumptions

- The factory (the token's deployer) initialises the pool at the manifest price and seeds
  one-sided LKUP liquidity as its own position (sender = factory, salt `0`), needing no ETH.
  `test/utils/MockLaunchFactory.sol` reproduces that shape; the real factory's exact router and
  amounts are not known here.
- Uniswap's PositionManager calls `PoolManager.modifyLiquidity` with itself as `msg.sender` and
  `bytes32(tokenId)` as the salt. `test/utils/MockPositionManager.sol` reproduces those two facts
  and the delta shapes of mint, increase, decrease, burn and collect. It simplifies settlement
  (no Permit2) and is not the real contract.
- v4-core is vendored at commit `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (2026-04-02); the
  PoolManager deployed in the tests is that source. Behaviour against the live Sepolia deployment
  is the fork rehearsal's job, which is a separate check.

## Operational responsibilities

- **Before launch:** confirm the manifest's PoolManager, chain, permission bits, pool key and
  price match `LaunchConfig`. Mine the hook salt against the actual CREATE2 deployer the factory
  uses; the address must carry `0x0600` or the constructor reverts.
- **Independent adversarial review** (read-only, separate contributor) before release, covering
  every removal path (PositionManager decrease, burn, multicall, delta 0), whether any path can
  lock liquidity forever or lock someone else's position, the shared-router grief, position-key
  derivation, and that `afterAddLiquidity` can never revert the factory's seed add. Passing tests
  are not an audit.
- **After launch:** nothing to operate. There is no owner, key, pause or upgrade. Monitoring is
  limited to reading `Locked` events and the views above.
- **LP guidance:** send LPs to the PositionManager, never to a shared test router. Tell them that
  every add, including a top-up, restarts the full 30 days.

## Tests

Foundry, with a real v4-core `PoolManager` deployed in each test and the hook at a mined address.

- `test/LaunchRehearsal.t.sol`: the launch as the factory performs it (initialise at the manifest
  price, one-sided seed with zero ETH, `Locked` for the seed, seed locked and removable at
  `unlockAt`), the first buy into the ETH-less pool, exact-in and exact-out in both directions,
  dust amounts, fuzzed sizes and round trips, donations, and that the hook holds no funds.
- `test/LiquidityLockupHook.t.sol`: permissions and address bits, constructor rejection of wrong
  or extra bits, position-key equality with the PoolManager, views, removal at `unlockAt - 1`
  reverts and at `unlockAt` passes (also fuzzed over elapsed time), top-up restarts, fee
  collection (delta 0) while locked through both a PositionManager and a shared router, two
  PositionManager NFTs on the same range locking independently, the shared-router limit, a pool
  whose currency0 is not ETH, every callback refusing non-PoolManager callers, and the disabled
  callbacks refusing even the PoolManager.
- `test/Lockup.t.sol`: metadata, single mint to the deployer, transfers, allowances, error paths,
  no admin or mint selector, ETH rejection, fuzzed supply conservation.
- `test/Deploy.t.sol`: the rehearsal script's salt mining and deployment, driven directly.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`ffi = false` and no filesystem permissions. Tests read no environment variables and do not
depend on the caller's address.

## Dependencies

Vendored as ordinary files under `lib/` (no submodules); see `lib/VENDORED.md`.
