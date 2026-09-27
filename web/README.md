# Lockup frontend

One static React / TypeScript page for the deployed ETH / LKUP pool on Sepolia. The production export is `../dist/`. It works at a gateway subpath with no server routes, hosted fonts, analytics, secrets, or backend. The worker does not publish the page, pin IPFS content, or deploy contracts.

## Run and rebuild

Use Node.js 22.12 or later. From `web/`:

```sh
npm ci
npm run build
npm run preview
```

The build typechecks, exports with Vite `base: './'`, verifies implementation ABI hashes, copies the ABIs and license, then generates `dist/imd-deployment.json` from the final exported bytes. `npm run check:export` checks the inventory without rewriting it. Always run the full build after a source or export change. Do not edit the export manually.

`npm run dev` serves the source and reads the deployment manifest/ABIs from the last production build through a small Vite middleware. Run the build once first. `npm run preview` serves the export. Browser interaction tests serve that export under `/preview/` in a bounded foreground process, then close both server and browser.

On this worker the home directory is read-only. Installation used `npm ci --cache /tmp/lockup-npm` and `PLAYWRIGHT_BROWSERS_PATH=/tmp/lockup-browsers`. These caches are outside the submission. No vendored registry, dependency archives, or node_modules are required to serve the committed export.

## Configuration and provenance

The sole **runtime** deployment configuration is `dist/imd-deployment.json`. `src/config.ts` fetches it relative to the entrypoint, then fetches each contract's referenced ABI and validates its canonical Keccak hash before constructing clients. It does not import the handoff or a second contract address map into the JavaScript bundle.

Build inputs:

- `config/deployment.json`: exact supplied handoff, including the deployed source commit, attestation, contract set, deployment block and pool parameters.
- `config/network.json`: exact supplied vetted network and wallet-add-chain parameters.
- `../docs/abi/Lockup.json` and `../docs/abi/LiquidityLockupHook.json`: unchanged implementation-derived ABI arrays from the pinned deployed commit.
- `src/config.ts`: protocol interface fragments for StateView, PositionManager, Permit2, Quoter and Universal Router; no deployment addresses.

The manifest copies the handoff identity and exact contract set; includes the unchanged `network` object and exact `walletAddChain`; adds pool/token descriptors and the deployment block for event scanning; and inventories every other exported file using SHA-256. Paths are relative to `dist/`. The manifest excludes itself. The attestation hash is an identity copied from the handoff; the browser does not verify an attestation signature or claim an independent audit.

Pinned ABI provenance and raw-byte checks are in [validation.md](../docs/frontend/validation.md). Neither deployed Solidity nor root build configuration was changed. New deployments require a new validated handoff and matching implementation ABI exports, followed by rebuilding and validation.

## Using the page

Public reads work without connecting a wallet. The page checks the RPC chain ID, nonempty code at both deployment contracts and all configured Uniswap addresses, and `poolManager()` on the hook, StateView and PositionManager. Pool price, active liquidity, and current position liquidity come from StateView. The hook's `LOCK_DURATION` and `unlockAt` are read directly.

`Locked` logs are scanned from the deployment block through one latest block. Requests use bounded ranges and shrink when an RPC imposes a smaller limit. Events are ordered and deduplicated by position key; every latest event must agree with the hook's mapping. Position state is read at that same block. The page refreshes every 45 seconds and provides **Refresh pool**. It shows the read block and marks failed or stale reads; transactions are unavailable during failed, incomplete, stale or refreshing reads. There is no persistent event cache or indexer. A long event history can make initial reads slow; partial scans never produce an apparently complete total.

“L” means raw Uniswap liquidity units, not tokens or dollars. Locked liquidity sums **current** liquidity for all observed positions still locked at the read block, including the factory seed and inactive ranges. Active liquidity is the pool's liquidity at its current tick. Large values use scientific notation (`1.134E23` means approximately `1.134 × 10^23`); exact integers are available in position/deployment details.

The ledger shows UTC unlock timestamps and a countdown estimated from the last block timestamp plus elapsed browser time. Transaction eligibility uses actual block time, not the local countdown. Unlocking requires a fresh chain read; a new top-up resets the entire 30-day window. Empty positions remain in the history. Burned NFTs have no owner or actions.

A PositionManager tokenId lookup reads `ownerOf` and `getPoolAndPositionInfo`, verifies the full pool key and packed tick range, and matches the tokenId salt to an observed Locked event. The wallet filter compares current `ownerOf` to the connected account. It never treats a callback sender as the wallet owner.

### Add, remove and collect

