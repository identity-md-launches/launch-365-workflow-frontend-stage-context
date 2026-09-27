import {
  createPublicClient,
  defineChain,
  fallback,
  http,
  custom,
  keccak256,
  stringToHex,
  encodeAbiParameters,
  parseAbi,
  parseAbiParameters,
  type Abi,
  type Address,
  type EIP1193Provider,
  type Hex,
} from "viem";

export interface Deployment {
  version: 1;
  launchId: string;
  chainId: number;
  sourceCommit: string;
  attestationHash: string;
  contracts: {
    name: string;
    address: Address;
    abiHash: string;
    abiPath: string;
  }[];
  assets: { path: string; sha256: string }[];
  network: {
    chainId: number;
    name: string;
    testnet: boolean;
    rpcUrls: string[];
    explorer: string;
    nativeCurrency: { name: string; symbol: string; decimals: number };
    faucets: string[];
    uniswapV4: Record<
      | "poolManager"
      | "positionManager"
      | "stateView"
      | "universalRouter"
      | "quoter"
      | "permit2",
      Address
    >;
  };
  walletAddChain: {
    chainId: Hex;
    chainName: string;
    rpcUrls: string[];
    nativeCurrency: { name: string; symbol: string; decimals: number };
    blockExplorerUrls: string[];
  };
  pool: {
    pairedCurrency: Address;
    fee: number;
    tickSpacing: number;
    initialPrice: string;
  };
  token: { contract: string; name: string; symbol: string; decimals: number };
  hook: { contract: string };
  deploymentBlock: number;
}
export type Provider = EIP1193Provider & {
  on?: (event: string, listener: (...args: any[]) => void) => void;
  removeListener?: (event: string, listener: (...args: any[]) => void) => void;
};
declare global {
  interface Window {
    ethereum?: Provider;
  }
}
export const poolTuple =
  "(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
export const poolParams = parseAbiParameters(`${poolTuple} poolKey`);
export const protocol = {
  manager: parseAbi(["function poolManager() view returns (address)"]),
  state: parseAbi([
    "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
    "function getLiquidity(bytes32 poolId) view returns (uint128)",
    "function getPositionInfo(bytes32 poolId,bytes32 positionId) view returns (uint128 liquidity,uint256 feeGrowthInside0LastX128,uint256 feeGrowthInside1LastX128)",
  ]),
  position: parseAbi([
    "function ownerOf(uint256 tokenId) view returns (address)",
    `function getPoolAndPositionInfo(uint256 tokenId) view returns (${poolTuple} poolKey,uint256 info)`,
    "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  ]),
  quoter: parseAbi([
    `function quoteExactInputSingle((${poolTuple} poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) params) returns (uint256 amountOut,uint256 gasEstimate)`,
  ]),
  router: parseAbi([
    "function execute(bytes commands,bytes[] inputs,uint256 deadline) payable",
  ]),
  permit2: parseAbi([
    "function allowance(address user,address token,address spender) view returns (uint160 amount,uint48 expiration,uint48 nonce)",
    "function approve(address token,address spender,uint160 amount,uint48 expiration)",
  ]),
};
export const canonical = (v: unknown): unknown =>
  Array.isArray(v)
    ? v.map(canonical)
    : v !== null && typeof v === "object"
      ? Object.fromEntries(
          Object.entries(v)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([k, v]) => [k, canonical(v)]),
        )
      : v;
export const abiHash = (abi: unknown) =>
  keccak256(stringToHex(JSON.stringify(canonical(abi)))).slice(2);
export const safePath = (path: string) =>
  !!path &&
  !path.startsWith("/") &&
  !path.includes("\\") &&
  !path.includes(":") &&
  path.split("/").every((p) => p !== ".." && p !== "." && p !== "");
export function context(d: Deployment, abis: Record<string, Abi>) {
  const token = d.contracts.find((c) => c.name === d.token.contract);
  const hook = d.contracts.find((c) => c.name === d.hook.contract);
  if (
    !token ||
    !hook ||
    d.chainId !== d.network.chainId ||
    Number(d.walletAddChain.chainId) !== d.chainId
  )
    throw Error("Deployment configuration is inconsistent.");
  const currencies = [d.pool.pairedCurrency, token.address].sort((a, b) =>
    BigInt(a) < BigInt(b) ? -1 : 1,
  );
  const poolKey = {
    currency0: currencies[0],
    currency1: currencies[1],
    fee: d.pool.fee,
    tickSpacing: d.pool.tickSpacing,
    hooks: hook.address,
  };
  const poolId = keccak256(encodeAbiParameters(poolParams, [poolKey]));
  const chain = defineChain({
    id: d.chainId,
    name: d.network.name,
    nativeCurrency: d.network.nativeCurrency,
    rpcUrls: { default: { http: d.network.rpcUrls } },
    testnet: d.network.testnet,
  });
  return {
    d,
    abis,
    token,
    hook,
    poolKey,
    poolId,
    chain,
    u: d.network.uniswapV4,
  };
}
export type Config = ReturnType<typeof context>;
export async function loadConfig(): Promise<Config> {
  const fetchJson = async (path: string) => {
    if (!safePath(path)) throw Error("Unsafe deployment asset path.");
    const response = await fetch(new URL(path, document.baseURI), {
      cache: "no-store",
    });
    if (!response.ok)
      throw Error(
        `Could not load ${path}. Retry after checking the static export.`,
      );
    return response.json();
  };
  const d: Deployment = await fetchJson("imd-deployment.json");
  if (
    d.version !== 1 ||
    !d.network?.rpcUrls.length ||
    !Array.isArray(d.contracts)
  )
    throw Error("Unsupported deployment configuration.");
  const abis = Object.fromEntries(
    await Promise.all(
      d.contracts.map(async (c) => {
        const abi = await fetchJson(c.abiPath);
        if (!Array.isArray(abi) || abiHash(abi) !== c.abiHash)
          throw Error(
            `ABI verification failed for ${c.name}. Actions are disabled.`,
          );
        return [c.name, abi];
      }),
    ),
  );
  return context(d, abis);
}
export function publicClient(c: Config, provider?: Provider) {
  return createPublicClient({
    chain: c.chain,
    batch: { multicall: false },
    transport: fallback(
      [
        ...c.d.network.rpcUrls.map((url) =>
          http(url, { timeout: 12_000, retryCount: 0 }),
        ),
        ...(provider ? [custom(provider, { retryCount: 0 })] : []),
      ],
      { retryCount: 0 },
    ),
  });
}
export type Reader = ReturnType<typeof publicClient>;
