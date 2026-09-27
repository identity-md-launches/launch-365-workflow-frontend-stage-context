# Frontend validation

## Scope and completion

Implemented the one-page Lockup frontend in `web/`, static export in `dist/`, and evidence/design documentation in `docs/`. It reads the live Sepolia deployment, observes locks and current liquidity, looks up PositionManager NFTs, manages eligible owned positions, collects fees, and quotes/swaps ETH and LKUP. Adding liquidity stays with external PositionManager clients. Contracts and root build settings are preserved.

**Implementation and worker validation are complete within the writable scope.** Two delivery constraints remain explicit: root `DESIGN.md` is outside the overriding path allowance, so the full design document is `docs/DESIGN.md`; and the repository's `.git` is read-only, so this worker cannot stage/commit the delivered files. `git add -- web dist docs` actually failed with `Unable to create .../.git/index.lock: Read-only file system`. No approval request or alternative mutation of protected metadata was attempted. The publisher can commit the ready source/export/evidence from the working tree.

No contracts were redeployed, no funds or live transactions were sent, and no website was published. Publication URL/CID checks are a later control-plane responsibility and are not claimed here. This is worker evidence, not independent certification.

## Executed checks

All commands below ran from the repository root unless shown otherwise. Final code checks returned exit 0.

| Check | Command / method | Result |
| --- | --- | --- |
| Clean dependency install | `npm ci --prefix web --cache /tmp/lockup-npm --ignore-scripts` | Pass; subsequent build reproduced identical manifest and asset bytes |
| TypeScript | `npm --prefix web run typecheck` and build's embedded check | Pass |
| Static production build | `npm --prefix web run build` | Pass; relative assets; manifest generated after Vite |
| Unit/encoding tests | `npm --prefix web run test` | 12 tests pass |
| Exported browser interactions | `PLAYWRIGHT_BROWSERS_PATH=/tmp/lockup-browsers npm --prefix web run test:browser` | Pass; production served under `/preview/` |
| Live contract reads | `npm --prefix web run check:live` | Pass; see `live-read.json` |
| Manifest/ABI/asset check | `npm --prefix web run check:export` | Pass; two canonical ABI bindings, eight declared assets |
| Dependencies | `npm audit --prefix web --cache /tmp/lockup-npm --json` | Zero reported vulnerabilities; `dependency-audit.json` |
| TickMath parity | Temporary SDK comparison before uninstalling the full SDK | 29,582 inputs match; `tick-parity.json`; 302 retained vectors run in the unit suite |
| Diff/scope/size | `node web/scripts/check-integrity.mjs` | See `integrity.json`; no generated dependency/cache directories in the candidate set |

A complete candidate Git bundle was constructed under exempt `test/scratch/` without changing the protected root `.git`. It measured about 2.86 MB, with an additional 16 KiB reserve for the integrity report update, below the 8 MiB submission limit. The final working tree contains no dependency/cache files in its candidate file inventory.

The full SDK was initially used for TickMath but pulled 263 unnecessary packages and npm reported 21 advisories. The delivered native-bigint adaptation preserves its algorithm and MIT notice, and eliminates those unused dependencies. Browser flows were rerun against the rebuilt final export after that change.

Vite reports a nonfatal main-chunk warning above 500 kB. The final main JavaScript is about 551 kB uncompressed / 169 kB gzip; the whole export is about 608 kB. No third-party font/image requests are made. This is comfortably below both the submission and HTTP asset budgets. The warning is retained, not hidden by increasing its threshold.

## Deployment binding

Supplied deployed source commit: `d7ff4b5f699501f01ea59a76d4c26a95b3b51512`. It was also the initial repository HEAD. Each ABI's bytes were compared using `git show <sourceCommit>:docs/abi/<name>.json | sha256sum` against the working source ABI. Both match:

| Contract | Raw JSON SHA-256 | Handoff canonical Keccak |
| --- | --- | --- |
| Lockup | `dfb923ed162a72a7080d494057b094f0aea7e044a1cb4832663c2deb938299d7` | `e75f4b333b33f3fadd1612627173fceac468caac46414924c376baf842e5458c` |
| LiquidityLockupHook | `8cf185876dc3c86ea7cf899f6832f2471df70e5ddef75751302644f818ab3f50` | `6f0baa560c314c19e63895c976c453eb78ed3315f231891889799ae1f473e91c` |

