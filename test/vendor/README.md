# Test-only upstream dependencies

These ordinary files make the real PositionManager integration self-contained. No submodules,
network access, new remappings, or compiler profile changes are needed for the tests.
Only the transitive Solidity imports of PositionManager and Permit2's deployment helper are included.
The existing repository's v4-core and Solmate are reused. Production sources are unchanged.

Pinned upstream sources:
- [Uniswap/v4-periphery](https://github.com/Uniswap/v4-periphery/tree/9969eec44cfdf07e24b41de47f40276a58401976) at `9969eec44cfdf07e24b41de47f40276a58401976`.
- [Uniswap/permit2](https://github.com/Uniswap/permit2/tree/cc56ad0f3439c502c246fc5cfcc3db92bb8b7219) at `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219`.
- [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/dbb6104ce834628e473d2173bbc9d47f81a9eec3) at `dbb6104ce834628e473d2173bbc9d47f81a9eec3`.

Only import paths were rewritten: `@uniswap/v4-core/` uses the existing `v4-core/`
remapping; vendored dependencies use relative imports. Runtime logic is unchanged.
Upstream licenses and Solidity SPDX identifiers are retained.

`DeployPermit2` is the upstream helper containing precompiled Permit2 runtime. It installs
that runtime at the canonical Permit2 address using `vm.etch`, avoiding Permit2's separate
Solidity 0.8.17/via-IR build requirement. PoolManager, PositionManager, and the hook are
constructed normally; the hook uses mined CREATE2 permission bits. The PositionManager
fixture does not call NFT metadata or WETH wrapping, so its descriptor and WETH addresses
are zero. Token payments use real Permit2 approvals and transfers.

The following SHA-256 hashes identify original bytes before import rewriting (and before
any automatic formatting performed on submission):

- `openzeppelin-contracts/contracts/token/ERC20/IERC20.sol`: `6f2faae462e286e24e091d7718575179644dc60e79936ef0c92e2d1ab3ca3cee`
- `permit2/src/interfaces/IAllowanceTransfer.sol`: `a31c712c5cc8d171818a4225c09011f9ba86b2d5edf6045ac812bab93b6bbb87`
- `permit2/src/interfaces/IEIP712.sol`: `e386407da496dbe874c10a81801c55744fb2922a51389a51c79001422e81e0cd`
- `permit2/src/interfaces/IERC1271.sol`: `ec69c9c80939d613cda408fd05424e0dfa7b1fd76168a1fb6593f4b26b3b3d7b`
- `permit2/src/libraries/SignatureVerification.sol`: `1804b3d7b1183225419ec8ee45daf89174ff3668315d71d28111d5fcc179f8e4`
- `permit2/test/utils/DeployPermit2.sol`: `c1a8b89e6c39377490c3c6f7290e9cd40e59c2156333261955feee34a84d4d41`
- `v4-periphery/src/PositionManager.sol`: `2e3c0043654fea263377c5e09c31344946751c8b8ace60580f5090385d3b4428`
- `v4-periphery/src/base/BaseActionsRouter.sol`: `e3ceda8c5bb24d3e439aef94d004fdce7956439bc74c5c5bcd86e2cb9455e813`
- `v4-periphery/src/base/DeltaResolver.sol`: `f72fc92131cf8fe0d6797ffe50290dbd6f12338a5773ba61847211652527f5f5`
- `v4-periphery/src/base/EIP712_v4.sol`: `5468276540ebe52a5e84dd9b0f45e7af833a0ec17c83a87b8a80c9dde1ea70cb`
- `v4-periphery/src/base/ERC721Permit_v4.sol`: `20ea450546f8904fc2325ecfc096144a46ab946b2543b8f91e9f16ca688e74c8`
- `v4-periphery/src/base/ImmutableState.sol`: `d3ef34f9c00fae08ec1eb24aa341d5d916c4d6d62e6c2118ef4afe9c7470fde5`
- `v4-periphery/src/base/Multicall_v4.sol`: `4abf8420610db70687e200ff315db4d9093a79fe640a3a7c457ce427100ea4e4`
- `v4-periphery/src/base/NativeWrapper.sol`: `8ca41a32e3c8e42866e6486fccd2e805b702cb583bf222c2d2da4bd429a23aa2`
- `v4-periphery/src/base/Notifier.sol`: `71d667d5abb48c1767f177ad781196fccc74e75082021df3630df7574e4a44a8`
- `v4-periphery/src/base/Permit2Forwarder.sol`: `be0db7277904908724b64b31e9a1ed266f96d8e98914b1c5ae43930121708935`
- `v4-periphery/src/base/PoolInitializer_v4.sol`: `142555120536369dcdd8e9ea363945f0babb256048054c9318091c7cb2d80461`
- `v4-periphery/src/base/ReentrancyLock.sol`: `a30c768301d6a3fb9befefd9efeecca7ba22b8bfac5e5e2c891410e14775fb10`
- `v4-periphery/src/base/SafeCallback.sol`: `0c25eef89a860e579d6e26f53e32240da787bd75827d7833b6f29e63af87b571`
- `v4-periphery/src/base/UnorderedNonce.sol`: `c64fa82d222e7ab25b37c21660b888a1843a5ed57996f5f010f28ad3a7960bf3`
- `v4-periphery/src/interfaces/IEIP712_v4.sol`: `ee4cc46349cc7f1f894197f368ddea0f71f2564c2962822eead755714f3ba57d`
- `v4-periphery/src/interfaces/IERC721Permit_v4.sol`: `80680771bccd7bf47641417d5a656f950746072766e24703f354e58c2ee0875c`
- `v4-periphery/src/interfaces/IImmutableState.sol`: `86f06a1f388f91ee0185495cb5d2912d564f73fabb163b3767e9c292c5069276`
- `v4-periphery/src/interfaces/IMsgSender.sol`: `cb96ee72c46755a67f9ca304df192365ae7c3923eaab9539f0ce74a88de10cf7`
- `v4-periphery/src/interfaces/IMulticall_v4.sol`: `0c0f4f1cccb7cf63c1ee3dc53e8d48cf867cbff08f5a8f85dd820873277e9481`
- `v4-periphery/src/interfaces/INotifier.sol`: `7fadc8550f73d9ae57925bb27f5ab3a134d4c020972a13683e1121fc11691249`
- `v4-periphery/src/interfaces/IPermit2Forwarder.sol`: `3b28167d65673e7de2bbed1e6f3508350cf889f8439e8680da23ad7586f4cc57`
- `v4-periphery/src/interfaces/IPoolInitializer_v4.sol`: `ca6ecf95cfbc647d49b774801d84c49c8213010771b44555b056118102d644fc`
- `v4-periphery/src/interfaces/IPositionDescriptor.sol`: `ea68397628ff5d386fdfbea48af0556acb537f8d63edccb22d2fa61ac4175cdd`
- `v4-periphery/src/interfaces/IPositionManager.sol`: `439bcd1310f47092a15fa1cc98971898a536eaaff91ac397d8b12eee3c7d79c1`
- `v4-periphery/src/interfaces/ISubscriber.sol`: `9672e03c964da7cd484df290ad3395b6beacd90adcdd8ea2236f835407fb8e2e`
- `v4-periphery/src/interfaces/IUnorderedNonce.sol`: `12e02d4e7e03a668fc1d493840315b4f2aaee2f366ca677574d37d3811d45701`
- `v4-periphery/src/interfaces/IV4Router.sol`: `a577e593bd1948ffcf9ce26964ae1e47bafcf6dffcd40baeb700bcb902367a53`
- `v4-periphery/src/interfaces/external/IWETH9.sol`: `d6b24fe796517f53292d6679adf173e1f3c1fc0dc5efedfc69fa4955c1a9c058`
- `v4-periphery/src/libraries/ActionConstants.sol`: `8e88393dd8b50b25b818e2f6c246aae5cfe63106b56b6e0609869e599c81ec79`
- `v4-periphery/src/libraries/Actions.sol`: `6e8981fcc1fe709e71f85befa2e8656fac6601a565d8ce677b41cff24a838437`
- `v4-periphery/src/libraries/CalldataDecoder.sol`: `93ee8bc3b166407c3f66227713849ba6560297a0ba4abed8ad6235ec02fc2ed3`
- `v4-periphery/src/libraries/ERC721PermitHash.sol`: `0d692bf7c7806644db1dbea2b2b4dd11151a16090a4bcc2ffcd904e61bcd7c2f`
- `v4-periphery/src/libraries/LiquidityAmounts.sol`: `02d6eaaa62d45ac8170b3668e92a31808d2003b0f8eb821581cb4a028b175b45`
- `v4-periphery/src/libraries/Locker.sol`: `aa0481cc66c87ab579438728dbeaee5bf351eac37e4876f0ab899d8c7f7bdbeb`
- `v4-periphery/src/libraries/PathKey.sol`: `0c00bae5a64829334a0b5d5541807faf7d18dff5a667cd74cadf9effaf5f0885`
- `v4-periphery/src/libraries/PositionInfoLibrary.sol`: `6abfa1c06d62753d177df1a4ce7af8028ea3724943ca8673f7083c1cf09bc4d9`
- `v4-periphery/src/libraries/SlippageCheck.sol`: `2f106f2f4773b8d7ef8c2364a95074ceb07ec2c80d38a7751e80fdfc9996ec02`
