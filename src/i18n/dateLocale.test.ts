import { describe, expect, it } from 'vitest';
import { intlLocale } from './resolveLanguage';
import { LANGUAGES } from './types';
import { CLOCK_24H, formatDateTime, formatInstant, formatTime } from '../utils/datetime';
import { monthTitle } from '../features/calendar/monthGrid';
import { dayKeyTitle, dayTitle, weekTitle, weekRange } from '../features/calendar/weekGrid';

/**
 * P4 step 2: every date and time display takes the resolved language's locale.
 *
 * TWO CLAIMS, and the file is split along them.
 *
 * 1. THE JAPANESE DID NOT MOVE. `intlLocale('ja')` is 'ja-JP', and on a
 *    Japanese runtime that is byte-identical to the `undefined` these calls
 *    used to pass. The literals below are written out rather than computed, so
 *    they would fail if the format changed.
 *
 * 2. THE ENGLISH IS NATURAL -- month names, weekday, date order -- EXCEPT for
 *    the clock, which stays 24-hour in both languages on purpose. The time
 *    grid's own axis is a hardcoded 00:00..23:00 ladder; an English viewer
 *    reading "9:00 AM" on a chip against that axis is the failure this avoids.
 *
 * These tests PIN THE RUNTIME'S TIME ZONE wherever a clock is involved, by
 * using instants whose rendering does not depend on it, or by asserting
 * relationships rather than absolute strings. vitest runs with whatever TZ the
 * machine has.
 */

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

/** Source with comments removed: these guards are about what the code DOES. */
const code = (path: string) =>
  source(path)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

/** 2026-08-29 is a Saturday. Noon UTC, so no zone can move the calendar date. */
const SAT_AUG_29 = new Date('2026-08-29T12:00:00Z');

describe('the locale resolver', () => {
  it('maps the two languages to region-qualified tags', () => {
    // A bare 'ja' leaves the region conventions unspecified, which is what the
    // P2 comment on this function warned about.
    expect(intlLocale('ja')).toBe('ja-JP');
    expect(intlLocale('en')).toBe('en-US');
  });

  it('answers a usable tag for every declared language', () => {
    for (const lang of LANGUAGES) {
      expect(() => new Intl.DateTimeFormat(intlLocale(lang))).not.toThrow();
      expect(intlLocale(lang)).toMatch(/^[a-z]{2}-[A-Z]{2}$/);
    }
  });

  it('is the ONE place the mapping lives', () => {
    // A second `lang === 'en' ? 'en-US' : ...` anywhere is how the toolbar and
    // the agenda end up on different conventions.
    const offenders = Object.entries(MODULES)
      .filter(([p]) => !p.includes('.test.'))
      .filter(([p]) => !p.endsWith('/i18n/resolveLanguage.ts'))
      .filter(([, text]) => /'(ja-JP|en-US)'/.test(text.replace(/\/\*[\s\S]*?\*\//g, '')))
      .map(([p]) => p.replace(/^\/src\//, ''));
    // utils/timezone.ts keeps its own 'en-US': that call asks whether a zone
    // NAME is usable, not how to show it, and localising it would change what
    // it tests.
    expect(offenders).toEqual(['utils/timezone.ts']);
  });

  it('does not reach the zone-validity probe', () => {
    expect(code('utils/timezone.ts')).toMatch(/Intl\.DateTimeFormat\('en-US'/);
    expect(code('utils/timezone.ts')).not.toMatch(/intlLocale|useLanguage|Language/);
  });
});

describe('the Japanese period titles are byte-identical', () => {
  it('the month title', () => {
    expect(monthTitle(SAT_AUG_29, intlLocale('ja'))).toBe('2026年8月');
  });

  it('the week title', () => {
    // Saturday 2026-08-29 sits in the week Mon 24th .. Sun 30th.
    expect(weekTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('ja'))).toBe('8/24 – 8/30');
  });

  it('the day title', () => {
    expect(dayTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('ja'))).toBe('2026年8月29日(土)');
  });

  it('the agenda heading, which now shares the day title’s words', () => {
    expect(dayKeyTitle('2026-08-29', intlLocale('ja'))).toBe('2026年8月29日(土)');
  });

  it('the agenda heading equals the day title for the same date', () => {
    // Two components, one helper -- so the dialog and the toolbar cannot
    // disagree about what day it is.
    expect(dayKeyTitle('2026-08-29', intlLocale('ja'))).toBe(
      dayTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('ja')),
    );
  });
});

describe('the English period titles read naturally', () => {
  it('the month is named, and the year follows it', () => {
    expect(monthTitle(SAT_AUG_29, intlLocale('en'))).toBe('August 2026');
  });

  it('the week range keeps month-before-day, matching en-US', () => {
    expect(weekTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('en'))).toBe('8/24 – 8/30');
  });

  it('the day title leads with the weekday and names the month', () => {
    expect(dayTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('en'))).toBe('Sat, August 29, 2026');
  });

  it('the agenda heading matches it', () => {
    expect(dayKeyTitle('2026-08-29', intlLocale('en'))).toBe('Sat, August 29, 2026');
  });

  it('no English title leaks Japanese characters', () => {
    for (const s of [
      monthTitle(SAT_AUG_29, intlLocale('en')),
      weekTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('en')),
      dayTitle(SAT_AUG_29, 'Asia/Tokyo', intlLocale('en')),
      dayKeyTitle('2026-08-29', intlLocale('en')),
    ]) {
      expect(s).not.toMatch(/[年月日ぁ-んァ-ン一-龯]/);
    }
  });

  it('every title actually differs between the two languages', () => {
    // Except the week range, which is M/D in both -- stated so that its
    // sameness is a known fact rather than a missed wiring.
    expect(monthTitle(SAT_AUG_29, 'en-US')).not.toBe(monthTitle(SAT_AUG_29, 'ja-JP'));
    expect(dayTitle(SAT_AUG_29, 'UTC', 'en-US')).not.toBe(dayTitle(SAT_AUG_29, 'UTC', 'ja-JP'));
    expect(weekTitle(SAT_AUG_29, 'UTC', 'en-US')).toBe(weekTitle(SAT_AUG_29, 'UTC', 'ja-JP'));
  });
});

