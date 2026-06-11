import { WordbankGlyph } from "./Logo";
import styles from "./ComingSoon.module.css";

/**
 * Placeholder for surfaces scheduled in later milestones — designed, honest,
 * never a dead end. Each names what the finished surface will hold so the
 * owner can review scope while it's still on the drawing board.
 */
export function ComingSoon({
  surface,
  description,
  contents,
}: {
  surface: string;
  description: string;
  contents: string[];
}) {
  return (
    <div className="container">
      <div className={`plate ${styles.box}`}>
        <WordbankGlyph size={40} />
        <p className="eyebrow">In the studio — next milestone</p>
        <h1 className={styles.title}>{surface}</h1>
        <p className={styles.desc}>{description}</p>
        <ul className={styles.list}>
          {contents.map((c) => (
            <li key={c}>{c}</li>
          ))}
        </ul>
      </div>
    </div>
  );
}