Canonical Keccak uses UTF-8 compact JSON with object keys sorted recursively; array order is retained. The build and browser loader both verify these hashes. The contract set/names/addresses/ABI hashes and handoff identifiers are preserved exactly. The network object and add-chain parameters are copied unchanged. The inventory lists all export files other than the manifest itself and is checked against final bytes. The source ABIs were not regenerated from an interface-only fragment or guessed from a block explorer.

`live-read.json` records the actual block, timestamp, pool ID, complete event scan and live StateView result. At the final read the seed position had `113387377674367368214378` liquidity units still locked, while active liquidity was zero. A read-only Chromium visit to the export also succeeded using real public RPCs (`browser-results.json`, `live-desktop.png`). This verifies reads, not a funded swap or removal.

## Interaction coverage

`browser-results.json` lists each completed scenario and measured contrast pair. It uses mocked JSON-RPC responses and an injected EIP-1193 wallet for consequential actions, with an independent live read-only browser visit at the end.

Checked scenarios include:

- Static gateway subpath, runtime manifest and ABI requests; ABI corruption fails closed.
- Repeated Locked events are deduplicated; current StateView liquidity, not historical added deltas, determines the locked total.
- Disconnected and owned-position filters, invalid/missing/valid tokenId lookup, error focus and recovery.
- Missing browser wallet, declined connection, visible wrong-chain state, exact switch → add chain → switch sequence.
- Ownership filtering; locked removal disabled; exact unlock timestamp enabled; ownership transfer after review blocks signing.
- Review cancellation restores focus; locked zero-delta fee collection; full removal with nonzero minimums and payout to the wallet; empty retained NFT still visible with removal disabled.
- Failed simulation never reaches `eth_sendTransaction`; rejected signature never becomes a confirmed transaction; successful mock receipts refresh state and preserve explorer links.
- Native ETH quote/buy has no approval and sends exactly the input amount. LKUP sell has two distinct bounded approvals to the configured Permit2/router, then a zero-ETH swap transaction. Router actions and liquidity actions are decoded/asserted in tests.
- Quote revert clears the prior result; editing amount invalidates the quote; account change resets transaction panels and refreshes ownership/balances.
- Missing contract code and RPC failure disable actions; refresh recovers. Mocked scenarios have no uncaught JavaScript errors, console errors, or failed static resource responses.

Unit tests add slippage bounds and bigint flooring, both swap directions, principal amounts in/below/above a range, tokenId salt identity, exact unlock boundary, no-liquidity/ownership exclusions, range-limit splitting without log gaps, add-chain rejection handling, and retained TickMath vectors.

## Better Interface consolidated review

The supplied workflow section and the core principles of **all six domains** were read before implementation. The document-web-design method was applied to the final source. No other repository text was treated as authorization to change the assignment.

The assigned MCP browser tool could not start: its first navigation returned `EROFS` for `/home/imd/.cache/ms-playwright/b/browser@...`. A foreground Playwright runner with browser binaries under `/tmp/lockup-browsers` provided the permitted fallback, serving `dist/` at `/preview/` and closing the server/browser at completion. Screenshots were opened and visually inspected; observations below are not based on source alone.

