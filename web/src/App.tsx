import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from "react";
import { formatUnits, parseUnits, type Address, type Hash } from "viem";
import {
  loadConfig,
  protocol,
  publicClient,
  type Config,
  type Reader,
} from "./config";
import {
  isEligible,
  lookup,
  message,
  minimum,
  readSnapshot,
  removalAmounts,
  removalData,
  sameAddress,
  send,
  slippageBps,
  swapData,
  switchNetwork,
  verifyDeployment,
  type Position,
  type Snapshot,
  type TxCall,
} from "./chain";

const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
const number = (n: bigint) => n.toLocaleString("en-US");
const compact = (n: bigint) =>
  Intl.NumberFormat("en", {
    notation: n >= 10n ** 15n ? "scientific" : "compact",
    maximumFractionDigits: 3,
  }).format(Number(n));
const amountText = (n: bigint, decimals = 18) => {
  const full = formatUnits(n, decimals);
  if (n > 0n && Number(full) < 0.000001) return "<0.000001";
  return Number(full).toLocaleString("en-US", { maximumFractionDigits: 6 });
};
const date = (timestamp: bigint) =>
  new Date(Number(timestamp) * 1000).toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
    timeZone: "UTC",
  }) + " UTC";
function remaining(until: bigint, timestamp: bigint) {
  const s = Number(until > timestamp ? until - timestamp : 0n);
  if (!s) return "Lock elapsed";
  const days = Math.floor(s / 86400),
    hours = Math.floor((s % 86400) / 3600),
    mins = Math.floor((s % 3600) / 60);
  return days
    ? `${days}d ${hours}h remaining`
    : hours
      ? `${hours}h ${mins}m remaining`
      : `${mins}m ${s % 60}s remaining`;
}
function Explorer({
  c,
  address,
  label,
}: {
  c: Config;
  address: string;
  label?: string;
}) {
  return (
    <a
      className="address"
      href={`${c.d.network.explorer}/address/${address}`}
      target="_blank"
      rel="noreferrer"
      title={address}
    >
      {label ?? short(address)}
      <span aria-hidden="true"> ↗</span>
      <span className="sr-only"> on the block explorer (new tab)</span>
    </a>
  );
}
function ErrorNote({ error }: { error: string }) {
  return error ? (
    <p role="alert" className="error">
      {error}
    </p>
  ) : null;
}

