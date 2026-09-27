import {
  BaseError,
  ContractFunctionRevertedError,
  createWalletClient,
  custom,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbiParameters,
  toHex,
  type Address,
  type Hash,
  type Hex,
  type Abi,
} from "viem";
import { sqrtRatioAtTick } from "./tickMath";
import {
  poolTuple,
  protocol,
  type Config,
  type Reader,
  type Provider,
} from "./config";

export function message(error: unknown): string {
  const e = error as {
    code?: number;
    shortMessage?: string;
    message?: string;
    cause?: unknown;
  };
  if (e?.code === 4001 || /rejected|denied/i.test(e?.message ?? ""))
    return "Request declined in your wallet. You can try again when ready.";
  // Viem's shortMessage can hide the RPC or contract revert reason in a nested cause.
  let detail = "",
    cause = error as any;
  for (let depth = 0; cause && depth < 8; depth++, cause = cause.cause) {
    if (typeof cause.reason === "string") detail = cause.reason;
    else if (typeof cause.details === "string") detail = cause.details;
  }
  const summary =
    e?.shortMessage ||
    e?.message ||
    "The request failed. Check your connection and try again.";
  return `${summary}${detail && !summary.includes(detail) ? ` ${detail}` : ""}`.slice(
    0,
    700,
  );
}
export const sameAddress = (a?: string, b?: string) =>
  !!a && !!b && a.toLowerCase() === b.toLowerCase();
export const positionKey = (
  sender: Address,
  lower: number,
  upper: number,
  salt: Hex,
) =>
  keccak256(
    encodePacked(
      ["address", "int24", "int24", "bytes32"],
      [sender, lower, upper, salt],
    ),
  );
