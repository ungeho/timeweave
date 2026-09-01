import { describe, expect, it } from 'vitest';
import { expandRule, formatRRule, parseRRule, UnsupportedRRuleError } from './recurrence';
import type { RecurrenceRule } from '../types/recurrence';
import { isoFromDateString } from '../utils/datetime';

describe('parseRRule', () => {
  it('parses a simple weekly rule', () => {
    expect(parseRRule('FREQ=WEEKLY;BYDAY=MO')).toEqual({
      freq: 'WEEKLY',
      interval: 1,
      byDay: ['MO'],
      count: undefined,
      until: undefined,
    });
  });

  it('parses multiple weekdays and interval', () => {
    const r = parseRRule('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH');
    expect(r.interval).toBe(2);
    expect(r.byDay).toEqual(['TU', 'TH']);
  });

  it('parses COUNT', () => {
    expect(parseRRule('FREQ=DAILY;COUNT=3').count).toBe(3);
  });

  it('rejects ordinal BYDAY like 2MO', () => {
    expect(() => parseRRule('FREQ=WEEKLY;BYDAY=2MO')).toThrow(UnsupportedRRuleError);
  });

  it('rejects unsupported keys', () => {
    expect(() => parseRRule('FREQ=MONTHLY;BYMONTHDAY=1')).toThrow(UnsupportedRRuleError);
  });

  it('rejects BYDAY without WEEKLY', () => {
    expect(() => parseRRule('FREQ=DAILY;BYDAY=MO')).toThrow(UnsupportedRRuleError);
  });

  it('rejects COUNT and UNTIL together', () => {
    expect(() => parseRRule('FREQ=DAILY;COUNT=2;UNTIL=20260101T000000Z')).toThrow(
      UnsupportedRRuleError,
    );
  });

  it('rejects missing FREQ', () => {
    expect(() => parseRRule('INTERVAL=2')).toThrow(UnsupportedRRuleError);
  });
});

describe('expandRule', () => {
  // Use local-time anchors; results are compared by count and local weekday.
  const localIso = (y: number, m: number, d: number, h = 9) =>
    new Date(y, m - 1, d, h, 0, 0, 0).toISOString();

  it('expands weekly Mondays within a range', () => {
    // 2026-08-03 is a Monday.
    const start = localIso(2026, 8, 3);
    const rangeStart = new Date(2026, 7, 1).toISOString();
    const rangeEnd = new Date(2026, 8, 1).toISOString();
    const occ = expandRule('FREQ=WEEKLY;BYDAY=MO', start, rangeStart, rangeEnd);
    // Mondays in Aug 2026: 3, 10, 17, 24, 31
    expect(occ).toHaveLength(5);
    for (const iso of occ) {
      expect(new Date(iso).getDay()).toBe(1); // Monday
    }
  });

  it('honours COUNT across the whole series, not just the range', () => {
    const start = localIso(2026, 8, 3);
    const rangeStart = new Date(2026, 0, 1).toISOString();
    const rangeEnd = new Date(2027, 0, 1).toISOString();
    const occ = expandRule('FREQ=WEEKLY;BYDAY=MO;COUNT=3', start, rangeStart, rangeEnd);
    expect(occ).toHaveLength(3);
  });

  it('handles bi-weekly interval', () => {
    const start = localIso(2026, 8, 4); // Tuesday
    const rangeStart = new Date(2026, 7, 1).toISOString();
    const rangeEnd = new Date(2026, 8, 1).toISOString();
    const occ = expandRule('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU', start, rangeStart, rangeEnd);
    // Every other Tuesday from Aug 4: 4, 18 (Sep 1 excluded)
    expect(occ).toHaveLength(2);
  });

  it('expands multi-day weekly (MO,WE,FR)', () => {
    const start = localIso(2026, 8, 3); // Monday
    const rangeStart = new Date(2026, 7, 3).toISOString();
    const rangeEnd = new Date(2026, 7, 10).toISOString(); // one week
    const occ = expandRule('FREQ=WEEKLY;BYDAY=MO,WE,FR', start, rangeStart, rangeEnd);
    expect(occ).toHaveLength(3);
  });

  it('expands daily and respects UNTIL', () => {
    const start = localIso(2026, 8, 1);
    const until = new Date(2026, 7, 5, 23, 0, 0).toISOString();
    const rangeStart = new Date(2026, 7, 1).toISOString();
    const rangeEnd = new Date(2026, 8, 1).toISOString();
    const occ = expandRule(
      `FREQ=DAILY;UNTIL=${toBasic(until)}`,
      start,
      rangeStart,
      rangeEnd,
    );
    // Aug 1..5 inclusive
    expect(occ).toHaveLength(5);
  });

  it('expands monthly on the same day', () => {
    const start = localIso(2026, 1, 15);
    const rangeStart = new Date(2026, 0, 1).toISOString();
    const rangeEnd = new Date(2026, 6, 1).toISOString(); // Jan..Jun
    const occ = expandRule('FREQ=MONTHLY', start, rangeStart, rangeEnd);
    expect(occ).toHaveLength(6);
    for (const iso of occ) {
      expect(new Date(iso).getDate()).toBe(15);
    }
  });
});