export default function App() {
  const [config, setConfig] = useState<Config>();
  const [error, setError] = useState("");
  const boot = useCallback(async () => {
    setError("");
    try {
      setConfig(await loadConfig());
    } catch (e) {
      setError(message(e));
    }
  }, []);
  useEffect(() => {
    void boot();
  }, [boot]);
  if (!config)
    return (
      <main className="boot">
        <img src="./mark.svg" width="48" height="48" alt="" />
        <h1>Lockup</h1>
        <p role="status">
          {error
            ? "Deployment could not be verified."
            : "Loading the verified deployment…"}
        </p>
        <ErrorNote error={error} />
        {error && <button onClick={() => void boot()}>Retry deployment</button>}
      </main>
    );
  return <Dashboard c={config} />;
}
function Dashboard({ c }: { c: Config }) {
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [walletError, setWalletError] = useState("");
  const [walletBusy, setWalletBusy] = useState(false);
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [verified, setVerified] = useState(false);
  const [loading, setLoading] = useState(false);
  const [readError, setReadError] = useState("");
  const [progress, setProgress] = useState("");
  const [clock, setClock] = useState(Date.now());
  const [txBusy, setTxBusy] = useState(false);
  const [txStatus, setTxStatus] = useState("");
  const [txError, setTxError] = useState("");
  const [txHash, setTxHash] = useState<Hash>();
  const generation = useRef(0);
  const reader = useMemo(
    () =>
      publicClient(
        c,
        account && chainId === c.d.chainId ? window.ethereum : undefined,
      ),
    [c, account, chainId],
  );
  const refresh = useCallback(async () => {
    const id = ++generation.current;
    setLoading(true);
    setReadError("");
    setVerified(false);
    try {
      await verifyDeployment(c, reader);
      const next = await readSnapshot(c, reader, account, (s) => {
        if (id === generation.current) setProgress(s);
      });
      if (id === generation.current) {
        setSnapshot(next);
        setVerified(true);
        setProgress("Pool state updated.");
      }
    } catch (e) {
      if (id === generation.current) {
        setReadError(
          `Pool data unavailable. ${message(e)} Use Refresh pool to retry.`,
        );
        setProgress("");
      }
    } finally {
      if (id === generation.current) setLoading(false);
    }
  }, [c, reader, account]);
  useEffect(() => {
    void refresh();
    const t = setInterval(() => void refresh(), 45_000);
    return () => {
      ++generation.current;
      clearInterval(t);
    };
  }, [refresh]);
  useEffect(() => {
    const t = setInterval(() => setClock(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  useEffect(() => {
    const p = window.ethereum;
    if (!p) return;
    const accounts = (value: Address[]) => {
      setAccount(value[0]);
      setWalletError("");
      setTxStatus("");
    };
    const chains = (value: string) => {
      setChainId(Number(value));
      setWalletError("");
    };
    const disconnected = () => {
      setAccount(undefined);
      setChainId(undefined);
    };
    void Promise.all([
      p.request({ method: "eth_accounts" }),
      p.request({ method: "eth_chainId" }),
    ])
      .then(([a, ch]) => {
        accounts(a);
        chains(ch);
      })
      .catch(() => {});
    p.on?.("accountsChanged", accounts);
    p.on?.("chainChanged", chains);
    p.on?.("disconnect", disconnected);
    return () => {
      p.removeListener?.("accountsChanged", accounts);
      p.removeListener?.("chainChanged", chains);
      p.removeListener?.("disconnect", disconnected);
    };
  }, []);
  async function connect() {
    setWalletError("");
    setWalletBusy(true);
    try {
      if (!window.ethereum)
        throw Error(
          "No browser wallet found. Install or open a browser wallet, then reload this page. You can still read the pool without a wallet.",
        );
      const a = await window.ethereum.request({
        method: "eth_requestAccounts",
      });
      if (!a[0])
        throw Error(
          "No account was shared. Open your wallet and try connecting again.",
        );
      setAccount(a[0]);
      setChainId(
        Number(await window.ethereum.request({ method: "eth_chainId" })),
      );
    } catch (e) {
      setWalletError(message(e));
    } finally {
      setWalletBusy(false);
    }
  }
  async function switchChain() {
    setWalletBusy(true);
    setWalletError("");
    try {
      await switchNetwork(window.ethereum!, c);
      setChainId(
        Number(await window.ethereum!.request({ method: "eth_chainId" })),
      );
    } catch (e) {
      setWalletError(message(e));
    } finally {
      setWalletBusy(false);
    }
  }
  const wrongChain = !!account && chainId !== c.d.chainId;
  const stale = !!snapshot && clock - snapshot.fetchedAt > 90_000;
  const ready =
    !!account && !wrongChain && verified && !loading && !txBusy && !stale;
  async function transact(call: TxCall, before?: () => Promise<void>) {
    if (!ready || !account || !window.ethereum)
      throw Error(
        "Connect on the correct chain and refresh verified pool data before continuing.",
      );
    setTxBusy(true);
    setTxError("");
    setTxHash(undefined);
    setTxStatus("Checking the action…");
    try {
      await before?.();
      await send(c, reader, window.ethereum, account, call, (s, h) => {
        setTxStatus(s);
        if (h) setTxHash(h);
      });
      await refresh();
    } catch (e) {
      setTxError(message(e));
      setTxStatus("Transaction not completed.");
      throw e;
    } finally {
      setTxBusy(false);
    }
  }
  const estimatedNow = snapshot
    ? snapshot.timestamp +
      BigInt(Math.max(0, Math.floor((clock - snapshot.fetchedAt) / 1000)))
    : 0n;
  const lockedTotal = snapshot?.positions.reduce(
    (sum, p) => sum + (p.unlockAt > snapshot.timestamp ? p.liquidity : 0n),
    0n,
  );
  return (
    <>
      <a className="skip" href="#main">
        Skip to content
      </a>
      <header className="site-header wrap">
        <a className="brand" href="#main">
          <img src="./mark.svg" width="36" height="36" alt="" />
          <span>
            Lockup<span className="brand-sub">Liquidity observatory</span>
          </span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#positions">Positions</a>
          <a href="#swap">Swap</a>
          <a href="#about">How it works</a>
        </nav>
        <div className="wallet">
          {account ? (
            <>
              <Explorer c={c} address={account} />
              <button
                className="small"
                onClick={() => setAccount(undefined)}
                disabled={txBusy}
              >
                Disconnect
              </button>
            </>
          ) : (
            <button
              className="primary"
              onClick={() => void connect()}
              disabled={walletBusy}
            >
              {walletBusy ? "Connecting…" : "Connect wallet"}
              <span aria-hidden="true"> ↗</span>
            </button>
          )}
        </div>
      </header>
      <main id="main" className="wrap">
        <div className="network-line">
          <span className="network-dot" aria-hidden="true" />
          {c.d.network.name} testnet <span className="line-separator">/</span>{" "}
          Uniswap v4 <span className="line-separator">/</span> ETH +{" "}
          {c.d.token.symbol}
        </div>
        <ErrorNote error={walletError} />
        {wrongChain && (
          <div className="notice">
            <div>
              <strong>Wallet is on another network</strong>
              <p>
                Reads use {c.d.network.name}. Switch your wallet to enable
                transactions.
              </p>
            </div>
            <button onClick={() => void switchChain()} disabled={walletBusy}>
              {walletBusy ? "Switching…" : `Switch to ${c.d.network.name}`}
            </button>
          </div>
        )}
        <section className="hero" aria-labelledby="title">
          <div>
            <p className="eyebrow">Time is part of the position</p>
            <h1 id="title">
              Liquidity,
              <br />
              on a clock.
            </h1>
            <p className="hero-copy">
              Follow every lock in the ETH / LKUP pool.
              <br className="desktop-break" /> Know when your liquidity is ready
              to move.
            </p>
            <a href="#positions" className="hero-link">
              Explore positions <span aria-hidden="true">↓</span>
            </a>
          </div>
          <div className="lock-rule">
            <div className="rule-heading">
              <span className="outline-lock" aria-hidden="true">
                ⌑
              </span>
              <span>The lock rule</span>
              <span className="rule-tag">Onchain</span>
            </div>
            <div className="duration">
              <span>
                {snapshot ? Number(snapshot.duration / 86400n) : "30"}
              </span>
              <span>
                days
                <br />
                after each add
              </span>
            </div>
            <div className="timeline" aria-hidden="true">
              <i />
              <span />
              <i />
            </div>
            <div className="timeline-labels">
              <span>Add liquidity</span>
              <span>Ready to remove</span>
            </div>
            <p>
              Every top-up restarts the clock.
              <br />
              No admin. No early unlock.
            </p>
          </div>
        </section>
        <section aria-label="Pool overview" className="stats">
          <div className="stat">
            <p>
              Liquidity still locked <span className="unit">L</span>
            </p>
            <strong
              title={
                lockedTotal !== undefined ? number(lockedTotal) : undefined
              }
            >
              {lockedTotal !== undefined ? compact(lockedTotal) : "—"}
            </strong>
            <span>
              {snapshot
                ? `${snapshot.positions.filter((p) => p.unlockAt > snapshot.timestamp && p.liquidity > 0n).length} locked positions · all ranges`
                : "Waiting for verified pool data"}
            </span>
          </div>
          <div className="stat">
            <p>
              Active pool liquidity <span className="unit">L</span>
            </p>
            <strong
              title={snapshot ? number(snapshot.activeLiquidity) : undefined}
            >
              {snapshot ? compact(snapshot.activeLiquidity) : "—"}
            </strong>
            <span>Liquidity at the current tick</span>
          </div>
          <div className="stat">
            <p>
              Pool price <span className="unit">LKUP / ETH</span>
            </p>
            <strong>
              {snapshot
                ? (
                    (Number(snapshot.sqrtPrice) ** 2 / 2 ** 192) *
                    10 **
                      (c.d.network.nativeCurrency.decimals - snapshot.decimals)
                  ).toLocaleString("en-US", { maximumFractionDigits: 2 })
                : "—"}
            </strong>
            <span>{c.d.pool.fee / 10000}% pool fee · no hook fee</span>
          </div>
        </section>
        <div className="sync-line">
          <span className={readError || stale ? "sync-warning" : ""}>
            {loading
              ? "Reading chain…"
              : readError
                ? "Pool read failed · actions disabled"
                : stale
                  ? "Data is stale · refresh to continue"
                  : snapshot
                    ? `Read at block ${number(snapshot.block)} · ${new Date(snapshot.fetchedAt).toLocaleTimeString()}`
                    : "Connecting to public RPC…"}
          </span>
          <button
            className="text-button"
            onClick={() => void refresh()}
            disabled={loading || txBusy}
          >
            {loading ? "Refreshing…" : "Refresh pool"}{" "}
            <span aria-hidden="true">↻</span>
          </button>
        </div>
        <div className="sr-only" role="status">
          {progress}
        </div>
        <ErrorNote error={readError} />
        {(txStatus || txError) && (
          <section className="transaction" aria-label="Transaction status">
            <p role="status">{txStatus}</p>
            <ErrorNote error={txError} />
            {txHash && (
              <a
                href={`${c.d.network.explorer}/tx/${txHash}`}
                target="_blank"
                rel="noreferrer"
              >
                View transaction {short(txHash)} ↗
              </a>
            )}
          </section>
        )}
        <div className="workspace">
          <Positions
            key={`${account}-${chainId}`}
            {...{ c, reader, account, snapshot, estimatedNow, ready, transact }}
          />
          <Swap
            key={`swap-${account}-${chainId}`}
            {...{ c, reader, account, snapshot, ready, transact }}
          />
        </div>
        <section className="about" id="about">
          <div>
            <p className="eyebrow">Understand your position</p>
            <h2>
              A fixed window.
              <br />A visible release.
            </h2>
            <p>
              Lockup records a 30-day lock each time liquidity is added to this
              native-ETH pool. At the unlock time, the position can remove
              liquidity. Swaps and fee collection remain available during the
              lock.
            </p>
          </div>
          <div className="explanations">
            <article>
              <span>01</span>
              <div>
                <h3>Add with PositionManager</h3>
                <p>
                  Use a Uniswap v4 PositionManager client for new positions or
                  top-ups. Each NFT tokenId has an independent lock. Adding is
                  handled outside this page.
                </p>
                <a
                  href="https://developers.uniswap.org/docs/protocols/v4/guides/position-manager"
                  target="_blank"
                  rel="noreferrer"
                >
                  PositionManager guide ↗
                </a>
              </div>
            </article>
            <article>
              <span>02</span>
              <div>
                <h3>Every add resets the window</h3>
                <p>
                  A top-up starts a fresh 30 days for that position. Shared test
                  routers are unsafe: anyone can add to the same key and restart
                  its lock, or remove its liquidity. This page uses only the
                  published PositionManager.
                </p>
              </div>
            </article>
            <article>
              <span>03</span>
              <div>
                <h3>Liquidity is not a token balance</h3>
                <p>
                  “L” is the pool’s raw liquidity unit. Locked liquidity sums
                  current position liquidity across all ranges. Active liquidity
                  includes only the current tick. Neither is an ETH balance or a
                  dollar value.
                </p>
              </div>
            </article>
          </div>
        </section>
        <details className="deployment">
          <summary>
            Deployment & data sources{" "}
            <span>Verified ABI binding · {short(c.d.sourceCommit)}</span>
          </summary>
          <div className="deployment-content">
            <p>
              Configuration and ABIs load from this export’s{" "}
              <a href="./imd-deployment.json">deployment manifest</a>. Reads use
              public RPCs. Code presence and PoolManager bindings are checked
              before actions; this is not an audit.
            </p>
            <dl>
              {c.d.contracts.map((contract) => (
                <div key={contract.name}>
                  <dt>{contract.name}</dt>
                  <dd>
                    <Explorer
                      c={c}
                      address={contract.address}
                      label={contract.address}
                    />
                  </dd>
                </div>
              ))}
              {Object.entries(c.u).map(([name, address]) => (
                <div key={name}>
                  <dt>{name}</dt>
                  <dd>
                    <Explorer c={c} address={address} label={address} />
                  </dd>
                </div>
              ))}
              <div>
                <dt>Pool ID</dt>
                <dd className="mono">{c.poolId}</dd>
              </div>
              <div>
                <dt>Exact locked liquidity</dt>
                <dd>
                  {lockedTotal !== undefined
                    ? number(lockedTotal)
                    : "Unavailable"}{" "}
                  L
                </dd>
              </div>
              <div>
                <dt>RPC endpoints</dt>
                <dd>
                  {c.d.network.rpcUrls.map((url) => (
                    <div key={url}>{url}</div>
                  ))}
                </dd>
              </div>
            </dl>
          </div>
        </details>
      </main>
      <footer className="wrap">
        <span className="footer-brand">
          Lockup <span> / </span> LKUP
        </span>
        <span>Built for transparent liquidity.</span>
        <span>{c.d.network.name} · Test assets only</span>
      </footer>
    </>
  );
}
interface PanelProps {
  c: Config;
  reader: Reader;
  account?: Address;
  snapshot?: Snapshot;
  ready: boolean;
  transact: (call: TxCall, before?: () => Promise<void>) => Promise<void>;
}
function Positions({
  c,
  reader,
  account,
  snapshot,
  estimatedNow,
  ready,
  transact,
}: PanelProps & { estimatedNow: bigint }) {
  const [filter, setFilter] = useState<"all" | "mine">("all");
  const [id, setId] = useState("");
  const [lookupError, setLookupError] = useState("");
  const [looking, setLooking] = useState(false);
  const [found, setFound] = useState<Position>();
  const [selected, setSelected] = useState<{
    p: Position;
    fees: boolean;
    opened: number;
  }>();
  const [slip, setSlip] = useState("0.5");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const review = useRef<HTMLHeadingElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const sectionTitle = useRef<HTMLHeadingElement>(null);
  const [limit, setLimit] = useState(6);
  useEffect(() => {
    if (selected) review.current?.focus();
    else if (returnFocus.current) {
      const target = returnFocus.current;
      (target.isConnected ? target : sectionTitle.current)?.focus();
      returnFocus.current = null;
    }
  }, [selected]);
  const all = snapshot
    ? [...snapshot.positions].sort((a, b) => Number(a.unlockAt - b.unlockAt))
    : [];
  const list = all.filter(
    (p) => filter === "all" || sameAddress(p.owner, account),
  );
  async function search(e: FormEvent) {
    e.preventDefault();
    setLookupError("");
    setFound(undefined);
    if (!/^\d+$/.test(id) || BigInt(id) === 0n || BigInt(id) >= 2n ** 256n) {
      setLookupError(
        "Enter a positive PositionManager tokenId, using digits only.",
      );
      input.current?.focus();
      return;
    }
    if (!snapshot) {
      setLookupError(
        "Pool data must finish loading before lookup. Use Refresh pool if the read failed.",
      );
      return;
    }
    setLooking(true);
    try {
      setFound(await lookup(c, reader, BigInt(id), snapshot));
    } catch (e) {
      setLookupError(message(e));
    } finally {
      setLooking(false);
    }
  }
  function select(p: Position, fees = false) {
    returnFocus.current = document.activeElement as HTMLElement;
    setSelected({ p, fees, opened: Date.now() });
    setError("");
  }
  let min0 = 0n,
    min1 = 0n,
    quoteError = "";
  try {
    if (selected && snapshot && !selected.fees) {
      const amounts = removalAmounts(selected.p, snapshot.sqrtPrice);
      const bps = slippageBps(slip);
      min0 = minimum(amounts[0], bps);
      min1 = minimum(amounts[1], bps);
      if (min0 + min1 === 0n)
        quoteError =
          "This position is too small to remove with a nonzero protected minimum.";
    }
  } catch (e) {
    quoteError = message(e);
  }
  async function confirm() {
    if (!selected || !snapshot || !account) return;
    setBusy(true);
    setError("");
    const p = selected.p,
      fees = selected.fees;
    try {
      if (quoteError) throw Error(quoteError);
      if (Date.now() - selected.opened > 90_000)
        throw Error(
          "This review expired. Cancel and review the position again.",
        );
      const block = await reader.getBlock();
      const data = removalData(c, p, account, min0, min1, fees);
      await transact(
        {
          address: c.u.positionManager,
          abi: protocol.position,
          functionName: "modifyLiquidities",
          args: [data, block.timestamp + 300n],
        },
        async () => {
          const [owner, until, info] = await Promise.all([
            reader.readContract({
              address: c.u.positionManager,
              abi: protocol.position,
              functionName: "ownerOf",
              args: [p.tokenId!],
            }),
            reader.readContract({
              address: c.hook.address,
              abi: c.abis[c.hook.name],
              functionName: "unlockAt",
              args: [c.poolId, p.key],
            }),
            reader.readContract({
              address: c.u.stateView,
              abi: protocol.state,
              functionName: "getPositionInfo",
              args: [c.poolId, p.key],
            }),
          ]);
          if (!sameAddress(owner, account))
            throw Error(
              "This wallet no longer owns the position. Refresh the pool.",
            );
          if (!fees && block.timestamp < (until as bigint))
            throw Error(
              "The position is still locked or was topped up. Refresh to see its new unlock time.",
            );
          if (info[0] !== p.liquidity)
            throw Error(
              "Position liquidity changed. Refresh and review the new amounts.",
            );
        },
      );
      setSelected(undefined);
      setFound(undefined);
    } catch (e) {
      setError(message(e));
    } finally {
      setBusy(false);
    }
  }
  function card(p: Position, lookupResult = false) {
    const owned = sameAddress(p.owner, account),
      locked = snapshot ? snapshot.timestamp < p.unlockAt : true;
    return (
      <article
        className="position-row"
        key={`${lookupResult ? "lookup" : "list"}-${p.key}`}
      >
        <div className="position-top">
          <div className="position-name">
            <span
              className={`position-icon ${locked ? "locked" : "unlocked"}`}
              aria-hidden="true"
            >
              {locked ? "◷" : "✓"}
            </span>
            <div>
              <h3>
                {p.tokenId !== undefined
                  ? `Position #${p.tokenId}`
                  : "Pool seed / router position"}
              </h3>
              <span className="caption">
                {p.tokenId !== undefined
                  ? "PositionManager NFT"
                  : "External position · read only"}
                {owned ? " · Yours" : ""}
              </span>
            </div>
          </div>
          <span className={`badge ${locked ? "" : "available"}`}>
            {p.liquidity === 0n ? "Empty" : locked ? "Locked" : "Unlocked"}
          </span>
        </div>
        <dl className="position-facts">
          <div>
            <dt>Current liquidity</dt>
            <dd title={number(p.liquidity)}>{compact(p.liquidity)} L</dd>
          </div>
          <div>
            <dt>{locked ? "Unlocks" : "Unlocked"}</dt>
            <dd>
              <time
                dateTime={new Date(Number(p.unlockAt) * 1000).toISOString()}
              >
                {date(p.unlockAt)}
              </time>
            </dd>
          </div>
        </dl>
        <div className="position-bottom">
          <span className="countdown">
            {remaining(p.unlockAt, estimatedNow)}
            {locked && estimatedNow >= p.unlockAt
              ? " · waiting for a new block read"
              : ""}
          </span>
          {owned && (
            <div className="row-actions">
              <button
                className="small"
                disabled={!ready || busy}
                onClick={() => select(p, true)}
              >
                Collect fees
              </button>
              <button
                className="small"
                disabled={
                  !ready ||
                  busy ||
                  !snapshot ||
                  !isEligible(p, account, snapshot.timestamp)
                }
                onClick={() => select(p)}
              >
                Remove liquidity
              </button>
            </div>
          )}
        </div>
        {owned && locked && (
          <p className="caption">
            Removal is available from {date(p.unlockAt)} after a fresh chain
            read.
          </p>
        )}
        <details className="position-details">
          <summary>Position details</summary>
          <dl>
            <div>
              <dt>Range</dt>
              <dd>
                Ticks {p.lower} to {p.upper}
              </dd>
            </div>
            <div>
              <dt>Liquidity</dt>
              <dd>{number(p.liquidity)} L</dd>
            </div>
            {p.owner && (
              <div>
                <dt>NFT owner</dt>
                <dd>
                  <Explorer c={c} address={p.owner} label={p.owner} />
                </dd>
              </div>
            )}
            <div>
              <dt>Position key</dt>
              <dd className="mono">{p.key}</dd>
            </div>
            <div>
              <dt>Last add</dt>
              <dd>
                <a
                  href={`${c.d.network.explorer}/tx/${p.eventHash}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  View Locked event transaction ↗
                </a>
              </dd>
            </div>
          </dl>
        </details>
      </article>
    );
  }
  return (
    <section
      id="positions"
      className="positions"
      aria-labelledby="positions-title"
    >
      <div className="section-heading">
        <div>
          <p className="eyebrow">The lock ledger</p>
          <h2 id="positions-title" ref={sectionTitle} tabIndex={-1}>
            Pool positions{" "}
            <span className="count">{snapshot ? all.length : "—"}</span>
          </h2>
        </div>
        <span className="caption">ETH / LKUP</span>
      </div>
      <div className="filter-row" role="group" aria-label="Position filter">
        <button
          aria-pressed={filter === "all"}
          onClick={() => {
            setFilter("all");
            setLimit(6);
          }}
        >
          All positions
        </button>
        <button
          aria-pressed={filter === "mine"}
          onClick={() => {
            setFilter("mine");
            setLimit(6);
          }}
        >
          My positions
        </button>
      </div>
      <form className="lookup-form" onSubmit={search} noValidate>
        <label htmlFor="token-id">Find a PositionManager tokenId</label>
        <div className="input-row">
          <input
            ref={input}
            id="token-id"
            inputMode="numeric"
            autoComplete="off"
            value={id}
            onChange={(e) => {
              setId(e.target.value);
              setLookupError("");
            }}
            placeholder="e.g. 12345"
            aria-invalid={!!lookupError}
            aria-describedby={lookupError ? "lookup-error" : undefined}
          />
          <button disabled={looking}>
            {looking ? "Finding…" : "Find position"}
          </button>
        </div>
        <div id="lookup-error">
          <ErrorNote error={lookupError} />
        </div>
      </form>
      {found && (
        <div className="lookup-result">
          <div className="result-heading">
            <strong>Lookup result</strong>
            <button className="text-button" onClick={() => setFound(undefined)}>
              Clear result
            </button>
          </div>
          {card(
            snapshot?.positions.find((p) => p.key === found.key) ?? found,
            true,
          )}
        </div>
      )}
      {selected && (
        <section className="review" aria-labelledby="review-title">
          <p className="eyebrow">Review before signing</p>
          <h3 id="review-title" ref={review} tabIndex={-1}>
            {selected.fees ? "Collect fees" : "Remove all liquidity"} · #
            {selected.p.tokenId?.toString()}
          </h3>
          <p>
            {selected.fees
              ? "Collect accrued ETH and LKUP fees. Liquidity and its unlock time stay the same."
              : "Decrease this position’s full liquidity and receive ETH and LKUP in your connected wallet. The NFT is retained."}
          </p>
          <p className="caption">Unlock time: {date(selected.p.unlockAt)}</p>
          {!selected.fees && (
            <>
              <label htmlFor="remove-slippage">Removal slippage (%)</label>
              <input
                id="remove-slippage"
                className="short-input"
                inputMode="decimal"
                value={slip}
                onChange={(e) => setSlip(e.target.value)}
                disabled={busy}
              />
              <dl>
                <div>
                  <dt>Minimum ETH</dt>
                  <dd>
                    {formatUnits(min0, c.d.network.nativeCurrency.decimals)}
                  </dd>
                </div>
                <div>
                  <dt>Minimum {snapshot?.symbol}</dt>
                  <dd>
                    {formatUnits(
                      min1,
                      snapshot?.decimals ?? c.d.token.decimals,
                    )}
                  </dd>
                </div>
              </dl>
              <p className="caption">
                Minimums protect principal at the displayed pool price. Accrued
                fees are additional. Review expires after 90 seconds.
              </p>
            </>
          )}
          <ErrorNote error={error || quoteError} />
          <div className="row-actions">
            <button
              onClick={() => void confirm()}
              disabled={!ready || busy || !!quoteError}
            >
              {busy
                ? "Submitting…"
                : selected.fees
                  ? "Confirm fee collection"
                  : "Confirm removal"}
            </button>
            <button onClick={() => setSelected(undefined)} disabled={busy}>
              Cancel
            </button>
          </div>
        </section>
      )}
      {!snapshot ? (
        <div className="empty">
          <span className="empty-mark" aria-hidden="true">
            ◷
          </span>
          <h3>Waiting for the pool</h3>
          <p>
            Positions appear after event history and current liquidity are read.
            If the connection fails, use Refresh pool above.
          </p>
        </div>
      ) : filter === "mine" && !account ? (
        <div className="empty">
          <span className="empty-mark" aria-hidden="true">
            ↗
          </span>
          <h3>Connect to see your positions</h3>
          <p>
            Connect your browser wallet above. Ownership is checked against each
            PositionManager NFT.
          </p>
        </div>
      ) : list.length === 0 ? (
        <div className="empty">
          <span className="empty-mark" aria-hidden="true">
            ◇
          </span>
          <h3>
            {filter === "mine"
              ? "No positions owned by this wallet"
              : "No positions found"}
          </h3>
          <p>
            {filter === "mine"
              ? "Try All positions or look up an NFT tokenId."
              : "Add liquidity with a v4 PositionManager client, then refresh this pool."}
          </p>
        </div>
      ) : (
        <div className="position-list">
          {list.slice(0, limit).map((p) => card(p))}
          {list.length > limit && (
            <button onClick={() => setLimit(limit + 6)}>
              Show more positions ({list.length - limit} remaining)
            </button>
          )}
        </div>
      )}
      <p className="ledger-note">
        Unlocks come from the hook’s latest Locked events. Current liquidity and
        pool price come from StateView.
      </p>
    </section>
  );
}
interface Quote {
  input: bigint;
  output: bigint;
  min: bigint;
  nativeIn: boolean;
  at: number;
  tokenAllowance: bigint;
  routerAllowance: bigint;
  expiration: number;
}
function Swap({ c, reader, account, snapshot, ready, transact }: PanelProps) {
  const [nativeIn, setNativeIn] = useState(true),
    [amount, setAmount] = useState(""),
    [slip, setSlip] = useState("0.5");
  const [quote, setQuote] = useState<Quote>(),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const request = useRef(0);
  const input = useRef<HTMLInputElement>(null);
  useEffect(
    () => () => {
      request.current++;
    },
    [],
  );
  const inputSymbol = nativeIn ? "ETH" : c.d.token.symbol,
    outputSymbol = nativeIn ? c.d.token.symbol : "ETH";
  const inputDecimals = nativeIn
    ? c.d.network.nativeCurrency.decimals
    : (snapshot?.decimals ?? c.d.token.decimals);
  const outputDecimals = nativeIn
    ? (snapshot?.decimals ?? c.d.token.decimals)
    : c.d.network.nativeCurrency.decimals;
  function invalidate() {
    request.current++;
    setQuote(undefined);
    setError("");
  }
  async function getQuote(e?: FormEvent) {
    e?.preventDefault();
    setError("");
    setQuote(undefined);
    const version = ++request.current;
    setBusy(true);
    try {
      if (
        !/^(?:\d+)(?:\.\d+)?$/.test(amount) ||
        (amount.split(".")[1]?.length ?? 0) > inputDecimals
      )
        throw Error(
          `Enter a positive ${inputSymbol} amount with at most ${inputDecimals} decimal places.`,
        );
      const value = parseUnits(amount, inputDecimals),
        bps = slippageBps(slip);
      if (value <= 0n || value >= 2n ** 128n)
        throw Error("The amount is outside the supported range.");
      const balance = nativeIn
        ? snapshot?.nativeBalance
        : snapshot?.tokenBalance;
      if (balance !== undefined && value > balance)
        throw Error(
          `Insufficient ${inputSymbol} balance. Lower the amount and leave ETH for gas.`,
        );
      const zeroForOne = sameAddress(
        nativeIn ? c.d.pool.pairedCurrency : c.token.address,
        c.poolKey.currency0,
      );
      const { result } = await reader.simulateContract({
        address: c.u.quoter,
        abi: protocol.quoter,
        functionName: "quoteExactInputSingle",
        args: [
          {
            poolKey: c.poolKey,
            zeroForOne,
            exactAmount: value,
            hookData: "0x",
          },
        ],
        account,
      });
      const min = minimum(result[0], bps);
      if (min === 0n || min >= 2n ** 128n)
        throw Error(
          "The quote has no usable minimum output. Try another amount.",
        );
      let tokenAllowance = 0n,
        routerAllowance = 0n,
        expiration = 0;
      if (!nativeIn && account) {
        const [token, router] = await Promise.all([
          reader.readContract({
            address: c.token.address,
            abi: c.abis[c.token.name],
            functionName: "allowance",
            args: [account, c.u.permit2],
          }) as Promise<bigint>,
          reader.readContract({
            address: c.u.permit2,
            abi: protocol.permit2,
            functionName: "allowance",
            args: [account, c.token.address, c.u.universalRouter],
          }),
        ]);
        tokenAllowance = token;
        routerAllowance = router[0];
        expiration = router[1];
      }
      if (version === request.current)
        setQuote({
          input: value,
          output: result[0],
          min,
          nativeIn,
          at: Date.now(),
          tokenAllowance,
          routerAllowance,
          expiration,
        });
    } catch (e) {
      if (version === request.current) {
        setError(message(e));
        input.current?.focus();
      }
    } finally {
      if (version === request.current) setBusy(false);
    }
  }
  async function approve(step: 1 | 2) {
    if (!quote || !account) return;
    setBusy(true);
    setError("");
    try {
      const block = await reader.getBlock();
      await transact(
        step === 1
          ? {
              address: c.token.address,
              abi: c.abis[c.token.name],
              functionName: "approve",
              args: [c.u.permit2, quote.input],
            }
          : {
              address: c.u.permit2,
              abi: protocol.permit2,
              functionName: "approve",
              args: [
                c.token.address,
                c.u.universalRouter,
                quote.input,
                Number(block.timestamp) + 1800,
              ],
            },
      );
      setQuote(undefined);
      await getQuote();
    } catch (e) {
      setError(message(e));
    } finally {
      setBusy(false);
    }
  }
  async function swap() {
    if (!quote) return;
    setBusy(true);
    setError("");
    try {
      if (Date.now() - quote.at > 60_000)
        throw Error("Quote expired. Get a new quote before swapping.");
      const block = await reader.getBlock();
      await transact({
        address: c.u.universalRouter,
        abi: protocol.router,
        functionName: "execute",
        args: [
          "0x10",
          [swapData(c, quote.nativeIn, quote.input, quote.min)],
          block.timestamp + 300n,
        ],
        value: quote.nativeIn ? quote.input : 0n,
      });
      setQuote(undefined);
      setAmount("");
    } catch (e) {
      setError(message(e));
    } finally {
      setBusy(false);
    }
  }
  const allowance1 = !!quote && quote.tokenAllowance >= quote.input;
  const allowance2 =
    !!quote &&
    quote.routerAllowance >= quote.input &&
    quote.expiration > Number(snapshot?.timestamp ?? 0n) + 300;
  const fresh = !!quote && Date.now() - quote.at <= 60_000;
  return (
    <aside className="swap-panel" id="swap" aria-labelledby="swap-title">
      <div className="section-heading">
        <div>
          <p className="eyebrow">Trade the pool</p>
          <h2 id="swap-title">Swap</h2>
        </div>
        <span className="badge">{c.d.network.name}</span>
      </div>
      <p className="swap-intro">
        The lock applies to liquidity.
        <br />
        You can swap at any time.
      </p>
      <form onSubmit={getQuote} noValidate>
        <label htmlFor="swap-amount">You pay</label>
        <div className="amount-field">
          <input
            ref={input}
            id="swap-amount"
            inputMode="decimal"
            autoComplete="off"
            placeholder="0.00"
            value={amount}
            disabled={busy}
            onChange={(e) => {
              invalidate();
              setAmount(e.target.value);
            }}
            aria-invalid={!!error}
            aria-describedby="swap-error"
          />
          <strong>{inputSymbol}</strong>
        </div>
        <div className="balance-line">
          Balance:{" "}
          {account && snapshot
            ? amountText(
                (nativeIn ? snapshot.nativeBalance : snapshot.tokenBalance) ??
                  0n,
                inputDecimals,
              )
            : "—"}{" "}
          {inputSymbol}
        </div>
        <button
          type="button"
          className="reverse"
          onClick={() => {
            invalidate();
            setNativeIn(!nativeIn);
            setAmount("");
          }}
          disabled={busy}
          aria-label={`Switch to paying ${outputSymbol}`}
        >
          ↓↑
        </button>
        <div className="receive">
          <span>You receive · estimated</span>
          <div>
            <strong>
              {quote ? amountText(quote.output, outputDecimals) : "—"}
            </strong>
            <b>{outputSymbol}</b>
          </div>
        </div>
        <div className="slippage">
          <label htmlFor="swap-slippage">Slippage tolerance</label>
          <div>
            <input
              id="swap-slippage"
              inputMode="decimal"
              value={slip}
              disabled={busy}
              onChange={(e) => {
                invalidate();
                setSlip(e.target.value);
              }}
            />
            <span>%</span>
          </div>
        </div>
        <button
          className="quote-button"
          disabled={!snapshot || busy || (!ready && !!account)}
        >
          {busy ? "Working…" : "Get quote"}
        </button>
      </form>
      <div id="swap-error">
        <ErrorNote error={error} />
      </div>
      {quote && (
        <div className="quote">
          <dl>
            <div>
              <dt>Minimum received</dt>
              <dd title={formatUnits(quote.min, outputDecimals)}>
                {amountText(quote.min, outputDecimals)} {outputSymbol}
              </dd>
            </div>
            <div>
              <dt>Quote rate</dt>
              <dd>
                1 {inputSymbol} ≈{" "}
                {(
                  Number(formatUnits(quote.output, outputDecimals)) /
                  Number(formatUnits(quote.input, inputDecimals))
                ).toLocaleString("en-US", { maximumSignificantDigits: 6 })}{" "}
                {outputSymbol}
              </dd>
            </div>
            <div>
              <dt>Quote status</dt>
              <dd>
                {fresh ? "Valid for 60 seconds" : "Expired · get a new quote"}
              </dd>
            </div>
          </dl>
          {!nativeIn && (
            <div className="approval-steps">
              <p>
                Approve only {amountText(quote.input, inputDecimals)}{" "}
                {inputSymbol}. Each step is a separate transaction.
              </p>
              <button
                disabled={!ready || busy || allowance1}
                onClick={() => void approve(1)}
              >
                {allowance1
                  ? "1. Permit2 allowance ready"
                  : "1. Approve LKUP for Permit2"}
              </button>
              <button
                disabled={!ready || busy || !allowance1 || allowance2}
                onClick={() => void approve(2)}
              >
                {allowance2
                  ? "2. Router allowance ready"
                  : "2. Allow router for 30 minutes"}
              </button>
            </div>
          )}
          <button
            className="primary swap-submit"
            disabled={
              !ready ||
              busy ||
              !fresh ||
              (!nativeIn && (!allowance1 || !allowance2))
            }
            onClick={() => void swap()}
          >
            Swap {inputSymbol} for {outputSymbol}
          </button>
        </div>
      )}
      {!account && (
        <p className="caption centered">Connect a wallet to approve or swap.</p>
      )}
      <div className="swap-footnote">
        <span aria-hidden="true">↳</span>
        <p>
          Quoted by Uniswap v4. Simulated before signing.{" "}
          {nativeIn
            ? "Native ETH needs no token approval."
            : "Token swaps use Permit2 and the Universal Router."}{" "}
          Network gas is additional.
        </p>
      </div>
    </aside>
  );
}
