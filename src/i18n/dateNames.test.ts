import { describe, expect, it } from 'vitest';
import { weekdayNamesShort, weekdayShort } from './dateNames';
import { DEFAULT_LANGUAGE, LANGUAGES, type Language } from './types';
import { WEEKDAYS } from '../types/recurrence';
import { buildWeekDays, buildDayCell, weekRange, dayRange } from '../features/calendar/weekGrid';
import { weekdayOfDayKey } from '../utils/timezone';

/**
 * P4 step 1: the four hardcoded weeks became one formatter.
 *
 * The claim is the usual one -- NOTHING THE USER SEES CHANGED TODAY -- so the
 * Japanese below is written out literally rather than read back from the
 * module. The second claim is new: the same seven names now reach the month
 * grid, the week grid, the recurrence chips and the anonymous share page, so a
 * single call decides all four at P6.
 *
 * What this file must also prove is a NEGATIVE: that reading the language for
 * a weekday name changed nothing about dates themselves. Those assertions live
 * at the bottom, against weekGrid and weekdayOfDayKey.
 */

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

/**
 * Source with comments removed, as wiring.test.ts does it.
 *
 * These guards are about what the code DOES, and this codebase explains its
 * reasoning at length -- dateNames.ts discusses `navigator.languages` in prose
 * precisely because NOT reading it is the decision worth recording, and
 * FreeBusyPage names `owner_settings` to say it never asks for one. Matching
 * raw text would flag both explanations as violations.
 */
const code = (path: string) =>
  source(path)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('the Japanese week is byte-identical to the four copies it replaced', () => {
  it('all seven, in order, Monday first', () => {
    expect(weekdayNamesShort('ja')).toEqual(['月', '火', '水', '木', '金', '土', '日']);
  });

  it('each one individually, by index', () => {
    expect(weekdayShort('ja', 0)).toBe('月');
    expect(weekdayShort('ja', 1)).toBe('火');
    expect(weekdayShort('ja', 2)).toBe('水');
    expect(weekdayShort('ja', 3)).toBe('木');
    expect(weekdayShort('ja', 4)).toBe('金');
    expect(weekdayShort('ja', 5)).toBe('土');
    expect(weekdayShort('ja', 6)).toBe('日');
  });

  it('is what the default language resolves to, so today nothing moved', () => {
    expect(DEFAULT_LANGUAGE).toBe('ja');
    expect(weekdayNamesShort(DEFAULT_LANGUAGE)).toEqual(weekdayNamesShort('ja'));
  });
});

