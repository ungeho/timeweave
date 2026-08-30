/**
 * Deterministic category colors, separated from the UI so a future
 * user-defined palette can be layered on via `overrides`.
 *
 * The same category name always maps to the same color. Saturation/lightness
 * are held in a narrow band so auto-generated colors keep enough contrast with
 * the fixed foreground (white), avoiding unreadable chips.
 */

export interface CategoryColor {
  /** Fill/background color (also used as the accent bar). */
  bg: string;
  /** Foreground text color chosen for contrast against `bg`. */
  fg: string;
  /** Slightly darker shade for borders. */
  border: string;
}

// Neutral color for uncategorised events (themeable via CSS variables).
const NEUTRAL: CategoryColor = {
  bg: 'var(--bg-muted)',
  fg: 'var(--text)',
  border: 'var(--border)',
};

// Constrained ranges keep contrast with white text acceptable across all hues.
const SATURATION = 60; // %
const LIGHTNESS = 42; // % (dark enough for white text)
const BORDER_LIGHTNESS = 32; // %

/** FNV-1a — small, stable string hash. */
function hashString(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/**
 * Map a category name to a stable color. `null`/empty -> neutral.
 * `overrides` (future user palette) takes precedence when it has the key.
 */
export function categoryColor(
  category: string | null | undefined,
  overrides?: Record<string, string>,
): CategoryColor {
  if (!category) return NEUTRAL;

  if (overrides && category in overrides) {
    const bg = overrides[category]!;
    return { bg, fg: '#ffffff', border: bg };
  }

  const hue = hashString(category) % 360;
  return {
    bg: `hsl(${hue} ${SATURATION}% ${LIGHTNESS}%)`,
    fg: '#ffffff',
    border: `hsl(${hue} ${SATURATION}% ${BORDER_LIGHTNESS}%)`,
  };
}
