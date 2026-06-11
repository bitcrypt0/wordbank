"use client";

import type { PublicClient } from "viem";
import {
  wordBankAbi,
  wordTokenAbi,
  feeHookAbi,
  burnEngineAbi,
  lpLockerAbi,
  bountyEngineAbi,
  royaltySplitterAbi,
} from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { useWallet } from "@/lib/wallet/WalletProvider";

const ZERO = "0x0000000000000000000000000000000000000000";

export interface AdminData {
  // gate
  wordBankOwner: string;
  isOwner: boolean;
  tokenOwner: string;
  tokenRenounced: boolean;
  // sale / phase / provenance
  phase: number;
  earlyBirdAllocation: number;
  publicAllocation: number;
  earlyBirdPriceWei: bigint;
  publicPriceWei: bigint;
  earlyBirdWalletCap: number;
  adminMinted: number;
  proceedsWei: bigint;
  slotsLocked: boolean;
  offsetSet: boolean;
  registrySynced: boolean;
  registryCursor: number;
  registryTarget: number;
  // royalty
  royaltyReceiver: string;
  royaltyBps: number;
  maxRoyaltyBps: number;
  // economics (FeeHook)
  feeBps: number;
  maxFeeBps: number;
  rewardsBps: number;
  bountyBps: number;
  burnBps: number;
  postRewardsBps: number;
  postBountyBps: number;
  burnSplitBounds: { rMin: number; rMax: number; bMin: number; bMax: number; uMin: number; uMax: number };
  postSplitBounds: { rMin: number; rMax: number; bMin: number; bMax: number };
  // guard
  tradingEnabledAt: number;
  guardActive: boolean;
  guardSunset: boolean;
  guardDuration: number;
  // burn engine
  maxSlippageBps: number;
  maxSlippageCeil: number;
  // lock
  lockLocked: boolean;
  lockedUntil: number;
  lockPermanent: boolean;
  minLockDuration: number;
  // bounty
  tiersWei: bigint[];
  minTierWei: bigint;
  maxTierWei: bigint;
  maxTiers: number;
  templateCount: number;
  maxTemplates: number;
  maxSlots: number;
  // token owner panel
  mintingSealed: boolean;
  burner: string;
  // royalty plumbing
  pendingDistributionWei: bigint;
  pendingAdminWei: bigint;
}

