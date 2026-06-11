import { createPublicClient, http, custom } from "viem";
import { mainnet } from "viem/chains";

console.log("NEXT_PUBLIC_RPC_URL set?", !!process.env.NEXT_PUBLIC_RPC_URL);

const client = createPublicClient({ chain: mainnet, transport: http() });
try {
  const bn = await client.getBlockNumber();
  console.log("PUBLIC FALLBACK read OK — mainnet block:", bn.toString());
  const logs = await client.getLogs({ fromBlock: bn - 5n, toBlock: bn });
  console.log("getLogs on public default OK — raw logs in 5-block window:", logs.length);
} catch (e) {
  console.log("PUBLIC FALLBACK read FAILED:", e.shortMessage || e.message);
}

const fakeProvider = {
  request: async ({ method, params }) => {
    const res = await fetch("https://cloudflare-eth.com", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params ?? [] }),
    }).then((r) => r.json());
    if (res.error) throw new Error(res.error.message);
    return res.result;
  },
};
const walletClient = createPublicClient({ chain: mainnet, transport: custom(fakeProvider) });
try {
  const bn2 = await walletClient.getBlockNumber();
  console.log("WALLET (custom provider) read OK — mainnet block:", bn2.toString());
} catch (e) {
  console.log("WALLET (custom provider) read FAILED:", e.shortMessage || e.message);
}
