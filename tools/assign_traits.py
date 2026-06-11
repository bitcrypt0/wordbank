#!/usr/bin/env python3
"""Generates the full 10,000-token word/trait assignment (provenance input).

This is the file whose hash gets committed onchain before mint opens (the
snipe-proof provenance pattern): word, category, material, ink, background,
honors for every slot, in a deterministically shuffled order. After the
public sellout fixes the global offset, slot i serves tokenId
((i + offset) % 10000) + 1 — nobody, including us, can aim a legendary.

Inputs:  assets/wordlist.json, assets/traits/materials.json,
         assets/traits/rarity.json, assets/honors/manifest.json
Output:  assets/assignments.json  (+ its keccak256 provenance hash)

Determinism: everything derives from the SEED below; rerunning reproduces the
file byte-for-byte, so the committed hash stays verifiable forever.

Run:  python tools/assign_traits.py
"""

import hashlib
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEED = "WORDBANK-assignment-v1"

CATS = ["NOUN", "VERB", "ADJ", "ADV"]


def main() -> None:
    rng = random.Random(SEED)
    words = json.loads((ROOT / "assets" / "wordlist.json").read_text(encoding="utf-8"))["words"]
    mats = json.loads((ROOT / "assets" / "traits" / "materials.json").read_text(encoding="utf-8"))["materials"]
    rarity = json.loads((ROOT / "assets" / "traits" / "rarity.json").read_text(encoding="utf-8"))
    honors = json.loads((ROOT / "assets" / "honors" / "manifest.json").read_text(encoding="utf-8"))

    tiers = ["Common", "Uncommon", "Rare", "Epic", "Legendary"]
    by_tier: dict[str, list[int]] = {t: [] for t in tiers}
    for idx, m in enumerate(mats):
        by_tier[tiers[m["tier"]]].append(idx)

    # Material weight per token = tierShare / materialsInTier.
    mat_ids = list(range(len(mats)))
    mat_weights = []
    for idx, m in enumerate(mats):
        tier = tiers[m["tier"]]
        mat_weights.append(rarity["tierShares"][tier] / len(by_tier[tier]))

    bias = rarity["biasStrength"]
    entries = []
    honors_words = set(honors)
    for e in words:
        w, cat = e["word"], e["category"]
        if w in honors_words:
            h = honors[w]
            entries.append(
                {"word": w, "category": cat, "material": h["material"], "ink": 0,
                 "background": h["background"], "honors": True}
            )
            continue
        mat_id = rng.choices(mat_ids, weights=mat_weights)[0]
        m = mats[mat_id]
        ink = rng.randrange(len(m["inks"]))
        bgs = m["backgrounds"]
        group = [i for i, b in enumerate(bgs) if b["bias"] == cat]
        if group and rng.random() < bias:
            bg = rng.choice(group)
        else:
            bg = rng.randrange(len(bgs))
        entries.append(
            {"word": w, "category": cat, "material": mat_id, "ink": ink, "background": bg, "honors": False}
        )

    rng.shuffle(entries)

    payload = json.dumps({"seed": SEED, "assignments": entries}, separators=(",", ":"), sort_keys=False)
    # keccak256 to match onchain provenance hashing.
    try:
        from Crypto.Hash import keccak  # pycryptodome, if available

        k = keccak.new(digest_bits=256)
        k.update(payload.encode())
        digest = "0x" + k.hexdigest()
        algo = "keccak256"
    except ImportError:
        digest = "0x" + hashlib.sha3_256(payload.encode()).hexdigest()
        algo = "sha3_256 (NOTE: install pycryptodome for keccak256 before the real commit)"

    out = ROOT / "assets" / "assignments.json"
    out.write_text(payload, encoding="utf-8")

    census: dict[str, int] = {}
    for e in entries:
        t = tiers[mats[e["material"]]["tier"]]
        census[t] = census.get(t, 0) + 1
    print(f"wrote {out.relative_to(ROOT)}: {len(entries)} assignments")
    print(f"tier census: {census}")
    print(f"provenance hash ({algo}): {digest}")


if __name__ == "__main__":
    main()