export interface Position {
  key: Hex;
  sender: Address;
  lower: number;
  upper: number;
  salt: Hex;
  tokenId?: bigint;
  liquidity: bigint;
  unlockAt: bigint;
  owner?: Address;
  eventHash: Hash;
  blockNumber: bigint;
}
export interface Snapshot {
  block: bigint;
  timestamp: bigint;
  fetchedAt: number;
  sqrtPrice: bigint;
  tick: number;
  activeLiquidity: bigint;
  duration: bigint;
  positions: Position[];
  lockedLiquidity: bigint;
  decimals: number;
  symbol: string;
  tokenBalance?: bigint;
  nativeBalance?: bigint;
}
export async function verifyDeployment(c: Config, client: Reader) {
  if ((await client.getChainId()) !== c.d.chainId)
    throw Error(
      "RPC chain ID differs from the deployment. Actions are disabled.",
    );
  const addresses = [
    ...c.d.contracts.map((x) => x.address),
    ...Object.values(c.u),
  ];
  await Promise.all(
    addresses.map(async (address) => {
      const code = await client.getCode({ address });
      if (!code || code === "0x")
        throw Error(`No deployed code at ${address}. Actions are disabled.`);
    }),
  );
  for (const address of [c.hook.address, c.u.positionManager, c.u.stateView]) {
    const manager = await client.readContract({
      address,
      abi: protocol.manager,
      functionName: "poolManager",
    });
    if (!sameAddress(manager, c.u.poolManager))
      throw Error(
        `PoolManager binding differs at ${address}. Actions are disabled.`,
      );
  }
}
// Bound each log request and split ranges when public providers impose smaller limits.
export async function scanLocks(
  c: Config,
  client: Reader,
  end: bigint,
  progress?: (s: string) => void,
) {
  const event = c.abis[c.hook.name].find(
    (x) => x.type === "event" && x.name === "Locked",
  );
  if (!event || event.type !== "event")
    throw Error("Locked event missing from the verified ABI.");
  const all = [];
  let start = BigInt(c.d.deploymentBlock),
    span = 45000n;
  while (start <= end) {
    const toBlock = start + span - 1n < end ? start + span - 1n : end;
    progress?.(
      `Reading lock events · blocks ${start.toLocaleString()}–${toBlock.toLocaleString()}`,
    );
    try {
      const logs = await client.getLogs({
        address: c.hook.address,
        event,
        args: { poolId: c.poolId },
        fromBlock: start,
        toBlock,
        strict: true,
      });
      all.push(...logs);
      start = toBlock + 1n;
    } catch (error) {
      if (span <= 100n) throw error;
      span /= 2n;
    }
  }
  return all;
}
export async function readSnapshot(
  c: Config,
  client: Reader,
  account?: Address,
  progress?: (s: string) => void,
): Promise<Snapshot> {
  const block = await client.getBlock();
  const blockNumber = block.number;
  const readHook = (functionName: string, args?: readonly unknown[]) =>
    client.readContract({
      address: c.hook.address,
      abi: c.abis[c.hook.name],
      functionName,
      args,
      blockNumber,
    });
  const [slot, activeLiquidity, duration, decimals, symbol, logs] =
    await Promise.all([
      client.readContract({
        address: c.u.stateView,
        abi: protocol.state,
        functionName: "getSlot0",
        args: [c.poolId],
        blockNumber,
      }),
      client.readContract({
        address: c.u.stateView,
        abi: protocol.state,
        functionName: "getLiquidity",
        args: [c.poolId],
        blockNumber,
      }),
      readHook("LOCK_DURATION"),
      client.readContract({
        address: c.token.address,
        abi: c.abis[c.token.name],
        functionName: "decimals",
        blockNumber,
      }),
      client.readContract({
        address: c.token.address,
        abi: c.abis[c.token.name],
        functionName: "symbol",
        blockNumber,
      }),
      scanLocks(c, client, blockNumber, progress),
    ]);
  if (slot[0] === 0n) throw Error("The configured pool is not initialized.");
  if (Number(decimals) !== c.d.token.decimals || symbol !== c.d.token.symbol)
    throw Error("Token metadata differs from the deployment.");
  const latest = new Map<string, (typeof logs)[number]>();
  for (const log of logs.sort(
    (a, b) =>
      Number(a.blockNumber! - b.blockNumber!) || a.logIndex! - b.logIndex!,
  )) {
    latest.set((log.args as any).positionKey, log);
  }
  const positions: Position[] = [];
  const entries = [...latest.values()];
  // Six positions at a time; do not overwhelm public RPCs for a large pool.
  for (let offset = 0; offset < entries.length; offset += 6) {
    progress?.(
      `Reading current liquidity · ${Math.min(offset + 6, entries.length)} of ${entries.length} positions`,
    );
    positions.push(
      ...(await Promise.all(
        entries.slice(offset, offset + 6).map(async (log) => {
          const a = log.args as {
            positionKey: Hex;
            sender: Address;
            tickLower: number;
            tickUpper: number;
            salt: Hex;
            unlockAt: bigint;
          };
          if (
            positionKey(a.sender, a.tickLower, a.tickUpper, a.salt) !==
            a.positionKey
          )
            throw Error("Lock event position key mismatch.");
          const [info, until] = await Promise.all([
            client.readContract({
              address: c.u.stateView,
              abi: protocol.state,
              functionName: "getPositionInfo",
              args: [c.poolId, a.positionKey],
              blockNumber,
            }),
            readHook("unlockAt", [c.poolId, a.positionKey]),
          ]);
          if (until !== a.unlockAt)
            throw Error(
              "Lock events and hook state disagree. Refresh to scan again.",
            );
          const tokenId = sameAddress(a.sender, c.u.positionManager)
            ? BigInt(a.salt)
            : undefined;
          let owner: Address | undefined;
          if (tokenId !== undefined) {
            try {
              owner = await client.readContract({
                address: c.u.positionManager,
                abi: protocol.position,
                functionName: "ownerOf",
                args: [tokenId],
                blockNumber,
              });
            } catch (error) {
              // A burned NFT remains in the event ledger with zero liquidity.
              // Transport failures must still fail the snapshot, not hide ownership.
              const reverted =
                error instanceof BaseError &&
                error.walk(
                  (cause) => cause instanceof ContractFunctionRevertedError,
                ) instanceof ContractFunctionRevertedError;
              if (info[0] !== 0n || !reverted) throw error;
            }
          }
          return {
            key: a.positionKey,
            sender: a.sender,
            lower: a.tickLower,
            upper: a.tickUpper,
            salt: a.salt,
            tokenId,
            liquidity: info[0],
            unlockAt: until as bigint,
            owner,
            eventHash: log.transactionHash!,
            blockNumber: log.blockNumber!,
          };
        }),
      )),
    );
  }
  const [tokenBalance, nativeBalance] = account
    ? await Promise.all([
        client.readContract({
          address: c.token.address,
          abi: c.abis[c.token.name],
          functionName: "balanceOf",
          args: [account],
          blockNumber,
        }) as Promise<bigint>,
        client.getBalance({ address: account, blockNumber }),
      ])
    : [undefined, undefined];
  return {
    block: blockNumber,
    timestamp: block.timestamp,
    fetchedAt: Date.now(),
    sqrtPrice: slot[0],
    tick: slot[1],
    activeLiquidity,
    duration: duration as bigint,
    positions,
    lockedLiquidity: positions.reduce(
      (sum, p) => sum + (p.unlockAt > block.timestamp ? p.liquidity : 0n),
      0n,
    ),
    decimals: Number(decimals),
    symbol: String(symbol),
    tokenBalance,
    nativeBalance,
  };
}
export async function lookup(
  c: Config,
  client: Reader,
  id: bigint,
  snapshot: Snapshot,
): Promise<Position> {
  const [owner, [key, info]] = await Promise.all([
    client.readContract({
      address: c.u.positionManager,
      abi: protocol.position,
      functionName: "ownerOf",
      args: [id],
    }),
    client.readContract({
      address: c.u.positionManager,
      abi: protocol.position,
      functionName: "getPoolAndPositionInfo",
      args: [id],
    }),
  ]);
  if (
    keccak256(
      encodeAbiParameters(parseAbiParameters(`${poolTuple} key`), [key]),
    ) !== c.poolId
  )
    throw Error(
      "This tokenId belongs to another pool. Enter a PositionManager tokenId from the ETH / LKUP pool.",
    );
  const signed24 = (n: bigint) => Number(BigInt.asIntN(24, n));
  const lower = signed24(info >> 8n),
    upper = signed24(info >> 32n);
  const derived = positionKey(
    c.u.positionManager,
    lower,
    upper,
    toHex(id, { size: 32 }),
  );
  const p = snapshot.positions.find((p) => p.key === derived);
  if (!p)
    throw Error(
      "No Locked event found for this position. Refresh the pool, then retry the tokenId.",
    );
  return { ...p, owner };
}
export function isEligible(
  p: Position,
  account: Address | undefined,
  timestamp: bigint,
) {
  return (
    p.tokenId !== undefined &&
    sameAddress(p.owner, account) &&
    p.liquidity > 0n &&
    timestamp >= p.unlockAt
  );
}
export async function switchNetwork(provider: Provider, c: Config) {
  const chainId = c.d.walletAddChain.chainId;
  try {
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId }],
    });
  } catch (error) {
    const e = error as {
      code?: number;
      message?: string;
      data?: { originalError?: { code?: number } };
    };
    if (
      e.code !== 4902 &&
      e.data?.originalError?.code !== 4902 &&
      !/unknown chain|unrecognized chain|chain.*not.*added/i.test(
        e.message ?? "",
      )
    )
      throw error;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [c.d.walletAddChain],
    });
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId }],
    });
  }
}
export function slippageBps(value: string): bigint {
  if (!/^(?:0|[1-4])(?:\.\d{1,2})?$|^5(?:\.0{1,2})?$/.test(value))
    throw Error(
      "Use slippage from 0.01% to 5%, with at most two decimal places.",
    );
  const bps = BigInt(Math.round(Number(value) * 100));
  if (bps < 1n) throw Error("Slippage must be at least 0.01%.");
  return bps;
}
export const minimum = (amount: bigint, bps: bigint) =>
  (amount * (10000n - bps)) / 10000n;
