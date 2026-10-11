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
 */
export const TIMEZONE_CHANGE_NOTICE = [
  '終日の予定は、このタイムゾーンの暦日として解釈されます。',
  '匿名共有ページに表示される空き時間が変わることがあります。',
  '時刻を指定した予定（開始・終了時刻のある予定）は変わりません。',
];

/**
 * What NOT setting a zone costs, for the owner who is wondering why their
 * available time is not showing up.
 *
 * Names the exact shape that triggers it, because "sometimes it does not work"
 * is what sent this project on a long hunt once already: an all-day Busy event
 * in the same week as a timed Available one is the combination that cannot be
 * computed without a zone.
 */
export const TIMEZONE_UNSET_NOTICE =
  'タイムゾーンが未設定のため、終日の予定と時刻指定の空き時間が同じ期間に含まれる場合、'
  + '匿名共有ページでは空き時間を表示できません（安全のため非表示になります）。';

/** Labels for the language control. Independent of the zone, always. */
export const LANGUAGES: { value: UiLanguage; label: string }[] = [
  { value: 'ja', label: '日本語' },
  { value: 'en', label: 'English' },
];

/**
 * What the language control actually does TODAY, which is store a value.
 *
 * THE TRANSLATION LAYER DOES NOT EXIST YET. Migration 0025 created the column
 * so the i18n phase would need no migration of its own, and the control is
 * here so the preference survives until that phase lands -- but every string in
 * this app is still Japanese, and choosing English changes nothing on screen.
 *
 * Saying "画面の文言だけが変わります" would therefore be a lie, and the
 * particular kind that is worst in a settings screen: the user picks English,
 * sees Japanese, and concludes the save failed or the app is broken. The notice
 * below says the value is kept and the switch is not live yet, which is both
 * true and the thing they need to know before clicking save.
 */
export const LANGUAGE_PENDING_NOTICE =
  '言語の切り替えはまだ有効になっていません。現在はすべて日本語で表示されます。'
  + '設定した値は保存され、翻訳の対応後に適用されます。';

/**
 * The half of the old sentence that WAS true, kept separate because it is
 * about a different thing: whatever the language ends up doing, it will never
 * reach the Free/Busy computation. 0025 declares the column and reads it from
 * nowhere, which the postflight pins at H02.
 */
export const LANGUAGE_NOT_IN_CALCULATION_NOTICE =
  '言語設定は、共有される空き時間の計算には影響しません。';
