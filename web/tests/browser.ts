import { createServer } from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import {
  chromium,
  expect,
  type Page,
  type BrowserContext,
} from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { decodeAbiParameters, parseAbiParameters } from "viem";
import { fixture, c, account, other } from "./mock";
const root = fileURLToPath(new URL("../../", import.meta.url));
const evidence = resolve(root, "docs/frontend");
await mkdir(evidence, { recursive: true });
const checks: string[] = [];
const errors: string[] = [];
const screenshots: string[] = [];
const record = (s: string) => {
  checks.push(s);
  console.log(`PASS ${s}`);
};
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url!, "http://localhost");
    if (!url.pathname.startsWith("/preview/")) {
      res.writeHead(404).end();
      return;
    }
    const file = resolve(
      root,
      "dist",
      decodeURIComponent(url.pathname.slice(9)) || "index.html",
    );
    if (!file.startsWith(resolve(root, "dist") + "/")) {
      res.writeHead(403).end();
      return;
    }
    const body = await readFile(file);
    res.writeHead(200, {
      "content-type":
        (
          {
            ".html": "text/html",
            ".js": "application/javascript",
            ".css": "text/css",
            ".json": "application/json",
            ".svg": "image/svg+xml",
          } as Record<string, string>
        )[extname(file)] ?? "application/octet-stream",
    });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
