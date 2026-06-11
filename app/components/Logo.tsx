import styles from "./Logo.module.css";

/**
 * The WORDBANK mark: a word on a solid ground.
 *
 * The collection's entire art system is "a word set on a solid-color
 * material" — so the mark is the system reduced to one glyph: a solid
 * plate (the single <rect> background rule), a hairline specimen frame,
 * and a serif-cut W. Pure SVG, no raster, crisp from 16px (favicon) to
 * hero scale. Construction notes: app/design/LOGO.md
 *
 * `app/icon.svg` (the favicon) is this exact geometry with fixed colors —
 * keep the two in sync if the mark ever changes.
 */
export function WordbankGlyph({
  size = 28,
  ground = "var(--ink)",
  ink = "var(--paper)",
  title = "WORDBANK",
}: {
  size?: number;
  ground?: string;
  ink?: string;
  title?: string;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      role="img"
      aria-label={title}
    >
      <rect width="64" height="64" rx="6" fill={ground} />
      <rect
        x="3.5"
        y="3.5"
        width="57"
        height="57"
        rx="3.5"
        fill="none"
        stroke={ink}
        strokeWidth="1"
        opacity="0.28"
      />
      {/* serif-cut W */}
      <g stroke={ink} fill="none">
        <polyline
          points="15,20 24.5,45.5 32,24.5 39.5,45.5 49,20"
          strokeWidth="5.2"
          strokeLinecap="butt"
          strokeLinejoin="miter"
        />
        <path d="M10.8 18.4 h8.4 M44.8 18.4 h8.4" strokeWidth="3.2" />
      </g>
    </svg>
  );
}

/** Horizontal lockup: glyph + letterspaced wordmark. */
export function WordbankLockup({
  glyphSize = 30,
  className,
}: {
  glyphSize?: number;
  className?: string;
}) {
  return (
    <span className={`${styles.lockup} ${className ?? ""}`}>
      <WordbankGlyph size={glyphSize} />
      <span className={styles.wordmark} aria-hidden="true">
        WORDBANK
      </span>
    </span>
  );
}
