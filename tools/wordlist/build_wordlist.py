#!/usr/bin/env python3
"""Builds assets/wordlist.json: 10,000 distinct, category-tagged words.

Sources (tools/wordlist/data/):
  dict/index.{noun,verb,adj,adv}  WordNet 3.1 — POS membership, base-form lemmas
  en_50k.txt                      frequency list (hermitdave/FrequencyWords) — quality ranking
  badwords_en.txt                 LDNOOBW blocklist — public-collection hygiene

Selection rules:
  - single lowercase a-z words, 3..12 chars, present in WordNet for the
    assigned POS and ranked by corpus frequency (common, recognizable words
    first — these words are the art and get read aloud in sentences)
  - each word appears exactly once, in exactly one category; multi-POS words
    go to the scarcest eligible category quota
  - quotas (noun/verb-heavy so sentence templates keep filling late into the
    collection burn-down): 5,000 NOUN / 2,500 VERB / 1,700 ADJ / 800 ADV
  - the 25 honors words ship with their normative categories and capitalized
    display forms; their lowercase twins are excluded from the regular pool

Run:  python tools/wordlist/build_wordlist.py
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = Path(__file__).resolve().parent / "data"
OUT = ROOT / "assets" / "wordlist.json"

# Regular-pool quotas are FROZEN at their original net values (4,987 N /
# 2,488 V / 1,700 ADJ / 800 ADV) so that recategorizing an honors word (Degen
# NOUN -> ADJ, owner-directed 2026-06-12) never reshuffles the regular pool or
# the seeded trait assignment. With honors now 12 N / 12 V / 1 ADJ, the shipped
# totals are 4,999 NOUN / 2,500 VERB / 1,701 ADJ / 800 ADV.
QUOTAS = {"NOUN": 4987, "VERB": 2488, "ADJ": 1700, "ADV": 800}

HONORS = {  # word -> category (NORMATIVE, architecture pre-build decisions)
    "Rekt": "VERB", "Pepe": "NOUN", "Degen": "ADJ", "Lambo": "NOUN", "Snipe": "VERB",
    "Liquid": "NOUN", "Pump": "VERB", "Dump": "VERB", "Rug": "VERB", "Floor": "NOUN",
    "Yield": "NOUN", "Swap": "VERB", "Trade": "VERB", "Stake": "VERB", "Airdrop": "NOUN",
    "Farm": "VERB", "Satoshi": "NOUN", "Hype": "VERB", "Fee": "NOUN", "Gas": "NOUN",
    "Sweep": "VERB", "Mint": "VERB", "Dev": "NOUN", "Token": "NOUN", "Moon": "NOUN",
}

WORD_RE = re.compile(r"^[a-z]{3,12}$")

# Closed-class / function words and conversational fillers: never art-worthy and
# poison sentence templates ("The but softly haves the all").
STOPWORDS = set(
    """the a an and or but nor for yet so if then than that this these those there here
    not no yes yeah yep nah okay also too very just only even still about out now
    have has had having be am is are was were been being do does did doing done
    don didn doesn isn wasn aren weren won wouldn couldn shouldn
    can could will would shall should may might must ought need dare
    i you he she it we they me him her us them my your his its our their mine yours
    hers ours theirs myself yourself himself herself itself ourselves themselves
    who whom whose which what when where why how whatever whoever whenever wherever
    of in on at by to from with without within into onto upon over under above below
    between among through during before after since until till against toward towards
    across behind beside besides beyond near next off per via amid amidst
    some any all both each every either neither few many much more most other another
    such own same several enough little less least lot lots
    one two three four five six seven eight nine ten first second third
    well anyway anyhow however therefore thus hence moreover furthermore meanwhile
    instead otherwise nonetheless nevertheless although though because while whereas
    gonna gotta wanna kinda sorta dunno ain etc mr mrs ms dr sir madam
    am pm oh ah uh um hmm hey hi hello bye god damn heck darn""".split()
)


def wordnet_lemmas(pos_file: str) -> dict[str, int]:
    """lemma -> synset count for one POS index."""
    lemmas: dict[str, int] = {}
    for line in (DATA / "dict" / pos_file).read_text(encoding="utf-8").splitlines():
        if line.startswith(" "):
            continue
        parts = line.split(" ")
        lemma = parts[0]
        if WORD_RE.match(lemma):
            lemmas[lemma] = int(parts[2])
    return lemmas


def proper_only_nouns() -> set[str]:
    """Words that occur in WordNet data files ONLY with capitalized lemmas
    (Ohio, June, Aristotle) — proper nouns that read wrong in sentences."""
    cap_seen: set[str] = set()
    low_seen: set[str] = set()
    for fname in ("data.noun", "data.adj"):
        for line in (DATA / "dict" / fname).read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split(" ")
            if len(parts) < 5 or not parts[0].isdigit():
                continue
            try:
                w_cnt = int(parts[3], 16)
            except ValueError:
                continue
            for i in range(w_cnt):
                lemma = parts[4 + i * 2]
                base = lemma.split("(")[0]
                if base.lower() != base:
                    cap_seen.add(base.lower())
                else:
                    low_seen.add(base)
    return cap_seen - low_seen


def inflected_forms() -> set[str]:
    """Left-hand side of WordNet exception files = irregular inflections
    (finer, feet, went) — never base forms, excluded."""
    forms: set[str] = set()
    for fname in ("noun.exc", "verb.exc", "adj.exc", "adv.exc"):
        for line in (DATA / "dict" / fname).read_text(encoding="utf-8").splitlines():
            parts = line.split(" ")
            if parts and WORD_RE.match(parts[0]):
                forms.add(parts[0])
    return forms


def main() -> None:
    pools = {
        "NOUN": wordnet_lemmas("index.noun"),
        "VERB": wordnet_lemmas("index.verb"),
        "ADJ": wordnet_lemmas("index.adj"),
        "ADV": wordnet_lemmas("index.adv"),
    }

    freq_rank: dict[str, int] = {}
    for rank, line in enumerate((DATA / "en_50k.txt").read_text(encoding="utf-8").splitlines()):
        w = line.split(" ", 1)[0]
        if w not in freq_rank:
            freq_rank[w] = rank

    blocked = {
        w.strip().lower()
        for w in (DATA / "badwords_en.txt").read_text(encoding="utf-8").splitlines()
        if w.strip()
    }
    blocked |= STOPWORDS
    blocked |= proper_only_nouns()
    blocked |= inflected_forms()
    honors_lower = {w.lower() for w in HONORS}

    # Candidates: frequency-ranked words that exist in at least one WordNet POS.
    chosen: dict[str, str] = {}
    counts = {c: 0 for c in QUOTAS}
    # Assignment: a word goes to its DOMINANT WordNet POS (most synsets — "time"
    # is a noun, "run" is a verb); if that quota is full, it falls to its next
    # most-senseful eligible category. Keeps grammar natural in sentences.
    for w in sorted(freq_rank, key=freq_rank.get):
        if not WORD_RE.match(w) or w in blocked or w in honors_lower or w in chosen:
            continue
        eligible = [c for c in QUOTAS if w in pools[c] and counts[c] < QUOTAS[c]]
        if not eligible:
            continue
        cat = max(eligible, key=lambda c: pools[c][w])
        chosen[w] = cat
        counts[cat] += 1
        if sum(counts.values()) == sum(QUOTAS.values()):
            break

    # If the frequency list ran dry for some category, top up from WordNet
    # alphabetically (rare in practice; ADV is the only category at risk).
    for cat, quota in QUOTAS.items():
        if counts[cat] < quota:
            for w in sorted(pools[cat]):
                if counts[cat] == quota:
                    break
                if w in chosen or w in blocked or w in honors_lower or not WORD_RE.match(w):
                    continue
                chosen[w] = cat
                counts[cat] += 1

    total_regular = sum(counts.values())
    need = 10_000 - len(HONORS)
    if total_regular != need:
        raise SystemExit(f"selected {total_regular} regular words, need {need}; adjust quotas")

    words = [{"word": w, "category": c} for w, c in chosen.items()]
    words += [{"word": w, "category": c} for w, c in HONORS.items()]
    if len(words) != 10_000:
        raise SystemExit(f"final count {len(words)} != 10000")

    final_counts: dict[str, int] = {}
    for e in words:
        final_counts[e["category"]] = final_counts.get(e["category"], 0) + 1

    OUT.write_text(json.dumps({"words": words}, indent=0), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(words)} words, category counts {final_counts}")


if __name__ == "__main__":
    main()
