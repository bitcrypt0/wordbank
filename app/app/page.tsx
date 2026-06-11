import Link from "next/link";
import { WordbankGlyph } from "@/components/Logo";
import { HeroStats } from "@/components/HeroStats";
import { WordArt } from "@/lib/art";
import styles from "./home.module.css";

/**
 * Decorative specimen strip — a curated branding showcase rendered by the
 * design twin (WordArt). The live collection (real onchain art) lives in the
 * gallery; these are illustrative samples that always look good pre-launch.
 */
const SHOWCASE = [
  { tokenId: 7214, word: "ember", material: 4, ink: 0, background: 0, honors: false },
  { tokenId: 5061, word: "luminous", material: 17, ink: 1, background: 4, honors: false },
  { tokenId: 9114, word: "wander", material: 8, ink: 2, background: 2, honors: false },
  { tokenId: 3604, word: "howling", material: 18, ink: 0, background: 5, honors: false },
  { tokenId: 9990, word: "Moon", material: 18, ink: 0, background: 0, honors: true, honorsArtSrc: "/art/honors_moon.svg" },
  { tokenId: 1283, word: "grief", material: 10, ink: 0, background: 0, honors: false },
];

export default function HomePage() {
  const strip = SHOWCASE;

  return (
    <>
      {/* ── Hero: the mark's place of honor ── */}
      <section className={styles.hero}>
        <div className="container">
          <div className={styles.heroMark}>
            <WordbankGlyph size={88} />
          </div>
          <h1 className={styles.heroTitle}>
            Ten thousand words,
            <br />
            fully onchain.
          </h1>
          <p className={styles.heroLede}>
            Every word is an artwork. Every artwork is backed by 1,000 WORD
            tokens, bound to it onchain. A daily sentence game pays bounties to
            the words it draws, holders share the pool's swap fees, and a
            buy-and-burn walks the token supply down to its floor.
          </p>
          <div className={styles.heroCtas}>
            <Link href="/gallery" className="btn">
              Browse the collection
            </Link>
            <Link href="/docs" className="btn btn--ghost">
              How it works
            </Link>
          </div>
        </div>
      </section>

      {/* ── Specimen strip: real renderer output ── */}
      <section aria-label="Sample words from the collection">
        <div className={`container ${styles.strip}`}>
          {strip.map((t) => (
            <Link
              key={t.tokenId}
              href={`/gallery/${t.tokenId}`}
              className={styles.stripItem}
              title={`${t.word} — №${t.tokenId}`}
            >
              <WordArt
                word={t.word}
                material={t.material}
                ink={t.ink}
                background={t.background}
                honors={t.honors}
                honorsArtSrc={"honorsArtSrc" in t ? t.honorsArtSrc : undefined}
                uid={`home-${t.tokenId}`}
              />
            </Link>
          ))}
        </div>
      </section>

      {/* ── Live numbers ── */}
      <HeroStats />

      {/* ── The four chapters ── */}
      <section className={`container ${styles.chapters}`}>
        <Chapter
          n="01"
          title="The word is the art"
          link="/gallery"
          linkLabel="Open the gallery"
        >
          One typeface across the whole collection. Materials — paper,
          parchment, stone, gold leaf — carry the rarity; the word carries the
          meaning. Twenty-five honors words are hand-lettered one-of-ones.
          Visual rarity is pure aesthetics: it never changes a word's odds,
          rewards, or backing.
        </Chapter>
        <Chapter
          n="02"
          title="Backed, not promised"
          link="/gallery"
          linkLabel="Inspect any token"
        >
          Each NFT holds 1,000 WORD in the WordBank vault, keyed to the token
          itself — the backing travels with every sale automatically. Unbinding
          burns the NFT forever and releases its 1,000 WORD. That is the only
          way backing ever moves.
        </Chapter>
        <Chapter
          n="03"
          title="A sentence a day pays bounties"
          link="/game"
          linkLabel="Visit the game console"
        >
          Once a day, anyone holding a word can start the draw. A sentence is
          composed from living words; each word drawn splits a bounty of up to
          0.5 ETH, funded by the pool's swap fees. Claim within seven days.
        </Chapter>
        <Chapter
          n="04"
          title="The burn shrinks WORD toward its living floor"
          link="/token"
          linkLabel="Watch the supply"
        >
          A quarter of every swap fee buys WORD on the open market and burns
          it — from the 11,000,000 cap down toward a living floor: the WORD
          backing the words still alive. That floor can never be breached, and
          it falls further every time a word is unbound, so the burn keeps
          working for the life of the protocol.
        </Chapter>
      </section>
    </>
  );
}

function Chapter({
  n,
  title,
  children,
  link,
  linkLabel,
}: {
  n: string;
  title: string;
  children: React.ReactNode;
  link: string;
  linkLabel: string;
}) {
  return (
    <article className={styles.chapter}>
      <span className={`eyebrow ${styles.chapterNum}`}>{n}</span>
      <h2 className={styles.chapterTitle}>{title}</h2>
      <p className={styles.chapterBody}>{children}</p>
      <Link href={link} className={styles.chapterLink}>
        {linkLabel} →
      </Link>
    </article>
  );
}