export function removalAmounts(p: Position, sqrtPrice: bigint) {
  const a = sqrtRatioAtTick(p.lower);
  const b = sqrtRatioAtTick(p.upper);
  const price = sqrtPrice < a ? a : sqrtPrice > b ? b : sqrtPrice;
  return [
    (p.liquidity * (b - price) * (1n << 96n)) / b / price,
    (p.liquidity * (price - a)) / (1n << 96n),
  ] as const;
}
export function removalData(
  c: Config,
  p: Position,
  recipient: Address,
  min0: bigint,
  min1: bigint,
  collectOnly = false,
) {
  if (p.tokenId === undefined)
    throw Error("Only PositionManager NFTs are supported.");
  return encodeAbiParameters(
    parseAbiParameters("bytes actions, bytes[] params"),
    [
      "0x0111",
      [
        encodeAbiParameters(
          parseAbiParameters(
            "uint256 tokenId,uint256 liquidity,uint128 amount0Min,uint128 amount1Min,bytes hookData",
          ),
          [p.tokenId, collectOnly ? 0n : p.liquidity, min0, min1, "0x"],
        ),
        encodeAbiParameters(
          parseAbiParameters(
            "address currency0,address currency1,address recipient",
          ),
          [c.poolKey.currency0, c.poolKey.currency1, recipient],
        ),
      ],
    ],
  );
}
export function swapData(
  c: Config,
  nativeIn: boolean,
  amount: bigint,
  minOut: bigint,
) {
  const input = nativeIn ? c.d.pool.pairedCurrency : c.token.address;
  const output = nativeIn ? c.token.address : c.d.pool.pairedCurrency;
  const zeroForOne = sameAddress(input, c.poolKey.currency0);
  return encodeAbiParameters(
    parseAbiParameters("bytes actions,bytes[] params"),
    [
      "0x060c0f",
      [
        encodeAbiParameters(
          parseAbiParameters(
            `(${poolTuple} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData) swap`,
          ),
          [
            {
              poolKey: c.poolKey,
              zeroForOne,
              amountIn: amount,
              amountOutMinimum: minOut,
              hookData: "0x",
            },
          ],
        ),
        encodeAbiParameters(
          parseAbiParameters("address currency,uint256 amount"),
          [input, amount],
        ),
        encodeAbiParameters(
          parseAbiParameters("address currency,uint256 amount"),
          [output, minOut],
        ),
      ],
    ],
  );
}
export interface TxCall {
  address: Address;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
  value?: bigint;
}
export async function send(
  c: Config,
  client: Reader,
  provider: Provider,
  account: Address,
  call: TxCall,
  status: (s: string, h?: Hash) => void,
) {
  const guard = async () => {
    const [chainId, accounts] = await Promise.all([
      provider.request({ method: "eth_chainId" }),
      provider.request({ method: "eth_accounts" }),
    ]);
    if (Number(chainId) !== c.d.chainId)
      throw Error(`Switch to ${c.d.network.name} before continuing.`);
    if (!sameAddress(accounts[0], account))
      throw Error("Your wallet account changed. Review the action again.");
  };
  await guard();
  status("Verifying deployment and simulating the transaction…");
  await verifyDeployment(c, client);
  const { request } = await client.simulateContract({ ...call, account });
  await guard();
  status("Confirm the transaction in your wallet.");
  const wallet = createWalletClient({
    chain: c.chain,
    transport: custom(provider),
    account,
  });
  const hash = await wallet.writeContract(request);
  status("Transaction submitted. Waiting for confirmation…", hash);
  const receipt = await client.waitForTransactionReceipt({
    hash,
    timeout: 180_000,
  });
  if (receipt.status !== "success")
    throw Error(
      "The transaction reverted onchain. Review the explorer details before retrying.",
    );
  status("Transaction confirmed.", hash);
  return receipt;
}