Adding liquidity is intentionally external. Use a v4 PositionManager client supporting Sepolia and the exact ETH / LKUP pool key from the deployment manifest: paired currency, deployed token, fee, tick spacing, and deployed hook. Confirm it sends to `network.uniswapV4.positionManager`, whose PoolManager binding the page checks. The [official PositionManager guide](https://developers.uniswap.org/docs/protocols/v4/guides/position-manager) describes the published client interface.

Do not use `PoolModifyLiquidityTest`. Anyone can remove positions held through that unguarded shared test router. Adding to a shared router/range/salt can also restart another participant's lock. PositionManager uses each NFT tokenId as its salt and checks NFT permissions. A top-up through an authorized PositionManager client still restarts that NFT's full 30 days.

For an owned NFT, **Remove liquidity** becomes available at or after the unlock block timestamp. The inline review removes its entire current liquidity, retains the NFT, and shows minimum ETH/LKUP principal amounts calculated with integer tick math and the selected slippage (0.01–5%, default 0.5%). Fees are additional. The 90-second review expires; the transaction has a five-minute deadline. Ownership, current liquidity and current unlock time are checked again before simulation and signing. All liquidity operations use PositionManager `modifyLiquidities` with `DECREASE_LIQUIDITY` plus `TAKE_PAIR` paying the connected wallet. Nothing sends liquidity operations to the PoolManager or a test router.

**Collect fees** uses the same guarded PositionManager route with zero liquidity delta and zero principal minimums. It does not change liquidity or unlock time and is available while locked. A successful simulation is not a guarantee of future execution; the onchain checks remain authoritative.

### Wallets and swaps

An injected EIP-1193 browser wallet is supported. No WalletConnect project ID was supplied, so no WalletConnect or remote wallet service is configured. Open the page in a wallet-enabled browser. The page handles missing wallets, user rejection, account changes, disconnects and wrong chains. Switching first requests `wallet_switchEthereumChain`; an unknown-chain error triggers the handoff's exact `wallet_addEthereumChain`, followed by switching again. Public RPC fallback is followed by the connected wallet provider only when it is on the configured chain.

Swaps are exact input in either direction. The configured v4 Quoter is called by simulation; no quote transaction is sent. Quotes expire after 60 seconds and are invalidated when amount/direction/slippage/account changes. Inputs use onchain token decimals and checked balances. Output minimums apply the selected slippage and are displayed before signing.

ETH input sends exactly the input as transaction value, with no approval. LKUP input presents two explicit transactions: token approval to the configured Permit2 for the exact input, followed by Permit2 authorization of the configured Universal Router for that same input, expiring in 30 minutes. The page reads existing allowances and skips satisfied steps. After each approval it refreshes the quote. Approval gas is additional; an approval already confirmed remains in place if a later swap is cancelled or fails.

The Universal Router payload is `commands = 0x10` and v4 actions `0x060c0f` (`SWAP_EXACT_IN_SINGLE`, `SETTLE_ALL`, `TAKE_ALL`). Pool, router, quoter, Permit2, addresses and network come from the runtime manifest. `execute` is simulated before a signature request. The wallet's chain and account are checked before simulation and again before signing. Submission, pending receipt, success, rejection and errors are displayed with an explorer link. A timeout can leave a transaction pending: inspect that link before retrying.

Protocol implementation references: [StateView](https://github.com/Uniswap/v4-periphery/blob/main/src/lens/StateView.sol), [swap routing](https://developers.uniswap.org/docs/protocols/v4/guides/swapping/routing), and the repository's pinned PositionManager implementation in `test/vendor/v4-periphery/`. Network addresses always come from the supplied network file, never these external pages.

## Validation

```sh
npm run typecheck
npm run build
npm run test
PLAYWRIGHT_BROWSERS_PATH=/tmp/lockup-browsers npm exec -- playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=/tmp/lockup-browsers npm run test:browser
npm run check:live
npm run check:export
node scripts/check-integrity.mjs
```

Unit tests cover deployment hashes, paths, boundaries, encoding, rounding, provider range limits and chain switching. Browser tests exercise the actual production export with mocked JSON-RPC and injected wallet requests; they never send a real transaction. The suite also visits the export with real public RPC reads and no wallet. Results, screenshots, six-domain review, limitations and exact commands are in [validation.md](../docs/frontend/validation.md). `scripts/check-live.ts` is read-only and updates `docs/frontend/live-read.json`.

[Design documentation](../docs/DESIGN.md) lives under `docs/` because the task's overriding write scope excludes repository-root `DESIGN.md`. `web/.gitignore` is the only changed ignore file (explicit budget: 512 bytes; actual 163 bytes), excluding generated dependencies/caches at every nesting level within the frontend. The export, source, lockfile, ABI assets and evidence belong in the submission; dependencies and package caches do not.