export function useAdminData() {
  const { account } = useWallet();

  return useChainData<AdminData>(
    async (client: PublicClient) => {
      const required: Parameters<typeof isDeployed>[0][] = [
        "wordBank", "wordToken", "feeHook", "burnEngine", "lpLocker", "bountyEngine", "royaltySplitter",
      ];
      for (const k of required) if (!isDeployed(k)) throw new NotDeployedError();

      const bank = requireAddress("wordBank");
      const token = requireAddress("wordToken");
      const hook = requireAddress("feeHook");
      const burn = requireAddress("burnEngine");
      const locker = requireAddress("lpLocker");
      const bounty = requireAddress("bountyEngine");
      const splitter = requireAddress("royaltySplitter");

      const [bankR, royaltyR, tokenR, hookR, burnR, lockR, bountyR, splitR, proceeds] = await Promise.all([
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: bank, abi: wordBankAbi, functionName: "owner" },
            { address: bank, abi: wordBankAbi, functionName: "phase" },
            { address: bank, abi: wordBankAbi, functionName: "earlyBirdAllocation" },
            { address: bank, abi: wordBankAbi, functionName: "publicAllocation" },
            { address: bank, abi: wordBankAbi, functionName: "earlyBirdPrice" },
            { address: bank, abi: wordBankAbi, functionName: "publicPrice" },
            { address: bank, abi: wordBankAbi, functionName: "earlyBirdWalletCap" },
            { address: bank, abi: wordBankAbi, functionName: "adminMinted" },
            { address: bank, abi: wordBankAbi, functionName: "slotsLocked" },
            { address: bank, abi: wordBankAbi, functionName: "offsetSet" },
            { address: bank, abi: wordBankAbi, functionName: "registrySynced" },
            { address: bank, abi: wordBankAbi, functionName: "registryCursor" },
            { address: bank, abi: wordBankAbi, functionName: "preRevealMinted" },
            { address: bank, abi: wordBankAbi, functionName: "MAX_ROYALTY_BPS" },
          ],
        }),
        client.readContract({ address: bank, abi: wordBankAbi, functionName: "royaltyInfo", args: [0n, 10_000n] }),
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: token, abi: wordTokenAbi, functionName: "owner" },
            { address: token, abi: wordTokenAbi, functionName: "mintingSealed" },
            { address: token, abi: wordTokenAbi, functionName: "burner" },
          ],
        }),
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: hook, abi: feeHookAbi, functionName: "feeBps" },
            { address: hook, abi: feeHookAbi, functionName: "MAX_FEE_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "rewardsBps" },
            { address: hook, abi: feeHookAbi, functionName: "bountyBps" },
            { address: hook, abi: feeHookAbi, functionName: "burnBps" },
            { address: hook, abi: feeHookAbi, functionName: "postRewardsBps" },
            { address: hook, abi: feeHookAbi, functionName: "postBountyBps" },
            { address: hook, abi: feeHookAbi, functionName: "tradingEnabledAt" },
            { address: hook, abi: feeHookAbi, functionName: "guardActive" },
            { address: hook, abi: feeHookAbi, functionName: "guardSunset" },
            { address: hook, abi: feeHookAbi, functionName: "GUARD_DURATION" },
            { address: hook, abi: feeHookAbi, functionName: "BURN_PHASE_REWARDS_MIN_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "BURN_PHASE_REWARDS_MAX_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "BURN_PHASE_BOUNTY_MIN_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "BURN_PHASE_BOUNTY_MAX_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "BURN_PHASE_BURN_MIN_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "BURN_PHASE_BURN_MAX_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "POST_BURN_REWARDS_MIN_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "POST_BURN_REWARDS_MAX_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "POST_BURN_BOUNTY_MIN_BPS" },
            { address: hook, abi: feeHookAbi, functionName: "POST_BURN_BOUNTY_MAX_BPS" },
          ],
        }),
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: burn, abi: burnEngineAbi, functionName: "maxSlippageBps" },
            { address: burn, abi: burnEngineAbi, functionName: "MAX_SLIPPAGE_BPS" },
          ],
        }),
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: locker, abi: lpLockerAbi, functionName: "locked" },
            { address: locker, abi: lpLockerAbi, functionName: "lockedUntil" },
            { address: locker, abi: lpLockerAbi, functionName: "PERMANENT" },
            { address: locker, abi: lpLockerAbi, functionName: "MIN_LOCK_DURATION" },
          ],
        }),
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: bounty, abi: bountyEngineAbi, functionName: "tiers" },
            { address: bounty, abi: bountyEngineAbi, functionName: "MIN_TIER_VALUE" },
            { address: bounty, abi: bountyEngineAbi, functionName: "MAX_TIER_VALUE" },
            { address: bounty, abi: bountyEngineAbi, functionName: "MAX_TIERS" },
            { address: bounty, abi: bountyEngineAbi, functionName: "templateCount" },
            { address: bounty, abi: bountyEngineAbi, functionName: "MAX_TEMPLATES" },
            { address: bounty, abi: bountyEngineAbi, functionName: "MAX_SLOTS" },
          ],
        }),
        client.multicall({
          allowFailure: false,
          contracts: [
            { address: splitter, abi: royaltySplitterAbi, functionName: "pendingDistribution" },
            { address: splitter, abi: royaltySplitterAbi, functionName: "pendingAdmin" },
          ],
        }),
        client.getBalance({ address: bank }),
      ]);

      const royalty = royaltyR as readonly [string, bigint];
      const tokenOwner = String(tokenR[0]);
      const lockedUntilRaw = lockR[1] as bigint;
      const lockPermanent = lockedUntilRaw === (lockR[2] as bigint);

      return {
        wordBankOwner: String(bankR[0]),
        isOwner: !!account && String(bankR[0]).toLowerCase() === account.toLowerCase(),
        tokenOwner,
        tokenRenounced: tokenOwner.toLowerCase() === ZERO,
        phase: Number(bankR[1]),
        earlyBirdAllocation: Number(bankR[2]),
        publicAllocation: Number(bankR[3]),
        earlyBirdPriceWei: bankR[4] as bigint,
        publicPriceWei: bankR[5] as bigint,
        earlyBirdWalletCap: Number(bankR[6]),
        adminMinted: Number(bankR[7]),
        proceedsWei: proceeds,
        slotsLocked: Boolean(bankR[8]),
        offsetSet: Boolean(bankR[9]),
        registrySynced: Boolean(bankR[10]),
        registryCursor: Number(bankR[11]),
        registryTarget: Number(bankR[12]) || 10000,
        royaltyReceiver: royalty[0],
        royaltyBps: Number(royalty[1]),
        maxRoyaltyBps: Number(bankR[13]),
        feeBps: Number(hookR[0]),
        maxFeeBps: Number(hookR[1]),
        rewardsBps: Number(hookR[2]),
        bountyBps: Number(hookR[3]),
        burnBps: Number(hookR[4]),
        postRewardsBps: Number(hookR[5]),
        postBountyBps: Number(hookR[6]),
        tradingEnabledAt: Number(hookR[7]),
        guardActive: Boolean(hookR[8]),
        guardSunset: Boolean(hookR[9]),
        guardDuration: Number(hookR[10]),
        burnSplitBounds: {
          rMin: Number(hookR[11]), rMax: Number(hookR[12]),
          bMin: Number(hookR[13]), bMax: Number(hookR[14]),
          uMin: Number(hookR[15]), uMax: Number(hookR[16]),
        },
        postSplitBounds: {
          rMin: Number(hookR[17]), rMax: Number(hookR[18]),
          bMin: Number(hookR[19]), bMax: Number(hookR[20]),
        },
        maxSlippageBps: Number(burnR[0]),
        maxSlippageCeil: Number(burnR[1]),
        lockLocked: Boolean(lockR[0]),
        lockedUntil: lockPermanent ? 0 : Number(lockedUntilRaw),
        lockPermanent,
        minLockDuration: Number(lockR[3]),
        tiersWei: [...(bountyR[0] as bigint[])],
        minTierWei: bountyR[1] as bigint,
        maxTierWei: bountyR[2] as bigint,
        maxTiers: Number(bountyR[3]),
        templateCount: Number(bountyR[4]),
        maxTemplates: Number(bountyR[5]),
        maxSlots: Number(bountyR[6]),
        mintingSealed: Boolean(tokenR[1]),
        burner: String(tokenR[2]),
        pendingDistributionWei: splitR[0] as bigint,
        pendingAdminWei: splitR[1] as bigint,
      };
    },
    [account],
    { refetchInterval: 20_000 },
  );
}
