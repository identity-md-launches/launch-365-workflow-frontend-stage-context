# Added integration and stateful coverage

The accepted tests remain intact. These additions deploy a real local v4-core PoolManager
and CREATE2-mine the production hook's address for permissions `0x0600`.

- `PositionManagerIntegration.t.sol` uses the pinned upstream PositionManager and real Permit2
  payments. It covers the exact lock boundary, top-ups before and after expiry, independent NFT
  salts (same and different wallets), both delta-zero collection entrypoints, burn, multicall,
  transfers, approvals, unauthorized calls, and rollback after a failed top-up or burn. It checks
  actual PoolManager liquidity, ownerOf, balances, and the complete wrapped StillLocked error.
- `LaunchExtensions.t.sol` fuzzes factory-style one-sided seed sizes, prices, and range boundaries.
  It compares exact-input/output swaps in both directions and donations against an equivalent
  unhooked pool, including deltas, ticks, price, active liquidity, and fee growth. A separate case
  reuses the same router/range/salt across two PoolIds to check lock isolation.
- `LiquidityLockupInvariant.t.sol` runs 128 sequences of 64 actions across three real NFTs.
  Its independent ghost model tracks successful adds, expected deadlines, and remaining principal.
  Actions include top-ups, removals, collection, time advances, exact-boundary probes, swaps, and
  donations. Unexpected outcomes are latched and fail the invariant; expected lock reverts are
  compared byte-for-byte. Every sequence ends by withdrawing at the final deadlines. A deterministic
  handler test also exercises both removal outcomes and every financial action.

All required dependency files, licenses, pinned revisions, and original source hashes are in
[`vendor/README.md`](vendor/README.md). Only upstream import paths were adapted. No network,
environment variables, filesystem reads, new remappings, or configuration changes are required.
NFT metadata and WETH wrapping are outside these tests; the fixture uses zero addresses for them.

Run with the repository's normal `forge build` and `forge test`. To keep generated artifacts in the
assignment's disposable directory, the local checks use:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

This is a local rehearsal, using the accepted `LaunchConfig` price and factory stand-in. No
`launch.json` was present in this assignment's inputs, so these tests do not assert agreement with
a generated manifest or claim to verify a deployed Sepolia factory/PositionManager's bytecode.
