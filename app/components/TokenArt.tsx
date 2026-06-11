"use client";

import { useEffect, useState } from "react";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { getPublicClient } from "@/lib/contracts/chain";

/**
 * On-chain token artwork. Reads WordBank.tokenURI(id) (Base64 JSON → `image`)
 * and renders it — the authoritative art, including honors one-of-ones and the
 * pre-reveal placeholder (tokenURI returns the Renderer's unrevealedTokenURI
 * before the offset is set). Replaces the design-twin <WordArt> at wiring.
 * Art is immutable post-reveal, so results are cached per tokenId.
 */
const cache = new Map<number, string>();

function decodeImage(uri: string): string | null {
  try {
    let json: string;
    if (uri.startsWith("data:application/json;base64,")) {
      json = atob(uri.slice("data:application/json;base64,".length));
    } else if (uri.startsWith("data:application/json")) {
      json = decodeURIComponent(uri.slice(uri.indexOf(",") + 1));
    } else {
      return null;
    }
    const meta = JSON.parse(json) as { image?: string };
    return meta.image ?? null;
  } catch {
    return null;
  }
}

export function TokenArt({
  tokenId,
  alt,
  className,
}: {
  tokenId: number;
  alt: string;
  className?: string;
}) {
  const [image, setImage] = useState<string | null>(cache.get(tokenId) ?? null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (image || !isDeployed("wordBank")) return;
    let cancelled = false;
    getPublicClient()
      .readContract({
        address: requireAddress("wordBank"),
        abi: wordBankAbi,
        functionName: "tokenURI",
        args: [BigInt(tokenId)],
      })
      .then((uri) => {
        if (cancelled) return;
        const img = decodeImage(uri as string);
        if (img) {
          cache.set(tokenId, img);
          setImage(img);
        } else {
          setFailed(true);
        }
      })
      .catch(() => !cancelled && setFailed(true));
    return () => {
      cancelled = true;
    };
  }, [tokenId, image]);

  const style: React.CSSProperties = {
    width: "100%",
    height: "100%",
    objectFit: "contain",
    display: "block",
    borderRadius: "inherit",
  };

  if (failed) {
    return (
      <div
        className={className}
        style={{ ...style, background: "var(--ink)" }}
        aria-label={`${alt} (art unavailable)`}
        role="img"
      />
    );
  }
  if (!image) {
    return <div className={`${className ?? ""} skeleton`} style={style} aria-hidden="true" />;
  }
  // eslint-disable-next-line @next/next/no-img-element
  return <img className={className} style={style} src={image} alt={alt} />;
}