describe('the clock is 24-hour in BOTH languages', () => {
  it('the pin is h23, not h24', () => {
    // They differ only at midnight, where h24 renders "24:00". The grid's axis
    // starts at 00:00 and an event at midnight has to agree with it.
    expect(CLOCK_24H.hourCycle).toBe('h23');
  });

  it('midnight is 00:00 and not 24:00, in either language', () => {
    // Formatted in a fixed zone so the assertion does not depend on the
    // machine's: 15:00Z is midnight in Asia/Tokyo.
    for (const lang of LANGUAGES) {
      const got = new Intl.DateTimeFormat(intlLocale(lang), {
        hour: '2-digit',
        minute: '2-digit',
        timeZone: 'Asia/Tokyo',
        ...CLOCK_24H,
      }).format(new Date('2026-08-28T15:00:00Z'));
      expect(got, lang).toBe('00:00');
    }
  });

  it('no clock output carries AM or PM', () => {
    // The whole point: en-US would say "09:00 AM" without the pin.
    for (const lang of LANGUAGES) {
      for (const hour of [0, 1, 9, 12, 13, 23]) {
        const iso = new Date(Date.UTC(2026, 7, 29, hour)).toISOString();
        expect(formatTime(iso, intlLocale(lang)), `${lang} ${hour}`).not.toMatch(/AM|PM|午前|午後/i);
      }
    }
  });

  it('the two languages render the same instant as the same clock time', () => {
    // The clock is pinned, so only the DATE parts may differ by language.
    const iso = new Date(Date.UTC(2026, 7, 29, 13, 45)).toISOString();
    expect(formatTime(iso, 'en-US')).toBe(formatTime(iso, 'ja-JP'));
  });

  it('it reads HH:MM, zero-padded, in both', () => {
    const iso = new Date(Date.UTC(2026, 7, 29, 1, 5)).toISOString();
    for (const lang of LANGUAGES) {
      expect(formatTime(iso, intlLocale(lang)), lang).toMatch(/^\d{2}:\d{2}$/);
    }
  });

  it('the hour ladder it has to agree with is still a raw 00..23', () => {
    expect(code('features/calendar/TimeGridView.tsx')).toMatch(/String\(h\)\.padStart\(2, '0'\)/);
    expect(code('features/calendar/TimeGridView.tsx')).toMatch(/\}:00<\/span>/);
  });

  it('formatDateTime carries the same pin, though nothing calls it yet', () => {
    const iso = new Date(Date.UTC(2026, 7, 29, 21, 30)).toISOString();
    for (const lang of LANGUAGES) {
      expect(formatDateTime(iso, intlLocale(lang)), lang).not.toMatch(/AM|PM/i);
    }
    const callers = Object.entries(MODULES)
      .filter(([p]) => !p.includes('.test.') && !p.endsWith('/utils/datetime.ts'))
      .filter(([, text]) => /\bformatDateTime\(/.test(text))
      .map(([p]) => p);
    expect(callers).toEqual([]);
  });
});

