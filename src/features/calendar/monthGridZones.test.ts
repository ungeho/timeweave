import { afterAll, describe, expect, it } from 'vitest';
import { buildMonthGrid, monthGridRange } from './monthGrid';
import { addDaysToDateString } from '../../utils/datetime';
import { dayStartInstantIso, weekdayOfDayKey } from '../../utils/timezone';

/*
  R1-M (P8-c1.1): the month grid is CALENDAR arithmetic, not local-Date
  arithmetic.

  It built each cell as a local `new Date(y, m, d)` and read the cell's date
  back out of it. Where the OS zone skipped a whole date that read-back lands
  on the next one: with the OS on Pacific/Apia, 2011-12-30 does not exist
  (12-29 23:59:59 was followed by 12-31 00:00), `new Date(2011, 11, 30)` is
  12-31 00:00, and December 2011 came out with two "31" cells, the same key
  twice and no 30th. The Gregorian calendar still has a 30th; the week view
  (addDaysToDateString) already shows it, as an empty day.

  The OS zone is the app's zone (getUserTimeZone reads the browser), so each
  OS zone below is also the calendar's zone.
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});

const OS_ZONES = ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'America/Sao_Paulo', 'Pacific/Apia'];
// [year, month0] -- the skipped date, midnight gaps/folds, a normal month, month and year edges
const MONTHS: Array<[number, number]> = [
  [2011, 11], [2012, 0], [2011, 10], [2018, 10], [2026, 2], [2026, 10], [2026, 7], [2026, 1], [2024, 1], [2026, 11],
];
const daysIn = (y: number, m0: number) => new Date(Date.UTC(y, m0 + 1, 0)).getUTCDate();

describe('buildMonthGrid is calendar arithmetic in every OS zone (R1-M)', () => {
  for (const os of OS_ZONES) {
    for (const [y, m0] of MONTHS) {
      it(`${os} ${y}-${String(m0 + 1).padStart(2, '0')}`, () => {
        env.TZ = os;
        const cells = buildMonthGrid(new Date(y, m0, 15));
        const keys = cells.map((c) => c.dayKey);
        expect(cells).toHaveLength(42);
        // consecutive calendar dates: no duplicate, no gap
        for (let i = 1; i < keys.length; i++) expect(keys[i], `${keys[i - 1]} -> ?`).toBe(addDaysToDateString(keys[i - 1]!, 1));
        expect(new Set(keys).size).toBe(42);
        // Monday first, and the 1st sits in the first row
        expect(weekdayOfDayKey(keys[0]!)).toBe(0);
        const firstKey = `${y}-${String(m0 + 1).padStart(2, '0')}-01`;
        expect(keys.indexOf(firstKey)).toBe(weekdayOfDayKey(firstKey));
        // the month's own dates, all of them, flagged as such
        const inMonth = cells.filter((c) => c.inCurrentMonth).map((c) => c.dayKey);
        expect(inMonth).toHaveLength(daysIn(y, m0));
        expect(inMonth.every((k) => k.startsWith(firstKey.slice(0, 8)))).toBe(true);
        // the number a cell shows is its own date
        for (const c of cells) expect(c.dayOfMonth, c.dayKey).toBe(Number(c.dayKey.slice(8)));
      });
    }
  }

  it('Apia, December 2011: the 30th is there once, between the 29th and the 31st', () => {
    env.TZ = 'Pacific/Apia';
    const keys = buildMonthGrid(new Date(2011, 11, 15)).map((c) => c.dayKey);
    const i = keys.indexOf('2011-12-30');
    expect(i).toBeGreaterThan(0);
    expect(keys.slice(i - 1, i + 2)).toEqual(['2011-12-29', '2011-12-30', '2011-12-31']);
    expect(keys.filter((k) => k === '2011-12-31')).toHaveLength(1);
  });

  it('Tokyo, August 2026 is unchanged: 2026-07-27 .. 2026-09-06', () => {
    env.TZ = 'Asia/Tokyo';
    const cells = buildMonthGrid(new Date(2026, 7, 15));
    expect(cells[0]!.dayKey).toBe('2026-07-27');
    expect(cells[41]!.dayKey).toBe('2026-09-06');
    expect(cells.map((c) => c.date.getDate())).toEqual(cells.map((c) => c.dayOfMonth));
  });

  it('today is flagged on exactly its own date, also next to the skipped one', () => {
    env.TZ = 'Pacific/Apia';
    const today = new Date(Date.parse('2011-12-31T12:00:00+14:00'));
    const todays = buildMonthGrid(new Date(2011, 11, 15), today).filter((c) => c.isToday);
    expect(todays.map((c) => c.dayKey)).toEqual(['2011-12-31']);
    env.TZ = 'Asia/Tokyo';
    const t2 = buildMonthGrid(new Date(2026, 9, 19), new Date(2026, 9, 19, 8)).filter((c) => c.isToday);
    expect(t2.map((c) => c.dayKey)).toEqual(['2026-10-19']);
  });

  it('the fetched range still runs from the first cell\'s start to the day after the last', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      for (const [y, m0] of MONTHS) {
        const cells = buildMonthGrid(new Date(y, m0, 15));
        const r = monthGridRange(new Date(y, m0, 15));
        expect(r.startIso, `${os} ${y}-${m0 + 1}`).toBe(dayStartInstantIso(cells[0]!.dayKey, os));
        expect(r.endIso, `${os} ${y}-${m0 + 1}`).toBe(dayStartInstantIso(addDaysToDateString(cells[41]!.dayKey, 1), os));
      }
    }
  });
});
