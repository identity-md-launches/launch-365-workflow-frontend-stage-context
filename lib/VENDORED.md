# Vendored dependencies

All dependencies are committed as ordinary files so the project builds with no network access.
No git submodules. Each library's own `lib/`, tests, CI configuration and git metadata were
removed; only the sources this project compiles or may import remain.

| Directory        | Upstream                                          | Version / commit                                            | Kept                                                 |
| ---------------- | ------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------- |
| `lib/v4-core`    | https://github.com/Uniswap/v4-core                | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (2026-04-02)     | `src/`, `test/utils/` (settler, liquidity math)      |
| `lib/forge-std`  | https://github.com/foundry-rs/forge-std           | `v1.9.7`                                                    | `src/`                                               |
| `lib/solmate`    | https://github.com/transmissions11/solmate        | `main` as of 2026-09-27                                     | `src/` minus tests (`Owned`, `ERC20` used by v4-core) |

Remappings are in `remappings.txt`:

```
forge-std/=lib/forge-std/src/
v4-core/=lib/v4-core/
solmate/=lib/solmate/
```

`lib/v4-core/test/utils/Deployers.sol` was dropped because it imports solmate's test mocks and
OpenZeppelin, neither of which this project needs; `test/utils/LockupTestBase.sol` plays that
role here.
