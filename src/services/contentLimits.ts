/**
 * Length limits for the free-text fields of an event, and the one function that
 * checks them. Kept UI-free so the same rule can be exercised directly.
 *
 * THE NUMBERS LIVE HERE AND NOWHERE ELSE IN TYPESCRIPT. `EventDialog` reads them
 * for both its `maxLength` attributes and its validation, so the field a user is
 * stopped at and the value the form refuses can never drift apart.
 *
 * WHAT THIS LAYER IS AND IS NOT:
 *   It sits above BOTH repositories -- every write carrying content goes through
 *   the dialog's `readForm()` -- so one check here covers localStorage and
 *   Supabase alike, and neither repository needs a rule of its own.
 *
 *   It is NOT the last line of defence. Anything writing through the API or SQL
 *   directly bypasses it, and rows that predate it keep whatever they hold. Only
 *   a database constraint can speak for those, and only the CSS clipping rules
 *   keep an over-long value from breaking the layout when one is displayed. None
 *   of the three replaces the others.
 *
 * COUNTING: `String.length` counts UTF-16 code units, matching what the HTML
 * `maxlength` attribute enforces, so the attribute and this function always
 * agree. A non-BMP character (most emoji, some kanji) is two units, so it costs
 * two against the limit while PostgreSQL's `char_length` would count it as one.
 * That asymmetry is the safe direction: a value this layer accepts is never
 * longer by the database's reckoning than by ours.
 */

export const TITLE_MAX = 200;
export const CATEGORY_MAX = 50;
export const DESCRIPTION_MAX = 2000;

/** The content fields as `readForm` assembles them: trimmed, empty -> null. */
export interface ContentLengths {
  title: string;
  description: string | null;
  category: string | null;
}

/**
 * A message naming the first field that is too long, or null when all fit.
 *
 * Callers pass values that are ALREADY trimmed, which is what makes the limit
 * mean what a user would expect: trailing whitespace never costs them a
 * character. Emptiness is not this function's business -- `readForm` owns the
 * rule that a title is required, and a null description or category simply has
 * no length to check.
 */
export function contentLengthError(content: ContentLengths): string | null {
  if (content.title.length > TITLE_MAX) {
    return `タイトルは${TITLE_MAX}文字以内で入力してください`;
  }
  if (content.category !== null && content.category.length > CATEGORY_MAX) {
    return `カテゴリは${CATEGORY_MAX}文字以内で入力してください`;
  }
  if (content.description !== null && content.description.length > DESCRIPTION_MAX) {
    return `メモは${DESCRIPTION_MAX}文字以内で入力してください`;
  }
  return null;
}