| Domain | Coverage | Evidence and limits |
| --- | --- | --- |
| Accessibility | Checked | Native controls, label bindings, semantic headings, status/error roles, disabled states, named direction control, skip link, form-error focus, review focus/return, visible keyboard focus. Axe A/AA: zero violations in connected desktop state, 28 rules passed. Screen-reader sessions, real wallet extension keyboard flow and physical device tests **not verified**. |
| Layout | Checked | Desktop 1440×1100, intermediate 800×1100, mobile 390×900, narrow 320×800; no document horizontal overflow. Full-page captures show stacking and reachable controls. Root text size 200% at 800px checked separately. Native browser zoom, RTL and localization **not verified**. |
| Writing | Checked | Verb-first actions, distinct quote/approve/swap stages, exact unlock dates/UTC, raw-liquidity definition, top-up reset and shared-router explanation, useful empty states and recoverable errors. No added marketing claim of safety or audit. |
| Typography | Checked | Final captions at least 12px, inputs at least 16px, ordered headings, system font stacks, wrapping IDs, exact-value disclosure and tabular counters. Viewed mobile/desktop wrapping. Other OS font substitutions **not verified**. |
| Colors | Checked | Final solid text/background pairs measured from rendered tokens; minimum tested text pair 5.39:1, primary text/page 10.98:1. Light focus is 6.51:1 against white. Light hero focus was keyboard-focused and viewed. Status has words as well as color. Forced-colors rendering **not verified**. Dark theme **not applicable**. |
| UI | Checked | Consistent bordered surfaces and component states, loading/empty/error/disabled/confirmed flows, inline transaction reviews, recovery, focus-return correction. Motion limited to guarded color transitions; browser runs with reduced motion. No overlays, dragging or autoplay; their behavior is **not applicable**. |

### Findings and fixes

Locations refer to the final source; fixes were rebuilt and the affected scenarios rerun.

| Severity / domain | Source | Finding, change and recheck |
| --- | --- | --- |
| Medium / writing | `web/src/chain.ts:25` | An initial browser test showed only viem's generic short error, losing the missing-NFT or revert reason. Nested reason/details now survive formatting; missing tokenId, quote revert and failed-removal simulation messages were rechecked. |
| Medium / typography | `web/src/styles.css:221` and caption/badge rules | Initial caption declarations were as small as 9–11px. Informational captions/badges now have a 12px floor; narrow screenshots were inspected after correction. |
| Medium / accessibility, colors | `web/src/styles.css:1378` | The default blue focus token was inappropriate on the dark hero. The hero link uses the existing light accent token; keyboard focus was inspected in `hero-focus.png` and its computed color asserted. |
| Medium / accessibility | `web/src/App.tsx:671` | Closing an inline review could leave focus on removed content. A saved trigger now receives focus again, with the section heading as fallback. Cancellation is exercised and focus asserted in the browser. |
| Low / typography, writing | `web/src/App.tsx:38` | Default compact notation produced unwieldy millions-of-trillions liquidity strings. Large raw liquidity now uses scientific notation with exact values in details; desktop/mobile display was reviewed. |
| Medium / UI | `web/src/App.tsx:682`, `web/src/chain.ts:254` | An initial list omitted zero-liquidity records. All observed positions now stay in the ledger; ownership is read for retained NFTs, while burned empty NFTs have no owner. Successful mock removal leaves the empty row visible and disabled. |

### Rendered evidence

Files under `docs/frontend/`:

- `desktop.png`: connected mock state with owned locked/unlocked positions.
- `tablet.png`, `mobile.png`, `narrow.png`: full-page responsive states at 800, 390 and 320px; these use mocked chain state.
- `mobile-viewport.png`: readable 390px viewport capture of the introduction.
- `text-200.png`: root-text enlargement at 800px; not native zoom.
- `hero-focus.png`, `keyboard-focus.png`: observed keyboard focus treatments.
- `live-desktop.png`: real public-RPC read-only result, without an injected wallet.

## Remaining limitations

No funded wallet, real approval, real swap, liquidity removal, fee collection, wallet extension UI, reorg/finality stress test, long-lived RPC outage, or very large event history was exercised against the live chain. Mocked interactions establish frontend branching and payload construction, not contract execution with real funds. The pool currently has no active liquidity at its tick, so quotes may revert; that recovery is tested with mocks. Future inclusion time and chain state can invalidate a successful simulation. Receipt timeouts require checking the explorer before retrying.

The complete history is scanned on each refresh; there is no indexer or persistent cache. Pagination bounds displayed rows, and position reads are limited to six concurrent positions, but a sufficiently large history still increases initial read time. The attestation signature and runtime bytecode equivalence to source are outside the browser's checks. No publication/CID/ENS verification has been run. Root design-document placement and a worker Git commit remain prevented by the stated scope/filesystem constraints described above.
