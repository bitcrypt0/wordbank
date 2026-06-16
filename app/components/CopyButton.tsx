"use client";

import { useCallback, useRef, useState } from "react";

interface Props {
  /** The text written to the clipboard. */
  value: string;
  /** Accessible label (e.g. "Copy provenance hash"). */
  label: string;
  className?: string;
}

/**
 * Minimal copy-to-clipboard control. Uses the async Clipboard API with a
 * legacy execCommand fallback for non-secure contexts. Shows a transient
 * "Copied" state. No external deps — keeps the injected-only/no-3rd-party rule.
 */
export function CopyButton({ value, label, className }: Props) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const copy = useCallback(async () => {
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(value);
      } else {
        const ta = document.createElement("textarea");
        ta.value = value;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
      }
      setCopied(true);
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => setCopied(false), 1600);
    } catch {
      // Silent — clipboard may be blocked; the full value is visible on-page.
    }
  }, [value]);

  return (
    <button
      type="button"
      onClick={copy}
      className={className}
      aria-label={copied ? "Copied" : label}
    >
      {copied ? "Copied ✓" : "Copy"}
    </button>
  );
}