describe('the English week', () => {
  it('is the conventional three-letter form, Monday first', () => {
    expect(weekdayNamesShort('en')).toEqual(['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
  });

  it('is short enough for the narrow day-header columns', () => {
    // The Japanese is one character per header; the columns were sized for
    // that. Three letters fit; a full name would not.
    for (const name of weekdayNamesShort('en')) expect(name.length).toBeLessThanOrEqual(3);
  });

  it('carries no Japanese and no punctuation', () => {
    for (const name of weekdayNamesShort('en')) {
      expect(name).not.toMatch(/[ぁ-んァ-ン一-龯]/);
      expect(name).toMatch(/^[A-Z][a-z]{2}$/);
    }
  });
});

describe('every language is complete and distinct', () => {
  it('each declared language has exactly seven names', () => {
    for (const value of LANGUAGES) {
      expect(weekdayNamesShort(value)).toHaveLength(7);
    }
  });

  it('no name is blank, and the seven never repeat within a language', () => {
    for (const value of LANGUAGES) {
      const names = weekdayNamesShort(value);
      for (const n of names) expect(n.trim(), `${value}`).not.toBe('');
      expect(new Set(names).size, `${value}`).toBe(7);
    }
  });

  it('agrees with Intl on this runtime, so the table cannot rot', () => {
    // THE REASON THE TABLE EXISTS rather than a direct Intl call: a runtime
    // built with reduced ICU answers in English for a locale it does not
    // carry, and the Japanese here is text this app has always shipped. This
    // check gets Intl's authority without making the UI depend on it.
    //
    // 2024-01-01 is a Monday. UTC noon, so no zone conversion can move it.
    for (const value of LANGUAGES) {
      const fmt = new Intl.DateTimeFormat(value, { weekday: 'short', timeZone: 'UTC' });
      const fromIntl = Array.from({ length: 7 }, (_, i) =>
        fmt.format(new Date(Date.UTC(2024, 0, 1 + i, 12))),
      );
      expect(fromIntl, value).toEqual([...weekdayNamesShort(value)]);
    }
  });
});

describe('Monday is index 0, everywhere that counts', () => {
  it('the formatter agrees with weekdayOfDayKey', () => {
    // 2024-01-01 is a Monday; weekdayOfDayKey is 0 = Monday .. 6 = Sunday.
    const expected = ['月', '火', '水', '木', '金', '土', '日'];
    for (let i = 0; i < 7; i++) {
      const dayKey = `2024-01-0${i + 1}`;
      expect(weekdayShort('ja', weekdayOfDayKey(dayKey)), dayKey).toBe(expected[i]);
    }
  });

  it('the formatter agrees with WEEKDAYS, position by position', () => {
    // The recurrence editor indexes the names by its position in WEEKDAYS
    // rather than looking the RFC 5545 code up, so the two orders have to
    // match. This is that assumption, stated.
    expect(WEEKDAYS).toEqual(['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU']);
    expect(WEEKDAYS[0]).toBe('MO');
    expect(weekdayShort('ja', 0)).toBe('月');
    expect(weekdayShort('en', 0)).toBe('Mon');
    expect(WEEKDAYS[6]).toBe('SU');
    expect(weekdayShort('en', 6)).toBe('Sun');
  });

  it('a built week starts on Monday and its cells index the names correctly', () => {
    // Wednesday 2024-01-03 as the anchor: the week must still begin Monday.
    const days = buildWeekDays(new Date('2024-01-03T12:00:00Z'), 'UTC');
    expect(days.map((d) => d.dayKey)).toEqual([
      '2024-01-01',
      '2024-01-02',
      '2024-01-03',
      '2024-01-04',
      '2024-01-05',
      '2024-01-06',
      '2024-01-07',
    ]);
    expect(days.map((d) => weekdayShort('ja', d.weekdayIndex))).toEqual([
      '月',
      '火',
      '水',
      '木',
      '金',
      '土',
      '日',
    ]);
    expect(days.map((d) => weekdayShort('en', d.weekdayIndex))).toEqual([
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ]);
  });
});

describe('a bad input cannot take the calendar down', () => {
  it('an out-of-range index is blank, not a crash and not a wrong day', () => {
    // Every caller passes weekdayOfDayKey's result or a WEEKDAYS position,
    // both 0..6 by construction. A day header is not worth throwing in render
    // for: a blank cell is visible, a crash loses the whole grid.
    for (const i of [-1, 7, 99, 0.5, NaN]) {
      expect(weekdayShort('ja', i), String(i)).toBe('');
    }
  });

  it('an unrecognised language falls back to the default, not to undefined', () => {
    // The value can arrive from owner_settings or navigator.languages, so a
    // row written by a newer version of the app must not render `undefined`.
    // The same runtime check `t()` applies.
    const bogus = 'de' as Language;
    expect(weekdayNamesShort(bogus)).toEqual(weekdayNamesShort(DEFAULT_LANGUAGE));
    expect(weekdayShort(bogus, 0)).toBe('月');
  });
});

describe('all four views share the one formatter', () => {
  it('each imports it, and none holds its own week any more', () => {
    const views = [
      'features/calendar/MonthView.tsx',
      'features/calendar/TimeGridView.tsx',
      'features/event/RecurrenceEditor.tsx',
      'features/share/FreeBusyPage.tsx',
    ];
    for (const p of views) {
      expect(source(p), p).toMatch(/from '[^']*i18n\/dateNames'/);
      expect(source(p), p).not.toMatch(/\['月', '火'/);
      expect(source(p), p).not.toMatch(/MO: '月'/);
    }
  });

  it('each gets the language from useLanguage and passes it explicitly', () => {
    // Not a second, independent read of navigator: the provider already
    // resolved the language once, and wiring.test.ts keeps that the only read.
    for (const p of [
      'features/calendar/MonthView.tsx',
      'features/calendar/TimeGridView.tsx',
      'features/event/RecurrenceEditor.tsx',
      'features/share/FreeBusyPage.tsx',
    ]) {
      expect(source(p), p).toMatch(/const \{ language \} = useLanguage\(\)/);
      expect(source(p), p).toMatch(/weekday(NamesShort|Short)\(language/);
    }
  });

  it('the formatter itself reads no browser locale of its own', () => {
    const mod = code('i18n/dateNames.ts');
    expect(mod).not.toMatch(/navigator|\.languages\b|resolvedOptions/);
    // And it makes no Intl call either: the table is what ships.
    expect(mod).not.toMatch(/Intl\./);
  });

  it('the month grid and the share page render the SAME name for a given day', () => {
    // Two different components, one formatter -- so a Wednesday is the same
    // character in the owner's calendar and on the anonymous page.
    const cell = buildDayCell(new Date('2024-01-03T12:00:00Z'), 'UTC');
    expect(weekdayShort('ja', cell.weekdayIndex)).toBe('水');
    expect(weekdayShort('en', cell.weekdayIndex)).toBe('Wed');
  });
});

/**
 * THE NEGATIVE. Reading the language for a weekday NAME must not have touched
 * what a date MEANS: the instants fetched, the day an all-day event belongs
 * to, or the value a recurrence saves.
 */
describe('the language changes names only, never dates', () => {
  it('the week range is identical whatever the language is', () => {
    // weekRange takes a zone and no language, and that is the point: nothing
    // added in this step can reach it.
    const anchor = new Date('2024-01-03T12:00:00Z');
    const a = weekRange(anchor, 'Asia/Tokyo');
    const b = weekRange(anchor, 'Asia/Tokyo');
    expect(a).toEqual(b);
    expect(a.startIso).toBe('2023-12-31T15:00:00.000Z');
    expect(a.endIso).toBe('2024-01-07T15:00:00.000Z');
  });

  it('the day range still comes from the zone alone', () => {
    const r = dayRange(new Date('2024-01-03T12:00:00Z'), 'Asia/Tokyo');
    expect(r.startIso).toBe('2024-01-02T15:00:00.000Z');
    expect(r.endIso).toBe('2024-01-03T15:00:00.000Z');
  });

  it('weekdayOfDayKey is zone- and language-independent', () => {
    expect(weekdayOfDayKey('2024-01-01')).toBe(0);
    expect(weekdayOfDayKey('2024-01-07')).toBe(6);
  });

  it('the week grid helpers take no language parameter at all', () => {
    const grid = source('features/calendar/weekGrid.ts');
    expect(grid).not.toMatch(/Language|useLanguage|dateNames/);
    // weekTitle and dayTitle take an optional `locale`, which is P4 STEP 2's
    // surface and is still unused by every caller.
    expect(grid).toMatch(/locale\?: string/);
  });

  it('the zone-validity probe still pins en-US, because it tests a NAME', () => {
    // utils/timezone.ts asks whether a zone name is usable. Localising that
    // call would change what it tests, so it is not a display format.
    expect(source('utils/timezone.ts')).toMatch(/Intl\.DateTimeFormat\('en-US'/);
    expect(source('utils/timezone.ts')).not.toMatch(/dateNames|useLanguage/);
  });

  it('the recurrence editor still saves the RFC 5545 code, not the label', () => {
    const editor = source('features/event/RecurrenceEditor.tsx');
    // The checkbox is keyed and toggled by `day`; only the <span> shows a name.
    expect(editor).toMatch(/checked=\{value\.weekdays\.includes\(day\)\}/);
    expect(editor).toMatch(/onChange=\{\(\) => toggleWeekday\(day\)\}/);
    expect(editor).toMatch(/<span>\{weekdays\[i\]\}<\/span>/);
    expect(editor).toMatch(/weekdays: has \? value\.weekdays\.filter/);
  });

  it('the anonymous page still never asks for owner settings', () => {
    // It reads the language from the provider, which carries isPublicRoute on
    // this route -- so this step added no fetch. anon holds no privilege on
    // owner_settings (0025/0026); a read would raise 42501.
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/owner_settings|getOwnerSettings|ownerSettingsRepository/);
    const app = source('App.tsx');
    const shareBranch = app.slice(
      app.indexOf("if (route.kind === 'share')"),
      app.indexOf('</LanguageProvider>'),
    );
    expect(shareBranch).toMatch(/<LanguageProvider isPublicRoute>/);
  });

  it('the Free/Busy fetch range is still built from days and the zone', () => {
    const page = source('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/weekRange\(view\.anchor, timeZone\)/);
    expect(page).toMatch(/getFreeBusy\(token, startIso, endIso, fromDate, toDate\)/);
    expect(page).not.toMatch(/getFreeBusy\([^)]*language/);
  });
});
