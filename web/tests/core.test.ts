import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  decodeAbiParameters,
  parseAbiParameters,
  toHex,
  type Address,
  type Abi,
} from "viem";
import {
  abiHash,
  context,
  poolTuple,
  safePath,
  type Deployment,
  type Reader,
  type Provider,
} from "../src/config";
import {
  isEligible,
  minimum,
  positionKey,
  removalAmounts,
  removalData,
  scanLocks,
  slippageBps,
  swapData,
  switchNetwork,
  type Position,
} from "../src/chain";
const d: Deployment = JSON.parse(
  await readFile(
    new URL("../../dist/imd-deployment.json", import.meta.url),
    "utf8",
  ),
);
const abis: Record<string, Abi> = Object.fromEntries(
  await Promise.all(
    d.contracts.map(async (c) => [
      c.name,
      JSON.parse(
        await readFile(
          new URL(`../../dist/${c.abiPath}`, import.meta.url),
          "utf8",
        ),
      ),
    ]),
  ),
);
const c = context(d, abis);
const owner = "0x0000000000000000000000000000000000001234" as Address;
const p: Position = {
  key: positionKey(c.u.positionManager, -60, 60, toHex(7, { size: 32 })),
  sender: c.u.positionManager,
  lower: -60,
  upper: 60,
  salt: toHex(7, { size: 32 }),
  tokenId: 7n,
  liquidity: 1000000n,
  unlockAt: 1000n,
  owner,
  eventHash: toHex(1, { size: 32 }),
  blockNumber: 1n,
};
test("canonical ABI hashes bind to the exact handoff", () => {
  for (const contract of d.contracts)
    assert.equal(abiHash(abis[contract.name]), contract.abiHash);
});
test("manifest paths cannot escape the gateway subpath", () => {
  for (const path of ["../x", "/abi/x", "https://x", "a\\b", "x/../y", "./x"])
    assert.equal(safePath(path), false);
  assert.equal(safePath("abi/Lockup.json"), true);
});
test("inclusive unlock boundary; token ownership and liquidity are mandatory", () => {
  assert.equal(isEligible(p, owner, 999n), false);
  assert.equal(isEligible(p, owner, 1000n), true);
  assert.equal(isEligible(p, undefined, 1001n), false);
  assert.equal(isEligible({ ...p, tokenId: undefined }, owner, 1001n), false);
  assert.equal(isEligible({ ...p, liquidity: 0n }, owner, 1001n), false);
  assert.equal(isEligible({ ...p, unlockAt: 2000n }, owner, 1001n), false);
});
test("slippage rejects invalid values and floors bigint minimums", () => {
  assert.equal(slippageBps("0.5"), 50n);
  assert.equal(minimum(101n, 100n), 99n);
  for (const s of ["0", "6", "-1", "NaN", "1e2", "0.001"])
    assert.throws(() => slippageBps(s));
});
test("position identity matches packed int24 ticks and tokenId salt", () => {
  assert.notEqual(
    p.key,
    positionKey(c.u.positionManager, -60, 60, toHex(8, { size: 32 })),
  );
  assert.notEqual(p.key, positionKey(owner, -60, 60, p.salt));
});
test("integer removal principal handles both out-of-range sides and balanced range", () => {
  const middle = removalAmounts(p, 1n << 96n);
  assert.equal(middle[0], 2995n);
  assert.equal(middle[1], 2995n);
  const low = removalAmounts(p, 1n);
  assert.equal(low[1], 0n);
  assert(low[0] > 0n);
  const high = removalAmounts(p, 2n ** 159n);
  assert.equal(high[0], 0n);
  assert(high[1] > 0n);
});
test("removal and fee collection target PositionManager NFT and settle to wallet", () => {
  for (const fees of [false, true]) {
    const [actions, params] = decodeAbiParameters(
      parseAbiParameters("bytes,bytes[]"),
      removalData(c, p, owner, 2n, 3n, fees),
    );
    assert.equal(actions, "0x0111");
    assert.deepEqual(
      decodeAbiParameters(
        parseAbiParameters("uint256,uint256,uint128,uint128,bytes"),
        params[0],
      ),
      [7n, fees ? 0n : 1000000n, 2n, 3n, "0x"],
    );
    const payout = decodeAbiParameters(
      parseAbiParameters("address,address,address"),
      params[1],
    );
    assert.equal(payout[2].toLowerCase(), owner);
  }
});
test("native buy and token sell encode the required router actions, directions, minimums", () => {
  for (const nativeIn of [true, false]) {
    const [actions, params] = decodeAbiParameters(
      parseAbiParameters("bytes,bytes[]"),
      swapData(c, nativeIn, 100n, 90n),
    );
    assert.equal(actions, "0x060c0f");
    const [swap] = decodeAbiParameters(
      parseAbiParameters(
        `(${poolTuple} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData)`,
      ),
      params[0],
    );
    assert.equal(swap.zeroForOne, nativeIn);
    assert.equal(swap.amountIn, 100n);
    assert.equal(swap.amountOutMinimum, 90n);
    assert.equal(swap.poolKey.hooks.toLowerCase(), c.hook.address);
    assert.equal(
      decodeAbiParameters(parseAbiParameters("address,uint256"), params[1])[1],
      100n,
    );
  }
});
test("wallet missing chain follows switch → exact add-chain parameters → switch", async () => {
  const calls: any[] = [];
  let first = true;
  const provider = {
    request: async (args: any) => {
      calls.push(args);
      if (first) {
        first = false;
        throw { code: 4902 };
      }
    },
  } as unknown as Provider;
  await switchNetwork(provider, c);
  assert.deepEqual(
    calls.map((x) => x.method),
    [
      "wallet_switchEthereumChain",
      "wallet_addEthereumChain",
      "wallet_switchEthereumChain",
    ],
  );
  assert.deepEqual(calls[1].params, [d.walletAddChain]);
});
test("wallet rejection never initiates add-chain", async () => {
  const methods: string[] = [];
  const provider = {
    request: async ({ method }: any) => {
      methods.push(method);
      throw { code: 4001 };
    },
  } as unknown as Provider;
  await assert.rejects(() => switchNetwork(provider, c));
  assert.equal(methods.length, 1);
});
test("event scan shrinks provider-limited ranges without gaps", async () => {
  const ranges: [bigint, bigint][] = [];
  const start = BigInt(c.d.deploymentBlock),
    end = start + 999n;
  const client = {
    getLogs: async ({ fromBlock, toBlock }: any) => {
      if (toBlock - fromBlock > 200n) throw Error("range limit");
      ranges.push([fromBlock, toBlock]);
      return [];
    },
  } as unknown as Reader;
  await scanLocks(c, client, end);
  assert.equal(ranges[0][0], start);
  assert.equal(ranges.at(-1)![1], end);
  ranges
    .slice(1)
    .forEach((range, i) => assert.equal(range[0], ranges[i][1] + 1n));
});

test("native bigint TickMath matches 302 retained SDK vectors and rejects invalid ticks", async () => {
  const { sqrtRatioAtTick } = await import("../src/tickMath");
  const vectors = JSON.parse(
    await readFile(new URL("./tick-vectors.json", import.meta.url), "utf8"),
  ) as [number, string][];
  for (const [tick, expected] of vectors)
    assert.equal(sqrtRatioAtTick(tick).toString(), expected);
  for (const tick of [887273, -887273, 0.5, NaN, Infinity])
    assert.throws(() => sqrtRatioAtTick(tick));
});
