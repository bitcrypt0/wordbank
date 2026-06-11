"use client";

import type { PublicClient } from "viem";
import { wordTokenAbi, wordBankAbi, bountyEngineAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { Stat } from "@/components/ui";
import { formatInt, formatWord, formatEth } from "@/lib/format";
import styles from "@/app/home.module.css";

interface HeroData {
  supplyWei: bigint;
  burnedWei: bigint;
  totalAlive: number;
  treasuryWei: bigint;
}

/** Live protocol stat strip (HANDOFF §2). Falls back to a quiet dash pre-deploy. */
export function HeroStats() {
  const { data } = useChainData<HeroData>(async (client: PublicClient) => {
    if (!isDeployed("wordToken") || !isDeployed("wordBank") || !isDeployed("bountyEngine")) {
      throw new NotDeployedError();
    }
    const r = await client.multicall({
      allowFailure: false,
      contracts: [
        { address: requireAddress("wordToken"), abi: wordTokenAbi, functionName: "totalSupply" },
        { address: requireAddress("wordToken"), abi: wordTokenAbi, functionName: "burnedTotal" },
        { address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "totalAlive" },
        { address: requireAddress("bountyEngine"), abi: bountyEngineAbi, functionName: "freeTreasury" },
      ],
    });
    return {
      supplyWei: r[0] as bigint,
      burnedWei: r[1] as bigint,
      totalAlive: Number(r[2]),
      treasuryWei: r[3] as bigint,
    };
  });

  return (
    <section className="container">
      <div className={`plate ${styles.stats}`}>
        <Stat
          label="WORD supply"
          value={data ? formatWord(data.supplyWei) : "—"}
          detail="shrinking toward the living backing floor"
        />
        <Stat
          label="Burned so far"
          value={data ? formatWord(data.burnedWei) : "—"}
          detail="cumulative, for the protocol's life"
          tone="ok"
        />
        <Stat
          label="Words alive"
          value={data ? formatInt(data.totalAlive) : "—"}
          detail="of 10,000 minted"
        />
        <Stat
          label="Bounty treasury"
          value={data ? `${formatEth(data.treasuryWei, 3)} ETH` : "—"}
          detail="funds the daily sentence game"
        />
      </div>
    </section>
  );
}
