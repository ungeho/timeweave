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

import { t } from '../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../i18n/types';

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
 * WHICH field is too long, and the ceiling it exceeded -- or null when all fit.
 *
 * Split out from `contentLengthError` in P6 step 8. EventDialog keeps the
 * violation in state rather than the sentence it reads as, so the refusal
 * follows the display language like everything else on screen. Holding the
 * FIELD rather than a message is what makes that possible: the three messages
 * differ, and each quotes its own number.
 *
 * `max` travels with the field so the sentence cannot disagree with the limit
 * that was actually applied.
 */
export type ContentLengthViolation =
  | { readonly field: 'title'; readonly max: number }
  | { readonly field: 'category'; readonly max: number }
  | { readonly field: 'description'; readonly max: number };

/**
 * The first field that is too long, or null when all fit.
 *
 * Callers pass values that are ALREADY trimmed, which is what makes the limit
 * mean what a user would expect: trailing whitespace never costs them a
 * character. Emptiness is not this function's business -- `readForm` owns the
 * rule that a title is required, and a null description or category simply has
 * no length to check.
 *
 * THE ORDER IS PART OF THE CONTRACT: title, then category, then description.
 * A form with two over-long fields names the first of them, and which one that
 * is has always been this order.
 */
export function contentLengthViolation(content: ContentLengths): ContentLengthViolation | null {
  if (content.title.length > TITLE_MAX) {
    return { field: 'title', max: TITLE_MAX };
  }
  if (content.category !== null && content.category.length > CATEGORY_MAX) {
    return { field: 'category', max: CATEGORY_MAX };
  }
  if (content.description !== null && content.description.length > DESCRIPTION_MAX) {
    return { field: 'description', max: DESCRIPTION_MAX };
  }
  return null;
}

/**
 * How one violation reads, in a language.
 *
 * The key is written out per field rather than indexed from the violation,
 * because `t` reads a message's placeholder names off the key's literal type:
 * a computed key would widen to the whole MessageKey union and the call would
 * owe it the widest variable set in the dictionary. The same reason
 * RecurrenceFormError re-derives its key in `localize`.
 */
export function contentLengthMessage(
  violation: ContentLengthViolation,
  lang: Language = DEFAULT_LANGUAGE,
): string {
  switch (violation.field) {
    case 'title':
      return t('content.titleTooLong', lang, { max: violation.max });
    case 'category':
      return t('content.categoryTooLong', lang, { max: violation.max });
    case 'description':
      return t('content.descriptionTooLong', lang, { max: violation.max });
  }
}

/**
 * A message naming the first field that is too long, or null when all fit.
 *
 * Kept as it was -- same arguments, same strings -- because it is asserted
 * directly in contentLimits.test.ts and in the i18n suites. It is now a
 * composition of the two functions above, so the rule and the wording cannot
 * drift apart between its callers and the dialog's state.
 */
export function contentLengthError(
  content: ContentLengths,
  lang: Language = DEFAULT_LANGUAGE,
): string | null {
  const violation = contentLengthViolation(content);
  return violation === null ? null : contentLengthMessage(violation, lang);
}
