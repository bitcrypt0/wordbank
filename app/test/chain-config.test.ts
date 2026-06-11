import { describe, it, expect, afterEach, vi } from "vitest";

/**
 * The chain is env-driven (NEXT_PUBLIC_CHAIN_ID): one build serves mainnet,
 * mainnet-fork, and Sepolia. chain.ts + addresses.ts + explorer.ts read the
 * env at module load, so each case resets modules and re-imports.
 */
afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("chain config (env-driven)", () => {
  it("defaults to mainnet when NEXT_PUBLIC_CHAIN_ID is unset", async () => {
    vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "");
    vi.resetModules();
    const chain = await import("@/lib/contracts/chain");
    expect(chain.EXPECTED_CHAIN_ID).toBe(1);
    expect(chain.CHAIN.id).toBe(1);

    const addr = await import("@/lib/contracts/addresses");
    expect(addr.UNISWAP.poolManager.toLowerCase()).toBe("0x000000000004444c5dc75cb358380d2e3de08a90");

    const exp = await import("@/lib/contracts/explorer");
    expect(exp.ETHERSCAN_BASE).toBe("https://etherscan.io/address/");
  });

  it("selects Sepolia + Sepolia Uniswap when NEXT_PUBLIC_CHAIN_ID=11155111", async () => {
    vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "11155111");
    vi.resetModules();
    const chain = await import("@/lib/contracts/chain");
    expect(chain.EXPECTED_CHAIN_ID).toBe(11155111);
    expect(chain.CHAIN.id).toBe(11155111);

    const addr = await import("@/lib/contracts/addresses");
    expect(addr.UNISWAP.poolManager.toLowerCase()).toBe("0xe03a1074c86cfedd5c142c4f04f1a1536e203543");
    expect(addr.UNISWAP.v4Quoter.toLowerCase()).toBe("0x61b3f2011a92d183c7dbadbda940a7555ccf9227");
    expect(addr.UNISWAP.weth9.toLowerCase()).toBe("0xfff9976782d46cc05630d1f6ebab18b2324d6b14");

    const exp = await import("@/lib/contracts/explorer");
    expect(exp.ETHERSCAN_BASE).toBe("https://sepolia.etherscan.io/address/");
  });
});

describe("RPC resolution (wallet → optional public URL → public default)", () => {
  it("PUBLIC_RPC_URL is undefined when NEXT_PUBLIC_RPC_URL is unset/blank", async () => {
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", "");
    vi.resetModules();
    const chain = await import("@/lib/contracts/chain");
    expect(chain.PUBLIC_RPC_URL).toBeUndefined();
    // The read client must still build (chain-default public RPC) with no env.
    expect(() => chain.getPublicClient()).not.toThrow();
    expect(chain.isUsingWalletRpc()).toBe(false);
  });

  it("uses an explicitly set public NEXT_PUBLIC_RPC_URL", async () => {
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", "https://example-public-rpc.invalid");
    vi.resetModules();
    const chain = await import("@/lib/contracts/chain");
    expect(chain.PUBLIC_RPC_URL).toBe("https://example-public-rpc.invalid");
  });

  it("setReadProvider toggles the wallet read path and rebuilds the client", async () => {
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", "");
    vi.resetModules();
    const chain = await import("@/lib/contracts/chain");
    const before = chain.getPublicClient();
    expect(chain.isUsingWalletRpc()).toBe(false);

    const fakeProvider = { request: async () => "0x1" };
    chain.setReadProvider(fakeProvider);
    expect(chain.isUsingWalletRpc()).toBe(true);
    const after = chain.getPublicClient();
    expect(after).not.toBe(before); // cache invalidated → rebuilt with custom()

    chain.setReadProvider(null);
    expect(chain.isUsingWalletRpc()).toBe(false);
  });
});
