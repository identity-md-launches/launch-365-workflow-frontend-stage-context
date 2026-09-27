import { readFile, writeFile, readdir, mkdir, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { resolve, relative } from "node:path";
import { keccak256, stringToHex } from "viem";

const root = fileURLToPath(new URL("../../", import.meta.url));
const readJson = async (p) =>
  JSON.parse(await readFile(resolve(root, p), "utf8"));
export const canonical = (v) =>
  Array.isArray(v)
    ? v.map(canonical)
    : v !== null && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, canonical(v[k])]),
        )
      : v;
const handoff = await readJson("web/config/deployment.json");
const { network, walletAddChain } = await readJson("web/config/network.json");
if (
  handoff.chainId !== network.chainId ||
  Number(walletAddChain.chainId) !== handoff.chainId
)
  throw Error("Network mismatch");
const checking = process.argv.includes("--check");
const contracts = [];
await mkdir(resolve(root, "dist/abi"), { recursive: true });
for (const contract of handoff.contracts) {
  if (!/^[A-Za-z0-9_]+$/.test(contract.name))
    throw Error("Unsafe contract name");
  const raw = await readFile(resolve(root, `docs/abi/${contract.name}.json`));
  const abi = JSON.parse(raw);
  const hash = keccak256(stringToHex(JSON.stringify(canonical(abi)))).slice(2);
  if (!Array.isArray(abi) || hash !== contract.abiHash)
    throw Error(`ABI hash mismatch: ${contract.name} (${hash})`);
  const abiPath = `abi/${contract.name}.json`;
  if (checking) {
    if (!(await readFile(resolve(root, "dist", abiPath))).equals(raw))
      throw Error(`Export ABI differs: ${abiPath}`);
  } else await writeFile(resolve(root, "dist", abiPath), raw);
  contracts.push({
    name: contract.name,
    address: contract.address,
    abiHash: contract.abiHash,
    abiPath,
  });
}
const assets = [];
async function walk(dir) {
  for (const item of (await readdir(dir, { withFileTypes: true })).sort(
    (a, b) => a.name.localeCompare(b.name),
  )) {
    const path = resolve(dir, item.name);
    if (item.isSymbolicLink()) throw Error("Symlinks forbidden in export");
    if (item.isDirectory()) await walk(path);
    else {
      const rel = relative(resolve(root, "dist"), path).replaceAll("\\", "/");
      if (rel === "imd-deployment.json") continue;
      if ((await stat(path)).size > 8388608)
        throw Error(`Oversize asset ${rel}`);
      assets.push({
        path: rel,
        sha256: createHash("sha256")
          .update(await readFile(path))
          .digest("hex"),
      });
    }
  }
}
await walk(resolve(root, "dist"));
assets.sort((a, b) => a.path.localeCompare(b.path));
if (assets.length > 128 || !assets.some((a) => a.path === "index.html"))
  throw Error("Asset count / entrypoint invalid");
const manifest = {
  version: 1,
  launchId: handoff.launchId,
  chainId: handoff.chainId,
  sourceCommit: handoff.sourceCommit,
  attestationHash: handoff.attestationHash,
  contracts,
  assets,
  network,
  walletAddChain,
  pool: handoff.manifest.pool,
  token: handoff.manifest.token,
  hook: { contract: handoff.manifest.hook.contract },
  deploymentBlock: Math.min(...handoff.contracts.map((c) => c.blockNumber)),
};
const output = JSON.stringify(manifest, null, 2) + "\n";
if (checking) {
  if (
    (await readFile(resolve(root, "dist/imd-deployment.json"), "utf8")) !==
    output
  )
    throw Error("Stale manifest");
} else await writeFile(resolve(root, "dist/imd-deployment.json"), output);
console.log(
  `${checking ? "Verified" : "Emitted"} manifest; ${contracts.length} canonical ABI hashes, ${assets.length} assets.`,
);
