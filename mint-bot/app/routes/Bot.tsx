import { useState, useEffect, useRef } from 'react';
import { ethers, Contract } from 'ethers';
import { Loader2, Wallet, Send, HardDriveDownload, Play, HardDriveUpload, RefreshCw, StopCircle, Hammer, Settings } from 'lucide-react';
import WordBankArtifact from '../../lib/WordBank.json';

// WordBank SalePhase enum (src/WordBank.sol) — order is ABI-stable.
const PHASE_LABEL: Record<number, string> = {
  0: 'Setup',
  1: 'Early Bird',
  2: 'Between',
  3: 'Public Sale',
};

interface SaleData {
  phase: number;
  phaseLabel: string;
  earlyBirdMinted: number;
  earlyBirdAllocation: number;
  publicMinted: number;
  publicAllocation: number;
  publicSupply: number; // PUBLIC_SUPPLY (9,800) — the provenance trigger
  earlyBirdPriceEth: string;
  publicPriceEth: string;
  publicPriceWei: bigint;
  totalMinted: number;
  maxSupply: number;
  adminMinted: number;
}

export default function Bot() {
  const wordBankAbi = (WordBankArtifact as { abi: ethers.InterfaceAbi }).abi;

  // ── connection ──
  const [rpcUrl, setRpcUrl] = useState('');
  const [contractAddress, setContractAddress] = useState('');
  const [primaryPrivateKey, setPrimaryPrivateKey] = useState('');

  // ── wallets ──
  const [walletCount, setWalletCount] = useState(20);
  const [fundingAmount, setFundingAmount] = useState('0.05');
  const [generatedWallets, setGeneratedWallets] = useState<Array<{ address: string; privateKey: string }>>([]);
  const [walletBalances, setWalletBalances] = useState<Record<string, string>>({});
  const [importedFileName, setImportedFileName] = useState<string>('');

  // ── mint controls ──
  const [mintPerTx, setMintPerTx] = useState(100); // NFTs per publicMint() tx (gas-bounded)
  const [targetMint, setTargetMint] = useState(0); // 0 = mint to public sellout

  // ── sale admin inputs ──
  const [ebAlloc, setEbAlloc] = useState(0);
  const [pubAlloc, setPubAlloc] = useState(9800);
  const [ebPriceEth, setEbPriceEth] = useState('0.01');
  const [pubPriceEth, setPubPriceEth] = useState('0.02');
  const [ebWalletCap, setEbWalletCap] = useState(5);
  const [adminMintCount, setAdminMintCount] = useState(1);
  const [adminMintTo, setAdminMintTo] = useState('');

  // ── runtime ──
  const [saleData, setSaleData] = useState<SaleData | null>(null);
  const [statusLog, setStatusLog] = useState<string[]>([]);
  const [isProcessing, setIsProcessing] = useState(false);
  const [isStopping, setIsStopping] = useState(false);
  const [transactionMode, setTransactionMode] = useState<'ultra-fast' | 'fast'>('fast');
  const [ultraFastBatchSize, setUltraFastBatchSize] = useState<number>(25);
  const [fastBatchSize, setFastBatchSize] = useState<number>(10);
  const [fastBatchDelayMs, setFastBatchDelayMs] = useState<number>(2000);
  const [initialBackoffMs, setInitialBackoffMs] = useState<number>(2000);
  const [backoffFactor, setBackoffFactor] = useState<number>(2);
  const [backoffMaxMs, setBackoffMaxMs] = useState<number>(30000);
  const [dryRunBeforeWithdraw, setDryRunBeforeWithdraw] = useState<boolean>(true);

  const stopRef = useRef(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // ───────────────────────── helpers (preserved from reference) ─────────────────────────
  const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms));
  const addStatus = (m: string) => setStatusLog((p) => [...p, `${new Date().toLocaleTimeString()}: ${m}`]);
  const clearStatusLog = () => setStatusLog([]);

  const isRateLimitError = (error: any): boolean => {
    const msg = String(error?.message || '').toLowerCase();
    return msg.includes('rate limit') || msg.includes('too many requests') || msg.includes('429') || error?.code === 'RATE_LIMIT' || error?.code === 'SERVER_ERROR';
  };

  /** Coerce ws(s) → http(s) for read/broadcast JsonRpcProvider. */
  const httpEndpoint = (url: string): string =>
    url.replace('wss://', 'https://').replace('ws://', 'http://').replace('/ws/', '/');

  const getReadProvider = (): ethers.JsonRpcProvider | null => {
    if (!rpcUrl) return null;
    try {
      return new ethers.JsonRpcProvider(httpEndpoint(rpcUrl));
    } catch (e) {
      console.error('provider error', e);
      return null;
    }
  };

  const sendTxWithRetry = async (
    signer: ethers.Wallet,
    tx: any,
    maxRetries = 5,
    initialDelayMs = initialBackoffMs,
    waitForConfirm = false,
    confirmTimeoutMs = 45000,
    contextAddress?: string,
  ): Promise<boolean> => {
    let attempt = 0;
    let delay = initialDelayMs;
    while (attempt <= maxRetries) {
      if (stopRef.current) return false;
      try {
        const resp = await signer.sendTransaction(tx);
        if (waitForConfirm) {
          const confirmed = await Promise.race([
            resp.wait(),
            new Promise<boolean>((resolve) => setTimeout(() => resolve(false), confirmTimeoutMs)),
          ]);
          return confirmed === false ? true : true;
        }
        return true;
      } catch (error: any) {
        if (isRateLimitError(error)) {
          await sleep(delay);
          delay = Math.min(Math.floor(delay * backoffFactor), backoffMaxMs);
          attempt += 1;
          continue;
        }
        addStatus(`Tx error${contextAddress ? ` from ${contextAddress.slice(0, 8)}…` : ''}: ${error?.shortMessage || error?.message || 'unknown'}`);
        return false;
      }
    }
    return false;
  };

  const sendRawWithRetry = async (
    rawTx: string,
    provider: ethers.AbstractProvider,
    maxRetries = 5,
    initialDelayMs = initialBackoffMs,
  ): Promise<boolean> => {
    let attempt = 0;
    let delay = initialDelayMs;
    while (attempt <= maxRetries) {
      if (stopRef.current) return false;
      try {
        await (provider as any).broadcastTransaction(rawTx);
        return true;
      } catch (error: any) {
        if (isRateLimitError(error)) {
          await sleep(delay);
          delay = Math.min(Math.floor(delay * backoffFactor), backoffMaxMs);
          attempt += 1;
          continue;
        }
        console.error('broadcast error', error);
        return false;
      }
    }
    return false;
  };

  const getBalanceWithRetry = async (provider: ethers.AbstractProvider, address: string, maxRetries = 4, initialDelayMs = 1000): Promise<bigint | null> => {
    let attempt = 0;
    let delay = initialDelayMs;
    while (attempt <= maxRetries) {
      try {
        return await provider.getBalance(address);
      } catch (error: any) {
        if (isRateLimitError(error)) {
          await sleep(delay);
          delay = Math.min(delay * 2, 15000);
          attempt += 1;
          continue;
        }
        return null;
      }
    }
    return null;
  };

  /** Premium fee data (reused from reference). */
  const getFees = async (provider: ethers.AbstractProvider) => {
    const feeData = await provider.getFeeData();
    const maxFeePerGas = (feeData.maxFeePerGas || feeData.gasPrice || 0n) * 12n / 10n;
    const priority = (feeData.maxPriorityFeePerGas || 0n) * 15n / 10n;
    const maxPriorityFeePerGas = priority > maxFeePerGas ? maxFeePerGas : priority;
    return { maxFeePerGas, maxPriorityFeePerGas };
  };

  // ───────────────────────── wallet management (preserved) ─────────────────────────
  const generateWallets = () => {
    const wallets: Array<{ address: string; privateKey: string }> = [];
    for (let i = 0; i < walletCount; i++) {
      const w = ethers.Wallet.createRandom();
      wallets.push({ address: w.address, privateKey: w.privateKey });
    }
    setGeneratedWallets(wallets);
    addStatus(`${walletCount} wallets generated`);
  };

  const handleFileUpload = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const data = JSON.parse(e.target?.result as string);
        if (Array.isArray(data) && data.every((it) => it.address && it.privateKey)) {
          setGeneratedWallets(data);
          setImportedFileName(file.name);
          addStatus(`${data.length} wallets imported from ${file.name}`);
        } else addStatus('Error: invalid wallet file format');
      } catch {
        addStatus('Error: failed to parse wallet file');
      }
      if (fileInputRef.current) fileInputRef.current.value = '';
    };
    reader.readAsText(file);
  };

  const exportPrivateKeys = () => {
    const data = JSON.stringify(generatedWallets);
    const blob = new Blob([data], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'wallets.json';
    a.click();
    addStatus('Wallet keys exported (keep this file local + secret)');
  };

  const handleImportExport = () => (generatedWallets.length > 0 ? exportPrivateKeys() : fileInputRef.current?.click());

  const resetWallets = () => {
    setGeneratedWallets([]);
    setImportedFileName('');
    if (fileInputRef.current) fileInputRef.current.value = '';
    addStatus('Wallet list reset');
  };

  const fetchWalletBalances = async () => {
    if (!generatedWallets.length) return;
    const provider = getReadProvider();
    if (!provider) return addStatus('Error: set a valid RPC URL for balances');
    const batchSize = 50;
    const addresses = generatedWallets.map((w) => w.address);
    const next: Record<string, string> = {};
    for (let i = 0; i < addresses.length; i += batchSize) {
      const batch = addresses.slice(i, i + batchSize);
      const results = await Promise.all(batch.map((a) => getBalanceWithRetry(provider, a)));
      results.forEach((bal, idx) => {
        next[batch[idx]] = bal !== null ? `${Number(ethers.formatEther(bal)).toFixed(5)} ETH` : 'N/A';
      });
      await sleep(300);
    }
    setWalletBalances(next);
  };

  const fundWallets = async () => {
    if (!primaryPrivateKey) return addStatus('Error: primary private key required');
    if (!generatedWallets.length) return addStatus('Error: generate/import wallets first');
    try {
      setIsProcessing(true);
      stopRef.current = false;
      const provider = getReadProvider();
      if (!provider) return addStatus('Error: invalid RPC URL');
      const funder = new ethers.Wallet(primaryPrivateKey, provider);
      const amount = ethers.parseEther(fundingAmount);
      const chainId = (await provider.getNetwork()).chainId;
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees(provider);
      const baseNonce = await provider.getTransactionCount(funder.address, 'pending');
      addStatus(`Funding ${generatedWallets.length} wallets with ${fundingAmount} ETH each…`);
      const raw = await Promise.all(
        generatedWallets.map((w, index) =>
          funder.signTransaction({ to: w.address, value: amount, chainId, maxFeePerGas, maxPriorityFeePerGas, gasLimit: 21000, nonce: baseNonce + index }),
        ),
      );
      const ok = await broadcastRawBatched(raw, provider);
      addStatus(`Funding done: ${ok}/${generatedWallets.length} broadcast`);
      await fetchWalletBalances();
    } catch (e: any) {
      addStatus(`Funding error: ${e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  const broadcastRawBatched = async (raw: string[], provider: ethers.AbstractProvider): Promise<number> => {
    const batchSize = transactionMode === 'ultra-fast' ? ultraFastBatchSize : fastBatchSize;
    let ok = 0;
    for (let i = 0; i < raw.length; i += batchSize) {
      if (stopRef.current) break;
      const batch = raw.slice(i, i + batchSize);
      const results = await Promise.allSettled(batch.map((r) => sendRawWithRetry(r, provider)));
      ok += results.filter((r) => r.status === 'fulfilled' && r.value).length;
      if (i + batchSize < raw.length) await sleep(fastBatchDelayMs);
    }
    return ok;
  };

  const withdrawAllToPrimary = async () => {
    if (!primaryPrivateKey) return addStatus('Error: primary private key required');
    if (!generatedWallets.length) return addStatus('Error: no wallets to sweep');
    try {
      setIsProcessing(true);
      stopRef.current = false;
      const provider = getReadProvider();
      if (!provider) return addStatus('Error: invalid RPC URL');
      const destination = new ethers.Wallet(primaryPrivateKey).address;
      const network = await provider.getNetwork();
      const chainId = network.chainId;
      const feeData = await provider.getFeeData();
      const eip1559 = !!feeData.maxFeePerGas && !!feeData.maxPriorityFeePerGas;
      const effectiveFee = eip1559 ? (feeData.maxFeePerGas as bigint) : (feeData.gasPrice || 0n);
      addStatus(`Sweeping leftover ETH back to ${destination.slice(0, 10)}…`);

      const txs: Array<{ signer: ethers.Wallet; tx: any; from: string }> = [];
      for (const w of generatedWallets) {
        if (stopRef.current) break;
        const bal = await getBalanceWithRetry(provider, w.address);
        if (!bal || bal <= 0n) continue;
        const gasLimit = 21000n;
        const gasCost = gasLimit * (effectiveFee || 0n) + 1000n;
        const value = bal > gasCost ? bal - gasCost : 0n;
        if (value <= 0n) continue;
        const signer = new ethers.Wallet(w.privateKey, provider);
        const nonce = await provider.getTransactionCount(w.address, 'latest');
        const tx: any = { to: destination, value, chainId, gasLimit: Number(gasLimit), nonce };
        if (eip1559) {
          tx.maxFeePerGas = feeData.maxFeePerGas;
          tx.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas;
        } else tx.gasPrice = effectiveFee;
        txs.push({ signer, tx, from: w.address });
      }

      if (dryRunBeforeWithdraw) {
        addStatus(`Dry run: ${txs.length} wallets will sweep`);
        for (const { tx, from } of txs) addStatus(`  ${from.slice(0, 10)}… → ${Number(ethers.formatEther(tx.value)).toFixed(5)} ETH`);
      }

      const batchSize = transactionMode === 'ultra-fast' ? ultraFastBatchSize : fastBatchSize;
      let ok = 0;
      for (let i = 0; i < txs.length; i += batchSize) {
        if (stopRef.current) break;
        const batch = txs.slice(i, i + batchSize);
        const results = await Promise.allSettled(batch.map(({ signer, tx, from }) => sendTxWithRetry(signer, tx, 5, initialBackoffMs, false, 45000, from)));
        ok += results.filter((r) => r.status === 'fulfilled' && r.value).length;
        if (i + batchSize < txs.length) await sleep(fastBatchDelayMs);
      }
      addStatus(`Sweep done: ${ok}/${txs.length} broadcast`);
      await fetchWalletBalances();
    } catch (e: any) {
      addStatus(`Sweep error: ${e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  // ───────────────────────── sale dashboard ─────────────────────────
  const refreshSale = async () => {
    if (!contractAddress || !rpcUrl) return;
    try {
      const provider = getReadProvider();
      if (!provider) return;
      const c = new Contract(contractAddress, wordBankAbi, provider) as any;
      const [phase, ebMinted, ebAllocOnchain, pubMinted, pubAllocOnchain, pubSupply, ebPrice, pubPrice, totalMinted, maxSupply, adminMinted] = await Promise.all([
        c.phase(), c.earlyBirdMinted(), c.earlyBirdAllocation(), c.publicMinted(), c.publicAllocation(), c.PUBLIC_SUPPLY(), c.earlyBirdPrice(), c.publicPrice(), c.totalMinted(), c.MAX_SUPPLY(), c.adminMinted(),
      ]);
      setSaleData({
        phase: Number(phase),
        phaseLabel: PHASE_LABEL[Number(phase)] ?? 'Unknown',
        earlyBirdMinted: Number(ebMinted),
        earlyBirdAllocation: Number(ebAllocOnchain),
        publicMinted: Number(pubMinted),
        publicAllocation: Number(pubAllocOnchain),
        publicSupply: Number(pubSupply),
        earlyBirdPriceEth: ethers.formatEther(ebPrice),
        publicPriceEth: ethers.formatEther(pubPrice),
        publicPriceWei: pubPrice as bigint,
        totalMinted: Number(totalMinted),
        maxSupply: Number(maxSupply),
        adminMinted: Number(adminMinted),
      });
    } catch (e: any) {
      // Quietly ignore transient read errors; surfaced only on demand.
      console.error('sale read error', e);
    }
  };

  useEffect(() => {
    refreshSale();
    const id = setInterval(refreshSale, 8000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contractAddress, rpcUrl]);

  // ───────────────────────── sale admin (owner = primary key) ─────────────────────────
  const ownerTx = async (label: string, build: (c: any) => Promise<any>) => {
    if (!primaryPrivateKey || !contractAddress) return addStatus('Error: primary key + contract address required');
    try {
      setIsProcessing(true);
      const provider = getReadProvider();
      if (!provider) return addStatus('Error: invalid RPC URL');
      const signer = new ethers.Wallet(primaryPrivateKey, provider);
      const c = new Contract(contractAddress, wordBankAbi, signer) as any;
      addStatus(`${label}…`);
      const tx = await build(c);
      await tx.wait();
      addStatus(`${label} ✓ (${tx.hash.slice(0, 12)}…)`);
      await refreshSale();
    } catch (e: any) {
      addStatus(`${label} failed: ${e?.shortMessage || e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  const doSetSaleConfig = () =>
    ownerTx('setSaleConfig', (c) =>
      c.setSaleConfig(BigInt(ebAlloc), BigInt(pubAlloc), ethers.parseEther(ebPriceEth), ethers.parseEther(pubPriceEth), BigInt(ebWalletCap)),
    );
  const doOpenEarlyBird = () => ownerTx('openEarlyBird', (c) => c.openEarlyBird());
  const doCloseEarlyBird = () => ownerTx('closeEarlyBird', (c) => c.closeEarlyBird());
  const doOpenPublicSale = () => ownerTx('openPublicSale', (c) => c.openPublicSale());
  const doAdminMint = () =>
    ownerTx('adminMint', (c) => c.adminMint(BigInt(adminMintCount), adminMintTo || new ethers.Wallet(primaryPrivateKey).address));

  // ───────────────────────── mass mint (publicMint batches across wallets) ─────────────────────────
  const massMintPublic = async () => {
    if (!contractAddress) return addStatus('Error: WordBank address required');
    if (!generatedWallets.length) return addStatus('Error: fund some wallets first');
    try {
      setIsProcessing(true);
      stopRef.current = false;
      const provider = getReadProvider();
      if (!provider) return addStatus('Error: invalid RPC URL');
      const readC = new Contract(contractAddress, wordBankAbi, provider) as any;
      const [phase, pubPrice, pubMinted, pubAlloc] = await Promise.all([readC.phase(), readC.publicPrice(), readC.publicMinted(), readC.publicAllocation()]);
      if (Number(phase) !== 3) return addStatus('Error: not in Public Sale phase — open the public sale first');

      const allocLeft = Number(pubAlloc) - Number(pubMinted);
      const want = targetMint > 0 ? Math.min(targetMint, allocLeft) : allocLeft;
      if (want <= 0) return addStatus('Nothing to mint — public allocation already minted out');

      // Split into chunks of mintPerTx.
      const chunks: number[] = [];
      let left = want;
      while (left > 0) {
        const n = Math.min(mintPerTx, left);
        chunks.push(n);
        left -= n;
      }
      addStatus(`Minting ${want} NFTs via publicMint in ${chunks.length} txs (${mintPerTx}/tx) across ${generatedWallets.length} wallets…`);

      const chainId = (await provider.getNetwork()).chainId;
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees(provider);

      // Per-wallet nonce tracking (a wallet may send several txs).
      const nonceMap = new Map<string, number>();
      const gasCache = new Map<number, bigint>(); // count → gasLimit

      const estimateGasFor = async (signer: ethers.Wallet, count: number): Promise<bigint> => {
        if (gasCache.has(count)) return gasCache.get(count)!;
        let gas: bigint;
        try {
          const c = new Contract(contractAddress, wordBankAbi, signer) as any;
          const est: bigint = await c.publicMint.estimateGas(count, { value: (pubPrice as bigint) * BigInt(count) });
          gas = (est * 12n) / 10n; // +20% headroom
        } catch {
          gas = BigInt(count) * 320000n + 200000n; // conservative fallback
        }
        gasCache.set(count, gas);
        return gas;
      };

      // Build all populated txs with explicit per-wallet nonces.
      const built: Array<{ signer: ethers.Wallet; tx: any; from: string; count: number }> = [];
      for (let i = 0; i < chunks.length; i++) {
        const w = generatedWallets[i % generatedWallets.length];
        const signer = new ethers.Wallet(w.privateKey, provider);
        if (!nonceMap.has(w.address)) nonceMap.set(w.address, await provider.getTransactionCount(w.address, 'pending'));
        const nonce = nonceMap.get(w.address)!;
        nonceMap.set(w.address, nonce + 1);
        const count = chunks[i];
        const gasLimit = await estimateGasFor(signer, count);
        const c = new Contract(contractAddress, wordBankAbi, signer) as any;
        const tx = await c.publicMint.populateTransaction(count, {
          value: (pubPrice as bigint) * BigInt(count),
          nonce, gasLimit, maxFeePerGas, maxPriorityFeePerGas, chainId,
        });
        built.push({ signer, tx, from: w.address, count });
      }

      // Broadcast in batches. waitForConfirm so progress + nonce ordering hold.
      const batchSize = transactionMode === 'ultra-fast' ? ultraFastBatchSize : fastBatchSize;
      let ok = 0;
      let mintedSoFar = 0;
      for (let i = 0; i < built.length; i += batchSize) {
        if (stopRef.current) {
          addStatus('Stopped by user.');
          break;
        }
        const batch = built.slice(i, i + batchSize);
        const results = await Promise.allSettled(
          batch.map(({ signer, tx, from }) => sendTxWithRetry(signer, tx, 5, initialBackoffMs, true, 60000, from)),
        );
        const good = results.filter((r) => r.status === 'fulfilled' && r.value);
        ok += good.length;
        mintedSoFar += batch.reduce((s, b, idx) => (results[idx].status === 'fulfilled' && (results[idx] as PromiseFulfilledResult<boolean>).value ? s + b.count : s), 0);
        addStatus(`Batch ${Math.floor(i / batchSize) + 1}/${Math.ceil(built.length / batchSize)}: ${good.length}/${batch.length} txs ok (~${mintedSoFar} NFTs)`);
        await refreshSale();
        if (i + batchSize < built.length) await sleep(fastBatchDelayMs);
      }
      addStatus(`Mass mint complete: ${ok}/${built.length} txs broadcast (~${mintedSoFar} NFTs).`);
      await refreshSale();
    } catch (e: any) {
      addStatus(`Mass mint error: ${e?.shortMessage || e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  const stopOperations = () => {
    setIsStopping(true);
    stopRef.current = true;
    addStatus('Stopping after the current batch…');
    setTimeout(() => {
      setIsStopping(false);
      setIsProcessing(false);
    }, 500);
  };

  useEffect(() => {
    if (generatedWallets.length > 0) fetchWalletBalances();
    else setWalletBalances({});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [generatedWallets, rpcUrl]);

  // % toward the 9,800 provenance trigger.
  const publicSold = saleData ? saleData.earlyBirdMinted + saleData.publicMinted : 0;
  const pctToReveal = saleData && saleData.publicSupply > 0 ? Math.min(100, (publicSold / saleData.publicSupply) * 100) : 0;

  const input = 'w-full px-3 py-2 bg-white/5 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500';
  const card = 'bg-white/10 backdrop-blur-md rounded-xl p-6 border border-white/20';
  const label = 'block text-sm font-medium text-blue-200 mb-2';

  return (
    <div className="min-h-screen bg-gradient-to-br from-amber-950 via-stone-900 to-indigo-950 p-6">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-8">
          <h1 className="text-4xl font-bold text-white mb-2">WORDBANK Mint Bot</h1>
          <p className="text-blue-200">Owner-run rehearsal tool — drive the sale to the 9,800 public sellout.</p>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Connection */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Connection</h2>
            <div className="space-y-4">
              <div>
                <label className={label}>RPC URL (http/ws — Sepolia / local fork / mainnet)</label>
                <input className={input} value={rpcUrl} onChange={(e) => setRpcUrl(e.target.value)} placeholder="http://127.0.0.1:8545" />
              </div>
              <div>
                <label className={label}>WordBank contract address</label>
                <input className={input} value={contractAddress} onChange={(e) => setContractAddress(e.target.value)} placeholder="0x…" />
              </div>
              <div>
                <label className={label}>Primary private key (funder + owner) — stays in your browser</label>
                <input type="password" className={input} value={primaryPrivateKey} onChange={(e) => setPrimaryPrivateKey(e.target.value)} placeholder="0x…" />
              </div>
            </div>
          </div>

          {/* Sale dashboard */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Sale dashboard</h2>
            {!saleData ? (
              <p className="text-blue-200 text-sm">Set RPC + contract address to read the live sale state.</p>
            ) : (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-3">
                  <Stat label="Phase" value={saleData.phaseLabel} highlight={saleData.phase === 3} />
                  <Stat label="Public price" value={`${saleData.publicPriceEth} ETH`} />
                  <Stat label="Early bird" value={`${saleData.earlyBirdMinted} / ${saleData.earlyBirdAllocation}`} />
                  <Stat label="Public" value={`${saleData.publicMinted} / ${saleData.publicAllocation}`} />
                  <Stat label="Total minted" value={`${saleData.totalMinted} / ${saleData.maxSupply}`} />
                  <Stat label="Admin reserve" value={`${saleData.adminMinted} / 200`} />
                </div>
                <div>
                  <div className="flex justify-between text-xs text-blue-200 mb-1">
                    <span>Toward the 9,800 reveal trigger</span>
                    <span className="font-mono">{publicSold} / {saleData.publicSupply} ({pctToReveal.toFixed(1)}%)</span>
                  </div>
                  <div className="h-2 bg-white/10 rounded-full overflow-hidden">
                    <div className="h-full bg-amber-400" style={{ width: `${pctToReveal}%` }} />
                  </div>
                </div>
                <button onClick={refreshSale} className="text-blue-300 hover:text-blue-200 text-sm flex items-center gap-2">
                  <RefreshCw className="w-4 h-4" /> Refresh
                </button>
              </div>
            )}
          </div>

          {/* Sale admin */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4 flex items-center gap-2"><Settings className="w-5 h-5" /> Sale admin (owner)</h2>
            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <div><label className={label}>EB allocation</label><input type="number" className={input} value={ebAlloc} onChange={(e) => setEbAlloc(parseInt(e.target.value) || 0)} /></div>
                <div><label className={label}>Public allocation</label><input type="number" className={input} value={pubAlloc} onChange={(e) => setPubAlloc(parseInt(e.target.value) || 0)} /></div>
                <div><label className={label}>EB price (ETH)</label><input className={input} value={ebPriceEth} onChange={(e) => setEbPriceEth(e.target.value)} /></div>
                <div><label className={label}>Public price (ETH)</label><input className={input} value={pubPriceEth} onChange={(e) => setPubPriceEth(e.target.value)} /></div>
                <div><label className={label}>EB wallet cap</label><input type="number" className={input} value={ebWalletCap} onChange={(e) => setEbWalletCap(parseInt(e.target.value) || 0)} /></div>
              </div>
              <p className="text-xs text-blue-300">EB + public + 200 reserve must equal 10,000. Set EB allocation 0 to rehearse the public-only path straight to sellout.</p>
              <div className="grid grid-cols-2 gap-2">
                <Btn onClick={doSetSaleConfig} disabled={isProcessing} color="bg-blue-600">Set sale config</Btn>
                <Btn onClick={doOpenEarlyBird} disabled={isProcessing} color="bg-teal-600">Open early bird</Btn>
                <Btn onClick={doCloseEarlyBird} disabled={isProcessing} color="bg-stone-600">Close early bird</Btn>
                <Btn onClick={doOpenPublicSale} disabled={isProcessing} color="bg-indigo-600">Open public sale</Btn>
              </div>
              <div className="grid grid-cols-3 gap-2 items-end">
                <div><label className={label}>Admin mint #</label><input type="number" className={input} value={adminMintCount} onChange={(e) => setAdminMintCount(parseInt(e.target.value) || 1)} /></div>
                <div className="col-span-2"><label className={label}>to (blank = primary)</label><input className={input} value={adminMintTo} onChange={(e) => setAdminMintTo(e.target.value)} placeholder="0x…" /></div>
              </div>
              <Btn onClick={doAdminMint} disabled={isProcessing} color="bg-amber-700">Admin mint (≤200 reserve)</Btn>
            </div>
          </div>

          {/* Wallet management */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Wallets</h2>
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div><label className={label}>Number of wallets</label><input type="number" min={1} max={5000} className={input} value={walletCount} onChange={(e) => setWalletCount(parseInt(e.target.value) || 1)} /></div>
                <div><label className={label}>Funding each (ETH)</label><input type="number" step="0.001" className={input} value={fundingAmount} onChange={(e) => setFundingAmount(e.target.value)} /></div>
              </div>
              {importedFileName && <p className="text-sm text-blue-200">Imported: {importedFileName}</p>}
              <div className="flex gap-2">
                <Btn onClick={generateWallets} disabled={isProcessing} color="bg-blue-600" icon={<Wallet className="w-4 h-4" />}>Generate</Btn>
                <Btn onClick={handleImportExport} disabled={isProcessing} color="bg-purple-600" icon={generatedWallets.length > 0 ? <HardDriveDownload className="w-4 h-4" /> : <HardDriveUpload className="w-4 h-4" />}>{generatedWallets.length > 0 ? 'Export' : 'Import'}</Btn>
                <Btn onClick={resetWallets} disabled={isProcessing} color="bg-gray-700" icon={<RefreshCw className="w-4 h-4" />}>Reset</Btn>
              </div>
              <input ref={fileInputRef} type="file" accept=".json" onChange={handleFileUpload} className="hidden" />
              <Btn onClick={fundWallets} disabled={isProcessing || !generatedWallets.length || !primaryPrivateKey} color="bg-green-600" icon={isProcessing ? <Loader2 className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4" />} full>Fund wallets</Btn>
            </div>
          </div>
        </div>

        {/* Mass mint */}
        <div className={`${card} mt-6`}>
          <h2 className="text-xl font-semibold text-white mb-4 flex items-center gap-2"><Hammer className="w-5 h-5" /> Mass mint → public sellout</h2>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div><label className={label}>NFTs per tx (gas-bounded)</label><input type="number" min={1} max={150} className={input} value={mintPerTx} onChange={(e) => setMintPerTx(parseInt(e.target.value) || 1)} /></div>
                <div><label className={label}>Target NFTs (0 = to sellout)</label><input type="number" min={0} className={input} value={targetMint} onChange={(e) => setTargetMint(parseInt(e.target.value) || 0)} /></div>
              </div>
              <div>
                <label className={label}>Broadcast mode</label>
                <div className="grid grid-cols-2 gap-2">
                  <Btn onClick={() => setTransactionMode('fast')} color={transactionMode === 'fast' ? 'bg-blue-600' : 'bg-white/5'}>Fast (batched)</Btn>
                  <Btn onClick={() => setTransactionMode('ultra-fast')} color={transactionMode === 'ultra-fast' ? 'bg-blue-600' : 'bg-white/5'}>Ultra fast</Btn>
                </div>
              </div>
              <div className="grid grid-cols-3 gap-2">
                <Adv label="Ultra batch" v={ultraFastBatchSize} set={setUltraFastBatchSize} />
                <Adv label="Fast batch" v={fastBatchSize} set={setFastBatchSize} />
                <Adv label="Batch delay ms" v={fastBatchDelayMs} set={setFastBatchDelayMs} />
                <Adv label="Backoff ms" v={initialBackoffMs} set={setInitialBackoffMs} />
                <Adv label="Backoff max" v={backoffMaxMs} set={setBackoffMaxMs} />
              </div>
            </div>
            <div className="space-y-4 flex flex-col justify-end">
              <Btn onClick={massMintPublic} disabled={isProcessing || !generatedWallets.length || !contractAddress} color="bg-orange-600" icon={isProcessing ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />} full>Mint to public sellout</Btn>
              {(isProcessing) && (
                <Btn onClick={stopOperations} disabled={isStopping} color="bg-gray-800" icon={isStopping ? <Loader2 className="w-4 h-4 animate-spin" /> : <StopCircle className="w-4 h-4" />} full>Stop after current batch</Btn>
              )}
              <p className="text-xs text-blue-300">Each tx sends exactly publicPrice × count (else the contract reverts WrongPayment). Block gas limit caps NFTs/tx — drop the count if a tx runs out of gas.</p>
            </div>
          </div>
        </div>

        {/* Wallet list */}
        {generatedWallets.length > 0 && (
          <div className={`${card} mt-6`}>
            <div className="flex justify-between items-center mb-4">
              <h2 className="text-xl font-semibold text-white">Wallets ({generatedWallets.length})</h2>
              <div className="flex items-center gap-3">
                <button onClick={fetchWalletBalances} disabled={isProcessing} className="text-blue-300 hover:text-blue-200 text-sm flex items-center gap-2"><RefreshCw className="w-4 h-4" /> Balances</button>
                <label className="flex items-center gap-2 text-xs text-blue-200"><input type="checkbox" checked={dryRunBeforeWithdraw} onChange={(e) => setDryRunBeforeWithdraw(e.target.checked)} /> Dry run sweep</label>
                <button onClick={withdrawAllToPrimary} disabled={isProcessing || !primaryPrivateKey} className="text-red-300 hover:text-red-200 text-sm flex items-center gap-2"><Send className="w-4 h-4" /> Sweep all → primary</button>
              </div>
            </div>
            <div className="max-h-40 overflow-y-auto space-y-2">
              {generatedWallets.map((w, i) => (
                <div key={i} className="bg-white/5 rounded-lg p-3 text-sm flex justify-between items-center">
                  <span className="text-white font-mono text-xs break-all">{w.address}</span>
                  <span className="text-blue-200 text-xs whitespace-nowrap ml-3">{walletBalances[w.address] ?? '…'}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Status log */}
        <div className={`${card} mt-6`}>
          <div className="flex justify-between items-center mb-4">
            <h2 className="text-xl font-semibold text-white">Status log</h2>
            <button onClick={clearStatusLog} className="text-blue-300 hover:text-blue-200 text-sm">Clear</button>
          </div>
          <div className="max-h-60 overflow-y-auto space-y-1">
            {statusLog.length === 0 ? <div className="text-gray-400 text-sm">No messages yet…</div> : statusLog.map((m, i) => <div key={i} className="text-sm text-gray-300 font-mono">{m}</div>)}
          </div>
        </div>
      </div>
    </div>
  );
}

function Stat({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div>
      <div className="text-xs text-blue-200 mb-1">{label}</div>
      <div className={`px-3 py-2 rounded-lg text-sm font-medium ${highlight ? 'bg-green-500/20 text-green-300' : 'bg-white/5 text-white'}`}>{value}</div>
    </div>
  );
}

function Btn({ onClick, disabled, color, icon, children, full }: { onClick: () => void; disabled?: boolean; color: string; icon?: React.ReactNode; children: React.ReactNode; full?: boolean }) {
  return (
    <button onClick={onClick} disabled={disabled} className={`${color} hover:opacity-90 disabled:bg-gray-600 disabled:opacity-100 text-white px-4 py-2 rounded-lg font-medium transition-all flex items-center justify-center gap-2 text-sm ${full ? 'w-full' : 'flex-1'}`}>
      {icon}{children}
    </button>
  );
}

function Adv({ label, v, set }: { label: string; v: number; set: (n: number) => void }) {
  return (
    <div>
      <label className="block text-xs text-blue-200 mb-1">{label}</label>
      <input type="number" min={0} value={v} onChange={(e) => set(parseInt(e.target.value) || 0)} className="w-full px-2 py-1 bg-white/5 border border-white/20 rounded-lg text-white text-xs" />
    </div>
  );
}
