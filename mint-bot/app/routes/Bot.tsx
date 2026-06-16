import { useState, useEffect, useRef } from 'react';
import { ethers, Contract } from 'ethers';
import { Loader2, Wallet, Send, HardDriveDownload, Play, HardDriveUpload, RefreshCw, Settings, ExternalLink } from 'lucide-react';
import WordBankArtifact from '../../lib/WordBank.json';
import {
  SalePhase,
  PHASE_LABEL,
  selectMintPlan,
  mintValueWei,
  earlyBirdCapCheck,
  fundingCheck,
} from '../../lib/mint';

interface SaleData {
  phase: number;
  phaseLabel: string;
  earlyBirdMinted: number;
  earlyBirdAllocation: number;
  publicMinted: number;
  publicAllocation: number;
  earlyBirdPriceEth: string;
  earlyBirdPriceWei: bigint;
  publicPriceEth: string;
  publicPriceWei: bigint;
  earlyBirdWalletCap: bigint;
  totalMinted: number;
  maxSupply: number;
  adminMinted: number;
}

type MintStatus = 'idle' | 'checking' | 'skipped' | 'pending' | 'success' | 'failed';

interface MintResult {
  address: string;
  status: MintStatus;
  txHash?: string;
  message?: string;
}

/** Known explorer base URLs keyed by chainId; fallback to Etherscan mainnet. */
function explorerTxUrl(chainId: number, hash: string): string {
  const base: Record<number, string> = {
    1: 'https://etherscan.io',
    11155111: 'https://sepolia.etherscan.io',
  };
  return `${base[chainId] ?? 'https://etherscan.io'}/tx/${hash}`;
}