describe('the share link expiry: display follows the language, the decision does not', () => {
  it('the Japanese line is byte-identical to the bare toLocaleString it replaced', () => {
    // It was `new Date(l.expiresAt).toLocaleString()`. formatInstant passes a
    // locale and the clock pin and NOTHING else, which is why ja-JP comes out
    // unchanged -- seconds and all.
    const iso = '2026-08-29T00:00:00.000Z';
    const expected = new Date(iso).toLocaleString('ja-JP');
    expect(formatInstant(iso, 'ja-JP')).toBe(expected);
  });

  it('the English line is 24-hour, which the bare call was not', () => {
    const iso = new Date(Date.UTC(2026, 7, 29, 13, 0)).toISOString();
    expect(formatInstant(iso, 'en-US')).not.toMatch(/AM|PM/i);
    // And it is genuinely different from the Japanese, so the wiring works.
    expect(formatInstant(iso, 'en-US')).not.toBe(formatInstant(iso, 'ja-JP'));
  });

  it('both languages describe the SAME instant', () => {
    // The display changed; the moment did not. Both renderings have to agree
    // on the clock, which the pin guarantees.
    const iso = new Date(Date.UTC(2026, 7, 29, 13, 45)).toISOString();
    const clock = /(\d{1,2}):(\d{2})/;
    const ja = clock.exec(formatInstant(iso, 'ja-JP'));
    const en = clock.exec(formatInstant(iso, 'en-US'));
    expect(ja).not.toBeNull();
    expect(en).not.toBeNull();
    // Compared as NUMBERS: en-US pads a one-digit hour ("09"), ja-JP does not
    // ("9"). Both are 9 o'clock; as strings they only agreed where the instant
    // happens to read 10:00 or later in the OS zone (P8-c1.1).
    expect(Number(ja![1])).toBe(Number(en![1]));
    expect(Number(ja![2])).toBe(Number(en![2]));
  });

  it('the expiry DECISION never sees a locale', () => {
    // shareLinkStatus compares the stored instant with `now`. If a locale
    // reached it, a language change could revive an expired link.
    const state = code('features/share/shareLinkState.ts');
    expect(state).not.toMatch(/locale|Language|intlLocale|useLanguage|format/);
  });

  it('the dialog passes a locale to the LINE and nothing else', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    // P8-c3.1 (E4): the line gained the UTC offset of the stored instant, in
    // shareExpiryLabel, whose date part is still formatInstant with the locale.
    expect(dlg).toMatch(/shareExpiryLabel\(l\.expiresAt, intlLocale\(language\), timeZone\)/);
    expect(code('features/share/shareExpiryLabel.ts')).toMatch(/formatInstant\(iso, locale\)/);
    // The create form still sends a raw ISO instant, untouched by display.
    // P8-c3 moved the conversion into shareExpiry.ts (which refuses a time
    // that does not exist); it is still isoFromDatetimeLocalValue, locale-free.
    expect(dlg).toMatch(/expiresAt: expiryNow\.kind === 'instant' \? expiryNow\.iso : null/);
    expect(code('features/share/shareExpiry.ts')).toMatch(/isoFromDatetimeLocalValue\(local\)/);
    expect(code('features/share/shareExpiry.ts')).not.toMatch(/locale|Language|format/);
    expect(dlg).not.toMatch(/shareLinkStatus\([^)]*locale/);
  });
});

