/**
 * The two things the dialog needs to know about availability, kept out of the
 * component so the rule can be tested: what the control offers, and when a
 * title has to be filled in.
 *
 * This sits beside recurrenceForm and timezoneField, the other pure helpers the
 * event dialog reads.
 */

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, isLanguage, type Language } from '../../i18n/types';
import type { Availability } from '../../types/event';

/**
 * Every availability, in lifecycle order: the default first, so the control
 * opens on it.
 *
 * A list of VALUES, not of {value,label} pairs. The label depends on the
 * display language and the value does not, so pairing them in a module
 * constant is what pinned the wording at import time -- the same shape
 * VISIBILITIES and visibilityMeta were split into during P6.
 */
export const AVAILABILITIES: readonly Availability[] = ['busy', 'available'];

/**
 * How one availability reads, in `lang`.
 *
 * WHY THIS IS NOW TRANSLATED. It was deliberately not, and the reason was
 * sound: `Busy` and `Available` are the terms the rest of the product uses
 * in Japanese too -- the share dialog says 空き時間(Available), the user
 * guide says the same, and the stored value is `available` -- so routing
 * the words through a dictionary invited a translation that would break
 * that correspondence. What it cost was an owner reading a Japanese form
 * with two English words in it and no Japanese name for either.
 *
 * The Japanese labels keep the English term in parentheses, so both hold:
 * there is a Japanese name to read, and the word every other screen names.
 * See the keys in i18n/ja.ts for the full argument.
 *
 * It takes no visibility, and must not: private and available are
 * independent settings and the control offers both values unconditionally.
 */
export function availabilityLabel(
  availability: Availability,
  lang: Language = DEFAULT_LANGUAGE,
): string {
  // Checked at runtime as well as in the type, for the reason t() checks
  // it: the value can arrive from owner_settings, so a row written by a
  // newer build must not render undefined.
  const l = isLanguage(lang) ? lang : DEFAULT_LANGUAGE;
  return availability === 'busy'
    ? t('event.availability.busy', l)
    : t('event.availability.available', l);
}

/**
 * Whether the form must refuse an empty title.
 *
 * A BUSY event without a title is almost certainly a mistake -- the owner meant
 * to write something and did not -- and that check has been in place since the
 * dialog existed. An AVAILABLE event is different: "these two hours are open"
 * is complete on its own, and demanding a name for it is the cost this feature
 * is meant to avoid paying on every entry.
 *
 * What it does NOT license is inventing one. An untitled available event stores
 * the empty string and eventDisplayTitle supplies the words at render time, so
 * nothing in the database is written in a particular language.
 */
export function isTitleRequired(availability: Availability): boolean {
  return availability === 'busy';
}
