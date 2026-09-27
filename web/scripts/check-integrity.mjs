import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  mkdtempSync,
  statSync,
  cpSync,
  lstatSync,
} from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import assert from "node:assert/strict";
const root = fileURLToPath(new URL("../../", import.meta.url));
const git = (args, options = {}) =>
  execFileSync("git", args, { cwd: root, encoding: "utf8", ...options });
const read = (path) => readFileSync(resolve(root, path));
const json = (path) => JSON.parse(read(path));
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const handoff = json("web/config/deployment.json"),
  network = json("web/config/network.json"),
  manifest = json("dist/imd-deployment.json");
for (const key of ["launchId", "chainId", "sourceCommit", "attestationHash"])
  assert.deepEqual(manifest[key], handoff[key]);
assert.deepEqual(manifest.network, network.network);
assert.deepEqual(manifest.walletAddChain, network.walletAddChain);
assert.deepEqual(
  manifest.contracts.map(({ abiPath, ...contract }) => contract),
  handoff.contracts.map(({ name, address, abiHash }) => ({
    name,
    address,
    abiHash,
  })),
);
for (const contract of handoff.contracts) {
  const path = `docs/abi/${contract.name}.json`;
  assert(
    read(path).equals(
      Buffer.from(git(["show", `${handoff.sourceCommit}:${path}`])),
    ),
  );
}
for (const asset of manifest.assets)
  assert.equal(sha(read(`dist/${asset.path}`)), asset.sha256);
const changed = [
  ...git(["diff", "--name-only", "HEAD"]).split("\n"),
  ...git(["ls-files", "--others", "--exclude-standard"]).split("\n"),
].filter(Boolean);
for (const path of changed) {
  assert(/^(web|dist|docs)\//.test(path), `Out-of-scope path: ${path}`);
  assert(
    !path
      .split("/")
      .some((x) => x.startsWith(".") && path !== "web/.gitignore"),
    `Unbudgeted dotfile: ${path}`,
  );
  assert(!/(^|\/)(node_modules|\.cache|\.npm|vendor\/npm)(\/|$)/.test(path));
  assert(!lstatSync(resolve(root, path)).isSymbolicLink());
}
assert(statSync(resolve(root, "web/.gitignore")).size <= 512);
assert(
  !git(["ls-files", "-s"])
    .split("\n")
    .some((x) => x.startsWith("160000 ")),
  "Git submodule found",
);
const candidate = git([
  "ls-files",
  "--cached",
  "--others",
  "--exclude-standard",
  "-z",
])
  .split("\0")
  .filter(Boolean);
const rawBytes = candidate.reduce(
  (sum, path) => sum + statSync(resolve(root, path)).size,
  0,
);
const scratchRoot = resolve(root, "test/scratch");
mkdirSync(scratchRoot, { recursive: true });
const scratch = mkdtempSync(resolve(scratchRoot, "frontend-bundle-"));
const gitDir = resolve(scratch, "candidate.git");
git(["clone", "--bare", "--no-hardlinks", "--quiet", root, gitDir]);
const candidateGit = (args) =>
  git([`--git-dir=${gitDir}`, `--work-tree=${root}`, ...args]);
candidateGit(["read-tree", "HEAD"]);
candidateGit(["add", "--", "web", "dist", "docs"]);
candidateGit(["diff", "--cached", "--check"]);
candidateGit([
  "-c",
  "user.name=Frontend validation",
  "-c",
  "user.email=validation@example.invalid",
  "commit",
  "--quiet",
  "-m",
  "Validate complete frontend submission snapshot",
]);
const bundle = resolve(scratch, "candidate.bundle");
candidateGit(["bundle", "create", bundle, "--all"]);
const bundleBytes = statSync(bundle).size;
// This report is written after the measured bundle; reserve ample bytes for its own final update.
const reportReserve = 16384;
assert(bundleBytes + reportReserve <= 8388608, "Submission would exceed 8 MiB");
const exportBytes = manifest.assets.reduce(
  (sum, a) => sum + read(`dist/${a.path}`).length,
  read("dist/imd-deployment.json").length,
);
assert(exportBytes < 32 * 1024 * 1024);
const report = {
  checkedAt: new Date().toISOString(),
  status: "passed",
  sourceCommit: handoff.sourceCommit,
  manifestSha256: sha(read("dist/imd-deployment.json")),
  abiSourceBytesAtPinnedCommit: "identical",
  networkAndHandoff: "identical",
  exportFilesIncludingManifest: manifest.assets.length + 1,
  exportBytes,
  candidateFileCount: candidate.length,
  candidateRawBytes: rawBytes,
  measuredCompleteGitBundleBytes: bundleBytes,
  finalReportUpdateReserveBytes: reportReserve,
  submissionBudgetBytes: 8388608,
  measurementNote:
    "Bundle constructed in exempt test/scratch from the unchanged repository history plus every candidate web/dist/docs file. The size excludes this report’s final metadata update; the reserve exceeds the entire report size. No write was made to the protected root .git.",
  ignoreFile: {
    path: "web/.gitignore",
    budgetBytes: 512,
    actualBytes: read("web/.gitignore").length,
  },
  changedPaths: changed.sort(),
};
const reportText = JSON.stringify(report, null, 2) + "\n";
assert(Buffer.byteLength(reportText) < reportReserve);
writeFileSync(resolve(root, "docs/frontend/integrity.json"), reportText);
console.log(
  `Verified ${manifest.assets.length} assets, ${exportBytes} export bytes; complete candidate Git bundle ${bundleBytes} bytes + ${reportReserve} report reserve < 8388608.`,
);
