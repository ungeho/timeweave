/**
 * The length rule for a share link's management label, as pure functions.
 *
 * THE UNIT IS UTF-16 CODE UNITS -- String.length, which is also what the HTML
 * maxlength attribute enforces, so the attribute and these functions always
 * agree. The same convention contentLimits.ts uses for event content; the
 * numbers differ because the database constraint behind this field does.
 *
 * WHO ENFORCES WHAT. ShareDialog owns the product rule: maxLength stops the
 * typing, the counter explains it, and labelLengthError is the fallback before
 * createShareLink is called. shareRepository and create_share_link deliberately
 * enforce NOTHING -- a caller that bypasses the dialog answers to the database
 * instead, where migration 0014's `octet_length(label) <= 200` remains the
 * storage/resource backstop for every write path.
 *
 * WHY THE TWO LIMITS CANNOT COLLIDE. A UTF-16 code unit costs at most 3 UTF-8
 * bytes, so 50 units is at most 150 bytes -- comfortably inside 200. That is
 * what lets the UI promise a character count while the database bounds storage
 * in bytes, with no input the dialog accepts that the CHECK would refuse. The
 * reasoning and the ceiling it implies are pinned in shareLinkLabel.test.ts.
 *
 * Nothing here is mapped in shareLinkError.ts: with this rule in place the
 * 23514 path is unreachable from the app, and the only callers who can reach it
 * are better served by the raw SQLSTATE than by Japanese copy.
 *
 * This is a module and not an expression in the dialog because the project has
 * no component-test environment (vitest runs with environment: 'node'), so a
 * rule that lives here is a rule that can be tested.
 */

/** The product limit, in UTF-16 code units. The only place this number lives. */
export const SHARE_LABEL_MAX = 50;

/**
 * The label's length in the unit the policy is written in, measured on the
 * TRIMMED value -- what validation counts and what the dialog actually saves.
 *
 * Absent, empty and whitespace-only labels are all 0: `label.trim() || null` in
 * the dialog turns every one of them into the same stored NULL, so they are the
 * same length here too. Total over the input state, so the counter can call it
 * on raw state with no preparation.
 */
export function shareLabelLength(label: string | null | undefined): number {
  return (label ?? '').trim().length;
}

/**
 * A message when the trimmed label is too long, or null when it fits. The limit
 * is INCLUSIVE: exactly SHARE_LABEL_MAX units is accepted.
 *
 * Neither trims in place nor truncates -- an over-long label is refused and
 * returned to the user intact, never silently shortened into a different label
 * than the one they typed.
 */
export function labelLengthError(label: string | null | undefined): string | null {
  if (shareLabelLength(label) > SHARE_LABEL_MAX) {
    return `ラベルは${SHARE_LABEL_MAX}文字以内で入力してください`;
  }
  return null;
}
