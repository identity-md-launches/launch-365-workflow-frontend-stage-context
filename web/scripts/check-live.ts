import { readFile, writeFile } from "node:fs/promises";
import { context, publicClient, type Deployment } from "../src/config";
import { readSnapshot, verifyDeployment } from "../src/chain";
const d: Deployment = JSON.parse(
  await readFile(
    new URL("../../dist/imd-deployment.json", import.meta.url),
    "utf8",
  ),
);
const abis = Object.fromEntries(
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
const c = context(d, abis),
  client = publicClient(c);
const evidence: { checkedAt: string; status: string; details: unknown } = {
  checkedAt: new Date().toISOString(),
  status: "not completed",
  details: {},
};
try {
  await verifyDeployment(c, client);
  const snapshot = await readSnapshot(c, client, undefined, console.log);
  evidence.status = "passed";
  evidence.details = {
    snapshot,
    rpcUrls: d.network.rpcUrls,
    poolId: c.poolId,
    checks: [
      "RPC chain ID",
      "Nonempty code at both handoff contracts and all six Uniswap addresses",
      "Hook, StateView, and PositionManager poolManager bindings",
      "StateView pool and position reads",
      "Complete Locked event scan from deployment block",
      "Hook unlockAt matches latest events",
      "Onchain token decimals and symbol",
    ],
    transactionsBroadcast: 0,
  };
} catch (error) {
  evidence.status = "failed";
  evidence.details = String(error);
  process.exitCode = 1;
}
const json =
  JSON.stringify(
    evidence,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  ) + "\n";
await writeFile(
  new URL("../../docs/frontend/live-read.json", import.meta.url),
  json,
);
console.log(json);