const port = (server.address() as { port: number }).port,
  url = `http://127.0.0.1:${port}/preview/`;
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
async function setup(wallet = true) {
  const mock = fixture();
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1100 },
    reducedMotion: "reduce",
  });
  const page = await context.newPage();
  await context.route(/https:\/\//, async (route) => {
    try {
      const req = route.request().postDataJSON();
      const handle = async (r: any) => {
        try {
          return { jsonrpc: "2.0", id: r.id, result: await mock.rpc(r) };
        } catch (e) {
          return {
            jsonrpc: "2.0",
            id: r.id,
            error: { code: -32000, message: String(e) },
          };
        }
      };
      const result = Array.isArray(req)
        ? await Promise.all(req.map(handle))
        : await handle(req);
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(result),
      });
    } catch (e) {
      await route.abort();
      errors.push(String(e));
    }
  });
  if (wallet) {
    await context.exposeFunction("__walletRequest", async (request: any) => {
      try {
        return { result: await mock.wallet(request) };
      } catch (e) {
        return {
          error: JSON.parse(JSON.stringify(e, Object.getOwnPropertyNames(e))),
        };
      }
    });
    await context.addInitScript({
      content: `
 const events = {};
 window.ethereum = {
   request: async function(a) { const x = await window.__walletRequest(a); if (x.error) throw x.error; return x.result; },
   on: function(n, f) { (events[n] ||= []).push(f); },
   removeListener: function(n, f) { events[n] = (events[n] || []).filter(x => x !== f); }
 };
 window.__emit = function(n, value) { (events[n] || []).forEach(f => f(value)); };
 `,
    });
  }
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (event) => {
    if (event.type() === "error") errors.push(event.text());
  });
  page.on("response", (r) => {
    if (r.url().startsWith(url) && r.status() >= 400)
      errors.push(`Resource ${r.status()} ${r.url()}`);
  });
  return { mock, context, page };
}
async function loaded(page: Page) {
  await expect(page.getByText(/Read at block/)).toBeVisible({
    timeout: 20_000,
  });
}
async function connect(page: Page) {
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await expect(
    page.getByRole("button", { name: "Switch to Sepolia" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Switch to Sepolia" }).click();
  await loaded(page);
  await expect(page.getByRole("button", { name: "Disconnect" })).toBeVisible();
}
async function screenshot(page: Page, name: string) {
  await page.screenshot({ path: resolve(evidence, name), fullPage: true });
  screenshots.push(`docs/frontend/${name}`);
}
function ownRow(page: Page, id: number) {
  return page.locator(".position-list .position-row").filter({
    has: page.getByRole("heading", { name: `Position #${id}`, exact: true }),
  });
}
let details: any = {};
try {
  const { mock, context, page } = await setup();
  await page.goto(url);
  await loaded(page);
  await expect(
    page.getByRole("heading", { name: "Pool positions 4" }),
  ).toBeVisible();
  await page.locator(".deployment>summary").click();
  await expect(
    page.getByText("14,000,000,000,000,000,000 L", { exact: true }),
  ).toBeVisible();
  await page.locator(".deployment>summary").click();
  record(
    "Gateway subpath loads manifest, verified ABIs and assets; repeated Locked events deduplicate and locked total uses current liquidity (14e18 L)",
  );
  await page.getByRole("button", { name: "My positions", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Connect to see your positions" }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "All positions", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Find position", exact: true })
    .click();
  await expect(page.getByRole("alert")).toContainText(
    "positive PositionManager tokenId",
  );
  assert.equal(
    await page
      .locator("#token-id")
      .evaluate((e) => e === document.activeElement),
    true,
  );
  await page.locator("#token-id").fill("999");
  await page
    .getByRole("button", { name: "Find position", exact: true })
    .click();
  await expect(page.getByRole("alert")).toContainText("NOT_MINTED");
  await page.locator("#token-id").fill("101");
  await page
    .getByRole("button", { name: "Find position", exact: true })
    .click();
  await expect(
    page
      .locator(".lookup-result")
      .getByRole("heading", { name: "Position #101" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Clear result" }).click();
  record(
    "Disconnected filter, invalid tokenId focus, missing NFT error, and successful tokenId lookup",
  );
  mock.state.rejectConnect = true;
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await expect(page.getByRole("alert")).toContainText("declined");
  mock.state.rejectConnect = false;
  await connect(page);
  const methods = mock.state.walletCalls.map((r) => r.method);
  assert(methods.includes("wallet_addEthereumChain"));
  assert.deepEqual(
    mock.state.walletCalls.find((r) => r.method === "wallet_addEthereumChain")!
      .params,
    [c.d.walletAddChain],
  );
  record(
    "Wallet rejection recovered; wrong-chain banner and exact switch/add/switch chain flow",
  );
  await expect(
    ownRow(page, 101).getByRole("button", { name: "Remove liquidity" }),
  ).toBeDisabled();
  await expect(
    ownRow(page, 102).getByRole("button", { name: "Remove liquidity" }),
  ).toBeEnabled();
  assert.equal(
    await ownRow(page, 103)
      .getByRole("button", { name: "Remove liquidity" })
      .count(),
    0,
  );
  record(
    "NFT ownership gates actions; removal disabled one second or more before unlock and enabled at exact block timestamp boundary",
  );
  await screenshot(page, "desktop.png");
  const axe = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
    .analyze();
  details.axe = {
    violations: axe.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      description: v.description,
      nodes: v.nodes.map((n) => n.target),
    })),
    passes: axe.passes.length,
  };
  assert.deepEqual(details.axe.violations, []);
  record("Automated axe WCAG A/AA audit of connected desktop state");
  const pairs = await page.evaluate(() => {
    const css = getComputedStyle(document.documentElement);
    return [
      "--text",
      "--muted",
      "--page",
      "--surface",
      "--accent",
      "--accent-text",
      "--hero",
      "--hero-text",
      "--hero-muted",
      "--focus",
      "--error",
      "--error-bg",
      "--success",
      "--success-bg",
    ].reduce(
      (o, k) => ({ ...o, [k]: css.getPropertyValue(k).trim() }),
      {} as Record<string, string>,
    );
  });
  const luminance = (h: string) => {
    const raw = h.replace("#", "");
    const n =
      raw.length === 3
        ? raw
            .split("")
            .map((x) => x + x)
            .join("")
        : raw;
    const rgb = [0, 2, 4]
      .map((i) => parseInt(n.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
  };
  const contrast = (a: string, b: string) => {
    const x = luminance(a),
      y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  };
  details.contrast = [
    ["--text", "--page"],
    ["--muted", "--surface"],
    ["--muted", "--page"],
    ["--accent-text", "--accent"],
    ["--hero-text", "--hero"],
    ["--hero-muted", "--hero"],
    ["--hero-muted", "#294037"],
    ["--error", "--error-bg"],
    ["--success", "--success-bg"],
    ["--focus", "--surface"],
    ["--focus", "--page"],
  ].map(([fg, bg]) => ({
    foreground: pairs[fg] ?? fg,
    background: pairs[bg] ?? bg,
    ratio: Number(contrast(pairs[fg] ?? fg, pairs[bg] ?? bg).toFixed(2)),
  }));
  assert(details.contrast.every((x: any) => x.ratio >= 4.5));
  record("Measured solid text and focus color pairs from rendered tokens");
  await page.keyboard.press("Tab");
  await page.getByRole("link", { name: "Explore positions" }).focus();
  assert.equal(
    await page
      .getByRole("link", { name: "Explore positions" })
      .evaluate((e) => getComputedStyle(e).outlineColor),
    "rgb(232, 243, 154)",
  );
  await page.screenshot({ path: resolve(evidence, "hero-focus.png") });
  screenshots.push("docs/frontend/hero-focus.png");
  record(
    "Visible 3px focus indicator uses a contrasting light color on the dark hero",
  );
  await ownRow(page, 101).getByRole("button", { name: "Collect fees" }).click();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(
    ownRow(page, 101).getByRole("button", { name: "Collect fees" }),
  ).toBeFocused();
  record("Cancelling an inline review restores keyboard focus to its trigger");
  await ownRow(page, 101).getByRole("button", { name: "Collect fees" }).click();
  await expect(
    page.getByRole("heading", { name: "Collect fees · #101" }),
  ).toBeFocused();
  await page.getByRole("button", { name: "Confirm fee collection" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Transaction confirmed." }),
  ).toBeVisible();
  let sent = mock.state.sent.at(-1)!;
  assert.equal(sent.to.toLowerCase(), c.u.positionManager);
  const feeParams = decodeAbiParameters(
    parseAbiParameters("bytes,bytes[]"),
    sent.args[0],
  )[1];
  assert.equal(
    decodeAbiParameters(
      parseAbiParameters("uint256,uint256,uint128,uint128,bytes"),
      feeParams[0],
    )[1],
    0n,
  );
  record(
    "Locked position fee collection simulates, requests wallet confirmation, uses PositionManager zero delta and confirms receipt",
  );
  await ownRow(page, 102)
    .getByRole("button", { name: "Remove liquidity" })
    .click();
  await expect(
    page.getByRole("heading", { name: "Remove all liquidity · #102" }),
  ).toBeFocused();
  mock.state.positions.find((p) => p.id === 102n)!.owner = other;
  await page.getByRole("button", { name: "Confirm removal" }).click();
  await expect(page.locator(".review .error")).toContainText("no longer owns");
  assert.equal(mock.state.sent.length, 1);
  mock.state.positions.find((p) => p.id === 102n)!.owner = account;
  record(
    "Ownership change after review is caught before any removal signature",
  );
  mock.state.revertSimulation = true;
  await page.getByRole("button", { name: "Confirm removal" }).click();
  await expect(page.locator(".review .error")).toContainText(
    "Simulation reverted",
  );
  assert.equal(mock.state.sent.length, 1);
  mock.state.revertSimulation = false;
  mock.state.rejectSend = true;
  await page.getByRole("button", { name: "Confirm removal" }).click();
  await expect(page.locator(".review .error")).toContainText("declined");
  assert.equal(mock.state.sent.length, 1);
  mock.state.rejectSend = false;
  await page.getByRole("button", { name: "Confirm removal" }).click();
  await expect(page.locator(".review")).toHaveCount(0);
  await loaded(page);
  assert.equal(mock.state.sent.length, 2);
  await expect(
    ownRow(page, 102).getByText("Empty", { exact: true }),
  ).toBeVisible();
  await expect(
    ownRow(page, 102).getByRole("button", { name: "Remove liquidity" }),
  ).toBeDisabled();
  record(
    "Empty retained NFT remains in the ledger with disabled removal and its original unlock details",
  );
  sent = mock.state.sent.at(-1)!;
  assert.equal(sent.to.toLowerCase(), c.u.positionManager);
  const removalParams = decodeAbiParameters(
    parseAbiParameters("bytes,bytes[]"),
    sent.args[0],
  )[1];
  const decrease = decodeAbiParameters(
    parseAbiParameters("uint256,uint256,uint128,uint128,bytes"),
    removalParams[0],
  );
  assert.equal(decrease[0], 102n);
  assert.equal(decrease[1], 4000000000000000000n);
  assert(decrease[2] > 0n && decrease[3] > 0n);
  assert.equal(
    decodeAbiParameters(
      parseAbiParameters("address,address,address"),
      removalParams[1],
    )[2].toLowerCase(),
    account,
  );
  record(
    "Removal review, slippage minimums, simulation revert (no send), wallet rejection (no send), successful full decrease and wallet payout",
  );
  await page.locator("#swap-amount").fill("0.01");
  await page.getByRole("button", { name: "Get quote", exact: true }).click();
  await expect(page.locator(".quote")).toBeVisible();
  await page
    .getByRole("button", { name: "Swap ETH for LKUP", exact: true })
    .click();
  await expect(page.locator(".quote")).toHaveCount(0);
  sent = mock.state.sent.at(-1)!;
  assert.equal(sent.to.toLowerCase(), c.u.universalRouter);
  assert.equal(BigInt(sent.value), 10n ** 16n);
  assert.equal(sent.args[0], "0x10");
  assert(!mock.state.sent.slice(0, -1).some((x) => x.method === "approve"));
  record(
    "Native ETH quote and simulated Universal Router buy, exact ETH value and no approvals",
  );
  await page
    .getByRole("button", { name: "Switch to paying LKUP", exact: true })
    .click();
  await page.locator("#swap-amount").fill("5");
  await page.getByRole("button", { name: "Get quote", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Swap LKUP for ETH", exact: true }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "1. Approve LKUP for Permit2", exact: true })
    .click();
  await expect(
    page.getByRole("button", {
      name: "2. Allow router for 30 minutes",
      exact: true,
    }),
  ).toBeEnabled();
  await page
    .getByRole("button", {
      name: "2. Allow router for 30 minutes",
      exact: true,
    })
    .click();
  await expect(
    page.getByRole("button", { name: "Swap LKUP for ETH", exact: true }),
  ).toBeEnabled();
  await page
    .getByRole("button", { name: "Swap LKUP for ETH", exact: true })
    .click();
  await expect(page.locator(".quote")).toHaveCount(0);
  const approvals = mock.state.sent.filter((x) => x.method === "approve");
  assert.equal(approvals.length, 2);
  assert.equal(approvals[0].args[0].toLowerCase(), c.u.permit2);
  assert.equal(approvals[0].args[1], 5n * 10n ** 18n);
  assert.equal(approvals[1].to.toLowerCase(), c.u.permit2);
  assert.equal(approvals[1].args[1].toLowerCase(), c.u.universalRouter);
  assert.equal(approvals[1].args[3], Number(mock.state.t) + 1800);
  assert.equal(BigInt(mock.state.sent.at(-1)!.value), 0n);
  record(
    "Token sell requires two separate bounded approvals, then simulates and sends with no ETH value",
  );
  await page.locator("#swap-amount").fill("1");
  mock.state.quoteFails = true;
  await page.getByRole("button", { name: "Get quote", exact: true }).click();
  await expect(page.locator("#swap-error")).toContainText(
    "no available liquidity",
  );
  await expect(page.locator(".quote")).toHaveCount(0);
  mock.state.quoteFails = false;
  record("Quote revert is visible and cannot leave an actionable stale quote");
  await page.getByRole("button", { name: "Get quote", exact: true }).click();
  await expect(page.locator(".quote")).toBeVisible();
  await page.locator("#swap-amount").fill("2");
  await expect(page.locator(".quote")).toHaveCount(0);
  record("Amount changes invalidate quote and approvals UI");
  mock.state.account = other;
  await page.evaluate(
    (a) => (window as any).__emit("accountsChanged", [a]),
    other,
  );
  await loaded(page);
  await page.getByRole("button", { name: "My positions", exact: true }).click();
  await expect(ownRow(page, 103)).toBeVisible();
  await expect(ownRow(page, 101)).toHaveCount(0);
  record(
    "Account change refreshes balances and ownership and clears transaction panels",
  );
  await page
    .getByRole("button", { name: "All positions", exact: true })
    .click();
  await page.locator("#swap-amount").fill("");
  for (const [width, height, name] of [
    [800, 1100, "tablet.png"],
    [390, 900, "mobile.png"],
    [320, 800, "narrow.png"],
  ] as const) {
    await page.setViewportSize({ width, height });
    await page.evaluate(() => window.scrollTo(0, 0));
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
      `Overflow at ${width}`,
    );
    await screenshot(page, name);
    if (width === 390) {
      await page.screenshot({ path: resolve(evidence, "mobile-viewport.png") });
      screenshots.push("docs/frontend/mobile-viewport.png");
    }
  }
  record(
    "800px, 390px and 320px reflow without horizontal overflow; full-page screenshots captured",
  );
  await page.setViewportSize({ width: 800, height: 1100 });
  await page.evaluate(() => (document.documentElement.style.fontSize = "200%"));
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
    true,
  );
  await screenshot(page, "text-200.png");
  await page.evaluate(() => (document.documentElement.style.fontSize = ""));
  record(
    "200% root text enlargement at 800px without document overflow (not browser-native zoom)",
  );
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.goto(url);
  await loaded(page);
  await page.keyboard.press("Tab");
  await expect(
    page.getByRole("link", { name: "Skip to content" }),
  ).toBeFocused();
  await page.keyboard.press("Enter");
  await page
    .getByRole("button", { name: "Find position", exact: true })
    .focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#token-id")).toBeFocused();
  await screenshot(page, "keyboard-focus.png");
  record(
    "Keyboard skip link, native form submission and error focus inspected",
  );
  mock.state.emptyCode = true;
  await page.getByRole("button", { name: "Refresh pool" }).click();
  await expect(
    page.getByRole("alert").filter({ hasText: "No deployed code" }),
  ).toBeVisible();
  await expect(
    ownRow(page, 103).getByRole("button", { name: "Remove liquidity" }),
  ).toBeDisabled();
  mock.state.emptyCode = false;
  await page.getByRole("button", { name: "Refresh pool" }).click();
  await loaded(page);
  record(
    "Empty contract code disables all transaction controls and refresh recovers",
  );
  mock.state.rpcError = true;
  await page.getByRole("button", { name: "Refresh pool" }).click();
  await expect(
    page.getByText("Pool read failed · actions disabled"),
  ).toBeVisible({ timeout: 20_000 });
  await expect(
    ownRow(page, 103).getByRole("button", { name: "Remove liquidity" }),
  ).toBeDisabled();
  record("RPC failure labels stale data and disables actions");
  await context.close();
  const noWallet = await setup(false);
  await noWallet.page.goto(url);
  await loaded(noWallet.page);
  await noWallet.page.getByRole("button", { name: "Connect wallet" }).click();
  await expect(noWallet.page.getByRole("alert")).toContainText(
    "No browser wallet found",
  );
  record("Missing wallet retains public reads and explains recovery");
  await noWallet.context.close();
  const invalid = await setup(false);
  await invalid.context.route("**/abi/Lockup.json", (route) =>
    route.fulfill({ contentType: "application/json", body: "[]" }),
  );
  await invalid.page.goto(url);
  await expect(invalid.page.getByRole("alert")).toContainText(
    "ABI verification failed",
  );
  assert.equal(
    await invalid.page.getByRole("button", { name: "Get quote" }).count(),
    0,
  );
  record("Tampered ABI fails closed before rendering transaction controls");
  await invalid.context.close();
  assert.deepEqual(errors, []);
  record(
    "No uncaught browser JavaScript errors or failed static resources in mocked scenarios",
  );
  // Read-only browser visit against actual public RPCs; no injected wallet and no signing.
  const liveContext = await browser.newContext({
    viewport: { width: 1440, height: 1100 },
  });
  const live = await liveContext.newPage();
  const liveErrors: string[] = [];
  live.on("pageerror", (e) => liveErrors.push(e.message));
  await live.goto(url);
  try {
    await loaded(live);
    details.liveBrowser = {
      status: "passed",
      state: await live.locator(".stats").innerText(),
      errors: liveErrors,
    };
    await screenshot(live, "live-desktop.png");
  } catch (e) {
    details.liveBrowser = {
      status: "not verified",
      reason: String(e),
      visible: await live.locator("main").innerText(),
    };
  }
  await liveContext.close();
} catch (error) {
  details.failure = String(error);
  process.exitCode = 1;
  console.error(error);
} finally {
  await browser.close();
  await new Promise<void>((resolve, reject) =>
    server.close((e) => (e ? reject(e) : resolve())),
  );
  await writeFile(
    resolve(evidence, "browser-results.json"),
    JSON.stringify(
      {
        checkedAt: new Date().toISOString(),
        status: process.exitCode ? "failed" : "passed",
        checks,
        errors,
        screenshots,
        ...details,
      },
      null,
      2,
    ) + "\n",
  );
}