describe('a language change moves no instant and no zone', () => {
  it('the week range is identical for both languages', () => {
    // weekRange takes a zone and no locale at all: nothing in this step can
    // reach the fetch window.
    const a = weekRange(SAT_AUG_29, 'Asia/Tokyo');
    expect(a.startIso).toBe('2026-08-23T15:00:00.000Z');
    expect(a.endIso).toBe('2026-08-30T15:00:00.000Z');
  });

  it('the titles take the zone and the locale as separate arguments', () => {
    // Which is the whole "date format and time zone are different concerns"
    // point: the same instant in two zones is two days; in two languages it is
    // one day said twice.
    expect(dayTitle(new Date('2026-08-29T20:00:00Z'), 'Asia/Tokyo', 'ja-JP')).toBe(
      '2026年8月30日(日)',
    );
    expect(dayTitle(new Date('2026-08-29T20:00:00Z'), 'UTC', 'ja-JP')).toBe('2026年8月29日(土)');
    // Same zone, two languages: the same day.
    expect(dayTitle(new Date('2026-08-29T20:00:00Z'), 'UTC', 'en-US')).toMatch(/August 29, 2026/);
  });

  it('formatTime passes no timeZone, so the viewer’s zone still decides', () => {
    const dt = code('utils/datetime.ts');
    const fn = dt.slice(dt.indexOf('export function formatTime'), dt.indexOf('export function formatDateTime'));
    expect(fn).not.toMatch(/timeZone/);
  });

  it('the ISO values the app stores are untouched by any of this', () => {
    const dt = code('utils/datetime.ts');
    // The serialisers still build their strings by hand, with padStart.
    expect(dt).toMatch(/padStart/);
    expect(dt).not.toMatch(/intlLocale|Language|useLanguage/);
  });

  it('the week still starts on Monday', () => {
    const grid = code('features/calendar/weekGrid.ts');
    expect(grid).toMatch(/-weekdayOfDayKey\(anchorKey\)/);
    expect(grid).not.toMatch(/intlLocale|Language|useLanguage/);
  });
});

describe('the anonymous share page', () => {
  it('formats its times and its week title with the VIEWER’s locale', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/const locale = intlLocale\(language\)/);
    expect(page).toMatch(/weekTitle\(view\.anchor, timeZone, locale\)/);
    expect(page).toMatch(/formatTime\(t\.start, locale\)/);
    expect(page).toMatch(/formatTime\(t\.end, locale\)/);
    // No bare formatTime call left behind on this page.
    expect(page).not.toMatch(/formatTime\(t\.(start|end)\)/);
  });

  it('still never asks for owner settings', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/owner_settings|getOwnerSettings|ownerSettingsRepository/);
    const app = source('App.tsx');
    const shareBranch = app.slice(
      app.indexOf("if (route.kind === 'share')"),
      app.indexOf('</LanguageProvider>'),
    );
    expect(shareBranch).toMatch(/<LanguageProvider isPublicRoute>/);
  });

  it('still fetches the same window, with no locale in the call', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/weekRange\(view\.anchor, timeZone\)/);
    expect(page).toMatch(/getFreeBusy\(token, startIso, endIso, fromDate, toDate\)/);
    expect(page).not.toMatch(/getFreeBusy\([^)]*locale/);
  });

  it('still keeps the zone the viewer’s own, resolved once', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/const timeZone = useMemo\(\(\) => getUserTimeZone\(\), \[\]\)/);
  });
});

describe('every display path takes an explicit locale', () => {
  it('nothing outside i18n hardcodes a BCP 47 tag for display', () => {
    const offenders = Object.entries(MODULES)
      .filter(([p]) => !p.includes('.test.'))
      .filter(([p]) => !p.endsWith('/i18n/resolveLanguage.ts'))
      .filter(([p]) => !p.endsWith('/utils/timezone.ts'))
      .filter(([, text]) =>
        /Intl\.DateTimeFormat\('[a-z]{2}/.test(text.replace(/\/\*[\s\S]*?\*\//g, '')),
      )
      .map(([p]) => p.replace(/^\/src\//, ''));
    expect(offenders).toEqual([]);
  });

  it('each of the five display call sites passes one', () => {
    const sites: Record<string, RegExp> = {
      'features/calendar/CalendarToolbar.tsx': /intlLocale\(language\)/,
      'features/calendar/EventChip.tsx': /formatTime\(occurrence\.start, intlLocale\(language\)\)/,
      'features/calendar/DayAgendaDialog.tsx': /dayKeyTitle\(agenda\.dayKey, intlLocale\(language\)\)/,
      'features/share/FreeBusyPage.tsx': /intlLocale\(language\)/,
      'features/share/ShareDialog.tsx': /intlLocale\(language\)/,
    };
    for (const [p, re] of Object.entries(sites)) {
      expect(code(p), p).toMatch(re);
    }
  });

  it('the shared option set is what pins the clock, in one place', () => {
    const dt = code('utils/datetime.ts');
    expect(dt).toMatch(/export const CLOCK_24H/);
    // All three formatters spread it rather than repeating the option.
    expect((dt.match(/\.\.\.CLOCK_24H|CLOCK_24H\)/g) ?? []).length).toBeGreaterThanOrEqual(3);
    expect((dt.match(/hourCycle/g) ?? []).length).toBe(1);
  });
});
