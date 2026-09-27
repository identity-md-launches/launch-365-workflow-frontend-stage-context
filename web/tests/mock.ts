import { readFile } from "node:fs/promises";
import {
  decodeAbiParameters,
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  parseAbiParameters,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { context, protocol, type Deployment } from "../src/config";
import { positionKey } from "../src/chain";
export const deployment: Deployment = JSON.parse(
  await readFile(
    new URL("../../dist/imd-deployment.json", import.meta.url),
    "utf8",
  ),
);
const abis: Record<string, Abi> = Object.fromEntries(
  await Promise.all(
    deployment.contracts.map(async (c) => [
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
export const c = context(deployment, abis);
export const account = "0x1111111111111111111111111111111111111111" as Address;
export const other = "0x2222222222222222222222222222222222222222" as Address;
export const hash = toHex(31, { size: 32 });
export type Rpc = { method: string; params?: any[] };
export function fixture() {
  const t = BigInt(Math.floor(Date.now() / 1000));
  const start = BigInt(deployment.deploymentBlock),
    block = start + 100n;
  const positions = [
    {
      id: 101n,
      owner: account,
      until: t + 86400n * 12n,
      liquidity: 3000000000000000000n,
      sender: c.u.positionManager,
      lower: -60,
      upper: 60,
    },
    {
      id: 102n,
      owner: account,
      until: t,
      liquidity: 4000000000000000000n,
      sender: c.u.positionManager,
      lower: -60,
      upper: 60,
    },
    {
      id: 103n,
      owner: other,
      until: t - 1000n,
      liquidity: 7000000000000000000n,
      sender: c.u.positionManager,
      lower: -120,
      upper: 120,
    },
    {
      id: 0n,
      owner: other,
      until: t + 2000000n,
      liquidity: 11000000000000000000n,
      sender: other,
      lower: -120,
      upper: 120,
    },
  ].map((p) => ({
    ...p,
    key: positionKey(p.sender, p.lower, p.upper, toHex(p.id, { size: 32 })),
  }));
  const state = {
    chainId: 1,
    account: undefined as Address | undefined,
    knownChain: false,
    block,
    t,
    positions,
    tokenAllowance: 0n,
    routerAllowance: 0n,
    expiration: 0,
    rpcError: false,
    emptyCode: false,
    badBinding: false,
    rejectConnect: false,
    rejectSend: false,
    revertSimulation: false,
    quoteFails: false,
    receiptFails: false,
    quoteDelay: 0,
    calls: [] as Rpc[],
    walletCalls: [] as Rpc[],
    simulations: [] as any[],
    sent: [] as any[],
  };
  const blockObj = () => ({
    number: toHex(state.block),
    hash,
    parentHash: toHex(30, { size: 32 }),
    timestamp: toHex(state.t),
    nonce: "0x0000000000000000",
    sha3Uncles: hash,
    logsBloom: toHex(0, { size: 256 }),
    transactionsRoot: hash,
    stateRoot: hash,
    receiptsRoot: hash,
    miner: other,
    difficulty: "0x0",
    totalDifficulty: "0x0",
    extraData: "0x",
    size: "0x100",
    gasLimit: "0x1c9c380",
    gasUsed: "0x0",
    baseFeePerGas: "0x3b9aca00",
    transactions: [],
    uncles: [],
    mixHash: hash,
  });
  function logs() {
    // Same NFT topped up: only its final event may contribute to the locked total.
    const events = [{ ...positions[0], until: t + 3600n }, ...positions];
    return events.map((p, i) => ({
      address: c.hook.address,
      topics: encodeEventTopics({
        abi: abis[c.hook.name],
        eventName: "Locked",
        args: { poolId: c.poolId, positionKey: p.key, sender: p.sender },
      }),
      data: encodeAbiParameters(
        parseAbiParameters("int24,int24,bytes32,int256,uint256"),
        [
          p.lower,
          p.upper,
          toHex(p.id, { size: 32 }),
          p.liquidity * 2n,
          p.until,
        ],
      ),
      blockNumber: toHex(start + BigInt(i)),
      blockHash: hash,
      transactionHash: toHex(i + 1, { size: 32 }),
      transactionIndex: "0x0",
      logIndex: toHex(i),
      removed: false,
    }));
  }
  const abiFor = (address: string): Abi => {
    const at = address.toLowerCase();
    if (at === c.token.address.toLowerCase()) return abis[c.token.name];
    if (at === c.hook.address.toLowerCase())
      return [...abis[c.hook.name], ...protocol.manager];
    if (at === c.u.stateView.toLowerCase())
      return [...protocol.state, ...protocol.manager];
    if (at === c.u.positionManager.toLowerCase())
      return [...protocol.position, ...protocol.manager];
    if (at === c.u.quoter.toLowerCase()) return protocol.quoter;
    if (at === c.u.permit2.toLowerCase()) return protocol.permit2;
    if (at === c.u.universalRouter.toLowerCase()) return protocol.router;
    throw Error(`Unknown contract ${address}`);
  };
  function execute(tx: any) {
    const abi = abiFor(tx.to),
      decoded = decodeFunctionData({ abi, data: tx.data });
    const args = decoded.args as any[];
    state.sent.push({
      to: tx.to,
      value: tx.value,
      method: decoded.functionName,
      args,
    });
    if (decoded.functionName === "approve") {
      if (tx.to.toLowerCase() === c.token.address.toLowerCase())
        state.tokenAllowance = args[1];
      else {
        state.routerAllowance = args[2];
        state.expiration = args[3];
      }
    }
    if (decoded.functionName === "modifyLiquidities") {
      const [actions, params] = decodeAbiParameters(
        parseAbiParameters("bytes,bytes[]"),
        args[0],
      );
      if (actions !== "0x0111") throw Error("Unsafe liquidity actions");
      const [id, liquidity] = decodeAbiParameters(
        parseAbiParameters("uint256,uint256,uint128,uint128,bytes"),
        params[0],
      );
      const position = positions.find((p) => p.id === id)!;
      if (!position || position.owner !== state.account)
        throw Error("Not NFT owner");
      if (liquidity > 0n && position.until > state.t)
        throw Error("StillLocked");
      position.liquidity -= liquidity;
    }
    return hash;
  }
  async function rpc(request: Rpc): Promise<any> {
    state.calls.push(request);
    const { method, params = [] } = request;
    if (state.rpcError) throw Error("Public RPC unavailable");
    if (method === "eth_chainId") return toHex(deployment.chainId);
    if (method === "eth_getCode") return state.emptyCode ? "0x" : "0x60016000";
    if (method === "eth_blockNumber") return toHex(state.block);
    if (method === "eth_getBlockByNumber") return blockObj();
    if (method === "eth_getBalance") return toHex(10n ** 22n);
    if (method === "eth_getLogs")
      return logs().filter(
        (log) =>
          BigInt(log.blockNumber) >= BigInt(params[0].fromBlock) &&
          BigInt(log.blockNumber) <= BigInt(params[0].toBlock),
      );
    if (method === "eth_getTransactionReceipt")
      return {
        transactionHash: hash,
        transactionIndex: "0x0",
        blockHash: hash,
        blockNumber: toHex(state.block),
        from: account,
        to: state.sent.at(-1)?.to ?? c.u.positionManager,
        cumulativeGasUsed: "0x5208",
        gasUsed: "0x5208",
        contractAddress: null,
        logs: [],
        logsBloom: toHex(0, { size: 256 }),
        status: state.receiptFails ? "0x0" : "0x1",
        effectiveGasPrice: "0x1",
        type: "0x2",
      };
    if (method === "eth_call") {
      const tx = params[0],
        abi = abiFor(tx.to),
        decoded = decodeFunctionData({ abi, data: tx.data });
      const args = (decoded.args ?? []) as any[];
      let result: any;
      switch (decoded.functionName) {
        case "poolManager":
          result = state.badBinding ? other : c.u.poolManager;
          break;
        case "getSlot0":
          result = [1n << 96n, 0, 0, 3000];
          break;
        case "getLiquidity":
          result = 99n * 10n ** 18n;
          break;
        case "LOCK_DURATION":
          result = 2592000n;
          break;
        case "decimals":
          result = 18;
          break;
        case "symbol":
          result = "LKUP";
          break;
        case "balanceOf":
          result = 10n ** 24n;
          break;
        case "getPositionInfo": {
          const p = positions.find((p) => p.key === args[1]);
          if (!p) throw Error("Unknown position");
          result = [p.liquidity, 0n, 0n];
          break;
        }
        case "unlockAt":
          result = positions.find((p) => p.key === args[1])!.until;
          break;
        case "ownerOf": {
          const p = positions.find((p) => p.id === args[0]);
          if (!p) throw Error("NOT_MINTED: no NFT for this tokenId");
          result = p.owner;
          break;
        }
        case "getPoolAndPositionInfo": {
          const p = positions.find((p) => p.id === args[0]);
          if (!p) throw Error("NOT_MINTED");
          result = [
            c.poolKey,
            (BigInt(c.poolId) & ~((1n << 56n) - 1n)) |
              (BigInt.asUintN(24, BigInt(p.upper)) << 32n) |
              (BigInt.asUintN(24, BigInt(p.lower)) << 8n),
          ];
          break;
        }
        case "quoteExactInputSingle":
          if (state.quoteDelay)
            await new Promise((r) => setTimeout(r, state.quoteDelay));
          if (state.quoteFails)
            throw Error("Quote reverted: no available liquidity");
          result = [args[0].exactAmount * 2n, 100000n];
          break;
        case "allowance":
          result =
            tx.to.toLowerCase() === c.token.address.toLowerCase()
              ? state.tokenAllowance
              : [state.routerAllowance, state.expiration, 0];
          break;
        case "approve":
          result =
            tx.to.toLowerCase() === c.token.address.toLowerCase()
              ? true
              : undefined;
          state.simulations.push({
            to: tx.to,
            method: decoded.functionName,
            args,
          });
          break;
        case "execute":
        case "modifyLiquidities":
          if (state.revertSimulation)
            throw Error(
              "Simulation reverted: price moved or position still locked",
            );
          state.simulations.push({
            to: tx.to,
            method: decoded.functionName,
            args,
            value: tx.value,
          });
          result = undefined;
          break;
        default:
          throw Error(`Unhandled call ${decoded.functionName}`);
      }
      return encodeFunctionResult({
        abi,
        functionName: decoded.functionName,
        result,
      });
    }
    throw Error(`Unhandled RPC method: ${method}`);
  }
  async function wallet(request: Rpc): Promise<any> {
    state.walletCalls.push(request);
    const { method, params = [] } = request;
    if (method === "eth_accounts") return state.account ? [state.account] : [];
    if (method === "eth_requestAccounts") {
      if (state.rejectConnect)
        throw { code: 4001, message: "User rejected connection" };
      state.account = account;
      return [account];
    }
    if (method === "eth_chainId") return toHex(state.chainId);
    if (method === "wallet_switchEthereumChain") {
      if (!state.knownChain) throw { code: 4902, message: "Unknown chain" };
      state.chainId = Number(params[0].chainId);
      return null;
    }
    if (method === "wallet_addEthereumChain") {
      state.knownChain = true;
      return null;
    }
    if (method === "eth_sendTransaction") {
      if (state.rejectSend)
        throw { code: 4001, message: "User rejected transaction" };
      return execute(params[0]);
    }
    return rpc(request);
  }
  return { state, rpc, wallet };
}