export default function Bot() {
  const wordBankAbi = (WordBankArtifact as { abi: ethers.InterfaceAbi }).abi;

  // ── connection ──
  const [rpcUrl, setRpcUrl] = useState('');
  const [chainId, setChainId] = useState('1');
  const [contractAddress, setContractAddress] = useState('');
  const [primaryPrivateKey, setPrimaryPrivateKey] = useState('');

  // ── wallets ──
  const [walletCount, setWalletCount] = useState(5);
  const [fundingAmount, setFundingAmount] = useState('0.05');
  const [generatedWallets, setGeneratedWallets] = useState<Array<{ address: string; privateKey: string }>>([]);
  const [walletBalances, setWalletBalances] = useState<Record<string, string>>({});
  const [importedFileName, setImportedFileName] = useState<string>('');
  const [pastedKeys, setPastedKeys] = useState('');

  // ── mint controls ──
  const [nftsPerWallet, setNftsPerWallet] = useState(1); // each wallet mints this many in its ONE tx

  // ── sale admin inputs (secondary) ──
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
  const [mintResults, setMintResults] = useState<MintResult[]>([]);

  const fileInputRef = useRef<HTMLInputElement>(null);

  // ───────────────────────── helpers ─────────────────────────
  const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms));
  const addStatus = (m: string) => setStatusLog((p) => [...p, `${new Date().toLocaleTimeString()}: ${m}`]);
  const clearStatusLog = () => setStatusLog([]);

  /** Coerce ws(s) → http(s) for the JsonRpcProvider. */
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

  /** Premium fee data (small bump so txs land promptly). */
  const getFees = async (provider: ethers.AbstractProvider) => {
    const feeData = await provider.getFeeData();
    const maxFeePerGas = (feeData.maxFeePerGas || feeData.gasPrice || 0n) * 12n / 10n;
    const priority = (feeData.maxPriorityFeePerGas || 0n) * 15n / 10n;
    const maxPriorityFeePerGas = priority > maxFeePerGas ? maxFeePerGas : priority;
    const gasPriceForEstimate = maxFeePerGas || feeData.gasPrice || 0n;
    return { maxFeePerGas, maxPriorityFeePerGas, gasPriceForEstimate };
  };

  // ───────────────────────── wallet management ─────────────────────────
  const generateWallets = () => {
    const wallets: Array<{ address: string; privateKey: string }> = [];
    for (let i = 0; i < walletCount; i++) {
      const w = ethers.Wallet.createRandom();
      wallets.push({ address: w.address, privateKey: w.privateKey });
    }
    setGeneratedWallets(wallets);
    setMintResults([]);
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
          setMintResults([]);
          addStatus(`${data.length} wallets imported from ${file.name}`);
        } else addStatus('Error: invalid wallet file format (expected [{address,privateKey}])');
      } catch {
        addStatus('Error: failed to parse wallet file');
      }
      if (fileInputRef.current) fileInputRef.current.value = '';
    };
    reader.readAsText(file);
  };

  /** Import one private key per line (0x… ). Addresses are derived. */
  const importPastedKeys = () => {
    const lines = pastedKeys.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (!lines.length) return addStatus('Error: paste at least one private key (one per line)');
    const wallets: Array<{ address: string; privateKey: string }> = [];
    for (const line of lines) {
      try {
        const w = new ethers.Wallet(line);
        wallets.push({ address: w.address, privateKey: w.privateKey });
      } catch {
        addStatus(`Skipped an invalid key line (not shown for safety)`);
      }
    }
    if (!wallets.length) return addStatus('Error: no valid private keys parsed');
    setGeneratedWallets(wallets);
    setImportedFileName('(pasted keys)');
    setPastedKeys('');
    setMintResults([]);
    addStatus(`${wallets.length} wallets imported from pasted keys`);
  };

  const exportPrivateKeys = () => {
    const data = JSON.stringify(generatedWallets, null, 2);
    const blob = new Blob([data], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'wallets.json';
    a.click();
    addStatus('Wallet keys exported (keep this file LOCAL + SECRET; delete after use)');
  };

  const resetWallets = () => {
    setGeneratedWallets([]);
    setImportedFileName('');
    setMintResults([]);
    if (fileInputRef.current) fileInputRef.current.value = '';
    addStatus('Wallet list reset');
  };

  const fetchWalletBalances = async () => {
    if (!generatedWallets.length) return;
    const provider = getReadProvider();
    if (!provider) return addStatus('Error: set a valid RPC URL for balances');
    const next: Record<string, string> = {};
    await Promise.all(
      generatedWallets.map(async (w) => {
        try {
          const bal = await provider.getBalance(w.address);
          next[w.address] = `${Number(ethers.formatEther(bal)).toFixed(5)} ETH`;
        } catch {
          next[w.address] = 'N/A';
        }
      }),
    );
    setWalletBalances(next);
  };

  /** Optional helper: fund each wallet from the primary key (simple parallel sends, no batching loop). */
  const fundWallets = async () => {
    if (!primaryPrivateKey) return addStatus('Error: primary private key required to fund');
    if (!generatedWallets.length) return addStatus('Error: generate/import wallets first');
    try {
      setIsProcessing(true);
      const provider = getReadProvider();
      if (!provider) return addStatus('Error: invalid RPC URL');
      const funder = new ethers.Wallet(primaryPrivateKey, provider);
      const amount = ethers.parseEther(fundingAmount);
      const net = await provider.getNetwork();
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees(provider);
      const baseNonce = await provider.getTransactionCount(funder.address, 'pending');
      addStatus(`Funding ${generatedWallets.length} wallets with ${fundingAmount} ETH each…`);
      const results = await Promise.allSettled(
        generatedWallets.map((w, i) =>
          funder.sendTransaction({
            to: w.address, value: amount, chainId: net.chainId,
            maxFeePerGas, maxPriorityFeePerGas, gasLimit: 21000, nonce: baseNonce + i,
          }),
        ),
      );
      const ok = results.filter((r) => r.status === 'fulfilled').length;
      addStatus(`Funding broadcast: ${ok}/${generatedWallets.length}`);
      await sleep(3000);
      await fetchWalletBalances();
    } catch (e: any) {
      addStatus(`Funding error: ${e?.shortMessage || e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  /** Optional helper: sweep leftover ETH back to the primary (simple parallel sends). */
  const sweepAllToPrimary = async () => {
    if (!primaryPrivateKey) return addStatus('Error: primary private key required to sweep');
    if (!generatedWallets.length) return addStatus('Error: no wallets to sweep');
    try {
      setIsProcessing(true);
      const provider = getReadProvider();
      if (!provider) return addStatus('Error: invalid RPC URL');
      const destination = new ethers.Wallet(primaryPrivateKey).address;
      const net = await provider.getNetwork();
      const feeData = await provider.getFeeData();
      const eip1559 = !!feeData.maxFeePerGas && !!feeData.maxPriorityFeePerGas;
      const effectiveFee = eip1559 ? (feeData.maxFeePerGas as bigint) : (feeData.gasPrice || 0n);
      addStatus(`Sweeping leftover ETH back to ${destination.slice(0, 10)}…`);
      const sends = await Promise.allSettled(
        generatedWallets.map(async (w) => {
          const bal = await provider.getBalance(w.address);
          if (bal <= 0n) return;
          const gasLimit = 21000n;
          const gasCost = gasLimit * (effectiveFee || 0n) + 1000n;
          const value = bal > gasCost ? bal - gasCost : 0n;
          if (value <= 0n) return;
          const signer = new ethers.Wallet(w.privateKey, provider);
          const nonce = await provider.getTransactionCount(w.address, 'latest');
          const tx: any = { to: destination, value, chainId: net.chainId, gasLimit: Number(gasLimit), nonce };
          if (eip1559) { tx.maxFeePerGas = feeData.maxFeePerGas; tx.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas; }
          else tx.gasPrice = effectiveFee;
          return signer.sendTransaction(tx);
        }),
      );
      const ok = sends.filter((r) => r.status === 'fulfilled' && r.value).length;
      addStatus(`Sweep broadcast: ${ok} wallets`);
      await sleep(3000);
      await fetchWalletBalances();
    } catch (e: any) {
      addStatus(`Sweep error: ${e?.shortMessage || e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  // ───────────────────────── sale dashboard (read-only) ─────────────────────────
  const refreshSale = async () => {
    if (!contractAddress || !rpcUrl) return;
    try {
      const provider = getReadProvider();
      if (!provider) return;
      const c = new Contract(contractAddress, wordBankAbi, provider) as any;
      const [phase, ebMinted, ebAllocOnchain, pubMinted, pubAllocOnchain, ebPrice, pubPrice, ebCap, totalMinted, maxSupply, adminMinted] = await Promise.all([
        c.phase(), c.earlyBirdMinted(), c.earlyBirdAllocation(), c.publicMinted(), c.publicAllocation(),
        c.earlyBirdPrice(), c.publicPrice(), c.earlyBirdWalletCap(), c.totalMinted(), c.MAX_SUPPLY(), c.adminMinted(),
      ]);
      setSaleData({
        phase: Number(phase),
        phaseLabel: PHASE_LABEL[Number(phase)] ?? 'Unknown',
        earlyBirdMinted: Number(ebMinted),
        earlyBirdAllocation: Number(ebAllocOnchain),
        publicMinted: Number(pubMinted),
        publicAllocation: Number(pubAllocOnchain),
        earlyBirdPriceEth: ethers.formatEther(ebPrice),
        earlyBirdPriceWei: ebPrice as bigint,
        publicPriceEth: ethers.formatEther(pubPrice),
        publicPriceWei: pubPrice as bigint,
        earlyBirdWalletCap: ebCap as bigint,
        totalMinted: Number(totalMinted),
        maxSupply: Number(maxSupply),
        adminMinted: Number(adminMinted),
      });
    } catch (e: any) {
      console.error('sale read error', e);
    }
  };

  useEffect(() => {
    refreshSale();
    const id = setInterval(refreshSale, 12000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contractAddress, rpcUrl]);

  // ───────────────────────── sale admin (owner = primary key) — secondary ─────────────────────────
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

  // ───────────────────────── THE MINT: one tx per imported wallet, all fired together ─────────────────────────
  const mintFromAllWallets = async () => {
    if (!contractAddress) return addStatus('Error: WordBank address required');
    if (!generatedWallets.length) return addStatus('Error: import/generate wallets first');
    const count = nftsPerWallet;
    if (!Number.isInteger(count) || count <= 0) return addStatus('Error: NFTs per wallet must be a positive integer');

    setIsProcessing(true);
    try {
      const provider = getReadProvider();
      if (!provider) { addStatus('Error: invalid RPC URL'); return; }

      // 1) Read live phase + prices from the contract.
      const readC = new Contract(contractAddress, wordBankAbi, provider) as any;
      const [phaseRaw, ebPrice, pubPrice, ebCap] = await Promise.all([
        readC.phase(), readC.earlyBirdPrice(), readC.publicPrice(), readC.earlyBirdWalletCap(),
      ]);
      const phase = Number(phaseRaw);

      // 2) Phase-aware function + unit price selection (PURE logic, unit-tested).
      const plan = selectMintPlan(phase, ebPrice as bigint, pubPrice as bigint);
      if (!plan.mintable || !plan.fn || plan.unitPriceWei === undefined) {
        addStatus(`Mint disabled: ${plan.reason ?? 'phase does not allow minting'}`);
        return;
      }
      const unitPriceWei = plan.unitPriceWei;
      const mintFn = plan.fn; // narrowed non-undefined; safe to use in async closures
      const valueWei = mintValueWei(unitPriceWei, count); // exact msg.value = price × count
      addStatus(
        `Phase ${PHASE_LABEL[phase]} → ${mintFn}(${count}); value/tx = ${ethers.formatEther(valueWei)} ETH ` +
        `(${ethers.formatEther(unitPriceWei)} × ${count}) across ${generatedWallets.length} wallets.`,
      );

      const net = await provider.getNetwork();
      const onchainChainId = Number(net.chainId);
      const { maxFeePerGas, maxPriorityFeePerGas, gasPriceForEstimate } = await getFees(provider);

      // 3) Pre-flight each wallet: early-bird cap (EB only) + balance >= value + gas.
      //    Build the list of wallets cleared to mint; flag/skip the rest.
      setMintResults(generatedWallets.map((w) => ({ address: w.address, status: 'checking' as MintStatus })));

      // Estimate gas once from the first wallet (same calldata shape for all).
      let gasLimit: bigint;
      try {
        const firstSigner = new ethers.Wallet(generatedWallets[0].privateKey, provider);
        const cFirst = new Contract(contractAddress, wordBankAbi, firstSigner) as any;
        const est: bigint = await cFirst[mintFn].estimateGas(count, { value: valueWei });
        gasLimit = (est * 13n) / 10n; // +30% headroom
      } catch {
        gasLimit = BigInt(count) * 320000n + 200000n; // conservative fallback
      }

      const cleared: Array<{ w: { address: string; privateKey: string } }> = [];
      const nextResults: MintResult[] = [];
      for (const w of generatedWallets) {
        // Early-bird per-wallet cap (only relevant in EarlyBird phase).
        if (phase === SalePhase.EarlyBird) {
          let already: bigint = 0n;
          try { already = await readC.earlyBirdMintedBy(w.address); } catch { /* default 0 */ }
          const cap = earlyBirdCapCheck(ebCap as bigint, already, count);
          if (!cap.ok) {
            nextResults.push({ address: w.address, status: 'skipped', message: cap.reason });
            continue;
          }
        }
        // Balance >= value + estimated gas (with pad).
        const bal = await provider.getBalance(w.address);
        const fund = fundingCheck({ balanceWei: bal, valueWei, gasLimit, gasPriceWei: gasPriceForEstimate });
        if (!fund.ok) {
          nextResults.push({
            address: w.address,
            status: 'skipped',
            message: `Underfunded: needs ~${ethers.formatEther(fund.requiredWei)} ETH, short ${ethers.formatEther(fund.shortfallWei)} ETH.`,
          });
          continue;
        }
        cleared.push({ w });
        nextResults.push({ address: w.address, status: 'pending' });
      }
      setMintResults(nextResults);

      const skipped = nextResults.filter((r) => r.status === 'skipped').length;
      if (!cleared.length) {
        addStatus(`No wallets cleared to mint (${skipped} skipped/flagged). Fund the wallets or adjust the count.`);
        return;
      }
      addStatus(`${cleared.length} wallets cleared, ${skipped} skipped. Firing one ${plan.fn}(${count}) tx per wallet…`);

      // 4) Fire ONE tx per cleared wallet, ALL together. Each wallet is its own
      //    signer with its own nonce, so there is no cross-wallet nonce
      //    contention — Promise.allSettled lets every wallet succeed/fail
      //    independently (one wallet's revert never blocks the others).
      const updateResult = (address: string, patch: Partial<MintResult>) =>
        setMintResults((prev) => prev.map((r) => (r.address === address ? { ...r, ...patch } : r)));

      await Promise.allSettled(
        cleared.map(async ({ w }) => {
          try {
            const signer = new ethers.Wallet(w.privateKey, provider);
            const c = new Contract(contractAddress, wordBankAbi, signer) as any;
            const nonce = await provider.getTransactionCount(w.address, 'pending');
            const tx = await c[mintFn](count, {
              value: valueWei, nonce, gasLimit, maxFeePerGas, maxPriorityFeePerGas, chainId: net.chainId,
            });
            updateResult(w.address, { status: 'pending', txHash: tx.hash, message: 'broadcast — waiting for confirmation' });
            const receipt = await tx.wait();
            if (receipt && receipt.status === 1) {
              updateResult(w.address, { status: 'success', txHash: tx.hash, message: `minted ${count}` });
            } else {
              updateResult(w.address, { status: 'failed', txHash: tx.hash, message: 'tx reverted' });
            }
          } catch (e: any) {
            updateResult(w.address, {
              status: 'failed',
              message: e?.shortMessage || e?.reason || e?.message || 'mint failed',
            });
          }
        }),
      );

      addStatus('Mint round complete — see per-wallet results.');
      await refreshSale();
      await fetchWalletBalances();
      // Re-bind explorer chainId for links from the actually-connected network.
      setChainId(String(onchainChainId));
    } catch (e: any) {
      addStatus(`Mint error: ${e?.shortMessage || e?.message || e}`);
    } finally {
      setIsProcessing(false);
    }
  };

  useEffect(() => {
    if (generatedWallets.length > 0) fetchWalletBalances();
    else setWalletBalances({});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [generatedWallets, rpcUrl]);

  // Live preview of the mint plan for the operator (read-only, from dashboard reads).
  const previewPlan = saleData
    ? selectMintPlan(saleData.phase, saleData.earlyBirdPriceWei, saleData.publicPriceWei)
    : null;
  const previewValueEth = saleData && previewPlan?.mintable && previewPlan.unitPriceWei !== undefined && nftsPerWallet > 0
    ? ethers.formatEther(previewPlan.unitPriceWei * BigInt(nftsPerWallet))
    : null;

  const explorerChainId = Number(chainId) || 1;

  const input = 'w-full px-3 py-2 bg-white/5 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500';
  const card = 'bg-white/10 backdrop-blur-md rounded-xl p-6 border border-white/20';
  const label = 'block text-sm font-medium text-blue-200 mb-2';

  return (
    <div className="min-h-screen bg-gradient-to-br from-amber-950 via-stone-900 to-indigo-950 p-6">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-8">
          <h1 className="text-4xl font-bold text-white mb-2">WORDBANK Mint Bot</h1>
          <p className="text-blue-200">Mainnet multi-wallet mint — one mint transaction per imported wallet, fired together. Works in early-bird and public phases.</p>
        </div>

        {/* Mainnet safety banner */}
        <div className="bg-amber-500/10 border border-amber-400/40 rounded-xl p-4 mb-6 text-amber-100 text-sm">
          <strong>Mainnet — real ETH.</strong> Do a live smoke test with ONE wallet + count 1 first, confirm it mints, THEN import the rest.
          Keys stay in your browser; never commit <code>wallets*.json</code>. Send the exact on-chain price; underfunded wallets are skipped, not reverted.
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Connection */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Connection</h2>
            <div className="space-y-4">
              <div>
                <label className={label}>RPC URL (mainnet = your mainnet RPC)</label>
                <input className={input} value={rpcUrl} onChange={(e) => setRpcUrl(e.target.value)} placeholder="https://… (mainnet)" />
              </div>
              <div className="grid grid-cols-3 gap-3">
                <div>
                  <label className={label}>Chain ID</label>
                  <input className={input} value={chainId} onChange={(e) => setChainId(e.target.value)} placeholder="1" />
                </div>
                <div className="col-span-2">
                  <label className={label}>WordBank address</label>
                  <input className={input} value={contractAddress} onChange={(e) => setContractAddress(e.target.value)} placeholder="0x63a9…1218" />
                </div>
              </div>
              <div>
                <label className={label}>Primary private key (only for fund/sweep/admin — NOT needed to mint) — stays in your browser</label>
                <input type="password" className={input} value={primaryPrivateKey} onChange={(e) => setPrimaryPrivateKey(e.target.value)} placeholder="0x… (optional)" />
              </div>
            </div>
          </div>

          {/* Sale dashboard (read-only) */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Sale dashboard</h2>
            {!saleData ? (
              <p className="text-blue-200 text-sm">Set RPC + contract address to read the live sale state.</p>
            ) : (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-3">
                  <Stat label="Phase" value={saleData.phaseLabel} highlight={saleData.phase === SalePhase.EarlyBird || saleData.phase === SalePhase.PublicSale} />
                  <Stat label={saleData.phase === SalePhase.EarlyBird ? 'Early-bird price' : 'Public price'} value={`${saleData.phase === SalePhase.EarlyBird ? saleData.earlyBirdPriceEth : saleData.publicPriceEth} ETH`} />
                  <Stat label="Early bird" value={`${saleData.earlyBirdMinted} / ${saleData.earlyBirdAllocation}`} />
                  <Stat label="Public" value={`${saleData.publicMinted} / ${saleData.publicAllocation}`} />
                  <Stat label="Total minted" value={`${saleData.totalMinted} / ${saleData.maxSupply}`} />
                  <Stat label="EB wallet cap" value={saleData.earlyBirdWalletCap.toString()} />
                </div>
                <button onClick={refreshSale} className="text-blue-300 hover:text-blue-200 text-sm flex items-center gap-2">
                  <RefreshCw className="w-4 h-4" /> Refresh
                </button>
              </div>
            )}
          </div>

          {/* Wallets — import is primary */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Wallets (import to mint from)</h2>
            <div className="space-y-4">
              {importedFileName && <p className="text-sm text-blue-200">Loaded: {importedFileName} — {generatedWallets.length} wallets</p>}
              <div className="flex gap-2">
                <Btn onClick={() => fileInputRef.current?.click()} disabled={isProcessing} color="bg-purple-600" icon={<HardDriveUpload className="w-4 h-4" />}>Import JSON</Btn>
                <Btn onClick={exportPrivateKeys} disabled={isProcessing || !generatedWallets.length} color="bg-purple-800" icon={<HardDriveDownload className="w-4 h-4" />}>Export</Btn>
                <Btn onClick={resetWallets} disabled={isProcessing} color="bg-gray-700" icon={<RefreshCw className="w-4 h-4" />}>Reset</Btn>
              </div>
              <input ref={fileInputRef} type="file" accept=".json" onChange={handleFileUpload} className="hidden" />
              <div>
                <label className={label}>…or paste private keys (one per line)</label>
                <textarea className={`${input} font-mono text-xs h-20`} value={pastedKeys} onChange={(e) => setPastedKeys(e.target.value)} placeholder={'0x…\n0x…'} />
                <Btn onClick={importPastedKeys} disabled={isProcessing || !pastedKeys.trim()} color="bg-purple-600" full>Import pasted keys</Btn>
              </div>
              <details className="text-sm text-blue-200">
                <summary className="cursor-pointer">Generate fresh wallets (secondary)</summary>
                <div className="mt-3 grid grid-cols-2 gap-3 items-end">
                  <div><label className={label}>Number</label><input type="number" min={1} max={500} className={input} value={walletCount} onChange={(e) => setWalletCount(parseInt(e.target.value) || 1)} /></div>
                  <Btn onClick={generateWallets} disabled={isProcessing} color="bg-blue-600" icon={<Wallet className="w-4 h-4" />}>Generate</Btn>
                </div>
              </details>
            </div>
          </div>

          {/* Optional fund / sweep */}
          <div className={card}>
            <h2 className="text-xl font-semibold text-white mb-4">Fund / sweep (optional)</h2>
            <div className="space-y-4">
              <p className="text-xs text-blue-300">Uses the primary key above. Simple parallel sends (no batching). Skip these if your wallets are already funded.</p>
              <div><label className={label}>Funding each (ETH)</label><input type="number" step="0.001" className={input} value={fundingAmount} onChange={(e) => setFundingAmount(e.target.value)} /></div>
              <div className="flex gap-2">
                <Btn onClick={fundWallets} disabled={isProcessing || !generatedWallets.length || !primaryPrivateKey} color="bg-green-700" icon={<Send className="w-4 h-4" />} full>Fund wallets</Btn>
                <Btn onClick={sweepAllToPrimary} disabled={isProcessing || !generatedWallets.length || !primaryPrivateKey} color="bg-red-800" icon={<Send className="w-4 h-4" />} full>Sweep → primary</Btn>
              </div>
              <Btn onClick={fetchWalletBalances} disabled={isProcessing || !generatedWallets.length} color="bg-stone-600" icon={<RefreshCw className="w-4 h-4" />} full>Refresh balances</Btn>
            </div>
          </div>
        </div>

        {/* THE MINT */}
        <div className={`${card} mt-6`}>
          <h2 className="text-xl font-semibold text-white mb-4 flex items-center gap-2"><Play className="w-5 h-5" /> Mint — one tx per wallet, fired together</h2>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="space-y-4">
              <div><label className={label}>NFTs per wallet (each wallet mints this many in its one tx)</label><input type="number" min={1} className={input} value={nftsPerWallet} onChange={(e) => setNftsPerWallet(parseInt(e.target.value) || 1)} /></div>
              {saleData && (
                <div className="text-sm text-blue-200 space-y-1">
                  {previewPlan?.mintable ? (
                    <>
                      <div>Live phase: <span className="text-white font-medium">{saleData.phaseLabel}</span> → calls <code className="text-amber-300">{previewPlan.fn}({nftsPerWallet})</code></div>
                      <div>Exact value per wallet: <span className="text-white font-mono">{previewValueEth} ETH</span></div>
                      {saleData.phase === SalePhase.EarlyBird && saleData.earlyBirdWalletCap === 0n && (
                        <div className="text-red-300">Early-bird wallet cap is 0 — all early-bird mints are blocked.</div>
                      )}
                    </>
                  ) : (
                    <div className="text-red-300">Mint disabled: {previewPlan?.reason ?? '—'}</div>
                  )}
                </div>
              )}
              <p className="text-xs text-blue-300">Each wallet sends exactly one mint tx with msg.value = on-chain price × count. Wallets short on funds are skipped (never reverted). Each wallet is its own signer with its own nonce, so all txs fire in parallel without nonce contention.</p>
            </div>
            <div className="flex flex-col justify-end">
              <Btn onClick={mintFromAllWallets} disabled={isProcessing || !generatedWallets.length || !contractAddress || (previewPlan ? !previewPlan.mintable : false)} color="bg-orange-600" icon={isProcessing ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />} full>
                {isProcessing ? 'Minting…' : `Mint from ${generatedWallets.length} wallet${generatedWallets.length === 1 ? '' : 's'}`}
              </Btn>
            </div>
          </div>

          {/* Per-wallet results */}
          {mintResults.length > 0 && (
            <div className="mt-6">
              <h3 className="text-sm font-semibold text-white mb-2">Per-wallet results</h3>
              <div className="max-h-72 overflow-y-auto space-y-2">
                {mintResults.map((r) => (
                  <div key={r.address} className="bg-white/5 rounded-lg p-3 text-sm flex items-center justify-between gap-3">
                    <span className="font-mono text-xs text-white break-all">{r.address.slice(0, 10)}…{r.address.slice(-6)}</span>
                    <span className="flex items-center gap-3 text-xs whitespace-nowrap">
                      <ResultBadge status={r.status} />
                      {r.message && <span className="text-blue-200 max-w-[18rem] truncate" title={r.message}>{r.message}</span>}
                      {r.txHash && (
                        <a className="text-blue-300 hover:text-blue-200 flex items-center gap-1" href={explorerTxUrl(explorerChainId, r.txHash)} target="_blank" rel="noreferrer">
                          tx <ExternalLink className="w-3 h-3" />
                        </a>
                      )}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Sale admin (secondary) */}
        <details className={`${card} mt-6`}>
          <summary className="text-xl font-semibold text-white cursor-pointer flex items-center gap-2"><Settings className="w-5 h-5" /> Sale admin (owner only — secondary)</summary>
          <div className="space-y-3 mt-4">
            <p className="text-xs text-blue-300">The dApp admin panel now owns sale configuration. These helpers stay for convenience and use the primary key as the owner.</p>
            <div className="grid grid-cols-2 gap-3">
              <div><label className={label}>EB allocation</label><input type="number" className={input} value={ebAlloc} onChange={(e) => setEbAlloc(parseInt(e.target.value) || 0)} /></div>
              <div><label className={label}>Public allocation</label><input type="number" className={input} value={pubAlloc} onChange={(e) => setPubAlloc(parseInt(e.target.value) || 0)} /></div>
              <div><label className={label}>EB price (ETH)</label><input className={input} value={ebPriceEth} onChange={(e) => setEbPriceEth(e.target.value)} /></div>
              <div><label className={label}>Public price (ETH)</label><input className={input} value={pubPriceEth} onChange={(e) => setPubPriceEth(e.target.value)} /></div>
              <div><label className={label}>EB wallet cap</label><input type="number" className={input} value={ebWalletCap} onChange={(e) => setEbWalletCap(parseInt(e.target.value) || 0)} /></div>
            </div>
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
        </details>

        {/* Wallet list */}
        {generatedWallets.length > 0 && (
          <div className={`${card} mt-6`}>
            <div className="flex justify-between items-center mb-4">
              <h2 className="text-xl font-semibold text-white">Wallets ({generatedWallets.length})</h2>
              <button onClick={fetchWalletBalances} disabled={isProcessing} className="text-blue-300 hover:text-blue-200 text-sm flex items-center gap-2"><RefreshCw className="w-4 h-4" /> Balances</button>
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

function ResultBadge({ status }: { status: MintStatus }) {
  const map: Record<MintStatus, { text: string; cls: string }> = {
    idle: { text: 'idle', cls: 'bg-white/10 text-gray-300' },
    checking: { text: 'checking', cls: 'bg-blue-500/20 text-blue-200' },
    skipped: { text: 'skipped', cls: 'bg-yellow-500/20 text-yellow-200' },
    pending: { text: 'pending', cls: 'bg-blue-500/20 text-blue-200' },
    success: { text: 'success', cls: 'bg-green-500/20 text-green-300' },
    failed: { text: 'failed', cls: 'bg-red-500/20 text-red-300' },
  };
  const m = map[status];
  return <span className={`px-2 py-0.5 rounded ${m.cls}`}>{m.text}</span>;
}

function Btn({ onClick, disabled, color, icon, children, full }: { onClick: () => void; disabled?: boolean; color: string; icon?: React.ReactNode; children: React.ReactNode; full?: boolean }) {
  return (
    <button onClick={onClick} disabled={disabled} className={`${color} hover:opacity-90 disabled:bg-gray-600 disabled:opacity-100 text-white px-4 py-2 rounded-lg font-medium transition-all flex items-center justify-center gap-2 text-sm ${full ? 'w-full' : 'flex-1'}`}>
      {icon}{children}
    </button>
  );
}
