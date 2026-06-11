import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { renderHook, act, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { WalletProvider, useWallet } from "@/lib/wallet/WalletProvider";
import { providerStore } from "@/lib/wallet/eip6963";
import {
  rememberConnection,
  wasConnected,
} from "@/lib/wallet/storage";
import {
  MockEip1193Provider,
  installAnnouncer,
  makeDetail,
} from "./mockProvider";

const wrapper = ({ children }: { children: ReactNode }) => (
  <WalletProvider>{children}</WalletProvider>
);

const cleanups: Array<() => void> = [];

function announce(...details: ReturnType<typeof makeDetail>[]) {
  for (const d of details) cleanups.push(installAnnouncer(d));
}

function mount() {
  return renderHook(() => useWallet(), { wrapper });
}

beforeEach(() => {
  window.localStorage.clear();
  providerStore._reset();
});

afterEach(() => {
  cleanups.splice(0).forEach((fn) => fn());
});

describe("wallet lifecycle", () => {
  it("first visit never auto-connects", async () => {
    const p = new MockEip1193Provider({ authorized: true });
    announce(makeDetail(p));
    const { result } = mount();
    await waitFor(() => expect(result.current.initializing).toBe(false));
    expect(result.current.status).toBe("disconnected");
    expect(result.current.account).toBeNull();
    expect(result.current.providers.length).toBe(1);
  });

  it("explicit connect succeeds (single provider)", async () => {
    const p = new MockEip1193Provider({
      accounts: ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
      chainId: 1,
    });
    announce(makeDetail(p));
    const { result } = mount();
    await waitFor(() => expect(result.current.providers.length).toBe(1));

    await act(async () => {
      await result.current.connect();
    });
    expect(result.current.status).toBe("connected");
    expect(result.current.account).toBe(
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    expect(result.current.wrongNetwork).toBe(false);
    expect(wasConnected()).toBe(true);
  });

  it("user rejection returns cleanly to idle, retry then works", async () => {
    const p = new MockEip1193Provider();
    p.rejectNextConnect();
    announce(makeDetail(p));
    const { result } = mount();
    await waitFor(() => expect(result.current.providers.length).toBe(1));

    await act(async () => {
      await result.current.connect();
    });
    // Clean: back to idle, no error toast spam (rejection swallowed).
    expect(result.current.status).toBe("disconnected");
    expect(result.current.error).toBeNull();

    await act(async () => {
      await result.current.connect();
    });
    expect(result.current.status).toBe("connected");
  });

  it("silently restores a prior session on reload (no prompt)", async () => {
    rememberConnection("com.mock.wallet");
    const p = new MockEip1193Provider({
      accounts: ["0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
      authorized: true, // eth_accounts returns without a prompt
    });
    announce(makeDetail(p, { rdns: "com.mock.wallet" }));
    const { result } = mount();

    await waitFor(() => expect(result.current.status).toBe("connected"));
    expect(result.current.account).toBe(
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
  });

  it("does NOT restore after an explicit disconnect", async () => {
    const p = new MockEip1193Provider({ chainId: 1 });
    announce(makeDetail(p, { rdns: "com.mock.wallet" }));
    const { result } = mount();
    await waitFor(() => expect(result.current.providers.length).toBe(1));

    await act(async () => {
      await result.current.connect();
    });
    expect(result.current.status).toBe("connected");

    act(() => result.current.disconnect());
    expect(result.current.status).toBe("disconnected");
    expect(result.current.account).toBeNull();
    expect(wasConnected()).toBe(false);
  });

  it("reflects accountsChanged live (switch + wallet-lock)", async () => {
    const p = new MockEip1193Provider({
      accounts: ["0xcccccccccccccccccccccccccccccccccccccccc"],
    });
    announce(makeDetail(p));
    const { result } = mount();
    await waitFor(() => expect(result.current.providers.length).toBe(1));
    await act(async () => {
      await result.current.connect();
    });

    act(() => p.emitAccountsChanged(["0xdddddddddddddddddddddddddddddddddddddddd"]));
    expect(result.current.account).toBe(
      "0xdddddddddddddddddddddddddddddddddddddddd",
    );

    // Empty accounts (wallet locked) → disconnected, no reload.
    act(() => p.emitAccountsChanged([]));
    expect(result.current.status).toBe("disconnected");
    expect(result.current.account).toBeNull();
  });

  it("detects wrong network and switches to mainnet live", async () => {
    const p = new MockEip1193Provider({ chainId: 5 }); // Goerli-ish wrong chain
    announce(makeDetail(p));
    const { result } = mount();
    await waitFor(() => expect(result.current.providers.length).toBe(1));
    await act(async () => {
      await result.current.connect();
    });
    expect(result.current.status).toBe("connected");
    expect(result.current.wrongNetwork).toBe(true);

    await act(async () => {
      await result.current.switchToMainnet();
    });
    expect(result.current.chainId).toBe(1);
    expect(result.current.wrongNetwork).toBe(false);
  });

  it("discovers multiple providers and connects the chosen one", async () => {
    const a = new MockEip1193Provider({
      accounts: ["0xa0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0"],
    });
    const b = new MockEip1193Provider({
      accounts: ["0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"],
    });
    announce(
      makeDetail(a, { rdns: "io.a.wallet", name: "A Wallet" }),
      makeDetail(b, { rdns: "io.b.wallet", name: "B Wallet" }),
    );
    const { result } = mount();
    await waitFor(() => expect(result.current.providers.length).toBe(2));

    await act(async () => {
      await result.current.connect("io.b.wallet");
    });
    expect(result.current.account).toBe(
      "0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0",
    );
  });
});
