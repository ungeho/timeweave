/**
 * The decisions the settings dialog makes about the owner's time zone, kept out
 * of the component so they can be tested: this project runs vitest with
 * environment 'node' and has no jsdom, so anything written inline in JSX cannot
 * be checked at all.
 *
 * WHAT THIS MODULE DELIBERATELY DOES NOT DO. It does not validate the zone
 * against a catalog. The database owns that question -- 0008's
 * `timezone_is_supported()` reads pg_timezone_names, and 0025 calls it from a
 * trigger that raises TIMEWEAVE_TZ_INVALID. A second, weaker list in the client
 * could only disagree with it, and the disagreement would always be the client
 * accepting something the server then refuses. So the UI offers the zones the
 * browser knows and lets the server have the final word.
 */

import type { UiLanguage } from '../../types/settings';
import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';

/**
 * Zones to offer, newest-browser-first with a small fallback.
 *
 * `Intl.supportedValuesOf('timeZone')` is the complete IANA list the runtime
 * carries, which is the right set to show: it is what the owner's own calendar
 * already renders in. Older runtimes do not have it, and a short list beats an
 * empty select -- the field stays free-text either way, so nothing is
 * unreachable.
 */
export function timezoneOptions(): string[] {
  const anyIntl = Intl as unknown as { supportedValuesOf?: (k: string) => string[] };
  try {
    const all = anyIntl.supportedValuesOf?.('timeZone');
    if (Array.isArray(all) && all.length > 0) return all;
  } catch {
    // Fall through to the short list.
  }
  return [
    'Asia/Tokyo', 'Asia/Seoul', 'Asia/Shanghai', 'Asia/Singapore', 'Asia/Kolkata',
    'Europe/London', 'Europe/Paris', 'Europe/Berlin',
    'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
    'Australia/Sydney', 'Pacific/Auckland', 'UTC',
  ];
}

/** The zone to pre-select for an owner who has never set one. */
export function browserTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}

/**
 * Whether saving `next` over `current` is a change the owner should be warned
 * about before it takes effect.
 *
 * Only a change that MOVES a day boundary qualifies. Setting a zone for the
 * first time qualifies too, and that is not an edge case: it is the moment an
 * owner's all-day events stop being uninterpretable and start being disclosed,
 * which is precisely when they deserve to be told what will happen.
 */
export function timezoneChangeNeedsWarning(
  current: string | null,
  next: string | null,
): boolean {
  if (next === null) return current !== null; // clearing re-hides available time
  return current !== next;
}

/**
 * What a zone change actually does, in the owner's terms.
 *
 * Says the quiet part explicitly: all-day events are reinterpreted, anonymous
 * Free/Busy can change, and TIMED events do not move. That last line matters
 * more than it looks -- an owner who thinks changing a zone will shift their
 * 09:00 meetings is being told, correctly, that it will not, because
 * `start_at` is an absolute instant.
 *
 * A FUNCTION SINCE P6 STEP 3. The three lines were resolved with
 * DEFAULT_LANGUAGE at import time, so an owner reading the dialog in English
 * would have been warned in Japanese -- about the one action in this app that
 * retroactively changes what a live share link discloses. That is the worst
 * place in the product to be unreadable.
 *
 * A TUPLE, NOT AN ARRAY. The three lines are an ordered set, not a list that
 * happens to have three entries: all-day events first (what is reinterpreted),
 * the share page second (who notices), timed events last (what does NOT move,
 * which is the reassurance the owner is looking for). Typing it as a readonly
 * triple makes "three, in this order" a compile-time fact rather than a runtime
 * assertion, the same shape WeekdayNames uses in i18n/dateNames.ts.
 *
 * No cache: this dialog renders once, and only while confirming.
 */
export type TimezoneChangeNotice = readonly [string, string, string];

export function timezoneChangeNotice(lang: Language = DEFAULT_LANGUAGE): TimezoneChangeNotice {
  return [
    t('settings.timezone.changeAllDay', lang),
    t('settings.timezone.changeShare', lang),
    t('settings.timezone.changeTimedUnaffected', lang),
  ];
}

/**
 * What NOT setting a zone costs, for the owner who is wondering why their
 * available time is not showing up.
 *
 * Names the exact shape that triggers it, because "sometimes it does not work"
 * is what sent this project on a long hunt once already: an all-day Busy event
 * in the same week as a timed Available one is the combination that cannot be
 * computed without a zone.
 *
 * `lang` defaults to the default language, so a call with no argument answers
 * in the Japanese this dialog has always shown.
 */
export function timezoneUnsetNotice(lang: Language = DEFAULT_LANGUAGE): string {
  return t('settings.timezone.unsetNotice', lang);
}

/** Labels for the language control. Independent of the zone, always. */
export const LANGUAGES: { value: UiLanguage; label: string }[] = [
  { value: 'ja', label: '日本語' },
  { value: 'en', label: 'English' },
];

/*
 * REMOVED AT THE END OF P6: languagePendingNotice.
 *
 * It said the language control stored a value but did not change the screen,
 * which was true for four phases and is now false -- LANGUAGE_SWITCH_ENABLED
 * is true, so a saved preference is applied. Keeping it would be the mirror of
 * the failure its own comment warned about: the owner would be told their
 * choice has not taken effect while the page around the notice was already in
 * their language.
 *
 * languageNotInCalculationNotice below stays. It is about something else --
 * that the display language is not an input to the Free/Busy computation --
 * and that remains true.
 */

/**
 * The half of the old sentence that WAS true, kept separate because it is
 * about a different thing: whatever the language ends up doing, it will never
 * reach the Free/Busy computation. 0025 declares the column and reads it from
 * nowhere, which the postflight pins at H02.
 *
 * THE CLAIM IS UNCHANGED BY TRANSLATING IT, and has to stay that way: the
 * sentence promises that the display language is not an input to what
 * anonymous viewers are told. P6 step 2 is what makes it verifiable rather than
 * merely asserted -- getFreeBusy takes no language argument, and the share
 * repository names no i18n symbol at all.
 */
export function languageNotInCalculationNotice(lang: Language = DEFAULT_LANGUAGE): string {
  return t('settings.language.notInCalculation', lang);
}
