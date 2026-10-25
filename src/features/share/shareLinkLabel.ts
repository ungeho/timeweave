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

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';

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
 *
 * `lang` DEFAULTS TO THE DEFAULT LANGUAGE, exactly as contentLengthError's
 * does. Both are refusals rendered by a dialog, both carry their ceiling as a
 * variable so the sentence cannot drift from the constant, and both are called
 * today with the argument omitted -- so the screen does not move. P6 adds the
 * language to this call and to EventDialog's in the same change, which is why
 * the two have the same shape rather than one of them reading a context.
 */
export function labelLengthError(
  label: string | null | undefined,
  lang: Language = DEFAULT_LANGUAGE,
): string | null {
  if (shareLabelLength(label) > SHARE_LABEL_MAX) {
    return labelTooLongMessage(SHARE_LABEL_MAX, lang);
  }
  return null;
}

/**
 * The refusal sentence on its own, given the ceiling it should quote.
 *
 * Extracted in P6 step 6 so the key lives in exactly one place. ShareDialog no
 * longer stores the sentence `labelLengthError` returns -- it keeps the FACT
 * that the label was too long, plus `max`, and renders it here in whatever
 * language the owner is reading. Without this function the dialog would have
 * had to repeat `t('share.label.tooLong', lang, { max })` itself, and the one
 * place this number lives would have become two.
 *
 * `max` is a parameter rather than read from the constant so the sentence
 * cannot disagree with the number the caller actually enforced.
 */
export function labelTooLongMessage(max: number, lang: Language = DEFAULT_LANGUAGE): string {
  return t('share.label.tooLong', lang, { max });
}
