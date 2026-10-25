/**
 * Display names for calendar dates, per language.
 *
 * WHY THIS IS NOT IN THE DICTIONARY. Weekday names are a DATE FORMAT, not
 * copy: they come as a set of seven that must stay in one order, every
 * language already has an authoritative short form, and `t()` would have to
 * hold them as fourteen unrelated keys that nothing stops a translator from
 * reordering. One module, one table, one order.
 *
 * It replaces FOUR hardcoded copies of the same week -- MonthView,
 * TimeGridView, RecurrenceEditor and FreeBusyPage each had their own, and
 * three of them were identical arrays while the fourth was a Record keyed by
 * RFC 5545 code. Those copies are what made "localise the weekday" a
 * four-file change instead of a one-file change.
 *
 * WHY A TABLE AND NOT `Intl` DIRECTLY. `Intl.DateTimeFormat('ja', { weekday:
 * 'short' })` does answer 月..日 -- dateNames.test.ts asserts that it agrees
 * with the table below, so the table cannot quietly rot. But a runtime built
 * with reduced ICU answers in English for every locale it does not carry, and
 * the Japanese here is text this app has shipped since it existed. A table
 * renders the same seven strings on every runtime; `Intl` renders whatever
 * that build happens to know. The check in the test gets the benefit of
 * `Intl` without making the UI depend on it.
 *
 * MONDAY FIRST, matching `DayCell.weekdayIndex` and `weekdayOfDayKey` (0 =
 * Monday .. 6 = Sunday) and `WEEKDAYS` in types/recurrence. Changing the week
 * start is a calendar-layout decision, not a formatting one, and nothing here
 * may be used to make it.
 */

import { DEFAULT_LANGUAGE, isLanguage, type Language } from './types';

/** Monday-first, exactly seven: the tuple length is what makes that checkable. */
export type WeekdayNames = readonly [string, string, string, string, string, string, string];

/**
 * Short weekday names, Monday first.
 *
 * `ja` is the exact set the four components hardcoded, character for
 * character, so nothing on screen moved when they started reading this.
 * `en` is the conventional three-letter abbreviation, which is what fits the
 * narrow day-header columns the Japanese single characters were sized for.
 */
const SHORT: Record<Language, WeekdayNames> = {
  ja: ['月', '火', '水', '木', '金', '土', '日'],
  en: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
};

/**
 * The seven short weekday names for `lang`, Monday first.
 *
 * `lang` is typed as `Language` and ALSO checked at runtime, for the same
 * reason `t()` checks it: the value can arrive from `owner_settings` or from
 * `navigator.languages`, so a build that trusted the type would render
 * `undefined` for a row written by a newer version of the app.
 */
export function weekdayNamesShort(lang: Language): WeekdayNames {
  return SHORT[isLanguage(lang) ? lang : DEFAULT_LANGUAGE];
}

/**
 * One short weekday name by its Monday-first index.
 *
 * Returns '' for an index outside 0..6. Every caller passes either
 * `weekdayOfDayKey`'s result or a position in `WEEKDAYS`, both 0..6 by
 * construction, so that branch is the type-level tail rather than a
 * behaviour -- but a day header is not worth throwing in render for, and a
 * blank cell is visible while a crash takes the whole calendar down.
 */
export function weekdayShort(lang: Language, weekdayIndex: number): string {
  return weekdayNamesShort(lang)[weekdayIndex] ?? '';
}