function toBasic(iso: string): string {
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return (
    `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
    `T${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`
  );
}

describe('parseRRule — UNTIL kinds', () => {
  it('parses a timed UNTIL (basic UTC date-time) as an instant', () => {
    expect(parseRRule('FREQ=DAILY;UNTIL=20260805T120000Z').until).toEqual({
      kind: 'instant',
      instant: '2026-08-05T12:00:00.000Z',
    });
  });

  it('parses an all-day UNTIL (DATE) as a date, without UTC conversion', () => {
    expect(parseRRule('FREQ=DAILY;UNTIL=20260805').until).toEqual({
      kind: 'date',
      date: '2026-08-05',
    });
  });

  it('rejects a malformed UNTIL', () => {
    expect(() => parseRRule('FREQ=DAILY;UNTIL=2026-08-05')).toThrow(UnsupportedRRuleError);
  });
});

describe('formatRRule — round-trip parse(format(rule)) === rule', () => {
  const cases: { name: string; rule: RecurrenceRule }[] = [
    { name: 'weekly single day', rule: { freq: 'WEEKLY', interval: 1, byDay: ['MO'], count: undefined, until: undefined } },
    { name: 'weekly multi-day + interval', rule: { freq: 'WEEKLY', interval: 2, byDay: ['MO', 'WE', 'FR'], count: undefined, until: undefined } },
    { name: 'daily count', rule: { freq: 'DAILY', interval: 1, byDay: undefined, count: 5, until: undefined } },
    { name: 'monthly', rule: { freq: 'MONTHLY', interval: 3, byDay: undefined, count: undefined, until: undefined } },
    {
      name: 'timed until (instant)',
      rule: { freq: 'WEEKLY', interval: 1, byDay: ['TU'], count: undefined, until: { kind: 'instant', instant: '2026-08-31T15:00:00.000Z' } },
    },
    {
      name: 'all-day until (date)',
      rule: { freq: 'DAILY', interval: 1, byDay: undefined, count: undefined, until: { kind: 'date', date: '2026-09-02' } },
    },
  ];

  for (const c of cases) {
    it(c.name, () => {
      expect(parseRRule(formatRRule(c.rule))).toEqual(c.rule);
    });
  }

  it('emits a timed UNTIL with T/Z and an all-day UNTIL without', () => {
    const timed = formatRRule({ freq: 'DAILY', interval: 1, until: { kind: 'instant', instant: '2026-08-05T12:00:00.000Z' } });
    const allDay = formatRRule({ freq: 'DAILY', interval: 1, until: { kind: 'date', date: '2026-08-05' } });
    expect(timed).toBe('FREQ=DAILY;UNTIL=20260805T120000Z');
    expect(allDay).toBe('FREQ=DAILY;UNTIL=20260805');
    // The all-day UNTIL *value* carries no time/zone marker.
    expect(allDay.split('UNTIL=')[1]).not.toMatch(/[TZ]/);
  });
});

describe('expandRule — all-day date UNTIL', () => {
  it('stops at the UNTIL date inclusively (calendar-date space)', () => {
    const start = isoFromDateString('2026-08-01'); // local midnight
    const rangeStart = new Date(2026, 7, 1).toISOString();
    const rangeEnd = new Date(2026, 8, 1).toISOString();
    const occ = expandRule('FREQ=DAILY;UNTIL=20260805', start, rangeStart, rangeEnd);
    expect(occ).toHaveLength(5); // Aug 1..5 inclusive
  });
});

describe('expandRule — MONTHLY month-end (RFC 5545 skip)', () => {
  const localIso = (y: number, m: number, d: number, h = 9) =>
    new Date(y, m - 1, d, h, 0, 0, 0).toISOString();

  /** Local "YYYY-MM-DD" of each occurrence, for exact date assertions. */
  const dayKeys = (occ: string[]): string[] =>
    occ.map((iso) => {
      const d = new Date(iso);
      const p2 = (n: number) => String(n).padStart(2, '0');
      return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}`;
    });

  it('skips months without the 31st instead of rolling into the next month', () => {
    // The old behaviour rolled Jan 31 + 1 month to Mar 3. RFC 5545 skips Feb.
    const start = localIso(2026, 1, 31);
    const occ = expandRule(
      'FREQ=MONTHLY',
      start,
      new Date(2026, 0, 1).toISOString(),
      new Date(2027, 0, 1).toISOString(),
    );
    expect(dayKeys(occ)).toEqual([
      '2026-01-31',
      '2026-03-31',
      '2026-05-31',
      '2026-07-31',
      '2026-08-31',
      '2026-10-31',
      '2026-12-31',
    ]);
    // Never lands on a rolled-over day (Mar 3, May 1, ...).
    for (const iso of occ) expect(new Date(iso).getDate()).toBe(31);
  });

  it('skips only February for a day-30 series', () => {
    const start = localIso(2026, 1, 30);
    const occ = expandRule(
      'FREQ=MONTHLY',
      start,
      new Date(2026, 0, 1).toISOString(),
      new Date(2027, 0, 1).toISOString(),
    );
    expect(occ).toHaveLength(11); // 12 months minus February
    for (const iso of occ) expect(new Date(iso).getDate()).toBe(30);
  });

  it('handles Feb 29: present only in leap Februaries', () => {
    const start = localIso(2024, 2, 29); // 2024 is a leap year
    const occ = expandRule(
      'FREQ=MONTHLY',
      start,
      new Date(2024, 0, 1).toISOString(),
      new Date(2029, 0, 1).toISOString(),
    );
    expect(occ).toHaveLength(56); // every month on the 29th, minus Feb 2025/26/27
    const februaries = dayKeys(occ).filter((k) => k.slice(5, 7) === '02');
    expect(februaries).toEqual(['2024-02-29', '2028-02-29']);
  });

  it('applies the skip with INTERVAL > 1', () => {
    // Every 2nd month from Jan 31: Jan, Mar, May, Jul all have 31; Sep/Nov do not.
    const start = localIso(2026, 1, 31);
    const occ = expandRule(
      'FREQ=MONTHLY;INTERVAL=2',
      start,
      new Date(2026, 0, 1).toISOString(),
      new Date(2027, 0, 1).toISOString(),
    );
    expect(dayKeys(occ)).toEqual([
      '2026-01-31',
      '2026-03-31',
      '2026-05-31',
      '2026-07-31',
    ]);
  });

  it('does not count skipped months toward COUNT', () => {
    // COUNT=3 must yield 3 REAL occurrences (Jan/Mar/May), not stop at May
    // having "spent" two counts on the skipped Feb and Apr.
    const start = localIso(2026, 1, 31);
    const occ = expandRule(
      'FREQ=MONTHLY;COUNT=3',
      start,
      new Date(2026, 0, 1).toISOString(),
      new Date(2027, 0, 1).toISOString(),
    );
    expect(dayKeys(occ)).toEqual(['2026-01-31', '2026-03-31', '2026-05-31']);
  });

  it('stops at UNTIL inclusively across a skipped month', () => {
    const until = new Date(2026, 2, 31, 23, 0, 0).toISOString(); // Mar 31 local
    const start = localIso(2026, 1, 31);
    const occ = expandRule(
      `FREQ=MONTHLY;UNTIL=${toBasic(until)}`,
      start,
      new Date(2026, 0, 1).toISOString(),
      new Date(2027, 0, 1).toISOString(),
    );
    expect(dayKeys(occ)).toEqual(['2026-01-31', '2026-03-31']);
  });

  it('still emits a later valid month when the range starts inside a skipped one', () => {
    // Range covers only Feb (skipped) and Mar; the Feb skip must not end the loop.
    const start = localIso(2026, 1, 31);
    const occ = expandRule(
      'FREQ=MONTHLY',
      start,
      new Date(2026, 1, 1).toISOString(),
      new Date(2026, 3, 1).toISOString(),
    );
    expect(dayKeys(occ)).toEqual(['2026-03-31']);
  });
});
